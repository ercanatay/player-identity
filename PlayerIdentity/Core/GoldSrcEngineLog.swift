import Foundation

// MARK: - §75.13 GoldSrc engine log evidence

/// What the engine itself wrote about its last GoldSrc 48 connection (`engine.log` in the data root; the engine
/// writes its console there when started with `-dev 1 -log`, which "Join Game" does for a GoldSrc 48 server).
/// Only the **last** GoldSrc connect block of the log counts: it must name this server's address and belong to a
/// recent session, otherwise there is no evidence (`nil`, the ban status stays unverified).
struct GoldSrcLogEvidence: Sendable, Equatable {
    enum Outcome: String, Codable, Sendable {
        /// "Server issued disconnect. Reason: …" / "Server message" with a ban text.
        case banned
        /// The server ended or refused the connection with another reason.
        case disconnected
        /// The engine entered the server ("Spooling demo header.") and no server reason followed: no ban at that time
        /// (it only clears an older ban record; it never means "no block").
        case connected
    }

    let outcome: Outcome
    /// The server's reason, cleaned (control characters removed, IP addresses masked), at most 200 characters.
    let reason: String
    /// `host:port` the engine connected to (as written by the engine).
    let address: String
    /// Start of the engine session that wrote the block ("Game started at …").
    let sessionStart: Date
}

enum GoldSrcEngineLog {
    static let fileName = "engine.log"
    static let maxBytes = 512 * 1024
    /// A block from an older session is stale.
    static let maxAge: TimeInterval = 24 * 60 * 60
    /// Clock tolerance between "Join Game" and the session header.
    static let joinTolerance: TimeInterval = 120
    static let goldSrcLine = "Trying to connect with GoldSrc 48 protocol"

    static func url(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    enum ReadResult: Sendable, Equatable {
        case missing
        /// The file exists but cannot be read (the error is shown to the caller to log).
        case unreadable(String)
        case data(String)

        var text: String? {
            if case .data(let text) = self { return text }
            return nil
        }
    }

    /// The tail of `<data root>/engine.log`. Read-only; a missing file and a read error are kept apart.
    static func read(dataRoot: URL, fileSystem: any FileSystemReading) -> ReadResult {
        let url = url(dataRoot: dataRoot)
        guard fileSystem.isRegularFile(url) else { return .missing }
        do {
            return .data(String(decoding: try fileSystem.readTail(url, maxBytes: maxBytes), as: UTF8.self))
        } catch {
            return .unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// `host:port` forms the engine may have written for a server (lower-cased; IPv6 in brackets). `known` adds IP
    /// addresses the app learned before (the last successful resolution, the server's own A2S address string), so a
    /// DNS failure now does not hide the engine's evidence; only IP literals are taken from them (never a hostname or
    /// any other text), always with the row's port.
    static func addresses(host: String, port: Int, resolved: String?, known: [String?] = []) -> Set<String> {
        let ips = known.compactMap { $0 }.compactMap(ipLiteral)
        return Set(([host, resolved].compactMap { $0 } + ips).filter { !$0.isEmpty }.map {
            ServerAddressText.hostPort(host: $0, port: port).lowercased()
        })
    }

    /// The IP of `1.2.3.4`, `1.2.3.4:27015`, `[2001:db8::1]:27015` or `2001:db8::1` (normalized); `nil` for anything
    /// that is not an IP literal (hostnames, paths, extra text).
    static func ipLiteral(_ text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespaces)
        if candidate.hasPrefix("["), let end = candidate.firstIndex(of: "]") {
            candidate = String(candidate[candidate.index(after: candidate.startIndex)..<end])
        } else if candidate.filter({ $0 == ":" }).count == 1, let colon = candidate.lastIndex(of: ":") {
            candidate = String(candidate[..<colon])
        }
        guard let address = ServerAddress.parse(candidate), address != .localMachine else { return nil }
        return address.text
    }

    /// Evidence of the last GoldSrc block for one of `addresses`; `nil` when the last block is another server's,
    /// has no server answer, has no session date, is older than `maxAge` or older than `notBefore` (the last
    /// "Join Game" of this server, when known).
    static func evidence(in text: String, addresses: Set<String>, now: Date, notBefore: Date? = nil,
                         redactor: Redactor = Redactor()) -> GoldSrcLogEvidence? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { clean(String($0)) }
        guard let start = lines.lastIndex(where: { $0.contains(goldSrcLine) }) else { return nil }
        // The address of the block: the nearest "Connecting to …" / "server …" line before it.
        var address: String?
        var sessionStart: Date?
        for index in stride(from: start - 1, through: 0, by: -1) {
            let line = lines[index]
            if address == nil, let value = connectAddress(line) { address = value }
            if let date = sessionDate(line) { sessionStart = date; break }
        }
        guard let address, addresses.contains(address.lowercased()), let sessionStart else { return nil }
        guard sessionStart >= now.addingTimeInterval(-maxAge), sessionStart <= now.addingTimeInterval(joinTolerance) else {
            return nil
        }
        if let notBefore, sessionStart < notBefore.addingTimeInterval(-joinTolerance) { return nil }
        // The server's answer inside the block (until the next connection attempt or session).
        var entered = false
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("Connecting to ") || line.contains(goldSrcLine) || sessionDate(line) != nil { break }
            if line.hasPrefix("Spooling demo header") { entered = true }
            var reason: String?
            if let range = line.range(of: "Server issued disconnect. Reason:") {
                reason = String(line[range.upperBound...])
            } else if line == "Server message" {
                reason = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            if let reason {
                let cleaned = GoldSrcReplies.serverMessage(EngineLogReader.redact(reason, redactor: redactor))
                let banned = GoldSrcBanText.isBan(cleaned)
                return GoldSrcLogEvidence(outcome: banned ? .banned : .disconnected, reason: cleaned, address: address,
                                          sessionStart: sessionStart)
            }
            index += 1
        }
        return entered ? GoldSrcLogEvidence(outcome: .connected, reason: "", address: address, sessionStart: sessionStart) : nil
    }

    /// Without colour codes and the `[HH:MM:SS] ` prefix of the console output.
    static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\[\d{2}:\d{2}:\d{2}\] "#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `Connecting to 192.0.2.10:27015... (retry #1)` / `server 192.0.2.10:27015` → `192.0.2.10:27015`.
    static func connectAddress(_ line: String) -> String? {
        for prefix in ["Connecting to ", "server "] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            let token = rest.split(separator: " ").first.map(String.init) ?? ""
            let address = token.hasSuffix("...") ? String(token.dropLast(3)) : token
            if address.range(of: #"^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$"#, options: .regularExpression) != nil {
                return address
            }
        }
        return nil
    }

    /// `Game started at Nov26 2026 [14:58.04]` → the local date.
    static func sessionDate(_ line: String) -> Date? {
        guard let range = line.range(of: "Game started at ") else { return nil }
        let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["MMMdd yyyy '['HH:mm.ss']'", "MMMd yyyy '['HH:mm.ss']'", "MMM d yyyy '['HH:mm.ss']'"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

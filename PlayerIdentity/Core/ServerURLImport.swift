import Foundation

/// §50 server import: parses pasted text (lines / commas) into server candidates. Pure; no network.
enum ServerURLImport {
    /// Most entries one run processes; the rest is reported, not parsed.
    static let maxEntries = 100

    /// Why an entry was rejected.
    enum Reason: Error, Sendable, Equatable {
        case unsupportedURL
        case ipv6NeedsBrackets
        case hostInvalid
        case portInvalid

        var text: String {
            switch self {
            case .unsupportedURL: return L10n.text(.serverImportReasonUnsupported)
            case .ipv6NeedsBrackets: return L10n.text(.serverImportReasonIPv6)
            case .hostInvalid: return L10n.text(.errorInvalidHost)
            case .portInvalid: return L10n.text(.serverProblemPortInvalid)
            }
        }
    }

    /// A valid host + port; the label defaults to the host.
    struct Candidate: Sendable, Equatable, Identifiable {
        let host: String
        let port: Int
        var label: String { host }
        var id: String { "\(host):\(port)" }
    }

    struct Invalid: Sendable, Equatable, Identifiable {
        /// 1-based position among the non-empty entries.
        let index: Int
        let raw: String
        let reason: Reason
        var id: Int { index }
    }

    struct Result: Sendable, Equatable {
        /// Valid and not yet in the list (selected by default).
        var fresh: [Candidate] = []
        /// Valid, but host + port already exist in the list.
        var existing: [Candidate] = []
        var invalid: [Invalid] = []
        /// Entries repeating an earlier one of the same input.
        var duplicates = 0
        /// Entries beyond `maxEntries` (not parsed).
        var overflow = 0

        var isEmpty: Bool { fresh.isEmpty && existing.isEmpty && invalid.isEmpty }
        /// Default selection: new and valid only.
        var defaultSelection: Set<String> { Set(fresh.map(\.id)) }
    }

    static func parse(_ text: String, existing: [ServerEntry] = []) -> Result {
        let tokens = text.components(separatedBy: .newlines)
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result = Result()
        result.overflow = max(0, tokens.count - maxEntries)
        let known = Set(existing.map { key(HostValidator.normalized($0.host), $0.port) })
        var seen = Set<String>()
        for (offset, token) in tokens.prefix(maxEntries).enumerated() {
            switch parseEntry(token) {
            case .failure(let reason):
                result.invalid.append(Invalid(index: offset + 1, raw: token, reason: reason))
            case .success(let candidate):
                guard seen.insert(candidate.id).inserted else {
                    result.duplicates += 1
                    continue
                }
                if known.contains(candidate.id) { result.existing.append(candidate) } else { result.fresh.append(candidate) }
            }
        }
        return result
    }

    private static func key(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    // MARK: Single entry

    static func parseEntry(_ token: String) -> Swift.Result<Candidate, Reason> {
        var rest = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
        let lower = rest.lowercased()

        if lower.hasPrefix("steam://connect/") {
            rest = String(rest.dropFirst("steam://connect/".count))
            rest = firstSegment(rest)
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            rest = String(rest[rest.index(rest.startIndex, offsetBy: lower.hasPrefix("https") ? 8 : 7)...])
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let authority = parts[0].lowercased()
            if authority == "www.gametracker.com" || authority == "gametracker.com" {
                guard parts.count >= 3, parts[1].lowercased() == "server_info", !parts[2].isEmpty else {
                    return .failure(.unsupportedURL)
                }
                rest = parts[2]
            } else {
                rest = parts[0]
            }
        } else if lower.contains("://") {
            return .failure(.unsupportedURL)
        } else {
            rest = firstSegment(rest)
        }
        return parseHostPort(rest)
    }

    private static func firstSegment(_ text: String) -> String {
        text.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    private static func parseHostPort(_ text: String) -> Swift.Result<Candidate, Reason> {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(.hostInvalid) }
        var host: String
        var portText: String?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return .failure(.hostInvalid) }
            host = String(value[value.index(after: value.startIndex)..<close])
            let tail = value[value.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { return .failure(.hostInvalid) }
                portText = String(tail.dropFirst())
            }
            guard host.contains(":"), ServerAddress.parse(host) != nil else { return .failure(.hostInvalid) }
        } else {
            let colons = value.filter { $0 == ":" }.count
            if colons > 1 { return .failure(.ipv6NeedsBrackets) }
            if colons == 1 {
                let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                host = String(parts[0])
                portText = String(parts[1])
            } else {
                host = value
            }
            guard HostValidator.classify(host) != nil else { return .failure(.hostInvalid) }
        }
        host = HostValidator.normalized(host)
        var port = ServerEntry.defaultPort
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }), portText.count <= 5,
                  let value = Int(portText), HostValidator.isValidPort(value) else { return .failure(.portInvalid) }
            port = value
        }
        return .success(Candidate(host: host, port: port))
    }
}

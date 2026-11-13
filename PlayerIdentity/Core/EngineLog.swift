import Foundation

// MARK: - §64.3 Engine log (read-only evidence)

/// Known engine log lines (§64.3). Matching is case-insensitive on the raw line.
enum EngineLogPattern: String, Codable, Sendable, CaseIterable {
    case couldntConnect
    case serverNotResponding
    case badChallenge
    case hostError
    case sendPacketError
    case connectionReset
    case invalidCDKey
    case ipBanned
    case banned

    /// Text searched for in a log line (the engine's own wording).
    var needle: String { Self.needles[self] ?? rawValue }

    private static let needles: [EngineLogPattern: String] = [
        .couldntConnect: "Couldn't connect",
        .serverNotResponding: "Server is not responding",
        .badChallenge: "Bad challenge",
        .hostError: "host_error",
        .sendPacketError: "NET_SendPacket ERROR",
        .connectionReset: "Connection reset",
        .invalidCDKey: "Invalid CD key",
        .ipBanned: "Your IP is banned",
        .banned: "You have been banned",
    ]

    /// Plain-language explanation.
    var explanation: String {
        switch self {
        case .couldntConnect: return L10n.text(.diagnoseLogPatternCouldntConnect)
        case .serverNotResponding: return L10n.text(.diagnoseLogPatternServerNotResponding)
        case .badChallenge: return L10n.text(.diagnoseLogPatternBadChallenge)
        case .hostError: return L10n.text(.diagnoseLogPatternHostError)
        case .sendPacketError: return L10n.text(.diagnoseLogPatternSendPacketError)
        case .connectionReset: return L10n.text(.diagnoseLogPatternConnectionReset)
        case .invalidCDKey: return L10n.text(.diagnoseLogPatternInvalidCDKey)
        case .ipBanned: return L10n.text(.diagnoseLogPatternIpBanned)
        case .banned: return L10n.text(.diagnoseLogPatternBanned)
        }
    }

    /// Direct engine statements that decide the verdict on their own (§64.3); every other pattern is evidence only.
    var directVerdict: DiagnosisVerdict? {
        switch self {
        case .ipBanned: return .ipBanned
        case .banned: return .cidBanned
        default: return nil
        }
    }
}

struct EngineLogMatch: Codable, Sendable, Equatable {
    var pattern: EngineLogPattern
    /// 1-based line number inside the scanned window (the last 200 lines).
    var matchedAt: Int
    /// The raw line, redacted (IP addresses and the home folder masked).
    var line: String
}

struct EngineLogReport: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case found
        case missing
        case unreadable
    }

    var status: Status
    /// File name that was read or attempted (`qconsole.log` / `console.log`); `nil` when there is none.
    var fileName: String?
    var matches: [EngineLogMatch] = []
    /// Number of lines scanned (≤ 200).
    var scannedLines = 0

    static let missing = EngineLogReport(status: .missing)

    /// The newest direct engine statement (`Your IP is banned` / `You have been banned`), if any.
    var directVerdict: DiagnosisVerdict? {
        matches.reversed().lazy.compactMap(\.pattern.directVerdict).first
    }
}

/// Reads the tail of `<data root>/<gamedir>/qconsole.log` (fallback `console.log`). Never writes, never creates.
enum EngineLogReader {
    static let fileNames = ["qconsole.log", "console.log"]
    static let maxBytes = 512 * 1024
    static let maxLines = 200
    /// Longest line kept (characters).
    static let maxLineLength = 300

    static func candidates(dataRoot: URL, gamedir: String?) -> [URL] {
        guard let gamedir, !gamedir.isEmpty else { return [] }
        let folder = dataRoot.appendingPathComponent(gamedir, isDirectory: true)
        return fileNames.map { folder.appendingPathComponent($0, isDirectory: false) }
    }

    static func read(dataRoot: URL, gamedir: String?, fileSystem: any FileSystemReading,
                     redactor: Redactor) -> EngineLogReport {
        guard let url = candidates(dataRoot: dataRoot, gamedir: gamedir).first(where: fileSystem.isRegularFile) else {
            return .missing
        }
        let data: Data
        do {
            data = try fileSystem.readTail(url, maxBytes: maxBytes)
        } catch {
            return EngineLogReport(status: .unreadable, fileName: url.lastPathComponent)
        }
        let lines = tailLines(data, truncated: data.count >= maxBytes)
        return EngineLogReport(status: .found, fileName: url.lastPathComponent,
                               matches: scan(lines, redactor: redactor), scannedLines: lines.count)
    }

    /// The last 200 lines; a cut-off first line of a truncated tail is dropped.
    static func tailLines(_ data: Data, truncated: Bool) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map(String.init)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(maxLines))
    }

    /// The home folder and IP literals masked (`Redactor`), including `a.b.c.d:port` forms it leaves whole.
    static func redact(_ line: String, redactor: Redactor) -> String {
        let text = redactor.text(line)
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b"#) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1.$2.x.x")
    }

    /// Direct engine statements are tried first so a combined line keeps its verdict.
    static let matchOrder: [EngineLogPattern] = [.ipBanned, .banned, .invalidCDKey, .badChallenge, .serverNotResponding,
                                                 .couldntConnect, .connectionReset, .sendPacketError, .hostError]

    /// One match per line (the first pattern of `matchOrder` that fits).
    static func scan(_ lines: [String], redactor: Redactor) -> [EngineLogMatch] {
        lines.enumerated().compactMap { index, line in
            let lower = line.lowercased()
            guard let pattern = matchOrder.first(where: { lower.contains($0.needle.lowercased()) }) else {
                return nil
            }
            let cleaned = BanReplies.printable(redact(line, redactor: redactor), limit: maxLineLength)
            return EngineLogMatch(pattern: pattern, matchedAt: index + 1, line: cleaned)
        }
    }
}

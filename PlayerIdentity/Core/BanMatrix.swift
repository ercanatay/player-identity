import Foundation

// MARK: - §38 Ban matrix

/// One cell of the matrix.
enum BanMatrixCell: String, Sendable, Equatable, CaseIterable {
    case banned
    case clear
    /// The step ran but the answer was not conclusive (or the step was never reached).
    case unknown
    /// The server rejected the client with a non-ban answer (protocol mismatch).
    case notApplicable
    /// No check yet / server unreachable: shown as "—".
    case none
}

struct BanMatrixRow: Sendable, Equatable {
    let serverID: UUID
    let label: String
    let host: String
    let port: Int
    let ipBan: BanMatrixCell
    let cidBan: BanMatrixCell
    /// §17.10: suspected range ban (CIDR) found by the last fix attempt; `nil` = none.
    let range: String?
    let lastCheck: Date?
    /// "Ban türü doğrulanamadı": rejected with an unknown ban type.
    let unverified: Bool
    let unreachable: Bool
    /// §66.1 diagnoses of the last 7 days (`nil` = not computed, shown as "—").
    var recent: BanMatrixRecent? = nil

    var isBanned: Bool { ipBan == .banned || cidBan == .banned || range != nil }

    /// Sort rank: banned, unverified, unknown/unreachable, clear, not checked.
    var rank: Int {
        if isBanned { return 0 }
        if unverified { return 1 }
        if unreachable || ipBan == .unknown || cidBan == .unknown { return 2 }
        if ipBan == .none && cidBan == .none { return 4 }
        return 3
    }
}

enum BanMatrix {
    /// Rows for the servers (banned first; §66.1 within a rank, more ban verdicts in the last 7 days first;
    /// otherwise the given order is kept).
    static func rows(servers: [ServerEntry], rangeBans: [UUID: String] = [:],
                     recent: [UUID: BanMatrixRecent] = [:]) -> [BanMatrixRow] {
        servers.map { entry -> BanMatrixRow in
            var row = row(for: entry, range: rangeBans[entry.id])
            row.recent = recent[entry.id]
            return row
        }
        .enumerated()
        .sorted { lhs, rhs in
            if lhs.element.rank != rhs.element.rank { return lhs.element.rank < rhs.element.rank }
            let left = lhs.element.recent?.banRuns ?? 0
            let right = rhs.element.recent?.banRuns ?? 0
            return left != right ? left > right : lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    static func row(for entry: ServerEntry, range: String?) -> BanMatrixRow {
        let check = entry.banCheck
        let cells: (BanMatrixCell, BanMatrixCell)
        switch check?.status {
        case nil: cells = (.none, .none)
        case .unreachable?: cells = (.none, .none)
        case .ipBanned?: cells = (.banned, .unknown)
        case .ipOk?: cells = (.clear, .none)
        case .cidOk?: cells = (.clear, .clear)
        case .cidBanned?: cells = (.clear, .banned)
        case .cidNotApplicable?: cells = (.clear, .notApplicable)
        case .cidUnknown?: cells = (.clear, .unknown)
        case .unknown?: cells = (.unknown, .unknown)
        }
        var unverified = false
        if let check, case .rejectedUnknownType = BanClassification.classify(check) { unverified = true }
        return BanMatrixRow(serverID: entry.id, label: entry.label, host: entry.host, port: entry.port,
                            ipBan: cells.0, cidBan: cells.1, range: range, lastCheck: check?.checkedAt,
                            unverified: unverified, unreachable: check?.status == .unreachable)
    }

    /// Suspected range bans per server from the history: the latest fix attempt ended with `rangeBanned`
    /// and no `banLifted` came after it.
    static func rangeBans(from history: [HistoryEntry]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for entry in history.sorted(by: { $0.ts < $1.ts }) {
            guard let id = entry.serverID else { continue }
            switch entry.kind {
            case .fixAttempt:
                if entry.note == "rangeBanned", let old = entry.old, let new = entry.new,
                   let cidr = IPRange.sharedWideRange(old, new) {
                    result[id] = cidr
                } else if entry.note == "resolved" {
                    result[id] = nil
                }
            case .banLifted:
                result[id] = nil
            default:
                break
            }
        }
        return result
    }

    /// Table for export: `header` first, then one line per row; cell texts come from the caller (localized).
    static func table(_ rows: [BanMatrixRow], header: [String],
                      cell: (BanMatrixRow) -> [String]) -> [[String]] {
        [header] + rows.map(cell)
    }
}

// MARK: - CSV (RFC 4180) and clipboard text

enum CSV {
    /// RFC 4180: CRLF line breaks; a field containing a comma, quote, CR or LF is quoted and quotes are doubled.
    static func encode(_ table: [[String]]) -> String {
        table.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + (table.isEmpty ? "" : "\r\n")
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Clipboard text: tab-separated lines (pastes into spreadsheets); tabs and line breaks in cells become spaces.
    static func tabSeparated(_ table: [[String]]) -> String {
        table.map { row in
            row.map { $0.components(separatedBy: CharacterSet(charactersIn: "\t\r\n")).joined(separator: " ") }
                .joined(separator: "\t")
        }
        .joined(separator: "\n") + (table.isEmpty ? "" : "\n")
    }
}

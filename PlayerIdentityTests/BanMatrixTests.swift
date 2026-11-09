import XCTest
@testable import PlayerIdentity

/// §38 ban matrix, sorting, CSV (RFC 4180) and clipboard text.
final class BanMatrixTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func entry(_ label: String, _ status: BanStatus?, detail: String = "") -> ServerEntry {
        ServerEntry(label: label, host: "192.0.2.10",
                    banCheck: status.map { BanCheck(status: $0, checkedAt: Self.t0, detail: detail) })
    }

    func testCellsPerStatus() {
        func cells(_ status: BanStatus?) -> [BanMatrixCell] {
            let row = BanMatrix.row(for: entry("x", status), range: nil)
            return [row.ipBan, row.cidBan]
        }
        XCTAssertEqual(cells(.ipBanned), [.banned, .unknown])
        XCTAssertEqual(cells(.cidBanned), [.clear, .banned])
        XCTAssertEqual(cells(.cidOk), [.clear, .clear])
        XCTAssertEqual(cells(.ipOk), [.clear, .none])
        XCTAssertEqual(cells(.cidNotApplicable), [.clear, .notApplicable])
        XCTAssertEqual(cells(.cidUnknown), [.clear, .unknown])
        XCTAssertEqual(cells(.unknown), [.unknown, .unknown])
        XCTAssertEqual(cells(.unreachable), [.none, .none])                  // "—"
        XCTAssertEqual(cells(nil), [.none, .none])
        XCTAssertTrue(BanMatrix.row(for: entry("x", .unreachable), range: nil).unreachable)
        XCTAssertEqual(BanMatrix.row(for: entry("x", .cidOk), range: nil).lastCheck, Self.t0)
        // "Ban türü doğrulanamadı"
        let unverified = BanMatrix.row(for: entry("x", .cidUnknown, detail: "ipOk → cidUnknown: errormsg Kicked"), range: nil)
        XCTAssertTrue(unverified.unverified)
        XCTAssertFalse(BanMatrix.row(for: entry("x", .cidUnknown, detail: "ipOk → cidUnknown"), range: nil).unverified)
    }

    func testSortingBannedFirst() {
        let servers = [entry("clear", .cidOk), entry("none", nil), entry("off", .unreachable), entry("ip", .ipBanned),
                       entry("odd", .cidUnknown, detail: "ipOk → cidUnknown: disconnect x"), entry("cid", .cidBanned),
                       entry("ranged", .cidOk)]
        let rows = BanMatrix.rows(servers: servers, rangeBans: [servers[6].id: "198.51.0.0/16"])
        XCTAssertEqual(rows.map(\.label), ["ip", "cid", "ranged", "odd", "off", "clear", "none"])
        XCTAssertEqual(rows[2].range, "198.51.0.0/16")
        XCTAssertEqual(BanMatrix.rows(servers: []), [])     // empty state
    }

    func testRangeBansFromHistory() {
        let a = UUID(), b = UUID(), c = UUID()
        let history = [
            HistoryEntry(ts: Self.t0, kind: .fixAttempt, serverID: a, old: "198.51.100.7", new: "198.51.23.9", note: "rangeBanned"),
            HistoryEntry(ts: Self.t0, kind: .fixAttempt, serverID: b, old: "198.51.100.7", new: "198.51.23.9", note: "rangeBanned"),
            HistoryEntry(ts: Self.t0 + 60, kind: .banLifted, serverID: b, old: "ipBanned", new: "cidOk"),
            HistoryEntry(ts: Self.t0, kind: .fixAttempt, serverID: c, old: "198.51.100.7", new: "203.0.113.5", note: "stillBanned"),
        ]
        XCTAssertEqual(BanMatrix.rangeBans(from: history), [a: "198.51.0.0/16"])
    }

    func testCSVEscaping() {
        let table = [["Server", "IP ban"], ["Plain", "no"], ["Comma, Inc", "say \"hi\""], ["Two\nLines", "x\r\ny"], ["", "end"]]
        XCTAssertEqual(CSV.encode(table),
                       "Server,IP ban\r\nPlain,no\r\n\"Comma, Inc\",\"say \"\"hi\"\"\"\r\n\"Two\nLines\",\"x\r\ny\"\r\n,end\r\n")
        XCTAssertEqual(CSV.encode([]), "")
        XCTAssertEqual(CSV.tabSeparated([["a\tb", "c\nd"], ["e", ""]]), "a b\tc d\ne\t\n")
    }

    func testTableUsesCallerTexts() {
        let rows = BanMatrix.rows(servers: [entry("A", .ipBanned)])
        let table = BanMatrix.table(rows, header: ["Server", "IP", "CID", "Range", "Last check"]) { row in
            [row.label, row.ipBan.rawValue, row.cidBan.rawValue, row.range ?? "—", row.lastCheck.map { ISO8601DateFormatter().string(from: $0) } ?? "—"]
        }
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table[1], ["A", "banned", "unknown", "—", "2026-10-26T07:33:20Z"])
    }
}

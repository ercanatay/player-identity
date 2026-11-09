import XCTest
@testable import PlayerIdentity

/// §20/§21 row texts and §22 history texts in both languages.
final class DisplayTextTests: XCTestCase {
    private func inLanguage<T>(_ language: String, _ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language)), operation: body)
    }

    private func row(resolvedIP: String? = nil, failure: HostResolutionFailure? = nil) -> ServerRowStatus {
        ServerRowStatus(id: UUID(), level: .orange, currentCID: nil, message: nil, resolvedIP: resolvedIP,
                        resolutionFailure: failure)
    }

    func testAddressLine() throws {
        try inLanguage("tr") {
            XCTAssertEqual(ServerRowText.addressLine(host: "play.example.com", status: row(resolvedIP: "1.2.3.4")),
                           "play.example.com → 1.2.3.4")
            XCTAssertEqual(ServerRowText.addressLine(host: "play.example.com", status: row(failure: .pending)),
                           "play.example.com → çözülüyor…")
            XCTAssertEqual(ServerRowText.addressLine(host: "play.example.com", status: row(failure: .notFound)),
                           "play.example.com → ad bulunamadı")
            XCTAssertEqual(ServerRowText.addressLine(host: "play.example.com", status: row(failure: .network)),
                           "play.example.com → DNS hatası (ağ)")
            XCTAssertNil(ServerRowText.addressLine(host: "51.68.190.91", status: row()))   // IP literal
            XCTAssertNil(ServerRowText.addressLine(host: "bad host", status: row(failure: .invalid)))
        }
        try inLanguage("en") {
            XCTAssertEqual(ServerRowText.addressLine(host: "a.example", status: row(failure: .pending)), "a.example → resolving…")
        }
    }

    func testInfoLineHidesUnknownParts() throws {
        try inLanguage("tr") {
            XCTAssertEqual(ServerRowText.infoLine(ServerInfo(name: "S", map: "rpg_city", players: 9, maxPlayers: 26, pingMillis: 42)),
                           "rpg_city · 9/26 · 42 ms")
            XCTAssertEqual(ServerRowText.infoLine(ServerInfo(players: 3)), "3")
            XCTAssertEqual(ServerRowText.infoLine(ServerInfo(pingMillis: 0)), "0 ms")
            XCTAssertNil(ServerRowText.infoLine(ServerInfo(name: "only name")))
            XCTAssertNil(ServerRowText.infoLine(nil))
        }
    }

    func testHistoryTexts() throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        try inLanguage("tr") {
            XCTAssertEqual(HistoryKind.allCases.map(HistoryText.kind).count, 17)   // §32 `appeal`, §36 `note`, §42 watch ×5
            XCTAssertEqual(HistoryText.kind(.banAppeared), "Ban başladı")
            XCTAssertEqual(HistoryText.change(HistoryEntry(ts: t0, kind: .banAppeared, old: nil, new: "ipBanned")), "IP ban")
            XCTAssertEqual(HistoryText.change(HistoryEntry(ts: t0, kind: .banLifted, old: "ipBanned", new: "ipOk")),
                           "IP ban → Engel yok")
            XCTAssertEqual(HistoryText.change(HistoryEntry(ts: t0, kind: .refresh, old: "orange", new: "green")),
                           "Dikkat → Tümü tamam")
            XCTAssertEqual(HistoryText.change(HistoryEntry(ts: t0, kind: .fixAttempt, old: "1.1.1.1", new: nil)), "1.1.1.1 → —")
            XCTAssertNil(HistoryText.change(HistoryEntry(ts: t0, kind: .apply)))
            XCTAssertEqual(HistoryText.note(HistoryEntry(ts: t0, kind: .fixAttempt, old: "A", new: "B", note: "resolved")),
                           "Çözüldü: IP değişti (A → B), ban kalktı.")
            XCTAssertEqual(HistoryText.note(HistoryEntry(ts: t0, kind: .fixAttempt, note: "failed")), "Düzeltme başarısız")
            XCTAssertEqual(HistoryText.note(HistoryEntry(ts: t0, kind: .apply, note: "config.cfg")), "config.cfg")
            for code in ["resolved", "stillBanned", "rangeBanned", "ipUnchanged", "changedUnverified", "networkTimeout",
                         "cancelled", "failed"] {
                XCTAssertNotEqual(HistoryText.note(HistoryEntry(ts: t0, kind: .fixAttempt, note: code)), code)
            }
        }
        try inLanguage("en") {
            XCTAssertEqual(HistoryText.kind(.ipChanged), "IP changed")
            XCTAssertEqual(HistoryText.change(HistoryEntry(ts: t0, kind: .refresh, old: nil, new: "red")), "Critical error")
        }
    }
}

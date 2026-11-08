import XCTest
@testable import PlayerIdentity

final class StatusTests: XCTestCase {
    private let serverID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let rawID: UInt64 = 0x0123_4567_89AB_CDEF

    private func identity(rawID: UInt64) -> Identity {
        Identity(source: IdentitySource(location: .homeConfig, url: URL(fileURLWithPath: "/tmp/home/.config/.xash_id")),
                 fileValue: rawID ^ IdentityLocation.homeMask,
                 rawID: rawID)
    }

    private func matchingPair(rawID: UInt64? = nil) -> (CurrentState, Snapshot) {
        let raw = rawID ?? self.rawID
        let cid = CIDCalculator.cid(rawID: raw, host: "95.173.174.175")!
        let server = ServerEntry(id: serverID, label: "Test", host: "95.173.174.175", cid: cid)
        let current = CurrentState(identity: .success(identity(rawID: raw)),
                                   displayName: "Oyuncu",
                                   model: "gordon",
                                   lanIPs: ["en0 · 192.0.2.10", "en0 · 2001:db8::5"],
                                   publicIP: "203.0.113.7",
                                   servers: [server])
        let snapshot = Snapshot(savedAt: Date(timeIntervalSince1970: 0),
                                gamedir: "valve", dataRoot: "/tmp", displayName: "Oyuncu", model: "gordon",
                                rawID: HexID.format(raw), identitySource: "/tmp/home/.config/.xash_id",
                                network: NetworkInfo(publicIP: "203.0.113.7",
                                                     lanIPs: ["en0 · 2001:db8::5", "en0 · 192.0.2.10"],
                                                     checkedAt: nil),
                                servers: [server])
        return (current, snapshot)
    }

    private func codes(_ report: StatusReport) -> Set<MessageCode> { Set(report.reasons.map(\.code)) }

    // MARK: Green

    func testGreenWhenEverythingMatches() {
        let (current, snapshot) = matchingPair()
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .green)
        XCTAssertEqual(report.reasons, [])
        XCTAssertEqual(report.server(serverID)?.level, .green)
        XCTAssertNil(report.server(serverID)?.message)
    }

    // MARK: Orange

    func testOrangeWhenSnapshotMissing() {
        let (current, _) = matchingPair()
        let report = StatusEvaluator.evaluate(current: current, snapshot: .missing)
        XCTAssertEqual(report.overall, .orange)
        XCTAssertTrue(codes(report).contains(.snapshotMissing))
        XCTAssertEqual(report.reasons.first { $0.code == .snapshotMissing }?.message,
                       "Kayıt yok. Doğrulama için Kaydet'e basın.")
        XCTAssertTrue(report.reasons.allSatisfy { $0.severity == .orange })
    }

    func testOrangeWhenRawIDZero() {
        let (current, snapshot) = matchingPair(rawID: 0)
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .orange)
        XCTAssertEqual(codes(report), [.rawIDZero])
    }

    func testOrangeWhenPublicIPNameModelLanChanged() {
        let (initial, snapshot) = matchingPair()
        var current = initial
        current.publicIP = "198.51.100.1"
        current.displayName = "Başka"
        current.model = "barney"
        current.lanIPs = ["en1 · 10.0.0.2"]
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .orange)
        XCTAssertEqual(codes(report), [.publicIPChanged, .nameChanged, .modelChanged, .lanIPChanged])
    }

    func testOrangeWhenNameModelEmptyAndNoLanIP() {
        var (current, snapshot) = matchingPair()
        current.displayName = ""
        current.model = ""
        current.lanIPs = []
        snapshot.displayName = ""
        snapshot.model = ""
        snapshot.network.lanIPs = []
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .orange)
        XCTAssertEqual(codes(report), [.nameEmpty, .modelEmpty, .lanIPMissing])
    }

    func testOrangeWhenServerCIDDiffersOrSavedEmpty() {
        var (current, snapshot) = matchingPair()
        let newServer = ServerEntry(label: "Yeni", host: "51.68.190.91")   // not in the record → saved CID empty
        current.servers.append(newServer)
        snapshot.servers[0].cid = "00000000000000000000000000000000"
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .orange)
        XCTAssertEqual(report.reasons.filter { $0.code == .serverCIDChanged }.count, 1)
        XCTAssertEqual(report.server(serverID)?.level, .orange)
        XCTAssertEqual(report.server(newServer.id)?.level, .orange)
        XCTAssertEqual(report.server(newServer.id)?.currentCID, CIDCalculator.cid(rawID: rawID, host: "51.68.190.91"))
    }

    // MARK: Red

    func testRedWhenIdentityMissing() {
        let (initial, snapshot) = matchingPair()
        var current = initial
        current.identity = .failure(.missing)
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .red)
        XCTAssertEqual(report.reasons.first, StatusReason(severity: .red, code: .identityMissing))
        XCTAssertNil(report.server(serverID)?.currentCID)
    }

    func testRedWhenIdentityInvalid() {
        let (initial, snapshot) = matchingPair()
        var current = initial
        current.identity = .failure(.invalid)
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .red)
        XCTAssertTrue(codes(report).contains(.identityInvalid))
    }

    func testRedWhenPublicIPFailed() {
        let (initial, snapshot) = matchingPair()
        var current = initial
        current.publicIP = nil
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.overall, .red)
        XCTAssertEqual(codes(report), [.publicIPFailed])
        XCTAssertEqual(report.reasons.first?.message, "Genel IP alınamadı. İnternet bağlantısını kontrol edin.")
    }

    func testRedWhenSnapshotCorruptOrUnsupported() {
        let (current, _) = matchingPair()
        for state in [SnapshotLoadResult.corrupt, .unsupportedSchema(99)] {
            let report = StatusEvaluator.evaluate(current: current, snapshot: state)
            XCTAssertEqual(report.overall, .red)
            XCTAssertTrue(codes(report).contains(.snapshotCorrupt))
        }
    }

    // MARK: Per row

    func testInvalidHostRowIsRedButDoesNotAffectOverall() {
        var (current, snapshot) = matchingPair()
        let bad = ServerEntry(label: "Bozuk", host: "999.1.1.1", cid: "")
        current.servers.append(bad)
        snapshot.servers.append(bad)
        let report = StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
        XCTAssertEqual(report.server(bad.id)?.level, .red)
        XCTAssertEqual(report.server(bad.id)?.message, .invalidHost)
        XCTAssertEqual(report.server(serverID)?.level, .green)
        XCTAssertEqual(report.overall, .green)
    }

    func testIPv6ServerRowUsesSameCIDLogic() throws {
        let (initial, _) = matchingPair()
        var current = initial
        let v6 = ServerEntry(label: "V6", host: "2001:db8::1")
        current.servers = [v6]
        let report = StatusEvaluator.evaluate(current: current, snapshot: .missing)
        let row = try XCTUnwrap(report.server(v6.id))
        XCTAssertEqual(row.level, .orange)   // no saved CID
        let cid = try XCTUnwrap(row.currentCID)
        XCTAssertEqual(cid.count, 32)
        XCTAssertTrue(cid.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(cid, CIDCalculator.cid(rawID: rawID, host: "2001:db8::1"))
    }

    // MARK: Ban (§13.3)

    private func reportWithBan(_ status: BanStatus) -> StatusReport {
        var (current, snapshot) = matchingPair()
        current.servers[0].banCheck = BanCheck(status: status, checkedAt: Date(timeIntervalSince1970: 0), detail: "")
        snapshot.servers[0].banCheck = nil   // ban results are not compared against the record
        return StatusEvaluator.evaluate(current: current, snapshot: .loaded(snapshot))
    }

    func testBanResultsTurnOverallRedWithReason() {
        for (status, code, text) in [(BanStatus.ipBanned, MessageCode.ipBanned, "Sunucu bu IP'yi banlamış."),
                                     (.cidBanned, .cidBanned, "Sunucu bu CID'yi banlamış.")] {
            let report = reportWithBan(status)
            XCTAssertEqual(report.overall, .red)
            XCTAssertEqual(report.reasons, [StatusReason(severity: .red, code: code)])
            XCTAssertEqual(report.reasons.first?.message, text)
            XCTAssertEqual(report.server(serverID)?.ban?.status, status)
            XCTAssertEqual(report.server(serverID)?.level, .green)   // CID row status is separate
            XCTAssertEqual(report.server(serverID)?.displayLevel, .red)  // the row icon reflects the ban
            XCTAssertEqual(report.server(serverID)?.displayMessage, code)
        }
    }

    func testUnreachableAndUnknownAreOrange() {
        XCTAssertEqual(reportWithBan(.unreachable).overall, .orange)
        XCTAssertEqual(reportWithBan(.unreachable).server(serverID)?.displayLevel, .orange)
        XCTAssertEqual(reportWithBan(.unreachable).reasons.first?.message, "Sunucuya erişilemedi (yanıt yok).")
        for status in [BanStatus.unknown, .cidUnknown, .ipOk] {
            let report = reportWithBan(status)
            XCTAssertEqual(report.overall, .orange)
            XCTAssertEqual(report.reasons.map(\.code), [.banUnknown])
            XCTAssertEqual(report.reasons.first?.message, "Ban durumu belirlenemedi.")
        }
    }

    func testNoBanIsGreen() {
        for status in [BanStatus.cidOk, .cidNotApplicable] {
            XCTAssertEqual(reportWithBan(status).overall, .green)
            XCTAssertEqual(reportWithBan(status).reasons, [])
            XCTAssertEqual(reportWithBan(status).server(serverID)?.displayLevel, .green)
        }
        XCTAssertEqual(MessageCode.cidNotApplicable.text, "CID kontrolü bu sunucuda uygulanamaz.")
    }

    func testBanLabels() {
        XCTAssertEqual(BanStatus.ipBanned.label, "IP ban")
        XCTAssertEqual(BanStatus.cidBanned.label, "CID ban")
        XCTAssertEqual(BanStatus.cidOk.label, "Engel yok")
        XCTAssertEqual(BanStatus.cidNotApplicable.label, "Engel yok")
        XCTAssertEqual(BanStatus.unreachable.label, "Erişilemiyor")
        XCTAssertEqual(BanStatus.unknown.label, "Belirsiz")
        XCTAssertEqual(BanStatus.cidUnknown.label, "Belirsiz")
    }

    func testStatusPresentation() {
        XCTAssertEqual(StatusLevel.green.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(StatusLevel.orange.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(StatusLevel.red.symbolName, "xmark.octagon.fill")
        XCTAssertEqual(StatusLevel.green.label, "Tümü tamam")
        XCTAssertEqual(StatusLevel.orange.label, "Dikkat")
        XCTAssertEqual(StatusLevel.red.label, "Kritik hata")
    }
}

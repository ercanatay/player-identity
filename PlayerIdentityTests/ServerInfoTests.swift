import XCTest
@testable import PlayerIdentity

/// §21: A2S_INFO parsing (GoldSrc 0x6D, Source 0x49) and reuse of the ban check's step (a) reply.
final class ServerInfoParserTests: XCTestCase {
    func testGoldSrcReply() {
        let info = ServerInfoParser.parse(A2SFixture.goldSrc())
        XCTAssertEqual(info, ServerInfo(name: "POLIGON RPG", map: "rpg_city", players: 9, maxPlayers: 26))
    }

    func testSourceReply() {
        let info = ServerInfoParser.parse(A2SFixture.source())
        XCTAssertEqual(info, ServerInfo(name: "Source Server", map: "de_dust2", players: 12, maxPlayers: 32))
    }

    func testMissingFieldsAreNilWithoutCrash() {
        let full = A2SFixture.goldSrc()
        // Cut right after the map string: folder/game/players/max are missing.
        let mapEnd = full.indices.filter { full[$0] == 0 }[2]
        let truncated = Array(full[...mapEnd])
        XCTAssertEqual(ServerInfoParser.parse(truncated), ServerInfo(name: "POLIGON RPG", map: "rpg_city"))
        // Unterminated name: nothing after it can be read.
        let unterminated = A2SFixture.header + [0x49, 17] + Array("half".utf8)
        XCTAssertEqual(ServerInfoParser.parse(unterminated), ServerInfo())
        // Type byte only.
        XCTAssertEqual(ServerInfoParser.parse(A2SFixture.header + [0x6D]), ServerInfo())
        // Max players missing (reply ends after players).
        let source = A2SFixture.source()
        let playersIndex = source.count - 7
        XCTAssertEqual(ServerInfoParser.parse(Array(source[...playersIndex]))?.players, 12)
        XCTAssertNil(ServerInfoParser.parse(Array(source[...playersIndex]))?.maxPlayers)
        // Empty name/map read as nil.
        let empty = ServerInfoParser.parse(A2SFixture.source(name: [], map: ""))
        XCTAssertNil(empty?.name)
        XCTAssertNil(empty?.map)
        XCTAssertEqual(empty?.players, 12)
    }

    func testNonInfoRepliesAreIgnored() {
        XCTAssertNil(ServerInfoParser.parse(A2SFixture.header + [0x41, 1, 2, 3, 4]))
        XCTAssertNil(ServerInfoParser.parse([0x6D, 0x00]))
        XCTAssertNil(ServerInfoParser.parse([]))
    }

    func testUTF8AndLatin1Names() {
        let utf8 = ServerInfoParser.parse(A2SFixture.goldSrc(name: Array("Türk Sunucu ★".utf8)))
        XCTAssertEqual(utf8?.name, "Türk Sunucu ★")
        // 0xE7 = "ç", 0xFC = "ü" in ISO Latin-1; invalid as UTF-8.
        let latin1 = ServerInfoParser.parse(A2SFixture.goldSrc(name: [0x47, 0xFC, 0x7A, 0x65, 0x6C, 0x20, 0xE7]))
        XCTAssertEqual(latin1?.name, "Güzel ç")
        // Control characters are removed.
        let control = ServerInfoParser.parse(A2SFixture.goldSrc(name: [0x41, 0x01, 0x0A, 0x42]))
        XCTAssertEqual(control?.name, "A B")
    }

    func testOversizedPacket() {
        let hugeName = [UInt8](repeating: 0x41, count: 70_000)
        let info = ServerInfoParser.parse(A2SFixture.source(name: hugeName))
        XCTAssertEqual(info?.name?.count, ServerInfoParser.maxStringLength + 1)   // truncated + "…"
        XCTAssertEqual(info?.map, "de_dust2")
        XCTAssertEqual(info?.players, 12)
        let noTerminator = A2SFixture.header + [0x6D] + [UInt8](repeating: 0x42, count: 100_000)
        XCTAssertEqual(ServerInfoParser.parse(noTerminator), ServerInfo())
    }

    func testCodableRoundtripAndOldRecords() throws {
        let check = BanCheck(status: .ipOk, checkedAt: Date(timeIntervalSince1970: 1_793_000_000), detail: "ipOk",
                             info: ServerInfo(name: "S", map: "m", players: 1, maxPlayers: 2, pingMillis: 3))
        let data = try SnapshotStore.makeEncoder().encode(check)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"max\" : 2"))
        XCTAssertEqual(try SnapshotStore.makeDecoder().decode(BanCheck.self, from: data), check)
        let old = Data(#"{"status":"ipOk","checkedAt":"2026-11-08T12:12:04Z","detail":""}"#.utf8)
        XCTAssertNil(try SnapshotStore.makeDecoder().decode(BanCheck.self, from: old).info)
    }
}

final class BanCheckServerInfoTests: XCTestCase {
    private let endpoint = UDPEndpoint(address: TestAddresses.v4("51.68.190.91"), port: 27015)

    private func request(cid: String? = "d9de0eb4419608a8423241430581e91c") -> BanCheckRequest {
        BanCheckRequest(serverID: UUID(), host: "51.68.190.91", port: 27015, endpoint: endpoint, cid: cid, name: "N")
    }

    private func infoPackets(_ transport: FakeUDPTransport) -> [[UInt8]] {
        transport.sentPackets.filter(FakeServer.isInfo)
    }

    func testInfoAndPingFromStepAWithoutExtraQuery() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.042)))
        let checker = BanChecker(transport: transport, now: { clock.now })
        let result = try await checker.check(request())
        XCTAssertEqual(result.status, .cidOk)
        XCTAssertEqual(result.info, ServerInfo(name: "POLIGON RPG", map: "rpg_city", players: 9, maxPlayers: 26, pingMillis: 42))
        XCTAssertEqual(infoPackets(transport).count, 1)
        XCTAssertEqual(transport.sentCount, 3)   // info, getchallenge, connect — unchanged
    }

    func testChallengeFlowIsKeptAndInfoComesFromSecondReply() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock) { endpoint, packet in
            if FakeServer.isInfo(packet) {
                let challenged = packet.count > 25
                return [challenged ? FakeReply(bytes: A2SFixture.source(), delay: 0.02)
                                   : FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes), delay: 0.5)]
            }
            return FakeServer.scripted()(endpoint, packet)
        }
        let checker = BanChecker(transport: transport, now: { clock.now })
        let result = try await checker.check(request())
        XCTAssertEqual(result.info?.map, "de_dust2")
        XCTAssertEqual(result.info?.pingMillis, 20)   // RTT of the challenged request
        let infos = infoPackets(transport)
        XCTAssertEqual(infos.count, 2)
        XCTAssertEqual(Array(infos[1].suffix(4)), FakeServer.challengeBytes)
    }

    func testNoInfoWhenChallengedQueryIsUnanswered() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock) { endpoint, packet in
            if FakeServer.isInfo(packet) {
                return packet.count > 25 ? [] : [FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes))]
            }
            return FakeServer.scripted()(endpoint, packet)
        }
        let result = try await BanChecker(transport: transport, now: { clock.now }).check(request())
        XCTAssertNil(result.info)
        XCTAssertEqual(result.status, .cidOk)
    }

    func testUnreachableHasNoInfoAndMinimalReplyHasPingOnly() async throws {
        let clock = TestClock()
        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil))
        let unreachable = try await BanChecker(transport: silent, now: { clock.now }).check(request())
        XCTAssertEqual(unreachable.status, .unreachable)
        XCTAssertNil(unreachable.info)

        let minimal = try await BanChecker(transport: FakeServer.healthy(clock: clock), now: { clock.now }).check(request())
        XCTAssertEqual(minimal.info, ServerInfo(pingMillis: 0))
    }
}

import XCTest
@testable import OyuncuKimlik

/// §13.6/1: sahte UDP taşıyıcısıyla ban kontrolü senaryoları (ağa çıkmaz).
final class BanCheckTests: XCTestCase {
    private let cid = "d9de0eb4419608a8423241430581e91c"

    private func request(cid: String? = "d9de0eb4419608a8423241430581e91c", name: String = "Oyuncu") -> BanCheckRequest {
        BanCheckRequest(serverID: UUID(), host: "51.68.190.91", port: 27015,
                        endpoint: UDPEndpoint(address: ServerAddress.parse("51.68.190.91")!, port: 27015),
                        cid: cid, name: name)
    }

    private func checker(_ transport: FakeUDPTransport, clock: TestClock) -> BanChecker {
        BanChecker(transport: transport, now: { clock.now }, qport: { 777 })
    }

    // 1. info → challenge → ipOk
    func testInfoThenChallengeIsIPOk() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock) { _, packet in
            if FakeServer.isInfo(packet) {
                // İlk sorguya A2S challenge, challenge'lı tekrar sorguya GoldSrc info.
                return packet.count == BanPackets.info().count
                    ? [FakeReply(bytes: FakeServer.oob(0x41, [1, 2, 3, 4]))]
                    : [FakeReply(bytes: FakeServer.oob(0x6D, [0x30]))]
            }
            if FakeServer.isGetChallenge(packet) { return [FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes))] }
            return []
        }
        let result = try await checker(transport, clock: clock).check(request(cid: nil))
        XCTAssertEqual(result.status, .ipOk)
        XCTAssertEqual(transport.sentPackets, [
            BanPackets.info(),
            BanPackets.info(challenge: [1, 2, 3, 4]),
            BanPackets.getChallenge(),
        ])
        XCTAssertEqual(BanPackets.info(), [0xFF, 0xFF, 0xFF, 0xFF] + Array("TSource Engine Query".utf8) + [0])
        XCTAssertEqual(BanPackets.getChallenge(), [0xFF, 0xFF, 0xFF, 0xFF] + Array("getchallenge\n".utf8))
    }

    // 2. ban metni → ipBanned
    func testBanTextIsIPBanned() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oobText("lYou have been BANNED from this server.\n"))))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .ipBanned)
        XCTAssertTrue(result.detail.contains("BANNED"))
        XCTAssertEqual(transport.sentCount, 2)   // connect gönderilmez
        XCTAssertEqual(result.status.label, "IP ban")
        XCTAssertEqual(result.status.level, .red)
    }

    // 3. client_connect → cidOk (hemen dur)
    func testClientConnectIsCIDOkAndStops() async throws {
        let clock = TestClock()
        let transport = FakeServer.healthy(clock: clock)
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .cidOk)
        XCTAssertEqual(result.status.label, "Engel yok")
        XCTAssertEqual(transport.sentCount, 3)
        let connect = String(decoding: transport.sentPackets[2].dropFirst(4), as: UTF8.self)
        XCTAssertEqual(connect,
                       "connect 49 305419896 \"prot=cidtest; uuid=\(cid); qport=777; ext=0; d=1\" \"name=Oyuncu\"\n")
        XCTAssertEqual(Array(transport.sentPackets[2].prefix(4)), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testTextClientConnectIsCIDOk() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            connect: FakeReply(bytes: FakeServer.oobText("client_connect"))))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .cidOk)
    }

    // 4. errormsg + ban → cidBanned
    func testErrormsgWithBanIsCIDBanned() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            connect: FakeReply(bytes: FakeServer.oobText("errormsg\nYou are banned (CID)\n"))))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .cidBanned)
        XCTAssertEqual(result.status.label, "CID ban")
        XCTAssertEqual(result.detail, "ipOk → cidBanned: errormsg You are banned (CID)")
    }

    func testDisconnectAnd0x39WithBanAreCIDBanned() {
        XCTAssertEqual(BanReplies.classifyConnect(FakeServer.oobText("disconnect\nbanned\n")),
                       .banned("disconnect\nbanned\n"))
        XCTAssertEqual(BanReplies.classifyConnect(FakeServer.oob(0x39, Array("Ban by admin".utf8))),
                       .banned("9Ban by admin"))
    }

    // 5. unsupported protocol → cidNotApplicable
    func testUnsupportedProtocolIsCIDNotApplicable() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            connect: FakeReply(bytes: FakeServer.oobText("errormsg\nUnsupported protocol 49\n"))))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .cidNotApplicable)
        XCTAssertEqual(result.status.label, "Engel yok")
        XCTAssertEqual(result.status.level, .green)
        XCTAssertEqual(BanReplies.classifyConnect(FakeServer.oobText("lWrong protocol version")),
                       .notApplicable("lWrong protocol version"))
    }

    // 6. sessizlik → unreachable
    func testSilenceIsUnreachable() async throws {
        let clock = TestClock()
        let start = clock.now
        let transport = FakeUDPTransport(clock: clock) { _, _ in [] }
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .unreachable)
        XCTAssertEqual(result.status.label, "Erişilemiyor")
        XCTAssertEqual(transport.sentCount, 1)          // diğer adımlar atlanır, yeniden deneme yok
        XCTAssertEqual(clock.now.timeIntervalSince(start), 4, accuracy: 0.001)
    }

    // MARK: Ek kurallar

    func testGetChallengeSilenceIsUnknownWithoutRetry() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(challenge: nil))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.status.label, "Belirsiz")
        XCTAssertEqual(transport.sentPackets.filter(FakeServer.isGetChallenge).count, 1)
    }

    func testUnrecognizedChallengeReplyIsUnknown() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oobText("lServer is full"))))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .unknown)
    }

    func testConnectSilenceIsCIDUnknown() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(connect: nil))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .cidUnknown)
        XCTAssertEqual(transport.sentCount, 3)
    }

    func testStepTimeoutsStayWithinTotalBudget() async throws {
        let clock = TestClock()
        let start = clock.now
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: FakeServer.oob(0x49), delay: 3.99),
            challenge: FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes), delay: 3.99),
            connect: nil))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .cidUnknown)
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(start), BanChecker.totalTimeout)
    }

    func testLateReplyBeyondStepTimeoutIsIgnored() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: FakeServer.oob(0x49), delay: 4.5)))
        let result = try await checker(transport, clock: clock).check(request())
        XCTAssertEqual(result.status, .unreachable)
    }

    func testChallengeIsLittleEndian() {
        XCTAssertEqual(BanReplies.classifyGetChallenge(FakeServer.oob(0x41, [0x78, 0x56, 0x34, 0x12])),
                       .challenge(0x1234_5678))
        // Yüksek bit set: işaretli 32 bit ondalık olarak yazılır.
        let packet = BanPackets.connect(challenge: 0xFFFF_FFFF, cid: "x", qport: 1, name: "n")
        XCTAssertTrue(String(decoding: packet.dropFirst(4), as: UTF8.self).hasPrefix("connect 49 -1 "))
    }

    func testCancellationStopsCheck() async {
        // Sessizlikte gerçekten bekleyen oturum: iptal, görev hangi anda başlarsa başlasın yakalanır.
        let transport = FakeUDPTransport(waitsOnSilence: true) { _, _ in [] }
        let checker = BanChecker(transport: transport, now: { Date() }, qport: { 1 })
        let req = request()
        let task = Task { try await checker.check(req) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("iptal bekleniyordu")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: 10 sn kısıtı (§13.6/5)

    func testSchedulerEnforcesTenSecondsPerServer() async {
        let scheduler = BanCheckScheduler()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = await scheduler.reserve("a", now: t0)
        let again = await scheduler.reserve("a", now: t0.addingTimeInterval(9.9))
        let other = await scheduler.reserve("b", now: t0.addingTimeInterval(1))
        let later = await scheduler.reserve("a", now: t0.addingTimeInterval(10))
        XCTAssertTrue(first)
        XCTAssertFalse(again)
        XCTAssertTrue(other)
        XCTAssertTrue(later)
    }

    func testRequestsSkipInvalidHosts() {
        let servers = [ServerEntry(label: "ok", host: "5.161.189.195"),
                       ServerEntry(label: "domain", host: "example.com"),
                       ServerEntry(label: "port", host: "1.2.3.4", port: 0),
                       ServerEntry(label: "v6", host: "2001:db8::1")]
        let requests = BanCheckRunner.requests(servers: servers, rawID: 0, name: "N")
        XCTAssertEqual(requests.map(\.host), ["5.161.189.195", "2001:db8::1"])
        XCTAssertEqual(requests.first?.cid, "5282a6daf7a33fe08469e453086de93c")
        XCTAssertNil(BanCheckRunner.requests(servers: servers, rawID: nil, name: "N").first?.cid)
    }
}

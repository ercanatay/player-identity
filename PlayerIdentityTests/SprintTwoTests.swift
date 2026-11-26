import AppKit
import XCTest
@testable import PlayerIdentity

// MARK: - Fixtures and fakes

/// A2S_PLAYER / A2S_RULES replies (§68.1).
enum A2SQueryFixture {
    static let header: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
    static let challenge: [UInt8] = [0x11, 0x22, 0x33, 0x44]

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }

    static func challengeReply(_ bytes: [UInt8] = challenge) -> [UInt8] { header + [0x41] + bytes }

    static func players(_ players: [(name: String, score: Int32, seconds: Float)], count: UInt8? = nil) -> [UInt8] {
        var bytes: [UInt8] = header + [0x44, count ?? UInt8(players.count)]
        for (offset, player) in players.enumerated() {
            bytes += [UInt8(offset)] + Array(player.name.utf8) + [0]
            bytes += le32(UInt32(bitPattern: player.score)) + le32(player.seconds.bitPattern)
        }
        return bytes
    }

    static func rules(_ rules: [(String, String)], count: UInt16? = nil) -> [UInt8] {
        let total = count ?? UInt16(rules.count)
        var bytes: [UInt8] = header + [0x45, UInt8(total & 0xFF), UInt8(total >> 8)]
        for (name, value) in rules { bytes += Array(name.utf8) + [0] + Array(value.utf8) + [0] }
        return bytes
    }

    static func isChallengeRequest(_ packet: [UInt8]) -> Bool { packet == header + [0x57] }
    static func isPlayers(_ packet: [UInt8]) -> Bool { packet.count == 9 && packet.starts(with: header + [0x55]) }
    static func isRules(_ packet: [UInt8]) -> Bool { packet.count == 9 && packet.starts(with: header + [0x56]) }

    /// Healthy diagnosis server that also answers `W` / `U` / `V`; `challengeAfter` = `W` requests left unanswered.
    static func server(players: [UInt8]? = nil, rules: [UInt8]? = nil, challengeAfter: Int = 0,
                       connect: FakeReply? = FakeReply(bytes: FakeServer.oob(0x42))) -> FakeUDPTransport.Responder {
        let counter = RequestCounter()
        let base = FakeServer.scripted(connect: connect)
        return { endpoint, packet in
            if isChallengeRequest(packet) {
                return counter.next() < challengeAfter ? [] : [FakeReply(bytes: challengeReply())]
            }
            if isPlayers(packet) { return players.map { [FakeReply(bytes: $0)] } ?? [] }
            if isRules(packet) { return rules.map { [FakeReply(bytes: $0)] } ?? [] }
            return base(endpoint, packet)
        }
    }
}

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

/// Transport whose sockets cannot be opened ("no network").
private struct OfflineTransport: UDPTransport {
    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession { throw UDPSocketError.system(51) }
}

/// Scripted ban record endpoint: records the URL and token of every request.
final class FakeBanRecordHTTP: BanRecordHTTP, @unchecked Sendable {
    enum Reply {
        case body(String, status: Int)
        case error(any Error)
    }

    private let lock = NSLock()
    private var recorded: [(URL, String?, TimeInterval)] = []
    let reply: Reply

    init(_ reply: Reply) { self.reply = reply }

    var requests: [(url: URL, token: String?, timeout: TimeInterval)] { lock.withLock { recorded.map { ($0.0, $0.1, $0.2) } } }

    func get(_ url: URL, bearerToken: String?, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        lock.withLock { recorded.append((url, bearerToken, timeout)) }
        switch reply {
        case .body(let text, let status): return (Data(text.utf8), status)
        case .error(let error): throw error
        }
    }
}

/// Keychain stand-in that records writes; `failing` makes every call throw.
final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var writes: [(String, String?)] = []
    let failing: Bool

    init(failing: Bool = false, values: [String: String] = [:]) {
        self.failing = failing
        self.values = values
    }

    func secret(for account: String) throws -> String? {
        if failing { throw Failure() }
        return lock.withLock { values[account] }
    }

    func setSecret(_ value: String?, for account: String) throws {
        if failing { throw Failure() }
        lock.withLock {
            writes.append((account, value))
            values[account] = (value?.isEmpty ?? true) ? nil : value
        }
    }
}

private func english<T>(_ body: () throws -> T) throws -> T {
    try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en")), operation: body)
}

// MARK: - §68.1 A2S_PLAYER / A2S_RULES

final class ServerQueryTests: XCTestCase {
    private let endpoint = UDPEndpoint(address: .ipv4([198, 51, 100, 20]), port: 27015)

    private func querier(_ transport: FakeUDPTransport, clock: TestClock) -> ServerQuerier {
        ServerQuerier(transport: transport, now: { clock.now })
    }

    func testChallengeThenPlayersAreParsed() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: A2SQueryFixture.server(
            players: A2SQueryFixture.players([("Gordon", 12, 754.5), ("Alyx", -3, 61)])))
        let session = try transport.makeSession(to: endpoint)
        let result = try await querier(transport, clock: clock).players(session, until: clock.now.addingTimeInterval(10))
        let players = try result.get()
        XCTAssertFalse(players.truncated)
        XCTAssertEqual(players.players, [ServerPlayer(index: 0, name: "Gordon", score: 12, durationSec: 754.5),
                                         ServerPlayer(index: 1, name: "Alyx", score: -3, durationSec: 61)])
        XCTAssertEqual(transport.sentPackets, [A2SQueryFixture.header + [0x57],
                                               A2SQueryFixture.header + [0x55] + A2SQueryFixture.challenge])
    }

    func testMissingChallengeIsRetriedOnceThenGivesUp() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: A2SQueryFixture.server(
            players: A2SQueryFixture.players([]), challengeAfter: 99))
        let session = try transport.makeSession(to: endpoint)
        let result = try await querier(transport, clock: clock).players(session, until: clock.now.addingTimeInterval(10))
        XCTAssertEqual(result, .failure(.noChallenge))
        XCTAssertEqual(transport.sentPackets.filter(A2SQueryFixture.isChallengeRequest).count, 2, "one retry only")
        XCTAssertFalse(transport.sentPackets.contains(where: A2SQueryFixture.isPlayers))
    }

    func testChallengeRetrySucceeds() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: A2SQueryFixture.server(
            rules: A2SQueryFixture.rules([("sv_cheats", "0")]), challengeAfter: 1))
        let session = try transport.makeSession(to: endpoint)
        let result = try await querier(transport, clock: clock).rules(session, until: clock.now.addingTimeInterval(10))
        XCTAssertEqual(try result.get().rules, [ServerRule(name: "sv_cheats", value: "0")])
        XCTAssertEqual(transport.sentCount, 3)
    }

    func testFreshChallengeReplyResendsTheQueryOnce() async throws {
        let clock = TestClock()
        let fresh: [UInt8] = [9, 8, 7, 6]
        let transport = FakeUDPTransport(clock: clock) { _, packet in
            if A2SQueryFixture.isChallengeRequest(packet) { return [FakeReply(bytes: A2SQueryFixture.challengeReply())] }
            if packet == A2SQueryFixture.header + [0x55] + A2SQueryFixture.challenge {
                return [FakeReply(bytes: A2SQueryFixture.challengeReply(fresh))]
            }
            if packet == A2SQueryFixture.header + [0x55] + fresh { return [FakeReply(bytes: A2SQueryFixture.players([("P", 1, 1)]))] }
            return []
        }
        let session = try transport.makeSession(to: endpoint)
        let result = try await querier(transport, clock: clock).players(session, until: clock.now.addingTimeInterval(10))
        XCTAssertEqual(try result.get().players.map(\.name), ["P"])
    }

    func testSilentServerIsNoReply() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: A2SQueryFixture.server())
        let session = try transport.makeSession(to: endpoint)
        let result = try await querier(transport, clock: clock).rules(session, until: clock.now.addingTimeInterval(10))
        XCTAssertEqual(result, .failure(.noReply))
    }

    func testZeroPlayersAndEmptyRules() throws {
        let players = try XCTUnwrap(ServerQueryParser.parsePlayers(A2SQueryFixture.players([])))
        XCTAssertEqual(players, ServerPlayersResult(players: [], truncated: false))
        let rules = try XCTUnwrap(ServerQueryParser.parseRules(A2SQueryFixture.rules([])))
        XCTAssertEqual(rules, ServerRulesResult(rules: [], truncated: false))
        XCTAssertNil(rules.passwordProtected)
    }

    func testBrokenAndMissingRepliesNeverTrap() throws {
        // Wrong type / not out-of-band: not a reply of this query.
        XCTAssertNil(ServerQueryParser.parsePlayers(A2SQueryFixture.rules([("a", "b")])))
        XCTAssertNil(ServerQueryParser.parseRules([0x01, 0x02]))
        XCTAssertNil(ServerQueryParser.parseRules([]))
        // Header only: no count.
        XCTAssertEqual(ServerQueryParser.parsePlayers(A2SQueryFixture.header + [0x44]), ServerPlayersResult(players: [], truncated: true))
        // Announces 3 players, carries 1 and a half.
        var short = A2SQueryFixture.players([("One", 5, 10), ("Two", 1, 1)], count: 3)
        short.removeLast(3)
        let partial = try XCTUnwrap(ServerQueryParser.parsePlayers(short))
        XCTAssertEqual(partial.players.map(\.name), ["One"])
        XCTAssertTrue(partial.truncated)
        // Rule without a terminating NUL.
        var rules = A2SQueryFixture.rules([("sv_lan", "0"), ("mp_timelimit", "30")])
        rules.removeLast()
        let cut = try XCTUnwrap(ServerQueryParser.parseRules(rules))
        XCTAssertEqual(cut.rules, [ServerRule(name: "sv_lan", value: "0")])
        XCTAssertTrue(cut.truncated)
        // Non-finite duration becomes 0.
        let nan = A2SQueryFixture.header + [0x44, 1, 0] + Array("N".utf8) + [0] + A2SQueryFixture.le32(1)
            + A2SQueryFixture.le32(Float.nan.bitPattern)
        XCTAssertEqual(ServerQueryParser.parsePlayers(nan)?.players.first?.durationSec, 0)
    }

    func testTwoHundredRules() throws {
        let list = (0..<200).map { ("cvar_\($0)", "\($0)") }
        let rules = try XCTUnwrap(ServerQueryParser.parseRules(A2SQueryFixture.rules(list)))
        XCTAssertEqual(rules.rules.count, 200)
        XCTAssertFalse(rules.truncated)
        XCTAssertEqual(rules.rules.last, ServerRule(name: "cvar_199", value: "199"))
    }

    func testRepliesOver4096BytesAreCutAndMarked() throws {
        let list = (0..<400).map { ("long_cvar_name_\($0)", String(repeating: "x", count: 20)) }
        let reply = A2SQueryFixture.rules(list)
        XCTAssertGreaterThan(reply.count, ServerQueryParser.maxReplyBytes)
        let rules = try XCTUnwrap(ServerQueryParser.parseRules(reply))
        XCTAssertTrue(rules.truncated)
        XCTAssertLessThan(rules.rules.count, 400)
        XCTAssertGreaterThan(rules.rules.count, 50)
        // A GoldSrc split reply keeps its first packet only.
        let split = ServerQueryParser.splitHeader + [1, 0, 0, 0, 0x02] + A2SQueryFixture.rules([("sv_lan", "1")], count: 5)
        let first = try XCTUnwrap(ServerQueryParser.parseRules(split))
        XCTAssertEqual(first.rules.map(\.name), ["sv_lan"])
        XCTAssertTrue(first.truncated)
    }

    func testPasswordAndHighlights() throws {
        func rules(_ pairs: [(String, String)]) -> ServerRulesResult { ServerRulesResult(rules: pairs.map { ServerRule(name: $0.0, value: $0.1) }, truncated: false) }
        XCTAssertEqual(rules([("sv_password", "1")]).passwordProtected, true)
        XCTAssertEqual(rules([("SV_PASSWORD", "secret")]).passwordProtected, true)
        XCTAssertEqual(rules([("sv_password", "0")]).passwordProtected, false)
        XCTAssertEqual(rules([("sv_password", "")]).passwordProtected, false)
        XCTAssertNil(rules([("sv_cheats", "0")]).passwordProtected)
        let all = rules([("mp_friendlyfire", "1"), ("zzz", "1"), ("sv_cheats", "0"), ("sv_maxplayers", "32"), ("sv_password", "0")])
        XCTAssertEqual(all.highlights.map(\.name), ["sv_password", "sv_cheats", "mp_friendlyfire", "sv_maxplayers"])
    }

    // MARK: diagnosis

    private func diagnose(_ responder: @escaping FakeUDPTransport.Responder, queryRules: Bool = true)
        async throws -> (ConnectionProbeResult, FakeUDPTransport) {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: responder)
        let request = ConnectionDiagnosisRequest(host: "198.51.100.20", port: 27015, rawID: 0x1033_1C2D_CE4C_91DB,
                                                 name: "Tester", checksEnabled: true, vpnActive: false, knownRange: nil,
                                                 queryRules: queryRules)
        let diagnoser = ConnectionDiagnoser(transport: transport, resolver: FakeAddressResolver(), now: { clock.now },
                                            qport: { 27005 })
        return (try await diagnoser.run(request), transport)
    }

    func testDiagnosisPasswordVerdictWithRulesStepOK() async throws {
        let (result, _) = try await diagnose(A2SQueryFixture.server(rules: A2SQueryFixture.rules([("sv_password", "1")])))
        XCTAssertEqual(result.verdict, .passwordProtected)
        XCTAssertEqual(result.steps.map(\.step), DiagnosisStepKind.probeSteps + [.rules])
        XCTAssertEqual(result.steps.last?.status, .ok)
        XCTAssertTrue(result.steps.last?.detail.contains("password=1") ?? false)
        XCTAssertEqual(result.rules?.passwordProtected, true)
    }

    func testDiagnosisBanKeepsPriorityOverPassword() async throws {
        let (result, _) = try await diagnose(A2SQueryFixture.server(
            rules: A2SQueryFixture.rules([("sv_password", "1")]),
            connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned (CID)"))))
        XCTAssertEqual(result.verdict, .cidBanned)
        XCTAssertEqual(result.facts.passwordProtected, true)
    }

    func testDiagnosisWithoutPasswordOrRulesKeepsTheProbeVerdict() async throws {
        let (open, _) = try await diagnose(A2SQueryFixture.server(rules: A2SQueryFixture.rules([("sv_password", "0")])))
        XCTAssertEqual(open.verdict, .noBan)
        let (silent, _) = try await diagnose(A2SQueryFixture.server())
        XCTAssertEqual(silent.verdict, .noBan)
        XCTAssertEqual(silent.steps.last?.step, .rules)
        XCTAssertEqual(silent.steps.last?.status, .failed)
        // Off (menu bar, CLI, Shortcuts): no extra packet, no rules step.
        let (plain, transport) = try await diagnose(A2SQueryFixture.server(rules: A2SQueryFixture.rules([("sv_password", "1")])),
                                                    queryRules: false)
        XCTAssertEqual(plain.verdict, .noBan)
        XCTAssertEqual(plain.steps.map(\.step), DiagnosisStepKind.probeSteps)
        XCTAssertEqual(transport.sentCount, 4)   // §75.3 capability probe + real CID
    }

    func testClassifierPasswordOverridesOnlyNonBanVerdicts() {
        var facts = DiagnosisFacts(dns: .resolved, info: .replied, challenge: .challenge, connect: .unrecognized)
        facts.passwordProtected = true
        XCTAssertEqual(DiagnosisClassifier.verdict(facts), .passwordProtected)
        facts.connect = .banned
        XCTAssertEqual(DiagnosisClassifier.verdict(facts), .cidBanned)
        facts.dns = .failed
        XCTAssertEqual(DiagnosisClassifier.verdict(facts), .dnsFailure)
        facts = DiagnosisFacts(dns: .resolved, info: .replied, challenge: .challenge, connect: .ok)
        facts.passwordProtected = false
        XCTAssertEqual(DiagnosisClassifier.verdict(facts), .noBan)
    }

    func testPasswordVerdictTextsAndReportNote() throws {
        try english {
            XCTAssertEqual(DiagnosisVerdict.passwordProtected.advice, "Ask the server owner for the password.")
            XCTAssertEqual(DiagnosisVerdict.passwordProtected.shortLabel, "Password")
            XCTAssertEqual(DiagnosisStepKind.rules.title, "A2S_RULES (server rules)")
        }
        var facts = DiagnosisFacts(dns: .resolved, info: .replied, challenge: .banned)
        facts.passwordProtected = true
        let probe = ConnectionProbeResult(steps: [], facts: facts, verdict: .ipBanned)
        let diagnosis = ConnectionDiagnosis(label: "S", host: "198.51.100.20", port: 27015, startedAt: Date(), probe: probe,
                                            engineLog: .missing)
        let report = try english { DiagnosisReport.markdown(diagnosis, appVersion: "2.18.0") }
        XCTAssertTrue(report.contains("The server is password protected (sv_password)"), report)
    }

    // MARK: UI model

    func testViewModelShowsFirstFiftyRulesSearchAndHighlights() throws {
        let list = [("sv_password", "1"), ("sv_cheats", "0")] + (0..<120).map { ("cvar_\($0)", "v\($0)") }
        let snapshot = ServerDetailsSnapshot(
            players: .success(ServerPlayersResult(players: [ServerPlayer(index: 0, name: "Gordon", score: 7, durationSec: 3725)],
                                                  truncated: false)),
            rules: .success(ServerRulesResult(rules: list.map { ServerRule(name: $0.0, value: $0.1) }, truncated: false)), at: Date())
        try english {
            let view = ServerDetailsViewModel(snapshot: snapshot)
            XCTAssertEqual(view.rules.count, ServerDetailsViewModel.ruleLimit)
            XCTAssertEqual(view.moreRules, "Showing 50 of 122 rules; search to find the rest.")
            XCTAssertEqual(view.highlights.map(\.name), ["sv_password", "sv_cheats"])
            XCTAssertEqual(view.password, "Password protected")
            XCTAssertEqual(view.passwordProtected, true)
            XCTAssertEqual(view.playersTitle, "Players (1)")
            XCTAssertEqual(view.playerRows, [.init(id: 0, name: "Gordon", score: "7", time: "1:02:05")])
            XCTAssertEqual(view.rulesTitle, "Rules (122)")
            XCTAssertFalse(view.truncated)

            let searched = ServerDetailsViewModel(snapshot: snapshot, search: "CVAR_11")
            XCTAssertEqual(searched.rules.map(\.name), ["cvar_11"] + (110...119).map { "cvar_\($0)" })
            XCTAssertNil(searched.moreRules)
            let none = ServerDetailsViewModel(snapshot: snapshot, search: "nothing")
            XCTAssertEqual(none.rulesMessage, "No rule matches “nothing”.")
        }
    }

    func testViewModelEmptyErrorAndTruncatedStates() throws {
        try english {
            let empty = ServerDetailsViewModel(snapshot: ServerDetailsSnapshot(
                players: .success(ServerPlayersResult(players: [], truncated: false)),
                rules: .success(ServerRulesResult(rules: [], truncated: true)), at: Date()))
            XCTAssertEqual(empty.playersMessage, "No players on the server.")
            XCTAssertEqual(empty.rulesMessage, "The server reported no rules.")
            XCTAssertTrue(empty.truncated)
            XCTAssertNil(empty.password)

            let failed = ServerDetailsViewModel(snapshot: ServerDetailsSnapshot(players: .failure(.noChallenge),
                                                                               rules: .failure(.malformed), at: Date()))
            XCTAssertEqual(failed.playersMessage, "The server did not answer the challenge request (W).")
            XCTAssertEqual(failed.rulesMessage, "The server sent an unreadable reply.")
            XCTAssertEqual(failed.playersTitle, "Players (—)")
            XCTAssertEqual(ServerDetailsViewModel.text(.noReply), "The server did not answer.")
            XCTAssertEqual(ServerDetailsViewModel.text(.unreachable), "The server address can't be used; check the address and the network.")
        }
        XCTAssertEqual(ServerDetailsViewModel.duration(59.9), "0:59")
        XCTAssertEqual(ServerDetailsViewModel.duration(754.5), "12:34")
    }

    // MARK: App model

    @MainActor
    func testModelQueriesOnlyOnRequest() async throws {
        let env = try TestAppEnvironment()
        let udp = FakeUDPTransport(clock: env.clock, responder: A2SQueryFixture.server(
            players: A2SQueryFixture.players([("Gordon", 3, 90)]), rules: A2SQueryFixture.rules([("sv_password", "1")])))
        let model = env.makeModel(udp: udp)
        model.addServer(ServerDraft(label: "A", host: "198.51.100.20"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        let before = udp.sentPackets
        XCTAssertFalse(before.contains { A2SQueryFixture.isPlayers($0) || A2SQueryFixture.isRules($0) }, "never automatic")
        XCTAssertNil(model.serverDetailsState(for: id))
        let task = model.refreshServerDetails(for: id)
        XCTAssertEqual(model.serverDetailsState(for: id)?.isLoading, true)
        XCTAssertNil(model.refreshServerDetails(for: id), "no second query while one runs")
        await task?.value
        let snapshot = try XCTUnwrap(model.serverDetailsState(for: id)?.snapshot)
        XCTAssertEqual(try snapshot.players.get().players.map(\.name), ["Gordon"])
        XCTAssertEqual(try snapshot.rules.get().passwordProtected, true)
        XCTAssertEqual(model.serverDetailsState(for: id)?.isLoading, false)
        XCTAssertEqual(udp.sentPackets.count - before.count, 4)   // W, U, W, V
    }

    @MainActor
    func testModelWithoutNetworkOrAddressShowsUnreachable() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel { deps in deps.udpTransport = OfflineTransport() }
        model.addServer(ServerDraft(label: "A", host: "198.51.100.20"))
        model.addServer(ServerDraft(label: "B", host: "unresolved.example"))
        let ids = model.servers.map(\.id)
        for id in ids {
            await model.refreshServerDetails(for: id)?.value
            let snapshot = try XCTUnwrap(model.serverDetailsState(for: id)?.snapshot)
            XCTAssertEqual(snapshot.players, .failure(.unreachable))
            XCTAssertEqual(snapshot.rules, .failure(.unreachable))
        }
    }

    @MainActor
    func testDetailsDiagnosisRunsRulesOnceAndShowsPasswordVerdict() async throws {
        let env = try TestAppEnvironment()
        let udp = FakeUDPTransport(clock: env.clock, responder: A2SQueryFixture.server(rules: A2SQueryFixture.rules([("sv_password", "1")])))
        let model = env.makeModel(udp: udp)
        model.addServer(ServerDraft(label: "A", host: "198.51.100.20"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.startDiagnosis(for: id)?.value
        let session = try XCTUnwrap(model.diagnosis(for: id))
        XCTAssertEqual(session.result?.verdict, .passwordProtected)
        XCTAssertEqual(ConnectionDiagnosisSection.visibleSteps(session), DiagnosisStepKind.probeSteps + [.rules])
        XCTAssertEqual(udp.sentPackets.filter(A2SQueryFixture.isRules).count, 1)
        XCTAssertFalse(udp.sentPackets.contains(where: A2SQueryFixture.isPlayers))
    }
}

// MARK: - §68.2 Ban record

final class BanRecordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func parse(_ json: String) throws -> BanRecordResult {
        try XCTUnwrap(BanRecordParser.parse(Data(json.utf8), now: now))
    }

    func testFieldNameVariants() throws {
        let result = try parse("""
        [{"reason":"Aimbot","admin":"Ercan","created":"2026-11-01T10:00:00Z","expires":"2026-12-01T10:00:00Z","ip":"203.0.113.7","steamId":"STEAM_0:1:1"},
         {"Reason":"Spam","adminName":"Mod","createdAt":1793000000000,"expiresAt":0,"playerIp":"1.2.3.4","playerId":"p"},
         {"reason":"Old","added":"2025-01-01 12:00:00","ends":"2025-02-01 12:00:00","permanent":false,"cid":"abc"},
         {"reason":"Forever","created":"1700000000","permanent":"true"}]
        """)
        XCTAssertEqual(result.entries.count, 4)
        let byReason = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.reason ?? "", $0) })
        let aimbot = try XCTUnwrap(byReason["Aimbot"])
        XCTAssertEqual(aimbot.admin, "Ercan")
        XCTAssertEqual(aimbot.playerIP, "203.0.113.7")
        XCTAssertEqual(aimbot.playerID, "STEAM_0:1:1")
        XCTAssertFalse(aimbot.permanent)
        let spam = try XCTUnwrap(byReason["Spam"])
        XCTAssertEqual(spam.admin, "Mod")
        XCTAssertEqual(spam.created, Date(timeIntervalSince1970: 1_793_000_000), "milliseconds")
        XCTAssertNil(spam.expires)
        XCTAssertTrue(spam.permanent, "expires 0 = never ends")
        XCTAssertEqual(spam.playerIP, "1.2.3.4")
        XCTAssertEqual(spam.playerID, "p")
        let old = try XCTUnwrap(byReason["Old"])
        XCTAssertEqual(old.playerID, "abc")
        XCTAssertNotNil(old.created)
        XCTAssertFalse(old.isActive(now: now))
        XCTAssertTrue(try XCTUnwrap(byReason["Forever"]).permanent)
    }

    func testArrayRoots() throws {
        let item = #"{"reason":"R","permanent":true}"#
        for json in ["[\(item)]", #"{"bans":[\#(item)]}"#, #"{"data":[\#(item)]}"#, #"{"results":[\#(item)]}"#,
                     #"{"data":{"bans":[\#(item)]}}"#] {
            XCTAssertEqual(try parse(json).entries.map(\.reason), ["R"], json)
        }
        XCTAssertEqual(try parse(#"{"bans":[]}"#).activeCount, 0)
        XCTAssertNil(BanRecordParser.parse(Data(#"{"total":1}"#.utf8), now: now))
        XCTAssertNil(BanRecordParser.parse(Data("<html>".utf8), now: now))
    }

    func testDurationsActiveCountAndNewestFirst() throws {
        let result = try parse("""
        {"bans":[
          {"reason":"timed","created":"2026-10-30T00:00:00Z","expires":\(Int(now.timeIntervalSince1970) + 2 * 86_400 + 3 * 3600)},
          {"reason":"past","created":"2026-11-02T00:00:00Z","expires":\(Int(now.timeIntervalSince1970) - 60)},
          {"reason":"perm","created":"2026-10-01T00:00:00Z","permanent":true},
          {"reason":"undated","permanent":true}
        ]}
        """)
        XCTAssertEqual(result.entries.map(\.reason), ["past", "timed", "perm", "undated"])
        XCTAssertEqual(result.activeCount, 3)
        let latest = try XCTUnwrap(result.latestActive)
        XCTAssertEqual(latest.reason, "timed")
        XCTAssertEqual(latest.remaining(now: now), 2 * 86_400 + 3 * 3600)
        XCTAssertNil(result.entries[0].remaining(now: now), "ended")
        XCTAssertNil(result.entries[2].remaining(now: now), "permanent")
        // The time-left units follow the app language (like the other formatters).
        L10n.setting = .en
        defer { L10n.setting = .system }
        try english {
            XCTAssertEqual(BanRecordText.remaining(2 * 86_400 + 3 * 3600), "2d 3h")
            let lines = BanRecordText.details(latest, now: now)
            XCTAssertEqual(lines.first, "Reason: timed")
            XCTAssertEqual(lines.last, "Time left: 2d 3h")
            XCTAssertEqual(BanRecordText.details(result.entries[2], now: now).last, "Permanent ban")
            XCTAssertEqual(BanRecordText.reportLine(.success(result)), "Ban record: 3 active")
            XCTAssertEqual(BanRecordText.reportLine(.failure(.timeout)), "Ban record: unavailable")
        }
    }

    func testClientErrorPaths() async throws {
        let url = try XCTUnwrap(URL(string: "https://bans.example.com/api?cid=abc"))
        func fetch(_ reply: FakeBanRecordHTTP.Reply) async -> BanRecordOutcome {
            await BanRecordClient(http: FakeBanRecordHTTP(reply)).fetch(url, bearerToken: nil, now: now)
        }
        let unauthorized = await fetch(.body("{}", status: 401))
        XCTAssertEqual(unauthorized, .failure(.unauthorized(401)))
        let forbidden = await fetch(.body("{}", status: 403))
        XCTAssertEqual(forbidden, .failure(.unauthorized(403)))
        let notFound = await fetch(.body("", status: 404))
        XCTAssertEqual(notFound, .failure(.notFound))
        let server = await fetch(.body("", status: 500))
        XCTAssertEqual(server, .failure(.http(500)))
        let timeout = await fetch(.error(URLError(.timedOut)))
        XCTAssertEqual(timeout, .failure(.timeout))
        let offline = await fetch(.error(URLError(.cannotConnectToHost)))
        XCTAssertEqual(offline, .failure(.network))
        let invalid = await fetch(.body("not json", status: 200))
        XCTAssertEqual(invalid, .failure(.invalidJSON))
        let http = FakeBanRecordHTTP(.body("[]", status: 200))
        _ = await BanRecordClient(http: http).fetch(url, bearerToken: "t0k3n", now: now)
        XCTAssertEqual(http.requests.first?.token, "t0k3n")
        XCTAssertEqual(http.requests.first?.timeout, 10)
        let plain = await BanRecordClient(http: http).fetch(try XCTUnwrap(URL(string: "http://x.example/{cid}")), bearerToken: nil, now: now)
        XCTAssertEqual(plain, .failure(.invalidTemplate(.notHTTPS)))
        try english {
            XCTAssertEqual(BanRecordError.unauthorized(401).text, "The ban record refused access (HTTP 401); check the token.")
            XCTAssertEqual(BanRecordError.timeout.text, "The ban record did not answer within 10 seconds.")
        }
    }

    func testTemplateNeedsCidOrIp() {
        XCTAssertEqual(BanRecordConfig.validate("https://b.example/api?cid={cid}"), .success("https://b.example/api?cid={cid}"))
        XCTAssertEqual(BanRecordConfig.validate("https://b.example/api?ip={ip}"), .success("https://b.example/api?ip={ip}"))
        XCTAssertEqual(BanRecordConfig.validate("https://b.example/api?host={host}"), .failure(.noPlaceholder))
        XCTAssertEqual(BanRecordConfig.validate("http://b.example/{cid}"), .failure(.notHTTPS))
    }

    // MARK: App model

    private let json = #"{"data":[{"reason":"Wallhack","admin":"Kerem","created":"2026-11-15T10:00:00Z","expires":"2026-12-15T10:00:00Z"}]}"#
    private let template = "https://bans.example.com/api/bans?cid={cid}&ip={ip}"

    @MainActor
    private func makeModel(_ env: TestAppEnvironment, http: FakeBanRecordHTTP, store: FakeSecretStore = FakeSecretStore(),
                           udp: FakeUDPTransport? = nil) async throws -> (AppModel, UUID) {
        let model = env.makeModel(udp: udp) { deps in
            deps.banRecordHTTP = http
            deps.secretStore = store
        }
        model.addServer(ServerDraft(label: "A", host: "198.51.100.20"))
        await model.refresh().value
        return (model, try XCTUnwrap(model.servers.first?.id))
    }

    @MainActor
    func testTokenGoesToTheKeychainOnlyAndCanBeRemoved() async throws {
        let env = try TestAppEnvironment()
        let store = FakeSecretStore()
        let (model, id) = try await makeModel(env, http: FakeBanRecordHTTP(.body("[]", status: 200)), store: store)
        XCTAssertNil(model.setBanRecord(urlTemplate: template, enabled: true, token: "s3cr3t-token", for: id))
        XCTAssertEqual(model.banRecordConfig(for: id), BanRecordConfig(urlTemplate: template, enabled: true))
        XCTAssertEqual(try store.secret(for: id.uuidString), "s3cr3t-token")
        XCTAssertTrue(model.hasBanRecordToken(for: id))
        model.save()
        let record = try String(contentsOf: AppPaths(home: env.home).snapshotFile, encoding: .utf8)
        XCTAssertTrue(record.contains("bans.example.com"))
        XCTAssertFalse(record.contains("s3cr3t-token"), "the token never reaches profile.json")
        // `nil` keeps the token; "" removes it.
        XCTAssertNil(model.setBanRecord(urlTemplate: template, enabled: false, token: nil, for: id))
        XCTAssertEqual(try store.secret(for: id.uuidString), "s3cr3t-token")
        XCTAssertNil(model.setBanRecord(urlTemplate: template, enabled: true, token: "", for: id))
        XCTAssertFalse(model.hasBanRecordToken(for: id))
        // Invalid template: nothing changes.
        XCTAssertEqual(model.setBanRecord(urlTemplate: "http://x/{cid}", enabled: true, token: "x", for: id),
                       .invalidTemplate(.notHTTPS))
        XCTAssertEqual(model.banRecordConfig(for: id)?.urlTemplate, template)
        // Deleting the server removes its token.
        _ = model.setBanRecord(urlTemplate: template, enabled: true, token: "again", for: id)
        model.deleteServer(id: id)
        XCTAssertNil(try store.secret(for: id.uuidString))
    }

    @MainActor
    func testKeychainFailureIsReportedAndLogged() async throws {
        let env = try TestAppEnvironment()
        let (model, id) = try await makeModel(env, http: FakeBanRecordHTTP(.body("[]", status: 200)),
                                              store: FakeSecretStore(failing: true))
        XCTAssertEqual(model.setBanRecord(urlTemplate: template, enabled: true, token: "x", for: id), .keychain)
        XCTAssertEqual(model.errorLog.entries.last?.area, .banLookup)
    }

    @MainActor
    func testLookupFillsTheCardAndEnrichesTheUnbanMessage() async throws {
        let env = try TestAppEnvironment()
        env.clock.advance(Date(timeIntervalSince1970: 1_795_000_000).timeIntervalSince(env.clock.now))
        let http = FakeBanRecordHTTP(.body(json, status: 200))
        let (model, id) = try await makeModel(env, http: http, store: FakeSecretStore(values: [:]))
        _ = model.setBanRecord(urlTemplate: template, enabled: true, token: "bearer-123", for: id)
        await model.refreshBanRecord(for: id)?.value
        guard case .finished(.success(let result))? = model.banRecordState(for: id) else {
            return XCTFail("no result: \(String(describing: model.banRecordState(for: id)))")
        }
        XCTAssertEqual(result.activeCount, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.token, "bearer-123")
        XCTAssertTrue(request.url.absoluteString.contains("ip=203.0.113.7"), request.url.absoluteString)
        XCTAssertTrue(request.url.absoluteString.contains("cid="))
        let check = BanCheck(status: .cidBanned, checkedAt: env.clock.now, detail: "cidBanned")
        let appeal = try english { try XCTUnwrap(model.appealText(for: id, check: check)) }
        XCTAssertTrue(appeal.contains("Ban record: Reason: Wallhack; Admin: Kerem; Time left: "), appeal)
    }

    @MainActor
    func testFailedLookupStaysOnTheCardAndInTheErrorLogWithoutSecrets() async throws {
        let env = try TestAppEnvironment()
        let (model, id) = try await makeModel(env, http: FakeBanRecordHTTP(.body("denied", status: 401)))
        _ = model.setBanRecord(urlTemplate: template, enabled: true, token: "bearer-xyz", for: id)
        await model.refreshBanRecord(for: id)?.value
        XCTAssertEqual(model.banRecordState(for: id), .finished(.failure(.unauthorized(401))))
        let entry = try XCTUnwrap(model.errorLog.entries.last)
        XCTAssertEqual(entry.area, .banLookup)
        XCTAssertEqual(entry.message, "http 401")
        XCTAssertFalse(entry.message.contains("bearer-xyz"))
        XCTAssertFalse(entry.message.contains("bans.example.com"))
        // Disabled: no lookup at all.
        _ = model.setBanRecord(urlTemplate: template, enabled: false, token: nil, for: id)
        XCTAssertNil(model.refreshBanRecord(for: id))
    }

    @MainActor
    func testDiagnosisLooksUpOnceAndTheReportKeepsOnlyTheCount() async throws {
        let env = try TestAppEnvironment()
        env.clock.advance(Date(timeIntervalSince1970: 1_795_000_000).timeIntervalSince(env.clock.now))
        let http = FakeBanRecordHTTP(.body(json, status: 200))
        let (model, id) = try await makeModel(env, http: http)
        _ = model.setBanRecord(urlTemplate: template, enabled: true, token: "bearer-secret-77", for: id)
        await model.startDiagnosis(for: id)?.value
        XCTAssertEqual(http.requests.count, 1)
        let diagnosis = try XCTUnwrap(model.diagnosis(for: id)?.result)
        XCTAssertEqual(try diagnosis.banRecord?.get().activeCount, 1)
        for masked in [true, false] {
            let report = try XCTUnwrap(try english { model.diagnosisReport(for: id, masked: masked) })
            XCTAssertTrue(report.contains("- Ban record: 1 active"), report)
            for secret in ["bearer-secret-77", "Wallhack", "Kerem", "bans.example.com", "\"data\""] {
                XCTAssertFalse(report.contains(secret), "\(secret) leaked into the report")
            }
        }
    }
}

// MARK: - §68.3 VPN reality card

final class VPNGuidanceTests: XCTestCase {
    func testVerdictTimesVPNMatrix() throws {
        XCTAssertEqual(VPNGuidance(verdict: .cidBanned, vpnActive: true)?.kind, .identityBan)
        XCTAssertNil(VPNGuidance(verdict: .cidBanned, vpnActive: false))
        XCTAssertEqual(VPNGuidance(verdict: .ipBanned, vpnActive: true)?.kind, .ipBan)
        XCTAssertNil(VPNGuidance(verdict: .ipBanned, vpnActive: false))
        XCTAssertEqual(VPNGuidance(verdict: .rangeBanned, vpnActive: true)?.kind, .identityBan)
        for verdict in DiagnosisVerdict.allCases where !verdict.isBan {
            XCTAssertNil(VPNGuidance(verdict: verdict, vpnActive: true), verdict.rawValue)
        }
        XCTAssertTrue(try XCTUnwrap(VPNGuidance(verdict: .ipBanned, vpnActive: true)).offersAppeal)
        XCTAssertFalse(try XCTUnwrap(VPNGuidance(verdict: .cidBanned, vpnActive: true)).offersAppeal)
    }

    func testCardTextsAndHelp() throws {
        try english {
            let cid = try XCTUnwrap(VPNGuidance(verdict: .cidBanned, vpnActive: true))
            XCTAssertEqual(cid.title, "Changing the VPN does not lift a CID ban")
            XCTAssertTrue(cid.text.contains("derived from the server address"))
            XCTAssertEqual(try XCTUnwrap(VPNGuidance(verdict: .ipBanned, vpnActive: true)).title, "Changing the VPN exit may help")
            XCTAssertEqual(VPNGuidance.helpTitle, "VPN and bans")
            XCTAssertTrue(VPNGuidance.helpText.contains("A CID ban"))
        }
        let turkish = try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            VPNGuidance(verdict: .cidBanned, vpnActive: true)?.title
        }
        XCTAssertEqual(turkish, "VPN değiştirmek CID banını çözmez")
        for name in ["lock.trianglebadge.exclamationmark", "arrow.triangle.swap"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    func testCardFollowsTheDiagnosis() {
        var facts = DiagnosisFacts(dns: .resolved, info: .replied, challenge: .challenge, connect: .banned)
        facts.vpnActive = true
        let probe = ConnectionProbeResult(steps: [], facts: facts, verdict: .cidBanned)
        let diagnosis = ConnectionDiagnosis(label: "S", host: "h", port: 27015, startedAt: Date(), probe: probe,
                                            engineLog: .missing)
        XCTAssertEqual(VPNGuidance(diagnosis)?.kind, .identityBan)
    }
}

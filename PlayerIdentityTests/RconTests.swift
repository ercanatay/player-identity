import XCTest
@testable import PlayerIdentity

/// §72 read-only RCON: packets, auth/timeout/closed port, allowlist, Keychain + no password leak, parsing, keys.
/// Every exchange goes through a fake UDP transport; nothing touches the network or the real Keychain.
final class RconTests: XCTestCase {
    static let endpoint = UDPEndpoint(address: .ipv4([192, 0, 2, 50]), port: 27015)
    static let password = "Hunter2-RCON-Secret-9f3"

    // MARK: (a) packets

    func testEncodeAuthAndCommandPackets() {
        let auth = RconPackets.auth(id: 1, password: "pw")
        XCTAssertEqual(auth, [12, 0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0, 0x70, 0x77, 0, 0] as [UInt8])
        let command = RconPackets.command(id: 2, .status)
        XCTAssertEqual(Array(command.prefix(12)), [16, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0] as [UInt8])
        XCTAssertEqual(Array(command.dropFirst(12)), Array("status".utf8) + [0, 0] as [UInt8])
    }

    func testDecodeRoundTripAndRejectsDamagedPackets() {
        let packet = RconPacket(id: -1, type: 2, body: Array("hello".utf8))
        XCTAssertEqual(RconPackets.decode(RconPackets.encode(packet)), packet)
        let empty = RconPacket(id: 7, type: 0, body: [])
        XCTAssertEqual(RconPackets.decode(RconPackets.encode(empty)), empty)
        XCTAssertNil(RconPackets.decode([]))
        XCTAssertNil(RconPackets.decode([10, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0] as [UInt8]), "short")
        XCTAssertNil(RconPackets.decode(FakeServer.oobText("print\nBad rcon_password.\n")), "OOB reply")
        var tooLong = RconPackets.encode(packet)
        tooLong[0] = 200
        XCTAssertNil(RconPackets.decode(tooLong), "size beyond the datagram")
        var noTerminator = RconPackets.encode(packet)
        noTerminator[noTerminator.count - 1] = 0x41
        XCTAssertNil(RconPackets.decode(noTerminator))
    }

    func testSplitReplyIsJoinedInOrder() async throws {
        let clock = TestClock()
        let transport = FakeRcon.transport(clock: clock, outputs: [.status: ["part one, ", "part two, ", "part three"]])
        let outcome = try await client(transport, clock).run(.status, endpoint: Self.endpoint, password: Self.password)
        let output = try outcome.get()
        XCTAssertEqual(output.text, "part one, part two, part three")
        XCTAssertFalse(output.truncated)
        XCTAssertEqual(transport.sentCount, 2, "auth + one command")
    }

    func testSplitReplyIsCutAt64KB() async throws {
        let clock = TestClock()
        let chunk = String(repeating: "x", count: 30_000)
        let transport = FakeRcon.transport(clock: clock, outputs: [.banlist: [chunk, chunk, chunk]])
        let output = try await client(transport, clock).run(.banlist, endpoint: Self.endpoint, password: Self.password).get()
        XCTAssertTrue(output.truncated)
        XCTAssertEqual(output.text.utf8.count, RconClient.maxResponseBytes)
    }

    // MARK: (b) auth failure / timeout / closed port

    func testWrongPasswordFailsAuthAndSendsNoCommand() async throws {
        let clock = TestClock()
        let transport = FakeRcon.transport(clock: clock, password: "other")
        let outcome = try await client(transport, clock).run(.status, endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(outcome, .failure(.authFailed))
        XCTAssertEqual(transport.sentCount, 1)
    }

    func testSilenceTimesOutAfterTwoRetries() async throws {
        let clock = TestClock()
        let start = clock.now
        let transport = FakeUDPTransport(clock: clock) { _, _ in [] }
        let outcome = try await client(transport, clock).run(.status, endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(outcome, .failure(.timeout))
        XCTAssertEqual(transport.sentCount, 1 + RconClient.maxRetries)
        XCTAssertEqual(clock.now.timeIntervalSince(start), 9, accuracy: 0.001, "3 s per attempt")
    }

    func testCommandTimeoutRetriesTheCommandOnly() async throws {
        let clock = TestClock()
        let transport = FakeRcon.transport(clock: clock, outputs: [:])
        let outcome = try await client(transport, clock).run(.listip, endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(outcome, .failure(.timeout))
        let types = transport.sentPackets.compactMap { RconPackets.decode($0)?.type }
        XCTAssertEqual(types, [3, 2, 2, 2])
    }

    func testClosedPortIsReported() async throws {
        let clock = TestClock()
        // The engine answers with an out-of-band text instead of an RCON packet.
        let oob = FakeUDPTransport(clock: clock) { _, _ in [FakeReply(bytes: FakeServer.oobText("print\nrcon disabled\n"))] }
        let first = try await client(oob, clock).run(.status, endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(first, .failure(.closed))
        XCTAssertEqual(oob.sentCount, 1, "no retry after an answer")
        // ICMP port unreachable: the send fails.
        let refused = try await client(RefusingTransport(), clock).run(.status, endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(refused, .failure(.closed))
        // No socket at all.
        let none = try await client(NoSocketRconTransport(), clock).run(.status, endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(none, .failure(.unreachable))
    }

    func testErrorReplyIsShownRawAndNotRetried() async throws {
        let clock = TestClock()
        let transport = FakeRcon.transport(clock: clock, outputs: [.users: ["Unknown command \"users\""]], errorType: true)
        let outcome = try await client(transport, clock).run(.users, endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(outcome, .failure(.rejected("Unknown command \"users\"")))
        XCTAssertEqual(transport.sentCount, 2)
    }

    // MARK: (c) allowlist

    func testOnlyAllowlistedCommandsAreSent() async throws {
        XCTAssertEqual(Set(RconCommand.allCases.map(\.rawValue)), ["status", "stats", "listip", "banlist", "users"])
        for text in ["kick player", "banid 0 STEAM_0:1:1", "addip 0 1.2.3.4", "removeip 1.2.3.4", "rcon_password x",
                     "status; quit", "status\nquit", "STATUS", " status", "status ", "", "quit", "changelevel de_dust2"] {
            XCTAssertNil(RconCommand(allowlisted: text), text)
            let clock = TestClock()
            let transport = FakeRcon.transport(clock: clock)
            let outcome = try await client(transport, clock).run(text: text, endpoint: Self.endpoint, password: Self.password)
            XCTAssertEqual(outcome, .failure(.notAllowed), text)
            XCTAssertEqual(transport.sessionCount, 0, text)
            XCTAssertEqual(transport.sentCount, 0, text)
        }
        let clock = TestClock()
        let transport = FakeRcon.transport(clock: clock, outputs: [.stats: ["CPU In Out"]])
        let ok = try await client(transport, clock).run(text: "stats", endpoint: Self.endpoint, password: Self.password)
        XCTAssertEqual(try ok.get().text, "CPU In Out")
    }

    @MainActor
    func testConsoleButtonsSendOnlyAllowlistedCommands() {
        XCTAssertEqual(RconConsoleSection.commands.prefix(3), [.status, .banlist, .listip])
        XCTAssertTrue(Set(RconConsoleSection.commands).isSubset(of: Set(RconCommand.allCases)))
    }

    // MARK: (d) Keychain (fake) and no password leak

    @MainActor
    func testPasswordIsStoredRemovedAndDeletedWithTheServer() throws {
        let env = try TestAppEnvironment()
        let store = InMemorySecretStore()
        let model = env.makeModel { $0.rconSecretStore = store }
        model.addServer(ServerDraft(label: "RCON", host: "192.0.2.50"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertFalse(model.hasRconPassword(for: id))
        XCTAssertNil(model.setRconPassword(Self.password, for: id))
        XCTAssertEqual(try store.secret(for: "rcon.\(id.uuidString)"), Self.password)
        XCTAssertTrue(model.hasRconPassword(for: id))
        XCTAssertNil(model.setRconPassword(nil, for: id))
        XCTAssertNil(try store.secret(for: RconKeychain.account(id)))
        XCTAssertNil(model.setRconPassword(Self.password, for: id))
        model.deleteServer(id: id)
        XCTAssertNil(try store.secret(for: RconKeychain.account(id)), "deleting the server removes its password")
    }

    @MainActor
    func testKeychainFailureIsLoggedWithoutThePassword() throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel { $0.rconSecretStore = FailingSecretStore() }
        model.addServer(ServerDraft(label: "RCON", host: "192.0.2.50"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertEqual(model.setRconPassword(Self.password, for: id), .keychain)
        model.setRconEnabled(true, for: id)
        XCTAssertNil(model.runRcon(.status, for: id))
        XCTAssertEqual(model.rconState(for: id), .finished(.status, .failure(.keychain)))
        let messages = model.errorLog.entries.filter { $0.area == .rcon }.map(\.message)
        XCTAssertEqual(messages, ["keychainWrite", "keychain status"])
        XCTAssertFalse(messages.joined().contains(Self.password))
    }

    @MainActor
    func testPasswordNeverReachesFilesLogsOrReports() async throws {
        let env = try TestAppEnvironment()
        let store = InMemorySecretStore()
        let clock = env.clock
        let wrong = WrongPasswordSwitch()
        let udp = FakeUDPTransport(clock: clock) { endpoint, packet in
            if wrong.on, RconPackets.decode(packet)?.type == RconPacket.typeAuth {
                return [FakeReply(bytes: FakeRcon.packet(id: -1, type: 2, ""))]
            }
            return FakeRcon.responder(password: Self.password, outputs: [.status: [FakeRcon.goldSrcStatus]])(endpoint, packet)
        }
        let model = env.makeModel(udp: udp) { $0.rconSecretStore = store }
        model.addServer(ServerDraft(label: "RCON", host: "192.0.2.50"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        model.setRconEnabled(true, for: id)
        XCTAssertTrue(model.setRconPort(27016, for: id))
        XCTAssertNil(model.setRconPassword(Self.password, for: id))
        model.save()
        XCTAssertNil(model.saveErrorMessage)

        // Success, then a wrong password, then a timeout: every outcome is kept and logged.
        await model.runRcon(.status, for: id)?.value
        guard case .finished(.status, .success(let output))? = model.rconState(for: id) else {
            return XCTFail("expected output, got \(String(describing: model.rconState(for: id)))")
        }
        XCTAssertEqual(RconParser.parse(output), .players(FakeRcon.goldSrcPlayers))
        wrong.on = true
        await model.runRcon(.banlist, for: id)?.value
        XCTAssertEqual(model.rconState(for: id), .finished(.banlist, .failure(.authFailed)))
        wrong.on = false
        await model.runRcon(.listip, for: id)?.value
        XCTAssertEqual(model.rconState(for: id), .finished(.listip, .failure(.timeout)))

        // Diagnosis report, sync file, settings export and the diagnostics ZIP.
        await model.startDiagnosis(for: id)?.value
        await model.waitForHistory()
        let report = try XCTUnwrap(model.diagnosisReport(for: id, masked: false))
        let folder = env.temp.url.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.setSyncFolder(folder).value
        XCTAssertNil(model.syncError)
        let export = try model.settingsArchive(scope: .settingsAndServers, includeDataRoot: true).encoded()
        let zip = await model.diagnosticsArchive(appInfo: DiagnosticsAppInfo(version: "1.0", build: "1", osVersion: "x",
                                                                            architecture: "arm64", language: "en"))
        let zipFiles = try XCTUnwrap(ZipArchive.read(zip))
        XCTAssertTrue(zipFiles.contains { $0.name == "errors.json" })

        // The RCON settings were saved (so the record was really written) …
        let profile = try String(contentsOf: AppPaths(home: env.home).snapshotFile, encoding: .utf8)
        XCTAssertTrue(profile.contains("\"rconEnabled\" : true"), profile)
        XCTAssertTrue(profile.contains("27016"))
        let rconLog = model.errorLog.entries.filter { $0.area == .rcon }.map(\.message)
        XCTAssertEqual(rconLog, ["authFailed banlist", "timeout listip"])

        // … but the password is nowhere: not in any file under the test home, the export, the ZIP, the report, the
        // error log or the preferences.
        var texts: [(String, Data)] = [("report", Data(report.utf8)), ("export", export), ("zip", zip)]
        texts += zipFiles.map { ("zip/\($0.name)", $0.data) }
        texts.append(("errorLog", Data(model.errorLog.entries.map(\.message).joined(separator: "\n").utf8)))
        let defaults = env.defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        texts.append(("defaults", Data(defaults.utf8)))
        let files = FileManager.default.enumerator(at: env.temp.url, includingPropertiesForKeys: [.isRegularFileKey])!
        var fileCount = 0
        for case let url as URL in files.allObjects where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            texts.append((url.path, try Data(contentsOf: url)))
            fileCount += 1
        }
        XCTAssertGreaterThan(fileCount, 3, "profile.json, errors.json, history and the sync file were written")
        XCTAssertTrue(texts.contains { $0.0.hasSuffix(SyncFile.fileName) })
        let needle = Data(Self.password.utf8)
        for (name, data) in texts {
            XCTAssertNil(data.range(of: needle), "password leaked into \(name)")
        }
        // The password only ever left through the auth packets of the fake transport (RCON is plain UDP).
        let authPackets = udp.sentPackets.compactMap(RconPackets.decode).filter { $0.type == RconPacket.typeAuth }
        XCTAssertFalse(authPackets.isEmpty)
    }

    // MARK: (e) parsing

    func testGoldSrcStatusParsesPlayers() {
        XCTAssertEqual(RconParser.status(FakeRcon.goldSrcStatus), FakeRcon.goldSrcPlayers)
    }

    func testSourceStatusParsesPlayers() {
        let text = """
        hostname: Source Server
        map     : de_dust2 at: 0 x, 0 y, 0 z
        # userid name uniqueid connected ping loss state adr
        #      2 "Alpha" STEAM_1:0:111 05:12 40 0 active 198.51.100.4:27005
        #      3 "Beta Two" BOT active
        #end
        """
        XCTAssertEqual(RconParser.status(text), [RconPlayer(name: "Alpha", score: "—", time: "05:12"),
                                                 RconPlayer(name: "Beta Two", score: "—", time: "active")])
    }

    func testStatusWithoutPlayersAndUnparseableStatus() {
        let empty = "hostname: Empty\nplayers : 0 active (32 max)\n\n#      name userid uniqueid frag time ping loss adr\n0 users\n"
        XCTAssertEqual(RconParser.status(empty), [])
        let output = RconOutput(command: .status, text: "garbage without a table", truncated: false, receivedAt: Date())
        XCTAssertEqual(RconParser.parse(output), .raw("garbage without a table"))
    }

    func testListipParsesAddresses() {
        let text = "IP filter list:\n198.51.100.4 : permanent\n203.0.113.0/24 :  20.000 min\nnot an ip\n"
        XCTAssertEqual(RconParser.listip(text), ["198.51.100.4", "203.0.113.0/24"])
        XCTAssertEqual(RconParser.listip("IP filter list: empty\n"), [])
        XCTAssertNil(RconParser.listip("Bad command"))
        let output = RconOutput(command: .listip, text: "nonsense", truncated: false, receivedAt: Date())
        XCTAssertEqual(RconParser.parse(output), .raw("nonsense"))
    }

    func testBanlistCountsLinesAndKeepsTheFirst50() {
        let lines = (1...120).map { "\($0): STEAM_0:0:\($0) permanent" }
        let output = RconOutput(command: .banlist, text: lines.joined(separator: "\n") + "\n\n", truncated: false,
                                receivedAt: Date())
        guard case .bans(let count, let shown) = RconParser.parse(output) else { return XCTFail() }
        XCTAssertEqual(count, 120)
        XCTAssertEqual(shown, Array(lines.prefix(50)))
        XCTAssertEqual(RconParser.parse(RconOutput(command: .banlist, text: " \n", truncated: false, receivedAt: Date())),
                       .raw(" \n"))
    }

    func testUnknownCommandAndFreeFormOutputStayRaw() {
        let unknown = RconOutput(command: .banlist, text: "Unknown command \"banlist\"\n", truncated: false, receivedAt: Date())
        XCTAssertTrue(unknown.isUnknownCommand)
        XCTAssertEqual(RconParser.parse(unknown), .raw(unknown.text))
        let stats = RconOutput(command: .stats, text: "CPU   In    Out\n0.00  1.2   3.4\n", truncated: false, receivedAt: Date())
        XCTAssertEqual(RconParser.parse(stats), .raw(stats.text))
    }

    // MARK: (f) keys

    func testRconKeysExistInEveryLanguage() throws {
        let keys = L10nKey.allCases.filter { $0.rawValue.hasPrefix("rcon.") }
        XCTAssertEqual(keys.count, 39)
        for language in AppLanguage.allCases {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                    subdirectory: nil, localization: language.rawValue))
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys { XCTAssertFalse(table[key.rawValue]?.isEmpty ?? true, "\(language.rawValue): \(key.rawValue)") }
        }
    }

    // MARK: (g) app model over the fake transport

    @MainActor
    func testModelRunsOnTheRconPortAndGatesOnSwitchAndPassword() async throws {
        let env = try TestAppEnvironment()
        let seen = EndpointRecorder()
        let udp = FakeUDPTransport(clock: env.clock) { endpoint, packet in
            seen.add(endpoint)
            return FakeRcon.responder(password: Self.password, outputs: [.listip: ["IP filter list:\n198.51.100.9 : permanent\n"]])(endpoint, packet)
        }
        let model = env.makeModel(udp: udp) { $0.rconSecretStore = InMemorySecretStore() }
        model.addServer(ServerDraft(label: "RCON", host: "192.0.2.50"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertFalse(model.servers[0].rconEnabled, "off by default")
        XCTAssertEqual(model.servers[0].rconPort, 27015)

        XCTAssertNil(model.runRcon(.listip, for: id))
        XCTAssertEqual(model.rconState(for: id), .finished(.listip, .failure(.disabled)))
        model.setRconEnabled(true, for: id)
        XCTAssertNil(model.runRcon(.listip, for: id))
        XCTAssertEqual(model.rconState(for: id), .finished(.listip, .failure(.noPassword)))
        XCTAssertFalse(model.setRconPort(0, for: id))
        XCTAssertFalse(model.setRconPort(70_000, for: id))
        XCTAssertTrue(model.setRconPort(27020, for: id))
        model.setRconPassword(Self.password, for: id)
        let packetsBefore = udp.sentCount
        XCTAssertEqual(packetsBefore, 0, "nothing is sent while the console is off or has no password")

        await model.runRcon(.listip, for: id)?.value
        guard case .finished(.listip, .success(let output))? = model.rconState(for: id) else { return XCTFail() }
        XCTAssertEqual(RconParser.parse(output), .ips(["198.51.100.9"]))
        XCTAssertEqual(seen.ports, [27020, 27020])
    }

    func testServerEntryCodingKeepsOldRecordsUnchanged() throws {
        let encoder = JSONEncoder()
        let plain = ServerEntry(label: "A", host: "192.0.2.1")
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("rcon"), "defaults are not written")
        XCTAssertEqual(try JSONDecoder().decode(ServerEntry.self, from: Data(plainJSON.utf8)), plain)

        let rcon = ServerEntry(label: "B", host: "192.0.2.2", rconEnabled: true, rconPort: 27016)
        XCTAssertEqual(try JSONDecoder().decode(ServerEntry.self, from: try encoder.encode(rcon)), rcon)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(rcon)) as? [String: Any])
        object["rconPort"] = 99_999
        let broken = try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(broken.rconPort, ServerEntry.defaultPort, "an invalid port falls back to the default")
        XCTAssertTrue(broken.rconEnabled)
    }

    // MARK: Helpers

    private func client(_ transport: any UDPTransport, _ clock: TestClock) -> RconClient {
        RconClient(transport: transport, now: { clock.now })
    }
}

// MARK: - Fakes

/// A scripted RCON server behind `FakeUDPTransport`.
enum FakeRcon {
    static func packet(id: Int32, type: Int32, _ body: String) -> [UInt8] {
        RconPackets.encode(RconPacket(id: id, type: type, body: Array(body.utf8)))
    }

    /// Auth with `password` → empty value packet + auth OK (type 2); a wrong one → id `-1`. A command answers with its
    /// chunks (one packet each, type 2 — or type 0 when `errorType`); a command without chunks stays silent.
    static func responder(password: String = RconTests.password, outputs: [RconCommand: [String]] = [:],
                          errorType: Bool = false) -> FakeUDPTransport.Responder {
        { _, bytes in
            guard let request = RconPackets.decode(bytes) else { return [] }
            switch request.type {
            case RconPacket.typeAuth:
                guard request.text == password else { return [FakeReply(bytes: packet(id: -1, type: 2, ""))] }
                return [FakeReply(bytes: packet(id: request.id, type: 0, "")),
                        FakeReply(bytes: packet(id: request.id, type: 2, ""))]
            case RconPacket.typeCommand:
                guard let command = RconCommand(allowlisted: request.text), let chunks = outputs[command] else { return [] }
                return chunks.map { FakeReply(bytes: packet(id: request.id, type: errorType ? 0 : 2, $0)) }
            default:
                return []
            }
        }
    }

    static func transport(clock: TestClock, password: String = RconTests.password,
                          outputs: [RconCommand: [String]] = [:], errorType: Bool = false) -> FakeUDPTransport {
        FakeUDPTransport(clock: clock, responder: responder(password: password, outputs: outputs, errorType: errorType))
    }

    static let goldSrcStatus = """
    hostname:  Test Server
    version :  48/1.1.2.7/Stdio 8684 secure  (10)
    tcp/ip  :  192.0.2.50:27015
    map     :  de_dust2 at: 0 x, 0 y, 0 z
    players :  2 active (32 max)

    #      name userid uniqueid frag time ping loss adr
    # 1 "Player One" 2 STEAM_0:1:123 5 12:34 50 0 198.51.100.4:27005
    # 2 "Bot" 3 BOT 0 1:02:03 0 0
    2 users
    """

    static let goldSrcPlayers = [RconPlayer(name: "Player One", score: "5", time: "12:34"),
                                 RconPlayer(name: "Bot", score: "0", time: "1:02:03")]
}

private final class WrongPasswordSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class EndpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [UDPEndpoint] = []
    func add(_ endpoint: UDPEndpoint) { lock.withLock { endpoints.append(endpoint) } }
    var ports: [UInt16] { lock.withLock { endpoints.map(\.port) } }
}

/// Every send fails (ICMP port unreachable on a connected UDP socket).
private struct RefusingTransport: UDPTransport {
    private struct Session: UDPSession {
        func send(_ packet: [UInt8]) throws { throw UDPSocketError.system(ECONNREFUSED) }
        func receive(timeout: TimeInterval) async throws -> [UInt8]? { nil }
        func close() {}
    }

    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession { Session() }
}

private struct NoSocketRconTransport: UDPTransport {
    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession { throw UDPSocketError.unsupportedAddress }
}

private struct FailingSecretStore: SecretStoring {
    func secret(for account: String) throws -> String? { throw SecretStoreError.status(-25_300) }
    func setSecret(_ value: String?, for account: String) throws { throw SecretStoreError.status(-25_300) }
}

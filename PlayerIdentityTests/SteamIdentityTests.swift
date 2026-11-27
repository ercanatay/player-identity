import XCTest
@testable import PlayerIdentity

/// Broker probes and process control without touching the host: records starts and stops.
final class FakeSteamBroker: SteamBrokerEnvironment, SteamBrokerProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    var pathResult: SteamBrokerPathCheck = .valid
    var steamRunning = true
    var brokerProcessRunning = false
    private var listeningValue = false
    /// The port starts listening once `start` ran (a broker that comes up).
    var listensAfterStart = true
    private var startedValue: [String] = []
    private var addressesValue: [String] = []
    private var cwdValue: [String] = []
    var executableFiles: Set<String> = []
    var steamStart: Date? = Date(timeIntervalSince1970: 1_000)
    var brokerStart: Date? = Date(timeIntervalSince1970: 2_000)
    private var stoppedValue: [Int32] = []
    var startFails = false

    var listening: Bool {
        get { lock.withLock { listeningValue } }
        set { lock.withLock { listeningValue = newValue } }
    }
    var started: [String] { lock.withLock { startedValue } }
    var startAddresses: [String] { lock.withLock { addressesValue } }
    var startDirectories: [String] { lock.withLock { cwdValue } }
    var stopped: [Int32] { lock.withLock { stoppedValue } }

    func pathCheck(_ path: String) -> SteamBrokerPathCheck { pathResult }
    func isPortListening(host: String, port: Int) -> Bool { listening }
    func isBrokerProcessRunning(executablePath: String) -> Bool { brokerProcessRunning }
    func isSteamClientRunning() -> Bool { steamRunning }
    func isExecutableRegularFile(_ path: String) -> Bool { executableFiles.contains(path) }
    func steamClientStartTime() -> Date? { steamRunning ? steamStart : nil }
    func brokerProcessStartTime(executablePath: String) -> Date? { listening || brokerProcessRunning ? brokerStart : nil }

    func start(executablePath: String, address: String, workingDirectory: String) throws -> Int32 {
        if startFails { throw CommandError.launchFailed }
        lock.withLock {
            startedValue.append(executablePath)
            addressesValue.append(address)
            cwdValue.append(workingDirectory)
            if listensAfterStart { listeningValue = true }
            brokerStart = Date(timeIntervalSince1970: 10_000)   // a started broker is newer than Steam
        }
        return 4242
    }

    func stop(pid: Int32) { lock.withLock { stoppedValue.append(pid); listeningValue = false } }
}

/// A file system that serves one `engine.log`.
struct FakeLogFileSystem: FileSystemReading {
    let log: String?
    func isRegularFile(_ url: URL) -> Bool { log != nil && url.lastPathComponent == "engine.log" }
    func isDirectory(_ url: URL) -> Bool { false }
    func readData(_ url: URL) throws -> Data { Data((log ?? "").utf8) }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { [] }
}

/// §76 Steam identity: argv, consent, broker ownership, engine log evidence, server memory, CLI.
final class SteamIdentityTests: XCTestCase {
    private static let app = "/Applications/Xash3D-FWGS.app"
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private let dataRoot = URL(fileURLWithPath: "/tmp/pi-steam-data", isDirectory: true)
    private let endpoint = SteamBrokerEndpoint(host: "127.0.0.1", port: 27420, executablePath: "/opt/broker/broker")
    private let steamTriple = ["+set", "cl_ticket_generator", "steam"]

    private func launcher(runner: FakeGameLaunchRunner = FakeGameLaunchRunner(),
                          running: Bool = false) -> GameLauncher {
        GameLauncher(locator: GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]), homeDirectory: home),
                     resolver: FakeAddressResolver(), detector: FakeGameDetector(running: running), runner: runner)
    }

    private func coordinator(runner: FakeGameLaunchRunner, broker: FakeSteamBroker, log: String? = nil,
                             running: Bool = false, now: Date = Date()) -> SteamJoinCoordinator {
        SteamJoinCoordinator(launcher: launcher(runner: runner, running: running),
                             broker: SteamBrokerManager(environment: broker, control: broker, sleep: { _ in }),
                             fileSystem: FakeLogFileSystem(log: log), now: { now }, sleep: { _ in })
    }

    private func join(_ coordinator: SteamJoinCoordinator, consent: Bool = true, protocol serverProtocol: ServerProtocol = .source49,
                      root: URL? = nil) async throws -> SteamJoinHandle {
        try await coordinator.join(host: "192.0.2.10", port: 27015, gamedir: "valve", known: [:],
                                   serverProtocol: serverProtocol, dataRoot: root ?? dataRoot, endpoint: endpoint,
                                   consent: { consent }, confirmReplace: { true })
    }

    // MARK: §76.8.6 argv

    func testBothMethodsSetTheTicketGeneratorExplicitly() async throws {
        let standard = try await launcher().plan(host: "192.0.2.10", port: 27015, gamedir: "valve")
        XCTAssertEqual(standard.command.argv, ["/usr/bin/open", "-a", Self.app, "--args", "-game", "valve",
                                               "+set", "cl_ticket_generator", "revemu2013", "+connect", "192.0.2.10:27015"])
        XCTAssertEqual(standard.command.identity, .standard)
        let steam = try await launcher().plan(host: "192.0.2.10", port: 27015, gamedir: "valve", identity: .steamAuth)
        XCTAssertEqual(steam.command.argv, ["/usr/bin/open", "-a", Self.app, "--args", "-game", "valve"]
                       + steamTriple + ["+connect", "192.0.2.10:27015"])
        // The two lines differ only in the cvar value.
        var swapped = steam.command.argv
        swapped[8] = "revemu2013"
        XCTAssertEqual(swapped, standard.command.argv)
        XCTAssertTrue(GameLaunchAllowlist.isAllowed(steam.command.argv))
        XCTAssertTrue(GameLaunchAllowlist.isAllowed(standard.command.argv))
    }

    /// §78.4.3 a `steam` value saved in `config.cfg` does not decide the method: the launch line always does, and
    /// the app writes nothing to the game folder.
    func testConfigCfgValueNeverDecidesTheStandardMethod() async throws {
        let temp = try TempDirectory()
        let cfg = try temp.write("data/valve/config.cfg", "cl_ticket_generator \"steam\"\nname \"N\"\n")
        let before = try Data(contentsOf: cfg)
        let plan = try await launcher().plan(host: "192.0.2.10", port: 27015, gamedir: "valve",
                                             dataRoot: temp.url.appendingPathComponent("data", isDirectory: true))
        XCTAssertEqual(Array(plan.command.argv[6..<9]), ["+set", "cl_ticket_generator", "revemu2013"])
        XCTAssertFalse(plan.command.argv.contains("steam"))
        XCTAssertEqual(try Data(contentsOf: cfg), before)
    }

    func testGoldSrcSteamArgvKeepsTheLogArgumentsAndTheAllowlistStaysStrict() async throws {
        let standard = try await launcher().plan(host: "192.0.2.10", port: 27015, gamedir: "valve",
                                                 serverProtocol: .goldsrc48, dataRoot: dataRoot)
        let steam = try await launcher().plan(host: "192.0.2.10", port: 27015, gamedir: "valve",
                                              serverProtocol: .goldsrc48, dataRoot: dataRoot, identity: .steamAuth)
        var swapped = steam.command.argv
        let marker = try XCTUnwrap(swapped.firstIndex(of: "+set"))
        swapped[marker + 2] = "revemu2013"
        XCTAssertEqual(swapped, standard.command.argv)
        XCTAssertTrue(steam.command.argv.suffix(3) == ["+connect", "192.0.2.10:27015", "gs"])
        XCTAssertTrue(GameLaunchAllowlist.isAllowed(steam.command.argv))
        // Any other `+set` shape is refused.
        var other = steam.command.argv
        other[marker + 2] = "other"
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(other))
        var twice = steam.command.argv
        twice.insert(contentsOf: steamTriple, at: marker)
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(twice))
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(["/usr/bin/open", "+set", "cl_ticket_generator", "steam", "+connect",
                                                      "192.0.2.10:27015"]))
        // A line without the explicit cvar is no longer a launch line.
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(["/usr/bin/open", "-a", Self.app, "--args", "-game", "valve",
                                                      "+connect", "192.0.2.10:27015"]))
    }

    // MARK: §76.8.3 consent

    func testDeclinedConsentStartsNothing() async throws {
        let runner = FakeGameLaunchRunner()
        let broker = FakeSteamBroker()
        let flow = coordinator(runner: runner, broker: broker)
        do {
            _ = try await join(flow, consent: false)
            XCTFail("declined consent must stop the flow")
        } catch {
            XCTAssertEqual(error as? GameLaunchError, .cancelled)
        }
        XCTAssertEqual(runner.commands, [])
        XCTAssertEqual(broker.started, [])
        XCTAssertEqual(broker.stopped, [])
    }

    func testConsentTextIsTheSpecWording() {
        XCTAssertTrue(L10n.text(.steamConsentMessage).contains("SteamID"))
        try? L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(L10n.text(.steamConsentMessage),
                           "Steam kimliğiyle bağlantı, bu sunucuya gerçek Steam hesabınızın kimliğini (SteamID) bildirir. "
                           + "Sunucu yöneticisi bu kimliği Steam hesabınıza bağlayabilir. Oyunda görünen isim değişmez.")
        }
    }

    @MainActor
    func testModelConsentIsAskedAtEverySelectionAndDecliningRunsNothing() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let broker = FakeSteamBroker()
        broker.listening = true
        let model = env.makeModel { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]), homeDirectory: self.home)
            deps.gameLaunchRunner = runner
            deps.steamBrokerEnvironment = broker
            deps.steamBrokerControl = broker
            deps.steamSleep = { _ in }
        }
        model.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)

        let first = try XCTUnwrap(model.joinGame(id, identity: .steamAuth))
        await Task.yield()
        for _ in 0..<50 where model.steamPrompt == nil { await Task.yield() }
        XCTAssertEqual(model.steamPrompt, .consent(label: "A"))
        model.answerSteamPrompt(false)
        await first.value
        XCTAssertEqual(runner.commands, [])
        XCTAssertNil(model.joinError)
        XCTAssertEqual(broker.started, [])

        // The next selection asks again (no "always").
        let second = try XCTUnwrap(model.joinGame(id, identity: .steamAuth))
        for _ in 0..<50 where model.steamPrompt == nil { await Task.yield() }
        XCTAssertEqual(model.steamPrompt, .consent(label: "A"))
        model.answerSteamPrompt(true)
        await second.value
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(Array(runner.commands[0][6..<9]), steamTriple)
        // A plain "Join Game" never carries it.
        await model.joinGame(id, identity: .standard)?.value
        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertEqual(Array(runner.commands[1][6..<9]), ["+set", "cl_ticket_generator", "revemu2013"])
    }

    // MARK: §76.8.4 / §76.8.5 broker state and errors

    func testBrokerStates() {
        let broker = FakeSteamBroker()
        let manager = SteamBrokerManager(environment: broker, control: broker, sleep: { _ in })
        XCTAssertEqual(manager.state(SteamBrokerEndpoint()), .notConfigured)
        broker.pathResult = .missing
        XCTAssertEqual(manager.state(endpoint), .notConfigured)
        broker.pathResult = .valid
        XCTAssertEqual(manager.state(endpoint), .notRunning)
        broker.brokerProcessRunning = true
        XCTAssertEqual(manager.state(endpoint), .unreachable)
        broker.listening = true
        XCTAssertEqual(manager.state(endpoint), .listening)
        broker.steamRunning = false
        XCTAssertEqual(manager.state(endpoint), .steamSessionMissing)
        XCTAssertFalse(SteamBrokerState.notConfigured.isUsable)
    }

    func testNotConfiguredAndSessionMissingErrorsStartNothing() async throws {
        let runner = FakeGameLaunchRunner()
        let broker = FakeSteamBroker()
        broker.pathResult = .empty
        let flow = coordinator(runner: runner, broker: broker)
        do { _ = try await join(flow); XCTFail() } catch {
            XCTAssertEqual(error as? GameLaunchError, .steamBrokerNotConfigured)
            XCTAssertEqual(GameLaunchText.error(.steamBrokerNotConfigured), L10n.text(.steamJoinDisabledHint))
        }
        broker.pathResult = .valid
        broker.steamRunning = false
        do { _ = try await join(flow); XCTFail() } catch {
            XCTAssertEqual(error as? GameLaunchError, .steamSessionRequired)
            XCTAssertEqual(GameLaunchText.error(.steamSessionRequired), L10n.text(.steamStateSessionMissing))
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(GameLaunchText.error(.steamSessionRequired), "Steam oturumu gerekli")
        }
        XCTAssertEqual(runner.commands, [])
        XCTAssertEqual(broker.started, [])
    }

    // MARK: §76.8.8 ownership

    func testBrokerStartedByTheAppIsStoppedAndAForeignOneIsNot() async throws {
        let runner = FakeGameLaunchRunner()
        let own = FakeSteamBroker()
        let ownFlow = coordinator(runner: runner, broker: own)
        let handle = try await join(ownFlow)
        XCTAssertEqual(own.started, ["/opt/broker/broker"])
        XCTAssertEqual(handle.session, SteamBrokerSession(startedByApp: true, pid: 4242))
        XCTAssertEqual(own.stopped, [])                       // still needed while the game runs
        _ = await ownFlow.finish(handle, addresses: [], dataRoot: nil)
        XCTAssertEqual(own.stopped, [4242])                   // the game closed: the app's broker stops

        let foreign = FakeSteamBroker()
        foreign.listening = true                              // the user started it themselves
        let foreignFlow = coordinator(runner: runner, broker: foreign)
        let foreignHandle = try await join(foreignFlow)
        XCTAssertEqual(foreign.started, [])
        XCTAssertEqual(foreignHandle.session, SteamBrokerSession(startedByApp: false, pid: nil))
        _ = await foreignFlow.finish(foreignHandle, addresses: [], dataRoot: nil)
        XCTAssertEqual(foreign.stopped, [])
    }

    func testBrokerThatNeverListensIsStoppedAndReported() async throws {
        let broker = FakeSteamBroker()
        broker.listensAfterStart = false
        let flow = coordinator(runner: FakeGameLaunchRunner(), broker: broker)
        do { _ = try await join(flow); XCTFail() } catch {
            XCTAssertEqual(error as? GameLaunchError, .steamBrokerUnreachable)
        }
        XCTAssertEqual(broker.stopped, [4242])
        broker.startFails = true
        do { _ = try await join(flow); XCTFail() } catch {
            XCTAssertEqual(error as? GameLaunchError, .steamBrokerStartFailed)
        }
    }

    func testLaunchFailureReleasesAnAppStartedBroker() async throws {
        let runner = FakeGameLaunchRunner()
        runner.status = 1
        let broker = FakeSteamBroker()
        let flow = coordinator(runner: runner, broker: broker)
        do { _ = try await join(flow); XCTFail() } catch {
            XCTAssertEqual(error as? GameLaunchError, .launchFailed(status: 1))
        }
        XCTAssertEqual(broker.stopped, [4242])
    }

    // MARK: §76.8.7 no game file is written

    func testNoGameFileIsWritten() async throws {
        let temp = try TempDirectory()
        try temp.write("data/valve/config.cfg", "name \"N\"\nbind \"g\" \"x\"\n")
        try temp.write("data/valve/userconfig.cfg", "bind \"b\" \"y\"\n")
        let root = temp.url.appendingPathComponent("data", isDirectory: true)
        func snapshot() throws -> [String: Data] {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return try Dictionary(uniqueKeysWithValues: files.filter { $0.hasDirectoryPath == false && !$0.path.hasSuffix("valve") }
                .map { ($0.path, try Data(contentsOf: $0)) })
        }
        let before = try snapshot()
        let broker = FakeSteamBroker()
        let flow = coordinator(runner: FakeGameLaunchRunner(), broker: broker)
        let handle = try await join(flow, root: root)
        _ = await flow.finish(handle, addresses: ["192.0.2.10:27015"], dataRoot: root)
        XCTAssertEqual(try snapshot(), before)
    }

    // MARK: §76.8.9 engine.log evidence → memory

    private func log(_ lines: [String], start: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMdd yyyy '['HH:mm.ss']'"
        return (["Game started at " + formatter.string(from: start)] + lines).joined(separator: "\n")
    }

    func testEngineLogOutcomesAreParsedAndWrittenToTheMemory() async throws {
        let now = Date()
        let connecting = "Connecting to 192.0.2.10:27015... (retry #1)"
        let cases: [(lines: [String], outcome: JoinOutcome, badge: SteamBadge?)] = [
            ([connecting, "Spooling demo header."], .success, .accepted),
            ([connecting, "Server issued disconnect. Reason: Steam authentication required"], .rejected, .refused),
            ([connecting, "Connecting to 192.0.2.10:27015... (retry #2)", "Connection failed after 4 retries"], .unknown, nil),
        ]
        for item in cases {
            let broker = FakeSteamBroker()
            let flow = coordinator(runner: FakeGameLaunchRunner(), broker: broker,
                                   log: log(item.lines, start: now), now: now)
            let handle = try await join(flow)
            let outcome = await flow.finish(handle, addresses: ["192.0.2.10:27015"], dataRoot: dataRoot)
            XCTAssertEqual(outcome, item.outcome, item.lines.joined(separator: "|"))
            var memory = ServerIdentityMemory()
            memory.record(identity: .steamAuth, outcome: outcome, host: "192.0.2.10", port: 27015, at: now)
            XCTAssertEqual(memory.badge(host: "192.0.2.10", port: 27015), item.badge)
        }
    }

    func testLogReaderReasonTimeoutAndStaleBlocks() {
        let now = Date()
        let text = log(["Connecting to 192.0.2.10:27015...", "Server issued disconnect. Reason: banned from 198.51.100.7"],
                       start: now)
        guard case .disconnected(let reason)? = JoinLogReader.evidence(in: text, addresses: ["192.0.2.10:27015"]) else {
            return XCTFail("disconnect expected")
        }
        XCTAssertFalse(reason.contains("198.51.100.7"))
        // Another server's block, and a block older than the attempt, are no evidence.
        XCTAssertNil(JoinLogReader.evidence(in: text, addresses: ["192.0.2.99:27015"]))
        XCTAssertNil(JoinLogReader.evidence(in: text, addresses: ["192.0.2.10:27015"], notBefore: now.addingTimeInterval(3600)))
        XCTAssertNil(JoinLogReader.evidence(in: "nothing here", addresses: ["192.0.2.10:27015"]))
    }

    // MARK: §76.8.10 memory persistence and privacy

    func testMemoryPersistsAndHoldsNoPersonalData() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url.appendingPathComponent("home", isDirectory: true))
        let store = SteamIdentityStore(paths: paths)
        var memory = ServerIdentityMemory()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        memory.record(identity: .steamAuth, outcome: .success, host: "Play.Example.test", port: 27015, at: date)
        try store.saveMemory(memory)
        try store.saveEndpoint(endpoint)

        let reloaded = SteamIdentityStore(paths: paths)
        XCTAssertEqual(reloaded.loadMemory(), memory)
        XCTAssertEqual(reloaded.loadMemory().badge(host: "play.example.test", port: 27015), .accepted)
        XCTAssertEqual(reloaded.loadEndpoint(), endpoint)

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.identityMemoryFile)) as? [String: Any]
        let records = try XCTUnwrap(raw?["records"] as? [String: [String: Any]])
        XCTAssertEqual(Set(records.keys), ["play.example.test:27015"])
        XCTAssertEqual(Set(try XCTUnwrap(records.values.first).keys), ["outcomes", "lastIdentity", "lastAttemptAt"])
        XCTAssertEqual(raw?.keys.sorted(), ["records"])
    }

    @MainActor
    func testAnAppModelReopenedKeepsTheBadgeAndTheBrokerSettings() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.setSteamBroker(path: "/opt/broker/broker", port: 27500)
        let store = SteamIdentityStore(paths: AppPaths(home: env.home))
        var memory = ServerIdentityMemory()
        memory.record(identity: .steamAuth, outcome: .rejected, host: "192.0.2.10", port: 27015, at: Date())
        try store.saveMemory(memory)
        let reopened = env.makeModel()
        XCTAssertEqual(reopened.steamEndpoint, SteamBrokerEndpoint(host: "127.0.0.1", port: 27500,
                                                                   executablePath: "/opt/broker/broker"))
        XCTAssertEqual(reopened.identityMemory.badge(host: "192.0.2.10", port: 27015), .refused)
    }

    func testBadgeOnlyForTheSteamMethod() {
        var memory = ServerIdentityMemory()
        XCTAssertNil(memory.badge(host: "192.0.2.10", port: 27015))
        memory.record(identity: .standard, outcome: .success, host: "192.0.2.10", port: 27015, at: Date())
        XCTAssertNil(memory.badge(host: "192.0.2.10", port: 27015))
        memory.record(identity: .steamAuth, outcome: .unknown, host: "192.0.2.10", port: 27015, at: Date())
        XCTAssertNil(memory.badge(host: "192.0.2.10", port: 27015))
    }

    // MARK: §76.6 recommendation, §76.3 settings

    @MainActor
    func testSteamIsRecommendedOnGoldSrc48AndDisabledWithoutABroker() async throws {
        let env = try TestAppEnvironment()
        let broker = FakeSteamBroker()
        let model = env.makeModel { deps in
            deps.steamBrokerEnvironment = broker
            deps.steamBrokerControl = broker
            deps.steamSleep = { _ in }
        }
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertFalse(model.isSteamBrokerConfigured)             // no path → the entry is disabled with a hint
        XCTAssertFalse(model.recommendsSteamIdentity(id))
        model.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        XCTAssertTrue(model.isSteamBrokerConfigured)
        model.setSteamBroker(path: "  ", port: 27420)
        XCTAssertFalse(model.isSteamBrokerConfigured)
        model.setSteamBroker(path: "/opt/broker/broker", port: 99999)   // invalid port keeps the old one
        XCTAssertEqual(model.steamEndpoint.port, 27420)
        XCTAssertEqual(SteamBrokerEndpoint().port, 27420)
        XCTAssertEqual(SteamBrokerEndpoint().host, "127.0.0.1")
    }

    @MainActor
    func testSettingsStartStopOnlyStopsAnAppStartedBroker() async throws {
        let env = try TestAppEnvironment()
        let broker = FakeSteamBroker()
        let model = env.makeModel { deps in
            deps.steamBrokerEnvironment = broker
            deps.steamBrokerControl = broker
            deps.steamSleep = { _ in }
        }
        model.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        XCTAssertFalse(model.canStopSteamBroker)
        await model.startSteamBroker().value
        XCTAssertTrue(model.canStopSteamBroker)
        XCTAssertEqual(model.steamBrokerState, .listening)
        model.stopSteamBroker()
        XCTAssertEqual(broker.stopped, [4242])
        XCTAssertFalse(model.canStopSteamBroker)

        // A broker the user started: starting from Settings adopts nothing, stopping does nothing.
        let foreign = FakeSteamBroker()
        foreign.listening = true
        let other = env.makeModel { deps in
            deps.steamBrokerEnvironment = foreign
            deps.steamBrokerControl = foreign
        }
        other.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        await other.startSteamBroker().value
        XCTAssertFalse(other.canStopSteamBroker)
        other.stopSteamBroker()
        XCTAssertEqual(foreign.stopped, [])
    }

    // MARK: §76.7 CLI

    private func cliContext(runner: FakeGameLaunchRunner, broker: FakeSteamBroker, home: URL,
                            interactive: Bool = false, answer: Bool = true) -> CLIContext {
        let clock = TestClock()
        var context = CLIContext(version: "2.27.0", build: "56", paths: AppPaths(home: home), environment: [:],
                                 fileSystem: LocalFileSystem(), resolver: FakeAddressResolver(),
                                 udpTransport: FakeServer.healthy(clock: clock), now: { clock.now })
        context.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]), homeDirectory: home)
        context.gameLaunchRunner = runner
        context.steamBrokerEnvironment = broker
        context.gameProcessDetector = FakeGameDetector()
        context.prompt = CLIPrompt(isInteractive: interactive, ask: { _ in answer })
        return context
    }

    func testCLIParsesJoin() {
        XCTAssertEqual(CLIParser.parse(["join", "--server", "192.0.2.10:27016"]),
                       .success(.join(host: "192.0.2.10", port: 27016, identity: .standard, yes: false, json: false)))
        XCTAssertEqual(CLIParser.parse(["join", "--server", "192.0.2.10", "--identity", "steam-auth", "--yes", "--json"]),
                       .success(.join(host: "192.0.2.10", port: 27015, identity: .steamAuth, yes: true, json: true)))
        guard case .failure = CLIParser.parse(["join"]) else { return XCTFail() }
        guard case .failure = CLIParser.parse(["join", "--server", "192.0.2.10", "--identity", "steam"]) else { return XCTFail() }
        guard case .failure = CLIParser.parse(["join", "--server", "192.0.2.10", "--timeout", "3"]) else { return XCTFail() }
        XCTAssertEqual(JoinIdentity.standard.jsonName, "standard")
        XCTAssertEqual(JoinIdentity.steamAuth.jsonName, "steam_auth")
    }

    func testCLIJoinJSONCarriesTheIdentity() async throws {
        let temp = try TempDirectory()
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        let runner = FakeGameLaunchRunner()
        let broker = FakeSteamBroker()
        let standard = await CLIRunner.run(arguments: ["join", "--server", "192.0.2.10:27015", "--json"],
                                           context: cliContext(runner: runner, broker: broker, home: home))
        XCTAssertEqual(standard.exitCode, 0, standard.stderr)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(standard.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["identity"] as? String, "standard")
        XCTAssertEqual(runner.commands, [["/usr/bin/open", "-a", Self.app, "--args", "-game", "valve",
                                          "+set", "cl_ticket_generator", "revemu2013", "+connect", "192.0.2.10:27015"]])
    }

    func testCLISteamAuthNeedsAConfiguredBrokerAndConsent() async throws {
        let temp = try TempDirectory()
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        let runner = FakeGameLaunchRunner()
        let broker = FakeSteamBroker()
        let arguments = ["join", "--server", "192.0.2.10:27015", "--identity", "steam-auth", "--json"]
        // Not configured: a clear error, nothing runs.
        let missing = await CLIRunner.run(arguments: arguments, context: cliContext(runner: runner, broker: broker, home: home))
        XCTAssertEqual(missing.exitCode, CLIExit.usage)
        XCTAssertTrue(missing.stdout.contains("steamBrokerNotConfigured"))
        XCTAssertEqual(runner.commands, [])

        try SteamIdentityStore(paths: AppPaths(home: home)).saveEndpoint(endpoint)
        // Configured but the broker does not listen: the tool never starts it.
        let silent = await CLIRunner.run(arguments: arguments + ["--yes"],
                                         context: cliContext(runner: runner, broker: broker, home: home))
        XCTAssertEqual(silent.exitCode, CLIExit.network)
        XCTAssertEqual(broker.started, [])
        broker.listening = true
        // No terminal and no --yes: not confirmed.
        let unconfirmed = await CLIRunner.run(arguments: arguments, context: cliContext(runner: runner, broker: broker, home: home))
        XCTAssertEqual(unconfirmed.exitCode, CLIExit.usage)
        XCTAssertEqual(runner.commands, [])
        // A terminal answering "no" starts nothing; "yes" launches with the extra argument.
        let declined = await CLIRunner.run(arguments: arguments, context: cliContext(runner: runner, broker: broker, home: home,
                                                                                     interactive: true, answer: false))
        XCTAssertEqual(declined.exitCode, CLIExit.usage)
        XCTAssertEqual(runner.commands, [])
        let accepted = await CLIRunner.run(arguments: arguments, context: cliContext(runner: runner, broker: broker, home: home,
                                                                                     interactive: true, answer: true))
        XCTAssertEqual(accepted.exitCode, 0, accepted.stderr)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(accepted.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["identity"] as? String, "steam_auth")
        XCTAssertEqual(Array(runner.commands[0][6..<9]), steamTriple)
    }

    // MARK: D1 per-method memory

    func testStandardAttemptKeepsTheSteamBadgeAndViceVersa() {
        let host = "192.0.2.10"
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var memory = ServerIdentityMemory()
        memory.record(identity: .steamAuth, outcome: .success, host: host, port: 27015, at: t0)
        // A standard attempt (started, then undecided) leaves Steam ✓ alone.
        memory.noteAttempt(identity: .standard, host: host, port: 27015, at: t0 + 10)
        memory.record(identity: .standard, outcome: .unknown, host: host, port: 27015, at: t0 + 20)
        XCTAssertEqual(memory.badge(host: host, port: 27015), .accepted)
        XCTAssertEqual(memory.record(host: host, port: 27015)?.lastIdentity, .standard)
        XCTAssertEqual(memory.record(host: host, port: 27015)?.outcomes.steamAuth?.result, .success)
        // A Steam attempt does not erase the Standard result.
        memory.record(identity: .standard, outcome: .rejected, host: host, port: 27015, at: t0 + 30)
        memory.record(identity: .steamAuth, outcome: .rejected, host: host, port: 27015, at: t0 + 40)
        XCTAssertEqual(memory.record(host: host, port: 27015)?.outcomes.standard?.result, .rejected)
        XCTAssertEqual(memory.badge(host: host, port: 27015), .refused)
        // The badge comes only from the Steam slot.
        var standardOnly = ServerIdentityMemory()
        standardOnly.record(identity: .standard, outcome: .success, host: host, port: 27015, at: t0)
        XCTAssertNil(standardOnly.badge(host: host, port: 27015))
    }

    func testMemoryReadsTheOlderSchemaAndTreatsDamageAsEmpty() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url.appendingPathComponent("home", isDirectory: true))
        let old = """
        {"records":{"192.0.2.10:27015":{"lastIdentity":"steamAuth","lastOutcome":"success","lastAttemptAt":"2026-11-27T10:00:00Z"},
        "192.0.2.11:27015":{"lastIdentity":"standard","lastOutcome":"rejected","lastAttemptAt":"2026-11-27T11:00:00Z"}}}
        """
        try temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/identity-memory.json", old)
        let memory = SteamIdentityStore(paths: paths).loadMemory()
        XCTAssertEqual(memory.badge(host: "192.0.2.10", port: 27015), .accepted)
        XCTAssertNil(memory.record(host: "192.0.2.10", port: 27015)?.outcomes.standard)
        XCTAssertEqual(memory.record(host: "192.0.2.11", port: 27015)?.outcomes.standard?.result, .rejected)
        XCTAssertNil(memory.record(host: "192.0.2.11", port: 27015)?.outcomes.steamAuth)
        XCTAssertNil(memory.badge(host: "192.0.2.11", port: 27015))
        try temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/identity-memory.json", "{ damaged")
        XCTAssertEqual(SteamIdentityStore(paths: paths).loadMemory(), ServerIdentityMemory())
    }

    // MARK: D2 broker argument

    func testBrokerIsStartedWithTheConfiguredHostAndPort() async throws {
        let broker = FakeSteamBroker()
        let custom = SteamBrokerEndpoint(host: "127.0.0.1", port: 27555, executablePath: "/opt/broker/broker")
        let manager = SteamBrokerManager(environment: broker, control: broker, sleep: { _ in })
        _ = try await manager.prepare(custom)
        XCTAssertEqual(broker.startAddresses, ["127.0.0.1:27555"])
        // §78.4.4 the broker runs in the folder of its binary (it finds its library next to itself).
        XCTAssertEqual(broker.startDirectories, ["/opt/broker"])
        XCTAssertEqual(SteamBrokerManager.workingDirectory(forBinary: "/opt/broker/broker"), "/opt/broker")
        XCTAssertEqual(SteamBrokerEndpoint(executablePath: "/x").addressArgument, "127.0.0.1:27420")
        // A host that is not a plain name / IP is never passed.
        var odd = custom
        odd.host = "127.0.0.1; rm -rf /"
        XCTAssertNil(odd.addressArgument)
        let fresh = FakeSteamBroker()
        do {
            _ = try await SteamBrokerManager(environment: fresh, control: fresh, sleep: { _ in }).prepare(odd)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GameLaunchError, .steamBrokerStartFailed)
        }
        XCTAssertEqual(fresh.started, [])
    }

    // MARK: D3 quit cleanup

    @MainActor
    func testQuitStopsOnlyBrokersTheAppStarted() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let own = FakeSteamBroker()
        let model = env.makeModel(game: FakeGameDetector(running: true)) { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]), homeDirectory: self.home)
            deps.gameLaunchRunner = runner
            deps.steamBrokerEnvironment = own
            deps.steamBrokerControl = own
            deps.steamSleep = { _ in }
        }
        model.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        let join = try XCTUnwrap(model.joinGame(id, identity: .steamAuth))
        for _ in 0..<50 where model.steamPrompt == nil { await Task.yield() }
        model.answerSteamPrompt(true)               // consent
        for _ in 0..<50 where model.steamPrompt == nil { await Task.yield() }
        model.answerSteamPrompt(true)               // the game is running: replace it
        await join.value
        XCTAssertEqual(own.started.count, 1)
        XCTAssertEqual(own.stopped, [])             // the game still runs
        model.releaseOwnedSteamBrokers()            // the app quits
        XCTAssertEqual(own.stopped, [4242])
        model.releaseOwnedSteamBrokers()
        XCTAssertEqual(own.stopped, [4242])         // not stopped twice

        let foreign = FakeSteamBroker()
        foreign.listening = true
        let other = env.makeModel { deps in
            deps.steamBrokerEnvironment = foreign
            deps.steamBrokerControl = foreign
        }
        other.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        await other.startSteamBroker().value
        other.releaseOwnedSteamBrokers()
        XCTAssertEqual(foreign.stopped, [])
    }

    // MARK: §77

    func testCandidateOrderAndFiltering() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let all = SteamBrokerCandidates.paths(home: home)
        XCTAssertEqual(all, ["/Users/test/Documents/steam-broker/steam-broker",
                             "/Users/test/Applications/Steam Broker.app/Contents/MacOS/steam-broker",
                             "/opt/homebrew/bin/steam-broker", "/usr/local/bin/steam-broker"])
        let broker = FakeSteamBroker()
        XCTAssertEqual(SteamBrokerCandidates.find(home: home, environment: broker), [])
        broker.executableFiles = [all[3], all[1]]
        XCTAssertEqual(SteamBrokerCandidates.find(home: home, environment: broker), [all[1], all[3]])
        // No file system access at all: nothing found, no crash.
        XCTAssertEqual(SteamBrokerCandidates.find(home: home, environment: UnavailableSteamBrokerEnvironment()), [])
    }

    func testRealProbeAcceptsOnlyExecutableRegularFiles() throws {
        let temp = try TempDirectory()
        let exe = try temp.write("bin/steam-broker", "#!/bin/sh\n")
        let plain = try temp.write("bin/plain", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        let link = temp.url.appendingPathComponent("bin/link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe.path)
        let folder = temp.url.appendingPathComponent("bin/dir").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let probe = SystemSteamBrokerEnvironment()
        XCTAssertTrue(probe.isExecutableRegularFile(exe.path))
        XCTAssertFalse(probe.isExecutableRegularFile(plain.path))   // not executable
        XCTAssertFalse(probe.isExecutableRegularFile(link))         // symbolic link
        XCTAssertFalse(probe.isExecutableRegularFile(folder))       // folder
        XCTAssertFalse(probe.isExecutableRegularFile(temp.url.appendingPathComponent("missing").path))
    }

    @MainActor
    func testUseFoundBrokerNeedsConsentAndNeverOverwrites() throws {
        let env = try TestAppEnvironment()
        let broker = FakeSteamBroker()
        let found = SteamBrokerCandidates.paths(home: env.home)[2]
        broker.executableFiles = [found, "/usr/local/bin/steam-broker"]
        let model = env.makeModel { deps in
            deps.steamBrokerEnvironment = broker
            deps.steamBrokerControl = broker
        }
        model.discoverSteamBroker()
        XCTAssertEqual(model.steamDiscovery, .available(found))
        XCTAssertFalse(model.useFoundSteamBroker(confirmed: false))        // no consent: nothing written
        XCTAssertNil(model.steamEndpoint.executablePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths(home: env.home).steamBrokerFile.path))
        XCTAssertTrue(model.useFoundSteamBroker(confirmed: true))
        XCTAssertEqual(model.steamEndpoint.executablePath, found)
        // A path is set now: discovery informs only and never overwrites.
        model.setSteamBroker(path: "/my/own/broker", port: 27420)
        XCTAssertEqual(model.steamDiscovery, .other(found))
        XCTAssertFalse(model.useFoundSteamBroker(confirmed: true))
        XCTAssertEqual(model.steamEndpoint.executablePath, "/my/own/broker")
        broker.executableFiles = []
        model.discoverSteamBroker()
        XCTAssertEqual(model.steamDiscovery, .none)
    }

    func testMenuEntryVariants() throws {
        let hint = SteamMenuItem.make(pathUsable: false, state: .notConfigured, recommended: false)
        XCTAssertFalse(hint.isEnabled)
        XCTAssertEqual(hint.help, L10n.text(.steamJoinDisabledHint))
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(SteamMenuItem.make(pathUsable: false, state: .notConfigured, recommended: false).help,
                           "Ayarlar › Bağlantı Yolları’ndan Steam broker yolunu seçin")
            XCTAssertTrue(SteamMenuItem.make(pathUsable: true, state: .notRunning, recommended: false).title
                .hasPrefix("Steam kimliğiyle (broker’ı başlat)"))
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(SteamMenuItem.make(pathUsable: false, state: .notConfigured, recommended: false).help,
                           "Choose the Steam broker path in Settings › Connection Paths")
        }
        let start = SteamMenuItem.make(pathUsable: true, state: .notRunning, recommended: true)
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.startsBroker)
        XCTAssertTrue(start.title.contains(L10n.text(.steamJoinSteamAuthStart)))
        XCTAssertTrue(start.title.contains(L10n.text(.steamJoinRecommended)))
        let running = SteamMenuItem.make(pathUsable: true, state: .listening, recommended: false)
        XCTAssertTrue(running.isEnabled)
        XCTAssertFalse(running.startsBroker)
        XCTAssertTrue(running.title.hasPrefix(L10n.text(.steamJoinSteamAuth)))
        XCTAssertFalse(running.title.contains(L10n.text(.steamJoinSteamAuthStart)))
    }

    @MainActor
    func testModelMenuStartsTheBrokerOnlyAfterConsentAndShowsStartFailure() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let broker = FakeSteamBroker()
        let model = env.makeModel { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]), homeDirectory: self.home)
            deps.gameLaunchRunner = runner
            deps.steamBrokerEnvironment = broker
            deps.steamBrokerControl = broker
            deps.steamSleep = { _ in }
        }
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertFalse(model.steamMenuItem(for: id).isEnabled)            // no path yet
        model.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        await model.refreshSteamBrokerState().value
        XCTAssertTrue(model.steamMenuItem(for: id).startsBroker)         // path set, broker down

        let declined = try XCTUnwrap(model.joinGame(id, identity: .steamAuth))
        for _ in 0..<50 where model.steamPrompt == nil { await Task.yield() }
        XCTAssertEqual(broker.started, [])                                // nothing before the consent
        model.answerSteamPrompt(false)
        await declined.value
        XCTAssertEqual(broker.started, [])

        let accepted = try XCTUnwrap(model.joinGame(id, identity: .steamAuth))
        for _ in 0..<50 where model.steamPrompt == nil { await Task.yield() }
        model.answerSteamPrompt(true)
        await accepted.value
        XCTAssertEqual(broker.startAddresses, ["127.0.0.1:27420"])
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertNil(model.joinError)

        // A start failure is shown, with the pointer to the settings; the app does not crash.
        let failing = FakeSteamBroker()
        failing.startFails = true
        let other = env.makeModel { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]), homeDirectory: self.home)
            deps.gameLaunchRunner = runner
            deps.steamBrokerEnvironment = failing
            deps.steamBrokerControl = failing
            deps.steamSleep = { _ in }
        }
        other.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        let otherID = try XCTUnwrap(other.servers.first?.id ?? { other.addServer(ServerDraft(label: "B", host: "192.0.2.11")); return other.servers.first?.id }())
        let task = try XCTUnwrap(other.joinGame(otherID, identity: .steamAuth))
        for _ in 0..<50 where other.steamPrompt == nil { await Task.yield() }
        other.answerSteamPrompt(true)
        await task.value
        XCTAssertEqual(other.joinError, .steamBrokerStartFailed)
        XCTAssertEqual(runner.commands.count, 1)                          // no second launch
        XCTAssertTrue(other.joinError?.isSteamBrokerProblem == true)
        let text = GameLaunchText.error(.steamBrokerStartFailed)
        XCTAssertTrue(text.contains(L10n.text(.steamErrorStart)))
        XCTAssertTrue(text.contains(L10n.text(.steamErrorSettingsHint)))
    }

    // MARK: §79

    func testStalenessFromProcessStartTimes() {
        let broker = FakeSteamBroker()
        broker.listening = true
        let manager = SteamBrokerManager(environment: broker, control: broker, sleep: { _ in })
        broker.steamStart = Date(timeIntervalSince1970: 5_000)
        broker.brokerStart = Date(timeIntervalSince1970: 4_000)        // broker older than Steam
        XCTAssertEqual(manager.state(endpoint), .stale)
        broker.brokerStart = Date(timeIntervalSince1970: 6_000)        // broker newer: fresh
        XCTAssertEqual(manager.state(endpoint), .listening)
        broker.steamRunning = false                                    // no Steam at all: existing behaviour
        XCTAssertEqual(manager.state(endpoint), .steamSessionMissing)
        // Without readable start times the "Steam quit was seen" hint decides.
        broker.steamRunning = true
        broker.brokerStart = nil
        XCTAssertEqual(manager.state(endpoint, markedStale: true), .stale)
        XCTAssertEqual(manager.state(endpoint, markedStale: false), .listening)
        XCTAssertTrue(SteamBrokerManager.isStale(brokerStart: Date(timeIntervalSince1970: 1), steamStart: Date(timeIntervalSince1970: 2), markedStale: false))
        XCTAssertFalse(SteamBrokerManager.isStale(brokerStart: Date(timeIntervalSince1970: 3), steamStart: Date(timeIntervalSince1970: 2), markedStale: true))
    }

    func testMenuVariantForAStaleBroker() {
        let stale = SteamMenuItem.make(pathUsable: true, state: .stale, recommended: false)
        XCTAssertTrue(stale.isEnabled)
        XCTAssertTrue(stale.startsBroker)
        XCTAssertTrue(stale.title.hasPrefix(L10n.text(.steamJoinSteamAuthRestart)))
        let fresh = SteamMenuItem.make(pathUsable: true, state: .listening, recommended: false)
        XCTAssertFalse(fresh.title.contains(L10n.text(.steamJoinSteamAuthRestart)))
        XCTAssertFalse(fresh.startsBroker)
        // Steam closed: not the restart variant.
        XCTAssertFalse(SteamMenuItem.make(pathUsable: true, state: .steamSessionMissing, recommended: false)
            .title.contains(L10n.text(.steamJoinSteamAuthRestart)))
    }

    @MainActor
    private func staleModel(_ env: TestAppEnvironment, broker: FakeSteamBroker, runner: FakeGameLaunchRunner = FakeGameLaunchRunner()) -> AppModel {
        let model = env.makeModel { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]), homeDirectory: self.home)
            deps.gameLaunchRunner = runner
            deps.steamBrokerEnvironment = broker
            deps.steamBrokerControl = broker
            deps.steamSleep = { _ in }
        }
        model.setSteamBroker(path: "/opt/broker/broker", port: 27420)
        return model
    }

    @MainActor
    func testSteamQuitStopsOnlyTheAppsBrokerAndStartsNothing() async throws {
        let env = try TestAppEnvironment()
        let own = FakeSteamBroker()
        let model = staleModel(env, broker: own)
        await model.startSteamBroker().value                         // the app starts it
        XCTAssertEqual(own.started.count, 1)
        model.steamClientDidTerminate()
        XCTAssertEqual(own.stopped, [4242])                          // the app's broker stops
        model.steamClientDidLaunch()
        XCTAssertEqual(own.started.count, 1)                         // nothing is started automatically

        let foreign = FakeSteamBroker()
        foreign.listening = true                                     // the user's own broker
        foreign.steamStart = Date(timeIntervalSince1970: 5_000)
        foreign.brokerStart = Date(timeIntervalSince1970: 4_000)
        let other = staleModel(env, broker: foreign)
        await other.startSteamBroker().value                         // adopts nothing
        other.steamClientDidTerminate()
        XCTAssertEqual(foreign.stopped, [])                          // not stopped, only marked stale
        await other.refreshSteamBrokerState().value
        XCTAssertEqual(other.steamBrokerState, .stale)
        XCTAssertEqual(foreign.started, [])
    }

    @MainActor
    func testSettingsRestartReplacesAStaleBrokerTheAppStartedWithTheHostPortArgument() async throws {
        let env = try TestAppEnvironment()
        let broker = FakeSteamBroker()
        let model = staleModel(env, broker: broker)
        await model.startSteamBroker().value
        XCTAssertEqual(broker.startAddresses, ["127.0.0.1:27420"])
        // Steam restarted after the broker: stale.
        broker.steamStart = Date(timeIntervalSince1970: 9_000)
        broker.brokerStart = Date(timeIntervalSince1970: 3_000)
        await model.refreshSteamBrokerState().value
        XCTAssertEqual(model.steamBrokerState, .stale)
        XCTAssertEqual(broker.started.count, 1)                      // nothing happened by itself
        await model.restartSteamBroker().value
        XCTAssertEqual(broker.stopped, [4242])                       // the old one (the app's) was stopped
        XCTAssertEqual(broker.startAddresses, ["127.0.0.1:27420", "127.0.0.1:27420"])
        XCTAssertEqual(broker.startDirectories, ["/opt/broker", "/opt/broker"])
        XCTAssertNil(model.steamSettingsError)
        XCTAssertEqual(model.steamBrokerState, .listening)
    }

    @MainActor
    func testRestartErrorsAreShownAndANonOwnedStaleBrokerIsNotReplaced() async throws {
        let env = try TestAppEnvironment()
        let foreign = FakeSteamBroker()
        foreign.listening = true
        foreign.steamStart = Date(timeIntervalSince1970: 5_000)
        foreign.brokerStart = Date(timeIntervalSince1970: 4_000)
        let model = staleModel(env, broker: foreign)
        await model.restartSteamBroker().value
        XCTAssertEqual(model.steamSettingsError, .steamBrokerStale)
        XCTAssertEqual(foreign.stopped, [])
        XCTAssertEqual(foreign.started, [])
        let text = GameLaunchText.error(.steamBrokerStale)
        XCTAssertTrue(text.contains(L10n.text(.steamErrorStale)) && text.contains(L10n.text(.steamErrorSettingsHint)))
        XCTAssertTrue(GameLaunchError.steamBrokerStale.isSteamBrokerProblem)

        // The app's own stale broker that cannot be started again: a clear error, no crash.
        let own = FakeSteamBroker()
        let other = staleModel(env, broker: own)
        await other.startSteamBroker().value
        own.steamStart = Date(timeIntervalSince1970: 9_000)
        own.brokerStart = Date(timeIntervalSince1970: 3_000)
        own.startFails = true
        await other.restartSteamBroker().value
        XCTAssertEqual(other.steamSettingsError, .steamBrokerStartFailed)
    }

    @MainActor
    func testJoinWithAStaleBrokerAsksConsentThenRestartsAndConnects() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let broker = FakeSteamBroker()
        let model = staleModel(env, broker: broker, runner: runner)
        await model.startSteamBroker().value
        broker.steamStart = Date(timeIntervalSince1970: 9_000)
        broker.brokerStart = Date(timeIntervalSince1970: 3_000)
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.refreshSteamBrokerState().value
        XCTAssertTrue(model.steamMenuItem(for: id).title.contains(L10n.text(.steamJoinSteamAuthRestart)))

        let join = try XCTUnwrap(model.joinGame(id, identity: .steamAuth))
        for _ in 0..<50 where model.steamPrompt == nil { await Task.yield() }
        XCTAssertEqual(broker.started.count, 1)                      // nothing before the consent
        model.answerSteamPrompt(true)
        await join.value
        XCTAssertEqual(broker.stopped.first, 4242)                    // the stale broker (the app's) was stopped first
        XCTAssertEqual(broker.started.count, 2)
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(Array(runner.commands[0][6..<9]), steamTriple)
    }
}

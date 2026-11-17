import XCTest
@testable import PlayerIdentity

// MARK: - Fakes

/// Records the app launches; `failure` makes every launch throw.
final class FakeAppLauncher: AppLaunching, @unchecked Sendable {
    struct Call: Equatable {
        let app: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    var calls: [Call] { lock.withLock { recorded } }

    func open(app: URL, arguments: [String]) async throws {
        lock.withLock { recorded.append(Call(app: app, arguments: arguments)) }
        if let failure { throw failure }
    }
}

/// Modification date of the engine log: `before` until `appearsAfter` lookups were made, then `after`.
final class FakeFileDating: FileDating, @unchecked Sendable {
    private let lock = NSLock()
    private var lookups = 0
    private let before: Date?
    private let after: Date?
    private let appearsAfter: Int
    private(set) var urls: [URL] = []

    init(before: Date? = nil, after: Date?, appearsAfter: Int) {
        self.before = before
        self.after = after
        self.appearsAfter = appearsAfter
    }

    var lookupCount: Int { lock.withLock { lookups } }

    func modificationDate(_ url: URL) -> Date? {
        lock.withLock {
            urls.append(url)
            defer { lookups += 1 }
            return lookups >= appearsAfter ? after : before
        }
    }
}

/// Records Spotlight calls; `failing` makes every call throw.
final class FakeSpotlightIndexer: SpotlightIndexing, @unchecked Sendable {
    enum Call: Equatable {
        case index([SpotlightServerItem])
        case delete([String])
        case deleteAll
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String { "indexUnavailable" }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var failing = false

    var calls: [Call] { lock.withLock { recorded } }

    func reset() { lock.withLock { recorded.removeAll() } }

    private func record(_ call: Call) throws {
        let fail = lock.withLock { () -> Bool in
            recorded.append(call)
            return failing
        }
        if fail { throw Failure() }
    }

    func index(_ items: [SpotlightServerItem]) async throws { try record(.index(items)) }
    func delete(identifiers: [String]) async throws { try record(.delete(identifiers)) }
    func deleteAll() async throws { try record(.deleteAll) }
}

private func english<T>(_ body: () throws -> T) throws -> T {
    try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en")), operation: body)
}

// MARK: - §67.2 `-condebug` launcher

final class CondebugLaunchTests: XCTestCase {
    private let clock = TestClock()
    private let app = "/Applications/Xash3D-FWGS.app"
    private let root = URL(fileURLWithPath: "/tmp/pi-data", isDirectory: true)

    private func launcher(installed: Bool = true, running: Bool = false, launcher: FakeAppLauncher = FakeAppLauncher(),
                          files: FakeFileDating) -> CondebugLauncher {
        CondebugLauncher(locator: GameAppLocator(fileSystem: FakeDirectories(directories: installed ? [app] : []),
                                                 homeDirectory: URL(fileURLWithPath: "/tmp/pi-home")),
                         detector: FakeGameDetector(running: running), launcher: launcher, files: files,
                         sleeper: FakeSleeper(clock: clock))
    }

    func testArgumentsAndLogPath() {
        XCTAssertEqual(CondebugLauncher.arguments(gamedir: nil), ["-condebug"])
        XCTAssertEqual(CondebugLauncher.arguments(gamedir: "valve"), ["-condebug"])
        XCTAssertEqual(CondebugLauncher.arguments(gamedir: "cstrike"), ["-game", "cstrike", "-condebug"])
        XCTAssertEqual(CondebugLauncher.arguments(gamedir: "../etc"), ["-condebug"], "only plain folder names")
        XCTAssertEqual(CondebugLauncher.logURL(dataRoot: root, gamedir: "cstrike").path, "/tmp/pi-data/cstrike/qconsole.log")
        XCTAssertEqual(CondebugLauncher.logURL(dataRoot: root, gamedir: nil).path, "/tmp/pi-data/valve/qconsole.log")
    }

    func testLaunchStartsXashWithCondebugAndDetectsTheLog() async {
        let apps = FakeAppLauncher()
        let files = FakeFileDating(after: clock.now, appearsAfter: 4)   // missing before; appears on the 4th poll
        let start = clock.now
        let progress = ProgressLog()
        let state = await launcher(launcher: apps, files: files).launch(dataRoot: root, gamedir: "cstrike") { state in
            progress.append(state)
        }
        XCTAssertEqual(state, .active("qconsole.log"))
        XCTAssertEqual(apps.calls, [FakeAppLauncher.Call(app: URL(fileURLWithPath: app, isDirectory: true),
                                                         arguments: ["-game", "cstrike", "-condebug"])])
        XCTAssertEqual(progress.states, [.waiting])
        XCTAssertEqual(Set(files.urls.map(\.path)), ["/tmp/pi-data/cstrike/qconsole.log"])
        XCTAssertEqual(clock.now.timeIntervalSince(start), 3, accuracy: 0.001, "polled once a second")
    }

    func testAnUnchangedOldLogIsNotEnoughAndTheWaitEndsAfterTenSeconds() async {
        let old = clock.now.addingTimeInterval(-3600)
        let start = clock.now
        let state = await launcher(files: FakeFileDating(before: old, after: old, appearsAfter: 0))
            .launch(dataRoot: root, gamedir: nil)
        XCTAssertEqual(state, .noLog("valve/qconsole.log"))
        XCTAssertEqual(clock.now.timeIntervalSince(start), CondebugLauncher.logWait, accuracy: 0.001)

        // The same file written after the start counts.
        let written = await launcher(files: FakeFileDating(before: old, after: clock.now, appearsAfter: 2))
            .launch(dataRoot: root, gamedir: "valve")
        XCTAssertEqual(written, .active("qconsole.log"))
    }

    func testRunningGameMissingAppAndLaunchErrorStartNothing() async {
        let apps = FakeAppLauncher()
        let files = FakeFileDating(after: nil, appearsAfter: 0)
        let running = launcher(running: true, launcher: apps, files: files)
        XCTAssertEqual(running.blocker(), .gameRunning)
        let blocked = await running.launch(dataRoot: root, gamedir: nil)
        XCTAssertEqual(blocked, .failed(.gameRunning))
        let missing = launcher(installed: false, launcher: apps, files: files)
        XCTAssertEqual(missing.blocker(), .appNotFound)
        let notInstalled = await missing.launch(dataRoot: root, gamedir: nil)
        XCTAssertEqual(notInstalled, .failed(.appNotFound))
        XCTAssertEqual(apps.calls, [], "nothing is started")
        XCTAssertNil(launcher(files: files).blocker())

        let failing = FakeAppLauncher(failure: CommandError.launchFailed)
        let start = clock.now
        guard case .failed(.launchFailed(let reason)) = await launcher(launcher: failing, files: files)
            .launch(dataRoot: root, gamedir: nil) else { return XCTFail("expected a launch failure") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(failing.calls.count, 1)
        XCTAssertEqual(clock.now, start, "no waiting after a failed start")
    }

    @MainActor
    func testModelShowsTheResultLogsFailuresAndBlocksWhileTheGameRuns() async throws {
        let env = try TestAppEnvironment()
        let failing = FakeAppLauncher(failure: CommandError.launchFailed)
        let model = env.makeModel { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [self.app]), homeDirectory: env.home)
            deps.appLauncher = failing
            deps.fileDating = FakeFileDating(after: nil, appearsAfter: 0)
        }
        XCTAssertNil(model.condebugBlocker)
        await model.launchGameWithLogging()?.value
        guard case .failed(.launchFailed)? = model.condebugState else { return XCTFail("\(String(describing: model.condebugState))") }
        XCTAssertEqual(model.errorLog.entries.map(\.area), [.launch])
        XCTAssertTrue(model.errorLog.entries.first?.message.hasPrefix("condebug: launchFailed") == true)
        try english {
            let lines = CondebugLaunchRow.statusLines(blocker: nil, state: model.condebugState).map(\.text)
            XCTAssertEqual(lines.count, 1)
            XCTAssertTrue(lines[0].hasPrefix("The game could not be launched:"), lines[0])
        }

        // Success: Xash3D started with -condebug, the log appears → "Logging is on".
        let apps = FakeAppLauncher()
        let working = env.makeModel { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [self.app]), homeDirectory: env.home)
            deps.appLauncher = apps
            deps.fileDating = FakeFileDating(after: env.clock.now, appearsAfter: 2)
        }
        await working.launchGameWithLogging()?.value
        XCTAssertEqual(working.condebugState, .active("qconsole.log"))
        XCTAssertEqual(apps.calls.map(\.arguments), [["-condebug"]])
        XCTAssertEqual(working.errorLog.entries, [])

        // The game runs: the button is disabled and says why; not installed: also disabled.
        let game = FakeGameDetector(running: true)
        let busy = env.makeModel(game: game) { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [self.app]), homeDirectory: env.home)
        }
        await busy.refresh().value
        XCTAssertEqual(busy.condebugBlocker, .gameRunning)
        try english {
            XCTAssertEqual(CondebugLaunchRow.statusLines(blocker: busy.condebugBlocker, state: nil).map(\.text),
                           ["The game is running; quit it first to launch it with logging."])
        }
        XCTAssertEqual(env.makeModel().condebugBlocker, .appNotFound)
    }
}

/// Collects progress states of a launch.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CondebugState] = []
    var states: [CondebugState] { lock.withLock { values } }
    func append(_ state: CondebugState) { lock.withLock { values.append(state) } }
}

// MARK: - §67.3 launch summary

final class LaunchSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private let utc = TimeZone(identifier: "UTC")!

    private func run(_ id: UUID, _ verdict: DiagnosisVerdict, daysAgo: Double) -> HistoryEntry {
        HistoryEntry(ts: now.addingTimeInterval(-daysAgo * day), kind: .diagnose, serverID: id, host: "x", new: verdict.rawValue)
    }

    func testThresholdWindowAndVerdicts() throws {
        let server = ServerEntry(label: "Zombie TR", host: "198.51.100.20")
        let id = server.id
        XCTAssertNil(LaunchSummary.make(entries: [], servers: [server], now: now), "no data → no card")
        XCTAssertNil(LaunchSummary.make(entries: [run(id, .cidBanned, daysAgo: 1)], servers: [server], now: now), "1 ban → no card")
        XCTAssertNil(LaunchSummary.make(entries: [run(id, .cidBanned, daysAgo: 1), run(id, .ipBanned, daysAgo: 8),
                                                  run(id, .timeout, daysAgo: 1), run(id, .noBan, daysAgo: 0)],
                                        servers: [server], now: now), "older and non-ban runs do not count")
        let summary = try XCTUnwrap(LaunchSummary.make(entries: [run(id, .cidBanned, daysAgo: 6), run(id, .rangeBanned, daysAgo: 0.5)],
                                                       servers: [server], now: now))
        XCTAssertEqual(summary, LaunchSummary(serverID: id, name: "Zombie TR", bans: 2))
        try english { XCTAssertEqual(summary.text, "Zombie TR: 2 bans in the last 7 days") }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(summary.text, "Zombie TR: son 7 günde 2 ban")
        }
        // A server removed from the list is not named.
        XCTAssertNil(LaunchSummary.make(entries: [run(id, .cidBanned, daysAgo: 1), run(id, .cidBanned, daysAgo: 2)],
                                        servers: [], now: now))
    }

    func testTheMostBannedServerIsChosenTiesKeepTheListOrder() throws {
        let a = ServerEntry(label: "A", host: "198.51.100.1")
        let b = ServerEntry(label: "", host: "2001:db8::5", port: 27016)
        let c = ServerEntry(label: "C", host: "198.51.100.3")
        let entries = [run(a.id, .ipBanned, daysAgo: 1), run(a.id, .ipBanned, daysAgo: 2),
                       run(b.id, .cidBanned, daysAgo: 1), run(b.id, .cidBanned, daysAgo: 2), run(b.id, .rangeBanned, daysAgo: 3),
                       run(c.id, .ipBanned, daysAgo: 1), run(c.id, .ipBanned, daysAgo: 2), run(c.id, .ipBanned, daysAgo: 3)]
        XCTAssertEqual(LaunchSummary.make(entries: entries, servers: [a, b, c], now: now),
                       LaunchSummary(serverID: b.id, name: "[2001:db8::5]:27016", bans: 3), "most bans; first on a tie; host:port without label")
        XCTAssertEqual(LaunchSummary.make(entries: entries, servers: [c, b, a], now: now)?.serverID, c.id)
    }

    func testDismissalHoldsForTheDayOnly() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LaunchSummaryTests-\(UUID().uuidString)"))
        XCTAssertFalse(LaunchSummary.isDismissed(defaults: defaults, now: now, timeZone: utc))
        LaunchSummary.dismiss(defaults: defaults, now: now, timeZone: utc)
        XCTAssertTrue(LaunchSummary.isDismissed(defaults: defaults, now: now.addingTimeInterval(3600), timeZone: utc))
        XCTAssertFalse(LaunchSummary.isDismissed(defaults: defaults, now: now.addingTimeInterval(day), timeZone: utc))
    }

    @MainActor
    func testModelCardDismissNextDayAndDetailsTarget() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "Quiet", host: "198.51.100.1"))
        model.addServer(ServerDraft(label: "Zombie TR", host: "198.51.100.20"))
        model.save()
        let zombie = try XCTUnwrap(model.servers.last?.id)
        let quiet = try XCTUnwrap(model.servers.first?.id)
        let now = env.clock.now
        await model.evaluateLaunchSummary()
        XCTAssertNil(model.launchSummary, "no data")
        XCTAssertNil(model.openLaunchSummaryDetails())

        try env.historyStore.append([
            HistoryEntry(ts: now.addingTimeInterval(-3600), kind: .diagnose, serverID: zombie, new: "cidBanned"),
            HistoryEntry(ts: now.addingTimeInterval(-7200), kind: .diagnose, serverID: zombie, new: "ipBanned"),
            HistoryEntry(ts: now.addingTimeInterval(-60), kind: .diagnose, serverID: quiet, new: "ipBanned"),
        ])
        await model.evaluateLaunchSummary()
        XCTAssertEqual(model.launchSummary, LaunchSummary(serverID: zombie, name: "Zombie TR", bans: 2))
        XCTAssertEqual(model.openLaunchSummaryDetails(), zombie)
        XCTAssertEqual(model.requestedServerDetail, zombie, "Details opens the server details (trend)")

        model.dismissLaunchSummary()
        XCTAssertNil(model.launchSummary)
        env.clock.advance(60)
        await model.evaluateLaunchSummary()
        XCTAssertNil(model.launchSummary, "hidden for the rest of the day")
        let reopened = env.makeModel()
        XCTAssertEqual(reopened.servers.count, 2)
        await reopened.evaluateLaunchSummary()
        XCTAssertNil(reopened.launchSummary, "the dismissal is kept in UserDefaults")

        env.clock.advance(24 * 60 * 60)
        try env.historyStore.append([
            HistoryEntry(ts: env.clock.now.addingTimeInterval(-60), kind: .diagnose, serverID: zombie, new: "rangeBanned"),
        ])
        await model.evaluateLaunchSummary()
        XCTAssertEqual(model.launchSummary?.serverID, zombie, "evaluated again the next day")
        XCTAssertEqual(model.launchSummary?.bans, 3)
    }
}

// MARK: - §67.4 Spotlight

final class SpotlightIndexTests: XCTestCase {
    private let cid = "d9de0eb4419608a8423241430581e91c"

    func testItemTitleAndShortenedCID() {
        var entry = ServerEntry(label: "Zombie TR", host: "198.51.100.20")
        entry.cid = cid
        XCTAssertEqual(SpotlightServers.item(for: entry),
                       SpotlightServerItem(identifier: entry.id.uuidString, title: "Zombie TR",
                                           summary: "198.51.100.20:27015 · d9de0eb4…e91c"))
        let unnamed = ServerEntry(label: "  ", host: "2001:db8::1", port: 27016)
        XCTAssertEqual(SpotlightServers.item(for: unnamed).title, "[2001:db8::1]:27016")
        XCTAssertEqual(SpotlightServers.item(for: unnamed).summary, "[2001:db8::1]:27016", "no CID yet")
        XCTAssertEqual(SpotlightServers.domainIdentifier, "tr.ercanatay.playeridentity.servers")
    }

    func testChangesAndOpenMapping() {
        let a = ServerEntry(label: "A", host: "198.51.100.1")
        var b = ServerEntry(label: "B", host: "198.51.100.2")
        let indexed = Dictionary(uniqueKeysWithValues: [a, b].map { ($0.id.uuidString, SpotlightServers.item(for: $0)) })
        XCTAssertTrue(SpotlightServers.changes(indexed: indexed, servers: [a, b]).upsert.isEmpty)
        b.label = "B2"
        b.favorite = true
        let c = ServerEntry(label: "C", host: "198.51.100.3")
        let changes = SpotlightServers.changes(indexed: indexed, servers: [b, c])
        XCTAssertEqual(changes.upsert.map(\.title), ["B2", "C"])
        XCTAssertEqual(changes.remove, [a.id.uuidString])

        XCTAssertEqual(SpotlightServers.serverID(identifier: b.id.uuidString, servers: [a, b]), b.id)
        XCTAssertNil(SpotlightServers.serverID(identifier: c.id.uuidString, servers: [a, b]), "deleted server")
        XCTAssertNil(SpotlightServers.serverID(identifier: "not-a-uuid", servers: [a, b]))
        XCTAssertNil(SpotlightServers.serverID(identifier: nil, servers: [a, b]))
    }

    @MainActor
    func testModelKeepsTheIndexInStep() async throws {
        let env = try TestAppEnvironment()
        let indexer = FakeSpotlightIndexer()
        let model = env.makeModel { $0.spotlightIndexer = indexer }
        await model.waitForSpotlight()
        XCTAssertEqual(indexer.calls, [.deleteAll, .index([])], "launch: the domain is replaced")
        indexer.reset()

        model.addServer(ServerDraft(label: "Zombie TR", host: "198.51.100.20"))
        await model.waitForSpotlight()
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertEqual(indexer.calls, [.index([SpotlightServerItem(identifier: id.uuidString, title: "Zombie TR",
                                                                   summary: "198.51.100.20:27015")])])
        indexer.reset()

        model.setFavorite(true, for: id)
        await model.waitForSpotlight()
        XCTAssertEqual(indexer.calls, [], "unrelated changes do not touch the index")

        var draft = ServerDraft(entry: try XCTUnwrap(model.servers.first))
        draft.label = "Zombie EU"
        model.updateServer(id: id, with: draft)
        await model.waitForSpotlight()
        XCTAssertEqual(indexer.calls.last, .index([SpotlightServerItem(identifier: id.uuidString, title: "Zombie EU",
                                                                       summary: "198.51.100.20:27015")]))
        indexer.reset()

        XCTAssertTrue(model.openSpotlightResult(id.uuidString))
        XCTAssertEqual(model.requestedServerDetail, id)
        model.requestedServerDetail = nil

        model.deleteServer(id: id)
        await model.waitForSpotlight()
        XCTAssertEqual(indexer.calls, [.delete([id.uuidString])])
        XCTAssertFalse(model.openSpotlightResult(id.uuidString), "a deleted server opens nothing")
        XCTAssertNil(model.requestedServerDetail)
        indexer.reset()

        model.addServer(ServerDraft(label: "Other", host: "198.51.100.30"))
        model.save()
        await model.waitForSpotlight()
        indexer.reset()
        let erased = await model.eraseAllData()
        XCTAssertNil(erased)
        await model.waitForSpotlight()
        XCTAssertEqual(indexer.calls, [.deleteAll], "Erase All Data removes the whole domain")
    }

    @MainActor
    func testIndexFailuresGoToTheErrorLog() async throws {
        let env = try TestAppEnvironment()
        let indexer = FakeSpotlightIndexer()
        indexer.failing = true
        let model = env.makeModel { $0.spotlightIndexer = indexer }
        model.addServer(ServerDraft(label: "Zombie TR", host: "198.51.100.20"))
        await model.waitForSpotlight()
        XCTAssertEqual(model.errorLog.entries.map(\.area), [.spotlight, .spotlight])
        XCTAssertEqual(model.errorLog.entries.map(\.message), ["reindex: indexUnavailable", "update: indexUnavailable"])
    }
}

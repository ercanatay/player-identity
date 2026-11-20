import XCTest
@testable import PlayerIdentity

/// Records every data file operation; the identity feature must never call any of them (U12).
final class RecordingDataFileOperations: DataFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.withLock { recorded } }
    private func note(_ text: String) { lock.withLock { recorded.append(text) } }

    func exists(_ url: URL) -> Bool { note("exists " + url.path); return false }
    func createDirectory(_ url: URL) throws { note("createDirectory " + url.path) }
    func write(_ data: Data, to url: URL) throws { note("write " + url.path) }
    func move(_ source: URL, to destination: URL) throws { note("move " + source.path) }
    func remove(_ url: URL) throws { note("remove " + url.path) }
    func contents(_ url: URL) throws -> [URL] { note("contents " + url.path); return [] }
}

/// Launcher that suspends until `release()` (stale regenerate tests).
final class GatedAppLauncher: AppLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func open(app: URL, arguments: [String]) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

/// §73 app flow: refresh, "Regenerate Identity", "Download Compatible Engine", engine override (U10–U15, U20; v2.25
/// T-P5, T-P6, T-A4, T-A5, T-U1).
@MainActor
final class MacIdentityModelTests: XCTestCase {
    private var env: TestAppEnvironment!
    private var files: FakeFileProbe!
    private var launcher: FakeAppLauncher!
    private var opener: RecordingURLOpener!
    private var dataOps: RecordingDataFileOperations!
    private var game: FakeGameDetector!

    override func setUp() async throws {
        env = try TestAppEnvironment()
        files = FakeFileProbe()
        launcher = FakeAppLauncher()
        opener = RecordingURLOpener()
        dataOps = RecordingDataFileOperations()
        game = FakeGameDetector()
    }

    override func tearDown() async throws {
        env = nil
    }

    private var identityPath: String { env.home.path + "/.config/.xash_id" }

    private func makeModel(launcher: FakeAppLauncher? = nil) -> AppModel {
        let files = self.files!, launcher = launcher ?? self.launcher!, opener = self.opener!, dataOps = self.dataOps!
        return env.makeModel(game: game) { deps in
            deps.fileProbe = files
            deps.appLauncher = launcher
            deps.urlOpener = opener
            deps.dataFileOperations = dataOps
        }
    }

    private func english<T>(_ body: () throws -> T) rethrows -> T {
        try L10n.$bundle.withValue(L10n.languageBundle("en")!, operation: body)
    }

    func testDefaultDependenciesSeeNoEngine() async {
        let model = env.makeModel()
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.finding, .engineNotFound)
        XCTAssertEqual(model.macIdentity?.state, .unknown)
    }

    func testFullRefreshAlsoChecksTheIdentity() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.nonzeroFile)
        let model = makeModel()
        await model.refresh().value
        XCTAssertTrue(model.isCheckingMacIdentity || model.macIdentity != nil)
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.state, .supported)
        XCTAssertEqual(model.macIdentity?.finding, .healthy)
    }

    func testRegenerateFlowLaunchesOnceWithoutWritingOrAutoRefreshing() async throws {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let realIdentity = env.home.appendingPathComponent(".config/.xash_id")
        let before = try MacIdentityFixture.tree(env.home)
        let model = makeModel()
        await model.refreshMacIdentity().value
        let report = try XCTUnwrap(model.macIdentity)
        XCTAssertEqual(report.action, .regenerate)

        model.requestMacIdentityRegeneration()
        XCTAssertTrue(model.showsMacIdentityRegenerateConfirmation)
        XCTAssertEqual(launcher.calls, [])   // nothing starts before the confirmation
        await model.confirmMacIdentityRegeneration()?.value
        XCTAssertEqual(launcher.calls, [.init(app: EnginePaths.defaultApp, arguments: [])])
        XCTAssertEqual(model.macIdentityRegenerateStatus, .launched)
        XCTAssertFalse(model.showsMacIdentityRegenerateConfirmation)
        // §73.5.3: no automatic refresh after the action.
        XCTAssertEqual(model.macIdentity, report)
        XCTAssertFalse(model.isCheckingMacIdentity)
        // U12/U20: no data file operation and no change on disk (identity file and game data).
        XCTAssertEqual(dataOps.calls, [])
        XCTAssertEqual(try MacIdentityFixture.tree(env.home), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realIdentity.path))
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: false,
                                               regenerateStatus: model.macIdentityRegenerateStatus)
            XCTAssertEqual(card.actionFeedback?.text, "The engine was opened. Quit it, then press Refresh.")
            XCTAssertEqual(card.actionFeedback?.isError, false)
        }
    }

    func testU14RefreshAfterTheEngineRepairedTheIdentityIsSupported() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        await model.refreshMacIdentity().value
        model.requestMacIdentityRegeneration()
        await model.confirmMacIdentityRegeneration()?.value
        files.setFile(identityPath, MacIdentityFixture.nonzeroFile)   // the engine rebuilt it from the hardware
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.state, .supported)
        XCTAssertEqual(model.macIdentity?.finding, .healthy)
        XCTAssertNil(model.macIdentityRegenerateStatus)
    }

    func testU15StillZeroStaysUnknownWithoutRetrying() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        await model.refreshMacIdentity().value
        model.requestMacIdentityRegeneration()
        await model.confirmMacIdentityRegeneration()?.value
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.state, .unknown)
        XCTAssertEqual(model.macIdentity?.finding, .zero)
        XCTAssertEqual(launcher.calls.count, 1)
    }

    func testU11EngineRunningBlocksTheActionWithAReason() async throws {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        await model.refreshMacIdentity().value
        game.isRunning = true
        model.requestMacIdentityRegeneration()
        XCTAssertFalse(model.showsMacIdentityRegenerateConfirmation)
        XCTAssertEqual(model.macIdentityRegenerateStatus, .failed(.engineRunning))
        XCTAssertTrue(model.isGameRunning)
        XCTAssertEqual(launcher.calls, [])
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: model.isGameRunning)
            XCTAssertEqual(card.regenerate, .init(enabled: false, blockedReason: "Quit the engine first."))
        }
    }

    func testU10UnsupportedNeverLaunches() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.installed))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.state, .unsupported)
        model.requestMacIdentityRegeneration()
        XCTAssertFalse(model.showsMacIdentityRegenerateConfirmation)
        XCTAssertEqual(model.macIdentityRegenerateStatus, .failed(.notOffered))
        await model.confirmMacIdentityRegeneration()?.value
        XCTAssertEqual(model.macIdentityRegenerateStatus, .failed(.notOffered))
        XCTAssertEqual(launcher.calls, [])
    }

    func testLaunchFailureIsShownAndLogged() async throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        let model = makeModel(launcher: FakeAppLauncher(failure: Boom()))
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.finding, .notGenerated)
        model.requestMacIdentityRegeneration()
        await model.confirmMacIdentityRegeneration()?.value
        guard case .failed(.launchFailed(let reason))? = model.macIdentityRegenerateStatus else {
            return XCTFail("\(String(describing: model.macIdentityRegenerateStatus))")
        }
        XCTAssertTrue(reason.contains("boom"))
        XCTAssertEqual(model.errorLog.entries.map(\.area), [.launch])
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: false,
                                               regenerateStatus: model.macIdentityRegenerateStatus)
            XCTAssertEqual(card.actionFeedback?.isError, true)
            XCTAssertTrue(card.actionFeedback?.text.hasPrefix("The engine could not be opened:") == true)
        }
    }

    func testU13DownloadOpensOnlyTheOfficialPage() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.installed))
        let model = makeModel()
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.action, .downloadEngine)
        XCTAssertTrue(model.openCompatibleEngineDownload())
        XCTAssertEqual(opener.opened, [EngineDownloadLink.url])
        XCTAssertEqual(launcher.calls, [])
        XCTAssertFalse(model.engineDownloadFailed)
    }

    func testDownloadFailureIsVisible() async {
        let model = env.makeModel()
        XCTAssertFalse(model.openCompatibleEngineDownload())
        XCTAssertTrue(model.engineDownloadFailed)
        XCTAssertEqual(model.errorLog.entries.map(\.area), [.launch])
    }

    func testTU1LinkRefusedByTheAllowlistIsVisibleAndLogged() throws {
        let model = makeModel()
        for text in ["http://github.com/FWGS/xash3d-fwgs/releases/tag/continuous",
                     "https://example.com/FWGS/xash3d-fwgs/releases/tag/continuous"] {
            XCTAssertFalse(model.openCompatibleEngineDownload(URL(string: text)!), text)
            XCTAssertTrue(model.engineDownloadFailed, text)
        }
        XCTAssertEqual(opener.opened, [])
        XCTAssertEqual(model.errorLog.entries.count, 2)
        XCTAssertTrue(model.errorLog.entries.allSatisfy { $0.area == .launch && $0.message.contains("notAllowed") })
        try english {
            let card = MacIdentityPresentation(report: nil, checking: false, engineRunning: false,
                                               downloadFailed: model.engineDownloadFailed)
            XCTAssertNil(card.actionFeedback)   // no report yet: nothing else is shown
            let files = FakeFileProbe()
            files.installEngine(executable: MachOFixture.thin(MachOFixture.installed))
            let report = MacIdentityChecker(files: files, detector: FakeGameDetector(), home: env.home)
                .check(engineApp: EnginePaths.defaultApp, gamedir: nil)
            let withReport = MacIdentityPresentation(report: report, checking: false, engineRunning: false,
                                                     downloadFailed: model.engineDownloadFailed)
            XCTAssertEqual(withReport.actionFeedback?.text, "The release page could not be opened.")
            XCTAssertEqual(withReport.actionFeedback?.isError, true)
        }
    }

    // MARK: v2.25 process tri-state, running priority, stale results

    func testTP6IsGameRunningFollowsTheIdentityReport() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        game.isRunning = true
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.finding, .engineRunning)
        XCTAssertTrue(model.isGameRunning)
        XCTAssertEqual(model.engineProcessState, .running)

        game.isRunning = false
        await model.refreshMacIdentity().value
        XCTAssertFalse(model.isGameRunning)
        XCTAssertEqual(model.engineProcessState, .notRunning)

        // Unavailable is "unknown": the flag is left alone (here: true from before), never turned into "closed".
        game.isRunning = true
        await model.refreshMacIdentity().value
        game.processState = .unavailable
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.finding, .processUnavailable)
        XCTAssertEqual(model.engineProcessState, .unavailable)
        XCTAssertTrue(model.isGameRunning)
    }

    func testTP2TP3UnavailableBlocksRegenerateWithoutLaunching() async throws {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.action, .regenerate)
        game.processState = .unavailable
        model.requestMacIdentityRegeneration()
        XCTAssertFalse(model.showsMacIdentityRegenerateConfirmation)
        XCTAssertEqual(model.macIdentityRegenerateStatus, .failed(.processUnavailable))
        XCTAssertEqual(model.engineProcessState, .unavailable)
        await model.confirmMacIdentityRegeneration()?.value
        XCTAssertEqual(launcher.calls, [])
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: model.isGameRunning,
                                               processState: model.engineProcessState,
                                               regenerateStatus: model.macIdentityRegenerateStatus)
            XCTAssertEqual(card.regenerate?.enabled, false)
            XCTAssertTrue(card.regenerate?.blockedReason?.hasPrefix("The engine process state could not be verified") == true)
        }
    }

    func testTP5LaunchAssumesTheEngineRunsAndRefreshAfterQuittingReenablesRegenerate() async throws {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        await model.refreshMacIdentity().value
        model.requestMacIdentityRegeneration()
        await model.confirmMacIdentityRegeneration()?.value
        XCTAssertEqual(model.macIdentityRegenerateStatus, .launched)
        XCTAssertTrue(model.isGameRunning)
        XCTAssertEqual(model.engineProcessState, .running)
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: model.isGameRunning,
                                               processState: model.engineProcessState,
                                               regenerateStatus: model.macIdentityRegenerateStatus)
            XCTAssertEqual(card.regenerate, .init(enabled: false, blockedReason: "Quit the engine first."))
            XCTAssertEqual(card.actionFeedback?.text, "The engine was opened. Quit it, then press Refresh.")
        }
        // The user quits the engine (still zero, e.g. the engine was closed too early) and presses Refresh.
        await model.refreshMacIdentity().value
        XCTAssertFalse(model.isGameRunning)
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: model.isGameRunning,
                                               processState: model.engineProcessState)
            XCTAssertEqual(card.regenerate, .init(enabled: true, blockedReason: nil))
        }
    }

    func testTA4CheckingHidesThePreviousResultDetailsAndActions() async throws {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let model = makeModel()
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.action, .regenerate)
        let task = model.refreshMacIdentity()
        XCTAssertTrue(model.isCheckingMacIdentity)
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: model.isCheckingMacIdentity,
                                               engineRunning: model.isGameRunning, processState: model.engineProcessState,
                                               regenerateStatus: .launched, downloadFailed: true,
                                               overrideRejection: .symbolicLink)
            XCTAssertEqual(card.stateLabel, "Checking…")
            XCTAssertEqual(card.message, "Checking…")
            XCTAssertEqual(card.tone, .neutral)
            XCTAssertEqual(card.notes, [])
            XCTAssertEqual(card.details, [])
            XCTAssertNil(card.regenerate)
            XCTAssertFalse(card.showsDownload)
            XCTAssertNil(card.actionFeedback)
            XCTAssertTrue(card.accessibilityStatus.contains("Checking…"))
        }
        // The request of an action during the check is refused (it would act on the previous result).
        model.requestMacIdentityRegeneration()
        XCTAssertEqual(model.macIdentityRegenerateStatus, .failed(.notOffered))
        XCTAssertNil(model.confirmMacIdentityRegeneration())
        await task.value
        XCTAssertFalse(model.isCheckingMacIdentity)
        XCTAssertEqual(launcher.calls, [])
    }

    func testANewRefreshCancelsThePreviousScan() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.nonzeroFile)
        let model = makeModel()
        let first = model.refreshMacIdentity()
        let second = model.refreshMacIdentity()
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        await first.value
        await second.value
        XCTAssertFalse(model.isCheckingMacIdentity)
        XCTAssertEqual(model.macIdentity?.finding, .healthy)
    }

    func testTA5StaleRegenerateResultNeverTouchesTheNewReport() async throws {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.zeroFile)
        let gated = GatedAppLauncher()
        let model = env.makeModel(game: game) { [files, opener, dataOps] deps in
            deps.fileProbe = files!
            deps.appLauncher = gated
            deps.urlOpener = opener!
            deps.dataFileOperations = dataOps!
        }
        await model.refreshMacIdentity().value
        model.requestMacIdentityRegeneration()
        let regenerate = try XCTUnwrap(model.confirmMacIdentityRegeneration())
        var spins = 0
        while !gated.isWaiting, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(gated.isWaiting)

        // A refresh starts a new generation while the launch is still pending; the engine repaired the identity.
        files.setFile(identityPath, MacIdentityFixture.nonzeroFile)
        await model.refreshMacIdentity().value
        let fresh = try XCTUnwrap(model.macIdentity)
        XCTAssertEqual(fresh.finding, .healthy)
        XCTAssertFalse(model.isGameRunning)

        gated.release()
        await regenerate.value
        XCTAssertEqual(model.macIdentity, fresh)
        XCTAssertNil(model.macIdentityRegenerateStatus)   // the stale "launched" is not shown on the new report
        // …but the launch itself is real: the engine now runs (process state synced, the new report untouched).
        XCTAssertTrue(model.isGameRunning)
        XCTAssertEqual(model.engineProcessState, .running)
        XCTAssertFalse(model.isRegeneratingMacIdentity)
        XCTAssertTrue(model.errorLog.entries.contains { $0.message.contains("staleRegenerate") })
    }

    // MARK: Review round 2 (findings 1, 7)

    func testExplicitOverrideIsNotReadWhileTheEngineRunsOrItsStateIsUnknown() async throws {
        let custom = env.home.appendingPathComponent("Games/Xash3D.app", isDirectory: true)
        files.installEngine(at: custom.path, executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.nonzeroFile)
        env.defaults.set(custom.path, forKey: DefaultsKey.engineApp)
        let model = makeModel()
        for (state, finding) in [(EngineProcessState.running, MacIdentityFinding.engineRunning),
                                 (.unavailable, .processUnavailable)] {
            game.processState = state
            await model.refreshMacIdentity().value
            XCTAssertEqual(files.reads, [], "\(state)")
            XCTAssertEqual(files.inspected, [], "\(state)")
            XCTAssertEqual(model.macIdentity?.finding, finding)
            XCTAssertFalse(model.engineResolution.validated)
            XCTAssertEqual(model.engineResolution.requestedPath, custom.standardized.path)
            XCTAssertNil(model.engineResolution.rejectedOverride)
        }
        // Choosing another override while the state is unknown reads nothing either; it is kept for validation.
        let other = env.home.appendingPathComponent("Games/Other.app", isDirectory: true)
        XCTAssertNil(model.setEngineApp(other))
        await model.refreshMacIdentity().value
        XCTAssertEqual(files.reads, [])
        XCTAssertEqual(files.inspected, [])
        XCTAssertEqual(model.engineAppOverride, other.standardized.path)
        // Engine closed: the kept choice is validated now (missing → refused, shown and logged; default used).
        game.processState = .notRunning
        await model.refreshMacIdentity().value
        XCTAssertTrue(model.engineResolution.validated)
        XCTAssertEqual(model.engineResolution.rejectedOverride, .notFound)
        XCTAssertTrue(model.errorLog.entries.contains { $0.message.contains("overrideRejected=notFound") })
        XCTAssertNil(model.setEngineApp(custom))
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.finding, .healthy)
        XCTAssertTrue(model.engineResolution.isOverride)
    }

    func testFullRefreshKeepsAnUnknownProcessStateUnknown() async {
        let model = makeModel()
        game.isRunning = true
        await model.refresh().value
        XCTAssertTrue(model.isGameRunning)
        // The legacy yes/no answer would say "not running" (unreadable list); the tri-state says "unknown".
        game.isRunning = false
        game.processState = .unavailable
        await model.refresh().value
        XCTAssertTrue(model.isGameRunning)   // not turned into "closed"
        XCTAssertEqual(model.engineProcessState, .unavailable)
        game.processState = .notRunning
        await model.refresh().value
        XCTAssertFalse(model.isGameRunning)
        XCTAssertEqual(model.engineProcessState, .notRunning)
    }

    func testRejectedOverrideIsVisibleOnTheCardAndLogged() async throws {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.nonzeroFile)
        files.set(env.home.path + "/Link.app", .link)
        env.defaults.set(env.home.path + "/Link.app", forKey: DefaultsKey.engineApp)
        let model = makeModel()
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.engineResolution.rejectedOverride, .symbolicLink)
        XCTAssertEqual(model.errorLog.entries.filter { $0.message.contains("overrideRejected=symbolicLink") }.count, 1)
        await model.refreshMacIdentity().value   // logged once per rejection, not on every refresh
        XCTAssertEqual(model.errorLog.entries.filter { $0.message.contains("overrideRejected=symbolicLink") }.count, 1)
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: false,
                                               overrideRejection: model.engineResolution.rejectedOverride)
            XCTAssertTrue(card.notes.contains("The chosen path was rejected (contains a symbolic link); the default is used."))
        }
    }

    func testEngineOverrideIsValidatedStoredAndReset() async {
        let custom = env.home.appendingPathComponent("Games/Xash3D.app", isDirectory: true)
        files.installEngine(at: custom.path, executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(identityPath, MacIdentityFixture.nonzeroFile)
        let model = makeModel()

        XCTAssertEqual(model.setEngineApp(env.home.appendingPathComponent("Missing.app")), .notFound)
        XCTAssertNil(model.engineAppOverride)
        XCTAssertEqual(model.engineOverrideRejection, .notFound)
        XCTAssertEqual(model.engineResolution.app, EnginePaths.defaultApp)

        let dataApp = env.valveDir.appendingPathComponent("Xash3D.app", isDirectory: true)
        files.installEngine(at: dataApp.path, executable: MachOFixture.thin(MachOFixture.upstream))
        XCTAssertEqual(model.setEngineApp(dataApp), .insideDataFolder)
        XCTAssertNil(model.engineAppOverride)

        XCTAssertNil(model.setEngineApp(custom))
        XCTAssertEqual(model.engineAppOverride, custom.standardizedFileURL.path)
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.engineResolution.app, custom.standardizedFileURL)
        XCTAssertTrue(model.engineResolution.isOverride)
        XCTAssertEqual(model.macIdentity?.finding, .healthy)
        XCTAssertNil(model.engineOverrideRejection)

        model.setEngineApp(nil)
        XCTAssertNil(model.engineAppOverride)
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.engineResolution.app, EnginePaths.defaultApp)
    }
}

/// U16 and §73.7: `diagnose --macos-identity` output, exit codes and privacy.
final class MacIdentityCLITests: XCTestCase {
    private let home = MacIdentityFixture.home

    private func context(_ files: FakeFileProbe, running: Bool = false, environment: [String: String] = [:]) -> CLIContext {
        var env = environment
        env[CLIContext.snapshotEnvironmentKey] = "/nonexistent/profile.json"
        var context = CLIContext(version: "2.24.0", build: "52", paths: AppPaths(home: home), environment: env,
                                 fileSystem: LocalFileSystem(), resolver: FakeAddressResolver(),
                                 udpTransport: FakeServer.healthy(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        context.fileProbe = files
        context.gameProcessDetector = FakeGameDetector(running: running)
        context.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        context.defaultsSuite = "PlayerIdentityTests-\(UUID().uuidString)"
        return context
    }

    private func engine(_ options: MachOFixture.Options?, identity: String?) -> FakeFileProbe {
        let files = FakeFileProbe()
        if let options { files.installEngine(executable: MachOFixture.thin(options)) }
        if let identity { files.setFile(home.path + "/.config/.xash_id", identity) }
        return files
    }

    private func run(_ arguments: [String], _ context: CLIContext) async -> CLIResult {
        await CLIRunner.run(arguments: arguments, context: context)
    }

    func testParsing() {
        XCTAssertEqual(try CLIParser.parse(["diagnose", "--macos-identity"]).get(), .diagnoseMacIdentity(json: false))
        XCTAssertEqual(try CLIParser.parse(["diagnose", "--macos-identity", "--json"]).get(),
                       .diagnoseMacIdentity(json: true))
        for arguments in [["diagnose", "--macos-identity", "1"], ["diagnose", "--macos-identity", "--timeout", "3"],
                          ["diagnose", "--macos-identity", "--fail-on-ban"], ["status", "--macos-identity"]] {
            guard case .failure = CLIParser.parse(arguments) else { return XCTFail("\(arguments) should fail") }
        }
        XCTAssertTrue(CLIRunner.usage.contains("diagnose --macos-identity [--json]"))
    }

    func testU16JSONHasTheFieldsButNoRawIdentityOrFullCID() async throws {
        let result = await run(["diagnose", "--macos-identity", "--json"],
                               context(engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile)))
        XCTAssertEqual(result.exitCode, CLIExit.identitySupported)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "supported")
        XCTAssertEqual(object["static_support"] as? String, "yes")
        XCTAssertEqual(object["raw_state"] as? String, "nonzero")
        XCTAssertEqual(object["cid_masked"] as? String, RawIdentityReader.mask(MacIdentityFixture.nonzeroCID))
        XCTAssertEqual(object["engine_path"] as? String, "/Applications/Xash3D-FWGS.app")
        XCTAssertEqual((object["engine_hash_short"] as? String)?.count, 12)
        XCTAssertEqual(object["engine_running"] as? Bool, false)
        XCTAssertEqual(object["app_version"] as? String, "2.24.0")
        XCTAssertEqual(object["engine_version_informational"] as? String, "0.21")
        XCTAssertEqual(object["timestamp"] as? String, "2027-01-15T08:00:00Z")
        let evidence = try XCTUnwrap(object["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["count"] as? Int, 4)
        XCTAssertEqual(evidence["k4_platform_serial_string"] as? Bool, true)
        for key in ["raw", "rawID", "raw_id", "cid", "serial"] { XCTAssertNil(object[key], key) }
        for secret in [MacIdentityFixture.nonzeroRawHex, MacIdentityFixture.nonzeroRawHex.lowercased(),
                       MacIdentityFixture.nonzeroCID, "00000000000000AB"] {
            XCTAssertFalse(result.stdout.contains(secret), secret)
            XCTAssertFalse(result.stderr.contains(secret), secret)
        }
    }

    func testHumanOutputAndExitCodes() async {
        let unsupported = await run(["diagnose", "--macos-identity"],
                                    context(engine(MachOFixture.installed, identity: MacIdentityFixture.zeroFile)))
        XCTAssertEqual(unsupported.exitCode, CLIExit.identityUnsupported)
        XCTAssertTrue(unsupported.stdout.contains("macOS hardware identity: unsupported"))
        XCTAssertTrue(unsupported.stdout.contains("raw state:       zero"))
        XCTAssertTrue(unsupported.stdout.contains(EngineDownloadLink.url.absoluteString))
        XCTAssertTrue(unsupported.stdout.contains("shares the same CID"))
        XCTAssertFalse(unsupported.stdout.contains(MacIdentityFixture.zeroCID))
        XCTAssertFalse(unsupported.stdout.contains("0000000000000000"))

        let zero = await run(["diagnose", "--macos-identity"],
                             context(engine(MachOFixture.upstream, identity: MacIdentityFixture.zeroFile)))
        XCTAssertEqual(zero.exitCode, CLIExit.identityUnknown)
        XCTAssertTrue(zero.stdout.contains("Regenerate Identity"))

        let missing = await run(["diagnose", "--macos-identity", "--json"], context(engine(nil, identity: nil)))
        XCTAssertEqual(missing.exitCode, CLIExit.identityUnknown)
        XCTAssertTrue(missing.stdout.contains("\"static_failure\" : \"engineNotFound\""))

        let running = await run(["diagnose", "--macos-identity", "--json"],
                                context(engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile), running: true))
        XCTAssertEqual(running.exitCode, CLIExit.identityUnknown)
        XCTAssertTrue(running.stdout.contains("\"raw_state\" : null"))
        XCTAssertTrue(running.stdout.contains("\"engine_running\" : true"))
    }

    func testTC3RunningEngineHasNoHashNoEvidenceAndNoStaticResult() async throws {
        let files = engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile)
        let result = await run(["diagnose", "--macos-identity", "--json"], context(files, running: true))
        XCTAssertEqual(result.exitCode, CLIExit.identityUnknown)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["process_state"] as? String, "running")
        XCTAssertEqual(object["finding"] as? String, "engineRunning")
        XCTAssertEqual(object["static_support"] as? String, "unknown")
        XCTAssertTrue(object["evidence"] is NSNull)
        XCTAssertTrue(object["engine_hash_short"] is NSNull)
        XCTAssertTrue(object["package_readability"] is NSNull)
        XCTAssertTrue(object["cid_masked"] is NSNull)
        XCTAssertEqual(files.reads, [])

        var unavailable = context(files)
        let detector = FakeGameDetector()
        detector.processState = .unavailable
        unavailable.gameProcessDetector = detector
        let blocked = await run(["diagnose", "--macos-identity"], unavailable)
        XCTAssertEqual(blocked.exitCode, CLIExit.identityUnknown)
        XCTAssertTrue(blocked.stdout.contains("macOS hardware identity: unknown (processUnavailable)"))
        XCTAssertTrue(blocked.stdout.contains("engine running:  unknown"))
        XCTAssertTrue(blocked.stdout.contains("raw state:       not read (unavailable)"))
        XCTAssertEqual(files.reads, [])
    }

    func testTO4RejectedOverrideNeverExitsZeroEvenWhenTheDefaultPasses() async throws {
        let files = engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile)   // default engine passes
        files.set("/Users/tester/Link.app", .link)
        let environment = [CLIContext.engineAppEnvironmentKey: "/Users/tester/Link.app"]
        let json = await run(["diagnose", "--macos-identity", "--json"], context(files, environment: environment))
        XCTAssertEqual(json.exitCode, CLIExit.identityUnknown)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "supported")   // the fallback result is still reported…
        XCTAssertEqual(object["override_rejected"] as? Bool, true)   // …but never as a pass
        XCTAssertEqual(object["reject_reason"] as? String, "symbolicLink")
        XCTAssertEqual(object["requested_engine_path"] as? String, "~/Link.app")
        XCTAssertEqual(object["effective_engine_path"] as? String, "/Applications/Xash3D-FWGS.app")
        XCTAssertEqual(object["engine_path"] as? String, "/Applications/Xash3D-FWGS.app")
        XCTAssertTrue(json.stderr.contains("requested engine override ~/Link.app rejected (symbolicLink)"))

        let human = await run(["diagnose", "--macos-identity"], context(files, environment: environment))
        XCTAssertEqual(human.exitCode, CLIExit.identityUnknown)
        XCTAssertTrue(human.stdout.contains("requested engine: ~/Link.app — REJECTED (symbolicLink)"))
        XCTAssertTrue(human.stdout.contains("engine:          /Applications/Xash3D-FWGS.app (default fallback)"))
        XCTAssertTrue(human.stdout.contains("next step:       fix or unset the engine override (symbolicLink)"))

        // A missing override path is rejected too (T-O5), and never exits 0.
        let missing = await run(["diagnose", "--macos-identity", "--json"],
                                context(files, environment: [CLIContext.engineAppEnvironmentKey: "/Users/tester/Nope.app"]))
        XCTAssertEqual(missing.exitCode, CLIExit.identityUnknown)
        XCTAssertTrue(missing.stdout.contains("\"reject_reason\" : \"notFound\""))

        // An accepted override is reported as requested and effective.
        files.installEngine(at: "/Users/tester/Games/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
        let accepted = await run(["diagnose", "--macos-identity", "--json"],
                                 context(files, environment: [CLIContext.engineAppEnvironmentKey: "/Users/tester/Games/Xash3D.app"]))
        XCTAssertEqual(accepted.exitCode, CLIExit.identitySupported)
        let acceptedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(accepted.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(acceptedObject["override_rejected"] as? Bool, false)
        XCTAssertTrue(acceptedObject["reject_reason"] is NSNull)
        XCTAssertEqual(acceptedObject["requested_engine_path"] as? String, "~/Games/Xash3D.app")
        XCTAssertEqual(acceptedObject["effective_engine_path"] as? String, "~/Games/Xash3D.app")
    }

    func testTL1CLIOutputNeverClaimsUniqueness() async {
        let cases: [(MachOFixture.Options?, String?, Bool)] = [
            (MachOFixture.upstream, MacIdentityFixture.nonzeroFile, false),
            (MachOFixture.installed, MacIdentityFixture.nonzeroFile, false),
            (MachOFixture.upstream, MacIdentityFixture.zeroFile, false),
            (MachOFixture.installed, nil, false),
            (MachOFixture.upstream, nil, true),
        ]
        for (options, identity, running) in cases {
            let result = await run(["diagnose", "--macos-identity"], context(engine(options, identity: identity),
                                                                                running: running))
            for line in result.stdout.split(separator: "\n") where line.lowercased().contains("unique") {
                XCTAssertTrue(line.contains("not verified") || line.contains("not directly verified"), String(line))
            }
            XCTAssertFalse(result.stdout.lowercased().contains("unique identity"))
        }
        let json = await run(["diagnose", "--macos-identity", "--json"],
                             context(engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile)))
        XCTAssertTrue(json.stdout.contains("\"uniqueness_verified\" : false"))
        XCTAssertFalse(CLIRunner.usage.lowercased().contains("unique identity"))
    }

    func testExplicitOverrideWithRunningOrUnknownEngineReadsNothing() async throws {
        for (state, finding) in [(EngineProcessState.running, "engineRunning"), (.unavailable, "processUnavailable")] {
            let files = engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile)
            files.installEngine(at: "/Users/tester/Games/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
            var context = context(files, environment: [CLIContext.engineAppEnvironmentKey: "/Users/tester/Games/Xash3D.app"])
            let detector = FakeGameDetector()
            detector.processState = state
            context.gameProcessDetector = detector
            let result = await run(["diagnose", "--macos-identity", "--json"], context)
            XCTAssertEqual(result.exitCode, CLIExit.identityUnknown, "\(state)")
            XCTAssertEqual(files.reads, [], "\(state)")
            XCTAssertEqual(files.inspected, [], "\(state)")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            XCTAssertEqual(object["finding"] as? String, finding)
            XCTAssertEqual(object["process_state"] as? String, state.rawValue)
            XCTAssertEqual(object["requested_engine_path"] as? String, "~/Games/Xash3D.app")
            XCTAssertTrue(object["effective_engine_path"] is NSNull)
            XCTAssertTrue(object["engine_physical_path"] is NSNull)
            XCTAssertEqual(object["engine_path_validated"] as? Bool, false)
            XCTAssertEqual(object["override_rejected"] as? Bool, false)
            XCTAssertTrue(object["evidence"] is NSNull)
            XCTAssertTrue(object["raw_state"] is NSNull)
            XCTAssertTrue(object["engine_hash_short"] is NSNull)
            let human = await run(["diagnose", "--macos-identity"], context)
            XCTAssertTrue(human.stdout.contains("requested engine: ~/Games/Xash3D.app — not validated (\(state.rawValue))"))
            XCTAssertEqual(files.reads, [])
        }
    }

    func testCancellingTheCommandCancelsTheScanBeforeTheIdentity() async throws {
        let files = engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile)
        let box = TaskBox()
        // The first binary read cancels the parent command task; the detached scan must stop with it.
        files.onRead = { path in
            if path.hasSuffix("/MacOS/xash3d") { box.cancelWhenReady() }
        }
        let context = context(files)
        let task = Task { await CLIRunner.run(arguments: ["diagnose", "--macos-identity", "--json"], context: context) }
        box.task = task
        let result = await task.value
        XCTAssertEqual(result.exitCode, CLIExit.identityError)
        XCTAssertTrue(result.stdout.contains("cancelled") || result.stderr.contains("cancelled"))
        XCTAssertFalse(files.reads.contains(home.path + "/.config/.xash_id"))
        XCTAssertFalse(files.inspected.contains(home.path + "/.config/.xash_id"))
    }

    func testIdentityHomeEnvironmentIsolatesTheIdentityFiles() async throws {
        let files = engine(MachOFixture.upstream, identity: MacIdentityFixture.zeroFile)
        files.setFile("/fixture/home/.config/.xash_id", MacIdentityFixture.nonzeroFile)
        let result = await run(["diagnose", "--macos-identity", "--json"],
                               context(files, environment: [CLIContext.identityHomeEnvironmentKey: "/fixture/home"]))
        XCTAssertEqual(result.exitCode, CLIExit.identitySupported)
        XCTAssertTrue(files.reads.contains("/fixture/home/.config/.xash_id"))
        XCTAssertFalse(files.reads.contains(home.path + "/.config/.xash_id"))
    }

    func testEngineOverrideEnvironmentAndRejection() async throws {
        let files = FakeFileProbe()
        files.installEngine(at: "/Users/tester/Games/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.nonzeroFile)
        let valid = await run(["diagnose", "--macos-identity", "--json"],
                              context(files, environment: [CLIContext.engineAppEnvironmentKey: "/Users/tester/Games/Xash3D.app"]))
        XCTAssertEqual(valid.exitCode, CLIExit.identitySupported)
        XCTAssertTrue(valid.stdout.contains("\"engine_path\" : \"~/Games/Xash3D.app\""))

        files.set("/Users/tester/Link.app", .link)
        let rejected = await run(["diagnose", "--macos-identity", "--json"],
                                 context(files, environment: [CLIContext.engineAppEnvironmentKey: "/Users/tester/Link.app"]))
        XCTAssertEqual(rejected.exitCode, CLIExit.identityUnknown)   // the default path has no engine here
        XCTAssertTrue(rejected.stdout.contains("\"reject_reason\" : \"symbolicLink\""))
        XCTAssertTrue(rejected.stdout.contains("\"override_rejected\" : true"))
        XCTAssertTrue(rejected.stderr.contains("engine override"))
    }

    func testCheckWritesNothing() async throws {
        let temp = try TempDirectory()
        let realHome = temp.physicalURL
        try temp.write(".config/.xash_id", MacIdentityFixture.zeroFile)
        let before = try MacIdentityFixture.tree(realHome)
        var context = context(FakeFileProbe())
        context.paths = AppPaths(home: realHome)
        context.fileProbe = LocalFileProbe()
        context.environment[CLIContext.engineAppEnvironmentKey] = realHome.appendingPathComponent("none.app").path
        _ = await run(["diagnose", "--macos-identity"], context)
        XCTAssertEqual(try MacIdentityFixture.tree(realHome), before)
    }
}

/// U19 and §73.8: the card texts exist in every language, keep the spec wording and promise no random identity.
final class MacIdentityLocalizationTests: XCTestCase {
    private static let languages = ["tr", "en", "de", "fr", "es", "it", "pt", "nl", "sv", "pl", "cs", "ro", "hu", "el", "bg",
                                    "uk", "ru", "ar", "fa", "hi", "zh-Hans", "ja", "ko", "id", "az", "vi"]

    private var keys: [L10nKey] { L10nKey.allCases.filter { $0.rawValue.hasPrefix("macIdentity.") } }

    func testEveryLanguageHasEveryKey() throws {
        XCTAssertEqual(keys.count, 45)
        for language in Self.languages {
            let bundle = try XCTUnwrap(L10n.languageBundle(language), language)
            L10n.$bundle.withValue(bundle) {
                for key in keys {
                    let text = L10n.text(key)
                    XCTAssertFalse(text.isEmpty, "\(language): \(key.rawValue)")
                    XCTAssertNotEqual(text, key.rawValue, "\(language): \(key.rawValue) missing")
                }
            }
        }
    }

    func testSpecWordingAndNoRandomIdentityPromise() throws {
        let tr = try XCTUnwrap(L10n.languageBundle("tr"))
        L10n.$bundle.withValue(tr) {
            XCTAssertEqual(L10n.text(.macIdentityTitle), "macOS donanım kimliği")
            XCTAssertEqual(L10n.text(.macIdentityTextHealthy),
                           "Sıfır olmayan kimlik ve donanım-kimliği statik göstergeleri bulundu. Tekillik doğrudan doğrulanmadı.")
            XCTAssertEqual(L10n.text(.macIdentityStateSupported), "Göstergeler bulundu")
            XCTAssertEqual(L10n.text(.macIdentityActionDownload), "Uyumlu motoru indir")
            XCTAssertEqual(L10n.text(.macIdentityActionRegenerate), "Kimliği yeniden oluştur")
        }
        for language in ["tr", "en"] {
            let bundle = try XCTUnwrap(L10n.languageBundle(language))
            L10n.$bundle.withValue(bundle) {
                for key in keys {
                    let text = L10n.text(key).lowercased()
                    XCTAssertFalse(text.contains("new random"), key.rawValue)
                    XCTAssertFalse(text.contains("yeni rastgele"), key.rawValue)
                }
            }
        }
    }
}

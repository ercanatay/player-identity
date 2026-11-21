import XCTest
@testable import PlayerIdentity

// §74 "Install Compatible Engine": app flow (AppModel), pure presentation, backups, CLI and localization. Everything
// runs on fakes and temporary folders: no network, no real /Applications, no real game data or identity files.

/// Installer fake: records calls, emits scripted progress and returns a scripted result. `hold` keeps the install in
/// the given phase until the task is cancelled (cancellable phases) or `release()` is called.
final class FakeEngineInstallService: EngineInstallServing, @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0
    private var installs = 0
    private var confirmationList: [EngineInstallConfirmation] = []
    private var environmentList: [EngineInstallEnvironment] = []
    private var released = false
    private var sawCancel = false
    var release: Result<EngineRelease, EngineInstallFailure> = .success(FakeEngineInstallService.fixtureRelease)
    var result = EngineInstallResult(outcome: .installed, report: EngineInstallReport(), log: [])
    var hold: EngineInstallPhase?
    var events: [EngineInstallProgress] = [EngineInstallProgress(phase: .downloading, bytes: 0, total: 100),
                                           EngineInstallProgress(phase: .downloading, bytes: 100, total: 100),
                                           EngineInstallProgress(phase: .backingUp),
                                           EngineInstallProgress(phase: .installing)]

    static let fixtureRelease = EngineRelease(
        tag: "continuous", prerelease: true, htmlURL: EngineReleaseSource.releasePageURL,
        commitSHA: EngineReleaseFixture.commit, architecture: .arm64,
        asset: EngineReleaseAsset(name: EngineArchitecture.arm64.assetName,
                                  downloadURL: EngineReleaseSource.downloadURL(for: EngineArchitecture.arm64.assetName),
                                  size: 5_284_228, sha256: String(repeating: "a", count: 64)))

    var fetchCount: Int { lock.withLock { fetches } }
    var installCount: Int { lock.withLock { installs } }
    var confirmations: [EngineInstallConfirmation] { lock.withLock { confirmationList } }
    var environments: [EngineInstallEnvironment] { lock.withLock { environmentList } }
    var cancelSeen: Bool { lock.withLock { sawCancel } }

    func record(_ environment: EngineInstallEnvironment) { lock.withLock { environmentList.append(environment) } }
    func releaseHold() { lock.withLock { released = true } }

    func fetchRelease() async -> Result<EngineRelease, EngineInstallFailure> {
        lock.withLock { fetches += 1 }
        return release
    }

    func install(_ release: EngineRelease, confirmation: EngineInstallConfirmation,
                 progress: @escaping @Sendable (EngineInstallProgress) async -> Void) async -> EngineInstallResult {
        lock.withLock {
            installs += 1
            confirmationList.append(confirmation)
        }
        if let hold {
            await progress(EngineInstallProgress(phase: hold, bytes: 10, total: 100))
            while !lock.withLock({ released }) {
                if Task.isCancelled {
                    lock.withLock { sawCancel = true }
                    if hold.isCancellable {
                        return EngineInstallResult(outcome: .cancelled, report: EngineInstallReport(), log: [])
                    }
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return result
        }
        for event in events { await progress(event) }
        return result
    }
}

@MainActor
final class EngineInstallModelTests: XCTestCase {
    private var env: TestAppEnvironment!
    private var files: FakeFileProbe!
    private var service: FakeEngineInstallService!
    private var launcher: FakeAppLauncher!
    private var game: FakeGameDetector!

    override func setUp() async throws {
        env = try TestAppEnvironment()
        files = FakeFileProbe()
        service = FakeEngineInstallService()
        launcher = FakeAppLauncher()
        game = FakeGameDetector()
    }

    override func tearDown() async throws {
        if let env { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupLock(env).path) }
        env = nil
    }

    private func backupLock(_ env: TestAppEnvironment) -> URL {
        AppPaths(home: env.home).engineBackupsDirectory.appendingPathComponent("identity-20260101-000000/sub")
    }

    private var globalPath: String { env.home.path + "/.config/.xash_id" }
    private var gamedirPath: String { env.valveDir.path + "/.xash_id" }
    private var gamedirNonzero: String { HexID.format(MacIdentityFixture.nonzeroRaw ^ IdentityLocation.gamedirMask) + "\n" }

    private func makeModel(architecture: EngineArchitecture = .arm64) -> AppModel {
        let files = self.files!, service = self.service!, launcher = self.launcher!
        return env.makeModel(game: game) { deps in
            deps.fileProbe = files
            deps.appLauncher = launcher
            deps.urlOpener = RecordingURLOpener()
            deps.engineArchitecture = architecture
            deps.engineInstallerFactory = { environment in
                service.record(environment)
                return service
            }
        }
    }

    /// The installed (old) engine with a zero identity: `unsupported`.
    private func unsupportedModel(architecture: EngineArchitecture = .arm64) async -> AppModel {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.installed))
        files.setFile(globalPath, MacIdentityFixture.zeroFile)
        let model = makeModel(architecture: architecture)
        await model.refreshMacIdentity().value
        return model
    }

    private func english<T>(_ body: () throws -> T) rethrows -> T {
        try L10n.$bundle.withValue(L10n.languageBundle("en")!, operation: body)
    }

    private func settle(_ model: AppModel) async {
        for _ in 0..<20_000 where model.isCheckingMacIdentity || model.isEngineInstallRunning { await Task.yield() }
    }

    private func installPresentation(_ model: AppModel) -> EngineInstallPresentation {
        EngineInstallPresentation(availability: model.engineInstallAvailability, flow: model.engineInstall,
                                  awaitingVerification: model.engineInstallAwaitingVerification,
                                  launchStatus: model.engineInstallLaunchStatus, home: model.homeDirectory)
    }

    private func confirmAndInstall(_ model: AppModel) async throws {
        await model.requestEngineInstall()?.value
        XCTAssertNotNil(model.engineInstall.offer)
        let task = try XCTUnwrap(model.confirmEngineInstall(acceptedCIDWarning: true))
        await task.value
        await settle(model)
    }

    // MARK: Availability

    func testUnsupportedOffersTheInstallAsPrimaryActionWithTheReleasePageAsSecondary() async throws {
        let model = await unsupportedModel()
        XCTAssertEqual(model.macIdentity?.state, .unsupported)
        XCTAssertEqual(model.engineInstallAvailability, .enabled)
        try english {
            let presentation = installPresentation(model)
            XCTAssertEqual(presentation.installButton, .enabled)
            XCTAssertTrue(presentation.showsReleasePageLink)
            XCTAssertEqual(L10n.text(.engineInstallActionInstall), "Install Compatible Engine")
        }
        XCTAssertEqual(service.fetchCount, 0)   // nothing before the click
    }

    func testOtherStatesDoNotOfferTheInstall() async {
        files.installEngine(executable: MachOFixture.thin(MachOFixture.installed))
        files.setFile(globalPath, MacIdentityFixture.nonzeroFile)   // no + nonzero → unknown (download link only)
        let model = makeModel()
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.finding, .nonzeroWithoutEvidence)
        XCTAssertEqual(model.engineInstallAvailability, .hidden)
        XCTAssertNil(model.requestEngineInstall())
        XCTAssertEqual(model.engineInstall, .blocked(.notOffered))
        XCTAssertEqual(service.fetchCount, 0)
        for (support, raw) in [(StaticSupport.yes, RawIdentityState.nonzero), (.yes, .zero), (.unknown, .zero),
                               (.no, .unreadable)] {
            XCTAssertEqual(EngineInstallAvailability.evaluate(report: .fixture(support: support, raw: raw), checking: false,
                                                              engineRunning: false, processState: nil,
                                                              architecture: .arm64, flow: .idle), .hidden)
        }
        // Checking hides it (it would belong to the previous report).
        XCTAssertEqual(EngineInstallAvailability.evaluate(report: .fixture(support: .no, raw: .zero), checking: true,
                                                          engineRunning: false, processState: nil, architecture: .arm64,
                                                          flow: .idle), .hidden)
    }

    func testRunningOrUnknownProcessDisablesWithAReasonAndNeverFetches() async throws {
        let unsupported = MacIdentityReport.fixture(support: .no, raw: .zero)
        XCTAssertEqual(EngineInstallAvailability.evaluate(report: unsupported, checking: false, engineRunning: true,
                                                          processState: nil, architecture: .arm64, flow: .idle),
                       .disabled(.engineRunning))
        XCTAssertEqual(EngineInstallAvailability.evaluate(report: unsupported, checking: false, engineRunning: false,
                                                          processState: .unavailable, architecture: .arm64, flow: .idle),
                       .disabled(.processUnavailable))
        XCTAssertEqual(EngineInstallAvailability.evaluate(report: unsupported, checking: false, engineRunning: false,
                                                          processState: nil, architecture: .arm64,
                                                          flow: .fetchingRelease), .disabled(.busy))
        let model = await unsupportedModel()
        game.isRunning = true   // the engine was opened after the check
        XCTAssertNil(model.requestEngineInstall())
        XCTAssertEqual(model.engineInstall, .blocked(.engineRunning))
        game.isRunning = false
        game.processState = .unavailable
        XCTAssertNil(model.requestEngineInstall())
        XCTAssertEqual(service.fetchCount, 0)
        try english {
            let presentation = EngineInstallPresentation(availability: .disabled(.engineRunning), flow: .idle,
                                                         awaitingVerification: false, launchStatus: nil)
            XCTAssertEqual(presentation.installButton, .disabled("The engine is running. Quit it before installing."))
        }
    }

    func testIntelMacIsDisabled() async {
        let model = await unsupportedModel(architecture: .amd64)
        XCTAssertEqual(model.engineInstallAvailability, .disabled(.architecture))
        XCTAssertNil(model.requestEngineInstall())
        XCTAssertEqual(service.fetchCount, 0)
    }

    // MARK: Fetch → confirm

    func testFetchOpensTheConfirmationAndNothingIsInstalledUntilTheWarningIsAccepted() async throws {
        let model = await unsupportedModel()
        let before = try MacIdentityFixture.tree(env.home)
        await model.requestEngineInstall()?.value
        XCTAssertEqual(service.fetchCount, 1)
        let offer = try XCTUnwrap(model.engineInstall.offer)
        XCTAssertEqual(offer.summary.cidMasked, model.macIdentity?.cidMasked)
        XCTAssertEqual(offer.environment.targetApp, EnginePaths.defaultApp)
        XCTAssertEqual(offer.environment.gamedir, "valve")
        XCTAssertNil(model.confirmEngineInstall(acceptedCIDWarning: false))
        XCTAssertEqual(service.installCount, 0)
        model.declineEngineInstall()
        XCTAssertEqual(model.engineInstall, .idle)
        XCTAssertEqual(service.installCount, 0)
        XCTAssertEqual(try MacIdentityFixture.tree(env.home), before)   // no write on decline

        try english {
            let content = EngineInstallConfirmationContent(summary: offer.summary, home: env.home)
            XCTAssertTrue(content.cidLine.hasPrefix("Current CID (masked): "))
            XCTAssertTrue(content.cidLine.contains("…"))
            XCTAssertFalse(content.cidLine.contains(MacIdentityFixture.zeroCID))
            XCTAssertEqual(content.warning, "This update may create a new identity (CID). A ban or account record on a "
                           + "server may not match the new identity.")
            XCTAssertTrue(content.details.contains("Commit: " + EngineReleaseFixture.commit))
            XCTAssertTrue(content.details.contains { $0.contains("xash3d-fwgs-apple-arm64.tar.xz") })
            XCTAssertTrue(content.details.contains { $0.contains("/Applications/Xash3D-FWGS.app") })
            XCTAssertTrue(content.details.contains { $0.contains("engine-backups") })
            XCTAssertTrue(content.license.contains("GPL"))
        }
    }

    func testFetchFailureIsVisibleAndLogged() async throws {
        service.release = .failure(.metadataInvalid)
        let model = await unsupportedModel()
        await model.requestEngineInstall()?.value
        XCTAssertEqual(model.engineInstall, .fetchFailed(.metadataInvalid))
        XCTAssertTrue(model.errorLog.entries.contains { $0.area == .engineInstall && $0.message.contains("metadataInvalid") })
        try english {
            let line = try XCTUnwrap(installPresentation(model).lines.first)
            XCTAssertEqual(line.kind, .error)
            XCTAssertTrue(line.text.contains("code: metadataInvalid"))
        }
        model.dismissEngineInstallResult()
        XCTAssertEqual(model.engineInstall, .idle)
    }

    func testConfirmChecksTheProcessAgain() async throws {
        let model = await unsupportedModel()
        await model.requestEngineInstall()?.value
        game.isRunning = true
        XCTAssertNil(model.confirmEngineInstall(acceptedCIDWarning: true))
        XCTAssertEqual(model.engineInstall, .blocked(.engineRunning))
        XCTAssertEqual(service.installCount, 0)
    }

    // MARK: Install outcomes and verification

    func testInstalledIsNotSupportedUntilTheCoreVerifiedTheIdentity() async throws {
        let model = await unsupportedModel()
        let cidBefore = try XCTUnwrap(model.macIdentity?.cidMasked)
        try await confirmAndInstall(model)
        XCTAssertEqual(service.confirmations, [EngineInstallConfirmation(acceptedCIDWarning: true, cidBefore: cidBefore)])
        XCTAssertEqual(model.engineInstall.finish?.outcome, .installed)
        XCTAssertTrue(model.engineInstallAwaitingVerification)
        XCTAssertEqual(launcher.calls, [])   // never opened automatically
        try english {
            let lines = installPresentation(model).lines.map(\.text)
            XCTAssertTrue(lines.contains("Install complete. The identity is not verified yet."))
            XCTAssertTrue(lines.contains("Open the engine once, quit it when the main menu appears, then press Refresh."))
            XCTAssertTrue(lines.contains { $0.contains("Privacy & Security") && $0.contains("Open Anyway") })
            XCTAssertTrue(installPresentation(model).showsOpenEngine)
            XCTAssertFalse(installPresentation(model).showsDismiss)
        }

        // The new engine is in place, the global identity is repaired, the game folder one is still missing.
        files.installEngine(executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(globalPath, MacIdentityFixture.nonzeroFile)
        await model.refreshMacIdentity().value
        XCTAssertEqual(model.macIdentity?.state, .supported)
        XCTAssertEqual(model.engineInstall.finish?.verification?.verification, .notVerified)
        XCTAssertTrue(model.engineInstallAwaitingVerification)
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: false,
                                               installVerificationPending: model.engineInstallAwaitingVerification)
            XCTAssertEqual(card.stateLabel, "Installed, verifying")
            XCTAssertNotEqual(card.tone, .good)
            XCTAssertFalse(card.message.contains("indicators were found"))
            XCTAssertTrue(installPresentation(model).lines.contains { $0.kind == .warning })
        }

        // Game folder identity written by the engine with the same raw value: repaired.
        files.setFile(gamedirPath, gamedirNonzero)
        await model.refreshMacIdentity().value
        let verification = try XCTUnwrap(model.engineInstall.finish?.verification)
        XCTAssertEqual(verification.verification, .identityRepaired)
        XCTAssertTrue(verification.cidChanged)
        XCTAssertFalse(model.engineInstallAwaitingVerification)
        try english {
            let card = MacIdentityPresentation(report: model.macIdentity, checking: false, engineRunning: false,
                                               installVerificationPending: model.engineInstallAwaitingVerification)
            XCTAssertEqual(card.stateLabel, "Indicators found")
            let lines = installPresentation(model).lines.map(\.text)
            XCTAssertTrue(lines.contains { $0.hasPrefix("Identity verified") && $0.contains("Uniqueness was not verified") })
            XCTAssertTrue(lines.contains { $0.hasPrefix("The identity changed: \(cidBefore) → ") })
            for line in lines {
                XCTAssertFalse(line.contains(MacIdentityFixture.nonzeroCID))
                XCTAssertFalse(line.contains(MacIdentityFixture.nonzeroRawHex))
                XCTAssertFalse(line.lowercased().contains("new random"))
            }
        }
        model.dismissEngineInstallResult()
        XCTAssertEqual(model.engineInstall, .idle)
    }

    func testRefreshWhileTheEngineRunsDoesNotVerify() async throws {
        let model = await unsupportedModel()
        try await confirmAndInstall(model)
        game.isRunning = true
        await model.refreshMacIdentity().value
        XCTAssertNil(model.engineInstall.finish?.verification)
        XCTAssertTrue(model.engineInstallAwaitingVerification)
    }

    func testOpenEngineOnlyOnUserActionAndOnlyWhenClosed() async throws {
        let model = await unsupportedModel()
        try await confirmAndInstall(model)
        XCTAssertEqual(launcher.calls, [])
        game.isRunning = true
        XCTAssertNil(model.openEngineAfterInstall())
        XCTAssertEqual(model.engineInstallLaunchStatus, .engineRunning)
        game.isRunning = false
        await model.openEngineAfterInstall()?.value
        XCTAssertEqual(launcher.calls, [.init(app: EnginePaths.defaultApp, arguments: [])])
        XCTAssertEqual(model.engineInstallLaunchStatus, .launched)
        XCTAssertEqual(model.engineProcessState, .running)
    }

    func testFailureOutcomesAreVisibleWithCodeBackupAndLogged() async throws {
        let backup = EngineBackupLocation(root: URL(fileURLWithPath: "/tmp/engine-backups"), stamp: "20260101-000000",
                                          app: URL(fileURLWithPath: "/tmp/engine-backups/a.app"),
                                          identity: URL(fileURLWithPath: "/tmp/i"), libraries: URL(fileURLWithPath: "/tmp/l"),
                                          manifest: URL(fileURLWithPath: "/tmp/m"))
        let cases: [(EngineInstallOutcome, EngineInstallPresentation.LineKind, String)] = [
            (.failed(.permissionDenied("/Applications")), .error, "permissionDenied"),
            (.rolledBack(.conflict), .error, "conflict"),
            (.rollbackIncomplete(.installFailed), .critical, "installFailed"),
            (.cancelled, .info, "cancelled"),
        ]
        for (outcome, kind, code) in cases {
            service = FakeEngineInstallService()
            var report = EngineInstallReport()
            report.backup = backup
            report.leftovers = ["/tmp/leftover"]
            service.result = EngineInstallResult(outcome: outcome, report: report, log: [])
            files = FakeFileProbe()
            let model = await unsupportedModel()
            try await confirmAndInstall(model)
            XCTAssertEqual(model.engineInstall.finish?.outcome, outcome)
            XCTAssertFalse(model.engineInstallAwaitingVerification)
            XCTAssertTrue(model.errorLog.entries.contains { $0.area == .engineInstall && $0.message.contains(code) }, code)
            XCTAssertTrue(model.errorLog.entries.contains { $0.message.contains("leftovers=1") })
            try english {
                let presentation = installPresentation(model)
                XCTAssertEqual(presentation.lines.first?.kind, kind, code)
                if outcome != .cancelled { XCTAssertTrue(presentation.lines.first?.text.contains("code: \(code)") == true) }
                XCTAssertTrue(presentation.lines.contains { $0.text.contains("/tmp/engine-backups · 20260101-000000") })
                XCTAssertTrue(presentation.lines.contains { $0.text.contains("could not be cleaned up") })
                XCTAssertTrue(presentation.showsDismiss)
                XCTAssertFalse(presentation.lines.contains { $0.text.contains("Identity verified") })
            }
        }
        try english {
            XCTAssertTrue(EngineInstallPresentation.text(.permissionDenied("/Applications"))
                .hasPrefix("Administrator permission required: /Applications is not writable."))
        }
    }

    func testCancelDuringDownloadCancelsTheTask() async throws {
        service.hold = .downloading
        let model = await unsupportedModel()
        await model.requestEngineInstall()?.value
        let task = try XCTUnwrap(model.confirmEngineInstall(acceptedCIDWarning: true))
        for _ in 0..<20_000 { if case .installing(let p, _) = model.engineInstall, p.bytes == 10 { break }; await Task.yield() }
        try english {
            let progress = try XCTUnwrap(installPresentation(model).progress)
            XCTAssertTrue(progress.cancellable)
            XCTAssertEqual(progress.fraction, 0.1)
            XCTAssertTrue(progress.text.contains("%") && progress.text.hasPrefix("Downloading: "), progress.text)
        }
        XCTAssertTrue(model.isEngineInstallRunning)
        XCTAssertNil(model.requestEngineInstall())   // a second install is refused
        XCTAssertEqual(service.fetchCount, 1)
        model.cancelEngineInstall()
        await task.value
        await settle(model)
        XCTAssertTrue(service.cancelSeen)
        XCTAssertEqual(model.engineInstall.finish?.outcome, .cancelled)
    }

    func testNoCancelAfterTheBackupStarted() async throws {
        service.hold = .backingUp
        let model = await unsupportedModel()
        await model.requestEngineInstall()?.value
        let task = try XCTUnwrap(model.confirmEngineInstall(acceptedCIDWarning: true))
        for _ in 0..<20_000 { if case .installing(let p, _) = model.engineInstall, p.phase == .backingUp { break }; await Task.yield() }
        try english {
            let presentation = installPresentation(model)
            XCTAssertEqual(presentation.progress?.cancellable, false)
            XCTAssertTrue(presentation.lines.contains { $0.text.hasPrefix("This step cannot be cancelled") })
        }
        model.cancelEngineInstall()
        model.engineInstallWindowWillClose()
        try await Task.sleep(for: .milliseconds(20))
        service.releaseHold()
        await task.value
        await settle(model)
        XCTAssertFalse(service.cancelSeen)
        XCTAssertEqual(model.engineInstall.finish?.outcome, .installed)
    }

    func testProgressTextsAndCancelOnlyInDownloadingAndExtracting() throws {
        try english {
            for phase in EngineInstallPhase.allCases {
                let presentation = EngineInstallPresentation(
                    availability: .hidden, flow: .installing(EngineInstallProgress(phase: phase), cancelling: false),
                    awaitingVerification: false, launchStatus: nil)
                XCTAssertEqual(presentation.progress?.cancellable, phase == .downloading || phase == .extracting, "\(phase)")
                XCTAssertFalse(presentation.progress?.text.isEmpty ?? true)
                XCTAssertNotNil(presentation.announcement)
            }
            XCTAssertEqual(EngineInstallPresentation.text(EngineInstallProgress(phase: .extracting)), "Extracting the archive…")
            XCTAssertEqual(EngineInstallSection.symbol(.critical), "exclamationmark.octagon.fill")   // not colour alone
        }
    }

    // MARK: Backups

    private func makeBackups(_ stamps: [String]) throws -> URL {
        let root = AppPaths(home: env.home).engineBackupsDirectory
        for stamp in stamps {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("identity-\(stamp)"),
                                                    withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: root.appendingPathComponent("manifest-\(stamp).json"))
        }
        return root
    }

    private func stamps(_ count: Int) -> [String] { (1...count).map { String(format: "202601%02d-000000", $0) } }

    func testBackupsAreDeletedOnlyAfterTheConfirmation() async throws {
        let root = try makeBackups(stamps(5))
        let model = makeModel()
        model.loadEngineBackups()
        XCTAssertEqual(model.engineBackups?.groups.count, 5)
        XCTAssertEqual(model.engineBackups?.pruneCandidates.map(\.stamp), ["20260102-000000", "20260101-000000"])
        model.requestEngineBackupDeletion()
        XCTAssertTrue(model.showsEngineBackupDeletionConfirmation)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10)
        model.cancelEngineBackupDeletion()
        model.confirmEngineBackupDeletion()   // no token any more: nothing happens
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10)

        model.requestEngineBackupDeletion()
        model.confirmEngineBackupDeletion()
        XCTAssertEqual(model.engineBackupDeletion?.status, .success)
        XCTAssertEqual(model.engineBackups?.groups.map(\.stamp), ["20260105-000000", "20260104-000000", "20260103-000000"])
        try english {
            let messages = EngineBackupsPresentation.messages(loadError: nil, deletion: model.engineBackupDeletion,
                                                              deletionError: nil)
            XCTAssertEqual(messages.map(\.text), ["2 backups deleted."])
            XCTAssertEqual(EngineBackupsPresentation(inventory: model.engineBackups).rows.first, "20260105-000000 — kept")
        }
    }

    func testChangedFolderOrRunningInstallDeletesNothing() async throws {
        let root = try makeBackups(stamps(4))
        let model = makeModel()
        model.requestEngineBackupDeletion()
        _ = try makeBackups(["20260110-000000"])   // a new backup appears after the confirmation
        model.confirmEngineBackupDeletion()
        XCTAssertEqual(model.engineBackupDeletionError, .confirmationRequired)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10)
        try english {
            XCTAssertEqual(EngineBackupsPresentation.messages(loadError: nil, deletion: nil,
                                                              deletionError: .confirmationRequired).map(\.text),
                           ["The backup list changed; confirm again to delete."])
        }
    }

    func testPartialDeletionIsShownAndLogged() async throws {
        let root = try makeBackups(stamps(4))
        let locked = backupLock(env)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let model = makeModel()
        model.requestEngineBackupDeletion()
        model.confirmEngineBackupDeletion()
        XCTAssertEqual(model.engineBackupDeletion?.status, .partialFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest-20260101-000000.json").path))
        XCTAssertTrue(model.errorLog.entries.contains { $0.area == .engineInstall && $0.message.contains("partialFailure") })
        try english {
            let messages = EngineBackupsPresentation.messages(loadError: nil, deletion: model.engineBackupDeletion,
                                                              deletionError: nil)
            XCTAssertTrue(messages.first?.isError == true)
            XCTAssertTrue(messages.first?.text.contains("20260101-000000: removeFailed") == true)
        }
    }
}

/// `playeridentityctl engine …`: parsing, exit codes, confirmation, JSON lines and privacy.
final class EngineInstallCLITests: XCTestCase {
    private let home = MacIdentityFixture.home

    private func context(_ files: FakeFileProbe, service: FakeEngineInstallService, prompt: CLIPrompt = .none,
                         running: Bool = false, paths: AppPaths? = nil) -> CLIContext {
        var context = CLIContext(version: "2.25.0", build: "53", paths: paths ?? AppPaths(home: home),
                                 environment: [CLIContext.snapshotEnvironmentKey: "/nonexistent/profile.json"],
                                 fileSystem: LocalFileSystem(), resolver: FakeAddressResolver(),
                                 udpTransport: FakeServer.healthy(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        context.fileProbe = files
        context.gameProcessDetector = FakeGameDetector(running: running)
        context.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        context.defaultsSuite = "PlayerIdentityTests-\(UUID().uuidString)"
        context.engineArchitecture = .arm64
        context.prompt = prompt
        context.engineInstallerFactory = { environment in
            service.record(environment)
            return service
        }
        return context
    }

    private func engine(_ options: MachOFixture.Options, identity: String) -> FakeFileProbe {
        let files = FakeFileProbe()
        files.installEngine(executable: MachOFixture.thin(options))
        files.setFile(home.path + "/.config/.xash_id", identity)
        return files
    }

    private var unsupported: FakeFileProbe { engine(MachOFixture.installed, identity: MacIdentityFixture.zeroFile) }

    func testParsing() {
        XCTAssertEqual(try CLIParser.parse(["engine", "status", "--json"]).get(), .engineStatus(json: true))
        XCTAssertEqual(try CLIParser.parse(["engine", "install-compatible", "--yes"]).get(),
                       .engineInstall(yes: true, json: false))
        XCTAssertEqual(try CLIParser.parse(["engine", "backups"]).get(), .engineBackups(json: false))
        XCTAssertEqual(try CLIParser.parse(["engine", "backups", "delete", "--confirm", "abc", "--json"]).get(),
                       .engineBackupsDelete(confirm: "abc", json: true))
        for arguments in [["engine"], ["engine", "nope"], ["engine", "status", "--yes"], ["engine", "status", "x"],
                          ["engine", "backups", "delete"], ["engine", "backups", "--confirm", "a"],
                          ["engine", "install-compatible", "--confirm", "a"], ["engine", "status", "--app", "x"],
                          ["status", "--confirm", "a"]] {
            guard case .failure = CLIParser.parse(arguments) else { return XCTFail("\(arguments) should fail") }
        }
        XCTAssertTrue(CLIRunner.usage.contains("engine install-compatible [--yes] [--json]"))
        XCTAssertFalse(CLIRunner.usage.lowercased().contains("unique identity"))
    }

    func testNoTerminalWithoutYesIsAUsageErrorBeforeAnyNetworkCall() async {
        let service = FakeEngineInstallService()
        let result = await CLIRunner.run(arguments: ["engine", "install-compatible", "--json"],
                                         context: context(unsupported, service: service))
        XCTAssertEqual(result.exitCode, CLIExit.usage)
        XCTAssertEqual(service.fetchCount, 0)
        XCTAssertEqual(service.installCount, 0)
    }

    func testNotOfferedAndRunningExitCodes() async {
        let service = FakeEngineInstallService()
        let healthy = await CLIRunner.run(arguments: ["engine", "install-compatible", "--yes"],
                                          context: context(engine(MachOFixture.upstream, identity: MacIdentityFixture.nonzeroFile),
                                                           service: service))
        XCTAssertEqual(healthy.exitCode, CLIExit.engineNotOffered)
        let running = await CLIRunner.run(arguments: ["engine", "install-compatible", "--yes"],
                                          context: context(unsupported, service: service, running: true))
        XCTAssertEqual(running.exitCode, CLIExit.engineFailed)
        var intel = context(unsupported, service: service)
        intel.engineArchitecture = .amd64
        let intelResult = await CLIRunner.run(arguments: ["engine", "install-compatible", "--yes"], context: intel)
        XCTAssertEqual(intelResult.exitCode, CLIExit.engineNotOffered)
        XCTAssertEqual(service.fetchCount, 0)
        XCTAssertEqual(service.installCount, 0)
    }

    func testDeclinedPromptShowsTheWarningAndInstallsNothing() async {
        let service = FakeEngineInstallService()
        let asked = QuestionBox()
        let prompt = CLIPrompt(isInteractive: true) { question in
            asked.set(question)
            return false
        }
        let result = await CLIRunner.run(arguments: ["engine", "install-compatible"],
                                         context: context(unsupported, service: service, prompt: prompt))
        XCTAssertEqual(result.exitCode, CLIExit.engineCancelled)
        XCTAssertEqual(service.installCount, 0)
        XCTAssertTrue(asked.value.contains("This update may create a new identity (CID)."))
        XCTAssertTrue(asked.value.contains(EngineReleaseFixture.commit))
        XCTAssertFalse(asked.value.contains(MacIdentityFixture.zeroCID))
    }

    func testYesInstallsWithJSONLinesAndNoRawOrFullCID() async throws {
        let service = FakeEngineInstallService()
        let result = await CLIRunner.run(arguments: ["engine", "install-compatible", "--yes", "--json"],
                                         context: context(unsupported, service: service))
        XCTAssertEqual(result.exitCode, CLIExit.engineInstalled)
        XCTAssertEqual(service.installCount, 1)
        XCTAssertEqual(service.confirmations.first?.acceptedCIDWarning, true)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 1)
        var last: [String: Any] = [:]
        for line in lines {
            last = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(last["stage"])
            XCTAssertNotNil(last["cidBefore"])
        }
        XCTAssertEqual(last["outcome"] as? String, "installed")
        XCTAssertEqual(last["supported"] as? Bool, false)
        XCTAssertEqual(last["identity_verification"] as? String, "pending")
        for secret in [MacIdentityFixture.zeroCID, "0000000000000000", MacIdentityFixture.zeroFile.trimmingCharacters(in: .newlines)] {
            XCTAssertFalse(result.stdout.contains(secret), secret)
            XCTAssertFalse(result.stderr.contains(secret), secret)
        }
        XCTAssertEqual(service.environments.first?.targetApp, EnginePaths.defaultApp)
    }

    func testOutcomeExitCodes() async {
        let cases: [(EngineInstallOutcome, Int32)] = [(.failed(.digestMismatch), 2), (.rolledBack(.conflict), 3),
                                                      (.rollbackIncomplete(.installFailed), 2), (.cancelled, 3)]
        for (outcome, code) in cases {
            let service = FakeEngineInstallService()
            service.result = EngineInstallResult(outcome: outcome, report: EngineInstallReport(), log: [])
            let result = await CLIRunner.run(arguments: ["engine", "install-compatible", "--yes"],
                                             context: context(unsupported, service: service))
            XCTAssertEqual(result.exitCode, code, "\(outcome)")
            XCTAssertFalse(result.stderr.isEmpty)
        }
        let failing = FakeEngineInstallService()
        failing.release = .failure(.digestMissing)
        let fetch = await CLIRunner.run(arguments: ["engine", "install-compatible", "--yes"],
                                        context: context(unsupported, service: failing))
        XCTAssertEqual(fetch.exitCode, CLIExit.engineFailed)
        XCTAssertEqual(failing.installCount, 0)
    }

    func testStatusIsOfflineAndBackupsDeleteNeedsTheCurrentCode() async throws {
        let service = FakeEngineInstallService()
        let status = await CLIRunner.run(arguments: ["engine", "status", "--json"],
                                         context: context(unsupported, service: service))
        XCTAssertEqual(status.exitCode, CLIExit.ok)
        XCTAssertEqual(service.fetchCount, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(status.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["install_offered"] as? Bool, true)
        XCTAssertEqual(object["network"] as? Bool, false)
        XCTAssertFalse(status.stdout.contains(MacIdentityFixture.zeroCID))

        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.physicalURL)
        for day in 1...5 {
            let stamp = String(format: "202601%02d-000000", day)
            try FileManager.default.createDirectory(at: paths.engineBackupsDirectory.appendingPathComponent("libs-\(stamp)"),
                                                    withIntermediateDirectories: true)
        }
        let ctx = context(unsupported, service: service, paths: paths)
        let list = await CLIRunner.run(arguments: ["engine", "backups", "--json"], context: ctx)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [String: Any])
        let code = try XCTUnwrap(listed["confirmation_code"] as? String)
        XCTAssertEqual((listed["prune_candidates"] as? [String])?.count, 2)
        let wrong = await CLIRunner.run(arguments: ["engine", "backups", "delete", "--confirm", "nope"], context: ctx)
        XCTAssertEqual(wrong.exitCode, CLIExit.engineFailed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.engineBackupsDirectory.path).count, 5)
        let deleted = await CLIRunner.run(arguments: ["engine", "backups", "delete", "--confirm", code], context: ctx)
        XCTAssertEqual(deleted.exitCode, CLIExit.ok)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.engineBackupsDirectory.path).count, 3)
        let stale = await CLIRunner.run(arguments: ["engine", "backups", "delete", "--confirm", code], context: ctx)
        XCTAssertEqual(stale.exitCode, CLIExit.engineFailed)
    }
}

private final class QuestionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String { lock.withLock { stored } }
    func set(_ text: String) { lock.withLock { stored = text } }
}

/// The new texts exist in all 26 languages, keep the spec wording and promise no random or unique identity.
final class EngineInstallLocalizationTests: XCTestCase {
    private static let languages = ["tr", "en", "de", "fr", "es", "it", "pt", "nl", "sv", "pl", "cs", "ro", "hu", "el", "bg",
                                    "uk", "ru", "ar", "fa", "hi", "zh-Hans", "ja", "ko", "id", "az", "vi"]

    private var keys: [L10nKey] {
        L10nKey.allCases.filter { $0.rawValue.hasPrefix("engineInstall.") || $0.rawValue.hasPrefix("engineBackups.") }
    }

    func testEveryLanguageHasEveryKey() throws {
        XCTAssertEqual(keys.count, 75)
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

    func testSpecWordingAndNoRandomOrUniqueIdentityClaims() throws {
        let tr = try XCTUnwrap(L10n.languageBundle("tr"))
        L10n.$bundle.withValue(tr) {
            XCTAssertEqual(L10n.text(.engineInstallActionInstall), "Uyumlu motoru kur")
            XCTAssertEqual(L10n.text(.engineInstallConfirmCidWarning),
                           "Bu güncelleme yeni bir kimlik (CID) oluşturabilir. Sunucudaki ban veya hesap kaydı yeni kimlikle eşleşmeyebilir.")
            XCTAssertEqual(L10n.text(.engineInstallReasonPermission),
                           "Yönetici izni gerekli: /Applications yazılamıyor. Uygulamayı Applications klasöründen kurabilir veya izni verebilirsiniz.")
            XCTAssertEqual(L10n.format(.engineInstallResultCidChanged, "aaaa…bbbb", "cccc…dddd"),
                           "Kimlik değişti: aaaa…bbbb → cccc…dddd. Sunucu kayıtlarınızı kontrol edin.")
        }
        for language in ["tr", "en"] {
            let bundle = try XCTUnwrap(L10n.languageBundle(language))
            L10n.$bundle.withValue(bundle) {
                for key in keys {
                    let text = L10n.text(key).lowercased()
                    for banned in ["new random", "yeni rastgele", "unique identity", "benzersiz", "tekil kimlik"] {
                        XCTAssertFalse(text.contains(banned), "\(language): \(key.rawValue)")
                    }
                }
            }
        }
    }
}

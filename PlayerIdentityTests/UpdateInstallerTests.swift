import XCTest
@testable import PlayerIdentity

/// §27.5: installer scenarios with a fake feed, downloader, tools and file system (no network, temp folders only).
final class UpdateInstallerTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: AppPaths!
    private var installed: URL!

    override func setUp() async throws {
        temp = try TempDirectory()
        paths = AppPaths(home: try temp.makeDirectory("home"))
        installed = try temp.makeDirectory("Applications").appendingPathComponent("PlayerIdentity.app", isDirectory: true)
        try UpdateFixture.makeApp(at: installed, bundleID: UpdateInstaller.bundleID, version: "1.1.0", marker: "old")
    }

    override func tearDown() async throws { temp = nil }

    private func installer(_ downloader: FakeUpdateDownloader, runner: FakeUpdateRunner = FakeUpdateRunner(),
                           files: UpdateFileManaging = LocalUpdateFileManager(), relauncher: FakeRelauncher = FakeRelauncher(),
                           current: String = "1.1.0", admin: Bool = true) -> UpdateInstaller {
        var installer = UpdateInstaller(paths: paths, installedApp: installed, currentVersion: current, downloader: downloader,
                                        fileManager: files, runner: runner, relauncher: relauncher)
        installer.allowAdministratorPrompt = admin
        return installer
    }

    private var backupApp: URL { paths.updateAppBackups.appendingPathComponent("PlayerIdentity-1.1.0.app", isDirectory: true) }

    private func assertNoLeftovers(file: StaticString = #filePath, line: UInt = #line) {
        let downloads = (try? FileManager.default.contentsOfDirectory(atPath: paths.updateDownloads.path)) ?? []
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: paths.updateStaging.path)) ?? []
        XCTAssertEqual(downloads, [], "downloads", file: file, line: line)
        XCTAssertEqual(staging, [], "staging", file: file, line: line)
    }

    private func assertOldAppInPlace(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old", file: file, line: line)
    }

    private func installError(_ installer: UpdateInstaller, _ release: AppRelease) async -> UpdateError? {
        do {
            _ = try await installer.install(release)
            return nil
        } catch {
            return error as? UpdateError
        }
    }

    // MARK: Happy path

    func testHappyPathVerifiesReplacesBacksUpAndRelaunches() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        let relauncher = FakeRelauncher()
        let phases = PhaseLog()
        let result = try await installer(FakeUpdateDownloader(files), runner: runner, relauncher: relauncher)
            .install(release) { await phases.add($0) }

        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
        XCTAssertEqual(UpdateFixture.marker(of: backupApp), "old")
        XCTAssertEqual(result, UpdateInstaller.Result(installed: installed, backup: backupApp, version: "1.2.0"))
        XCTAssertEqual(relauncher.relaunched, [installed])
        let kinds = runner.commands.map { command -> String in
            switch command {
            case .unzip: return "unzip"
            case .verifySignature: return "verify"
            case .signingInfo: return "info"
            case .assess: return "gatekeeper"
            case .removeQuarantine: return "quarantine"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["unzip", "verify", "info", "gatekeeper", "quarantine"])
        let recorded = await phases.phases
        XCTAssertEqual(recorded, [.downloading(1), .verifying, .installing, .relaunching])
        assertNoLeftovers()
    }

    // MARK: Verification failures (nothing installed, downloads deleted)

    func testChecksumMismatch() async throws {
        let (release, files) = UpdateFixture.release("1.2.0", sums: "\(String(repeating: "0", count: 64))  PlayerIdentity-1.2.0-macos.zip\n")
        let error = await installError(installer(FakeUpdateDownloader(files)), release)
        XCTAssertEqual(error, .checksumMismatch)
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testChecksumMissingForTheZip() async throws {
        let (release, files) = UpdateFixture.release("1.2.0", sums: "\(String(repeating: "a", count: 64))  other.zip\n")
        let error = await installError(installer(FakeUpdateDownloader(files)), release)
        XCTAssertEqual(error, .checksumMissing)
        assertNoLeftovers()
    }

    func testSizeMismatch() async throws {
        let (release, files) = UpdateFixture.release("1.2.0", zipSize: 9_999)
        let error = await installError(installer(FakeUpdateDownloader(files)), release)
        XCTAssertEqual(error, .sizeMismatch(expected: 9_999, actual: Data("zip-bytes".utf8).count))
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testWrongTeam() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        runner.teamID = "AAAAAAAAAA"
        let error = await installError(installer(FakeUpdateDownloader(files), runner: runner), release)
        XCTAssertEqual(error, .teamMismatch(found: "AAAAAAAAAA"))
        assertOldAppInPlace()
        assertNoLeftovers()
        XCTAssertFalse(runner.commands.contains { if case .open = $0 { return true } else { return false } })
    }

    func testUnsignedAppIsRejected() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        runner.signatureValid = false
        let error = await installError(installer(FakeUpdateDownloader(files), runner: runner), release)
        XCTAssertEqual(error, .signatureInvalid)
        assertOldAppInPlace()
    }

    func testWrongBundle() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        runner.bundleID = "com.example.other"
        let error = await installError(installer(FakeUpdateDownloader(files), runner: runner), release)
        XCTAssertEqual(error, .bundleMismatch(found: "com.example.other"))
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testVersionMismatch() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        runner.appVersion = "1.3.0"
        let error = await installError(installer(FakeUpdateDownloader(files), runner: runner), release)
        XCTAssertEqual(error, .versionMismatch(found: "1.3.0"))
        assertOldAppInPlace()
    }

    func testUnzipFailure() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        runner.unzipStatus = 1
        let error = await installError(installer(FakeUpdateDownloader(files), runner: runner), release)
        XCTAssertEqual(error, .unzipFailed)
        assertNoLeftovers()
    }

    // MARK: Rollback

    func testRollbackWhenTheNewAppCannotBePutInPlace() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let faulty = FaultyFileManager()
        faulty.failMoveFrom = paths.updateStaging
        let relauncher = FakeRelauncher()
        let error = await installError(installer(FakeUpdateDownloader(files), files: faulty, relauncher: relauncher), release)
        XCTAssertEqual(error, .installFailed(rolledBack: true, backup: nil))
        assertOldAppInPlace()
        XCTAssertEqual(relauncher.relaunched, [])
        assertNoLeftovers()
    }

    func testRollbackWhenTheNewAppDoesNotOpen() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let relauncher = FakeRelauncher()
        relauncher.fails = true
        let error = await installError(installer(FakeUpdateDownloader(files), relauncher: relauncher), release)
        XCTAssertEqual(error, .installFailed(rolledBack: true, backup: nil))
        assertOldAppInPlace()
    }

    func testFailedRollbackReportsTheBackupLocation() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let faulty = FaultyFileManager()
        faulty.failMovesAfter = 1   // current → backup works, everything after fails
        let error = await installError(installer(FakeUpdateDownloader(files), files: faulty), release)
        XCTAssertEqual(error, .installFailed(rolledBack: false, backup: backupApp))
        XCTAssertEqual(UpdateFixture.marker(of: backupApp), "old")
    }

    // MARK: Cancel, HTTP, same version

    func testCancelDuringDownloadChangesNothing() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let downloader = FakeUpdateDownloader(files)
        downloader.cancelOn = release.zip?.downloadURL
        let runner = FakeUpdateRunner()
        let error = await installError(installer(downloader, runner: runner), release)
        XCTAssertEqual(error, .cancelled)
        XCTAssertEqual(runner.commands, [])
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testCancelledTaskStopsBeforeInstalling() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        let subject = installer(FakeUpdateDownloader(files), runner: runner)
        let task = Task { try await subject.install(release) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? UpdateError, .cancelled)
        }
        assertOldAppInPlace()
    }

    func testHTTPIsRejectedExceptLoopback() async throws {
        let (insecure, files) = UpdateFixture.release("1.2.0", host: "http://github.com")
        let downloader = FakeUpdateDownloader(files)
        let error = await installError(installer(downloader), insecure)
        XCTAssertEqual(error, .insecureURL)
        XCTAssertEqual(downloader.requestedURLs, [])

        XCTAssertTrue(UpdateInstaller.isAllowedURL(URL(string: "https://github.com/x.zip")!))
        XCTAssertTrue(UpdateInstaller.isAllowedURL(URL(string: "http://127.0.0.1:8080/x.zip")!))
        XCTAssertFalse(UpdateInstaller.isAllowedURL(URL(string: "http://localhost/x.zip")!))
        XCTAssertFalse(UpdateInstaller.isAllowedURL(URL(string: "file:///tmp/x.zip")!))
        XCTAssertFalse(UpdateInstaller.isAllowedURL(URL(string: "ftp://github.com/x.zip")!))

        let (loopback, loopbackFiles) = UpdateFixture.release("1.2.0", host: "http://127.0.0.1:8080")
        _ = try await installer(FakeUpdateDownloader(loopbackFiles)).install(loopback)
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
    }

    func testSameVersionAndMissingAssetsAreRejected() async throws {
        let (same, files) = UpdateFixture.release("1.1.0")
        let error = await installError(installer(FakeUpdateDownloader(files)), same)
        XCTAssertEqual(error, .sameVersion)
        let bare = AppRelease(version: SemanticVersion("1.2.0")!, versionString: "1.2.0", tag: "v1.2.0", pageURL: nil,
                              notes: "", publishedAt: nil, zip: nil, sums: nil)
        let missing = await installError(installer(FakeUpdateDownloader([:])), bare)
        XCTAssertEqual(missing, .missingAsset)
    }

    // MARK: Not writable → administrator prompt

    func testNotWritableUsesTheAdministratorPrompt() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let faulty = FaultyFileManager()
        faulty.notWritable = [installed.deletingLastPathComponent().standardizedFileURL]
        let runner = FakeUpdateRunner()
        _ = try await installer(FakeUpdateDownloader(files), runner: runner, files: faulty).install(release)
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
        XCTAssertEqual(UpdateFixture.marker(of: backupApp), "old")
        let admin = try XCTUnwrap(runner.commands.first { if case .adminReplace = $0 { return true } else { return false } })
        XCTAssertTrue(UpdateCommandAllowlist.isAllowed(admin.argv))
    }

    func testNotWritableWithoutPromptOrWhenDeclined() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let faulty = FaultyFileManager()
        faulty.notWritable = [installed.deletingLastPathComponent().standardizedFileURL]
        let disallowed = await installError(installer(FakeUpdateDownloader(files), files: faulty, admin: false), release)
        XCTAssertEqual(disallowed, .notWritable)

        let runner = FakeUpdateRunner()
        runner.adminResult = CommandOutput(status: 1, output: "execution error: User canceled. (-128)")
        let declined = await installError(installer(FakeUpdateDownloader(files), runner: runner, files: faulty), release)
        XCTAssertEqual(declined, .cancelledByUser)
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testAdministratorPromptThatCannotStartIsReportedSeparately() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let faulty = FaultyFileManager()
        faulty.notWritable = [installed.deletingLastPathComponent().standardizedFileURL]
        let runner = FakeUpdateRunner()
        runner.adminLaunchFails = true
        let error = await installError(installer(FakeUpdateDownloader(files), runner: runner, files: faulty), release)
        XCTAssertEqual(error, .adminPromptFailed)
        assertOldAppInPlace()
        assertNoLeftovers()
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertTrue(UpdateStatusText.error(.cancelledByUser).hasPrefix("Kurulum iptal edildi"))
            XCTAssertNotEqual(UpdateStatusText.error(.adminPromptFailed), UpdateStatusText.error(.notWritable))
            XCTAssertNotEqual(UpdateStatusText.error(.cancelledByUser), UpdateStatusText.error(.notWritable))
        }
    }

    // MARK: Allowlist

    func testCommandAllowlist() throws {
        let app = try XCTUnwrap(UpdatePath(URL(fileURLWithPath: "/Applications/PlayerIdentity.app")))
        let zip = try XCTUnwrap(UpdatePath(URL(fileURLWithPath: "/Users/u/Library/Application Support/x/a.zip")))
        let commands: [UpdateCommand] = [.unzip(zip, into: app), .verifySignature(app), .signingInfo(app), .assess(app),
                                         .removeQuarantine(app), .open(app),
                                         .adminReplace(current: app, backup: zip, staged: app)]
        for command in commands { XCTAssertTrue(UpdateCommandAllowlist.isAllowed(command.argv), "\(command)") }
        XCTAssertEqual(UpdateCommand.verifySignature(app).argv,
                       ["/usr/bin/codesign", "--verify", "--deep", "--strict", "/Applications/PlayerIdentity.app"])
        XCTAssertEqual(UpdateCommand.unzip(zip, into: app).argv.prefix(3), ["/usr/bin/ditto", "-x", "-k"])

        for bad in ["/tmp/a'b.app", "/tmp/a\"b.app", "/tmp/$(id).app", "/tmp/a`b`.app", "/tmp/a\\b.app", "/tmp/a\nb.app"] {
            XCTAssertNil(UpdatePath(URL(fileURLWithPath: bad)), bad)
        }
        XCTAssertNil(UpdatePath(URL(string: "https://example.com/x")!))
        XCTAssertFalse(UpdateCommandAllowlist.isAllowed(["/bin/sh", "-c", "id"]))
        XCTAssertFalse(UpdateCommandAllowlist.isAllowed(["/usr/bin/open", "-a", "Terminal"]))
        XCTAssertFalse(UpdateCommandAllowlist.isAllowed(["/usr/bin/osascript", "-e", "do shell script \"id\" with administrator privileges"]))
        XCTAssertFalse(UpdateCommandAllowlist.isAllowed(["/usr/bin/ditto", "-x", "-k", "relative.zip", "/tmp"]))
    }

    /// Real `codesign` through the allowlisted runner on the installed app (read-only; skipped if absent).
    func testRealCodesignOutputOfTheInstalledApp() async throws {
        let app = URL(fileURLWithPath: "/Applications/PlayerIdentity.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path), let path = UpdatePath(app) else {
            throw XCTSkip("PlayerIdentity.app is not installed")
        }
        let runner = ProcessUpdateCommandRunner()
        let info = try await runner.run(.signingInfo(path))
        let fields = UpdateInstaller.signingFields(info.output)
        XCTAssertEqual(fields["Identifier"], UpdateInstaller.bundleID)
        guard fields["TeamIdentifier"] == UpdateInstaller.teamID else { throw XCTSkip("installed copy is not Developer ID signed") }
        let verify = try await runner.run(.verifySignature(path))
        XCTAssertEqual(verify.status, 0, verify.output)
    }

    func testSigningFieldsAndHash() {
        let fields = UpdateInstaller.signingFields("Executable=/a\nIdentifier=tr.ercanatay.playeridentity\nTeamIdentifier=GJ3Y762WQ9\n")
        XCTAssertEqual(fields["TeamIdentifier"], "GJ3Y762WQ9")
        XCTAssertEqual(fields["Identifier"], "tr.ercanatay.playeridentity")
        XCTAssertEqual(UpdateInstaller.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

actor PhaseLog {
    private(set) var phases: [InstallPhase] = []
    func add(_ phase: InstallPhase) { phases.append(phase) }
}

// MARK: - Hardening: Gatekeeper, tool time limits and cancellation

extension UpdateInstallerTests {
    func testGatekeeperRejectionStopsTheInstallAndDeletesTheDownload() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let rejections = [
            CommandOutput(status: 3, output: "/x/PlayerIdentity.app: rejected\nsource=Unnotarized Developer ID"),
            CommandOutput(status: 0, output: "/x/PlayerIdentity.app: rejected"),   // exit 0 alone is not enough
            CommandOutput(status: 0, output: ""),
            CommandOutput(status: 0, output: "/x/PlayerIdentity.app: accepted"),   // no notarized source
        ]
        for result in rejections {
            let runner = FakeUpdateRunner()
            runner.gatekeeperResult = result
            let relauncher = FakeRelauncher()
            let error = await installError(installer(FakeUpdateDownloader(files), runner: runner, relauncher: relauncher), release)
            XCTAssertEqual(error, .gatekeeperRejected, result.output)
            assertOldAppInPlace()
            assertNoLeftovers()
            XCTAssertEqual(relauncher.relaunched, [])
            XCTAssertTrue(runner.commands.contains { if case .assess = $0 { return true } else { return false } })
        }
    }

    func testGatekeeperOutputParsing() {
        XCTAssertTrue(UpdateInstaller.gatekeeperAccepted(CommandOutput(
            status: 0, output: "/Applications/PlayerIdentity.app: accepted\nsource=Notarized Developer ID\n")))
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted(CommandOutput(status: 3, output: "/a.app: accepted")))
        // §49.8: "accepted" alone is not enough; the notarized Developer ID source is required.
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted(CommandOutput(status: 0, output: "/a.app: accepted\n")))
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted(CommandOutput(
            status: 0, output: "/a.app: accepted\nsource=Developer ID\n")))
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted(CommandOutput(
            status: 0, output: "/a.app: rejected\nsource=Notarized Developer ID\n")))
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted(CommandOutput(
            status: 0, output: "/bin/ls: rejected (the code is valid but does not seem to be an app)")))
        // A folder named "accepted" in the path does not count.
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted(CommandOutput(status: 0, output: "/tmp/accepted/App.app: rejected")))
    }

    /// Real `spctl` through the allowlisted runner on the installed notarized app (read-only; skipped if absent).
    func testRealGatekeeperAssessmentOfTheInstalledApp() async throws {
        let app = URL(fileURLWithPath: "/Applications/PlayerIdentity.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path), let path = UpdatePath(app) else {
            throw XCTSkip("PlayerIdentity.app is not installed")
        }
        let runner = ProcessUpdateCommandRunner()
        let fields = UpdateInstaller.signingFields(try await runner.run(.signingInfo(path)).output)
        guard fields["TeamIdentifier"] == UpdateInstaller.teamID else { throw XCTSkip("installed copy is not Developer ID signed") }
        let output = try await runner.run(.assess(path))
        XCTAssertTrue(UpdateInstaller.gatekeeperAccepted(output), output.output)
    }

    func testATimedOutToolStopsTheInstallAndDeletesTheDownload() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        runner.failure = { command in
            if case .verifySignature = command { return UpdateError.processTimedOut(tool: command.toolName) }
            return nil
        }
        let error = await installError(installer(FakeUpdateDownloader(files), runner: runner), release)
        XCTAssertEqual(error, .processTimedOut(tool: "codesign"))
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testCancellingAHangingVerificationStepCleansUp() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let runner = FakeUpdateRunner()
        runner.assessWaitsForCancellation = true
        let installer = installer(FakeUpdateDownloader(files), runner: runner)
        let task = Task { try await installer.prepare(release) }
        for _ in 0..<250 where !runner.commands.contains(where: { if case .assess = $0 { return true } else { return false } }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("prepare should be cancelled")
        } catch {
            XCTAssertEqual(error as? UpdateError, .cancelled)
        }
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testCommandTimeLimitsCancellationAndErrorMapping() throws {
        let app = try XCTUnwrap(UpdatePath(URL(fileURLWithPath: "/Applications/PlayerIdentity.app")))
        let zip = try XCTUnwrap(UpdatePath(URL(fileURLWithPath: "/tmp/a.zip")))
        for command in [UpdateCommand.unzip(zip, into: app), .verifySignature(app), .signingInfo(app), .assess(app)] {
            XCTAssertEqual(command.timeout, UpdateCommand.defaultTimeout, "\(command)")
            XCTAssertTrue(command.isCancellable, "\(command)")
        }
        for command in [UpdateCommand.removeQuarantine(app), .open(app)] {
            XCTAssertEqual(command.timeout, UpdateCommand.defaultTimeout, "\(command)")
            XCTAssertFalse(command.isCancellable, "\(command)")
        }
        let admin = UpdateCommand.adminReplace(current: app, backup: zip, staged: app)
        XCTAssertNil(admin.timeout, "the administrator prompt waits for the user")
        XCTAssertFalse(admin.isCancellable)
        XCTAssertEqual(UpdateCommand.defaultTimeout, 120)
        XCTAssertEqual(UpdateCommand.assess(app).toolName, "spctl")

        let timedOut = ProcessUpdateCommandRunner.mapped(CommandError.timedOut, command: .verifySignature(app))
        XCTAssertEqual(timedOut as? UpdateError, .processTimedOut(tool: "codesign"))
        XCTAssertTrue(ProcessUpdateCommandRunner.mapped(CommandError.cancelled, command: .assess(app)) is CancellationError)
        XCTAssertEqual(ProcessUpdateCommandRunner.mapped(CommandError.launchFailed, command: .open(app)) as? CommandError, .launchFailed)
    }

    func testNewUpdateErrorTextsInBothLanguages() throws {
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                let gatekeeper = UpdateStatusText.error(.gatekeeperRejected)
                let timeout = UpdateStatusText.error(.processTimedOut(tool: "spctl"))
                XCTAssertTrue(gatekeeper.contains("Gatekeeper"), language)
                XCTAssertTrue(timeout.hasPrefix("spctl "), language)
                XCTAssertNotEqual(gatekeeper, UpdateStatusText.error(.signatureInvalid))
                XCTAssertFalse((UpdateStatusText.text(.backingUp) ?? "").isEmpty)
            }
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(UpdateStatusText.text(.backingUp), "Veriler yedekleniyor…")
        }
    }
}

/// `SystemProcess`: time limit, cancellation and normal output (real `/bin/sleep` and `/bin/echo`).
final class SystemProcessTests: XCTestCase {
    func testOutputAndStatus() async throws {
        let output = try await SystemProcess.run(["/bin/echo", "hello"], timeout: 10, cancellable: true)
        XCTAssertEqual(output, CommandOutput(status: 0, output: "hello\n"))
        let failing = try await SystemProcess.run(["/bin/sh", "-c", "echo oops >&2; exit 3"], timeout: 10)
        XCTAssertEqual(failing, CommandOutput(status: 3, output: "oops\n"))
    }

    func testAProcessThatRunsTooLongIsStopped() async throws {
        let start = Date()
        do {
            _ = try await SystemProcess.run(["/bin/sleep", "20"], timeout: 0.3)
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? CommandError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancellingTheTaskStopsACancellableProcess() async throws {
        let start = Date()
        let task = Task { try await SystemProcess.run(["/bin/sleep", "20"], timeout: 60, cancellable: true) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch {
            XCTAssertEqual(error as? CommandError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testAlreadyCancelledTaskDoesNotStartTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SystemProcess.run(["/usr/bin/touch", marker.path], timeout: 10, cancellable: true)
        }
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch {
            XCTAssertEqual(error as? CommandError, .cancelled)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testANonCancellableProcessRunsToItsEnd() async throws {
        let task = Task { try await SystemProcess.run(["/bin/sleep", "0.3"], timeout: 10) }
        task.cancel()
        let output = try await task.value
        XCTAssertEqual(output.status, 0)
    }
}

// MARK: - Hardening: a prepared download never stays behind when finishing fails

extension UpdateInstallerTests {
    func testFinishWithAMissingStagedAppRemovesTheDownload() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let installer = installer(FakeUpdateDownloader(files))
        let prepared = try await installer.prepare(release)
        try FileManager.default.removeItem(at: prepared.staged)
        do {
            _ = try await installer.finish(prepared)
            XCTFail("expected appMissing")
        } catch {
            XCTAssertEqual(error as? UpdateError, .appMissing)
        }
        assertOldAppInPlace()
        assertNoLeftovers()
    }

    func testFinishThatCannotCreateTheBackupFolderRemovesTheDownload() async throws {
        let (release, files) = UpdateFixture.release("1.2.0")
        let installer = installer(FakeUpdateDownloader(files))
        let prepared = try await installer.prepare(release)
        // A file where the app backup folder should be: creating the folder fails with a non-update error.
        try FileManager.default.createDirectory(at: paths.updateAppBackups.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.updateAppBackups)
        do {
            _ = try await installer.finish(prepared)
            XCTFail("expected a failure")
        } catch {
            XCTAssertNil(error as? UpdateError, "the original error is passed on")
        }
        assertOldAppInPlace()
        assertNoLeftovers()
    }
}

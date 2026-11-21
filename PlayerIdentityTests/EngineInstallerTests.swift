import XCTest
@testable import PlayerIdentity

/// v2.26 engine install orchestration on a temporary folder tree with the real bundle topology, fake network,
/// archive, signer, clock and process detector (T-E-BP1, T-E-BF*, T-E-X3, T-E-M*, T-E-SDL3–5, T-E-AT1/2, T-E-DL1–3,
/// T-E-SYM1–3, T-E-FD1–3, T-E-BC1–3, T-E-RS1–3, T-E-IB1, T-E-LG3, T-E-TOCTOU*, T-E-K*).
final class EngineInstallerTests: XCTestCase {
    private func assertValidPhases(_ fixture: EngineInstallFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.recorder.invalidTransitions, [], "\(fixture.recorder.phases)", file: file, line: line)
    }

    private func assertNothingLeftBehind(_ fixture: EngineInstallFixture, file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        XCTAssertEqual(try fixture.temporarySiblings(), [], file: file, line: line)
        XCTAssertEqual(fixture.runDirectories(), [], file: file, line: line)
    }

    private var excludedEngineFolders: (EngineInstallFixture) -> [URL] {
        { [$0.paths.engineUpdatesDirectory, $0.paths.engineBackupsDirectory] }
    }

    private func outsideSnapshot(_ fixture: EngineInstallFixture) throws -> [String: String] {
        try fixture.snapshot(fixture.root, excluding: excludedEngineFolders(fixture))
    }

    // MARK: Success (T-E-BP1, T-E-BF1, T-E-X3, T-E-M2, T-E-M3, T-E-SDL5, T-E-B3, T-E-G2, T-E-LG3)

    func testSuccessfulInstallUsesTheRealBundleTopology() async throws {
        let fixture = try EngineInstallFixture()
        let originalManifest = try fixture.appManifest()
        let resourcesBefore = try fixture.snapshot(fixture.contents.appendingPathComponent("Resources"))
        let frameworksBefore = try fixture.snapshot(fixture.contents.appendingPathComponent("Frameworks"))
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        assertValidPhases(fixture)
        XCTAssertEqual(fixture.recorder.phases, [.downloading, .verifyingDigest, .extracting, .verifyingSignature,
                                                 .preflightPermission, .preflightProcess, .backingUp, .installing,
                                                 .awaitingIdentityRepair])

        let macOS = fixture.contents.appendingPathComponent("MacOS")
        XCTAssertEqual(fixture.text(macOS.appendingPathComponent("xash3d")), "new-xash3d+sig", "signed executable")
        for module in EngineArchiveLayout.requiredModules where module != "xash3d" {
            XCTAssertEqual(fixture.text(macOS.appendingPathComponent(module)), "new-\(module)", module)
        }
        XCTAssertNil(fixture.text(macOS.appendingPathComponent("libref_soft.dylib")))
        XCTAssertEqual(result.report.removedModules, ["libref_soft.dylib"])
        XCTAssertEqual(Set(result.report.unknownFilesKept), ["Contents/MacOS/helper.sh",
                                                             "Contents/MacOS/cl_dlls/client_amd64.dylib",
                                                             "Contents/MacOS/dlls/opfor_arm64.dylib"])
        XCTAssertEqual(fixture.text(macOS.appendingPathComponent("dlls/opfor_arm64.dylib")), "old-opfor")

        // Extras are never copied (AC-E41a); Resources and Frameworks are untouched (AC-E42).
        for extra in EngineArchiveLayout.rootExtras {
            XCTAssertNil(fixture.text(macOS.appendingPathComponent(extra)), extra)
            XCTAssertNil(fixture.text(macOS.appendingPathComponent((extra as NSString).lastPathComponent)), extra)
        }
        XCTAssertEqual(try fixture.snapshot(fixture.contents.appendingPathComponent("Resources")), resourcesBefore)
        XCTAssertEqual(try fixture.snapshot(fixture.contents.appendingPathComponent("Frameworks")), frameworksBefore)

        // Bundle fallback libraries at the real path: exact upstream bytes even after signing (AC-E46d).
        let package = EngineInstallFixture.upstreamPackage()
        XCTAssertEqual(try Data(contentsOf: fixture.bundleClient), package["valve/cl_dlls/client_arm64.dylib"])
        XCTAssertEqual(try Data(contentsOf: fixture.bundleServer), package["valve/dlls/hl_arm64.dylib"])
        XCTAssertEqual(try Data(contentsOf: fixture.clientLib), package["valve/cl_dlls/client_arm64.dylib"])
        XCTAssertEqual(try Data(contentsOf: fixture.serverLib), package["valve/dlls/hl_arm64.dylib"])
        XCTAssertEqual(Set(result.report.updatedLibraries),
                       ["bundle:Contents/MacOS/cl_dlls/client_arm64.dylib", "bundle:Contents/MacOS/dlls/hl_arm64.dylib",
                        "gamedir:valve/cl_dlls/client_arm64.dylib", "gamedir:valve/dlls/hl_arm64.dylib"])
        XCTAssertTrue(result.report.effectiveLibraries.allSatisfy { $0.version == .upstream })
        XCTAssertEqual(result.report.restoredLibraries, [])
        XCTAssertEqual(result.report.skippedLibraries, [])

        // SDL2 next to the engine (`@loader_path`), only `Versions/A` with package bytes and the three links.
        let framework = macOS.appendingPathComponent("SDL2.framework")
        let local = LocalEngineFileOperations()
        XCTAssertEqual(try local.contents(framework), ["Headers", "Resources", "SDL2", "Versions"])
        XCTAssertEqual(try local.contents(framework.appendingPathComponent("Versions")), ["A", "Current"])
        for link in EngineSDL2Framework.links {
            XCTAssertEqual(local.symbolicLinkTarget(framework.appendingPathComponent(link.path)), link.target)
        }
        XCTAssertEqual(fixture.text(framework.appendingPathComponent("SDL2")), "new-sdl+sig", "signed framework")
        XCTAssertEqual(fixture.text(framework.appendingPathComponent("Headers/SDL_video.h")), "header-SDL_video.h")
        XCTAssertEqual(fixture.text(framework.appendingPathComponent("Versions/A/_CodeSignature/CodeResources")), "seal")

        let calls = fixture.signer.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls[0].hasPrefix("framework:") && calls[0].hasSuffix("/Contents/MacOS/SDL2.framework"))
        XCTAssertTrue(calls[1].hasPrefix("app:"))
        XCTAssertEqual(calls[3], "verify:" + fixture.target.path)

        // Backup: identity checksums only in the private manifest, never in the report (AC-E85).
        let backup = try XCTUnwrap(result.report.backup)
        XCTAssertEqual(backup.app.lastPathComponent, "Xash3D-FWGS-20261118-110640.app")
        XCTAssertEqual(try EngineTree.manifest(backup.app, files: local), originalManifest)
        let manifest = try JSONDecoder().decode(EngineBackupManifest.self, from: Data(contentsOf: backup.manifest))
        XCTAssertEqual(manifest.app, originalManifest)
        XCTAssertEqual(manifest.commit, EngineReleaseFixture.commit)
        XCTAssertEqual(manifest.identity.map(\.label).sorted(), ["gamedir", "homeConfig"])
        let identitySum = try local.sha256(fixture.globalIdentity)
        XCTAssertEqual(manifest.identity.first { $0.label == "homeConfig" }?.sha256, identitySum)
        XCTAssertFalse(String(describing: result.report).contains(identitySum), "no identity hash in the report")
        XCTAssertFalse(result.log.joined().contains(identitySum))
        XCTAssertEqual(fixture.mode(backup.manifest), 0o600)
        for folder in [fixture.paths.engineBackupsDirectory, fixture.paths.engineUpdatesDirectory, backup.identity,
                       backup.libraries] {
            XCTAssertEqual(fixture.mode(folder), 0o700, folder.lastPathComponent)
        }
        XCTAssertEqual(result.report.leftovers, [])
        try assertNothingLeftBehind(fixture)
    }

    // MARK: Write scope and identity (T-E-K1, T-E-K5, T-E-IB1)

    func testOnlyTheAppTheTwoLibrariesStagingAndBackupsAreWritten() async throws {
        let fixture = try EngineInstallFixture()
        let homeBefore = try fixture.snapshot(fixture.home, excluding: excludedEngineFolders(fixture))
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        let homeAfter = try fixture.snapshot(fixture.home, excluding: excludedEngineFolders(fixture))
        let changed = Set(homeBefore.keys).union(homeAfter.keys).filter { homeBefore[$0] != homeAfter[$0] }
        let dataPrefix = String(fixture.dataRoot.path.dropFirst(fixture.home.path.count + 1))
        XCTAssertEqual(changed, [dataPrefix + "/valve/cl_dlls/client_arm64.dylib", dataPrefix + "/valve/dlls/hl_arm64.dylib"])
    }

    func testIdentityFilesAreNeverWrittenAndAbsentIsNotUnchanged() async throws {
        for failing in [false, true] {
            let fixture = try EngineInstallFixture()
            let before = fixture.identityPaths.map { try? LocalEngineFileOperations().sha256($0) }
            if failing {
                let server = fixture.serverLib.path
                fixture.files.fail = { operation, url in operation == "swap" && url.path == server ? .posix(EIO) : nil }
            }
            let result = await fixture.install()
            XCTAssertEqual(result.outcome, failing ? .rolledBack(.installFailed) : .installed)
            let identityPaths = Set(fixture.identityPaths.map(\.path))
            XCTAssertEqual(fixture.files.mutations.filter { identityPaths.contains($0.path) }, [])
            XCTAssertEqual(fixture.identityPaths.map { try? LocalEngineFileOperations().sha256($0) }, before)
            let changes = Dictionary(uniqueKeysWithValues: result.report.identityChanges.map { ($0.location, $0) })
            XCTAssertEqual(changes["homeConfig"]?.change, .unchanged)
            XCTAssertEqual(changes["gamedir"]?.change, .unchanged)
            XCTAssertEqual(changes["homeLocal"]?.change, .notComparable, "absent is never 'unchanged' (AC-E80)")
            XCTAssertEqual(changes["home"]?.before, .absent)
            XCTAssertEqual(changes["homeConfig"]?.before, .presentNonzero)
            XCTAssertFalse(result.report.identityFilesChanged)
        }
    }

    // MARK: Preflight (T-E-P1, AC-E3, AC-E4, T-E-AT1)

    func testPermissionPrecheckFailsBeforeAnyBackupIsCreated() async throws {
        for denied in ["applications", "library"] {
            let fixture = try EngineInstallFixture()
            let before = try outsideSnapshot(fixture)
            let deniedURL = denied == "applications" ? fixture.applications : fixture.serverLib.deletingLastPathComponent()
            fixture.files.writable = { $0.standardized.path == deniedURL.path ? false : nil }
            let result = await fixture.install()
            XCTAssertEqual(result.outcome, .failed(.permissionDenied(deniedURL.path)), denied)
            XCTAssertEqual(fixture.backupEntries(), [], "only the lock file, no backup")
            XCTAssertEqual(try outsideSnapshot(fixture), before)
            assertValidPhases(fixture)
            try assertNothingLeftBehind(fixture)
        }
    }

    func testRunningOrUnverifiableEngineAtPreflightWritesNothing() async throws {
        for (state, failure) in [(EngineProcessState.running, EngineInstallFailure.engineRunning),
                                 (.unavailable, .processUnavailable)] {
            let fixture = try EngineInstallFixture()
            fixture.detector = SequencedEngineDetector([state])
            let before = try outsideSnapshot(fixture)
            let result = await fixture.install()
            XCTAssertEqual(result.outcome, .failed(failure))
            XCTAssertEqual(try outsideSnapshot(fixture), before)
            XCTAssertEqual(fixture.backupEntries(), [])
            try assertNothingLeftBehind(fixture)
        }
    }

    func testVolumeWithoutRenameSwapIsRefusedBeforeAnythingIsWritten() async throws {
        let fixture = try EngineInstallFixture()
        fixture.files.atomicSwapSupported = false
        let before = try fixture.snapshot(fixture.root)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.atomicSwapUnsupported))
        XCTAssertEqual(fixture.downloader.calls, [])
        XCTAssertEqual(fixture.files.mutations, [])
        XCTAssertEqual(try fixture.snapshot(fixture.root), before)
    }

    func testSwapThatTurnsOutUnsupportedIsAFailureWithoutAFallback() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        fixture.files.fail = { operation, _ in operation == "swap" ? .posix(ENOTSUP) : nil }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.atomicSwapUnsupported))
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "move" && $0.path == fixture.target.path },
                       "no rename-based fallback ever moves the target")
        XCTAssertEqual(fixture.backupEntries(), [], "nothing changed: this run's backup is discarded")
        try assertNothingLeftBehind(fixture)
    }

    // MARK: TOCTOU (T-E-TOCTOU1, T-E-TOCTOU2, T-E-RS2)

    func testEngineStartedRightBeforeTheSwapChangesNothing() async throws {
        let fixture = try EngineInstallFixture()
        fixture.detector = SequencedEngineDetector([.notRunning, .running])
        let before = try outsideSnapshot(fixture)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.engineRunning))
        XCTAssertEqual(try outsideSnapshot(fixture), before)
        XCTAssertEqual(fixture.backupEntries(), [])
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" })
        try assertNothingLeftBehind(fixture)
    }

    func testEngineStartedDuringTheInstallRollsBackAndReportsTheFinalState() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        fixture.detector = SequencedEngineDetector([.notRunning, .notRunning, .notRunning, .running])
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rolledBack(.engineRunning))
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertEqual(fixture.text(fixture.clientLib), "old-game-client")
        XCTAssertEqual(result.report.restoredLibraries, ["gamedir:valve/cl_dlls/client_arm64.dylib"])
        XCTAssertEqual(result.report.updatedLibraries, [], "nothing upstream is left (AC-E79a)")
        XCTAssertTrue(result.report.effectiveLibraries.allSatisfy { $0.version == .original },
                      "\(result.report.effectiveLibraries)")
        XCTAssertEqual(fixture.backupEntries().count, 4, "backup kept after a rollback")
        assertValidPhases(fixture)
        try assertNothingLeftBehind(fixture)
    }

    // MARK: Atomic replace and rollback (T-E-B2, T-E-L1, T-E-RS1)

    func testPermissionErrorAtTheSwapIsAFailureNotARollback() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        fixture.files.fail = { operation, _ in operation == "swap" ? .posix(EACCES) : nil }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.permissionDenied(fixture.applications.path)))
        XCTAssertFalse(fixture.recorder.phases.contains(.rollingBack))
        XCTAssertEqual(try fixture.appManifest(), original)
        try assertNothingLeftBehind(fixture)
    }

    func testFailedLibrarySwapRollsBackLibrariesThenApp() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        let server = fixture.serverLib.path
        fixture.files.fail = { operation, url in operation == "swap" && url.path == server ? .posix(EIO) : nil }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rolledBack(.installFailed))
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertEqual(fixture.text(fixture.clientLib), "old-game-client")
        XCTAssertEqual(fixture.text(fixture.serverLib), "old-game-hl")
        let operations = fixture.files.mutations
        let restoreLibrary = try XCTUnwrap(operations.lastIndex { $0.operation == "swap" && $0.path == fixture.clientLib.path })
        let restoreApp = try XCTUnwrap(operations.lastIndex { $0.operation == "swap" && $0.path == fixture.target.path })
        XCTAssertLessThan(restoreLibrary, restoreApp, "libraries are put back before the app")
        try assertNothingLeftBehind(fixture)
    }

    func testUpdatedLibrariesMeansChangedByThisRunNotJustUpstreamOnDisk() async throws {
        let fixture = try EngineInstallFixture()
        let first = await fixture.install()
        XCTAssertEqual(first.outcome, .installed)
        try FileManager.default.removeItem(at: fixture.clientLib)
        try fixture.write(fixture.clientLib, "old-game-client")
        let server = fixture.serverLib.path
        fixture.files.fail = { operation, url in operation == "swap" && url.path == server ? .posix(EIO) : nil }
        fixture.downloader.setMode(.fail)
        let second = await fixture.install()
        XCTAssertEqual(second.outcome, .rolledBack(.installFailed))
        XCTAssertEqual(second.report.restoredLibraries, ["gamedir:valve/cl_dlls/client_arm64.dylib"])
        XCTAssertEqual(second.report.updatedLibraries, [], "the server library was already upstream, not updated now")
        XCTAssertTrue(second.report.effectiveLibraries.contains(
            EngineLibraryState(path: "gamedir:valve/dlls/hl_arm64.dylib", version: .upstream)), "disk truth kept apart")
        XCTAssertTrue(second.report.effectiveLibraries.contains(
            EngineLibraryState(path: "gamedir:valve/cl_dlls/client_arm64.dylib", version: .original)))
    }

    func testFailedVerificationOfTheInstalledAppRollsBack() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        fixture.signer.failVerifyPath = fixture.target.path
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rolledBack(.codesign))
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertTrue(result.log.contains("note=codesign:signatureInvalid:exit1"))
        try assertNothingLeftBehind(fixture)
    }

    func testUnverifiableRollbackKeepsTheBackupAndReportsIt() async throws {
        let fixture = try EngineInstallFixture()
        let server = fixture.serverLib.path
        let client = fixture.clientLib.path
        let counter = SwapCounter()
        fixture.files.fail = { operation, url in
            if operation == "swap" && url.path == server { return .posix(EIO) }
            if operation == "swap" && url.path == client { return counter.next() > 1 ? .posix(EIO) : nil }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rollbackIncomplete(.installFailed))
        let backup = try XCTUnwrap(result.report.backup)
        XCTAssertEqual(LocalEngineFileOperations().kind(backup.app), .directory, "never deleted")
        XCTAssertEqual(result.report.restoredLibraries, [])
        XCTAssertTrue(result.report.effectiveLibraries.contains(
            EngineLibraryState(path: "gamedir:valve/cl_dlls/client_arm64.dylib", version: .upstream)))
        XCTAssertEqual(fixture.recorder.phases.suffix(2), [.rollingBack, .rollbackIncomplete])
        XCTAssertEqual(result.log.last, "stage=rollbackIncomplete error=installFailed")
    }

    func testBackupFailureBeforeAnyChangeIsFailedWithoutAPartialBackup() async throws {
        let fixture = try EngineInstallFixture()
        let before = try outsideSnapshot(fixture)
        fixture.files.fail = { operation, url in
            operation == "copyFile" && url.lastPathComponent == "gamedir.xash_id" ? .posix(ENOSPC) : nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.backupFailed))
        XCTAssertFalse(fixture.recorder.phases.contains(.rollingBack))
        XCTAssertEqual(fixture.backupEntries(), [])
        XCTAssertNil(result.report.backup)
        XCTAssertEqual(try outsideSnapshot(fixture), before)
        assertValidPhases(fixture)
        try assertNothingLeftBehind(fixture)
    }

    // MARK: Conflict after the backup (T-E-BC1 – T-E-BC3, T-E-RS3)

    private func failOnSiblingCopy(_ fixture: EngineInstallFixture, _ effect: @escaping () -> Void) {
        let applications = fixture.applications.path
        let once = SwapCounter()
        fixture.files.fail = { operation, url in
            if operation == "copyItem", url.deletingLastPathComponent().path == applications, once.next() == 1 { effect() }
            return nil
        }
    }

    func testTargetChangedAfterTheBackupIsAConflictWithoutMutation() async throws {
        let fixture = try EngineInstallFixture()
        let plist = fixture.contents.appendingPathComponent("Info.plist")
        failOnSiblingCopy(fixture) { try? Data("<plist/>".utf8).write(to: plist) }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.conflict))
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" })
        XCTAssertEqual(fixture.text(plist), "<plist/>", "the user's change is kept")
        XCTAssertEqual(fixture.backupEntries(), [])
        try assertNothingLeftBehind(fixture)
    }

    func testLibraryChangedAfterTheBackupIsAConflictWithoutMutation() async throws {
        let fixture = try EngineInstallFixture()
        let client = fixture.clientLib
        failOnSiblingCopy(fixture) { try? Data("edited".utf8).write(to: client) }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.conflict))
        XCTAssertEqual(fixture.text(client), "edited")
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" })
    }

    func testFolderTurnedIntoALinkAfterTheBackupIsRefusedWithoutMutation() async throws {
        let fixture = try EngineInstallFixture()
        let dlls = fixture.contents.appendingPathComponent("MacOS/dlls")
        let outside = fixture.root.appendingPathComponent("outside")
        failOnSiblingCopy(fixture) {
            try? FileManager.default.moveItem(at: dlls, to: outside)
            try? FileManager.default.createSymbolicLink(at: dlls, withDestinationURL: outside)
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.unsafePath("dlls")))
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" })
    }

    func testBackupThatCannotBeCleanedKeepsItsMetadata() async throws {
        let fixture = try EngineInstallFixture()
        let plist = fixture.contents.appendingPathComponent("Info.plist")
        let applications = fixture.applications.path
        let backups = fixture.paths.engineBackupsDirectory.path
        let once = SwapCounter()
        fixture.files.fail = { operation, url in
            if operation == "copyItem", url.deletingLastPathComponent().path == applications, once.next() == 1 {
                try? Data("<plist/>".utf8).write(to: plist)
            }
            if operation == "remove", url.deletingLastPathComponent().path == backups, url.pathExtension == "app" {
                return .posix(EPERM)
            }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.conflict))
        let backup = try XCTUnwrap(result.report.backup, "the location is kept")
        XCTAssertEqual(LocalEngineFileOperations().kind(backup.manifest), .regularFile, "manifest kept (AC-E79d)")
        XCTAssertTrue(result.report.leftovers.contains(backup.app.path), "\(result.report.leftovers)")
    }

    // MARK: Install deadline (T-E-DL1 – T-E-DL3, T-E-PR2)

    func testDeadlineBeforeTheSwapDiscardsEverythingWithoutTouchingTheTarget() async throws {
        let fixture = try EngineInstallFixture()
        let before = try outsideSnapshot(fixture)
        let clock = fixture.clock
        failOnSiblingCopy(fixture) { clock.advance(by: 301) }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.timeout(.install)))
        XCTAssertEqual(result.log.last, "stage=failed error=timeout:install")
        XCTAssertEqual(try outsideSnapshot(fixture), before)
        XCTAssertEqual(fixture.backupEntries(), [])
        try assertNothingLeftBehind(fixture)
    }

    func testDeadlineDuringTheBackupIsAFailure() async throws {
        let fixture = try EngineInstallFixture()
        let clock = fixture.clock
        let backups = fixture.paths.engineBackupsDirectory.path
        fixture.files.fail = { operation, url in
            if operation == "copyItem", url.deletingLastPathComponent().path == backups { clock.advance(by: 301) }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.timeout(.install)))
        XCTAssertEqual(fixture.backupEntries(), [])
    }

    func testDeadlineAfterTheSwapRollsBack() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        let clock = fixture.clock
        let target = fixture.target.path
        let once = SwapCounter()
        fixture.files.fail = { operation, url in
            if operation == "swap", url.path == target, once.next() == 1 { clock.advance(by: 301) }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rolledBack(.timeout(.install)))
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertEqual(fixture.text(fixture.clientLib), "old-game-client")
        XCTAssertTrue(result.log.contains("stage=rollingBack note=appRestored"))
        try assertNothingLeftBehind(fixture)
    }

    func testDeadlineAfterTheSwapWithAFailedRollbackIsIncomplete() async throws {
        let fixture = try EngineInstallFixture()
        let clock = fixture.clock
        let target = fixture.target.path
        let counter = SwapCounter()
        fixture.files.fail = { operation, url in
            guard operation == "swap", url.path == target else { return nil }
            if counter.next() == 1 {
                clock.advance(by: 301)
                return nil
            }
            return .posix(EIO)
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rollbackIncomplete(.timeout(.install)))
        let backup = try XCTUnwrap(result.report.backup)
        XCTAssertEqual(LocalEngineFileOperations().kind(backup.app), .directory)
        XCTAssertTrue(result.log.contains("stage=rollingBack note=appRestoreFailed"))
    }

    // MARK: Signature and mixed build (T-E-C1, T-E-C2, T-E-M1, T-E-SDL3 – T-E-SDL5, T-E-FD3)

    func testSigningOrVerificationFailureStopsBeforeTheTarget() async throws {
        for failure in ["framework", "app", "verify"] {
            let fixture = try EngineInstallFixture()
            switch failure {
            case "framework": fixture.signer.failFrameworkSign = true
            case "app": fixture.signer.failSign = true
            default: fixture.signer.failVerify = true
            }
            let before = try outsideSnapshot(fixture)
            let result = await fixture.install()
            XCTAssertEqual(result.outcome, .failed(.codesign), failure)
            XCTAssertEqual(try outsideSnapshot(fixture), before)
            XCTAssertEqual(fixture.backupEntries(), [])
            XCTAssertEqual(fixture.detector.checks, 0)
            try assertNothingLeftBehind(fixture)
        }
    }

    func testStagedFileThatDiffersFromThePackageIsAMixedBuild() async throws {
        let fixture = try EngineInstallFixture()
        fixture.files.afterCopy = { url in
            if url.path.contains("/run-"), url.path.contains("/app/"), url.lastPathComponent == "libxash.dylib" {
                try? Data("old-libxash.dylib".utf8).write(to: url)
            }
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.mixedBuild("Contents/MacOS/libxash.dylib")))
        XCTAssertEqual(fixture.signer.calls, [])
        try assertNothingLeftBehind(fixture)
    }

    func testExtractedSourceChangedAfterHashingIsAMixedBuild() async throws {
        let fixture = try EngineInstallFixture()
        let updates = fixture.paths.engineUpdatesDirectory.path
        fixture.files.fail = { operation, url in
            if operation == "copyItem", url.path.hasPrefix(updates), url.lastPathComponent == "Xash3D-FWGS.app",
               let run = try? FileManager.default.contentsOfDirectory(atPath: updates).first(where: { $0.hasPrefix("run-") }) {
                try? Data("swapped".utf8).write(to: URL(fileURLWithPath: updates + "/" + run + "/x/libmenu.dylib"))
            }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.mixedBuild("Contents/MacOS/libmenu.dylib")))
    }

    func testFrameworkFileThatDiffersFromVersionsAIsAMixedBuild() async throws {
        let copy = try EngineInstallFixture()
        copy.archive.package["SDL2.framework/Versions/Current/Resources/License.txt"] = Data("other".utf8)
        let result = await copy.install()
        XCTAssertEqual(result.outcome, .failed(.mixedBuild("SDL2.framework/Versions/Current/Resources/License.txt")))

        let staged = try EngineInstallFixture()
        staged.files.fail = { operation, url in
            if operation == "symlink", url.lastPathComponent == "Current" {
                try? Data("tampered".utf8).write(to: url.deletingLastPathComponent()
                    .appendingPathComponent("A/Resources/License.txt"))
            }
            return nil
        }
        let stagedResult = await staged.install()
        XCTAssertEqual(stagedResult.outcome,
                       .failed(.mixedBuild("Contents/MacOS/SDL2.framework/Versions/A/Resources/License.txt")))
        XCTAssertEqual(staged.signer.calls, [], "checked before signing")
    }

    func testExtraFileAtTheFrameworkRootIsRefused() async throws {
        let fixture = try EngineInstallFixture()
        fixture.files.fail = { operation, url in
            if operation == "symlink", url.lastPathComponent == "Resources", !url.path.contains("/Versions/") {
                try? Data("x".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("Extra.txt"))
            }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.mixedBuild("Contents/MacOS/SDL2.framework")))
    }

    func testSignerThatRewritesNestedLibrariesIsCaughtAfterSigning() async throws {
        let fixture = try EngineInstallFixture()
        fixture.signer.rewritesNestedLibraries = true
        let before = try outsideSnapshot(fixture)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.mixedBuild("Contents/MacOS/cl_dlls/client_arm64.dylib")))
        XCTAssertEqual(try outsideSnapshot(fixture), before)
    }

    func testMissingSDL2TargetFailsBeforeTheTarget() async throws {
        let fixture = try EngineInstallFixture()
        for header in EngineInstallFixture.headers {
            fixture.archive.package.removeValue(forKey: "SDL2.framework/Versions/A/Headers/" + header)
            fixture.archive.package.removeValue(forKey: "SDL2.framework/Versions/Current/Headers/" + header)
            fixture.archive.package.removeValue(forKey: "SDL2.framework/Headers/" + header)
        }
        let before = try fixture.snapshot(fixture.applications)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.sdl2Reconstruction))
        XCTAssertEqual(try fixture.snapshot(fixture.applications), before)
    }

    // MARK: Download and archive trust chain (T-E-N3, T-E-N4, T-E-D*, T-E-FD1, T-E-FD2)

    func testWrongDigestOrSizeFailsClosedBeforeExtraction() async throws {
        let template = try EngineInstallFixture()
        let cases: [(EngineRelease, EngineInstallFailure)] = [
            (template.release(sha: String(repeating: "0", count: 64)), .digestMismatch),
            (template.release(size: 10), .sizeTooLarge),
            (template.release(size: 99), .sizeMismatch(expected: 99, actual: 15)),
        ]
        for (release, failure) in cases {
            let fixture = try EngineInstallFixture()
            let result = await fixture.install(release)
            XCTAssertEqual(result.outcome, .failed(failure))
            XCTAssertEqual(fixture.archive.listCalls, 0)
            try assertNothingLeftBehind(fixture)
        }
    }

    func testArchiveIsReadOnceAndEveryPassUsesTheSameVerifiedBytes() async throws {
        let fixture = try EngineInstallFixture()
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        let digest = EngineInstallFixture.sha(fixture.archiveBytes)
        XCTAssertEqual(fixture.archive.receivedHashes, [digest, digest], "list and extract from the same bytes")
        XCTAssertEqual(fixture.files.wholeFileReads.count, 1, "the archive path is opened once")
    }

    func testReplacingTheCacheFileAfterVerificationHasNoEffect() async throws {
        let fixture = try EngineInstallFixture()
        let cached = fixture.paths.engineUpdatesDirectory.appendingPathComponent(EngineArchitecture.arm64.assetName)
        fixture.archive.onList = {
            try? FileManager.default.removeItem(at: cached)
            try? Data("attacker-archive".utf8).write(to: cached)
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        let digest = EngineInstallFixture.sha(fixture.archiveBytes)
        XCTAssertEqual(fixture.archive.receivedHashes, [digest, digest], "extraction used the verified bytes")
        XCTAssertEqual(fixture.files.wholeFileReads.count, 1, "the replaced path is never read")
        // The next install re-verifies the cache and refuses the replaced file.
        fixture.archive.onList = nil
        fixture.downloader.setMode(.fail)
        let next = await fixture.install()
        XCTAssertEqual(next.outcome, .failed(.downloadFailed))
    }

    func testDownloadCanBeCancelledAndLeavesNothing() async throws {
        let fixture = try EngineInstallFixture()
        fixture.downloader.setMode(.hang)
        let before = try outsideSnapshot(fixture)
        let installer = fixture.installer
        let release = fixture.release()
        let recorder = fixture.recorder
        let task = Task {
            await installer.install(release, confirmation: EngineInstallConfirmation(acceptedCIDWarning: true,
                                                                                     cidBefore: nil)) {
                recorder.record($0)
            }
        }
        for _ in 0..<500 where !fixture.downloader.started { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        assertValidPhases(fixture)
        XCTAssertEqual(try outsideSnapshot(fixture), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.engineUpdatesDirectory.path), [])
    }

    func testTimeLimitsEndTheirStage() async throws {
        let download = try EngineInstallFixture()
        download.downloader.setMode(.hang)
        download.clock.expiring = [600]
        let downloadResult = await download.install()
        XCTAssertEqual(downloadResult.outcome, .failed(.timeout(.download)))
        try assertNothingLeftBehind(download)

        let extraction = try EngineInstallFixture()
        extraction.archive.hangsOnExtract = true
        extraction.clock.expiring = [120]
        let extractionResult = await extraction.install()
        XCTAssertEqual(extractionResult.outcome, .failed(.timeout(.extraction)))
        XCTAssertEqual(extractionResult.log.last, "stage=failed error=timeout:extraction")
        try assertNothingLeftBehind(extraction)

        let metadata = try EngineInstallFixture()
        metadata.metadata.hangs = true
        metadata.clock.expiring = [30]
        let metadataResult = await metadata.installer.fetchRelease()
        XCTAssertEqual(metadataResult, .failure(.timeout(.metadata)))
    }

    func testToolFailureIsLoggedAsACategoryOnly() async throws {
        let fixture = try EngineInstallFixture()
        fixture.archive.failure = EngineToolError(tool: "tar", category: .archiveRejected, exitStatus: 2)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.extractionFailed))
        XCTAssertTrue(result.log.contains("note=tar:archiveRejected:exit2"))
    }

    func testFetchReleaseParsesTheAPIAndChecksTheArchitectureFirst() async throws {
        let fixture = try EngineInstallFixture()
        let fetched = await fixture.installer.fetchRelease()
        XCTAssertEqual(fetched, .success(fixture.release()))
        let intel = try EngineInstallFixture()
        intel.architecture = .amd64
        let intelFetch = await intel.installer.fetchRelease()
        XCTAssertEqual(intelFetch, .failure(.unsupportedArchitecture))
        XCTAssertEqual(intel.metadata.calls, 0)
    }

    // MARK: Archive (T-E-X*, AC-E23)

    func testUnsafeArchiveExtractsNothing() async throws {
        let fixture = try EngineInstallFixture()
        fixture.archive.entriesOverride = fixture.archive.entries + [EngineArchiveEntry(path: "./valve/evil.dylib",
                                                                                        type: .regular)]
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.unsafeArchive("./valve/evil.dylib")))
        XCTAssertEqual(fixture.archive.extractCalls, 0)
        try assertNothingLeftBehind(fixture)
    }

    func testExtractedTreeMustMatchTheListing() async throws {
        let extra = try EngineInstallFixture()
        extra.archive.extraOnExtract = ["valve/cl_dlls/evil.dylib": Data("x".utf8)]
        let extraResult = await extra.install()
        XCTAssertEqual(extraResult.outcome, .failed(.unsafeArchive("valve/cl_dlls/evil.dylib")))

        let missing = try EngineInstallFixture()
        missing.archive.skippedOnExtract = ["libref_gl.dylib"]
        let missingResult = await missing.install()
        XCTAssertEqual(missingResult.outcome, .failed(.missingExpectedFile("libref_gl.dylib")))
        try assertNothingLeftBehind(missing)
    }

    // MARK: Libraries (T-E-BF2, T-E-BF3, T-E-Q1)

    func testPackageWithoutGameLibrariesLeavesThemAndReportsIt() async throws {
        let fixture = try EngineInstallFixture()
        for library in EngineArchiveLayout.gameLibraries(architecture: .arm64) {
            fixture.archive.package.removeValue(forKey: library.source)
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertEqual(fixture.text(fixture.clientLib), "old-game-client")
        XCTAssertEqual(fixture.text(fixture.bundleClient), "old-bundle-client")
        XCTAssertEqual(Set(result.report.skippedLibraries.map(\.path)),
                       ["bundle:Contents/MacOS/cl_dlls/client_arm64.dylib", "bundle:Contents/MacOS/dlls/hl_arm64.dylib",
                        "gamedir:valve/cl_dlls/client_arm64.dylib", "gamedir:valve/dlls/hl_arm64.dylib"])
        XCTAssertTrue(result.report.skippedLibraries.allSatisfy { $0.reason == .noUpstreamMatch })
        XCTAssertEqual(result.report.updatedLibraries, [])
    }

    func testMissingGamedirLibraryIsNotCreatedButTheBundleFallbackIsExact() async throws {
        let fixture = try EngineInstallFixture()
        try FileManager.default.removeItem(at: fixture.clientLib)
        try FileManager.default.removeItem(at: fixture.serverLib)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertEqual(LocalEngineFileOperations().kind(fixture.clientLib), .missing)
        let package = EngineInstallFixture.upstreamPackage()
        XCTAssertEqual(try Data(contentsOf: fixture.bundleClient), package["valve/cl_dlls/client_arm64.dylib"])
        XCTAssertEqual(Set(result.report.skippedLibraries), [
            EngineLibrarySkip(path: "gamedir:valve/cl_dlls/client_arm64.dylib", reason: .targetAbsent),
            EngineLibrarySkip(path: "gamedir:valve/dlls/hl_arm64.dylib", reason: .targetAbsent)])
    }

    func testOtherActiveGamedirGetsNoValveLibraries() async throws {
        let fixture = try EngineInstallFixture()
        fixture.gamedir = "cstrike"
        let cstrike = fixture.dataRoot.appendingPathComponent("cstrike/cl_dlls/client_arm64.dylib")
        try fixture.write(cstrike, "cs-client")
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertEqual(fixture.text(cstrike), "cs-client")
        XCTAssertTrue(result.report.skippedLibraries.contains(
            EngineLibrarySkip(path: "gamedir:cstrike/cl_dlls/client_arm64.dylib", reason: .noUpstreamMatch)))
    }

    func testQuarantineFailureIsReportedButDoesNotStopTheInstall() async throws {
        let fixture = try EngineInstallFixture()
        let target = fixture.target.path
        fixture.files.fail = { operation, url in
            operation == "xattr" && url.lastPathComponent == "hl_arm64.dylib" && !url.path.hasPrefix(target)
                ? .posix(EPERM) : nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertTrue(result.report.quarantineFailures.contains("gamedir:valve/dlls/hl_arm64.dylib"))
        XCTAssertTrue(result.report.quarantineFailures.contains("staged/Contents/MacOS/dlls/hl_arm64.dylib"))
    }

    // MARK: Confirmation, target and links (AC-E2a, AC-E49, T-E-SYM1 – T-E-SYM3)

    func testWithoutConfirmationNothingHappens() async throws {
        let fixture = try EngineInstallFixture()
        let before = try fixture.snapshot(fixture.root)
        let result = await fixture.install(accepted: false)
        XCTAssertEqual(result.outcome, .failed(.notConfirmed))
        XCTAssertEqual(fixture.files.mutations, [])
        XCTAssertEqual(try fixture.snapshot(fixture.root), before)
    }

    func testLinkedBundleOrGameFoldersAreRefusedBeforeAnyWrite() async throws {
        let cases: [(String, String)] = [("Contents/MacOS/cl_dlls", "cl_dlls"), ("Contents/MacOS/dlls", "dlls"),
                                         ("Contents/Frameworks", "frameworks"), ("Contents/Resources/valve", "resourcesValve"),
                                         ("Contents/MacOS/SDL2.framework", "sdl2Framework"),
                                         ("Contents/MacOS/cl_dlls/client_arm64.dylib", "bundleLib")]
        for (path, role) in cases {
            let fixture = try EngineInstallFixture()
            let item = fixture.target.appendingPathComponent(path)
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: item, to: outside)
            try FileManager.default.createSymbolicLink(at: item, withDestinationURL: outside)
            let before = try fixture.snapshot(fixture.root)
            let result = await fixture.install()
            XCTAssertEqual(result.outcome, .failed(.unsafePath(role)), path)
            XCTAssertEqual(fixture.files.mutations, [], path)
            XCTAssertEqual(fixture.downloader.calls, [], path)
            XCTAssertEqual(try fixture.snapshot(fixture.root), before, path)
        }
        for path in ["valve/cl_dlls", "valve/dlls/hl_arm64.dylib", "valve"] {
            let fixture = try EngineInstallFixture()
            let item = fixture.dataRoot.appendingPathComponent(path)
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: item, to: outside)
            try FileManager.default.createSymbolicLink(at: item, withDestinationURL: outside)
            let result = await fixture.install()
            XCTAssertEqual(result.outcome, .failed(.unsafePath("gamedirLibs")), path)
            XCTAssertEqual(fixture.files.mutations, [], path)
        }
    }

    func testFolderTurnedIntoALinkDuringTheInstallStopsAndRollsBack() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        let clDlls = fixture.clientLib.deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("outside-cl_dlls")
        let target = fixture.target.path
        let once = SwapCounter()
        fixture.files.fail = { operation, url in
            if operation == "swap", url.path == target, once.next() == 1 {
                try? FileManager.default.moveItem(at: clDlls, to: outside)
                try? FileManager.default.createSymbolicLink(at: clDlls, withDestinationURL: outside)
            }
            return nil
        }
        let result = await fixture.install()
        // The app is put back, but the library is now reached through a link: never claimed as restored (AC-E92a).
        XCTAssertEqual(result.outcome, .rollbackIncomplete(.unsafePath("gamedirLibs")))
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertEqual(fixture.text(outside.appendingPathComponent("client_arm64.dylib")), "old-game-client",
                       "nothing written through the link")
        XCTAssertFalse(fixture.files.mutations.contains { $0.path.hasPrefix(clDlls.path + "/") })
    }

    func testCleanupNeverDeletesThroughALink() async throws {
        let fixture = try EngineInstallFixture()
        let applications = fixture.applications.path
        let victim = fixture.root.appendingPathComponent("victim")
        try fixture.write(victim.appendingPathComponent("keep.txt"), "keep")
        fixture.files.fail = { operation, url in
            if operation == "copyItem", url.deletingLastPathComponent().path == applications {
                try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
                return .posix(EIO)
            }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.installFailed))
        XCTAssertEqual(fixture.text(victim.appendingPathComponent("keep.txt")), "keep")
        XCTAssertTrue(result.report.leftovers.contains { $0.hasPrefix(applications + "/.Xash3D-FWGS.app.pi-new-") },
                      "\(result.report.leftovers)")
    }

    func testTargetMustBeAPlainEngineAppOutsideTheDataFolders() async throws {
        let inside = try EngineInstallFixture()
        let hidden = inside.dataRoot.appendingPathComponent("Xash3D-FWGS.app")
        try FileManager.default.copyItem(at: inside.target, to: hidden)
        let insideInstaller = EngineInstaller(environment: EngineInstallEnvironment(
            targetApp: hidden, dataRoot: inside.dataRoot, gamedir: "valve", home: inside.home, paths: inside.paths,
            architecture: .arm64), metadata: inside.metadata, downloader: inside.downloader, archive: inside.archive,
            signer: inside.signer, files: inside.files, detector: inside.detector, clock: inside.clock)
        let insideResult = await insideInstaller.install(inside.release(), confirmation: .init(acceptedCIDWarning: true,
                                                                                              cidBefore: nil))
        XCTAssertEqual(insideResult.outcome, .failed(.forbiddenTarget))

        let traversal = try EngineInstallFixture()
        traversal.gamedir = "../valve"
        let traversalResult = await traversal.install()
        XCTAssertEqual(traversalResult.outcome, .failed(.forbiddenTarget))

        let missing = try EngineInstallFixture()
        try FileManager.default.removeItem(at: missing.target)
        let missingResult = await missing.install()
        XCTAssertEqual(missingResult.outcome, .failed(.targetInvalid(.notFound)))
        for fixture in [inside, traversal, missing] { XCTAssertEqual(fixture.downloader.calls, []) }
    }

    func testInvalidReleaseIsRefusedWithoutNetwork() async throws {
        let fixture = try EngineInstallFixture()
        let good = fixture.release()
        let forged = EngineRelease(tag: good.tag, prerelease: true, htmlURL: good.htmlURL, commitSHA: good.commitSHA,
                                   architecture: .arm64,
                                   asset: EngineReleaseAsset(name: good.asset.name,
                                                             downloadURL: URL(string: "https://evil.example/x.tar.xz")!,
                                                             size: good.asset.size, sha256: good.asset.sha256))
        let forgedResult = await fixture.install(forged)
        XCTAssertEqual(forgedResult.outcome, .failed(.hostNotAllowed("evil.example")))
        let notPrerelease = EngineRelease(tag: good.tag, prerelease: false, htmlURL: good.htmlURL,
                                          commitSHA: good.commitSHA, architecture: .arm64, asset: good.asset)
        let notPrereleaseResult = await fixture.install(notPrerelease)
        XCTAssertEqual(notPrereleaseResult.outcome, .failed(.metadataInvalid))
        XCTAssertEqual(fixture.downloader.calls, [])
    }

    // MARK: E21 lock (T-E-LK1, T-E-LK3)

    func testSecondInstallerCannotTakeTheLockAndDownloadsNothing() async throws {
        let fixture = try EngineInstallFixture()
        try FileManager.default.createDirectory(at: fixture.paths.engineBackupsDirectory, withIntermediateDirectories: true)
        let holder = try LocalEngineFileOperations().acquireExclusiveLock(fixture.lockFile)
        let before = try outsideSnapshot(fixture)
        let blocked = await fixture.install()
        XCTAssertEqual(blocked.outcome, .failed(.locked))
        XCTAssertEqual(blocked.log.last, "stage=failed error=conflict:locked")
        XCTAssertEqual(fixture.downloader.calls, [])
        XCTAssertEqual(try outsideSnapshot(fixture), before)
        holder.release()
        let next = await fixture.install()
        XCTAssertEqual(next.outcome, .installed)
        // Released at the end of the run (also after a failure).
        let again = try LocalEngineFileOperations().acquireExclusiveLock(fixture.lockFile)
        again.release()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.engineBackupsDirectory.path)
            .filter { $0.hasPrefix(".") }, [".install.lock"], "no PID file")
    }

    func testLinkedLockFileIsUnavailableAndNothingHappens() async throws {
        let fixture = try EngineInstallFixture()
        try FileManager.default.createDirectory(at: fixture.paths.engineBackupsDirectory, withIntermediateDirectories: true)
        let victim = try fixture.temp.write("victim.txt", "keep")
        try FileManager.default.createSymbolicLink(at: fixture.lockFile, withDestinationURL: victim)
        let before = try outsideSnapshot(fixture)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.lockUnavailable))
        XCTAssertEqual(result.log.last, "stage=failed error=conflict:lockUnavailable")
        XCTAssertEqual(fixture.downloader.calls, [])
        XCTAssertEqual(fixture.text(victim), "keep")
        XCTAssertEqual(try outsideSnapshot(fixture), before)

        let failing = try EngineInstallFixture()
        failing.files.lockFailure = { _ in EngineLockError.unavailable(EACCES) }
        let failingResult = await failing.install()
        XCTAssertEqual(failingResult.outcome, .failed(.lockUnavailable))
        XCTAssertEqual(failing.downloader.calls, [])
    }

    // MARK: E21 immediate library checks (T-E-IM1, T-E-IM2, T-E-RV1, T-E-RV2)

    private func onLibraryTemp(_ fixture: EngineInstallFixture, named name: String, _ effect: @escaping () -> Void) {
        fixture.files.fail = { operation, url in
            if operation == "copyFile", url.lastPathComponent.hasPrefix(".\(name).pi-new-") { effect() }
            return nil
        }
    }

    func testLibraryChangedRightBeforeItsSwapIsNeverOverwritten() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        let client = fixture.clientLib
        onLibraryTemp(fixture, named: "client_arm64.dylib") { try? Data("edited".utf8).write(to: client) }
        let result = await fixture.install()
        // The app was already swapped: it is put back; the edited library is not the backed-up one (AC-E92a).
        XCTAssertEqual(result.outcome, .rollbackIncomplete(.conflict))
        XCTAssertEqual(fixture.text(client), "edited", "the conflicting library is never overwritten")
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" && $0.path == client.path })
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertEqual(result.report.restoredLibraries, [])

        let modeOnly = try EngineInstallFixture()
        let modeClient = modeOnly.clientLib
        onLibraryTemp(modeOnly, named: "client_arm64.dylib") {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: modeClient.path)
        }
        let modeResult = await modeOnly.install()
        XCTAssertEqual(modeResult.outcome, .rollbackIncomplete(.conflict), "a mode change is a conflict too")
        XCTAssertEqual(modeOnly.text(modeClient), "old-game-client")
    }

    func testSecondLibraryConflictRestoresOnlyTheFirst() async throws {
        let fixture = try EngineInstallFixture()
        let server = fixture.serverLib
        onLibraryTemp(fixture, named: "hl_arm64.dylib") { try? Data("edited".utf8).write(to: server) }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rollbackIncomplete(.conflict))
        XCTAssertEqual(result.report.restoredLibraries, ["gamedir:valve/cl_dlls/client_arm64.dylib"])
        XCTAssertEqual(fixture.text(fixture.clientLib), "old-game-client")
        XCTAssertEqual(fixture.text(server), "edited")
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" && $0.path == server.path })
        XCTAssertEqual(result.report.updatedLibraries, [])
    }

    func testAppSwapWaitsForEveryLibraryToMatchItsRecord() async throws {
        let fixture = try EngineInstallFixture()
        let server = fixture.serverLib
        fixture.detector.onCheck = { number in
            if number == 2 { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: server.path) }
        }
        let result = await fixture.install()
        // The mode changed after the manifest check, right before the swap: the last check stops the app swap.
        XCTAssertEqual(result.outcome, .failed(.conflict))
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" })
    }

    func testRollbackChecksEveryLibraryIncludingUntouchedOnes() async throws {
        let fixture = try EngineInstallFixture()
        let server = fixture.serverLib
        fixture.files.fail = { operation, url in
            guard operation == "swap", url.path == server.path else { return nil }
            // An outside change of the library that is never replaced.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: server.path)
            return .posix(EIO)
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rollbackIncomplete(.installFailed))
        XCTAssertEqual(result.report.restoredLibraries, ["gamedir:valve/cl_dlls/client_arm64.dylib"],
                       "only replaced libraries are listed")
        XCTAssertTrue(result.log.contains("stage=rollingBack note=libraryMismatch"))
        XCTAssertEqual(fixture.text(server), "old-game-hl", "verified, never rewritten (AC-E92b)")
    }

    // MARK: E21 swap operands, SDL2 guard, deadline, volumes (T-E-SW1, T-E-SD1, T-E-SD2, T-E-PV1, T-E-VL1)

    func testSwapSourceTurnedIntoALinkIsRefused() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        let applications = fixture.applications
        let outside = fixture.root.appendingPathComponent("outside-app")
        fixture.detector.onCheck = { number in
            guard number == 2,
                  let incoming = try? FileManager.default.contentsOfDirectory(atPath: applications.path)
                    .first(where: { $0.hasPrefix(".Xash3D-FWGS.app.pi-new-") }) else { return }
            let url = applications.appendingPathComponent(incoming)
            try? FileManager.default.moveItem(at: url, to: outside)
            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.unsafePath("appParent")))
        XCTAssertFalse(fixture.files.mutations.contains { $0.operation == "swap" })
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertEqual(LocalEngineFileOperations().kind(outside), .directory, "nothing deleted through the link")
    }

    func testSDL2RepairChecksEveryLinkPosition() async throws {
        let fixture = try EngineInstallFixture()
        let outside = try fixture.temp.write("outside-sdl", "keep")
        fixture.files.fail = { operation, url in
            if operation == "symlink", url.lastPathComponent == "Current" {
                let root = url.deletingLastPathComponent().deletingLastPathComponent()
                try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("SDL2"), withDestinationURL: outside)
            }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.unsafePath("staging")))
        XCTAssertEqual(fixture.text(outside), "keep")
        try assertNothingLeftBehind(fixture)
    }

    func testStagedAppIsPrivateAndTheTargetKeepsItsMode() async throws {
        let fixture = try EngineInstallFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.target.path)
        let applications = fixture.applications.path
        let updates = fixture.paths.engineUpdatesDirectory.path
        let seen = ModeRecorder()
        fixture.files.fail = { operation, url in
            if operation == "copyItem", url.deletingLastPathComponent().path == applications,
               let run = try? FileManager.default.contentsOfDirectory(atPath: updates).first(where: { $0.hasPrefix("run-") }) {
                seen.mode = fixture.mode(URL(fileURLWithPath: "\(updates)/\(run)/app/Xash3D-FWGS.app"))
            }
            return nil
        }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertEqual(seen.mode, 0o700, "staged app is private while it is built")
        XCTAssertEqual(fixture.mode(fixture.target), 0o755, "the installed app keeps its mode")
    }

    func testStagingParentThatIsALinkIsRefused() async throws {
        let fixture = try EngineInstallFixture()
        let outside = fixture.root.appendingPathComponent("outside-cache")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.paths.engineUpdatesDirectory, withDestinationURL: outside)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.unsafePath("cache")))
        XCTAssertEqual(fixture.downloader.calls, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [], "nothing written through it")
    }

    func testVerificationThatRunsPastTheDeadlineRollsBack() async throws {
        let fixture = try EngineInstallFixture()
        let original = try fixture.appManifest()
        let clock = fixture.clock
        let target = fixture.target.path
        fixture.signer.onVerify = { url in if url.path == target { clock.advance(by: 301) } }
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .rolledBack(.timeout(.install)))
        XCTAssertEqual(try fixture.appManifest(), original)
        XCTAssertEqual(fixture.text(fixture.serverLib), "old-game-hl")
    }

    func testLibraryVolumeWithoutRenameSwapIsRefusedBeforeDownload() async throws {
        let fixture = try EngineInstallFixture()
        let clDlls = fixture.clientLib.deletingLastPathComponent().path
        fixture.files.atomicSwapSupport = { $0.standardized.path == clDlls ? false : nil }
        let before = try fixture.snapshot(fixture.root)
        let result = await fixture.install()
        XCTAssertEqual(result.outcome, .failed(.atomicSwapUnsupported))
        XCTAssertEqual(fixture.downloader.calls, [])
        XCTAssertEqual(fixture.files.mutations, [])
        XCTAssertEqual(try fixture.snapshot(fixture.root), before)

        let probe = try EngineInstallFixture()
        probe.files.swapProbeResult = false
        let probeResult = await probe.install()
        XCTAssertEqual(probeResult.outcome, .failed(.atomicSwapUnsupported))
        XCTAssertEqual(probe.downloader.calls, [])
        XCTAssertTrue(probe.files.mutations.contains { $0.operation == "probe" })
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: probe.paths.engineUpdatesDirectory.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("swap-probe-") }, "probe folder removed")
        XCTAssertEqual(probe.backupEntries(), [])
    }

    // MARK: Privacy (AC-E47, T-E-CID3)

    func testLogHasOnlyAllowedFieldsAndNoRawIdentityOrFullCID() async throws {
        let fixture = try EngineInstallFixture()
        let fullCID = "9f8e7d6c5b4a39281706f5e4d3c2b1a0"
        let result = await fixture.install(cidBefore: fullCID)
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertNil(result.report.cidBefore, "a full CID is never kept")
        let allowed: Set<String> = ["stage", "asset", "commit", "digest", "size", "error", "cid", "note"]
        let secrets = [HexID.format(EngineInstallFixture.rawID),
                       HexID.format(EngineInstallFixture.rawID ^ IdentityLocation.homeMask),
                       HexID.format(EngineInstallFixture.rawID ^ IdentityLocation.gamedirMask)]
        for line in result.log {
            for field in line.split(separator: " ") {
                XCTAssertTrue(allowed.contains(String(field.split(separator: "=").first ?? "")), line)
            }
            XCTAssertFalse(line.contains(fullCID), line)
            for secret in secrets { XCTAssertFalse(line.uppercased().contains(secret), line) }
            XCTAssertFalse(line.contains(fixture.home.path), line)
        }
        XCTAssertEqual(result.log.first, "stage=start asset=xash3d-fwgs-apple-arm64.tar.xz commit=\(EngineReleaseFixture.commit) "
                       + "digest=\(fixture.release().asset.digest) size=15 cid=none")
        let reportText = String(describing: result.report)
        XCTAssertFalse(reportText.contains(fullCID))
        for secret in secrets { XCTAssertFalse(reportText.uppercased().contains(secret)) }
    }

    func testSecondInstallOfTheSameUpstreamIsIdempotentForTheApp() async throws {
        let fixture = try EngineInstallFixture()
        let first = await fixture.install()
        XCTAssertEqual(first.outcome, .installed)
        let manifest = try fixture.appManifest()
        fixture.downloader.setMode(.fail)
        let second = await fixture.install()
        XCTAssertEqual(second.outcome, .installed)
        XCTAssertTrue(second.log.contains("note=cacheHit"))
        XCTAssertEqual(try fixture.appManifest(), manifest, "same package, same staged app")
        XCTAssertEqual(second.report.removedModules, [])
        XCTAssertEqual(fixture.backupEntries().filter { $0.hasPrefix("identity-") }.count, 2)
    }
}

/// Thread-safe mode holder for hooks.
final class ModeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    var mode: Int? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Thread-safe call counter for fault hooks.
final class SwapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// SDL2 reconstruction on its own (T-E-SDL1, T-E-SDL2).
final class EngineSDL2FrameworkTests: XCTestCase {
    func testRebuildsRelativeLinksAndIsIdempotent() throws {
        let temp = try TempDirectory()
        let local = LocalEngineFileOperations()
        let framework = temp.url.appendingPathComponent("SDL2.framework")
        try temp.write("SDL2.framework/Versions/A/SDL2", "binary")
        try temp.write("SDL2.framework/Versions/A/Headers/SDL.h", "header")
        try temp.write("SDL2.framework/Versions/A/Resources/Info.plist", "plist")
        try temp.write("SDL2.framework/SDL2", "binary")
        try temp.write("SDL2.framework/Headers/SDL.h", "header")
        try temp.write("SDL2.framework/Versions/Current/SDL2", "binary")

        try EngineSDL2Framework.reconstruct(framework, files: local)
        let first = try EngineTree.manifest(framework, files: local)
        for link in EngineSDL2Framework.links {
            let url = framework.appendingPathComponent(link.path)
            XCTAssertEqual(local.kind(url), .symbolicLink, link.path)
            XCTAssertEqual(local.symbolicLinkTarget(url), link.target)
        }
        try EngineSDL2Framework.reconstruct(framework, files: local)
        XCTAssertEqual(try EngineTree.manifest(framework, files: local), first, "same tree on the second run")
    }

    func testMissingLinkTargetFails() throws {
        for missing in ["SDL2", "Headers", "Resources"] {
            let temp = try TempDirectory()
            for name in ["SDL2", "Headers/SDL.h", "Resources/Info.plist"] where !name.hasPrefix(missing) {
                try temp.write("SDL2.framework/Versions/A/" + name, "x")
            }
            XCTAssertThrowsError(try EngineSDL2Framework.reconstruct(temp.url.appendingPathComponent("SDL2.framework"),
                                                                     files: LocalEngineFileOperations()), missing) {
                XCTAssertEqual($0 as? EngineInstallFailure, .sdl2Reconstruction)
            }
        }
    }
}

import CryptoKit
import Darwin
import XCTest
@testable import PlayerIdentity

/// v2.26 production adapters against the real system tools, in a temporary folder only (no network, no
/// `/Applications`): `/usr/bin/tar` fed from in-memory archive bytes (T-E-X*, T-E-FD1, T-E-U1), `/usr/bin/codesign`
/// (T-E-C*, T-E-SDL5), the Darwin file operations (RENAME_SWAP, `O_EXCL`/`O_NOFOLLOW`, private modes, quarantine) and
/// `SystemProcess` reaping (T-E-PR1, T-E-PR3).
final class EngineInstallAdapterTests: XCTestCase {
    private func makeTar(from folder: URL, items: [String], absolute: Bool = false) async throws -> Data {
        let archive = folder.deletingLastPathComponent().appendingPathComponent("archive-\(UUID().uuidString).tar.xz")
        let flags = absolute ? "-cJPf" : "-cJf"
        let output = try await SystemProcess.run(["/usr/bin/tar", "--no-mac-metadata", flags, archive.path, "-C",
                                                  folder.path] + items, timeout: 60)
        XCTAssertEqual(output.status, 0, output.output)
        return try Data(contentsOf: archive)
    }

    private func populatePackage(_ temp: TempDirectory, root: String) throws {
        for module in EngineArchiveLayout.requiredModules { try temp.write("\(root)/\(module)", "new-\(module)") }
        for extra in EngineArchiveLayout.rootExtras { try temp.write("\(root)/\(extra)", "extra") }
        for version in ["SDL2.framework/Versions/A", "SDL2.framework/Versions/Current", "SDL2.framework"] {
            try temp.write("\(root)/\(version)/SDL2", "sdl")
            try temp.write("\(root)/\(version)/Headers/SDL.h", "h")
            try temp.write("\(root)/\(version)/Resources/Info.plist", "p")
        }
        try temp.write("\(root)/valve/cl_dlls/client_arm64.dylib", "client")
    }

    // MARK: tar from memory (T-E-X1 – T-E-X6, T-E-FD1, T-E-U1)

    func testTarListsAndExtractsAPackageFromTheSameBytesOnStdin() async throws {
        let temp = try TempDirectory()
        try populatePackage(temp, root: "src")
        let bytes = try await makeTar(from: temp.url.appendingPathComponent("src"), items: ["."])
        // The archive file is gone before listing: only the in-memory bytes are used.
        for name in try FileManager.default.contentsOfDirectory(atPath: temp.url.path) where name.hasPrefix("archive-") {
            try FileManager.default.removeItem(at: temp.url.appendingPathComponent(name))
        }
        let tar = TarEngineArchive()
        let entries = try await tar.list(bytes)
        XCTAssertTrue(entries.contains(EngineArchiveEntry(path: "./xash3d", type: .regular)))
        let plan = try EngineArchiveLayout.validate(entries, architecture: .arm64).get()
        XCTAssertTrue(plan.contains("valve/extras.pk3"))
        XCTAssertTrue(plan.contains("SDL2.framework/Versions/Current/Headers/SDL.h"))

        // A destination with a space and a semicolon is one argument; no shell interprets it.
        let destination = temp.url.appendingPathComponent("out dir; touch pwned")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await tar.extract(bytes, into: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("libxash.dylib"), encoding: .utf8),
                       "new-libxash.dylib")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("pwned").path))
    }

    func testTarListingExposesLinksAndTraversalSoTheScanRejectsThem() async throws {
        let temp = try TempDirectory()
        try populatePackage(temp, root: "links")
        let links = temp.url.appendingPathComponent("links")
        try FileManager.default.removeItem(at: links.appendingPathComponent("SDL2.framework/SDL2"))
        try FileManager.default.createSymbolicLink(atPath: links.appendingPathComponent("SDL2.framework/SDL2").path,
                                                   withDestinationPath: "Versions/A/SDL2")
        XCTAssertEqual(link(links.appendingPathComponent("libmenu.dylib").path,
                            links.appendingPathComponent("mdldec2").path), 0)
        let entries = try await TarEngineArchive().list(try await makeTar(from: links, items: ["."]))
        XCTAssertTrue(entries.contains { $0.path == "./SDL2.framework/SDL2" && $0.type == .symbolicLink }, "\(entries)")
        XCTAssertTrue(entries.contains { $0.type == .hardLink }, "\(entries)")
        guard case .failure(.unsafeArchive) = EngineArchiveLayout.validate(entries, architecture: .arm64) else {
            return XCTFail("links accepted")
        }

        try temp.write("base/evil.dylib", "evil")
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("base/sub"),
                                                withIntermediateDirectories: true)
        let traversal = try await TarEngineArchive().list(
            try await makeTar(from: temp.url.appendingPathComponent("base/sub"), items: ["../evil.dylib"], absolute: true))
        XCTAssertEqual(traversal, [EngineArchiveEntry(path: "../evil.dylib", type: .regular)])
        XCTAssertEqual(EngineArchiveLayout.validate(traversal, architecture: .arm64),
                       .failure(.unsafeArchive("../evil.dylib")))
    }

    func testBrokenArchiveIsAToolErrorWithoutOutput() async throws {
        do {
            _ = try await TarEngineArchive().list(Data("not an archive /Users/secret".utf8))
            XCTFail("listed")
        } catch let error as EngineToolError {
            XCTAssertEqual(error.tool, "tar")
            XCTAssertEqual(error.category, .archiveRejected)
            XCTAssertNotEqual(error.exitStatus, 0)
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    // MARK: codesign (T-E-C1, T-E-C2, T-E-SDL5)

    func testCodesignWithoutDeepKeepsNestedLibrariesAndVerifiesStrictly() async throws {
        let temp = try TempDirectory()
        let app = temp.url.appendingPathComponent("Xash3D-FWGS.app")
        try temp.write("Xash3D-FWGS.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>xash3d</string>\
        <key>CFBundleIdentifier</key><string>tr.ercanatay.playeridentity.tests.engine</string>\
        <key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS.appendingPathComponent("dlls"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("xash3d").path)
        // A nested, already (platform-)signed Mach-O library stand-in.
        let nested = macOS.appendingPathComponent("dlls/hl_arm64.dylib")
        try FileManager.default.copyItem(atPath: "/usr/bin/false", toPath: nested.path)
        let nestedBefore = try LocalEngineFileOperations().sha256(nested)
        try temp.write("Xash3D-FWGS.app/Contents/Resources/data.txt", "resource")

        let signer = ProcessEngineCodeSigner()
        try await signer.signApp(app)
        try await signer.verify(app)
        XCTAssertEqual(try LocalEngineFileOperations().sha256(nested), nestedBefore, "not re-signed (no --deep)")

        try temp.write("Xash3D-FWGS.app/Contents/Resources/data.txt", "tampered")
        do {
            try await signer.verify(app)
            XCTFail("tampered bundle verified")
        } catch let error as EngineToolError {
            XCTAssertEqual(error.category, .signatureInvalid)
        }
    }

    // MARK: File operations (AC-E39, AC-E48, AC-E30, AC-E73)

    func testPrivateFoldersExclusiveFilesNoFollowAndWholeFileReads() throws {
        let temp = try TempDirectory()
        let files = LocalEngineFileOperations()
        let folder = temp.url.appendingPathComponent("a/b")
        try files.createPrivateDirectory(folder)
        XCTAssertEqual(try permissions(folder), 0o700)
        try files.createDirectory(temp.url.appendingPathComponent("c"), permissions: 0o755)
        XCTAssertEqual(try permissions(temp.url.appendingPathComponent("c")), 0o755)

        let source = try temp.write("source.bin", "payload")
        let copy = folder.appendingPathComponent("copy.bin")
        try files.copyFile(source, to: copy, permissions: 0o600)
        XCTAssertEqual(try permissions(copy), 0o600)
        XCTAssertThrowsError(try files.copyFile(source, to: copy, permissions: 0o600)) {
            XCTAssertEqual($0 as? EngineFileError, .posix(EEXIST))
        }
        let alias = temp.url.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try files.copyFile(alias, to: folder.appendingPathComponent("x"), permissions: 0o600))
        XCTAssertThrowsError(try files.readRegularFile(alias, maxBytes: 100), "a link is never opened")
        XCTAssertEqual(try files.readRegularFile(source, maxBytes: 100), Data("payload".utf8))
        XCTAssertThrowsError(try files.readRegularFile(source, maxBytes: 3)) {
            XCTAssertEqual($0 as? EngineFileError, .tooLarge)
        }
        XCTAssertEqual(link(source.path, temp.url.appendingPathComponent("hard.bin").path), 0)
        XCTAssertEqual(files.linkCount(source), 2)
    }

    func testRenameSwapIsAtomicAndItsSupportIsReadWithoutWriting() throws {
        let temp = try TempDirectory()
        let files = LocalEngineFileOperations()
        XCTAssertTrue(files.supportsAtomicSwap(temp.url), "APFS temp volume")
        XCTAssertFalse(files.supportsAtomicSwap(URL(fileURLWithPath: "/dev")), "devfs cannot swap")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path), [], "query wrote nothing")
        try temp.write("one/marker", "one")
        try temp.write("two/marker", "two")
        try files.swapItems(temp.url.appendingPathComponent("one"), temp.url.appendingPathComponent("two"))
        XCTAssertEqual(try String(contentsOf: temp.url.appendingPathComponent("one/marker"), encoding: .utf8), "two")
        XCTAssertThrowsError(try files.swapItems(temp.url.appendingPathComponent("one"),
                                                 temp.url.appendingPathComponent("missing")))
    }

    func testPathGuardRefusesLinkedAncestorsAndEscapes() throws {
        let temp = try TempDirectory()
        let files = LocalEngineFileOperations()
        let root = URL(fileURLWithPath: LocalFileProbe.physicalPath(temp.url.path))
        try temp.write("real/inner/file", "x")
        try temp.write("outside/file", "y")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("real/link"),
                                                   withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertNoThrow(try EnginePathGuard.check(root.appendingPathComponent("real/inner/file"), root: root,
                                                   role: "test", files: files))
        XCTAssertNoThrow(try EnginePathGuard.check(root.appendingPathComponent("real/inner/new"), root: root,
                                                   role: "test", files: files))
        for path in ["real/link/file", "real/link", "real/link/new"] {
            XCTAssertThrowsError(try EnginePathGuard.check(root.appendingPathComponent(path), root: root, role: "test",
                                                           files: files), path) {
                XCTAssertEqual($0 as? EngineInstallFailure, .unsafePath("test"))
            }
        }
        XCTAssertThrowsError(try EnginePathGuard.check(URL(fileURLWithPath: "/etc/hosts"), root: root, role: "test",
                                                       files: files))
        XCTAssertThrowsError(try EnginePathGuard.check(root, root: root, role: "test", files: files), "never the root")
    }

    func testQuarantineAttributeIsRemovedAndAbsenceIsNotAnError() throws {
        let temp = try TempDirectory()
        let files = LocalEngineFileOperations()
        let file = try temp.write("lib.dylib", "x")
        let value = Array("0081;00000000;PlayerIdentityTests;".utf8)
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", value, value.count, 0, 0), 0)
        try files.removeExtendedAttribute("com.apple.quarantine", at: file)
        XCTAssertEqual(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0), -1)
        XCTAssertNoThrow(try files.removeExtendedAttribute("com.apple.quarantine", at: file))
    }

    // MARK: E21 lock and descriptor-relative swap (T-E-LK2, T-E-SW2)

    func testLockIsExclusiveAndReleasedWhenTheHoldingProcessEnds() async throws {
        let temp = try TempDirectory()
        let files = LocalEngineFileOperations()
        let url = temp.url.appendingPathComponent(".install.lock")
        let first = try files.acquireExclusiveLock(url)
        XCTAssertThrowsError(try files.acquireExclusiveLock(url)) { XCTAssertEqual($0 as? EngineLockError, .busy) }
        first.release()
        let second = try files.acquireExclusiveLock(url)
        second.release()

        // Another process holds it (flock via lockf); killing that process releases it. No PID file exists.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", url.path, "/bin/sleep", "30"]
        try holder.run()
        var busy = false
        for _ in 0..<200 {
            do {
                let probe = try files.acquireExclusiveLock(url)
                probe.release()
            } catch EngineLockError.busy {
                busy = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(busy, "the other process holds the lock")
        holder.terminate()
        holder.waitUntilExit()
        let after = try files.acquireExclusiveLock(url)
        after.release()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path), [".install.lock"])
        XCTAssertEqual(try permissions(url), 0o600)
    }

    func testLockOnALinkIsUnavailable() throws {
        let temp = try TempDirectory()
        let target = try temp.write("target", "keep")
        let link = temp.url.appendingPathComponent(".install.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LocalEngineFileOperations().acquireExclusiveLock(link)) {
            XCTAssertEqual($0 as? EngineLockError, .unavailable(ELOOP))
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testSwapIsDescriptorRelativeAndRefusesALinkedParent() throws {
        let temp = try TempDirectory()
        let files = LocalEngineFileOperations()
        let root = URL(fileURLWithPath: LocalFileProbe.physicalPath(temp.url.path))
        try temp.write("real/a", "a")
        try temp.write("real/b", "b")
        try files.swapItems(root.appendingPathComponent("real/a"), root.appendingPathComponent("real/b"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("real/a"), encoding: .utf8), "b")

        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("real"))
        XCTAssertThrowsError(try files.swapItems(alias.appendingPathComponent("a"), alias.appendingPathComponent("b")),
                             "a parent reached through a link is never opened")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("real/a"), encoding: .utf8), "b", "unchanged")
        XCTAssertTrue(files.probeAtomicSwap(in: root.appendingPathComponent("real")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("real").path).sorted(),
                       ["a", "b"], "probe files removed")
        XCTAssertEqual(files.volumeID(root.appendingPathComponent("real/a")), files.volumeID(root))
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}

/// `SystemProcess` returns only after the child (and its process group) is gone (T-E-PR1, T-E-PR3).
final class SystemProcessReapTests: XCTestCase {
    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private func readPID(_ url: URL) async throws -> pid_t {
        for _ in 0..<200 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("child never wrote its pid")
        return -1
    }

    func testTimeoutWaitsUntilAChildThatIgnoresTermIsKilledAndReaped() async throws {
        let temp = try TempDirectory()
        let pidFile = temp.url.appendingPathComponent("pid")
        let start = Date()
        do {
            _ = try await SystemProcess.run(["/bin/sh", "-c", "trap '' TERM; echo $$ > '\(pidFile.path)'; "
                                             + "while :; do /bin/sleep 0.05; done"], timeout: 0.3)
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? CommandError, .timedOut)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, SystemProcess.killGrace, "waited for SIGKILL, not just the signal")
        XCTAssertLessThan(elapsed, 10)
        let pid = try await readPID(pidFile)
        XCTAssertFalse(isAlive(pid), "the child is gone when the call returns")
    }

    func testCancellationCleanupRunsAfterTheWholeGroupIsGone() async throws {
        let temp = try TempDirectory()
        let folder = temp.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.path
        let task = Task {
            try await SystemProcess.run(["/bin/sh", "-c", "i=0; while :; do i=$((i+1)); "
                                         + "/usr/bin/touch '\(path)/f'$i; /bin/sleep 0.02; done"],
                                        timeout: 60, cancellable: true)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch {
            XCTAssertEqual(error as? CommandError, .cancelled)
        }
        // Cleanup after the reap: nothing can write into the folder any more.
        try FileManager.default.removeItem(at: folder)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "no child left that recreates files")
    }

    // MARK: E21 waitpid and spawn failures (T-E-WP1 – T-E-WP3)

    private func fakeSpawn(_ pid: pid_t = 4_242_424) -> ProcessSystemCalls {
        var calls = ProcessSystemCalls.live
        calls.spawn = { _, _, _, _, _ in (0, pid) }
        return calls
    }

    func testWaitFailuresAreFailures() async {
        for result in [(pid_t(-1), Int32(0), ECHILD), (pid_t(1), Int32(0), Int32(0)), (pid_t(-1), Int32(0), EINVAL)] {
            var calls = fakeSpawn()
            calls.wait = { _ in result }
            do {
                _ = try await SystemProcess.run(["/bin/echo"], timeout: 5, system: calls)
                XCTFail("\(result)")
            } catch {
                XCTAssertEqual(error as? CommandError, .waitFailed, "\(result)")
            }
        }
    }

    func testOnlyANormalExitIsAStatusAndASignalIsAFailure() async throws {
        var signaled = fakeSpawn(77)
        signaled.wait = { pid in (pid, 9, 0) }
        do {
            _ = try await SystemProcess.run(["/bin/echo"], timeout: 5, system: signaled)
            XCTFail("signaled child reported as a result")
        } catch {
            XCTAssertEqual(error as? CommandError, .signaled(9))
        }
        var exited = fakeSpawn(78)
        exited.wait = { pid in (pid, 3 << 8, 0) }
        let output = try await SystemProcess.run(["/bin/echo"], timeout: 5, system: exited)
        XCTAssertEqual(output.status, 3, "a non-zero exit is returned as a status, never as success by callers")
        do {
            _ = try await SystemProcess.run(["/bin/sh", "-c", "kill -9 $$"], timeout: 10)
            XCTFail("killed child reported as a result")
        } catch {
            XCTAssertEqual(error as? CommandError, .signaled(9))
        }
    }

    func testEverySpawnSetupFailureIsExplicitAndLaunchesNothing() async {
        let spawned = SwapCounter()
        for step in ProcessSpawnStep.allCases {
            var calls = ProcessSystemCalls.live
            calls.injectSetupFailure = { $0 == step ? EINVAL : 0 }
            calls.spawn = { _, _, _, _, _ in
                _ = spawned.next()
                return (0, 1)
            }
            do {
                _ = try await SystemProcess.run(["/bin/echo"], timeout: 5, system: calls)
                XCTFail(step.rawValue)
            } catch {
                XCTAssertEqual(error as? CommandError, .launchFailed, step.rawValue)
            }
        }
        XCTAssertEqual(spawned.next(), 1, "posix_spawn never ran")
        var noPipe = ProcessSystemCalls.live
        noPipe.makePipe = { nil }
        var spawnError = ProcessSystemCalls.live
        spawnError.spawn = { _, _, _, _, _ in (ENOENT, 0) }
        for calls in [noPipe, spawnError] {
            do {
                _ = try await SystemProcess.run(["/bin/echo"], timeout: 5, system: calls)
                XCTFail("launched")
            } catch {
                XCTAssertEqual(error as? CommandError, .launchFailed)
            }
        }
    }

    func testAFailingGroupSignalIsReportedAfterTheChildIsReaped() async throws {
        let temp = try TempDirectory()
        let pidFile = temp.url.appendingPathComponent("pid")
        var calls = ProcessSystemCalls.live
        calls.signal = { pid, signal in pid < 0 ? EPERM : (kill(pid, signal) == 0 ? 0 : errno) }
        do {
            _ = try await SystemProcess.run(["/bin/sh", "-c", "echo $$ > '\(pidFile.path)'; exec /bin/sleep 30"],
                                            timeout: 0.3, system: calls)
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? CommandError, .signalFailed)
        }
        let pid = try await readPID(pidFile)
        XCTAssertFalse(isAlive(pid), "the child was still stopped and reaped")
    }

    func testStdinIsFedAndStderrCanBeDiscarded() async throws {
        let text = String(repeating: "archive-bytes-0123456789\n", count: 20_000)
        let echoed = try await SystemProcess.run(["/bin/cat"], timeout: 30, input: Data(text.utf8))
        XCTAssertEqual(echoed, CommandOutput(status: 0, output: text), "large stdin fully delivered")
        let quiet = try await SystemProcess.run(["/bin/sh", "-c", "echo out; echo secret >&2; exit 4"], timeout: 10,
                                                includeStandardError: false)
        XCTAssertEqual(quiet, CommandOutput(status: 4, output: "out\n"))
    }
}

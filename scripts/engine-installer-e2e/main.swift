// T-E-GE7 (opt-in release gate, spec E19.9/E20): the real official asset through the real installer core.
//
// Built and run only by `scripts/test-engine-installer-e2e.sh` (compiled together with `PlayerIdentity/Core`). Every
// path it writes is below the work folder given as the first argument (a fresh temporary folder): a fake target app
// with the real bundle topology, a temporary HOME and a temporary game data root. The engine run is wrapped in
// `sandbox-exec` with writes to the real home folder and `/Applications` denied; the real game data is offered only
// as a read-only `-rodir` without identity or config files. Output: release facts, check results, masked CID only.

import CryptoKit
import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: e2e <work-folder> <expected-commit> <expected-digest>")
    exit(2)
}
let work = URL(fileURLWithPath: arguments[1], isDirectory: true)
let expectedCommit = arguments[2]
let expectedDigest = arguments[3]
let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir), isDirectory: true)
let local = LocalEngineFileOperations()
var failures: [String] = []

@MainActor
func check(_ condition: Bool, _ label: String) {
    print((condition ? "PASS " : "FAIL ") + label)
    if !condition { failures.append(label) }
}

func write(_ url: URL, _ text: String, mode: Int = 0o644) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

func sha(_ url: URL) -> String? { try? local.sha256(url) }

// MARK: Isolated layout

let home = work.appendingPathComponent("home", isDirectory: true)
let applications = work.appendingPathComponent("Applications", isDirectory: true)
let target = applications.appendingPathComponent("Xash3D-FWGS.app", isDirectory: true)
let paths = AppPaths(home: home)
let dataRoot = paths.defaultDataRoot
let gamedir = dataRoot.appendingPathComponent("valve", isDirectory: true)
let contents = target.appendingPathComponent("Contents", isDirectory: true)

try FileManager.default.createDirectory(at: paths.snapshotFile.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try write(contents.appendingPathComponent("Info.plist"), """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>xash3d</string>\
<key>CFBundleIdentifier</key><string>su.xash.Xash3D</string><key>CFBundlePackageType</key><string>APPL</string>\
<key>CFBundleShortVersionString</key><string>0.20</string></dict></plist>
""")
for module in EngineArchiveLayout.knownModules {
    try write(contents.appendingPathComponent("MacOS/\(module)"), "old-\(module)", mode: 0o755)
}
try write(contents.appendingPathComponent("MacOS/cl_dlls/client_arm64.dylib"), "old-bundle-client", mode: 0o755)
try write(contents.appendingPathComponent("MacOS/dlls/hl_arm64.dylib"), "old-bundle-hl", mode: 0o755)
// An unrelated nested library is a signed Mach-O like in the real bundle (codesign refuses unsigned nested code).
try FileManager.default.copyItem(atPath: "/usr/bin/false",
                                 toPath: contents.appendingPathComponent("MacOS/dlls/opfor_arm64.dylib").path)
try write(contents.appendingPathComponent("Resources/valve/extras.pk3"), "old-extras")
let oldFramework = contents.appendingPathComponent("MacOS/SDL2.framework")
try write(oldFramework.appendingPathComponent("Versions/A/SDL2"), "old-sdl", mode: 0o755)
try write(oldFramework.appendingPathComponent("Versions/A/Headers/SDL.h"), "old")
try write(oldFramework.appendingPathComponent("Versions/A/Resources/Info.plist"), "old")
for link in EngineSDL2Framework.links {
    try FileManager.default.createSymbolicLink(atPath: oldFramework.appendingPathComponent(link.path).path,
                                               withDestinationPath: link.target)
}
try write(gamedir.appendingPathComponent("cl_dlls/client_arm64.dylib"), "old-game-client")
try write(gamedir.appendingPathComponent("dlls/hl_arm64.dylib"), "old-game-hl")
try write(gamedir.appendingPathComponent("gameinfo.txt"),
          "title \"Half-Life\"\ngamedir \"valve\"\ngamedll \"dlls/hl.dll\"\ngamedll_osx \"dlls/hl.dylib\"\n")

let environment = EngineInstallEnvironment(targetApp: target, dataRoot: dataRoot, gamedir: "valve", home: home,
                                           paths: paths, architecture: .arm64)
let reader = LocalEngineIdentityReader()
let identityBefore = reader.snapshot(home: home, gamedir: gamedir)

// MARK: Release metadata (AC-E49)

let installer = EngineInstaller.live(environment: environment)
let release: EngineRelease
switch await installer.fetchRelease() {
case .success(let value): release = value
case .failure(let failure):
    print("FAIL fetchRelease: \(failure.code)")
    exit(1)
}
print("release commit=\(release.commitSHA) asset=\(release.asset.name) size=\(release.asset.size) digest=\(release.asset.digest)")
check(release.prerelease, "prerelease == true")
check(release.commitSHA == expectedCommit, "commit equals the API value")
check(release.asset.digest == expectedDigest, "digest equals the API value (read live, not pinned)")

// MARK: Install

let result = await installer.install(release, confirmation: EngineInstallConfirmation(acceptedCIDWarning: true,
                                                                                      cidBefore: identityBefore.cidMasked))
for line in result.log { print("log " + line) }
check(result.outcome == .installed, "install outcome installed (\(result.outcome))")
check(result.report.leftovers.isEmpty, "no leftovers")
guard result.outcome == .installed else {
    print("E2E RESULT: FAIL (install did not complete)")
    exit(1)
}

// Independent reference: the cached archive re-verified and extracted on its own.
let cached = paths.engineUpdatesDirectory.appendingPathComponent(release.asset.name)
let reference = work.appendingPathComponent("reference", isDirectory: true)
try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
let archiveBytes = try Data(contentsOf: cached)
check(EngineInstallNaming.sha256Hex(archiveBytes) == release.asset.sha256, "cached archive matches the digest")
let extracted = try await SystemProcess.run(["/usr/bin/tar", "-xJf", "-", "-C", reference.path], timeout: 120,
                                            input: archiveBytes)
check(extracted.status == 0, "reference extraction")
let listing = try await TarEngineArchive().list(archiveBytes)
let plan = try EngineArchiveLayout.validate(listing, architecture: .arm64).get()
let rootFiles = Set(plan.files.filter { !$0.contains("/") || $0.hasPrefix("valve/") && $0.split(separator: "/").count == 2 })
let expectedExtras = Set(EngineArchiveLayout.rootExtras)
check(rootFiles.subtracting(EngineArchiveLayout.knownModules) == expectedExtras, "root extras are exactly the six (E19.2)")
check(!plan.contains("libref_soft.dylib"), "libref_soft is not in the package")

let macOS = contents.appendingPathComponent("MacOS")
for module in EngineArchiveLayout.requiredModules where module != "xash3d" {
    check(sha(macOS.appendingPathComponent(module)) == sha(reference.appendingPathComponent(module)),
          "module \(module) is the exact upstream build")
}
check(local.kind(macOS.appendingPathComponent("libref_soft.dylib")) == .missing, "stale libref_soft removed")
for extra in EngineArchiveLayout.rootExtras {
    check(local.kind(macOS.appendingPathComponent((extra as NSString).lastPathComponent)) == .missing,
          "extra \(extra) not copied")
}
for library in EngineArchiveLayout.gameLibraries(architecture: .arm64) {
    let upstream = sha(reference.appendingPathComponent(library.source))
    check(upstream != nil && sha(target.appendingPathComponent(library.bundle)) == upstream,
          "bundle \(library.bundle) is the exact upstream build after signing (AC-E46d)")
    check(sha(gamedir.appendingPathComponent(library.gamedirRelative)) == upstream,
          "gamedir \(library.gamedirRelative) is the exact upstream build")
}
let framework = macOS.appendingPathComponent("SDL2.framework")
check((try? local.contents(framework)) == ["Headers", "Resources", "SDL2", "Versions"], "SDL2 root holds only links + Versions")
for link in EngineSDL2Framework.links {
    check(local.symbolicLinkTarget(framework.appendingPathComponent(link.path)) == link.target, "SDL2 link \(link.path)")
}
let versionItems = (try? EngineTree.walk(framework.appendingPathComponent("Versions/A"), files: local)) ?? []
var frameworkMatches = !versionItems.isEmpty
for item in versionItems where item.kind == .regularFile && item.path != "SDL2" && !item.path.hasPrefix("_CodeSignature/") {
    if sha(framework.appendingPathComponent("Versions/A/" + item.path))
        != sha(reference.appendingPathComponent("SDL2.framework/Versions/A/" + item.path)) {
        frameworkMatches = false
    }
}
check(frameworkMatches, "SDL2 Versions/A files equal upstream (signed binary/_CodeSignature exempt)")
let verify = try await SystemProcess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--", target.path],
                                         timeout: 120, includeStandardError: false)
check(verify.status == 0, "codesign --verify --deep --strict on the installed app")
check(local.kind(contents.appendingPathComponent("Resources/valve/extras.pk3")) == .regularFile, "Resources untouched")

// MARK: Engine run in a sandbox (identity repair, AC-E44)

let realData = realHome.appendingPathComponent("Library/Application Support/Xash3D FWGS/valve", isDirectory: true)
let readOnly = work.appendingPathComponent("rodir/valve", isDirectory: true)
try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
let excluded: Set<String> = ["cl_dlls", "dlls", "custom", "save", "downloads", "console_history.txt", "voice_ban.dt",
                             "gameinfo.txt"]
if local.kind(realData) == .directory {
    for name in try FileManager.default.contentsOfDirectory(atPath: realData.path)
    where !name.hasPrefix(".") && !excluded.contains(name) && !name.hasSuffix(".cfg") && !name.contains(".bak")
        && !name.contains(".appbak") {
        try FileManager.default.createSymbolicLink(at: readOnly.appendingPathComponent(name),
                                                   withDestinationURL: realData.appendingPathComponent(name))
    }
} else {
    print("FAIL no Half-Life data at the default location: the engine run needs it read-only (-rodir)")
    exit(1)
}
let profile = "(version 1)(allow default)(deny file-write* (subpath \"\(realHome.path)\") (subpath \"/Applications\"))"
// Prove the sandbox really denies writes to the real home before the engine runs in it.
let probeFile = realHome.appendingPathComponent(".pi-engine-e2e-sandbox-probe-\(getpid())")
let probe = Process()
probe.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
probe.arguments = ["-p", profile, "/usr/bin/touch", probeFile.path]
probe.standardError = FileHandle.nullDevice
try probe.run()
probe.waitUntilExit()
let leaked = FileManager.default.fileExists(atPath: probeFile.path)
if leaked { try? FileManager.default.removeItem(at: probeFile) }
check(probe.terminationStatus != 0 && !leaked, "sandbox denies writes to the real home")
guard !leaked else {
    print("E2E RESULT: FAIL (sandbox not effective; the engine is not run)")
    exit(1)
}

// The lock is taken and released by the installer; a second holder is refused while one is held (T-E-LK1).
let lockURL = paths.engineBackupsDirectory.appendingPathComponent(".install.lock")
let held = try local.acquireExclusiveLock(lockURL)
let blocked = await installer.install(release, confirmation: EngineInstallConfirmation(acceptedCIDWarning: true,
                                                                                       cidBefore: nil))
check(blocked.outcome == .failed(.locked), "a second installer is refused while the lock is held")
held.release()
let engine = Process()
engine.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
engine.arguments = ["-p", profile, macOS.appendingPathComponent("xash3d").path, "-rodir",
                    work.appendingPathComponent("rodir").path, "-game", "valve", "-windowed", "-width", "320",
                    "-height", "240", "+quit"]
engine.environment = ["HOME": home.path, "XASH3D_BASEDIR": dataRoot.path, "PATH": "/usr/bin:/bin"]
engine.currentDirectoryURL = dataRoot
engine.standardOutput = FileHandle.nullDevice
engine.standardError = FileHandle.nullDevice
try engine.run()
let started = Date()
while engine.isRunning && Date().timeIntervalSince(started) < 60 { try await Task.sleep(for: .milliseconds(200)) }
if engine.isRunning {
    engine.terminate()
    engine.waitUntilExit()
}
check(engine.terminationStatus == 0, "engine run exited cleanly (status \(engine.terminationStatus))")
let identityAfter = reader.snapshot(home: home, gamedir: gamedir)
let verdict = EngineIdentityVerifier.evaluate(before: identityBefore, after: identityAfter)
print("identity before global=\(identityBefore.global.rawValue) gamedir=\(identityBefore.gamedir.rawValue)")
print("identity after global=\(identityAfter.global.rawValue) gamedir=\(identityAfter.gamedir.rawValue) "
      + "rawEqual=\(identityAfter.rawEqual) cid=\(identityAfter.cidMasked ?? "none")")
check(identityAfter.global == .nonzero && identityAfter.gamedir == .nonzero && identityAfter.rawEqual,
      "global and gamedir raw non-zero and equal")
check(verdict.verification == .identityRepaired, "verifier: identityRepaired (\(verdict.verification.rawValue))")

// MARK: Atomic replace + rollback with an injected failure

struct FailingLibrarySwap: EngineFileOperating {
    let real = LocalEngineFileOperations()
    let failingPath: String
    func kind(_ url: URL) -> ProbedItemKind { real.kind(url) }
    func size(_ url: URL) throws -> UInt64 { try real.size(url) }
    func permissions(_ url: URL) -> UInt32? { real.permissions(url) }
    func read(_ url: URL, offset: UInt64, length: Int) throws -> Data { try real.read(url, offset: offset, length: length) }
    func resolvedPath(_ url: URL) -> String { real.resolvedPath(url) }
    func linkCount(_ url: URL) -> Int? { real.linkCount(url) }
    func isWritable(_ url: URL) -> Bool { real.isWritable(url) }
    func supportsAtomicSwap(_ url: URL) -> Bool { real.supportsAtomicSwap(url) }
    func contents(_ url: URL) throws -> [String] { try real.contents(url) }
    func createDirectory(_ url: URL, permissions: UInt16) throws { try real.createDirectory(url, permissions: permissions) }
    func copyItem(_ source: URL, to destination: URL) throws { try real.copyItem(source, to: destination) }
    func copyFile(_ source: URL, to destination: URL, permissions: UInt16) throws {
        try real.copyFile(source, to: destination, permissions: permissions)
    }
    func writeFile(_ data: Data, to destination: URL, permissions: UInt16) throws {
        try real.writeFile(data, to: destination, permissions: permissions)
    }
    func readRegularFile(_ url: URL, maxBytes: Int64) throws -> Data { try real.readRegularFile(url, maxBytes: maxBytes) }
    func moveItem(_ source: URL, to destination: URL) throws { try real.moveItem(source, to: destination) }
    func swapItems(_ first: URL, _ second: URL) throws {
        if second.path == failingPath { throw EngineFileError.posix(EIO) }
        try real.swapItems(first, second)
    }
    func volumeID(_ url: URL) -> UInt64? { real.volumeID(url) }
    func probeAtomicSwap(in folder: URL) -> Bool { real.probeAtomicSwap(in: folder) }
    func acquireExclusiveLock(_ url: URL) throws -> EngineFileLock { try real.acquireExclusiveLock(url) }
    func removeItem(_ url: URL) throws { try real.removeItem(url) }
    func createSymbolicLink(_ url: URL, target: String) throws { try real.createSymbolicLink(url, target: target) }
    func symbolicLinkTarget(_ url: URL) -> String? { real.symbolicLinkTarget(url) }
    func setPermissions(_ url: URL, _ mode: UInt16) throws { try real.setPermissions(url, mode) }
    func sha256(_ url: URL) throws -> String { try real.sha256(url) }
    func removeExtendedAttribute(_ name: String, at url: URL) throws { try real.removeExtendedAttribute(name, at: url) }
}

// Put the old libraries back so the second install has something to replace, then fail the second library swap.
try local.removeItem(gamedir.appendingPathComponent("cl_dlls/client_arm64.dylib"))
try write(gamedir.appendingPathComponent("cl_dlls/client_arm64.dylib"), "old-game-client")
let appBefore = try EngineTree.manifest(target, files: local)
let clientBefore = sha(gamedir.appendingPathComponent("cl_dlls/client_arm64.dylib"))
let serverBefore = sha(gamedir.appendingPathComponent("dlls/hl_arm64.dylib"))
let failing = EngineInstaller.live(environment: environment,
                                   files: FailingLibrarySwap(failingPath: gamedir.appendingPathComponent("dlls/hl_arm64.dylib").path))
let rollback = await failing.install(release, confirmation: EngineInstallConfirmation(acceptedCIDWarning: true,
                                                                                      cidBefore: nil))
for line in rollback.log { print("log " + line) }
check(rollback.outcome == .rolledBack(.installFailed), "injected failure rolls back (\(rollback.outcome))")
check((try? EngineTree.manifest(target, files: local)) == appBefore, "app equals its backup after rollback")
check(sha(gamedir.appendingPathComponent("cl_dlls/client_arm64.dylib")) == clientBefore, "client library restored")
check(sha(gamedir.appendingPathComponent("dlls/hl_arm64.dylib")) == serverBefore, "server library unchanged")
check(rollback.report.updatedLibraries.filter { $0.hasPrefix("gamedir:") }.isEmpty, "result reports no gamedir update")
check(rollback.report.restoredLibraries == ["gamedir:valve/cl_dlls/client_arm64.dylib"], "result reports the restore")

print(failures.isEmpty ? "E2E RESULT: PASS" : "E2E RESULT: FAIL (\(failures.count))")
exit(failures.isEmpty ? 0 : 1)

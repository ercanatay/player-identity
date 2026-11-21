import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import PlayerIdentity

// MARK: - v2.26 engine install test doubles
//
// Everything runs in a temporary folder: a fake `Applications/Xash3D-FWGS.app` with the real bundle topology
// (`Contents/MacOS/{modules, cl_dlls, dlls, SDL2.framework}`), a fake home with identity files and a fake game data
// root. No network, no real `/Applications`, no real game data.

/// Release JSON in the shape of the GitHub API.
enum EngineReleaseFixture {
    static let commit = "cdcb29aa86a5ab16154622e862dd05c62b7561fc"

    static func asset(name: String = EngineArchitecture.arm64.assetName, size: Any = Int64(1234),
                      digest: Any? = "sha256:" + String(repeating: "a", count: 64),
                      url: String? = nil) -> [String: Any] {
        var asset: [String: Any] = ["name": name, "size": size,
                                    "browser_download_url": url ?? EngineReleaseSource.downloadURL(for: name).absoluteString]
        if let digest { asset["digest"] = digest }
        return asset
    }

    /// `nil` values leave the key out.
    static func json(assets: [[String: Any]], tag: String = "continuous",
                     html: String = EngineReleaseSource.releasePageURL.absoluteString,
                     commitish: Any? = commit, prerelease: Any? = true, draft: Any? = false) -> Data {
        var object: [String: Any] = ["tag_name": tag, "html_url": html, "assets": assets]
        if let commitish { object["target_commitish"] = commitish }
        if let prerelease { object["prerelease"] = prerelease }
        if let draft { object["draft"] = draft }
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

final class FakeEngineMetadata: EngineReleaseMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var data: Data
    var hangs = false

    init(data: Data) { self.data = data }

    var calls: Int { lock.withLock { count } }

    func fetchReleaseJSON() async throws -> Data {
        lock.withLock { count += 1 }
        if hangs { while true { try await Task.sleep(for: .seconds(3600)) } }
        return data
    }
}

final class FakeEngineDownloader: EngineAssetDownloading, @unchecked Sendable {
    enum Mode {
        case data(Data)
        case hang
        case fail
    }

    private let lock = NSLock()
    private var mode: Mode
    private var urls: [URL] = []
    private var didStart = false

    init(_ mode: Mode) { self.mode = mode }

    var calls: [URL] { lock.withLock { urls } }
    var started: Bool { lock.withLock { didStart } }

    func setMode(_ mode: Mode) { lock.withLock { self.mode = mode } }

    func download(_ url: URL, to destination: URL, maxBytes: Int64,
                  progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let mode = lock.withLock { () -> Mode in
            urls.append(url)
            didStart = true
            return self.mode
        }
        switch mode {
        case .fail:
            throw EngineInstallFailure.downloadFailed
        case .hang:
            FileManager.default.createFile(atPath: destination.path, contents: Data("partial".utf8))
            while true { try await Task.sleep(for: .seconds(3600)) }
        case .data(let data):
            // Like the real downloader: never more than `maxBytes` on disk.
            let kept = data.prefix(Int(min(Int64(data.count), maxBytes)))
            guard FileManager.default.createFile(atPath: destination.path, contents: kept,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw EngineInstallFailure.downloadFailed
            }
            await progress(Int64(kept.count))
            if Int64(data.count) > maxBytes { throw EngineInstallFailure.sizeTooLarge }
        }
    }
}

/// Lists the package from memory and "extracts" it by writing the files; records the hash of the archive bytes it
/// was given for every pass (proves list and extract use the same verified bytes).
final class FakeEngineArchive: EngineArchiveHandling, @unchecked Sendable {
    private let lock = NSLock()
    var package: [String: Data]
    var entriesOverride: [EngineArchiveEntry]?
    /// Written on extraction although not listed.
    var extraOnExtract: [String: Data] = [:]
    /// Listed but not written.
    var skippedOnExtract: Set<String> = []
    /// Written with other bytes than listed.
    var replacedOnExtract: [String: Data] = [:]
    var hangsOnList = false
    var hangsOnExtract = false
    var failure: (any Error)?
    /// Runs after listing (e.g. to tamper with the cache file).
    var onList: (() -> Void)?
    private var received: [String] = []
    private var listCount = 0
    private var extractCount = 0

    init(package: [String: Data]) { self.package = package }

    var listCalls: Int { lock.withLock { listCount } }
    var extractCalls: Int { lock.withLock { extractCount } }
    /// SHA-256 of the archive bytes of every call (list, then extract).
    var receivedHashes: [String] { lock.withLock { received } }

    var entries: [EngineArchiveEntry] {
        var folders = Set<String>()
        for path in package.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                folders.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return [EngineArchiveEntry(path: "./", type: .directory)]
            + folders.sorted().map { EngineArchiveEntry(path: "./\($0)/", type: .directory) }
            + package.keys.sorted().map { EngineArchiveEntry(path: "./\($0)", type: .regular) }
    }

    func list(_ archive: Data) async throws -> [EngineArchiveEntry] {
        lock.withLock {
            listCount += 1
            received.append(EngineInstallNaming.sha256Hex(archive))
        }
        if let failure { throw failure }
        if hangsOnList { while true { try await Task.sleep(for: .seconds(3600)) } }
        onList?()
        return entriesOverride ?? entries
    }

    func extract(_ archive: Data, into directory: URL) async throws {
        lock.withLock {
            extractCount += 1
            received.append(EngineInstallNaming.sha256Hex(archive))
        }
        if hangsOnExtract { while true { try await Task.sleep(for: .seconds(3600)) } }
        var all = package.filter { !skippedOnExtract.contains($0.key) }
        all.merge(extraOnExtract) { $1 }
        all.merge(replacedOnExtract) { $1 }
        for (path, data) in all {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let executable = !path.contains("/") || path.hasSuffix("/SDL2") || path.hasSuffix(".dylib")
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        }
    }
}

final class FakeEngineSigner: EngineCodeSigning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var failSign = false
    var failFrameworkSign = false
    var failVerify = false
    /// Fails `verify` only for this exact path (e.g. the installed target).
    var failVerifyPath: String?
    /// Simulates what ad-hoc signing rewrites: the main executable and the framework binary.
    var rewritesSignedFiles = true
    /// Simulates a `--deep` signer that also rewrites nested libraries (must be caught as mixed build).
    var rewritesNestedLibraries = false

    var calls: [String] { lock.withLock { log } }

    func signFramework(_ framework: URL) async throws {
        lock.withLock { log.append("framework:" + framework.path) }
        if failFrameworkSign { throw EngineToolError(tool: "codesign", category: .signatureInvalid, exitStatus: 1) }
        if rewritesSignedFiles { try append(framework.appendingPathComponent("Versions/A/SDL2")) }
    }

    func signApp(_ app: URL) async throws {
        lock.withLock { log.append("app:" + app.path) }
        if failSign { throw EngineToolError(tool: "codesign", category: .signatureInvalid, exitStatus: 1) }
        if rewritesSignedFiles { try append(app.appendingPathComponent("Contents/MacOS/xash3d")) }
        if rewritesNestedLibraries { try append(app.appendingPathComponent("Contents/MacOS/cl_dlls/client_arm64.dylib")) }
    }

    /// Runs during every `verify` (e.g. to move the clock past the deadline).
    var onVerify: ((URL) -> Void)?

    func verify(_ app: URL) async throws {
        lock.withLock { log.append("verify:" + app.path) }
        onVerify?(app)
        if failVerify || app.path == failVerifyPath {
            throw EngineToolError(tool: "codesign", category: .signatureInvalid, exitStatus: 1)
        }
    }

    private func append(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+sig".utf8))
        try handle.close()
    }
}

/// Wall clock that tests can move; a sleep returns at once only for the listed limits (others wait until cancelled).
final class FakeEngineClock: EngineInstallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    let date = Date(timeIntervalSince1970: 1_795_000_000)
    var expiring: Set<Double> = []

    func advance(by seconds: TimeInterval) { lock.withLock { offset += seconds } }

    func now() -> Date { date.addingTimeInterval(lock.withLock { offset }) }

    func sleep(seconds: Double) async throws {
        if expiring.contains(seconds) { return }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// Answers the given process states in order (the last one repeats).
final class SequencedEngineDetector: GameProcessDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [EngineProcessState]
    private var count = 0
    /// Runs before answering check number `n` (1-based), e.g. to change files right before the swap.
    var onCheck: ((Int) -> Void)?

    init(_ states: [EngineProcessState] = [.notRunning]) { self.states = states }

    var checks: Int { lock.withLock { count } }

    func isGameRunning() -> Bool { engineProcessState() == .running }

    func engineProcessState() -> EngineProcessState {
        let number = lock.withLock { () -> Int in
            count += 1
            return count
        }
        onCheck?(number)
        return lock.withLock { states.count > 1 ? states.removeFirst() : states[0] }
    }
}

/// Real file operations with recorded mutations and reads, and injectable failures or side effects.
final class RecordingEngineFiles: EngineFileOperating, @unchecked Sendable {
    struct Mutation: Equatable {
        let operation: String
        let path: String
    }

    private let real = LocalEngineFileOperations()
    private let lock = NSLock()
    private var recorded: [Mutation] = []
    private var readPaths: [String] = []
    private var failHook: ((String, URL) -> EngineFileError?)?
    private var writableHook: ((URL) -> Bool?)?
    private var afterCopyHook: ((URL) -> Void)?
    private var swapSupport: ((URL) -> Bool?)?
    private var probeResult: Bool?
    private var lockOverride: ((URL) -> (any Error)?)?

    var mutations: [Mutation] { lock.withLock { recorded } }
    /// Paths read whole with `readRegularFile` (the archive).
    var wholeFileReads: [String] { lock.withLock { readPaths } }

    /// `(operation, destination) → error`; may also cause side effects (operation: `mkdir`, `copyItem`,
    /// `copyFile`, `writeFile`, `move`, `swap`, `remove`, `symlink`, `chmod`, `xattr`).
    var fail: ((String, URL) -> EngineFileError?)? {
        get { lock.withLock { failHook } }
        set { lock.withLock { failHook = newValue } }
    }

    var writable: ((URL) -> Bool?)? {
        get { lock.withLock { writableHook } }
        set { lock.withLock { writableHook = newValue } }
    }

    /// Runs after a successful `copyFile` (e.g. to corrupt a staged file).
    var afterCopy: ((URL) -> Void)? {
        get { lock.withLock { afterCopyHook } }
        set { lock.withLock { afterCopyHook = newValue } }
    }

    /// Overrides the volume capability answer for all folders (`nil`: real).
    var atomicSwapSupported: Bool? {
        get { nil }
        set { lock.withLock { swapSupport = newValue.map { value in { _ in value } } } }
    }

    /// Overrides the volume capability answer per folder (`nil` result: real).
    var atomicSwapSupport: ((URL) -> Bool?)? {
        get { lock.withLock { swapSupport } }
        set { lock.withLock { swapSupport = newValue } }
    }

    /// Overrides the swap probe result (`nil`: real probe).
    var swapProbeResult: Bool? {
        get { lock.withLock { probeResult } }
        set { lock.withLock { probeResult = newValue } }
    }

    /// Makes lock acquisition throw (`nil` result: real `flock`).
    var lockFailure: ((URL) -> (any Error)?)? {
        get { lock.withLock { lockOverride } }
        set { lock.withLock { lockOverride = newValue } }
    }

    private func mutate(_ operation: String, _ url: URL, _ extra: URL? = nil) throws {
        lock.withLock {
            recorded.append(Mutation(operation: operation, path: url.path))
            if let extra { recorded.append(Mutation(operation: operation, path: extra.path)) }
        }
        if let error = fail?(operation, url) { throw error }
    }

    func kind(_ url: URL) -> ProbedItemKind { real.kind(url) }
    func size(_ url: URL) throws -> UInt64 { try real.size(url) }
    func permissions(_ url: URL) -> UInt32? { real.permissions(url) }
    func read(_ url: URL, offset: UInt64, length: Int) throws -> Data { try real.read(url, offset: offset, length: length) }
    func resolvedPath(_ url: URL) -> String { real.resolvedPath(url) }
    func linkCount(_ url: URL) -> Int? { real.linkCount(url) }
    func isWritable(_ url: URL) -> Bool { writable?(url) ?? real.isWritable(url) }
    func supportsAtomicSwap(_ url: URL) -> Bool { atomicSwapSupport?(url) ?? real.supportsAtomicSwap(url) }
    func volumeID(_ url: URL) -> UInt64? { real.volumeID(url) }

    func probeAtomicSwap(in folder: URL) -> Bool {
        lock.withLock { recorded.append(Mutation(operation: "probe", path: folder.path)) }
        return swapProbeResult ?? real.probeAtomicSwap(in: folder)
    }

    func acquireExclusiveLock(_ url: URL) throws -> EngineFileLock {
        try mutate("lock", url)
        if let error = lockFailure?(url) { throw error }
        return try real.acquireExclusiveLock(url)
    }
    func contents(_ url: URL) throws -> [String] { try real.contents(url) }
    func symbolicLinkTarget(_ url: URL) -> String? { real.symbolicLinkTarget(url) }
    func sha256(_ url: URL) throws -> String { try real.sha256(url) }

    func readRegularFile(_ url: URL, maxBytes: Int64) throws -> Data {
        lock.withLock { readPaths.append(url.path) }
        return try real.readRegularFile(url, maxBytes: maxBytes)
    }

    func createDirectory(_ url: URL, permissions: UInt16) throws {
        try mutate("mkdir", url)
        try real.createDirectory(url, permissions: permissions)
    }

    func copyItem(_ source: URL, to destination: URL) throws {
        try mutate("copyItem", destination)
        try real.copyItem(source, to: destination)
    }

    func copyFile(_ source: URL, to destination: URL, permissions: UInt16) throws {
        try mutate("copyFile", destination)
        try real.copyFile(source, to: destination, permissions: permissions)
        afterCopy?(destination)
    }

    func writeFile(_ data: Data, to destination: URL, permissions: UInt16) throws {
        try mutate("writeFile", destination)
        try real.writeFile(data, to: destination, permissions: permissions)
    }

    func moveItem(_ source: URL, to destination: URL) throws {
        try mutate("move", destination, source)
        try real.moveItem(source, to: destination)
    }

    func swapItems(_ first: URL, _ second: URL) throws {
        try mutate("swap", second, first)
        try real.swapItems(first, second)
    }

    func removeItem(_ url: URL) throws {
        try mutate("remove", url)
        try real.removeItem(url)
    }

    func createSymbolicLink(_ url: URL, target: String) throws {
        try mutate("symlink", url)
        try real.createSymbolicLink(url, target: target)
    }

    func setPermissions(_ url: URL, _ mode: UInt16) throws {
        try mutate("chmod", url)
        try real.setPermissions(url, mode)
    }

    func removeExtendedAttribute(_ name: String, at url: URL) throws {
        try mutate("xattr", url)
        try real.removeExtendedAttribute(name, at: url)
    }
}

/// Records every progress phase and checks each change against the state machine (from `confirm`).
final class EnginePhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [EngineInstallProgress] = []

    var events: [EngineInstallProgress] { lock.withLock { recorded } }
    var phases: [EngineInstallPhase] {
        events.map(\.phase).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }

    func record(_ event: EngineInstallProgress) { lock.withLock { recorded.append(event) } }

    var invalidTransitions: [String] {
        var invalid: [String] = []
        var previous = EngineInstallPhase.confirm
        for phase in phases {
            if !EngineInstallStateMachine.canTransition(from: previous, to: phase) {
                invalid.append("\(previous.rawValue)->\(phase.rawValue)")
            }
            previous = phase
        }
        return invalid
    }
}

// MARK: Fixture

final class EngineInstallFixture {
    static let rawID: UInt64 = 0x1122_3344_5566_7788

    let temp: TempDirectory
    let root: URL
    let home: URL
    let applications: URL
    let target: URL
    let dataRoot: URL
    let paths: AppPaths
    var gamedir = "valve"
    var architecture = EngineArchitecture.arm64
    var amd64Enabled = false

    let archiveBytes = Data("fake-xz-archive".utf8)
    let metadata: FakeEngineMetadata
    let downloader: FakeEngineDownloader
    let archive: FakeEngineArchive
    let signer = FakeEngineSigner()
    let files = RecordingEngineFiles()
    let clock = FakeEngineClock()
    var detector = SequencedEngineDetector()
    let recorder = EnginePhaseRecorder()

    static let headers = ["SDL.h", "SDL_video.h", "begin_code.h", "close_code.h"]

    /// The real upstream layout (E19.1): root modules and extras, `valve/` libraries and extras, and SDL2 with
    /// `Versions/A` plus the plain-folder copies at the root and in `Versions/Current`.
    static func upstreamPackage(architecture: EngineArchitecture = .arm64) -> [String: Data] {
        var package: [String: Data] = [:]
        for module in EngineArchiveLayout.requiredModules { package[module] = Data("new-\(module)".utf8) }
        for extra in EngineArchiveLayout.rootExtras { package[extra] = Data("extra-\(extra)".utf8) }
        var version: [String: Data] = [
            "SDL2": Data("new-sdl".utf8),
            "Resources/Info.plist": Data("new-sdl-plist".utf8),
            "Resources/License.txt": Data("license".utf8),
            "Resources/default.metallib": Data("metallib".utf8),
            "Resources/CMake/sdl2-config.cmake": Data("cmake".utf8),
        ]
        for header in headers { version["Headers/" + header] = Data("header-\(header)".utf8) }
        for (member, data) in version {
            package["SDL2.framework/Versions/A/" + member] = data
            package["SDL2.framework/Versions/Current/" + member] = data
            package["SDL2.framework/" + member] = data
        }
        package["SDL2.framework/Versions/A/_CodeSignature/CodeResources"] = Data("seal".utf8)
        package["SDL2.framework/Versions/Current/_CodeSignature/CodeResources"] = Data("seal".utf8)
        for library in EngineArchiveLayout.gameLibraries(architecture: architecture) {
            package[library.source] = Data("new-\((library.source as NSString).lastPathComponent)".utf8)
        }
        return package
    }

    init() throws {
        temp = try TempDirectory()
        // Physical path (no `/var` alias), like `/Applications`.
        root = URL(fileURLWithPath: LocalFileProbe.physicalPath(temp.url.path), isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        target = applications.appendingPathComponent("Xash3D-FWGS.app", isDirectory: true)
        paths = AppPaths(home: home)
        dataRoot = paths.defaultDataRoot
        metadata = FakeEngineMetadata(data: Data())
        downloader = FakeEngineDownloader(.data(archiveBytes))
        archive = FakeEngineArchive(package: Self.upstreamPackage())
        try buildOldApp()
        try buildGameData()
        metadata.data = EngineReleaseFixture.json(assets: [EngineReleaseFixture.asset(
            size: Int64(archiveBytes.count), digest: "sha256:" + Self.sha(archiveBytes))])
    }

    static func sha(_ data: Data) -> String { CIDCalculator.hexLower(Array(SHA256.hash(data: data))) }

    func write(_ url: URL, _ text: String, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    var contents: URL { target.appendingPathComponent("Contents") }
    var bundleClient: URL { contents.appendingPathComponent("MacOS/cl_dlls/client_arm64.dylib") }
    var bundleServer: URL { contents.appendingPathComponent("MacOS/dlls/hl_arm64.dylib") }

    /// The real installed topology (E19.3).
    private func buildOldApp() throws {
        try write(contents.appendingPathComponent("Info.plist"), """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>xash3d</string>\
        <key>CFBundleIdentifier</key><string>su.xash.Xash3D</string>\
        <key>CFBundleShortVersionString</key><string>0.20</string></dict></plist>
        """)
        for module in EngineArchiveLayout.knownModules {
            try write(contents.appendingPathComponent("MacOS/\(module)"), "old-\(module)", mode: 0o755)
        }
        try write(contents.appendingPathComponent("MacOS/helper.sh"), "unknown-helper", mode: 0o755)
        try write(bundleClient, "old-bundle-client", mode: 0o755)
        try write(contents.appendingPathComponent("MacOS/cl_dlls/client_amd64.dylib"), "old-bundle-client-amd64", mode: 0o755)
        try write(bundleServer, "old-bundle-hl", mode: 0o755)
        try write(contents.appendingPathComponent("MacOS/dlls/opfor_arm64.dylib"), "old-opfor", mode: 0o755)
        try write(contents.appendingPathComponent("Frameworks/libSDL2-2.0.0.dylib"), "old-libsdl", mode: 0o755)
        try write(contents.appendingPathComponent("Resources/xash3d-fwgs.icns"), "icon")
        try write(contents.appendingPathComponent("Resources/valve/extras.pk3"), "old-extras")
        let framework = contents.appendingPathComponent("MacOS/SDL2.framework")
        try write(framework.appendingPathComponent("Versions/A/SDL2"), "old-sdl", mode: 0o755)
        try write(framework.appendingPathComponent("Versions/A/Headers/SDL.h"), "old-header")
        try write(framework.appendingPathComponent("Versions/A/Resources/Info.plist"), "old-sdl-plist")
        for link in EngineSDL2Framework.links {
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent(link.path).path,
                                                       withDestinationPath: link.target)
        }
    }

    var gamedirURL: URL { dataRoot.appendingPathComponent(gamedir, isDirectory: true) }
    var clientLib: URL { dataRoot.appendingPathComponent("valve/cl_dlls/client_arm64.dylib") }
    var serverLib: URL { dataRoot.appendingPathComponent("valve/dlls/hl_arm64.dylib") }
    var globalIdentity: URL { home.appendingPathComponent(".config/.xash_id") }
    var gamedirIdentity: URL { dataRoot.appendingPathComponent("valve/.xash_id") }
    var identityPaths: [URL] {
        [home.appendingPathComponent(".config/.xash_id"), home.appendingPathComponent(".local/.xash_id"),
         home.appendingPathComponent(".xash_id"), dataRoot.appendingPathComponent("\(gamedir)/.xash_id")]
    }

    private func buildGameData() throws {
        // The app's own data folder exists already (the engine folders inside it do not).
        try FileManager.default.createDirectory(at: paths.snapshotFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try write(clientLib, "old-game-client")
        try write(serverLib, "old-game-hl")
        try write(dataRoot.appendingPathComponent("valve/config.cfg"), "name \"player\"")
        try write(dataRoot.appendingPathComponent("valve/maps/c1a0.bsp"), "map-data")
        try write(globalIdentity, HexID.format(Self.rawID ^ IdentityLocation.homeMask) + "\n", mode: 0o600)
        try write(gamedirIdentity, HexID.format(Self.rawID ^ IdentityLocation.gamedirMask) + "\n", mode: 0o600)
        try write(home.appendingPathComponent("Documents/notes.txt"), "user-file")
    }

    var environment: EngineInstallEnvironment {
        EngineInstallEnvironment(targetApp: target, dataRoot: dataRoot, gamedir: gamedir, home: home, paths: paths,
                                 architecture: architecture, amd64Enabled: amd64Enabled)
    }

    var installer: EngineInstaller {
        EngineInstaller(environment: environment, metadata: metadata, downloader: downloader, archive: archive,
                        signer: signer, files: files, detector: detector, clock: clock)
    }

    func release(size: Int64? = nil, sha: String? = nil, architecture: EngineArchitecture? = nil) -> EngineRelease {
        let arch = architecture ?? self.architecture
        return EngineRelease(tag: "continuous", prerelease: true, htmlURL: EngineReleaseSource.releasePageURL,
                             commitSHA: EngineReleaseFixture.commit, architecture: arch,
                             asset: EngineReleaseAsset(name: arch.assetName,
                                                       downloadURL: EngineReleaseSource.downloadURL(for: arch.assetName),
                                                       size: size ?? Int64(archiveBytes.count),
                                                       sha256: sha ?? Self.sha(archiveBytes)))
    }

    func install(_ release: EngineRelease? = nil, accepted: Bool = true,
                 cidBefore: String? = "abcd…0123") async -> EngineInstallResult {
        let recorder = self.recorder
        return await installer.install(release ?? self.release(),
                                       confirmation: EngineInstallConfirmation(acceptedCIDWarning: accepted,
                                                                               cidBefore: cidBefore)) {
            recorder.record($0)
        }
    }

    // MARK: Inspection

    func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    /// Relative path → checksum / link target / folder marker of every item below `url` (links not followed).
    func snapshot(_ url: URL, excluding: [URL] = []) throws -> [String: String] {
        var result: [String: String] = [:]
        let local = LocalEngineFileOperations()
        guard local.kind(url) == .directory else { return result }
        for item in try EngineTree.walk(url, files: local) {
            let itemURL = url.appendingPathComponent(item.path)
            if excluding.contains(where: { EnginePaths.isInside(itemURL, $0) }) { continue }
            switch item.kind {
            case .regularFile: result[item.path] = try local.sha256(itemURL)
            case .symbolicLink: result[item.path] = "link:" + (local.symbolicLinkTarget(itemURL) ?? "?")
            default: result[item.path] = "dir"
            }
        }
        return result
    }

    func appManifest() throws -> EngineTreeManifest { try EngineTree.manifest(target, files: LocalEngineFileOperations()) }

    func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Hidden temporary siblings left next to the app or the libraries.
    func temporarySiblings() throws -> [String] {
        try [applications, clientLib.deletingLastPathComponent(), serverLib.deletingLastPathComponent()]
            .filter { LocalEngineFileOperations().kind($0) == .directory }
            .flatMap { folder in
                try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".pi-") }
            }
    }

    /// Backup items (the lock file is not a backup).
    func backupEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.engineBackupsDirectory.path)) ?? [])
            .filter { $0 != ".install.lock" }
    }

    var lockFile: URL { paths.engineBackupsDirectory.appendingPathComponent(".install.lock") }

    func runDirectories() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.engineUpdatesDirectory.path)) ?? [])
            .filter { $0.hasPrefix("run-") || $0.contains(".partial-") }
    }
}

extension MacIdentityReport {
    static func fixture(support: StaticSupport, raw: RawIdentityState?, process: EngineProcessState = .notRunning)
        -> MacIdentityReport {
        let decision = MacIdentityDecision.decide(process: process, support: support, raw: raw)
        return MacIdentityReport(state: decision.state, finding: decision.finding, action: decision.action,
                                 staticSupport: process == .notRunning ? support : .unknown,
                                 evidence: CapabilityEvidence(), capabilityFailure: support == .unknown ? .unreadable : nil,
                                 rawState: raw, cidMasked: nil, engineApp: EnginePaths.defaultApp,
                                 engineHashShort: nil, engineVersion: nil, processState: process,
                                 generatedAt: Date(timeIntervalSince1970: 0))
    }
}

import Darwin
import Foundation

// MARK: - v2.26 engine install: orchestration (no UI)
//
// download → digest → immutable archive bytes → pre-scan + extraction (same bytes) → staged app (skeleton + exact
// upstream engine set + SDL2 from `Versions/A` + bundle game libraries) → pre-sign hashes → sign + strict verify →
// post-sign hashes → permission/swap/process preflight → full backup with a checksum manifest → conflict check →
// atomic sibling swap (`RENAME_SWAP`, process re-checked right before it) → game libraries (`RENAME_SWAP`) →
// verification. A failure before the first change of the target is `failed` (this run's backup is discarded);
// after it, the app and libraries are put back and verified against the backup. The identity files are only read and
// copied into the backup.
//
// Concurrency and threat model (E21.9): a target-specific `flock` serialises installers; every write, rename and
// delete re-checks that no component of its path is a link; each library is re-verified right before it is changed;
// swaps are descriptor-relative (`renameatx_np` with parent folders opened `O_DIRECTORY | O_NOFOLLOW`) with no
// rename fallback; staging is private (`0700`). This keeps the installer from writing or deleting outside its own
// staging, cache and backup folders and the exact targets. It is not a defence against a malicious process of the
// same user that ignores the lock and swaps paths between a check and the following call: the install is not
// claimed to be race-free against such a process.

/// Where the install reads and writes.
struct EngineInstallEnvironment: Sendable, Equatable {
    /// The engine app to replace (default `/Applications/Xash3D-FWGS.app`).
    let targetApp: URL
    /// The game data root (`~/Library/Application Support/Xash3D FWGS`).
    let dataRoot: URL
    /// The active game folder (default `valve`).
    let gamedir: String
    let home: URL
    /// Cache, staging and backup locations (`engine-updates`, `engine-backups`).
    let paths: AppPaths
    let architecture: EngineArchitecture
    var amd64Enabled = EngineInstallCapability.amd64Enabled

    var gamedirURL: URL { dataRoot.appendingPathComponent(gamedir, isDirectory: true) }
}

/// AC-E19 time limits in seconds.
struct EngineInstallLimits: Sendable, Equatable {
    var metadata: Double = 30
    var download: Double = 600
    var extraction: Double = 120
    /// Backups, sibling copy, game libraries and verification (AC-E43a/b).
    var install: Double = 300
}

private enum EngineTimeoutRace<T: Sendable>: Sendable {
    case value(T)
    case expired
}

/// Runs `operation` against a clock-driven limit; the limit wins with `EngineInstallFailure.timeout(stage)` and the
/// operation is cancelled (and, for a process, reaped before this returns).
func withEngineTimeout<T: Sendable>(_ seconds: Double, stage: EngineInstallTimedStage, clock: any EngineInstallClock,
                                    operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: EngineTimeoutRace<T>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try await clock.sleep(seconds: seconds)
            return .expired
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw EngineInstallFailure.timeout(stage) }
        switch first {
        case .value(let value): return value
        case .expired: throw EngineInstallFailure.timeout(stage)
        }
    }
}

struct EngineInstaller: Sendable {
    let environment: EngineInstallEnvironment
    let metadata: any EngineReleaseMetadataProviding
    let downloader: any EngineAssetDownloading
    let archive: any EngineArchiveHandling
    let signer: any EngineCodeSigning
    let files: any EngineFileOperating
    let detector: any GameProcessDetecting
    let clock: any EngineInstallClock
    var limits = EngineInstallLimits()

    /// Production wiring (GitHub API, URLSession, `/usr/bin/tar`, `/usr/bin/codesign`, Darwin file calls).
    static func live(environment: EngineInstallEnvironment,
                     detector: any GameProcessDetecting = SystemGameProcessDetector(),
                     files: any EngineFileOperating = LocalEngineFileOperations()) -> EngineInstaller {
        let runner = ProcessEngineCommandRunner()
        return EngineInstaller(environment: environment, metadata: GitHubEngineReleaseMetadataProvider(),
                               downloader: URLSessionEngineAssetDownloader(), archive: TarEngineArchive(runner: runner),
                               signer: ProcessEngineCodeSigner(runner: runner), files: files,
                               detector: detector, clock: SystemEngineInstallClock())
    }

    /// The backup inventory of this environment (AC-E40).
    var backupStore: EngineBackupStore {
        EngineBackupStore(root: environment.paths.engineBackupsDirectory, files: files)
    }

    /// `checking`: architecture gate, then the release API (only network call before confirmation).
    func fetchRelease() async -> Result<EngineRelease, EngineInstallFailure> {
        if let failure = EngineInstallCapability.check(environment.architecture,
                                                       amd64Enabled: environment.amd64Enabled) {
            return .failure(failure)
        }
        let metadata = self.metadata
        do {
            let data = try await withEngineTimeout(limits.metadata, stage: .metadata, clock: clock) {
                try await metadata.fetchReleaseJSON()
            }
            return EngineReleaseParser.parse(data, architecture: environment.architecture)
        } catch let failure as EngineInstallFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.metadataUnavailable)
        }
    }

    /// The whole install after confirmation. Never throws: every path ends in one outcome with a report and log.
    func install(_ release: EngineRelease, confirmation: EngineInstallConfirmation,
                 progress: @escaping @Sendable (EngineInstallProgress) async -> Void = { _ in })
        async -> EngineInstallResult {
        let run = EngineInstallRun(installer: self, release: release, confirmation: confirmation, progress: progress)
        return await run.execute()
    }
}

// MARK: SDL2 framework (AC-E28)

enum EngineSDL2Framework {
    /// Relative links of a standard framework, in creation order (`Versions/Current` first).
    static let links: [(path: String, target: String)] = [
        ("Versions/Current", "A"),
        ("SDL2", "Versions/Current/SDL2"),
        ("Headers", "Versions/Current/Headers"),
        ("Resources", "Versions/Current/Resources"),
    ]

    /// Rebuilds the standard link structure in place. Correct links are kept, anything else at a link position is
    /// replaced, so running it twice yields the same tree. A missing link target is `sdl2Reconstruction`.
    /// `check` runs before every remove and link (the path guard of the caller, AC-E94).
    static func reconstruct(_ framework: URL, files: any EngineFileOperating,
                            check: (URL) throws -> Void = { _ in }) throws {
        let version = framework.appendingPathComponent("Versions/A", isDirectory: true)
        guard files.kind(framework.appendingPathComponent("Versions")) == .directory,
              files.kind(version) == .directory,
              files.kind(version.appendingPathComponent("SDL2")) == .regularFile,
              files.kind(version.appendingPathComponent("Headers")) == .directory,
              files.kind(version.appendingPathComponent("Resources")) == .directory else {
            throw EngineInstallFailure.sdl2Reconstruction
        }
        do {
            for link in links {
                let url = framework.appendingPathComponent(link.path)
                if files.kind(url) == .symbolicLink, files.symbolicLinkTarget(url) == link.target { continue }
                if files.kind(url) != .missing {
                    try check(url)
                    try files.removeItem(url)
                }
                try check(url)
                try files.createSymbolicLink(url, target: link.target)
            }
        } catch let failure as EngineInstallFailure {
            throw failure
        } catch {
            throw EngineInstallFailure.sdl2Reconstruction
        }
        let binary = files.resolvedPath(version.appendingPathComponent("SDL2"))
        guard files.resolvedPath(framework.appendingPathComponent("SDL2")) == binary else {
            throw EngineInstallFailure.sdl2Reconstruction
        }
    }
}

// MARK: Tree helpers

enum EngineTree {
    struct Item: Sendable, Equatable {
        let path: String
        let kind: ProbedItemKind
    }

    /// Every item below `root` (relative paths, sorted), links not followed.
    static func walk(_ root: URL, files: any EngineFileOperating) throws -> [Item] {
        var items: [Item] = []
        var pending: [String] = [""]
        while let relative = pending.popLast() {
            let folder = relative.isEmpty ? root : root.appendingPathComponent(relative)
            for name in try files.contents(folder) {
                let path = relative.isEmpty ? name : relative + "/" + name
                let kind = files.kind(root.appendingPathComponent(path))
                items.append(Item(path: path, kind: kind))
                guard items.count <= EngineTreeManifest.maxEntries else { throw EngineFileError.tooLarge }
                if kind == .directory { pending.append(path) }
            }
        }
        return items.sorted { $0.path < $1.path }
    }

    static func manifest(_ root: URL, files: any EngineFileOperating) throws -> EngineTreeManifest {
        var entries: [EngineTreeManifest.Entry] = []
        for item in try walk(root, files: files) {
            let url = root.appendingPathComponent(item.path)
            let mode = files.permissions(url).map { UInt16($0 & 0o7777) }
            switch item.kind {
            case .regularFile:
                entries.append(.init(path: item.path, kind: "file", sha256: try files.sha256(url), mode: mode,
                                     target: nil))
            case .directory:
                entries.append(.init(path: item.path, kind: "dir", sha256: nil, mode: mode, target: nil))
            case .symbolicLink:
                entries.append(.init(path: item.path, kind: "link", sha256: nil, mode: nil,
                                     target: files.symbolicLinkTarget(url)))
            case .missing, .other, .unreadable:
                throw EngineFileError.notRegularFile
            }
        }
        return EngineTreeManifest(entries: entries)
    }
}

// MARK: Path guard (AC-E70 – AC-E72)

enum EnginePathGuard {
    /// Bundle folders that must never be links (AC-E70a) with their roles.
    static let bundleFolders: [(path: String, role: String)] = [
        ("Contents", "contents"), ("Contents/MacOS", "macos"), ("Contents/MacOS/cl_dlls", "cl_dlls"),
        ("Contents/MacOS/dlls", "dlls"), ("Contents/Frameworks", "frameworks"), ("Contents/Resources", "resources"),
        ("Contents/Resources/valve", "resourcesValve"), (EngineArchiveLayout.bundleFramework, "sdl2Framework"),
    ]

    static func isPhysical(_ url: URL, files: any EngineFileOperating) -> Bool {
        EnginePaths.systemCanonical(files.resolvedPath(url)) == EnginePaths.systemCanonical(url.standardized.path)
    }

    /// Every component from `root` down to the parent of `url` is a real folder (no link), the final item is missing,
    /// a regular file or a folder (never a link), and the physical parent stays inside the physical root.
    static func check(_ url: URL, root: URL, role: String, files: any EngineFileOperating) throws {
        let rootPath = root.standardized.path
        let path = url.standardized.path
        guard path != rootPath, EnginePaths.isInside(path: path, root: rootPath), files.kind(root) == .directory,
              isPhysical(root, files: files) else {
            throw EngineInstallFailure.unsafePath(role)
        }
        let components = path.dropFirst(rootPath.count).split(separator: "/").map(String.init)
        var current = root
        for component in components.dropLast() {
            current = current.appendingPathComponent(component)
            guard files.kind(current) == .directory else { throw EngineInstallFailure.unsafePath(role) }
        }
        switch files.kind(url) {
        case .missing, .regularFile, .directory: break
        default: throw EngineInstallFailure.unsafePath(role)
        }
        let physicalParent = EnginePaths.systemCanonical(files.resolvedPath(url.deletingLastPathComponent()))
        let physicalRoot = EnginePaths.systemCanonical(files.resolvedPath(root))
        guard EnginePaths.isInside(path: physicalParent, root: physicalRoot) else {
            throw EngineInstallFailure.unsafePath(role)
        }
    }

    /// AC-E70a: no bundle folder, module or bundle library of `app` is a link.
    static func checkBundle(_ app: URL, architecture: EngineArchitecture, files: any EngineFileOperating) throws {
        for folder in bundleFolders {
            switch files.kind(app.appendingPathComponent(folder.path)) {
            case .missing, .directory: continue
            default: throw EngineInstallFailure.unsafePath(folder.role)
            }
        }
        let items = EngineArchiveLayout.knownModules.map { ("Contents/MacOS/" + $0, "module") }
            + EngineArchiveLayout.gameLibraries(architecture: architecture).map { ($0.bundle, "bundleLib") }
        for (path, role) in items {
            switch files.kind(app.appendingPathComponent(path)) {
            case .missing, .regularFile: continue
            default: throw EngineInstallFailure.unsafePath(role)
            }
        }
    }
}

// MARK: One run

/// State of one install. Used only inside `EngineInstaller.install` (never shared across tasks).
final class EngineInstallRun {
    private struct LibraryTarget {
        let library: EngineGameLibrary
        let target: URL
        /// `gamedir:<gamedir>/<relative>`.
        let label: String
    }

    private struct Placed {
        let staged: URL
        /// Package path of the upstream source.
        let source: String
        let label: String
        /// Signing rewrites this file (main executable, framework binary, `_CodeSignature`) (AC-E46c).
        let signedMayChange: Bool
    }

    private typealias IdentityState = (state: EngineIdentityFileState, hash: String?)

    private let installer: EngineInstaller
    private let release: EngineRelease
    private let confirmation: EngineInstallConfirmation
    private let progress: @Sendable (EngineInstallProgress) async -> Void
    private var files: any EngineFileOperating { installer.files }
    private var environment: EngineInstallEnvironment { installer.environment }
    private var targetParent: URL { environment.targetApp.deletingLastPathComponent() }
    private var appDataRoot: URL { environment.paths.snapshotFile.deletingLastPathComponent() }

    private var log = EngineInstallLog()
    private var report = EngineInstallReport()
    private let runID = String(UUID().uuidString.prefix(8)).lowercased()
    private var temporaries: [URL] = []
    private var workDirectory: URL?
    private var extraction: URL?
    private var archivePlan: EngineArchivePlan?
    /// SHA-256 of every extracted file right after extraction (AC-E74).
    private var extractedHashes: [String: String] = [:]
    private var placed: [Placed] = []
    private var stagedApp: URL?
    private var stagedFrameworks: [URL] = []
    private var stagedManifest: EngineTreeManifest?
    private var originalManifest: EngineTreeManifest?
    private var libraryTargets: [LibraryTarget] = []
    private var libraryRecords: [String: EngineFileRecord] = [:]
    /// Runtime-only identity baseline (state + hash per location); never reported (AC-E80, AC-E85).
    private var identityBefore: [IdentityLocation: IdentityState]?
    private var backupItems: [URL] = []
    private var replacedLibraries: [LibraryTarget] = []
    private var oldApp: URL?
    private var swapped = false
    /// The previous app was put back by the rollback.
    private var appRestored = false
    /// `bundle:<path>` of the bundle libraries the staged app carries in the upstream build.
    private var stagedBundleLibraries: [String] = []
    /// The target (app or a game library) was changed (AC-E79).
    private var mutated = false
    private var installDeadline: Date?
    /// The target lock; released at the very end of `finish` (AC-E88a).
    private var installLock: EngineFileLock?
    /// Mode of the target app folder, restored on the copy that is swapped in.
    private var originalAppMode: UInt16 = 0o755

    init(installer: EngineInstaller, release: EngineRelease, confirmation: EngineInstallConfirmation,
         progress: @escaping @Sendable (EngineInstallProgress) async -> Void) {
        self.installer = installer
        self.release = release
        self.confirmation = confirmation
        self.progress = progress
    }

    func execute() async -> EngineInstallResult {
        report.release = release
        report.cidBefore = confirmation.cidBefore
        log.add([(.stage, "start"), (.asset, release.asset.name), (.commit, release.commitSHA),
                 (.digest, release.asset.digest), (.size, String(release.asset.size)),
                 (.cid, confirmation.cidBefore ?? "none")])
        guard confirmation.acceptedCIDWarning else { return await finish(.failed(.notConfirmed)) }
        do {
            if let failure = EngineInstallCapability.check(environment.architecture,
                                                           amd64Enabled: environment.amd64Enabled)
                ?? validateRelease() {
                throw failure
            }
            try validateTarget()
            try acquireLock()
            try probeAtomicSwapVolumes()
        } catch {
            return await finish(.failed(failure(error, fallback: .stagingFailed)))
        }

        // Cancellable part: download, digest, extraction and staging (AC-E7).
        do {
            let archive = try await download()
            try await extract(archive)
            try Task.checkCancellation()
            try buildStagedApp()
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || (error as? EngineInstallFailure) == .cancelled {
                return await finish(.cancelled)
            }
            return await finish(.failed(failure(error, fallback: .stagingFailed)))
        }

        // From here on nothing is cancellable.
        do {
            try await sign()
            await emit(.preflightPermission)
            try planGameLibraries()
            try checkPermissions()
            await emit(.preflightProcess)
            if let failure = processFailure() { throw failure }
        } catch {
            return await finish(.failed(failure(error, fallback: .stagingFailed)))
        }

        await emit(.backingUp)
        installDeadline = installer.clock.now().addingTimeInterval(installer.limits.install)
        do {
            try backup()
        } catch {
            let reason = failure(error, fallback: .backupFailed)
            discardBackup()
            return await finish(.failed(reason))
        }

        await emit(.installing)
        do {
            try await installStaged()
        } catch {
            let reason = failure(error, fallback: .installFailed)
            if mutated { return await rollback(reason) }
            discardTemporaries()
            discardBackup()
            return await finish(.failed(reason))
        }
        report.installedApp = environment.targetApp
        return await finish(.installed)
    }

    // MARK: Validation

    private func validateRelease() -> EngineInstallFailure? {
        let asset = release.asset
        guard release.architecture == environment.architecture,
              asset.name == environment.architecture.assetName else { return .assetNotFound }
        guard release.prerelease, EngineReleaseParser.isHex(release.commitSHA, count: 40) else {
            return .metadataInvalid
        }
        guard asset.size > 0, asset.size <= EngineReleaseSource.maxAssetSize else { return .sizeTooLarge }
        guard EngineReleaseParser.parseDigest(asset.digest) == asset.sha256 else { return .digestInvalid }
        return EngineReleaseSource.checkAssetURL(asset.downloadURL, assetName: asset.name)
    }

    /// The target is a plain `.app` (no link anywhere on its path or in its engine folders) with the `xash3d`
    /// executable, outside the data and identity folders; the game folder is plain and link-free; both volumes can
    /// swap atomically. Read-only: nothing is downloaded or written before this passes.
    private func validateTarget() throws {
        guard EngineInstallNaming.isPlainGamedir(environment.gamedir) else { throw EngineInstallFailure.forbiddenTarget }
        let target = environment.targetApp.standardized
        let roots = EnginePaths.forbiddenRoots(home: environment.home, dataRoot: environment.dataRoot)
        if EnginePaths.isForbidden(target, roots: roots, files: files) { throw EngineInstallFailure.forbiddenTarget }
        guard EnginePathGuard.isPhysical(targetParent, files: files) else { throw EngineInstallFailure.unsafePath("appParent") }
        switch EnginePaths.inspect(target, files: files) {
        case .failure(let error): throw EngineInstallFailure.targetInvalid(error)
        case .success(let bundle):
            guard bundle.executable.lastPathComponent == EngineArchiveLayout.executableName else {
                throw EngineInstallFailure.targetInvalid(.missingExecutable)
            }
        }
        try EnginePathGuard.checkBundle(target, architecture: environment.architecture, files: files)
        try checkGamedirTree()
        // Read-only capability check of every volume a swap may happen on (AC-E39, AC-E96).
        for folder in swapFolders() where !files.supportsAtomicSwap(folder) {
            throw EngineInstallFailure.atomicSwapUnsupported
        }
    }

    /// The target parent and every existing library parent of the active game folder.
    private func swapFolders() -> [URL] {
        let gamedir = environment.gamedirURL
        let libraryParents = EngineArchiveLayout.gameLibraries(architecture: environment.architecture)
            .map { gamedir.appendingPathComponent($0.gamedirRelative).deletingLastPathComponent() }
        return [targetParent] + libraryParents.filter { files.kind($0) == .directory }
    }

    // MARK: Lock (AC-E88, AC-E89)

    /// Takes the target lock before anything is downloaded; held until `finish` (rollback and cleanup included).
    private func acquireLock() throws {
        let root = environment.paths.engineBackupsDirectory
        let url = root.appendingPathComponent(".install.lock", isDirectory: false)
        do {
            try guardWrite(root, root: appDataRoot, role: "backup")
            try files.createPrivateDirectory(root)
            try guardWrite(url, root: root, role: "lock")
        } catch {
            throw EngineInstallFailure.lockUnavailable
        }
        do {
            installLock = try files.acquireExclusiveLock(url)
        } catch EngineLockError.busy {
            throw EngineInstallFailure.locked
        } catch {
            throw EngineInstallFailure.lockUnavailable
        }
    }

    /// AC-E96: a real descriptor-relative `RENAME_SWAP` in a private `0700` probe folder on every swap volume. The
    /// probe for the target and library volumes runs in the cache folder when it is on the same volume, otherwise in
    /// a hidden private folder next to the target that is removed right after.
    private func probeAtomicSwapVolumes() throws {
        let updates = environment.paths.engineUpdatesDirectory
        try guardWrite(updates, root: appDataRoot, role: "cache")
        try files.createPrivateDirectory(updates)
        var probed: [UInt64: Bool] = [:]
        let localProbe = updates.appendingPathComponent("swap-probe-\(runID)", isDirectory: true)
        try guardWrite(localProbe, root: updates, role: "cache")
        try files.createPrivateDirectory(localProbe)
        if let volume = files.volumeID(localProbe) { probed[volume] = files.probeAtomicSwap(in: localProbe) }
        if !safeRemove(localProbe) { throw EngineInstallFailure.atomicSwapUnsupported }
        for folder in swapFolders() {
            guard let volume = files.volumeID(folder) else { throw EngineInstallFailure.atomicSwapUnsupported }
            if probed[volume] == nil {
                let probe = folder.appendingPathComponent(".pi-swapprobe-\(runID)", isDirectory: true)
                let root = folder == targetParent ? targetParent : environment.dataRoot
                try guardWrite(probe, root: root, role: "probe")
                try files.createPrivateDirectory(probe)
                probed[volume] = files.probeAtomicSwap(in: probe)
                if !safeRemove(probe) { throw EngineInstallFailure.atomicSwapUnsupported }
            }
            if probed[volume] != true { throw EngineInstallFailure.atomicSwapUnsupported }
        }
    }

    /// The data root, the active game folder, its `cl_dlls`/`dlls` folders and the two libraries are no links.
    private func checkGamedirTree() throws {
        let role = "gamedirLibs"
        switch files.kind(environment.dataRoot) {
        case .missing: return
        case .directory:
            guard EnginePathGuard.isPhysical(environment.dataRoot, files: files) else {
                throw EngineInstallFailure.unsafePath(role)
            }
        default: throw EngineInstallFailure.unsafePath(role)
        }
        let gamedir = environment.gamedirURL
        for folder in [gamedir, gamedir.appendingPathComponent("cl_dlls"), gamedir.appendingPathComponent("dlls")] {
            switch files.kind(folder) {
            case .missing, .directory: continue
            default: throw EngineInstallFailure.unsafePath(role)
            }
        }
        for library in EngineArchiveLayout.gameLibraries(architecture: environment.architecture) {
            switch files.kind(gamedir.appendingPathComponent(library.gamedirRelative)) {
            case .missing, .regularFile: continue
            default: throw EngineInstallFailure.unsafePath(role)
            }
        }
    }

    private func guardWrite(_ url: URL, root: URL, role: String) throws {
        try EnginePathGuard.check(url, root: root, role: role, files: files)
    }

    // MARK: Download + digest (AC-E14, AC-E17, AC-E18, AC-E73)

    /// Returns the verified archive bytes; the archive path is never opened again after this.
    private func download() async throws -> Data {
        let asset = release.asset
        await emit(.downloading, bytes: 0, total: asset.size)
        let updates = environment.paths.engineUpdatesDirectory
        do {
            try guardWrite(updates, root: appDataRoot, role: "cache")
            try files.createPrivateDirectory(updates)
        } catch let failure as EngineInstallFailure {
            throw failure
        } catch {
            throw EngineInstallFailure.downloadFailed
        }
        let cached = updates.appendingPathComponent(asset.name, isDirectory: false)
        if files.kind(cached) == .regularFile,
           let data = try? files.readRegularFile(cached, maxBytes: asset.size), verified(data) {
            log.add([(.note, "cacheHit")])
            await emit(.verifyingDigest)
            return data
        }
        if files.kind(cached) != .missing, !safeRemove(cached) { throw EngineInstallFailure.downloadFailed }
        let partial = updates.appendingPathComponent("\(asset.name).partial-\(runID)", isDirectory: false)
        temporaries.append(partial)
        let downloader = installer.downloader
        let progress = self.progress
        let url = asset.downloadURL
        let total = asset.size
        do {
            _ = try await withEngineTimeout(installer.limits.download, stage: .download, clock: installer.clock) {
                try await downloader.download(url, to: partial, maxBytes: total) { bytes in
                    await progress(EngineInstallProgress(phase: .downloading, bytes: bytes, total: total))
                }
                return true
            }
        } catch {
            throw Self.passThrough(error, fallback: .downloadFailed)
        }
        try Task.checkCancellation()
        await emit(.verifyingDigest)
        let data: Data
        do {
            data = try files.readRegularFile(partial, maxBytes: asset.size)
        } catch EngineFileError.tooLarge {
            throw EngineInstallFailure.sizeMismatch(expected: asset.size, actual: asset.size + 1)
        } catch {
            throw EngineInstallFailure.downloadFailed
        }
        guard Int64(data.count) == asset.size else {
            throw EngineInstallFailure.sizeMismatch(expected: asset.size, actual: Int64(data.count))
        }
        guard EngineInstallNaming.sha256Hex(data) == asset.sha256 else { throw EngineInstallFailure.digestMismatch }
        // Keep the verified file as a cache (re-verified before any later use); its loss is not an error.
        do {
            try files.setPermissions(partial, 0o600)
            try guardWrite(cached, root: updates, role: "cache")
            try files.moveItem(partial, to: cached)
            temporaries.removeAll { $0 == partial }
        } catch {
            log.add([(.note, "cacheNotKept")])
        }
        return data
    }

    private func verified(_ data: Data) -> Bool {
        Int64(data.count) == release.asset.size && EngineInstallNaming.sha256Hex(data) == release.asset.sha256
    }

    // MARK: Extraction (AC-E20 – AC-E23, AC-E73a, AC-E74)

    private func extract(_ archive: Data) async throws {
        await emit(.extracting)
        let updates = environment.paths.engineUpdatesDirectory
        let work = updates.appendingPathComponent("run-\(runID)", isDirectory: true)
        let destination = work.appendingPathComponent("x", isDirectory: true)
        workDirectory = work
        do {
            try guardWrite(work, root: updates, role: "staging")
            try files.createPrivateDirectory(work)
            try files.createPrivateDirectory(destination)
        } catch let failure as EngineInstallFailure {
            throw failure
        } catch {
            throw EngineInstallFailure.extractionFailed
        }
        guard verified(archive) else { throw EngineInstallFailure.archiveChanged }
        let handler = installer.archive
        let architecture = environment.architecture
        let expected = release.asset.sha256
        let plan: EngineArchivePlan
        do {
            plan = try await withEngineTimeout(installer.limits.extraction, stage: .extraction,
                                               clock: installer.clock) { () -> EngineArchivePlan in
                let entries = try await handler.list(archive)
                let plan = try EngineArchiveLayout.validate(entries, architecture: architecture).get()
                try Task.checkCancellation()
                // Same immutable bytes as the scan and the digest (AC-E74a).
                guard EngineInstallNaming.sha256Hex(archive) == expected else { throw EngineInstallFailure.archiveChanged }
                try await handler.extract(archive, into: destination)
                return plan
            }
        } catch {
            if error is CancellationError { throw error }
            throw failure(error, fallback: .extractionFailed)
        }
        // What landed on disk must be exactly what the scan accepted: regular files (one link each) and folders.
        let items: [EngineTree.Item]
        do { items = try EngineTree.walk(destination, files: files) } catch { throw EngineInstallFailure.extractionFailed }
        var foundFiles = Set<String>()
        var foundFolders = Set<String>()
        for item in items {
            switch item.kind {
            case .regularFile:
                guard files.linkCount(destination.appendingPathComponent(item.path)) == 1 else {
                    throw EngineInstallFailure.unsafeArchive(EngineArchiveLayout.sanitized(item.path))
                }
                foundFiles.insert(item.path)
            case .directory:
                foundFolders.insert(item.path)
            default:
                throw EngineInstallFailure.unsafeArchive(EngineArchiveLayout.sanitized(item.path))
            }
        }
        if let missing = plan.files.subtracting(foundFiles).sorted().first {
            throw EngineInstallFailure.missingExpectedFile(missing)
        }
        let impliedFolders = Set(plan.files.flatMap(Self.parents)).union(plan.directories)
        if let extra = foundFiles.subtracting(plan.files).sorted().first
            ?? foundFolders.subtracting(impliedFolders).sorted().first {
            throw EngineInstallFailure.unsafeArchive(EngineArchiveLayout.sanitized(extra))
        }
        do {
            for path in plan.files { extractedHashes[path] = try files.sha256(destination.appendingPathComponent(path)) }
        } catch {
            throw EngineInstallFailure.extractionFailed
        }
        // The plain-folder copies left by upstream packaging must be byte-identical to `Versions/A` (E19.1, E19.6).
        for copy in EngineArchiveLayout.frameworkCopies {
            for path in plan.files where path.hasPrefix(copy + "/") {
                let member = String(path.dropFirst(copy.count + 1))
                if copy == EngineArchiveLayout.framework, member.hasPrefix("Versions/") { continue }
                let original = EngineArchiveLayout.frameworkVersion + "/" + member
                guard let sum = extractedHashes[path], extractedHashes[original] == sum else {
                    throw EngineInstallFailure.mixedBuild(path)
                }
            }
        }
        extraction = destination
        archivePlan = plan
    }

    private static func parents(_ path: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty {
            result.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }

    // MARK: Staged app (AC-E25 – AC-E28, AC-E30, AC-E31a, AC-E42, AC-E46)

    private func buildStagedApp() throws {
        guard let work = workDirectory, let source = extraction, let plan = archivePlan else {
            throw EngineInstallFailure.stagingFailed
        }
        let root = work.appendingPathComponent("app", isDirectory: true)
        let staged = root.appendingPathComponent(environment.targetApp.lastPathComponent, isDirectory: true)
        try staging {
            try guardWrite(root, root: work, role: "staging")
            try files.createPrivateDirectory(root)
            try files.copyItem(environment.targetApp, to: staged)
            // The staged app itself is private while it is built (AC-E94a); the original mode is put back on the
            // copy that goes next to the target.
            originalAppMode = mode(environment.targetApp, default: 0o755)
            try files.setPermissions(staged, 0o700)
        }
        try EnginePathGuard.checkBundle(staged, architecture: environment.architecture, files: files)
        let macOS = staged.appendingPathComponent("Contents/MacOS", isDirectory: true)

        // Engine modules (AC-E42b); a known module absent upstream is removed (AC-E27).
        try staging {
            for module in EngineArchiveLayout.knownModules {
                let destination = macOS.appendingPathComponent(module)
                try guardWrite(destination, root: work, role: "staging")
                if plan.contains(module) {
                    let upstream = source.appendingPathComponent(module)
                    try files.removeItem(destination)
                    try files.copyFile(upstream, to: destination, permissions: mode(upstream, default: 0o755))
                    placed.append(Placed(staged: destination, source: module, label: "Contents/MacOS/" + module,
                                         signedMayChange: module == EngineArchiveLayout.executableName))
                } else if files.kind(destination) != .missing {
                    try files.removeItem(destination)
                    report.removedModules.append(module)
                }
            }
        }

        // SDL2: only `Versions/A` is staged; links are rebuilt (AC-E28, AC-E46b).
        let frameworkSource = source.appendingPathComponent(EngineArchiveLayout.frameworkVersion, isDirectory: true)
        let framework = staged.appendingPathComponent(EngineArchiveLayout.bundleFramework, isDirectory: true)
        guard files.kind(frameworkSource) == .directory else { throw EngineInstallFailure.sdl2Reconstruction }
        try staging {
            try guardWrite(framework, root: work, role: "staging")
            try files.removeItem(framework)
            try files.createDirectory(framework.appendingPathComponent("Versions"), permissions: 0o755)
            try files.copyItem(frameworkSource, to: framework.appendingPathComponent("Versions/A"))
        }
        try EngineSDL2Framework.reconstruct(framework, files: files) { [self] url in
            try guardWrite(url, root: work, role: "staging")
        }
        try checkFramework(framework, plan: plan)
        stagedFrameworks = [framework]

        // Bundle fallback libraries: existing copies at the real bundle path get the exact upstream build (E19.3).
        for library in EngineArchiveLayout.gameLibraries(architecture: environment.architecture) {
            let destination = staged.appendingPathComponent(library.bundle)
            guard files.kind(destination) == .regularFile else {
                report.skippedLibraries.append(EngineLibrarySkip(path: "bundle:" + library.bundle, reason: .targetAbsent))
                continue
            }
            guard plan.contains(library.source) else {
                report.skippedLibraries.append(EngineLibrarySkip(path: "bundle:" + library.bundle,
                                                                 reason: .noUpstreamMatch))
                continue
            }
            try staging {
                let keep = mode(destination, default: 0o755)
                try guardWrite(destination, root: work, role: "staging")
                try files.removeItem(destination)
                try files.copyFile(source.appendingPathComponent(library.source), to: destination, permissions: keep)
            }
            placed.append(Placed(staged: destination, source: library.source, label: library.bundle,
                                 signedMayChange: false))
            stagedBundleLibraries.append("bundle:" + library.bundle)
        }

        // Unknown files are kept and reported (AC-E27, T-E-M3); extras are never copied (AC-E41a).
        let reserved = Set(EngineArchiveLayout.knownModules + [EngineArchiveLayout.framework, "cl_dlls", "dlls"])
        let libraryNames = Set(EngineArchiveLayout.gameLibraries(architecture: environment.architecture).map(\.bundle))
        try staging {
            report.unknownFilesKept = try files.contents(macOS).filter { !reserved.contains($0) }
                .map { "Contents/MacOS/" + $0 }
            for folder in ["cl_dlls", "dlls"] where files.kind(macOS.appendingPathComponent(folder)) == .directory {
                report.unknownFilesKept += try files.contents(macOS.appendingPathComponent(folder))
                    .map { "Contents/MacOS/\(folder)/\($0)" }.filter { !libraryNames.contains($0) }
            }
        }

        // AC-E25/AC-E74: byte equality with the extracted package, before anything is signed.
        try checkPlaced(includeSigned: true)
        report.quarantineFailures += removeQuarantine(tree: staged, label: "staged")
        stagedApp = staged
    }

    /// `Versions/A` holds exactly the package files with the package bytes; the root holds only the three links and
    /// `Versions`; `Versions` holds only `A` and the `Current` link (AC-E46a, AC-E46b).
    private func checkFramework(_ framework: URL, plan: EngineArchivePlan) throws {
        let label = EngineArchiveLayout.bundleFramework
        let prefix = EngineArchiveLayout.frameworkVersion + "/"
        let expected = Set(plan.files.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        let version = framework.appendingPathComponent("Versions/A")
        let items: [EngineTree.Item]
        do { items = try EngineTree.walk(version, files: files) } catch { throw EngineInstallFailure.mixedBuild(label) }
        let found = Set(items.filter { $0.kind == .regularFile }.map(\.path))
        guard found == expected, items.allSatisfy({ $0.kind == .regularFile || $0.kind == .directory }) else {
            throw EngineInstallFailure.mixedBuild(label)
        }
        for member in expected.sorted() {
            placed.append(Placed(staged: version.appendingPathComponent(member), source: prefix + member,
                                 label: label + "/Versions/A/" + member,
                                 signedMayChange: member == "SDL2" || member.hasPrefix("_CodeSignature/")))
        }
        let rootNames = (try? files.contents(framework)) ?? []
        let versionNames = (try? files.contents(framework.appendingPathComponent("Versions"))) ?? []
        guard rootNames == ["Headers", "Resources", "SDL2", "Versions"], versionNames == ["A", "Current"],
              ["Headers", "Resources", "SDL2"].allSatisfy({ files.kind(framework.appendingPathComponent($0)) == .symbolicLink }),
              files.kind(framework.appendingPathComponent("Versions/Current")) == .symbolicLink else {
            throw EngineInstallFailure.mixedBuild(label)
        }
    }

    /// Every placed file equals its extracted source, and the source still equals the hash taken right after
    /// extraction. After signing (`includeSigned == false`) files that signing rewrites are exempt (AC-E46c/d).
    private func checkPlaced(includeSigned: Bool) throws {
        guard let source = extraction else { throw EngineInstallFailure.stagingFailed }
        for item in placed where includeSigned || !item.signedMayChange {
            guard let expected = extractedHashes[item.source],
                  (try? files.sha256(item.staged)) == expected,
                  !includeSigned || (try? files.sha256(source.appendingPathComponent(item.source))) == expected else {
                throw EngineInstallFailure.mixedBuild(item.label)
            }
        }
    }

    private func staging(_ body: () throws -> Void) throws {
        do { try body() } catch let failure as EngineInstallFailure { throw failure } catch {
            throw EngineInstallFailure.stagingFailed
        }
    }

    private func mode(_ url: URL, default fallback: UInt16) -> UInt16 {
        files.permissions(url).map { UInt16($0 & 0o777) } ?? fallback
    }

    // MARK: Signature (AC-E29, AC-E46)

    private func sign() async throws {
        await emit(.verifyingSignature)
        guard let staged = stagedApp else { throw EngineInstallFailure.stagingFailed }
        do {
            for framework in stagedFrameworks { try await installer.signer.signFramework(framework) }
            try await installer.signer.signApp(staged)
            try await installer.signer.verify(staged)
        } catch {
            throw failure(error, fallback: .codesign)
        }
        try checkPlaced(includeSigned: false)
        do { stagedManifest = try EngineTree.manifest(staged, files: files) } catch {
            throw EngineInstallFailure.stagingFailed
        }
    }

    // MARK: Preflight (AC-E35, AC-E36)

    /// The two active-gamedir libraries with an exact upstream source; a missing source or file is skipped and
    /// reported, a link refuses the install.
    private func planGameLibraries() throws {
        guard let plan = archivePlan else { throw EngineInstallFailure.stagingFailed }
        let gamedir = environment.gamedirURL
        for library in EngineArchiveLayout.gameLibraries(architecture: environment.architecture) {
            let target = gamedir.appendingPathComponent(library.gamedirRelative, isDirectory: false)
            let label = "gamedir:\(environment.gamedir)/\(library.gamedirRelative)"
            guard environment.gamedir == EngineArchiveLayout.packageGamedir, plan.contains(library.source) else {
                report.skippedLibraries.append(EngineLibrarySkip(path: label, reason: .noUpstreamMatch))
                continue
            }
            switch files.kind(target) {
            case .missing:
                report.skippedLibraries.append(EngineLibrarySkip(path: label, reason: .targetAbsent))
            case .regularFile where EnginePathGuard.isPhysical(target, files: files):
                try guardWrite(target, root: environment.dataRoot, role: "gamedirLibs")
                libraryTargets.append(LibraryTarget(library: library, target: target, label: label))
            default:
                throw EngineInstallFailure.unsafePath("gamedirLibs")
            }
        }
    }

    private func checkPermissions() throws {
        let parents = [targetParent] + libraryTargets.map { $0.target.deletingLastPathComponent() }
        for parent in parents where !files.isWritable(parent) {
            throw EngineInstallFailure.permissionDenied(parent.path)
        }
    }

    private func processFailure() -> EngineInstallFailure? {
        switch installer.detector.engineProcessState() {
        case .notRunning: return nil
        case .running: return .engineRunning
        case .unavailable: return .processUnavailable
        }
    }

    private func checkDeadline() throws {
        if let deadline = installDeadline, installer.clock.now() > deadline {
            throw EngineInstallFailure.timeout(.install)
        }
    }

    // MARK: Backup (AC-E33a, AC-E34, AC-E38, AC-E85)

    private func backup() throws {
        let root = environment.paths.engineBackupsDirectory
        try guardWrite(root, root: appDataRoot, role: "backup")
        try files.createPrivateDirectory(root)
        var stamp = EngineInstallNaming.timestamp(installer.clock.now())
        let base = environment.targetApp.deletingPathExtension().lastPathComponent
        func names(_ stamp: String) -> [URL] {
            [root.appendingPathComponent("\(base)-\(stamp).app", isDirectory: true),
             root.appendingPathComponent("identity-\(stamp)", isDirectory: true),
             root.appendingPathComponent("libs-\(stamp)", isDirectory: true),
             root.appendingPathComponent("manifest-\(stamp).json", isDirectory: false)]
        }
        if names(stamp).contains(where: { files.kind($0) != .missing }) { stamp += "-" + runID }
        let locations = names(stamp)
        let location = EngineBackupLocation(root: root, stamp: stamp, app: locations[0], identity: locations[1],
                                            libraries: locations[2], manifest: locations[3])
        // Known from the start, so a backup that cannot be cleaned up keeps its location (AC-E79d).
        report.backup = location

        identityBefore = identityStates()
        try checkDeadline()
        let original = try EngineTree.manifest(environment.targetApp, files: files)
        originalManifest = original
        try guardWrite(location.app, root: root, role: "backup")
        backupItems.append(location.app)
        try files.copyItem(environment.targetApp, to: location.app)
        guard try EngineTree.manifest(location.app, files: files) == original else {
            throw EngineInstallFailure.backupFailed
        }

        try checkDeadline()
        try guardWrite(location.identity, root: root, role: "backup")
        backupItems.append(location.identity)
        try files.createPrivateDirectory(location.identity)
        var identity: [EngineFileRecord] = []
        for candidate in identityCandidates() {
            guard files.kind(candidate.url) == .regularFile, EnginePathGuard.isPhysical(candidate.url, files: files) else {
                if files.kind(candidate.url) != .missing { log.add([(.note, "identitySkipped")]) }
                continue
            }
            let copy = location.identity.appendingPathComponent("\(candidate.location.rawValue).xash_id")
            identity.append(try copyIntoBackup(candidate.url, to: copy, label: candidate.location.rawValue, root: root))
        }
        report.identityFilesBackedUp = identity.count

        try checkDeadline()
        try guardWrite(location.libraries, root: root, role: "backup")
        backupItems.append(location.libraries)
        try files.createPrivateDirectory(location.libraries)
        var libraries: [EngineFileRecord] = []
        for library in libraryTargets {
            let name = "\(environment.gamedir)-" + library.library.gamedirRelative.replacingOccurrences(of: "/", with: "-")
            let record = try copyIntoBackup(library.target, to: location.libraries.appendingPathComponent(name),
                                            label: library.label, root: root)
            libraries.append(record)
            libraryRecords[library.label] = record
        }

        try checkDeadline()
        let manifest = EngineBackupManifest(version: 1, timestamp: stamp, assetName: release.asset.name,
                                            digest: release.asset.digest, commit: release.commitSHA,
                                            originalApp: environment.targetApp.path,
                                            appBackup: location.app.lastPathComponent, app: original,
                                            identity: identity, libraries: libraries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(manifest)
        try guardWrite(location.manifest, root: root, role: "backup")
        backupItems.append(location.manifest)
        try files.writeFile(data, to: location.manifest, permissions: 0o600)
        let written = try files.read(location.manifest, offset: 0, length: data.count + 1)
        guard try JSONDecoder().decode(EngineBackupManifest.self, from: written) == manifest else {
            throw EngineInstallFailure.backupFailed
        }
        report.backup = location
    }

    private func identityCandidates() -> [IdentitySource] {
        IdentityReader(fileSystem: LocalFileSystem(), homeDirectory: environment.home)
            .candidates(gamedir: environment.gamedirURL)
    }

    /// A `0600` copy whose checksum matches the source; the source is only read.
    private func copyIntoBackup(_ source: URL, to copy: URL, label: String, root: URL) throws -> EngineFileRecord {
        let sourceMode = mode(source, default: 0o644)
        let size = Int64(try files.size(source))
        let sum = try files.sha256(source)
        try guardWrite(copy, root: root, role: "backup")
        try files.copyFile(source, to: copy, permissions: 0o600)
        guard try files.sha256(copy) == sum else { throw EngineInstallFailure.backupFailed }
        return EngineFileRecord(label: label, original: source.path, backup: copy.lastPathComponent, sha256: sum,
                                size: size, mode: sourceMode)
    }

    /// Removes this run's backup when nothing on the target changed. The manifest goes last: if any other item
    /// cannot be removed, the manifest and the backup location are kept (AC-E79d).
    private func discardBackup() {
        let manifest = backupItems.first { $0.pathExtension == "json" }
        var complete = true
        for item in backupItems where item != manifest {
            if !safeRemove(item) { complete = false }
        }
        if complete, let manifest, !safeRemove(manifest) { complete = false }
        backupItems = []
        if complete { report.backup = nil }
    }

    // MARK: Identity baseline (AC-E80)

    private func identityStates() -> [IdentityLocation: IdentityState] {
        var states: [IdentityLocation: IdentityState] = [:]
        for candidate in identityCandidates() { states[candidate.location] = identityState(candidate) }
        return states
    }

    private func identityState(_ candidate: IdentitySource) -> IdentityState {
        switch files.kind(candidate.url) {
        case .missing: return (.absent, nil)
        case .regularFile where EnginePathGuard.isPhysical(candidate.url, files: files):
            guard let size = try? files.size(candidate.url), size <= RawIdentityReader.maxFileSize,
                  let data = try? files.read(candidate.url, offset: 0, length: Int(size)),
                  let value = RawIdentityReader.parse(data) else { return (.unreadable, nil) }
            let raw = Identity.rawID(fileValue: value, location: candidate.location)
            return (raw == 0 ? .presentZero : .presentNonzero, EngineInstallNaming.sha256Hex(data))
        default: return (.unreadable, nil)
        }
    }

    private func identityChanges() -> [EngineIdentityLocationChange] {
        guard let before = identityBefore else { return [] }
        let after = identityStates()
        return IdentityLocation.allCases.compactMap { location in
            guard let old = before[location], let new = after[location] else { return nil }
            let change: EngineIdentityChangeKind
            if old.state == .unreadable || new.state == .unreadable || (old.state == .absent && new.state == .absent) {
                change = .notComparable
            } else if old.state == .absent || new.state == .absent {
                change = .changed
            } else {
                change = old.hash == new.hash ? .unchanged : .changed
            }
            return EngineIdentityLocationChange(location: location.rawValue, before: old.state, after: new.state,
                                                change: change)
        }
    }

    // MARK: Install (AC-E35, AC-E39, AC-E39c, AC-E43, AC-E78)

    private func sibling(of url: URL, _ tag: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).pi-\(tag)-\(runID)")
    }

    /// Descriptor-relative atomic exchange after both operands passed the path guard right before it (AC-E93).
    private func guardedSwap(_ first: URL, _ second: URL, root: URL, role: String) throws {
        try guardWrite(first, root: root, role: role)
        try guardWrite(second, root: root, role: role)
        try files.swapItems(first, second)
    }

    /// Swap errors: guard failures pass through; an unsupported exchange is `atomicSwapUnsupported`; a permission
    /// error is `permissionDenied(parent)`; anything else `installFailed`. A failed swap changed nothing.
    private func swapFailure(_ error: any Error, parent: URL) -> EngineInstallFailure {
        if let failure = error as? EngineInstallFailure { return failure }
        switch EngineFileError.from(error) {
        case .posix(let code) where code == ENOTSUP || code == EINVAL || code == ENOSYS:
            return .atomicSwapUnsupported
        case let error where error.isPermission:
            return .permissionDenied(parent.path)
        default:
            return .installFailed
        }
    }

    /// The library is the backed-up file: a regular file on a link-free path with the recorded SHA-256 and mode.
    private func libraryMatchesRecord(_ library: LibraryTarget) -> Bool {
        guard let record = libraryRecords[library.label], files.kind(library.target) == .regularFile,
              EnginePathGuard.isPhysical(library.target, files: files),
              (try? EnginePathGuard.check(library.target, root: environment.dataRoot, role: "gamedirLibs",
                                          files: files)) != nil else {
            return false
        }
        return (try? files.sha256(library.target)) == record.sha256 && mode(library.target, default: 0) == record.mode
    }

    /// AC-E90/AC-E91: checked right before a library (or the app) is changed; a mismatch changes nothing there.
    private func verifyLibraryUnchanged(_ library: LibraryTarget) throws {
        guard libraryMatchesRecord(library) else { throw EngineInstallFailure.conflict }
    }

    private func installStaged() async throws {
        guard let staged = stagedApp, let expected = stagedManifest, let original = originalManifest,
              let source = extraction else {
            throw EngineInstallFailure.stagingFailed
        }
        let target = environment.targetApp
        let incoming = sibling(of: target, "new")
        try checkDeadline()
        try guardWrite(incoming, root: targetParent, role: "appParent")
        temporaries.append(incoming)
        do {
            try files.copyItem(staged, to: incoming)
            try guardWrite(incoming, root: targetParent, role: "appParent")
            try files.setPermissions(incoming, originalAppMode)
        } catch let failure as EngineInstallFailure {
            throw failure
        } catch {
            let error = EngineFileError.from(error)
            throw error.isPermission ? EngineInstallFailure.permissionDenied(targetParent.path) : .installFailed
        }
        guard (try? EngineTree.manifest(incoming, files: files)) == expected else {
            throw EngineInstallFailure.installFailed
        }
        try checkDeadline()

        // AC-E78/AC-E91: nothing changed since the backup; no link appeared on the way.
        try guardWrite(target, root: targetParent, role: "appParent")
        try EnginePathGuard.checkBundle(target, architecture: environment.architecture, files: files)
        try checkGamedirTree()
        guard (try? EngineTree.manifest(target, files: files)) == original else { throw EngineInstallFailure.conflict }
        // TOCTOU: the engine state is checked again right before the swap (AC-E35).
        if let failure = processFailure() { throw failure }
        try checkDeadline()
        // AC-E91: every library still matches its record as the last step before the app swap.
        for library in libraryTargets { try verifyLibraryUnchanged(library) }

        do {
            try guardedSwap(incoming, target, root: targetParent, role: "appParent")
        } catch {
            throw swapFailure(error, parent: targetParent)
        }
        swapped = true
        mutated = true
        oldApp = incoming

        for library in libraryTargets {
            try checkDeadline()
            if let failure = processFailure() { throw failure }
            let temp = sibling(of: library.target, "new")
            let upstream = source.appendingPathComponent(library.library.source)
            let keep = libraryRecords[library.label]?.mode ?? 0o644
            try guardWrite(temp, root: environment.dataRoot, role: "gamedirLibs")
            temporaries.append(temp)
            do {
                try files.copyFile(upstream, to: temp, permissions: keep & 0o777)
            } catch {
                let error = EngineFileError.from(error)
                throw error.isPermission
                    ? EngineInstallFailure.permissionDenied(library.target.deletingLastPathComponent().path)
                    : .installFailed
            }
            guard (try? files.sha256(temp)) == extractedHashes[library.library.source] else {
                throw EngineInstallFailure.mixedBuild(library.label)
            }
            // AC-E90: the very last check before this library changes.
            try verifyLibraryUnchanged(library)
            do {
                try guardedSwap(temp, library.target, root: environment.dataRoot, role: "gamedirLibs")
            } catch {
                throw swapFailure(error, parent: library.target.deletingLastPathComponent())
            }
            replacedLibraries.append(library)
            // `temp` now holds the previous library (the backup keeps it too).
            if safeRemove(temp) { temporaries.removeAll { $0 == temp } }
            report.quarantineFailures += removeQuarantine(item: library.target, label: library.label)
        }

        try checkDeadline()
        guard (try? EngineTree.manifest(target, files: files)) == expected else { throw EngineInstallFailure.installFailed }
        do { try await installer.signer.verify(target) } catch { throw failure(error, fallback: .codesign) }
        // AC-E95: a verification that ran past the deadline rolls back too.
        try checkDeadline()

        // Success: the previous app (now at the sibling path) is removed; the backup keeps it.
        if safeRemove(incoming) { temporaries.removeAll { $0 == incoming } }
        oldApp = nil
    }

    // MARK: Rollback (AC-E38a, AC-E38b, AC-E39a, AC-E43b, AC-E43c, AC-E92)

    /// Runs to its end (not limited by the install deadline); every step is logged.
    private func rollback(_ reason: EngineInstallFailure) async -> EngineInstallResult {
        await emit(.rollingBack)
        var complete = true
        let target = environment.targetApp
        var restored: [String] = []

        // Libraries first, then the app; only replaced libraries are written (AC-E92b).
        for library in replacedLibraries.reversed() {
            guard let record = libraryRecords[library.label], let backup = report.backup else {
                complete = false
                continue
            }
            let restore = sibling(of: library.target, "restore")
            do {
                try guardWrite(restore, root: environment.dataRoot, role: "gamedirLibs")
                temporaries.append(restore)
                try files.copyFile(backup.libraries.appendingPathComponent(record.backup), to: restore,
                                   permissions: record.mode & 0o777)
                try guardedSwap(restore, library.target, root: environment.dataRoot, role: "gamedirLibs")
                restored.append(library.label)
                log.add([(.stage, "rollingBack"), (.note, "libraryRestored")])
            } catch {
                complete = false
                log.add([(.stage, "rollingBack"), (.note, "libraryRestoreFailed")])
            }
        }

        if swapped {
            var appBack = false
            if let previous = oldApp, files.kind(previous) == .directory {
                appBack = (try? guardedSwap(previous, target, root: targetParent, role: "appParent")) != nil
            }
            if !appBack, let backup = report.backup {
                let restore = sibling(of: target, "restore")
                do {
                    try guardWrite(restore, root: targetParent, role: "appParent")
                    temporaries.append(restore)
                    try files.copyItem(backup.app, to: restore)
                    try guardedSwap(restore, target, root: targetParent, role: "appParent")
                    appBack = true
                } catch {
                    appBack = false
                }
            }
            appRestored = appBack
            log.add([(.stage, "rollingBack"), (.note, appBack ? "appRestored" : "appRestoreFailed")])
            if !appBack { complete = false }
        }

        // AC-E38b/AC-E92: the app and EVERY library must match the backup (kind, SHA-256, mode).
        if let original = originalManifest, (try? EngineTree.manifest(target, files: files)) != original {
            complete = false
        }
        for library in libraryTargets where !libraryMatchesRecord(library) {
            complete = false
            restored.removeAll { $0 == library.label }
            log.add([(.stage, "rollingBack"), (.note, "libraryMismatch")])
        }
        report.restoredLibraries = restored.reversed()
        discardTemporaries()
        return await finish(complete ? .rolledBack(reason) : .rollbackIncomplete(reason))
    }

    // MARK: Removal (AC-E72)

    /// Deletes only inside the staging/cache/backup folders, or this run's own hidden siblings next to the app or a
    /// library; the path must be link-free. A refused or failed removal is a leftover (AC-E79c).
    @discardableResult
    private func safeRemove(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        var root: URL?
        for candidate in [environment.paths.engineUpdatesDirectory, environment.paths.engineBackupsDirectory]
        where EnginePaths.isInside(path: url.standardized.path, root: candidate.standardized.path)
            && url.standardized.path != candidate.standardized.path {
            root = candidate
        }
        let siblingParents = [(targetParent, environment.targetApp.lastPathComponent)]
            + libraryTargets.map { ($0.target.deletingLastPathComponent(), $0.target.lastPathComponent) }
        if root == nil, name == ".pi-swapprobe-\(runID)" {
            for folder in swapFolders() where url.deletingLastPathComponent().standardized.path == folder.standardized.path {
                root = folder == targetParent ? targetParent : environment.dataRoot
            }
        }
        if root == nil {
            for (parent, base) in siblingParents
            where url.deletingLastPathComponent().standardized.path == parent.standardized.path
                && name.hasPrefix(".\(base).pi-") && name.hasSuffix("-\(runID)") {
                root = parent == targetParent ? targetParent : environment.dataRoot
            }
        }
        guard let root else {
            report.leftovers.append(url.path)
            return false
        }
        do {
            try EnginePathGuard.check(url, root: root, role: "cleanup", files: files)
            try files.removeItem(url)
            return true
        } catch {
            report.leftovers.append(url.path)
            return false
        }
    }

    private func discardTemporaries() {
        for item in temporaries where files.kind(item) != .missing { safeRemove(item) }
        temporaries = []
    }

    // MARK: Quarantine (AC-E30)

    private static let quarantine = "com.apple.quarantine"

    private func removeQuarantine(tree root: URL, label: String) -> [String] {
        var failures = removeQuarantine(item: root, label: label)
        guard let items = try? EngineTree.walk(root, files: files) else { return failures + [label] }
        for item in items {
            failures += removeQuarantine(item: root.appendingPathComponent(item.path), label: label + "/" + item.path)
        }
        return failures
    }

    private func removeQuarantine(item: URL, label: String) -> [String] {
        do {
            try files.removeExtendedAttribute(Self.quarantine, at: item)
            return []
        } catch {
            return [label]
        }
    }

    // MARK: Final library state (AC-E79a, AC-E79b)

    private func libraryStates() -> [EngineLibraryState] {
        var states: [EngineLibraryState] = []
        let libraries = EngineArchiveLayout.gameLibraries(architecture: environment.architecture)
        if originalManifest != nil {
            for library in libraries {
                let url = environment.targetApp.appendingPathComponent(library.bundle)
                guard files.kind(url) == .regularFile, let sum = try? files.sha256(url) else { continue }
                states.append(EngineLibraryState(path: "bundle:" + library.bundle,
                                                 version: version(sum, upstream: extractedHashes[library.source],
                                                                  original: originalManifest?.sha256(of: library.bundle))))
            }
        }
        for library in libraryTargets {
            guard let sum = try? files.sha256(library.target) else {
                states.append(EngineLibraryState(path: library.label, version: .unknown))
                continue
            }
            states.append(EngineLibraryState(path: library.label,
                                             version: version(sum, upstream: extractedHashes[library.library.source],
                                                              original: libraryRecords[library.label]?.sha256)))
        }
        return states
    }

    private func version(_ sum: String, upstream: String?, original: String?) -> EngineLibraryVersion {
        if sum == upstream { return .upstream }
        if sum == original { return .original }
        return .unknown
    }

    // MARK: Progress, outcome, cleanup

    private func emit(_ phase: EngineInstallPhase, bytes: Int64 = 0, total: Int64 = 0) async {
        log.add([(.stage, phase.rawValue)])
        await progress(EngineInstallProgress(phase: phase, bytes: bytes, total: total))
    }

    private func finish(_ outcome: EngineInstallOutcome) async -> EngineInstallResult {
        discardTemporaries()
        if let work = workDirectory, files.kind(work) != .missing { safeRemove(work) }
        report.effectiveLibraries = libraryStates()
        // Updated = changed by this run, not put back, and the upstream build on disk (AC-E79a).
        var touched = Set(replacedLibraries.map(\.label)).subtracting(report.restoredLibraries)
        if swapped && !appRestored { touched.formUnion(stagedBundleLibraries) }
        report.updatedLibraries = report.effectiveLibraries
            .filter { $0.version == .upstream && touched.contains($0.path) }.map(\.path)
        report.identityChanges = identityChanges()
        switch outcome {
        case .failed(let failure), .rolledBack(let failure), .rollbackIncomplete(let failure):
            log.add([(.stage, outcome.phase.rawValue), (.error, failure.code)])
        case .installed, .cancelled:
            log.add([(.stage, outcome.phase.rawValue)])
        }
        // Cleanup and rollback are done: only now may another installer start (AC-E88a).
        installLock?.release()
        installLock = nil
        await progress(EngineInstallProgress(phase: outcome.phase))
        return EngineInstallResult(outcome: outcome, report: report, log: log.lines)
    }

    /// Install failures (also time limits) pass through; a tool error is logged with its fixed category only and
    /// becomes `fallback` (AC-E86); anything else becomes `fallback`.
    private func failure(_ error: any Error, fallback: EngineInstallFailure) -> EngineInstallFailure {
        if let failure = error as? EngineInstallFailure { return failure }
        if let tool = error as? EngineToolError {
            log.add([(.note, tool.logNote)])
            return fallback
        }
        return fallback
    }

    private static func passThrough(_ error: any Error, fallback: EngineInstallFailure) -> any Error {
        if error is CancellationError || error is EngineInstallFailure { return error }
        return fallback
    }
}

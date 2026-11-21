import CryptoKit
import Darwin
import Foundation

// MARK: - v2.26 engine install: dependencies (DI) and production adapters
//
// Every external effect of `EngineInstaller` goes through one of these protocols, so the tests run without network,
// without `/Applications` and without game data. The production adapters use fixed executables with fixed argument
// arrays (no shell), HTTPS with a host allowlist, size caps and time limits. Tool output (stderr) never leaves the
// adapters: failures carry only a fixed category and the exit status (AC-E86).

// MARK: Protocols

/// The official release JSON (`EngineReleaseSource.apiURL` only).
protocol EngineReleaseMetadataProviding: Sendable {
    func fetchReleaseJSON() async throws -> Data
}

/// Streams one asset to `destination` (created `0600`), never writing more than `maxBytes`.
protocol EngineAssetDownloading: Sendable {
    func download(_ url: URL, to destination: URL, maxBytes: Int64,
                  progress: @escaping @Sendable (Int64) async -> Void) async throws
}

/// Lists and extracts the package from the verified, immutable archive bytes (never from a path, AC-E73).
protocol EngineArchiveHandling: Sendable {
    func list(_ archive: Data) async throws -> [EngineArchiveEntry]
    func extract(_ archive: Data, into directory: URL) async throws
}

/// Ad-hoc signing and strict verification (`/usr/bin/codesign` in production).
protocol EngineCodeSigning: Sendable {
    func signFramework(_ framework: URL) async throws
    func signApp(_ app: URL) async throws
    func verify(_ app: URL) async throws
}

/// Wall clock for backup names and the install deadline, and a sleep for the time limits.
protocol EngineInstallClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

/// Read-only identity snapshot (masked CID, state labels, raw equality) for the before/after comparison.
protocol EngineIdentityReading: Sendable {
    func snapshot(home: URL, gamedir: URL?) -> EngineIdentitySnapshot
}

/// File operations of the installer. Links are never followed; every write creates a new item (no in-place edit).
protocol EngineFileOperating: ReadOnlyFileProbing {
    /// Hard link count of a regular file (`st_nlink`), `nil` when it cannot be inspected.
    func linkCount(_ url: URL) -> Int?
    /// `access(W_OK)` on the item.
    func isWritable(_ url: URL) -> Bool
    /// The volume of `url` supports `renamex_np(RENAME_SWAP)` (read-only capability query, nothing is written).
    func supportsAtomicSwap(_ url: URL) -> Bool
    /// Names inside a folder (sorted).
    func contents(_ url: URL) throws -> [String]
    /// Creates the folder (and missing parents) with `permissions`; an existing folder is set to `permissions`.
    func createDirectory(_ url: URL, permissions: UInt16) throws
    /// Recursive copy that keeps links as links (the source item itself must not be a link).
    func copyItem(_ source: URL, to destination: URL) throws
    /// Copies a regular file (opened without following links) to a new file with `permissions`.
    func copyFile(_ source: URL, to destination: URL, permissions: UInt16) throws
    /// Writes a new file (`O_EXCL`) with `permissions`.
    func writeFile(_ data: Data, to destination: URL, permissions: UInt16) throws
    /// Reads a whole regular file through one descriptor opened with `O_NOFOLLOW` (at most `maxBytes`).
    func readRegularFile(_ url: URL, maxBytes: Int64) throws -> Data
    /// `rename(2)` inside one volume (staging and cache only).
    func moveItem(_ source: URL, to destination: URL) throws
    /// Atomic exchange of two items: each parent folder is opened with `O_DIRECTORY | O_NOFOLLOW` (and must be the
    /// same folder the path names), then `renameatx_np(fromFD, name, toFD, name, RENAME_SWAP)`. There is no
    /// rename-based fallback (AC-E93a).
    func swapItems(_ first: URL, _ second: URL) throws
    /// Volume (`st_dev`) of an item, not following a final link.
    func volumeID(_ url: URL) -> UInt64?
    /// Creates two files in `folder` (a private probe folder), exchanges them with the same descriptor-relative
    /// `RENAME_SWAP` as `swapItems` and removes them again; `true` when the exchange worked (AC-E96).
    func probeAtomicSwap(in folder: URL) -> Bool
    /// `flock(LOCK_EX | LOCK_NB)` on `url`, opened `O_RDWR | O_CREAT | O_NOFOLLOW` with `0600`; the content is never
    /// read or written. Held until `release()` or until the process ends (AC-E88).
    func acquireExclusiveLock(_ url: URL) throws -> EngineFileLock
    func removeItem(_ url: URL) throws
    func createSymbolicLink(_ url: URL, target: String) throws
    func symbolicLinkTarget(_ url: URL) -> String?
    func setPermissions(_ url: URL, _ mode: UInt16) throws
    /// SHA-256 (lowercase hex) of a regular file, read without following links.
    func sha256(_ url: URL) throws -> String
    /// Removes one extended attribute of the item itself (not followed); an absent attribute is not an error.
    func removeExtendedAttribute(_ name: String, at url: URL) throws
}

extension EngineFileOperating {
    func createPrivateDirectory(_ url: URL) throws { try createDirectory(url, permissions: 0o700) }
}

/// A held `flock`. Released explicitly, on deinit, or by the system when the process ends; there is no PID file.
final class EngineFileLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let onRelease: (@Sendable () -> Void)?

    init(descriptor: Int32, onRelease: (@Sendable () -> Void)? = nil) {
        self.descriptor = descriptor
        self.onRelease = onRelease
    }

    var isHeld: Bool { lock.withLock { descriptor >= 0 } }

    func release() {
        let held: Int32 = lock.withLock {
            let value = descriptor
            descriptor = -1
            return value
        }
        guard held >= 0 else { return }
        flock(held, LOCK_UN)
        close(held)
        onRelease?()
    }

    deinit { release() }
}

enum EngineLockError: Error, Sendable, Equatable {
    /// Another holder has the lock (`EWOULDBLOCK`).
    case busy
    /// The lock file cannot be opened or locked (link, permission, path error) (`errno`).
    case unavailable(Int32)
}

enum EngineFileError: Error, Sendable, Equatable {
    case posix(Int32)
    case notRegularFile
    case tooLarge

    /// `EACCES` / `EPERM` / `EROFS`.
    var isPermission: Bool {
        if case .posix(let code) = self { return code == EACCES || code == EPERM || code == EROFS }
        return false
    }

    static func from(_ error: any Error) -> EngineFileError {
        if let error = error as? EngineFileError { return error }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return .posix(Int32(underlying.code))
        }
        if nsError.domain == NSPOSIXErrorDomain { return .posix(Int32(nsError.code)) }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .posix(EACCES)
            case NSFileWriteVolumeReadOnlyError: return .posix(EROFS)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .posix(ENOENT)
            case NSFileWriteFileExistsError: return .posix(EEXIST)
            default: break
            }
        }
        return .posix(EIO)
    }
}

/// A system tool failed. Only the tool name, a fixed category and the exit status are kept; the tool's own output
/// (which may contain paths, user names or other secrets) is dropped (AC-E86, AC-E86a).
struct EngineToolError: Error, Sendable, Equatable {
    enum Category: String, Sendable {
        case archiveRejected
        case signatureInvalid
        case launchFailed
        case notAllowed
        /// The process could not be waited for, was killed by a signal, or its pipes failed.
        case processFailed
    }

    let tool: String
    let category: Category
    let exitStatus: Int32

    /// `tar:archiveRejected:exit2`.
    var logNote: String { "\(tool):\(category.rawValue):exit\(exitStatus)" }
}

// MARK: Commands (fixed argv allowlist, AC-E20, AC-E37, AC-E50)

enum EngineCommand: Sendable, Equatable {
    /// `/usr/bin/tar -tJf -` (archive bytes on stdin)
    case tarList
    /// `/usr/bin/tar -tvJf -`
    case tarListVerbose
    /// `/usr/bin/tar --no-xattrs --no-acls --no-fflags --no-mac-metadata -xJf - -C <folder>` (nothing from the
    /// archive's metadata is restored: no quarantine/xattr, ACL or file flag)
    case tarExtract(into: UpdatePath)
    /// `/usr/bin/codesign --force --sign - -- <framework>`
    case signFramework(UpdatePath)
    /// `/usr/bin/codesign --force --sign - -- <app>` (not `--deep`: nested engine and game libraries keep their
    /// upstream bytes, AC-E46c/d)
    case signApp(UpdatePath)
    /// `/usr/bin/codesign --verify --deep --strict -- <app>`
    case verifySignature(UpdatePath)

    static let tar = "/usr/bin/tar"
    static let codesign = "/usr/bin/codesign"
    static let extractOptions = ["--no-xattrs", "--no-acls", "--no-fflags", "--no-mac-metadata"]

    /// The archive is read from stdin (`-f -`); paths are absolute (they start with `/`, so they can never be read as
    /// an option) and codesign paths follow `--`. Every element is one argument; no shell sees them.
    var argv: [String] {
        switch self {
        case .tarList: return [Self.tar, "-tJf", "-"]
        case .tarListVerbose: return [Self.tar, "-tvJf", "-"]
        case .tarExtract(let folder): return [Self.tar] + Self.extractOptions + ["-xJf", "-", "-C", folder.value]
        case .signFramework(let path), .signApp(let path):
            return [Self.codesign, "--force", "--sign", "-", "--", path.value]
        case .verifySignature(let path): return [Self.codesign, "--verify", "--deep", "--strict", "--", path.value]
        }
    }

    var tool: String { URL(fileURLWithPath: argv[0]).lastPathComponent }

    var timeout: TimeInterval { 120 }

    /// Listing and extraction stop when the install is cancelled; signing always runs to its end.
    var isCancellable: Bool {
        switch self {
        case .tarList, .tarListVerbose, .tarExtract: return true
        case .signFramework, .signApp, .verifySignature: return false
        }
    }

    /// Listings are machine-read and tool errors are never shown: stderr is discarded for every command.
    var readsStandardOutputOnly: Bool { true }
}

enum EngineCommandAllowlist {
    static func isAllowed(_ argv: [String]) -> Bool {
        func path(_ text: String) -> Bool { UpdatePath(URL(fileURLWithPath: text))?.value == text }
        switch argv.first {
        case EngineCommand.tar?:
            if argv.count == 3 { return (argv[1] == "-tJf" || argv[1] == "-tvJf") && argv[2] == "-" }
            let options = EngineCommand.extractOptions
            guard argv.count == 5 + options.count, Array(argv[1...options.count]) == options else { return false }
            let rest = Array(argv[(options.count + 1)...])
            return rest[0] == "-xJf" && rest[1] == "-" && rest[2] == "-C" && path(rest[3])
        case EngineCommand.codesign?:
            guard argv.count == 6, path(argv[5]) else { return false }
            return Array(argv[1...4]) == ["--force", "--sign", "-", "--"]
                || Array(argv[1...4]) == ["--verify", "--deep", "--strict", "--"]
        default:
            return false
        }
    }
}

protocol EngineCommandRunning: Sendable {
    /// `input` is written to the tool's stdin (the archive bytes for `tar`).
    func run(_ command: EngineCommand, input: Data?) async throws -> CommandOutput
}

/// Runs allowlisted argv directly (no shell) in its own process group, with the command's time limit and
/// cancellation; returns only after the child was reaped (`SystemProcess`).
struct ProcessEngineCommandRunner: EngineCommandRunning {
    init() {}

    func run(_ command: EngineCommand, input: Data?) async throws -> CommandOutput {
        let argv = command.argv
        guard EngineCommandAllowlist.isAllowed(argv) else { throw CommandError.notAllowed }
        return try await SystemProcess.run(argv, timeout: command.timeout, cancellable: command.isCancellable,
                                           includeStandardError: !command.readsStandardOutputOnly, input: input)
    }
}

enum EngineCommandMapping {
    /// Time limit → `timeout(stage)`, cancellation → `CancellationError`, any other runner error → a tool error with
    /// a fixed category (no output).
    static func mapped(_ error: any Error, command: EngineCommand, stage: EngineInstallTimedStage,
                       category: EngineToolError.Category) -> any Error {
        if error is CancellationError { return error }
        switch error as? CommandError {
        case .timedOut?: return EngineInstallFailure.timeout(stage)
        case .cancelled?: return CancellationError()
        case .notAllowed?: return EngineToolError(tool: command.tool, category: .notAllowed, exitStatus: -1)
        case .launchFailed?: return EngineToolError(tool: command.tool, category: .launchFailed, exitStatus: -1)
        case .signaled(let signal)?:
            return EngineToolError(tool: command.tool, category: .processFailed, exitStatus: 128 + signal)
        case .waitFailed?, .signalFailed?, .ioFailed?:
            return EngineToolError(tool: command.tool, category: .processFailed, exitStatus: -1)
        case nil: return EngineToolError(tool: command.tool, category: category, exitStatus: -1)
        }
    }
}

/// `tar` adapter: plain + verbose listing (parsed by `EngineTarListing`) and extraction, all fed from the same
/// in-memory archive bytes on stdin.
struct TarEngineArchive: EngineArchiveHandling {
    let runner: any EngineCommandRunning

    init(runner: any EngineCommandRunning = ProcessEngineCommandRunner()) {
        self.runner = runner
    }

    func list(_ archive: Data) async throws -> [EngineArchiveEntry] {
        let names = try await run(.tarList, archive)
        let verbose = try await run(.tarListVerbose, archive)
        guard let entries = EngineTarListing.parse(names: names.output, verbose: verbose.output) else {
            throw EngineInstallFailure.unsafeArchive("listing")
        }
        return entries
    }

    func extract(_ archive: Data, into directory: URL) async throws {
        guard let folder = UpdatePath(directory) else {
            throw EngineToolError(tool: "tar", category: .notAllowed, exitStatus: -1)
        }
        _ = try await run(.tarExtract(into: folder), archive)
    }

    private func run(_ command: EngineCommand, _ archive: Data) async throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try await runner.run(command, input: archive)
        } catch {
            throw EngineCommandMapping.mapped(error, command: command, stage: .extraction, category: .archiveRejected)
        }
        guard output.status == 0 else {
            throw EngineToolError(tool: command.tool, category: .archiveRejected, exitStatus: output.status)
        }
        return output
    }
}

/// `codesign` adapter: framework, then app (not deep), then strict deep verification.
struct ProcessEngineCodeSigner: EngineCodeSigning {
    let runner: any EngineCommandRunning

    init(runner: any EngineCommandRunning = ProcessEngineCommandRunner()) {
        self.runner = runner
    }

    func signFramework(_ framework: URL) async throws { try await run(framework, EngineCommand.signFramework) }
    func signApp(_ app: URL) async throws { try await run(app, EngineCommand.signApp) }
    func verify(_ app: URL) async throws { try await run(app, EngineCommand.verifySignature) }

    private func run(_ url: URL, _ make: (UpdatePath) -> EngineCommand) async throws {
        guard let path = UpdatePath(url) else {
            throw EngineToolError(tool: "codesign", category: .notAllowed, exitStatus: -1)
        }
        let command = make(path)
        let output: CommandOutput
        do {
            output = try await runner.run(command, input: nil)
        } catch {
            throw EngineCommandMapping.mapped(error, command: command, stage: .install, category: .signatureInvalid)
        }
        guard output.status == 0 else {
            throw EngineToolError(tool: command.tool, category: .signatureInvalid, exitStatus: output.status)
        }
    }
}

// MARK: Network adapters (AC-E9, AC-E10, AC-E14, AC-E16, AC-E83)

/// Records the first redirect that left the allowlist and refuses it (the redirect response is returned instead).
final class EngineRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejection: EngineInstallFailure?
    private let allowsRedirects: Bool

    init(allowsRedirects: Bool) {
        self.allowsRedirects = allowsRedirects
    }

    var rejected: EngineInstallFailure? { lock.withLock { rejection } }

    /// The decision for one redirect target (also used directly by the tests).
    func evaluate(_ url: URL?) -> Bool {
        guard let url else { return reject(.redirectRejected("")) }
        let host = url.host?.lowercased() ?? ""
        guard allowsRedirects else { return reject(.redirectRejected(host)) }
        switch EngineReleaseSource.checkDownloadHost(url) {
        case nil: return true
        case .insecureURL?: return reject(.insecureURL)
        default: return reject(.redirectRejected(host))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        evaluate(request.url) ? request : nil
    }

    private func reject(_ failure: EngineInstallFailure) -> Bool {
        lock.withLock { if rejection == nil { rejection = failure } }
        return false
    }
}

enum EngineNetwork {
    /// No cookies, no cache, no stored credentials.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// AC-E83 order: the redirect guard's typed rejection first, then cancellation, then install failures, then a
    /// generic network failure (`fallback`).
    static func classify(_ error: any Error, rejection: EngineInstallFailure?,
                         fallback: EngineInstallFailure) -> any Error {
        if let rejection { return rejection }
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        if let failure = error as? EngineInstallFailure { return failure }
        return fallback
    }
}

/// `GET` of the exact release API URL; no redirects, 30 s, at most 2 MB.
struct GitHubEngineReleaseMetadataProvider: EngineReleaseMetadataProviding {
    init() {}

    func fetchReleaseJSON() async throws -> Data {
        let url = EngineReleaseSource.apiURL
        guard EngineReleaseSource.isAllowedAPI(url) else { throw EngineInstallFailure.urlNotAllowed }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PlayerIdentity", forHTTPHeaderField: "User-Agent")
        let guardDelegate = EngineRedirectGuard(allowsRedirects: false)
        let session = EngineNetwork.session()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate)
            if let rejected = guardDelegate.rejected { throw rejected }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host?.lowercased() == EngineReleaseSource.apiHost else {
                throw EngineInstallFailure.metadataUnavailable
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > EngineReleaseSource.maxMetadataSize { throw EngineInstallFailure.metadataInvalid }
            }
            return data
        } catch {
            throw EngineNetwork.classify(error, rejection: guardDelegate.rejected, fallback: .metadataUnavailable)
        }
    }
}

/// HTTPS streaming download with the redirect allowlist; stops as soon as more than `maxBytes` arrive.
struct URLSessionEngineAssetDownloader: EngineAssetDownloading {
    init() {}

    func download(_ url: URL, to destination: URL, maxBytes: Int64,
                  progress: @escaping @Sendable (Int64) async -> Void) async throws {
        if let failure = EngineReleaseSource.checkDownloadHost(url) { throw failure }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("PlayerIdentity", forHTTPHeaderField: "User-Agent")
        let guardDelegate = EngineRedirectGuard(allowsRedirects: true)
        let session = EngineNetwork.session()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate)
            if let rejected = guardDelegate.rejected { throw rejected }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url else {
                throw EngineInstallFailure.downloadFailed
            }
            if let failure = EngineReleaseSource.checkDownloadHost(final) {
                throw failure == .insecureURL ? failure : .redirectRejected(final.host?.lowercased() ?? "")
            }
            if http.expectedContentLength > maxBytes { throw EngineInstallFailure.sizeTooLarge }
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw EngineInstallFailure.downloadFailed }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var buffer = Data()
            buffer.reserveCapacity(1 << 16)
            var written: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    written += Int64(buffer.count)
                    guard written <= maxBytes else { throw EngineInstallFailure.sizeTooLarge }
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    await progress(written)
                }
            }
            written += Int64(buffer.count)
            guard written <= maxBytes else { throw EngineInstallFailure.sizeTooLarge }
            try handle.write(contentsOf: buffer)
            try handle.close()
            await progress(written)
        } catch {
            throw EngineNetwork.classify(error, rejection: guardDelegate.rejected, fallback: .downloadFailed)
        }
    }
}

// MARK: Clock

struct SystemEngineInstallClock: EngineInstallClock {
    init() {}
    func now() -> Date { Date() }
    func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

// MARK: Identity reader (read-only)

/// Global identity (first valid of the three home locations) and the gamedir identity, read with the §73 rules
/// (no links, ≤ 64 bytes, 16 hex). Only labels, the raw equality and a masked CID are returned.
struct LocalEngineIdentityReader: EngineIdentityReading {
    let files: any ReadOnlyFileProbing

    init(files: any ReadOnlyFileProbing = LocalFileProbe()) {
        self.files = files
    }

    func snapshot(home: URL, gamedir: URL?) -> EngineIdentitySnapshot {
        let candidates = IdentityReader(fileSystem: LocalFileSystem(), homeDirectory: home).candidates(gamedir: gamedir)
        var global: (RawIdentityState, UInt64?) = (.absent, nil)
        var sawUnreadable = false
        for candidate in candidates where candidate.location != .gamedir {
            let value = Self.read(candidate, files: files)
            if value.0 == .unreadable { sawUnreadable = true; continue }
            if value.0 != .absent { global = value; break }
        }
        if global.0 == .absent, sawUnreadable { global = (.unreadable, nil) }
        let gamedirValue = candidates.first(where: { $0.location == .gamedir }).map { Self.read($0, files: files) }
            ?? (.absent, nil)
        let equal = global.0 == .nonzero && gamedirValue.0 == .nonzero && global.1 == gamedirValue.1
        let masked = RawIdentityReader.probe(home: home, gamedir: gamedir, files: files).cidMasked
        return EngineIdentitySnapshot(global: global.0, gamedir: gamedirValue.0, rawEqual: equal,
                                      cidMasked: EngineInstallPrivacy.strictMasked(masked))
    }

    /// State and raw value of one location (the raw value stays inside this module).
    static func read(_ candidate: IdentitySource, files: any ReadOnlyFileProbing) -> (RawIdentityState, UInt64?) {
        switch files.kind(candidate.url) {
        case .missing: return (.absent, nil)
        case .regularFile where RawIdentityReader.isPhysical(candidate.url, files: files):
            guard let size = try? files.size(candidate.url), size <= RawIdentityReader.maxFileSize,
                  let data = try? files.read(candidate.url, offset: 0, length: Int(size)),
                  let value = RawIdentityReader.parse(data) else { return (.unreadable, nil) }
            let raw = Identity.rawID(fileValue: value, location: candidate.location)
            return (raw == 0 ? .zero : .nonzero, raw)
        default: return (.unreadable, nil)
        }
    }
}

// MARK: Local file operations

/// `FileManager` + Darwin calls. Reads never follow links (`O_NOFOLLOW`, `lstat`); new files are `O_EXCL`.
struct LocalEngineFileOperations: EngineFileOperating {
    private let probe = LocalFileProbe()

    init() {}

    // ReadOnlyFileProbing
    func kind(_ url: URL) -> ProbedItemKind { probe.kind(url) }
    func size(_ url: URL) throws -> UInt64 { try probe.size(url) }
    func permissions(_ url: URL) -> UInt32? { probe.permissions(url) }
    func read(_ url: URL, offset: UInt64, length: Int) throws -> Data { try probe.read(url, offset: offset, length: length) }
    func resolvedPath(_ url: URL) -> String { probe.resolvedPath(url) }

    func linkCount(_ url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_nlink)
    }

    func isWritable(_ url: URL) -> Bool { access(url.path, W_OK) == 0 }

    func supportsAtomicSwap(_ url: URL) -> Bool {
        struct Buffer {
            var length: UInt32 = 0
            var capabilities = vol_capabilities_attr_t()
        }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var buffer = Buffer()
        guard getattrlist(url.path, &request, &buffer, MemoryLayout<Buffer>.size, 0) == 0 else { return false }
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        let capabilities = withUnsafeBytes(of: buffer.capabilities.capabilities) { Array($0.bindMemory(to: UInt32.self)) }
        let valid = withUnsafeBytes(of: buffer.capabilities.valid) { Array($0.bindMemory(to: UInt32.self)) }
        let bit = UInt32(VOL_CAP_INT_RENAME_SWAP)
        return valid[index] & bit != 0 && capabilities[index] & bit != 0
    }

    func contents(_ url: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        } catch {
            throw EngineFileError.from(error)
        }
    }

    func createDirectory(_ url: URL, permissions: UInt16) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: Int(permissions)])
        } catch {
            throw EngineFileError.from(error)
        }
        guard kind(url) == .directory else { throw EngineFileError.notRegularFile }
        try setPermissions(url, permissions)
    }

    func copyItem(_ source: URL, to destination: URL) throws {
        guard kind(source) != .symbolicLink else { throw EngineFileError.notRegularFile }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw EngineFileError.from(error)
        }
    }

    func copyFile(_ source: URL, to destination: URL, permissions: UInt16) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw EngineFileError.posix(errno) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, UInt32(info.st_mode) & 0o170000 == 0o100000 else {
            throw EngineFileError.notRegularFile
        }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(permissions))
        guard output >= 0 else { throw EngineFileError.posix(errno) }
        var failed: EngineFileError?
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        copying: while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                failed = .posix(errno)
                break
            }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + offset, count - offset) }
                if written < 0 {
                    if errno == EINTR { continue }
                    failed = .posix(errno)
                    break copying
                }
                offset += written
            }
        }
        if failed == nil, fchmod(output, mode_t(permissions)) != 0 { failed = .posix(errno) }
        if failed == nil, fsync(output) != 0 { failed = .posix(errno) }
        close(output)
        if let failed {
            unlink(destination.path)
            throw failed
        }
    }

    func writeFile(_ data: Data, to destination: URL, permissions: UInt16) throws {
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(permissions))
        guard output >= 0 else { throw EngineFileError.posix(errno) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(destination.path)
            throw EngineFileError.from(error)
        }
    }

    func readRegularFile(_ url: URL, maxBytes: Int64) throws -> Data {
        let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw EngineFileError.posix(errno) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, UInt32(info.st_mode) & 0o170000 == 0o100000 else {
            throw EngineFileError.notRegularFile
        }
        guard Int64(info.st_size) <= maxBytes else { throw EngineFileError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw EngineFileError.posix(errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard Int64(data.count) <= maxBytes else { throw EngineFileError.tooLarge }
        }
        return data
    }

    func moveItem(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else { throw EngineFileError.posix(errno) }
    }

    func swapItems(_ first: URL, _ second: URL) throws {
        let firstParent = try Self.openParent(of: first)
        defer { close(firstParent) }
        let secondParent = try Self.openParent(of: second)
        defer { close(secondParent) }
        guard renameatx_np(firstParent, first.lastPathComponent, secondParent, second.lastPathComponent,
                           UInt32(RENAME_SWAP)) == 0 else {
            throw EngineFileError.posix(errno)
        }
    }

    /// The parent folder of `url` opened without following a link, and checked to be the folder the path names
    /// (same device and inode as `lstat` of the path).
    private static func openParent(of url: URL) throws -> Int32 {
        let parent = url.deletingLastPathComponent().path
        let descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EngineFileError.posix(errno) }
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0, lstat(parent, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            close(descriptor)
            throw EngineFileError.posix(ELOOP)
        }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            close(descriptor)
            throw EngineFileError.posix(EINVAL)
        }
        return descriptor
    }

    func volumeID(_ url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return UInt64(bitPattern: Int64(info.st_dev))
    }

    func probeAtomicSwap(in folder: URL) -> Bool {
        let first = folder.appendingPathComponent("swap-probe-a")
        let second = folder.appendingPathComponent("swap-probe-b")
        defer {
            unlink(first.path)
            unlink(second.path)
        }
        do {
            try writeFile(Data("a".utf8), to: first, permissions: 0o600)
            try writeFile(Data("b".utf8), to: second, permissions: 0o600)
            try swapItems(first, second)
            return try readRegularFile(first, maxBytes: 1) == Data("b".utf8)
        } catch {
            return false
        }
    }

    func acquireExclusiveLock(_ url: URL) throws -> EngineFileLock {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw EngineLockError.unavailable(errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, UInt32(info.st_mode) & 0o170000 == 0o100000 else {
            close(descriptor)
            throw EngineLockError.unavailable(EFTYPE)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw code == EWOULDBLOCK ? EngineLockError.busy : EngineLockError.unavailable(code)
        }
        return EngineFileLock(descriptor: descriptor)
    }

    func removeItem(_ url: URL) throws {
        guard kind(url) != .missing else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw EngineFileError.from(error)
        }
    }

    func createSymbolicLink(_ url: URL, target: String) throws {
        guard symlink(target, url.path) == 0 else { throw EngineFileError.posix(errno) }
    }

    func symbolicLinkTarget(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(url.path, &buffer, buffer.count - 1)
        guard count >= 0 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func setPermissions(_ url: URL, _ mode: UInt16) throws {
        guard lchmod(url.path, mode_t(mode)) == 0 else { throw EngineFileError.posix(errno) }
    }

    func sha256(_ url: URL) throws -> String {
        let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw EngineFileError.posix(errno) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, UInt32(info.st_mode) & 0o170000 == 0o100000 else {
            throw EngineFileError.notRegularFile
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw EngineFileError.posix(errno)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        return CIDCalculator.hexLower(Array(hasher.finalize()))
    }

    func removeExtendedAttribute(_ name: String, at url: URL) throws {
        guard removexattr(url.path, name, XATTR_NOFOLLOW) == 0 else {
            if errno == ENOATTR { return }
            throw EngineFileError.posix(errno)
        }
    }
}

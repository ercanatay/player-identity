import CryptoKit
import Darwin
import Foundation

// MARK: - §73 macOS hardware identity health
//
// Static capability check of the installed Xash3D engine (does it show indicators of deriving the identity from the
// Mac's hardware?) plus the state of the raw identity (`nonzero` / `zero` / `absent` / `unreadable`). Indicators are
// not a proof of uniqueness: the check never claims that the identity is unique. Everything here is read-only: no
// file is written or deleted, no process is started (except the user's "Regenerate Identity", see
// `MacIdentityRegenerator`) and nothing touches the network. The raw identity and the full CID never leave this file:
// reports carry only the state label and a masked CID.

// MARK: Read-only file access

/// Kind of a file system item, seen without following symbolic links (`lstat`).
enum ProbedItemKind: Sendable, Equatable {
    /// Definitely absent (`ENOENT` only).
    case missing
    case directory
    case regularFile
    case symbolicLink
    case other
    /// The item could not be inspected (`EACCES`, `EPERM`, `EIO`, `ESTALE`, … — every error except `ENOENT`).
    case unreadable
}

/// Read-only access used by the capability check and the raw identity probe. There is deliberately no write, move or
/// delete method; tests inject an in-memory fake.
protocol ReadOnlyFileProbing: Sendable {
    /// Kind of the item itself (a symbolic link is reported, never followed). `.missing` only when the item
    /// definitely does not exist; any other failure is `.unreadable`.
    func kind(_ url: URL) -> ProbedItemKind
    /// Size of a regular file in bytes.
    func size(_ url: URL) throws -> UInt64
    /// POSIX permission bits (`st_mode & 0o7777`) of the item itself (not followed); `nil` when it cannot be inspected.
    func permissions(_ url: URL) -> UInt32?
    /// At most `length` bytes from `offset` (fewer at the end of the file); opened read-only, never through a link.
    func read(_ url: URL, offset: UInt64, length: Int) throws -> Data
    /// The physical path with every symbolic link resolved (compared with the given path to reject links anywhere in
    /// it, and used for the forbidden-root containment check).
    func resolvedPath(_ url: URL) -> String
}

enum FileProbeError: Error, Sendable, Equatable {
    case unreadable
}

/// Default when nothing is injected (tests, UI testing): nothing exists.
struct UnavailableFileProbe: ReadOnlyFileProbing {
    init() {}
    func kind(_ url: URL) -> ProbedItemKind { .missing }
    func size(_ url: URL) throws -> UInt64 { throw FileProbeError.unreadable }
    func permissions(_ url: URL) -> UInt32? { nil }
    func read(_ url: URL, offset: UInt64, length: Int) throws -> Data { throw FileProbeError.unreadable }
    func resolvedPath(_ url: URL) -> String { url.standardized.path }
}

/// `lstat` + `open(O_RDONLY | O_NOFOLLOW)` + `pread`; a file is never opened for writing.
struct LocalFileProbe: ReadOnlyFileProbing {
    init() {}

    func kind(_ url: URL) -> ProbedItemKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return Self.kind(forLstatError: errno)
        }
        switch UInt32(info.st_mode) & Self.typeMask {
        case Self.directoryType: return .directory
        case Self.regularType: return .regularFile
        case Self.linkType: return .symbolicLink
        default: return .other
        }
    }

    /// Only `ENOENT` proves the item is absent; every other `lstat` error (permission, I/O, stale handle, …) is
    /// `.unreadable`.
    static func kind(forLstatError code: Int32) -> ProbedItemKind {
        code == ENOENT ? .missing : .unreadable
    }

    func size(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, UInt32(info.st_mode) & Self.typeMask == Self.regularType else {
            throw FileProbeError.unreadable
        }
        return UInt64(max(0, info.st_size))
    }

    func permissions(_ url: URL) -> UInt32? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return UInt32(info.st_mode) & 0o7777
    }

    // `S_IFMT`, `S_IFDIR`, `S_IFREG`, `S_IFLNK`.
    private static let typeMask: UInt32 = 0o170000
    private static let directoryType: UInt32 = 0o040000
    private static let regularType: UInt32 = 0o100000
    private static let linkType: UInt32 = 0o120000

    func read(_ url: URL, offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, offset <= UInt64(Int64.max) else { throw FileProbeError.unreadable }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileProbeError.unreadable }
        defer { close(descriptor) }
        guard length > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: length)
        var filled = 0
        while filled < length {
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress! + filled, length - filled, off_t(offset) + off_t(filled))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FileProbeError.unreadable
            }
            if count == 0 { break }
            filled += count
        }
        return Data(buffer.prefix(filled))
    }

    func resolvedPath(_ url: URL) -> String {
        Self.physicalPath(url.standardized.path)
    }

    /// `realpath` of the path; when it does not exist (yet), the physical path of its longest existing parent plus the
    /// remaining components (links in existing parent folders are still resolved).
    static func physicalPath(_ path: String) -> String {
        if let resolved = realPath(path) { return resolved }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (physicalPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

// MARK: Engine path (§73.6)

/// Why an engine app path cannot be used.
enum EnginePathError: String, Error, Sendable, Equatable, CaseIterable {
    /// Nothing at the path.
    case notFound
    /// Not a directory with the `.app` extension.
    case notAppBundle
    /// The path (or an item inside the bundle that is read) is a symbolic link.
    case symbolicLink
    /// No executable file under `Contents/MacOS`.
    case missingExecutable
    /// The path (lexical or physical) lies inside the game data root or an identity file folder.
    case insideDataFolder
    /// An item of the bundle could not be inspected or read (permission, I/O error, …).
    case unreadable
}

/// The parts of an engine bundle the capability check reads.
struct EngineBundle: Sendable, Equatable {
    let app: URL
    /// `Contents/MacOS/<CFBundleExecutable>`.
    let executable: URL
    /// `Contents/MacOS/libxash.dylib` when present (the engine library of FWGS builds).
    let library: URL?
    /// `CFBundleShortVersionString`: informational only, never a decision input (§73.3).
    let version: String?

    /// The binaries searched for evidence (executable first).
    var binaries: [URL] { [executable] + (library.map { [$0] } ?? []) }
    /// The binary whose hash is reported: the engine library, else the executable.
    var hashedBinary: URL { library ?? executable }
}

enum EnginePaths {
    static let defaultApp = URL(fileURLWithPath: "/Applications/Xash3D-FWGS.app", isDirectory: true)
    static let libraryName = "libxash.dylib"
    static let fallbackExecutable = "xash3d"
    /// Upper bound of the `Info.plist` read.
    static let maxInfoPlistSize: UInt64 = 1024 * 1024

    /// Folders an engine override may not point into: the data root (with its game folders) and the folders of the
    /// home identity files (`~/.config`, `~/.local`).
    static func forbiddenRoots(home: URL, dataRoot: URL?) -> [URL] {
        var roots = [home.appendingPathComponent(".config", isDirectory: true),
                     home.appendingPathComponent(".local", isDirectory: true)]
        if let dataRoot { roots.append(dataRoot) }
        return roots
    }

    /// macOS system aliases that are links by design (`/var`, `/tmp`, `/etc` → `/private/…`). A path through them is
    /// written in its canonical form before it is compared with a physical path; any other link stays a link.
    static let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]

    static func systemCanonical(_ path: String) -> String {
        for (alias, target) in systemAliases where path == alias || path.hasPrefix(alias + "/") {
            return target + path.dropFirst(alias.count)
        }
        return path
    }

    static func isInside(_ url: URL, _ root: URL) -> Bool {
        isInside(path: url.standardized.path, root: root.standardized.path)
    }

    static func isInside(path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Containment on both the lexical and the physical (links resolved) paths of the candidate and of every root, so
    /// an alias (a link to a forbidden folder, or a forbidden root reached through a link) cannot escape the check.
    static func isForbidden(_ url: URL, roots: [URL], files: any ReadOnlyFileProbing) -> Bool {
        let candidates = Set([url.standardized.path, files.resolvedPath(url)])
        return roots.contains { root in
            let bases = Set([root.standardized.path, files.resolvedPath(root)])
            return candidates.contains { path in bases.contains { isInside(path: path, root: $0) } }
        }
    }

    /// §73.6.2 override rules: not inside the data or identity folders (lexical and physical), an `.app` directory,
    /// no symbolic link anywhere in the path, and an executable under `Contents/MacOS`.
    static func validateOverride(_ url: URL, files: any ReadOnlyFileProbing, forbiddenRoots: [URL]) -> EnginePathError? {
        let standardized = url.standardized
        if isForbidden(standardized, roots: forbiddenRoots, files: files) { return .insideDataFolder }
        switch inspect(standardized, files: files) {
        case .success: return nil
        case .failure(let error): return error
        }
    }

    /// Validates a bundle and finds its binaries. Symbolic links are never followed; an item that cannot be inspected
    /// makes the bundle unverifiable (`.unreadable`), never "not found".
    static func inspect(_ app: URL, files: any ReadOnlyFileProbing) -> Result<EngineBundle, EnginePathError> {
        let app = app.standardized
        switch files.kind(app) {
        case .missing: return .failure(.notFound)
        case .unreadable: return .failure(.unreadable)
        case .symbolicLink: return .failure(.symbolicLink)
        case .directory: break
        case .regularFile, .other: return .failure(.notAppBundle)
        }
        guard app.pathExtension.lowercased() == "app" else { return .failure(.notAppBundle) }
        guard files.resolvedPath(app) == app.path else { return .failure(.symbolicLink) }
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        for folder in [contents, macOS] {
            switch files.kind(folder) {
            case .directory: continue
            case .symbolicLink: return .failure(.symbolicLink)
            case .unreadable: return .failure(.unreadable)
            default: return .failure(.missingExecutable)
            }
        }
        let info: (executable: String?, version: String?)
        switch readInfo(contents.appendingPathComponent("Info.plist", isDirectory: false), files: files) {
        case .success(let value): info = value
        case .failure(let error): return .failure(error)
        }
        let name = info.executable.flatMap(isPlainName) ?? fallbackExecutable
        let executable = macOS.appendingPathComponent(name, isDirectory: false)
        switch files.kind(executable) {
        case .regularFile: break
        case .symbolicLink: return .failure(.symbolicLink)
        case .unreadable: return .failure(.unreadable)
        default: return .failure(.missingExecutable)
        }
        // A regular file without any POSIX execute bit is not an executable.
        guard let mode = files.permissions(executable) else { return .failure(.unreadable) }
        guard mode & 0o111 != 0 else { return .failure(.missingExecutable) }
        let libraryURL = macOS.appendingPathComponent(libraryName, isDirectory: false)
        var library: URL?
        switch files.kind(libraryURL) {
        case .missing: library = nil
        case .regularFile: library = libraryURL
        case .symbolicLink: return .failure(.symbolicLink)
        // Something exists under the library name but is not a regular file (folder, FIFO, socket, device): it is
        // never treated as "no library"; the package cannot be verified.
        case .unreadable, .directory, .other: return .failure(.unreadable)
        }
        return .success(EngineBundle(app: app, executable: executable, library: library, version: info.version))
    }

    private static func isPlainName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    /// A missing `Info.plist` (or one that is not a property list) falls back to the default executable name; an
    /// `Info.plist` that exists but cannot be inspected or read makes the bundle unverifiable.
    private static func readInfo(_ url: URL, files: any ReadOnlyFileProbing)
        -> Result<(executable: String?, version: String?), EnginePathError> {
        switch files.kind(url) {
        case .missing: return .success((nil, nil))
        case .unreadable: return .failure(.unreadable)
        case .symbolicLink: return .failure(.symbolicLink)
        case .directory, .other: return .success((nil, nil))
        case .regularFile: break
        }
        guard let size = try? files.size(url), size <= maxInfoPlistSize,
              let data = try? files.read(url, offset: 0, length: Int(size)) else {
            return .failure(.unreadable)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .success((nil, nil))
        }
        return .success((plist["CFBundleExecutable"] as? String, plist["CFBundleShortVersionString"] as? String))
    }
}

/// The engine app the check uses: a valid override, else the default path. A rejected override is reported (with the
/// requested path) so the reason can be shown and the CLI never treats the fallback as a clean result.
struct EnginePathResolution: Sendable, Equatable {
    let app: URL
    let isOverride: Bool
    let rejectedOverride: EnginePathError?
    /// The override that was asked for (tilde expanded, lexically normalized); `nil` when none was set.
    let requestedPath: String?
    /// `false` when the path was only normalized, not inspected (the engine is running or its process state is
    /// unknown, so nothing of the bundle may be read).
    let validated: Bool

    init(app: URL, isOverride: Bool, rejectedOverride: EnginePathError?, requestedPath: String? = nil,
         validated: Bool = true) {
        self.app = app
        self.isOverride = isOverride
        self.rejectedOverride = rejectedOverride
        self.requestedPath = requestedPath
        self.validated = validated
    }

    /// Lexical only: no file system access at all (used while the engine runs or its state is unknown).
    static func unvalidated(override: String?) -> EnginePathResolution {
        guard let text = override?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return EnginePathResolution(app: EnginePaths.defaultApp, isOverride: false, rejectedOverride: nil,
                                        validated: false)
        }
        let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath, isDirectory: true).standardized
        return EnginePathResolution(app: url, isOverride: true, rejectedOverride: nil, requestedPath: url.path,
                                    validated: false)
    }

    static func resolve(override: String?, files: any ReadOnlyFileProbing, forbiddenRoots: [URL]) -> EnginePathResolution {
        guard let text = override?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return EnginePathResolution(app: EnginePaths.defaultApp, isOverride: false, rejectedOverride: nil)
        }
        let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath, isDirectory: true)
        let requested = url.standardized.path
        if let error = EnginePaths.validateOverride(url, files: files, forbiddenRoots: forbiddenRoots) {
            return EnginePathResolution(app: EnginePaths.defaultApp, isOverride: false, rejectedOverride: error,
                                        requestedPath: requested)
        }
        return EnginePathResolution(app: url.standardized, isOverride: true, rejectedOverride: nil,
                                    requestedPath: requested)
    }
}

// MARK: Static capability (§73.4)

/// `yes` / `no` / `unknown` (§73.4.2).
enum StaticSupport: String, Sendable, Equatable, CaseIterable {
    case yes
    case no
    case unknown
}

/// K1–K4 static evidence, each searched read-only in the engine binaries.
struct CapabilityEvidence: Sendable, Equatable {
    /// K1: a load command links the IOKit framework.
    var ioKitLinked = false
    /// K2: a load command links the CoreFoundation framework.
    var coreFoundationLinked = false
    /// K3: an IORegistry / IOService access symbol or string.
    var ioRegistryAccess = false
    /// K4: the `IOPlatformSerialNumber` string.
    var platformSerialString = false

    var count: Int {
        [ioKitLinked, coreFoundationLinked, ioRegistryAccess, platformSerialString].filter { $0 }.count
    }

    /// `yes` needs at least three items and K4; otherwise `no` (a structurally valid, readable binary).
    var support: StaticSupport {
        count >= 3 && platformSerialString ? .yes : .no
    }

    mutating func merge(_ other: CapabilityEvidence) {
        ioKitLinked = ioKitLinked || other.ioKitLinked
        coreFoundationLinked = coreFoundationLinked || other.coreFoundationLinked
        ioRegistryAccess = ioRegistryAccess || other.ioRegistryAccess
        platformSerialString = platformSerialString || other.platformSerialString
    }
}

/// Why the static result is `unknown`.
enum CapabilityFailure: String, Sendable, Equatable {
    case engineNotFound
    case notAppBundle
    case symbolicLink
    case missingExecutable
    case insideDataFolder
    case unreadable
    case tooLarge
    /// Not a Mach-O file, or structurally broken (load commands, sections or regions out of bounds).
    case notMachO
    case timeout
    case cancelled

    init(_ error: EnginePathError) {
        switch error {
        case .notFound: self = .engineNotFound
        case .notAppBundle: self = .notAppBundle
        case .symbolicLink: self = .symbolicLink
        case .missingExecutable: self = .missingExecutable
        case .insideDataFolder: self = .insideDataFolder
        case .unreadable: self = .unreadable
        }
    }
}

struct CapabilityResult: Sendable, Equatable {
    let support: StaticSupport
    let evidence: CapabilityEvidence
    let failure: CapabilityFailure?
    /// First 12 hex characters of the SHA-256 of the engine binary; `nil` when it could not be read.
    let engineHashShort: String?
    let engineVersion: String?

    static func unknown(_ failure: CapabilityFailure, version: String? = nil) -> CapabilityResult {
        CapabilityResult(support: .unknown, evidence: CapabilityEvidence(), failure: failure, engineHashShort: nil,
                         engineVersion: version)
    }
}

/// Monotonic time of the scan limit (never the wall clock, so moving the system clock can neither stretch nor cut the
/// limit). Tests inject a stepping clock.
struct MonotonicClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
    }

    static let system = MonotonicClock { ContinuousClock.now }
}

/// Mach-O header, load commands and string regions (symbol string table, C-string sections), read in chunks. The
/// whole file is never loaded; size (512 MB), time (3 s, monotonic) and cancellation (checked at every chunk) make the
/// result `unknown`. Structurally broken load commands, sections or regions are `notMachO` (`unknown`), never `no`.
struct MachOCapabilityScanner: Sendable {
    static let maxBinarySize: UInt64 = 512 * 1024 * 1024
    static let timeLimit: Duration = .seconds(3)
    static let chunkSize = 256 * 1024
    static let maxLoadCommandsSize: UInt32 = 16 * 1024 * 1024
    static let maxFatSlices: UInt32 = 16

    static let ioKitFramework = Array("IOKit.framework".utf8)
    static let coreFoundationFramework = Array("CoreFoundation.framework".utf8)
    static let ioRegistryTokens = ["IOServiceGetMatchingService", "IOServiceMatching", "IORegistryEntry"]
        .map { Array($0.utf8) }
    static let platformSerialToken = Array("IOPlatformSerialNumber".utf8)

    let files: any ReadOnlyFileProbing
    let clock: MonotonicClock

    init(files: any ReadOnlyFileProbing, clock: MonotonicClock = .system) {
        self.files = files
        self.clock = clock
    }

    enum ScanError: Error, Equatable {
        case unreadable
        case tooLarge
        case notMachO
        case timeout
        case cancelled
    }

    /// The deadline of a scan started now.
    func deadline() -> ContinuousClock.Instant {
        clock.now().advanced(by: Self.timeLimit)
    }

    /// The whole check of one bundle: evidence of every binary (merged), then the hash of the engine binary. The time
    /// limit is checked once more at the end, so a single read that blocked past it never ends as a success.
    func check(_ bundle: EngineBundle) -> CapabilityResult {
        let deadline = deadline()
        do {
            var evidence = CapabilityEvidence()
            for binary in bundle.binaries {
                evidence.merge(try scan(binary, deadline: deadline))
            }
            let hash = try sha256Short(bundle.hashedBinary, deadline: deadline)
            try checkTime(deadline)
            return CapabilityResult(support: evidence.support, evidence: evidence, failure: nil, engineHashShort: hash,
                                    engineVersion: bundle.version)
        } catch let error as ScanError {
            let failure: CapabilityFailure
            switch error {
            case .unreadable: failure = .unreadable
            case .tooLarge: failure = .tooLarge
            case .notMachO: failure = .notMachO
            case .timeout: failure = .timeout
            case .cancelled: failure = .cancelled
            }
            return .unknown(failure, version: bundle.version)
        } catch {
            return .unknown(.unreadable, version: bundle.version)
        }
    }

    // MARK: Binary

    func scan(_ url: URL, deadline: ContinuousClock.Instant) throws -> CapabilityEvidence {
        try checkTime(deadline)
        guard files.kind(url) == .regularFile else { throw ScanError.unreadable }
        let size: UInt64
        do { size = try files.size(url) } catch { throw ScanError.unreadable }
        guard size <= Self.maxBinarySize else { throw ScanError.tooLarge }
        let head = try read(url, offset: 0, length: 8, deadline: deadline)
        guard head.count >= 8 else { throw ScanError.notMachO }
        let bigMagic = Self.uint32(head, 0, bigEndian: true)
        var evidence = CapabilityEvidence()
        if bigMagic == 0xCAFE_BABE || bigMagic == 0xCAFE_BABF {
            let is64 = bigMagic == 0xCAFE_BABF
            let count = Self.uint32(head, 4, bigEndian: true)
            guard count > 0, count <= Self.maxFatSlices else { throw ScanError.notMachO }
            let entrySize = is64 ? 32 : 20
            let table = try read(url, offset: 8, length: Int(count) * entrySize, deadline: deadline)
            guard table.count == Int(count) * entrySize else { throw ScanError.notMachO }
            for index in 0..<Int(count) {
                let base = index * entrySize
                let offset = is64 ? Self.uint64(table, base + 8, bigEndian: true)
                    : UInt64(Self.uint32(table, base + 8, bigEndian: true))
                let length = is64 ? Self.uint64(table, base + 16, bigEndian: true)
                    : UInt64(Self.uint32(table, base + 12, bigEndian: true))
                guard offset < size, length <= size - offset else { throw ScanError.notMachO }
                evidence.merge(try scanSlice(url, base: offset, sliceSize: length, deadline: deadline))
            }
        } else {
            evidence = try scanSlice(url, base: 0, sliceSize: size, deadline: deadline)
        }
        return evidence
    }

    private struct Region {
        let offset: UInt64
        let size: UInt64
    }

    // Load command numbers.
    private static let dylibCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]
    private static let symtabCommand: UInt32 = 0x2
    private static let segmentCommand: UInt32 = 0x1
    private static let segment64Command: UInt32 = 0x19

    private func scanSlice(_ url: URL, base: UInt64, sliceSize: UInt64,
                           deadline: ContinuousClock.Instant) throws -> CapabilityEvidence {
        let header = try read(url, offset: base, length: 32, deadline: deadline)
        guard header.count >= 28 else { throw ScanError.notMachO }
        let magic = Self.uint32(header, 0, bigEndian: false)
        let is64: Bool
        switch magic {
        case 0xFEED_FACF: is64 = true
        case 0xFEED_FACE: is64 = false
        default: throw ScanError.notMachO
        }
        let headerSize: UInt64 = is64 ? 32 : 28
        let commandCount = Self.uint32(header, 16, bigEndian: false)
        let commandsSize = Self.uint32(header, 20, bigEndian: false)
        guard commandCount > 0, commandsSize > 0, commandsSize <= Self.maxLoadCommandsSize,
              headerSize + UInt64(commandsSize) <= sliceSize, UInt64(commandCount) * 8 <= UInt64(commandsSize) else {
            throw ScanError.notMachO
        }
        let commands = try read(url, offset: base + headerSize, length: Int(commandsSize), deadline: deadline)
        guard commands.count == Int(commandsSize) else { throw ScanError.notMachO }

        var evidence = CapabilityEvidence()
        var regions: [Region] = []
        var cursor = 0
        for _ in 0..<commandCount {
            guard cursor + 8 <= commands.count else { throw ScanError.notMachO }
            let command = Self.uint32(commands, cursor, bigEndian: false)
            let commandSize = Int(Self.uint32(commands, cursor + 4, bigEndian: false))
            guard commandSize >= 8, commandSize % 4 == 0, cursor + commandSize <= commands.count else {
                throw ScanError.notMachO
            }
            let body = commands.subdata(in: commands.startIndex + cursor ..< commands.startIndex + cursor + commandSize)
            if Self.dylibCommands.contains(command) {
                // dylib_command: cmd, cmdsize, name offset, timestamp, current and compatibility version (24 bytes);
                // the name lies inside the command.
                guard body.count >= 24 else { throw ScanError.notMachO }
                let nameOffset = Int(Self.uint32(body, 8, bigEndian: false))
                guard nameOffset >= 24, nameOffset < body.count else { throw ScanError.notMachO }
                let name = Array(body[(body.startIndex + nameOffset)...])
                if Self.contains(name, Self.ioKitFramework) { evidence.ioKitLinked = true }
                if Self.contains(name, Self.coreFoundationFramework) { evidence.coreFoundationLinked = true }
            } else if command == Self.symtabCommand {
                // symtab_command: symoff, nsyms, stroff, strsize; the tables must lie inside the slice.
                guard body.count >= 24 else { throw ScanError.notMachO }
                let symbolsOffset = UInt64(Self.uint32(body, 8, bigEndian: false))
                let symbolCount = UInt64(Self.uint32(body, 12, bigEndian: false))
                let stringOffset = UInt64(Self.uint32(body, 16, bigEndian: false))
                let stringSize = UInt64(Self.uint32(body, 20, bigEndian: false))
                let symbolsSize = symbolCount * (is64 ? 16 : 12)
                // File-backed tables lie inside the slice and never start at offset 0 (the Mach-O header is there).
                guard symbolsOffset + symbolsSize <= sliceSize, stringOffset + stringSize <= sliceSize,
                      symbolsSize == 0 || symbolsOffset > 0, stringSize == 0 || stringOffset > 0 else {
                    throw ScanError.notMachO
                }
                regions.append(Region(offset: stringOffset, size: stringSize))
            } else if command == Self.segment64Command || command == Self.segmentCommand {
                regions += try Self.stringSections(body, is64: command == Self.segment64Command, sliceSize: sliceSize)
            }
            // Any other (valid, unrelated) command is skipped.
            cursor += commandSize
        }
        // The commands must fill the declared size exactly (no missing or extra command).
        guard cursor == commands.count else { throw ScanError.notMachO }

        for region in regions where region.size > 0 {
            try scanRegion(url, offset: base + region.offset, size: region.size, evidence: &evidence, deadline: deadline)
            if evidence.ioRegistryAccess && evidence.platformSerialString { break }
        }
        return evidence
    }

    // Section types without file contents (`S_ZEROFILL`, `S_GB_ZEROFILL`, `S_THREAD_LOCAL_ZEROFILL`).
    private static let zeroFillTypes: Set<UInt32> = [0x1, 0xC, 0x12]

    /// C-string literal sections (`S_CSTRING_LITERALS`) and `__TEXT,__const` of a segment command. The segment and
    /// every section with file contents must lie inside the slice, else the binary is structurally broken.
    private static func stringSections(_ body: Data, is64: Bool, sliceSize: UInt64) throws -> [Region] {
        let segmentHeader = is64 ? 72 : 56
        let sectionSize = is64 ? 80 : 68
        guard body.count >= segmentHeader else { throw ScanError.notMachO }
        let fileOffset = is64 ? uint64(body, 40, bigEndian: false) : UInt64(uint32(body, 32, bigEndian: false))
        let fileSize = is64 ? uint64(body, 48, bigEndian: false) : UInt64(uint32(body, 36, bigEndian: false))
        guard fileOffset <= sliceSize, fileSize <= sliceSize - fileOffset else { throw ScanError.notMachO }
        let sectionCount = Int(uint32(body, is64 ? 64 : 48, bigEndian: false))
        guard sectionCount <= (body.count - segmentHeader) / sectionSize else { throw ScanError.notMachO }
        var regions: [Region] = []
        for index in 0..<sectionCount {
            let start = segmentHeader + index * sectionSize
            let name = fixedString(body, start, 16)
            let segment = fixedString(body, start + 16, 16)
            let size = is64 ? uint64(body, start + 40, bigEndian: false) : UInt64(uint32(body, start + 36, bigEndian: false))
            let offset = UInt64(uint32(body, start + (is64 ? 48 : 40), bigEndian: false))
            let flags = uint32(body, start + (is64 ? 64 : 56), bigEndian: false)
            let type = flags & 0xFF
            // Only real zero-fill sections have no file contents; every other non-empty section is file-backed and
            // must lie inside the slice, past offset 0 (the Mach-O header is there).
            if zeroFillTypes.contains(type) || size == 0 { continue }
            guard offset > 0, offset <= sliceSize, size <= sliceSize - offset else { throw ScanError.notMachO }
            if type == 0x2 || name == "__cstring" || (segment == "__TEXT" && name == "__const") {
                regions.append(Region(offset: offset, size: size))
            }
        }
        return regions
    }

    private func scanRegion(_ url: URL, offset: UInt64, size: UInt64, evidence: inout CapabilityEvidence,
                            deadline: ContinuousClock.Instant) throws {
        let overlap = ([Self.platformSerialToken] + Self.ioRegistryTokens).map(\.count).max()! - 1
        var position: UInt64 = 0
        var carry: [UInt8] = []
        while position < size {
            let length = Int(min(UInt64(Self.chunkSize), size - position))
            let chunk = try read(url, offset: offset + position, length: length, deadline: deadline)
            guard chunk.count == length else { throw ScanError.unreadable }
            let window = carry + Array(chunk)
            if !evidence.platformSerialString, Self.contains(window, Self.platformSerialToken) {
                evidence.platformSerialString = true
            }
            if !evidence.ioRegistryAccess, Self.ioRegistryTokens.contains(where: { Self.contains(window, $0) }) {
                evidence.ioRegistryAccess = true
            }
            if evidence.platformSerialString && evidence.ioRegistryAccess { return }
            carry = Array(window.suffix(overlap))
            position += UInt64(length)
        }
    }

    // MARK: Hash

    func sha256Short(_ url: URL, deadline: ContinuousClock.Instant) throws -> String {
        let size: UInt64
        do { size = try files.size(url) } catch { throw ScanError.unreadable }
        guard size <= Self.maxBinarySize else { throw ScanError.tooLarge }
        var hasher = SHA256()
        var position: UInt64 = 0
        while position < size {
            let length = Int(min(UInt64(Self.chunkSize * 4), size - position))
            let chunk = try read(url, offset: position, length: length, deadline: deadline)
            guard chunk.count == length else { throw ScanError.unreadable }
            hasher.update(data: chunk)
            position += UInt64(length)
        }
        try checkTime(deadline)
        return String(CIDCalculator.hexLower(Array(hasher.finalize())).prefix(12))
    }

    // MARK: Helpers

    /// Cancellation first (the refresh that started the scan is gone), then the monotonic deadline.
    private func checkTime(_ deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled { throw ScanError.cancelled }
        if clock.now() > deadline { throw ScanError.timeout }
    }

    /// Every read is a chunk boundary: cancellation and the deadline are checked before and after it.
    private func read(_ url: URL, offset: UInt64, length: Int, deadline: ContinuousClock.Instant) throws -> Data {
        try checkTime(deadline)
        let data: Data
        do {
            data = try files.read(url, offset: offset, length: length)
        } catch {
            throw ScanError.unreadable
        }
        try checkTime(deadline)
        return data
    }

    static func uint32(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            let byte = UInt32(data[data.startIndex + offset + index])
            value |= bigEndian ? byte << (8 * UInt32(3 - index)) : byte << (8 * UInt32(index))
        }
        return value
    }

    static func uint64(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt64 {
        let first = UInt64(uint32(data, offset, bigEndian: bigEndian))
        let second = UInt64(uint32(data, offset + 4, bigEndian: bigEndian))
        return bigEndian ? first << 32 | second : second << 32 | first
    }

    private static func fixedString(_ data: Data, _ offset: Int, _ length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let bytes = data[(data.startIndex + offset)..<(data.startIndex + offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, Array(haystack[index..<index + needle.count]) == needle { return true }
            index += 1
        }
        return false
    }
}

// MARK: Raw identity state (§73.3)

/// State of the raw identity; the value itself is never exposed.
enum RawIdentityState: String, Sendable, Equatable, CaseIterable {
    case nonzero
    case zero
    case absent
    case unreadable
}

/// Result of the raw identity probe: the state and a masked CID (first 4 + `…` + last 4 characters).
struct RawIdentityProbe: Sendable, Equatable {
    let state: RawIdentityState
    let cidMasked: String?
}

/// Reads the known identity file locations (§3.1 order) without following links. A file above 64 bytes, or with
/// anything but 16 hex characters (an optional line ending), is `unreadable`; so is a location that cannot be inspected
/// (any error except `ENOENT`). Only a definite absence of every location is `absent`. Never writes.
enum RawIdentityReader {
    static let maxFileSize: UInt64 = 64

    static func probe(home: URL, gamedir: URL?, files: any ReadOnlyFileProbing) -> RawIdentityProbe {
        let candidates = IdentityReader(fileSystem: LocalFileSystem(), homeDirectory: home).candidates(gamedir: gamedir)
        var sawUnreadable = false
        for candidate in candidates {
            switch files.kind(candidate.url) {
            case .missing:
                continue
            case .regularFile where !isPhysical(candidate.url, files: files):
                // A link in a parent folder (`~`, `~/.config`, `~/.local`, the game folder, …) is never followed.
                sawUnreadable = true
            case .regularFile:
                guard let size = try? files.size(candidate.url), size <= maxFileSize,
                      let data = try? files.read(candidate.url, offset: 0, length: Int(size)),
                      let value = parse(data) else {
                    sawUnreadable = true
                    continue
                }
                let raw = Identity.rawID(fileValue: value, location: candidate.location)
                return RawIdentityProbe(state: raw == 0 ? .zero : .nonzero,
                                        cidMasked: mask(CIDCalculator.cid(rawID: raw, address: .localMachine)))
            case .directory, .symbolicLink, .other, .unreadable:
                sawUnreadable = true
            }
        }
        return RawIdentityProbe(state: sawUnreadable ? .unreadable : .absent, cidMasked: nil)
    }

    /// The candidate's physical path equals its written path (system aliases such as `/var` → `/private/var` aside):
    /// no user-controlled link anywhere in it.
    static func isPhysical(_ url: URL, files: any ReadOnlyFileProbing) -> Bool {
        let written = EnginePaths.systemCanonical(url.standardized.path)
        return EnginePaths.systemCanonical(files.resolvedPath(url)) == written
    }

    /// Exactly 16 hex characters, optionally followed by `\n` or `\r\n`.
    static func parse(_ data: Data) -> UInt64? {
        var bytes = Array(data)
        if bytes.last == 0x0A { bytes.removeLast() }
        if bytes.last == 0x0D { bytes.removeLast() }
        guard bytes.count == 16, bytes.allSatisfy(isHex) else { return nil }
        return UInt64(String(decoding: bytes, as: UTF8.self), radix: 16)
    }

    /// `abcd…wxyz`; text shorter than 9 characters is fully hidden.
    static func mask(_ cid: String) -> String {
        guard cid.count > 8 else { return "…" }
        return String(cid.prefix(4)) + "…" + String(cid.suffix(4))
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

// MARK: Decision (§73.3)

enum MacIdentityState: String, Sendable, Equatable, CaseIterable {
    /// Static indicators and a non-zero identity were found; uniqueness itself is not verified.
    case supported
    case unsupported
    case unknown
}

/// The row of the decision table that applies (drives the card text).
enum MacIdentityFinding: String, Sendable, Equatable, CaseIterable {
    /// yes + nonzero: non-zero identity and static hardware-identity indicators (uniqueness not verified).
    case healthy
    /// no + nonzero: the identity is set, but there is no static hardware-identity verification.
    case nonzeroWithoutEvidence
    /// yes + zero.
    case zero
    /// yes + absent.
    case notGenerated
    /// no + zero / absent.
    case unsupported
    /// The engine app was not found.
    case engineNotFound
    /// The engine package could not be verified (read, parse, size, time or path problem).
    case engineUnverifiable
    /// An identity file exists but cannot be accessed or has a wrong format.
    case identityUnreadable
    /// The engine is running: nothing was scanned or read (quit it and refresh).
    case engineRunning
    /// The engine process state could not be verified: nothing was scanned or read.
    case processUnavailable
}

enum MacIdentityAction: String, Sendable, Equatable {
    case none
    /// "Regenerate Identity": opens the engine so it repairs the identity itself.
    case regenerate
    /// "Download Compatible Engine": opens the official release page.
    case downloadEngine
}

enum MacIdentityDecision {
    /// §73.3 decision: process state first, then the package, then the static support × raw identity table. The
    /// engine version is not an input.
    static func decide(process: EngineProcessState = .notRunning, support: StaticSupport, raw: RawIdentityState?,
                       failure: CapabilityFailure? = nil) -> (state: MacIdentityState, finding: MacIdentityFinding,
                                                              action: MacIdentityAction) {
        switch process {
        case .unavailable: return (.unknown, .processUnavailable, .none)
        case .running: return (.unknown, .engineRunning, .none)
        case .notRunning: break
        }
        if support == .unknown {
            return (.unknown, failure == .engineNotFound ? .engineNotFound : .engineUnverifiable, .none)
        }
        guard let raw else { return (.unknown, .identityUnreadable, .none) }
        switch (support, raw) {
        case (_, .unreadable): return (.unknown, .identityUnreadable, .none)
        case (.yes, .nonzero): return (.supported, .healthy, .none)
        case (_, .nonzero): return (.unknown, .nonzeroWithoutEvidence, .downloadEngine)
        case (.yes, .zero): return (.unknown, .zero, .regenerate)
        case (.yes, .absent): return (.unknown, .notGenerated, .regenerate)
        default: return (.unsupported, .unsupported, .downloadEngine)
        }
    }
}

/// Readability of the engine package (§73 B).
enum PackageReadability: String, Sendable, Equatable {
    case readable
    case unverifiable
}

/// Result of one check (card, CLI and diagnostics). It holds no raw identity and no full CID.
struct MacIdentityReport: Sendable, Equatable {
    let state: MacIdentityState
    let finding: MacIdentityFinding
    let action: MacIdentityAction
    /// `unknown` (and no evidence) when the package was not scanned.
    let staticSupport: StaticSupport
    let evidence: CapabilityEvidence
    let capabilityFailure: CapabilityFailure?
    /// `nil` when the identity was not read (engine running, process state unavailable, check cancelled).
    let rawState: RawIdentityState?
    let cidMasked: String?
    let engineApp: URL
    /// `nil` when the package was not hashed (engine running, process state unavailable, unreadable).
    let engineHashShort: String?
    /// Informational only.
    let engineVersion: String?
    let processState: EngineProcessState
    let generatedAt: Date

    var engineRunning: Bool { processState == .running }
    /// The package was scanned (only when the engine is known not to run).
    var staticChecked: Bool { processState == .notRunning }
    /// `nil` when the package was not scanned.
    var packageReadability: PackageReadability? {
        guard staticChecked else { return nil }
        return staticSupport == .unknown ? .unverifiable : .readable
    }
}

/// §73.5.3 refresh order: process state → (only when not running) path → static evidence → raw state → decision →
/// masked CID. A running engine, or a process state that cannot be verified, stops the check before anything is
/// scanned, hashed or read.
struct MacIdentityChecker: Sendable {
    let files: any ReadOnlyFileProbing
    let detector: any GameProcessDetecting
    let now: @Sendable () -> Date
    let clock: MonotonicClock
    let home: URL

    init(files: any ReadOnlyFileProbing, detector: any GameProcessDetecting, home: URL,
         now: @escaping @Sendable () -> Date = { Date() }, clock: MonotonicClock = .system) {
        self.files = files
        self.detector = detector
        self.home = home
        self.now = now
        self.clock = clock
    }

    /// The whole refresh of the app and the CLI: the process state comes first; only when the engine is known to be
    /// closed is the engine override validated (its bundle and `Info.plist` read), the package scanned and the raw
    /// identity read. While it runs, or when its state is unknown, the override is only normalized lexically.
    func check(override: String?, forbiddenRoots: [URL], gamedir: URL?) -> MacIdentityCheck {
        let started = now()
        let process = detector.engineProcessState()
        guard process == .notRunning else {
            let resolution = EnginePathResolution.unvalidated(override: override)
            return MacIdentityCheck(report: skipped(process, engineApp: resolution.app, started: started),
                                    resolution: resolution)
        }
        let resolution = EnginePathResolution.resolve(override: override, files: files, forbiddenRoots: forbiddenRoots)
        return MacIdentityCheck(report: inspect(engineApp: resolution.app, gamedir: gamedir, started: started),
                                resolution: resolution)
    }

    /// The check of a given engine app (no override rules); the process state still comes first.
    func check(engineApp: URL, gamedir: URL?) -> MacIdentityReport {
        let started = now()
        let process = detector.engineProcessState()
        guard process == .notRunning else { return skipped(process, engineApp: engineApp, started: started) }
        return inspect(engineApp: engineApp, gamedir: gamedir, started: started)
    }

    /// Running / unavailable: nothing was inspected, scanned, hashed or read.
    private func skipped(_ process: EngineProcessState, engineApp: URL, started: Date) -> MacIdentityReport {
        let decision = MacIdentityDecision.decide(process: process, support: .unknown, raw: nil)
        return MacIdentityReport(state: decision.state, finding: decision.finding, action: decision.action,
                                 staticSupport: .unknown, evidence: CapabilityEvidence(), capabilityFailure: nil,
                                 rawState: nil, cidMasked: nil, engineApp: engineApp.standardized,
                                 engineHashShort: nil, engineVersion: nil, processState: process,
                                 generatedAt: started)
    }

    /// The engine is known to be closed: package, static evidence, then (unless cancelled) the raw identity.
    private func inspect(engineApp: URL, gamedir: URL?, started: Date) -> MacIdentityReport {
        var capability: CapabilityResult
        switch EnginePaths.inspect(engineApp, files: files) {
        case .failure(let error):
            capability = .unknown(CapabilityFailure(error))
        case .success(let bundle):
            capability = MachOCapabilityScanner(files: files, clock: clock).check(bundle)
        }
        if Task.isCancelled, capability.failure != .cancelled {
            capability = .unknown(.cancelled, version: capability.engineVersion)
        }
        // A cancelled check stops here: the identity files are not read (no raw state, no masked CID).
        let probe: RawIdentityProbe? = capability.failure == .cancelled
            ? nil : RawIdentityReader.probe(home: home, gamedir: gamedir, files: files)
        let decision = MacIdentityDecision.decide(process: .notRunning, support: capability.support, raw: probe?.state,
                                                  failure: capability.failure)
        return MacIdentityReport(state: decision.state, finding: decision.finding, action: decision.action,
                                 staticSupport: capability.support, evidence: capability.evidence,
                                 capabilityFailure: capability.failure, rawState: probe?.state,
                                 cidMasked: probe?.cidMasked, engineApp: engineApp.standardized,
                                 engineHashShort: capability.engineHashShort, engineVersion: capability.engineVersion,
                                 processState: .notRunning, generatedAt: started)
    }
}

/// A report with the engine path resolution it used (validated only when the engine was known to be closed).
struct MacIdentityCheck: Sendable, Equatable {
    let report: MacIdentityReport
    let resolution: EnginePathResolution
}

// MARK: Actions (§73.5.2)

/// The only external page the feature opens (https, fixed).
enum EngineDownloadLink {
    static let url = URL(string: "https://github.com/FWGS/xash3d-fwgs/releases/tag/continuous")!

    static func isAllowed(_ candidate: URL) -> Bool {
        candidate.scheme?.lowercased() == "https" && candidate.absoluteString == url.absoluteString
    }
}

enum MacIdentityRegenerateError: Error, Sendable, Equatable {
    /// The current state does not offer the action (only yes + zero / absent with the engine closed do).
    case notOffered
    /// The engine is running; the user has to quit it first.
    case engineRunning
    /// The engine process state could not be verified; the action stays blocked.
    case processUnavailable
    /// The engine app is no longer usable at its path.
    case engineUnavailable
    /// The launcher failed (technical reason).
    case launchFailed(String)
}

/// "Regenerate Identity": opens the engine (no arguments) so it rebuilds a zero / missing identity from the hardware
/// on its own. The app writes and deletes nothing, never quits the engine and does not refresh afterwards.
struct MacIdentityRegenerator: Sendable {
    let files: any ReadOnlyFileProbing
    let detector: any GameProcessDetecting
    let launcher: any AppLaunching

    func regenerate(report: MacIdentityReport) async throws {
        guard report.action == .regenerate, report.processState == .notRunning else {
            throw MacIdentityRegenerateError.notOffered
        }
        switch detector.engineProcessState() {
        case .running: throw MacIdentityRegenerateError.engineRunning
        case .unavailable: throw MacIdentityRegenerateError.processUnavailable
        case .notRunning: break
        }
        guard case .success(let bundle) = EnginePaths.inspect(report.engineApp, files: files) else {
            throw MacIdentityRegenerateError.engineUnavailable
        }
        do {
            try await launcher.open(app: bundle.app, arguments: [])
        } catch {
            throw MacIdentityRegenerateError.launchFailed(String(describing: error))
        }
    }
}

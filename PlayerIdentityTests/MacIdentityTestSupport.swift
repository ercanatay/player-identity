import CryptoKit
import Foundation
@testable import PlayerIdentity

/// §73 in-memory read-only file system: files, folders and symbolic links by absolute path. Records every read so tests
/// can prove which files were opened. It has no write API (the protocol has none either).
final class FakeFileProbe: ReadOnlyFileProbing, @unchecked Sendable {
    enum Entry {
        case file(Data)
        case directory
        /// A symbolic link whose target is unknown (resolves to a different path).
        case link
        /// A symbolic link to `target` (an alias; `resolvedPath` follows it).
        case alias(String)
        /// A regular file of the given size whose reads fail.
        case unreadable(size: UInt64)
        /// A regular file reporting a huge size (no data behind it).
        case sized(UInt64)
        /// `lstat` fails with something other than `ENOENT` (permission, I/O, stale handle).
        case inaccessible
        /// Neither a file, a folder nor a link (FIFO, socket, device).
        case special
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var readPaths: [String] = []
    private var kindPaths: [String] = []
    private var readHook: (@Sendable (String) -> Void)?
    private var modes: [String: UInt32] = [:]

    init() {}

    var reads: [String] { lock.withLock { readPaths } }
    /// Every path whose kind was asked (proves what was looked at, not only what was read).
    var inspected: [String] { lock.withLock { kindPaths } }

    /// Called after every read (in the reading task), e.g. to cancel it or to move a clock.
    var onRead: (@Sendable (String) -> Void)? {
        get { lock.withLock { readHook } }
        set { lock.withLock { readHook = newValue } }
    }

    func set(_ path: String, _ entry: Entry) {
        lock.withLock {
            entries[path] = entry
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if entries[parent] == nil { entries[parent] = .directory }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    func setFile(_ path: String, _ text: String) { set(path, .file(Data(text.utf8))) }

    /// POSIX permission bits of an item (default `0o755`).
    func setPermissions(_ path: String, _ mode: UInt32) { lock.withLock { modes[path] = mode } }

    /// A bundle at `app` with `Contents/MacOS/xash3d` and optionally `libxash.dylib`.
    func installEngine(at app: String = EnginePaths.defaultApp.path, executable: Data, library: Data? = nil,
                       version: String = "0.21") {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>xash3d</string>\
        <key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>
        """
        set(app + "/Contents/Info.plist", .file(Data(plist.utf8)))
        set(app + "/Contents/MacOS/xash3d", .file(executable))
        if let library { set(app + "/Contents/MacOS/libxash.dylib", .file(library)) }
    }

    private func entry(_ url: URL) -> Entry? {
        lock.withLock { entries[url.standardizedFileURL.path] }
    }

    func kind(_ url: URL) -> ProbedItemKind {
        lock.withLock { kindPaths.append(url.standardizedFileURL.path) }
        switch entry(url) {
        case nil: return .missing
        case .directory?: return .directory
        case .link?, .alias?: return .symbolicLink
        case .file?, .unreadable?, .sized?: return .regularFile
        case .inaccessible?: return .unreadable
        case .special?: return .other
        }
    }

    func permissions(_ url: URL) -> UInt32? {
        let path = url.standardizedFileURL.path
        return lock.withLock { () -> UInt32? in
            switch entries[path] {
            case nil, .inaccessible?: return nil
            default: return modes[path] ?? 0o755
            }
        }
    }

    func size(_ url: URL) throws -> UInt64 {
        switch entry(url) {
        case .file(let data)?: return UInt64(data.count)
        case .unreadable(let size)?: return size
        case .sized(let size)?: return size
        default: throw FileProbeError.unreadable
        }
    }

    func read(_ url: URL, offset: UInt64, length: Int) throws -> Data {
        let path = url.standardizedFileURL.path
        lock.withLock { readPaths.append(path) }
        defer { onRead?(path) }
        guard case .file(let data)? = entry(url) else { throw FileProbeError.unreadable }
        guard offset < UInt64(data.count) else { return Data() }
        let start = Int(offset)
        return data.subdata(in: start..<min(data.count, start + length))
    }

    /// A path with an unknown link anywhere in it resolves to a different path; an alias is followed to its target.
    func resolvedPath(_ url: URL) -> String {
        resolve(url.standardizedFileURL.path, depth: 0)
    }

    private func resolve(_ path: String, depth: Int) -> String {
        guard depth < 16 else { return "/resolved" + path }
        let components = path.split(separator: "/").map(String.init)
        var prefix = ""
        for (index, component) in components.enumerated() {
            prefix += "/" + component
            switch lock.withLock({ entries[prefix] }) {
            case .link?:
                return "/resolved" + path
            case .alias(let target)?:
                let rest = components[(index + 1)...].joined(separator: "/")
                return resolve(rest.isEmpty ? target : target + "/" + rest, depth: depth + 1)
            default:
                continue
            }
        }
        return path
    }
}

/// Wall clock that moves `step` seconds on every reading (it may go backwards); the scan limit must ignore it.
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    let step: TimeInterval

    init(step: TimeInterval) { self.step = step }

    func now() -> Date {
        lock.withLock {
            defer { current = current.addingTimeInterval(step) }
            return current
        }
    }
}

/// Monotonic clock for the 3-second scan limit: moves `step` seconds on every reading, and `advance` simulates a
/// single read that blocked for a while.
final class SteppingMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    let step: Duration

    init(step: Duration = .zero) { self.step = step }

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            defer { current = current.advanced(by: step) }
            return current
        }
    }

    func advance(_ duration: Duration) {
        lock.withLock { current = current.advanced(by: duration) }
    }

    var clock: MonotonicClock { MonotonicClock { self.now() } }
}

extension TempDirectory {
    /// The physical path of the folder (`/var` → `/private/var`): the engine path rules reject links anywhere.
    var physicalURL: URL { URL(fileURLWithPath: LocalFileProbe.physicalPath(url.path), isDirectory: true) }
}

/// Holds a task once it exists (a hook can cancel the parent task of the code it runs in).
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<CLIResult, Never>?

    var task: Task<CLIResult, Never>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Waits (briefly, off the main thread) until the task is stored, then cancels it.
    func cancelWhenReady() {
        for _ in 0..<20_000 where task == nil { usleep(100) }
        task?.cancel()
    }
}

/// `true` exactly once (thread-safe).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.withLock {
            defer { fired = true }
            return !fired
        }
    }
}

/// Builds small synthetic Mach-O files (64-bit thin, optionally inside a fat wrapper) with the chosen K1–K4 evidence.
enum MachOFixture {
    struct Options {
        var ioKit = false
        var coreFoundation = false
        /// Undefined symbols in the symbol string table (K3).
        var symbols: [String] = []
        /// C strings in `__TEXT,__cstring` (K4 / K3 string traces).
        var cStrings: [String] = []
        /// Adds a valid but unrelated load command (`LC_UUID`) that the scanner must skip.
        var unrelatedCommand = false
    }

    static let upstream = Options(ioKit: true, coreFoundation: true,
                                  symbols: ["_IOServiceGetMatchingService", "_IORegistryEntryCreateCFProperty"],
                                  cStrings: ["IOPlatformSerialNumber", "IOPlatformExpertDevice"])
    static let installed = Options(ioKit: false, coreFoundation: false, symbols: ["_SDL_Init", "_malloc"],
                                   cStrings: ["xash3d", "valve"])

    static func thin(_ options: Options) -> Data {
        func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        func le64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        func fixed(_ text: String, _ length: Int) -> [UInt8] {
            Array(text.utf8) + [UInt8](repeating: 0, count: length - text.utf8.count)
        }

        var dylibs: [[UInt8]] = []
        var frameworks: [String] = ["/usr/lib/libSystem.B.dylib"]
        if options.ioKit { frameworks.append("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit") }
        if options.coreFoundation {
            frameworks.append("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation")
        }
        for name in frameworks {
            var nameBytes = Array(name.utf8) + [0]
            while (24 + nameBytes.count) % 8 != 0 { nameBytes.append(0) }
            dylibs.append(le32(0xC) + le32(UInt32(24 + nameBytes.count)) + le32(24) + le32(2) + le32(0x10000) + le32(0x10000)
                          + nameBytes)
        }
        var stringTable: [UInt8] = [0x20, 0]
        for symbol in options.symbols { stringTable += Array(symbol.utf8) + [UInt8(0)] }
        var cStrings: [UInt8] = []
        for text in options.cStrings { cStrings += Array(text.utf8) + [UInt8(0)] }

        if options.unrelatedCommand {
            dylibs.append(le32(0x1B) + le32(24) + [UInt8](repeating: 0xAB, count: 16))
        }
        let symtabSize = 24
        let segmentSize = 72 + 80
        let commandsSize = dylibs.reduce(0) { $0 + $1.count } + symtabSize + segmentSize
        let dataStart = 32 + commandsSize
        let stringOffset = dataStart
        let cStringOffset = stringOffset + stringTable.count

        var bytes: [UInt8] = []
        bytes += le32(0xFEED_FACF) + le32(0x0100_000C) + le32(0) + le32(6)
        bytes += le32(UInt32(dylibs.count + 2)) + le32(UInt32(commandsSize)) + le32(0) + le32(0)
        for dylib in dylibs { bytes += dylib }
        bytes += le32(0x2) + le32(UInt32(symtabSize)) + le32(0) + le32(0) + le32(UInt32(stringOffset))
            + le32(UInt32(stringTable.count))
        bytes += le32(0x19) + le32(UInt32(segmentSize)) + fixed("__TEXT", 16) + le64(0) + le64(0x4000) + le64(0)
            + le64(UInt64(cStringOffset + cStrings.count)) + le32(5) + le32(5) + le32(1) + le32(0)
        bytes += fixed("__cstring", 16) + fixed("__TEXT", 16) + le64(UInt64(cStringOffset)) + le64(UInt64(cStrings.count))
            + le32(UInt32(cStringOffset)) + le32(0) + le32(0) + le32(0) + le32(0x2) + le32(0) + le32(0) + le32(0)
        precondition(bytes.count == dataStart)
        bytes += stringTable
        bytes += cStrings
        return Data(bytes)
    }

    /// Writes a fixture binary with the execute bits set (`0o755`), like a real engine executable.
    static func writeExecutable(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Offset of the first load command `command` in a thin fixture.
    static func commandOffset(_ data: Data, _ command: UInt32) -> Int? {
        let bytes = Array(data)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        var cursor = 32
        for _ in 0..<u32(16) {
            if u32(cursor) == command { return cursor }
            cursor += Int(u32(cursor + 4))
        }
        return nil
    }

    /// The thin fixture with a little-endian 32-bit value replaced at `offset` (structural corruption tests).
    static func patched(_ data: Data, at offset: Int, _ value: UInt32) -> Data {
        var bytes = Array(data)
        withUnsafeBytes(of: value.littleEndian) { for (index, byte) in $0.enumerated() { bytes[offset + index] = byte } }
        return Data(bytes)
    }

    /// A fat (universal) file holding the given thin slices.
    static func fat(_ slices: [Data]) -> Data {
        func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }
        var header = be32(0xCAFE_BABE) + be32(UInt32(slices.count))
        var offset = 4096
        var body: [UInt8] = []
        for slice in slices {
            header += be32(0x0100_000C) + be32(0) + be32(UInt32(offset)) + be32(UInt32(slice.count)) + be32(12)
            let padding = offset - 4096 - body.count
            body += [UInt8](repeating: 0, count: padding) + Array(slice)
            offset += slice.count
            offset = (offset + 4095) / 4096 * 4096
        }
        return Data(header + [UInt8](repeating: 0, count: 4096 - header.count) + body)
    }
}

enum MacIdentityFixture {
    static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    /// Identity file contents (home mask 0x10331C2DCE4C91DB): raw zero and a non-zero raw identity.
    static let zeroFile = "10331C2DCE4C91DB\n"
    static let nonzeroFile = "00000000000000AB\n"
    static let nonzeroRaw: UInt64 = 0x1033_1C2D_CE4C_91DB ^ 0xAB
    static var nonzeroRawHex: String { HexID.format(nonzeroRaw) }
    static var nonzeroCID: String { CIDCalculator.cid(rawID: nonzeroRaw, address: .localMachine) }
    static var zeroCID: String { CIDCalculator.cid(rawID: 0, address: .localMachine) }

    static func sha256(_ url: URL) throws -> String {
        CIDCalculator.hexLower(Array(SHA256.hash(data: try Data(contentsOf: url))))
    }

    /// SHA-256 of every regular file under `root` (relative path → hash).
    static func tree(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[String(url.path.dropFirst(root.path.count))] = try sha256(url)
        }
        return result
    }
}

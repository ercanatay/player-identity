import CryptoKit
import Foundation

// MARK: - Errors (§27.4)

enum UpdateError: Error, Sendable, Equatable {
    case feedUnavailable
    /// Not HTTPS (HTTP is only accepted for 127.0.0.1).
    case insecureURL
    case missingAsset
    case sameVersion
    case downloadFailed
    case sizeMismatch(expected: Int, actual: Int)
    case checksumMissing
    case checksumMismatch
    case unzipFailed
    case appMissing
    case signatureInvalid
    case teamMismatch(found: String?)
    case bundleMismatch(found: String?)
    case versionMismatch(found: String?)
    /// Gatekeeper (`spctl -a -t exec`) did not accept the app (not notarized, revoked, or no valid signature).
    case gatekeeperRejected
    /// A system tool (`tool`) ran longer than its time limit and was stopped; nothing was installed.
    case processTimedOut(tool: String)
    /// The install location is not writable and administrator approval is not available/declined.
    case notWritable
    /// The administrator prompt was cancelled (`-128`): nothing was moved.
    case cancelledByUser
    /// The administrator prompt could not be shown (`osascript` did not start); nothing was moved.
    case adminPromptFailed
    /// Replacing the app failed; `rolledBack` tells whether the previous app is back in place,
    /// otherwise it is still at `backup`.
    case installFailed(rolledBack: Bool, backup: URL?)
    case cancelled
}

// MARK: - Origin check (§58.1)

/// What `spctl -a -vv -t exec` said about the downloaded app.
enum GatekeeperAssessment: Sendable, Equatable {
    /// Exit 0, an `accepted` line and the notarized Developer ID source.
    case accepted
    /// A verdict that is not a full acceptance (a `rejected` line, exit 3, or exit 0 without the notarized source).
    case rejected
    /// `spctl` could not assess the app (it could not be started, or it failed without a verdict, e.g. in a
    /// restricted environment). `reason` is a short code for the diagnostics log.
    case unavailable(reason: String)
}

/// How the origin of a verified release was confirmed (§58.1).
enum UpdateVerification: Sendable, Equatable {
    /// Gatekeeper accepted the notarized Developer ID app.
    case gatekeeper
    /// `spctl` was not available: `codesign --verify --deep --strict`, the TeamIdentifier, the Identifier and the
    /// version (all checked before `spctl`) are the verification. Written to the diagnostics log as `spctlUnavailable`.
    case codesignFallback(reason: String)

    var spctlUnavailable: Bool {
        if case .codesignFallback = self { return true }
        return false
    }
}

// MARK: - Locations

extension AppPaths {
    /// `~/Library/Application Support/tr.ercanatay.playeridentity/updates`
    var updatesDirectory: URL { snapshotFile.deletingLastPathComponent().appendingPathComponent("updates", isDirectory: true) }
    var updateDownloads: URL { updatesDirectory.appendingPathComponent("downloads", isDirectory: true) }
    var updateStaging: URL { updatesDirectory.appendingPathComponent("staging", isDirectory: true) }
    /// Previous app versions: `updates/backup/PlayerIdentity-<old>.app` (§27.1/5).
    var updateAppBackups: URL { updatesDirectory.appendingPathComponent("backup", isDirectory: true) }
    /// Data backups before a version change: `updates/backups/data-<from>-to-<to>-<ts>/` (§28.2/3).
    var dataBackups: URL { updatesDirectory.appendingPathComponent("backups", isDirectory: true) }
}

// MARK: - Commands (fixed argv allowlist)

/// Absolute file path used in an update command. Paths come from the app's own locations, never from user input;
/// they are still validated so they cannot break out of an argument (no quotes, backslashes or control characters).
struct UpdatePath: Sendable, Equatable {
    let value: String

    init?(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard url.isFileURL, path.hasPrefix("/"), !path.contains(".."),
              !path.unicodeScalars.contains(where: { $0 == "\"" || $0 == "'" || $0 == "\\" || $0 == "`" || $0 == "$"
                  || $0.properties.generalCategory == .control }) else { return nil }
        value = path
    }
}

enum UpdateCommand: Sendable, Equatable {
    /// `/usr/bin/ditto -x -k <zip> <dir>`
    case unzip(UpdatePath, into: UpdatePath)
    /// `/usr/bin/codesign --verify --deep --strict <app>`
    case verifySignature(UpdatePath)
    /// `/usr/bin/codesign -dvv <app>` (TeamIdentifier, Identifier on stderr)
    case signingInfo(UpdatePath)
    /// `/usr/sbin/spctl -a -vv -t exec <app>`
    case assess(UpdatePath)
    /// `/usr/bin/xattr -dr com.apple.quarantine <app>`
    case removeQuarantine(UpdatePath)
    /// `/usr/bin/open -n <app>`
    case open(UpdatePath)
    /// One administrator prompt: move the current app to the backup, then the new app into place; on failure the
    /// backup is moved back. `/usr/bin/osascript -e 'do shell script "…" with administrator privileges'`.
    case adminReplace(current: UpdatePath, backup: UpdatePath, staged: UpdatePath)

    var argv: [String] {
        switch self {
        case .unzip(let zip, let dir): return ["/usr/bin/ditto", "-x", "-k", zip.value, dir.value]
        case .verifySignature(let app): return ["/usr/bin/codesign", "--verify", "--deep", "--strict", app.value]
        case .signingInfo(let app): return ["/usr/bin/codesign", "-dvv", app.value]
        case .assess(let app): return ["/usr/sbin/spctl", "-a", "-vv", "-t", "exec", app.value]
        case .removeQuarantine(let app): return ["/usr/bin/xattr", "-dr", "com.apple.quarantine", app.value]
        case .open(let app): return ["/usr/bin/open", "-n", app.value]
        case .adminReplace(let current, let backup, let staged):
            return ["/usr/bin/osascript", "-e", Self.adminScript(current: current, backup: backup, staged: staged)]
        }
    }

    /// Time limit of every tool run (the download is not a process and has no such limit).
    static let defaultTimeout: TimeInterval = 120

    /// `nil` for the administrator prompt: it waits for the user, and stopping it halfway could leave the app moved.
    var timeout: TimeInterval? {
        if case .adminReplace = self { return nil }
        return Self.defaultTimeout
    }

    /// Only the steps before anything is replaced (unpack + verification) stop when the install is cancelled;
    /// replacing, quarantine removal and relaunch always run to their end.
    var isCancellable: Bool {
        switch self {
        case .unzip, .verifySignature, .signingInfo, .assess: return true
        case .removeQuarantine, .open, .adminReplace: return false
        }
    }

    /// Last path component of the tool (`codesign`, `spctl`, …) for error texts.
    var toolName: String { URL(fileURLWithPath: argv[0]).lastPathComponent }

    static func adminScript(current: UpdatePath, backup: UpdatePath, staged: UpdatePath) -> String {
        let shell = "/bin/rm -rf '\(backup.value)' && /bin/mv '\(current.value)' '\(backup.value)' && "
            + "( /bin/mv '\(staged.value)' '\(current.value)' || ( /bin/mv '\(backup.value)' '\(current.value)'; exit 1 ) )"
        return "do shell script \"\(shell)\" with administrator privileges"
    }
}

enum UpdateCommandAllowlist {
    /// Only argv arrays produced by `UpdateCommand` pass (re-validated element by element).
    static func isAllowed(_ argv: [String]) -> Bool {
        func path(_ text: String) -> Bool { UpdatePath(URL(fileURLWithPath: text))?.value == text }
        switch argv.first {
        case "/usr/bin/ditto"?:
            return argv.count == 5 && argv[1] == "-x" && argv[2] == "-k" && path(argv[3]) && path(argv[4])
        case "/usr/bin/codesign"?:
            if argv.count == 5 { return argv[1...3] == ["--verify", "--deep", "--strict"] && path(argv[4]) }
            return argv.count == 3 && argv[1] == "-dvv" && path(argv[2])
        case "/usr/sbin/spctl"?:
            return argv.count == 6 && argv[1...4] == ["-a", "-vv", "-t", "exec"] && path(argv[5])
        case "/usr/bin/xattr"?:
            return argv.count == 4 && argv[1] == "-dr" && argv[2] == "com.apple.quarantine" && path(argv[3])
        case "/usr/bin/open"?:
            return argv.count == 3 && argv[1] == "-n" && path(argv[2])
        case "/usr/bin/osascript"?:
            guard argv.count == 3, argv[1] == "-e" else { return false }
            let q = "'([^'\"\\\\`$]+)'"
            let pattern = "^do shell script \"/bin/rm -rf \(q) && /bin/mv \(q) \(q) && \\( /bin/mv \(q) \(q) \\|\\| \\( /bin/mv \(q) \(q); exit 1 \\) \\)\" with administrator privileges$"
            return argv[2].range(of: pattern, options: .regularExpression) != nil
        default:
            return false
        }
    }
}

protocol UpdateCommandRunning: Sendable {
    func run(_ command: UpdateCommand) async throws -> CommandOutput
}

/// Real runner: allowlisted argv only, executed directly by `Process` (no shell, except the fixed admin script).
/// Every run has the command's time limit (`processTimedOut`); the verification steps stop when the task is
/// cancelled (`CancellationError`, reported as `cancelled`).
struct ProcessUpdateCommandRunner: UpdateCommandRunning {
    init() {}

    func run(_ command: UpdateCommand) async throws -> CommandOutput {
        let argv = command.argv
        guard UpdateCommandAllowlist.isAllowed(argv) else { throw CommandError.notAllowed }
        do {
            return try await SystemProcess.run(argv, timeout: command.timeout, cancellable: command.isCancellable)
        } catch {
            throw Self.mapped(error, command: command)
        }
    }

    /// `CommandError.timedOut` → `UpdateError.processTimedOut`, `CommandError.cancelled` → `CancellationError`.
    static func mapped(_ error: any Error, command: UpdateCommand) -> any Error {
        switch error as? CommandError {
        case .timedOut?: return UpdateError.processTimedOut(tool: command.toolName)
        case .cancelled?: return CancellationError()
        default: return error
        }
    }
}

enum SystemProcess {
    /// Runs `argv[0]` with the remaining arguments in its own process group; stdout and stderr are combined unless
    /// `includeStandardError` is `false` (stderr is then discarded). `input` is written to stdin (otherwise stdin is
    /// `/dev/null`). Never blocks the caller's thread.
    ///
    /// A child that exits normally returns its exit status (callers treat non-zero as failure). A child that ends
    /// through a signal throws `CommandError.signaled`. `timeout`: after this many seconds the process group gets
    /// `SIGTERM`, then `SIGKILL` after a short grace, and `CommandError.timedOut` is thrown. `cancellable`: cancelling
    /// the waiting task does the same and throws `CommandError.cancelled`. In every case the call returns only after
    /// `waitpid` reaped exactly this child; a failing `waitpid` is `CommandError.waitFailed`, a failing spawn step is
    /// `launchFailed`, a failing group signal is `signalFailed` (AC-E75, AC-E97–E97b).
    static func run(_ argv: [String], timeout: TimeInterval? = nil, cancellable: Bool = false,
                    includeStandardError: Bool = true, input: Data? = nil,
                    system: ProcessSystemCalls = .live) async throws -> CommandOutput {
        let running = RunningProcess(argv, includeStandardError: includeStandardError, input: input, system: system)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                running.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            if cancellable { running.stop(.cancelled) }
        }
    }

    /// Grace between `SIGTERM` and `SIGKILL` of a stopped process group.
    static let killGrace: TimeInterval = 2
}

/// The spawn setup steps whose failure is reported (never ignored).
enum ProcessSpawnStep: String, Sendable, CaseIterable {
    case fileActionsInit
    case attributesInit
    case stdin
    case stdout
    case stderr
    case signalDefaults
    case signalMask
    case processGroup
    case flags
}

/// The system calls of `SystemProcess` (tests inject failures; production uses `.live`).
struct ProcessSystemCalls: Sendable {
    /// `pipe(2)`: read and write ends, or `nil` on failure.
    var makePipe: @Sendable () -> (read: Int32, write: Int32)?
    /// Extra failure for a setup step (`0`: none). Production never injects.
    var injectSetupFailure: @Sendable (ProcessSpawnStep) -> Int32
    /// `posix_spawn`: (error, pid).
    var spawn: @Sendable (_ path: String, _ actions: UnsafePointer<posix_spawn_file_actions_t?>,
                          _ attributes: UnsafePointer<posix_spawnattr_t?>,
                          _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
                          _ environment: UnsafePointer<UnsafeMutablePointer<CChar>?>) -> (error: Int32, pid: pid_t)
    /// `waitpid(pid, &status, 0)` retried on `EINTR`: (returned pid, status, errno).
    var wait: @Sendable (pid_t) -> (pid: pid_t, status: Int32, error: Int32)
    /// `kill(2)`: `0` or errno.
    var signal: @Sendable (pid_t, Int32) -> Int32

    static let live = ProcessSystemCalls(
        makePipe: {
            var ends: [Int32] = [-1, -1]
            return pipe(&ends) == 0 ? (ends[0], ends[1]) : nil
        },
        injectSetupFailure: { _ in 0 },
        spawn: { path, actions, attributes, argv, environment in
            var child: pid_t = 0
            let error = posix_spawn(&child, path, actions, attributes,
                                    UnsafeMutablePointer(mutating: argv), UnsafeMutablePointer(mutating: environment))
            return (error, child)
        },
        wait: { pid in
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, 0)
                if result < 0 && errno == EINTR { continue }
                return (result, status, result < 0 ? errno : 0)
            }
        },
        signal: { pid, signal in kill(pid, signal) == 0 ? 0 : errno }
    )
}

/// Output collected by the reader threads.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var readError = false
    private var writeError = false

    var data: Data { lock.withLock { buffer } }
    var failedRead: Bool { lock.withLock { readError } }
    var failedWrite: Bool { lock.withLock { writeError } }

    func append(_ data: Data) { lock.withLock { buffer.append(data) } }
    func markReadFailure() { lock.withLock { readError = true } }
    func markWriteFailure() { lock.withLock { writeError = true } }
}

/// One child process spawned with `posix_spawn` into its own process group. Output is read on background threads;
/// a waiter thread reaps the child with `waitpid`. The continuation is resumed exactly once and only after the child
/// was reaped: with the output, or with the stop reason (time limit / cancellation) after `SIGTERM` → wait →
/// `SIGKILL` → wait of the whole group.
private final class RunningProcess: @unchecked Sendable {
    /// Guards the state; also signalled when the child is reaped (the timer threads wait on it). Timers run on their
    /// own threads, never on the shared dispatch pool, so a busy or exhausted pool cannot delay a time limit or the
    /// `SIGKILL` escalation.
    private let lock = NSCondition()
    private let argv: [String]
    private let includeStandardError: Bool
    private let input: Data?
    private let system: ProcessSystemCalls
    private var continuation: CheckedContinuation<CommandOutput, any Error>?
    private var pid: pid_t = 0
    private var stopReason: CommandError?
    private var signalFailure = false
    private var reaped = false

    init(_ argv: [String], includeStandardError: Bool, input: Data?, system: ProcessSystemCalls) {
        self.argv = argv
        self.includeStandardError = includeStandardError
        self.input = input
        self.system = system
    }

    func start(timeout: TimeInterval?, continuation: CheckedContinuation<CommandOutput, any Error>) {
        let early: CommandError? = lock.withLock {
            if let stopReason { return stopReason }
            self.continuation = continuation
            return nil
        }
        if let early {   // cancelled before it started: nothing is launched
            continuation.resume(throwing: early)
            return
        }
        guard !argv.isEmpty, let spawned = spawn() else {
            resume(.failure(CommandError.launchFailed))
            return
        }
        let stoppedWhileSpawning = lock.withLock { () -> Bool in
            pid = spawned.pid
            return stopReason != nil
        }
        if stoppedWhileSpawning { signalGroup(SIGTERM, scheduleKill: true) }
        if let timeout {
            let deadline = Date().addingTimeInterval(max(timeout, 0))
            Thread.detachNewThread { [self] in
                if !waitForReap(until: deadline) { stop(.timedOut) }
            }
        }

        let readers = DispatchGroup()
        let collected = OutputBuffer()
        for descriptor in spawned.outputs {
            readers.enter()
            Thread.detachNewThread {
                let result = Self.readAll(descriptor)
                collected.append(result.data)
                if !result.complete { collected.markReadFailure() }
                readers.leave()
            }
        }
        if let writer = spawned.input {
            let data = input ?? Data()
            readers.enter()
            Thread.detachNewThread {
                if !Self.writeAll(data, to: writer) { collected.markWriteFailure() }
                readers.leave()
            }
        }
        let child = spawned.pid
        let system = self.system
        Thread.detachNewThread { [self] in
            let waited = system.wait(child)
            // Only a reap of exactly this child counts; ECHILD, any other error or another pid is a failure.
            let reapedChild = waited.pid == child && waited.error == 0
            let state: (reason: CommandError?, signalFailed: Bool) = lock.withLock {
                reaped = true
                lock.broadcast()
                return (stopReason, signalFailure)
            }
            // A stopped run also removes anything left in its process group.
            if state.reason != nil { _ = system.signal(-child, SIGKILL) }
            readers.wait()
            let output = String(decoding: collected.data, as: UTF8.self)
            let termination = waited.status & 0x7F
            let exitStatus = (waited.status >> 8) & 0xFF
            if !reapedChild {
                resume(.failure(CommandError.waitFailed))
            } else if state.signalFailed {
                resume(.failure(CommandError.signalFailed))
            } else if let reason = state.reason {
                resume(.failure(reason))
            } else if termination != 0 {
                resume(.failure(CommandError.signaled(termination)))
            } else if collected.failedRead || (collected.failedWrite && exitStatus == 0) {
                resume(.failure(CommandError.ioFailed))
            } else {
                resume(.success(CommandOutput(status: exitStatus, output: output)))
            }
        }
    }

    /// Records the stop reason and signals the group; the waiting task is resumed by the waiter after the reap.
    func stop(_ reason: CommandError) {
        // Not started yet (no pid): `start` throws the reason without launching anything, or signals the group
        // itself when the stop came while it was spawning.
        let signal: Bool = lock.withLock {
            guard !reaped, stopReason == nil else { return false }
            stopReason = reason
            return pid > 0
        }
        if signal { signalGroup(SIGTERM, scheduleKill: true) }
    }

    /// Signals the process group. A failure other than "no such process" is recorded (the run then ends with
    /// `signalFailed`) and the child itself is signalled directly, so it still ends and is reaped.
    private func signalGroup(_ signal: Int32, scheduleKill: Bool) {
        let group = lock.withLock { pid }
        guard group > 0 else { return }
        send(signal, to: group)
        if scheduleKill {
            let deadline = Date().addingTimeInterval(SystemProcess.killGrace)
            Thread.detachNewThread { [self] in
                if !waitForReap(until: deadline) { send(SIGKILL, to: group) }
            }
        }
    }

    private func send(_ signal: Int32, to group: pid_t) {
        let error = system.signal(-group, signal)
        guard error != 0, error != ESRCH else { return }
        lock.withLock { signalFailure = true }
        _ = system.signal(group, signal)
    }

    /// `true` as soon as the child is reaped; `false` when `deadline` passes first.
    private func waitForReap(until deadline: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while !reaped {
            if !lock.wait(until: deadline) { return reaped }
        }
        return true
    }

    private func resume(_ result: Result<CommandOutput, any Error>) {
        let pending: CheckedContinuation<CommandOutput, any Error>? = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }

    private struct Spawned {
        let pid: pid_t
        let outputs: [Int32]
        let input: Int32?
    }

    /// `posix_spawn` with its own process group, only fds 0–2 inherited, default signal handling. Every setup step
    /// is checked; any failure closes what was opened and returns `nil` (reported as `launchFailed`).
    private func spawn() -> Spawned? {
        guard let output = system.makePipe() else { return nil }
        var inputEnds: (read: Int32, write: Int32)?
        if input != nil {
            guard let ends = system.makePipe() else {
                close(output.read); close(output.write)
                return nil
            }
            inputEnds = ends
        }
        func closeAll() {
            close(output.read); close(output.write)
            if let inputEnds { close(inputEnds.read); close(inputEnds.write) }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func step(_ name: ProcessSpawnStep, _ result: Int32) -> Bool {
            result == 0 && system.injectSetupFailure(name) == 0
        }
        guard step(.fileActionsInit, posix_spawn_file_actions_init(&actions)) else { closeAll(); return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard step(.attributesInit, posix_spawnattr_init(&attributes)) else { closeAll(); return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        let stdinResult = inputEnds.map { posix_spawn_file_actions_adddup2(&actions, $0.read, 0) }
            ?? posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let stderrResult = includeStandardError ? posix_spawn_file_actions_adddup2(&actions, output.write, 2)
            : posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                          | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard step(.stdin, stdinResult),
              step(.stdout, posix_spawn_file_actions_adddup2(&actions, output.write, 1)),
              step(.stderr, stderrResult),
              step(.signalDefaults, posix_spawnattr_setsigdefault(&attributes, &defaults)),
              step(.signalMask, posix_spawnattr_setsigmask(&attributes, &mask)),
              step(.processGroup, posix_spawnattr_setpgroup(&attributes, 0)),
              step(.flags, posix_spawnattr_setflags(&attributes, flags)) else {
            closeAll()
            return nil
        }

        let cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnvironment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in cArguments + cEnvironment { free(pointer) } }
        let spawned = cArguments.withUnsafeBufferPointer { argvPointer in
            cEnvironment.withUnsafeBufferPointer { environmentPointer in
                system.spawn(argv[0], &actions, &attributes, argvPointer.baseAddress!, environmentPointer.baseAddress!)
            }
        }
        close(output.write)
        if let inputEnds { close(inputEnds.read) }
        guard spawned.error == 0, spawned.pid > 0 else {
            close(output.read)
            if let inputEnds { close(inputEnds.write) }
            return nil
        }
        if let inputEnds { _ = fcntl(inputEnds.write, F_SETNOSIGPIPE, 1) }
        return Spawned(pid: spawned.pid, outputs: [output.read], input: inputEnds?.write)
    }

    /// Reads to end of file; `complete == false` when a read failed.
    private static func readAll(_ descriptor: Int32) -> (data: Data, complete: Bool) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var complete = true
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 { complete = false }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        close(descriptor)
        return (data, complete)
    }

    /// Writes everything; `false` when the child stopped reading (closed stdin or exited) or a write failed.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        let complete = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
        close(descriptor)
        return complete
    }
}

// MARK: - Dependencies (DI)

protocol UpdateDownloading: Sendable {
    /// Downloads `url` to `destination`; `progress` receives the fraction (0…1) when the size is known.
    func download(_ url: URL, to destination: URL, expectedSize: Int,
                  progress: @escaping @Sendable (Double) async -> Void) async throws
}

/// `URLSession` streaming download (HTTPS enforced by the installer before this is called).
struct URLSessionUpdateDownloader: UpdateDownloading {
    init() {}

    func download(_ url: URL, to destination: URL, expectedSize: Int,
                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.downloadFailed
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if expectedSize > 0 { await progress(min(1, Double(written) / Double(expectedSize))) }
                // Downloads larger than the declared asset size are cut off early.
                if expectedSize > 0, written > expectedSize { throw UpdateError.sizeMismatch(expected: expectedSize, actual: written) }
            }
        }
        try handle.write(contentsOf: buffer)
        await progress(1)
    }
}

/// File operations of the installer (real `FileManager` by default; tests inject failures).
protocol UpdateFileManaging: Sendable {
    func exists(_ url: URL) -> Bool
    func size(_ url: URL) -> Int?
    func data(_ url: URL) throws -> Data
    func isWritable(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
    func contents(_ url: URL) throws -> [URL]
}

struct LocalUpdateFileManager: UpdateFileManaging {
    init() {}

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func size(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func isWritable(_ url: URL) -> Bool { FileManager.default.isWritableFile(atPath: url.path) }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func move(_ source: URL, to destination: URL) throws { try FileManager.default.moveItem(at: source, to: destination) }

    func remove(_ url: URL) throws {
        if exists(url) { try FileManager.default.removeItem(at: url) }
    }

    func contents(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

/// Starts the new app and quits the running one (§27.1/5). The app passes the real termination.
protocol AppRelaunching: Sendable {
    func relaunch(_ app: URL) async throws
}

/// Default when no relauncher is injected: reports failure, so an install is rolled back instead of leaving the
/// old process running a replaced bundle.
struct UnavailableRelauncher: AppRelaunching {
    init() {}
    func relaunch(_ app: URL) async throws { throw UpdateError.installFailed(rolledBack: false, backup: nil) }
}

struct OpenAndTerminateRelauncher: AppRelaunching {
    let runner: any UpdateCommandRunning
    let terminate: @Sendable () async -> Void

    func relaunch(_ app: URL) async throws {
        guard let path = UpdatePath(app), try await runner.run(.open(path)).status == 0 else {
            throw UpdateError.installFailed(rolledBack: false, backup: nil)
        }
        await terminate()
    }
}

// MARK: - Installer (§27.1, §28.2/4)

enum InstallPhase: Sendable, Equatable {
    case downloading(Double)
    case verifying
    case installing
    case relaunching
}

/// Downloads, verifies and installs a release (upgrade or downgrade). Every external effect is injected.
struct UpdateInstaller: Sendable {
    static let teamID = "GJ3Y762WQ9"
    static let bundleID = "tr.ercanatay.playeridentity"

    let paths: AppPaths
    /// The running app bundle (`Bundle.main.bundleURL` in the app).
    let installedApp: URL
    let currentVersion: String
    let downloader: any UpdateDownloading
    let fileManager: any UpdateFileManaging
    let runner: any UpdateCommandRunning
    let relauncher: any AppRelaunching
    /// Use the one-time administrator prompt when the install location is not writable (§27.4).
    var allowAdministratorPrompt = true

    struct Result: Sendable, Equatable {
        let installed: URL
        let backup: URL
        let version: String
        /// §58.1: how the origin of the new app was confirmed.
        var verification: UpdateVerification = .gatekeeper
    }

    /// HTTPS only; plain HTTP is accepted for 127.0.0.1 (tests).
    static func isAllowedURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https"?: return url.host != nil
        case "http"?: return url.host == "127.0.0.1"
        default: return false
        }
    }

    /// A downloaded and fully verified release, staged and ready to replace the running app.
    struct Prepared: Sendable, Equatable {
        let release: AppRelease
        let staged: URL
        fileprivate let files: [URL]
        /// §58.1: how the origin of the staged app was confirmed.
        fileprivate(set) var verification: UpdateVerification = .gatekeeper
    }

    func install(_ release: AppRelease,
                 progress: @escaping @Sendable (InstallPhase) async -> Void = { _ in }) async throws -> Result {
        let prepared = try await prepare(release, progress: progress)
        return try await finish(prepared, progress: progress)
    }

    /// Download + size + SHA-256 + unzip + signature + team + bundle + version (§27.1/3–4). Nothing is replaced;
    /// on any failure or cancellation the downloaded files are deleted.
    func prepare(_ release: AppRelease,
                 progress: @escaping @Sendable (InstallPhase) async -> Void = { _ in }) async throws -> Prepared {
        guard let zipAsset = release.zip, let sumsAsset = release.sums else { throw UpdateError.missingAsset }
        guard release.version != SemanticVersion(currentVersion) else { throw UpdateError.sameVersion }
        guard Self.isAllowedURL(zipAsset.downloadURL), Self.isAllowedURL(sumsAsset.downloadURL) else {
            throw UpdateError.insecureURL
        }

        let downloads = paths.updateDownloads
        let staging = paths.updateStaging.appendingPathComponent(release.versionString, isDirectory: true)
        let zip = downloads.appendingPathComponent(zipAsset.name, isDirectory: false)
        let sums = downloads.appendingPathComponent(sumsAsset.name, isDirectory: false)
        var prepared = Prepared(release: release,
                                staged: staging.appendingPathComponent(installedApp.lastPathComponent, isDirectory: true),
                                files: [zip, sums, staging])
        do {
            // Download + size + SHA-256
            try fileManager.createDirectory(downloads)
            try await download(sumsAsset, to: sums, progress: { _ in })
            try await download(zipAsset, to: zip, progress: { await progress(.downloading($0)) })
            try Task.checkCancellation()
            await progress(.verifying)
            guard let expected = SHA256Sums.parse(String(decoding: try fileManager.data(sums), as: UTF8.self))[zipAsset.name] else {
                throw UpdateError.checksumMissing
            }
            guard Self.sha256(try fileManager.data(zip)) == expected else { throw UpdateError.checksumMismatch }

            // Unpack + signature + team + bundle + version
            try? fileManager.remove(staging)
            try fileManager.createDirectory(staging)
            guard let zipPath = UpdatePath(zip), let stagingPath = UpdatePath(staging),
                  try await runner.run(.unzip(zipPath, into: stagingPath)).status == 0 else { throw UpdateError.unzipFailed }
            guard fileManager.exists(prepared.staged), let stagedPath = UpdatePath(prepared.staged) else {
                throw UpdateError.appMissing
            }
            prepared.verification = try await verify(staged: stagedPath, appURL: prepared.staged, release: release)
            try Task.checkCancellation()
        } catch {
            discard(prepared)
            if error is CancellationError { throw UpdateError.cancelled }
            throw error
        }
        return prepared
    }

    /// Removes the downloaded and staged files of a prepared release.
    func discard(_ prepared: Prepared) {
        for url in prepared.files { try? fileManager.remove(url) }
    }

    /// Replace + quarantine removal + relaunch (§27.1/5–6). Not cancellable: it completes or rolls back.
    func finish(_ prepared: Prepared,
                progress: @escaping @Sendable (InstallPhase) async -> Void = { _ in }) async throws -> Result {
        // Every failure before the replacement removes the downloaded and staged files (nothing is left behind in
        // `updates/downloads` or `updates/staging`).
        guard fileManager.exists(prepared.staged) else {
            discard(prepared)
            throw UpdateError.appMissing
        }
        await progress(.installing)
        let backup = paths.updateAppBackups.appendingPathComponent("PlayerIdentity-\(currentVersion).app", isDirectory: true)
        do {
            try fileManager.createDirectory(paths.updateAppBackups)
            try await replace(staged: prepared.staged, backup: backup)
        } catch {
            discard(prepared)
            throw error
        }
        if let target = UpdatePath(installedApp) {
            _ = try? await runner.run(.removeQuarantine(target))
        }
        discard(prepared)

        // Relaunch; if the new app cannot be opened, the previous one is put back (§27.1/6).
        await progress(.relaunching)
        do {
            try await relauncher.relaunch(installedApp)
        } catch {
            throw rollback(backup: backup)
        }
        return Result(installed: installedApp, backup: backup, version: prepared.release.versionString,
                      verification: prepared.verification)
    }

    private func download(_ asset: ReleaseAsset, to destination: URL,
                          progress: @escaping @Sendable (Double) async -> Void) async throws {
        try? fileManager.remove(destination)
        do {
            try await downloader.download(asset.downloadURL, to: destination, expectedSize: asset.size, progress: progress)
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateError.downloadFailed
        }
        let actual = fileManager.size(destination) ?? -1
        guard actual == asset.size else { throw UpdateError.sizeMismatch(expected: asset.size, actual: actual) }
    }

    /// Signature, team, bundle and version first, then Gatekeeper (§58.1): `rejected` is never accepted; only when
    /// `spctl` cannot assess the app at all do the codesign checks above stand on their own (`codesignFallback`).
    private func verify(staged path: UpdatePath, appURL: URL, release: AppRelease) async throws -> UpdateVerification {
        guard try await runner.run(.verifySignature(path)).status == 0 else { throw UpdateError.signatureInvalid }
        let info = try await runner.run(.signingInfo(path))
        guard info.status == 0 else { throw UpdateError.signatureInvalid }
        let fields = Self.signingFields(info.output)
        guard fields["TeamIdentifier"] == Self.teamID else { throw UpdateError.teamMismatch(found: fields["TeamIdentifier"]) }
        let plist = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let dictionary = (try? fileManager.data(plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let bundleID = dictionary["CFBundleIdentifier"] as? String
        guard bundleID == Self.bundleID, fields["Identifier"] == Self.bundleID else {
            throw UpdateError.bundleMismatch(found: bundleID ?? fields["Identifier"])
        }
        let version = dictionary["CFBundleShortVersionString"] as? String
        guard let version, SemanticVersion(version) == release.version else { throw UpdateError.versionMismatch(found: version) }
        // Gatekeeper: the release is notarized and stapled, so the assessment also passes offline.
        let assessment: GatekeeperAssessment
        do {
            assessment = Self.gatekeeperAssessment(try await runner.run(.assess(path)))
        } catch let error as UpdateError {
            throw error   // time limit: reported as such, nothing installed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            assessment = .unavailable(reason: Self.unavailableReason(error))
        }
        switch assessment {
        case .accepted: return .gatekeeper
        case .rejected: throw UpdateError.gatekeeperRejected
        case .unavailable(let reason): return .codesignFallback(reason: reason)
        }
    }

    /// `spctl -a -vv` accepted the app (see `gatekeeperAssessment`).
    static func gatekeeperAccepted(_ output: CommandOutput) -> Bool {
        gatekeeperAssessment(output) == .accepted
    }

    /// `spctl` exit status for a denied assessment (`man spctl`).
    static let spctlDeniedStatus: Int32 = 3

    /// Reads `spctl -a -vv` output independent of line endings (`\n`, `\r\n`, `\r`), surrounding white space and letter
    /// case. Accepted: exit 0, an `accepted` line and the notarized Developer ID source (§49.8). A `rejected` line or
    /// exit 3 is always a rejection; exit 0 without a full acceptance is a rejection too. Any other failure without
    /// a verdict means `spctl` could not assess the app (`unavailable`).
    static func gatekeeperAssessment(_ output: CommandOutput) -> GatekeeperAssessment {
        let lines = output.output.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let rejected = lines.contains { line in
            line == "rejected" || line.hasPrefix("rejected ") || line.hasSuffix(": rejected") || line.contains(": rejected ")
        }
        if rejected || output.status == spctlDeniedStatus { return .rejected }
        let accepted = lines.contains { $0 == "accepted" || $0.hasSuffix(": accepted") }
        let notarizedSource = "Notarized Developer ID".lowercased()
        let notarized = lines.contains { line in
            let value = line.hasPrefix("source=") ? String(line.dropFirst("source=".count)) : line
            return value.trimmingCharacters(in: .whitespaces) == notarizedSource
        }
        if output.status == 0 { return accepted && notarized ? .accepted : .rejected }
        return .unavailable(reason: "exit\(output.status)")
    }

    /// Short code of a runner error for the diagnostics log (`launchFailed`, `notAllowed`, …).
    private static func unavailableReason(_ error: any Error) -> String {
        switch error as? CommandError {
        case .launchFailed?: return "launchFailed"
        case .notAllowed?: return "notAllowed"
        default: return String(describing: type(of: error))
        }
    }

    /// Current app → backup, staged app → current location; on failure the backup is moved back.
    private func replace(staged: URL, backup: URL) async throws {
        let parent = installedApp.deletingLastPathComponent()
        if fileManager.isWritable(parent), fileManager.isWritable(installedApp) {
            try? fileManager.remove(backup)
            do {
                try fileManager.move(installedApp, to: backup)
            } catch {
                throw UpdateError.installFailed(rolledBack: true, backup: nil)
            }
            do {
                try fileManager.move(staged, to: installedApp)
            } catch {
                throw rollback(backup: backup)
            }
            return
        }
        guard allowAdministratorPrompt, let current = UpdatePath(installedApp), let backupPath = UpdatePath(backup),
              let stagedPath = UpdatePath(staged) else { throw UpdateError.notWritable }
        let output: CommandOutput
        do {
            output = try await runner.run(.adminReplace(current: current, backup: backupPath, staged: stagedPath))
        } catch {
            throw UpdateError.adminPromptFailed
        }
        if output.status == 0 { return }
        // `-128` = the administrator prompt was cancelled: nothing moved.
        if output.output.contains("-128") { throw UpdateError.cancelledByUser }
        // A failed second move is undone by the script itself (the backup goes back into place).
        throw fileManager.exists(installedApp) ? UpdateError.installFailed(rolledBack: true, backup: nil)
                                               : UpdateError.installFailed(rolledBack: false, backup: backup)
    }

    /// Puts the previous app back; returns the error to report.
    private func rollback(backup: URL) -> UpdateError {
        try? fileManager.remove(installedApp)
        do {
            try fileManager.move(backup, to: installedApp)
            return .installFailed(rolledBack: true, backup: nil)
        } catch {
            return .installFailed(rolledBack: false, backup: backup)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `Key=Value` lines of `codesign -dvv`.
    static func signingFields(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = String(line[line.index(after: equals)...]) }
        }
        return fields
    }
}

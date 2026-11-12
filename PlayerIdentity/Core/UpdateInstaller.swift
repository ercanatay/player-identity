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
    /// Runs `argv[0]` with the remaining arguments; stdout and stderr are combined. Never blocks the caller's thread.
    ///
    /// `timeout`: the process is stopped (`SIGTERM`, then `SIGKILL`) after this many seconds and `CommandError.timedOut`
    /// is thrown. `cancellable`: cancelling the waiting task stops the process and throws `CommandError.cancelled`;
    /// otherwise the process always runs to its end (steps that must not be interrupted). The defaults keep the
    /// previous behaviour: no limit, not cancellable.
    static func run(_ argv: [String], timeout: TimeInterval? = nil, cancellable: Bool = false) async throws -> CommandOutput {
        let running = RunningProcess(argv)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                running.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            if cancellable { running.stop(.cancelled) }
        }
    }
}

/// One `Process` with its output pipe. The output is read on a background thread until the pipe closes; the
/// continuation is resumed exactly once: with the output when the process exits, or with an error when it could not
/// start, ran too long or was cancelled (then it is terminated and the continuation does not wait for it).
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private var continuation: CheckedContinuation<CommandOutput, any Error>?
    /// Set once the result is decided (also when `stop` comes before `start`).
    private var outcome: CommandError?
    private var finished = false

    init(_ argv: [String]) {
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func start(timeout: TimeInterval?, continuation: CheckedContinuation<CommandOutput, any Error>) {
        let stoppedEarly: CommandError? = lock.withLock {
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let stoppedEarly {   // cancelled before it started: nothing is launched
            continuation.resume(throwing: stoppedEarly)
            return
        }
        do {
            try process.run()
        } catch {
            finish(.failure(CommandError.launchFailed))
            return
        }
        // Stopped while it was being launched: the waiting task already has the error, the process must not stay.
        if lock.withLock({ outcome != nil }) { terminate() }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0)) { [self] in stop(.timedOut) }
        }
        let process = self.process
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = reader.readDataToEndOfFile()
            process.waitUntilExit()
            finish(.success(CommandOutput(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))))
        }
    }

    /// Stops the process (time limit or cancellation); the waiting task gets `reason` right away.
    func stop(_ reason: CommandError) {
        let state: (CheckedContinuation<CommandOutput, any Error>?, Bool) = lock.withLock {
            guard !finished, outcome == nil else { return (nil, false) }
            outcome = reason
            finished = continuation != nil
            let pending = continuation
            continuation = nil
            return (pending, true)
        }
        guard state.1 else { return }
        if let pending = state.0 {
            terminate()
            pending.resume(throwing: reason)
        }
    }

    private func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // A process that ignores SIGTERM is killed two seconds later.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func finish(_ result: Result<CommandOutput, any Error>) {
        let pending: CheckedContinuation<CommandOutput, any Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
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
        let prepared = Prepared(release: release,
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
            try await verify(staged: stagedPath, appURL: prepared.staged, release: release)
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
        return Result(installed: installedApp, backup: backup, version: prepared.release.versionString)
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

    private func verify(staged path: UpdatePath, appURL: URL, release: AppRelease) async throws {
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
        guard Self.gatekeeperAccepted(try await runner.run(.assess(path))) else { throw UpdateError.gatekeeperRejected }
    }

    /// `spctl -a -vv` accepted the app: exit status 0 and a `<path>: accepted` line (a rejection prints `rejected`).
    static func gatekeeperAccepted(_ output: CommandOutput) -> Bool {
        guard output.status == 0 else { return false }
        return output.output.split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text == "accepted" || text.hasSuffix(": accepted")
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

import Foundation

// MARK: - §67.2 "Launch Game with Logging" (`-condebug`)

/// Opens an application bundle with launch arguments (the app uses NSWorkspace; tests a fake). It only starts the
/// process: no file is written.
protocol AppLaunching: Sendable {
    func open(app: URL, arguments: [String]) async throws
}

/// Default when nothing is injected (tests): never starts anything.
struct UnavailableAppLauncher: AppLaunching {
    init() {}
    func open(app: URL, arguments: [String]) async throws { throw CommandError.launchFailed }
}

enum CondebugLaunchError: Error, Sendable, Equatable {
    /// `Xash3D-FWGS.app` is not installed.
    case appNotFound
    /// The game is already running (the button is disabled; checked again when pressed).
    case gameRunning
    /// The launcher failed; the technical reason (also written to the error log).
    case launchFailed(String)
}

/// What the "Launch Game with Logging" button shows.
enum CondebugState: Sendable, Equatable {
    /// Started; waiting (at most 10 s) for the engine log.
    case waiting
    /// The engine log was created / written after the start (file name).
    case active(String)
    /// No log within 10 s; the expected path (`<gamedir>/qconsole.log`).
    case noLog(String)
    case failed(CondebugLaunchError)
}

/// Modification date of a file, `nil` when it does not exist (read-only).
protocol FileDating: Sendable {
    func modificationDate(_ url: URL) -> Date?
}

struct LocalFileDating: FileDating {
    init() {}
    func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

struct CondebugLauncher: Sendable {
    static let argument = "-condebug"
    static let logFileName = "qconsole.log"
    /// How long the log is waited for after the start, and the polling interval.
    static let logWait: TimeInterval = 10
    static let pollInterval: TimeInterval = 1

    let locator: GameAppLocator
    let detector: any GameProcessDetecting
    let launcher: any AppLaunching
    let files: any FileDating
    let sleeper: any Sleeping

    /// The only arguments passed: `-condebug` (and `-game <gamedir>` for a game folder other than `valve`).
    static func arguments(gamedir: String?) -> [String] {
        guard let name = GameLaunchCommand.gamedirArgument(gamedir), name != GameLaunchCommand.defaultGamedir else {
            return [argument]
        }
        return ["-game", name, argument]
    }

    /// `<data root>/<gamedir>/qconsole.log` (`valve` without a game folder).
    static func logURL(dataRoot: URL, gamedir: String?) -> URL {
        let name = GameLaunchCommand.gamedirArgument(gamedir) ?? GameLaunchCommand.defaultGamedir
        return dataRoot.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(logFileName, isDirectory: false)
    }

    /// Why the button is disabled, `nil` when it can be used.
    func blocker() -> CondebugLaunchError? {
        if locator.locate() == nil { return .appNotFound }
        if detector.isGameRunning() { return .gameRunning }
        return nil
    }

    /// Starts Xash3D with `-condebug`, then waits up to 10 s for `qconsole.log` to appear (or to be written after the
    /// start). Returns `.active`, `.noLog` or `.failed`; `progress` gets `.waiting` once the game was started.
    func launch(dataRoot: URL, gamedir: String?,
                progress: @Sendable (CondebugState) async -> Void = { _ in }) async -> CondebugState {
        guard let app = locator.locate() else { return .failed(.appNotFound) }
        guard !detector.isGameRunning() else { return .failed(.gameRunning) }
        let log = Self.logURL(dataRoot: dataRoot, gamedir: gamedir)
        let before = files.modificationDate(log)
        do {
            try await launcher.open(app: app, arguments: Self.arguments(gamedir: gamedir))
        } catch {
            return .failed(.launchFailed(String(describing: error)))
        }
        await progress(.waiting)
        var waited: TimeInterval = 0
        while true {
            if let date = files.modificationDate(log), before.map({ date > $0 }) ?? true {
                return .active(log.lastPathComponent)
            }
            guard waited < Self.logWait else { break }
            do {
                try await sleeper.sleep(seconds: Self.pollInterval)
            } catch {
                break
            }
            waited += Self.pollInterval
        }
        let gamedirName = GameLaunchCommand.gamedirArgument(gamedir) ?? GameLaunchCommand.defaultGamedir
        return .noLog("\(gamedirName)/\(Self.logFileName)")
    }
}

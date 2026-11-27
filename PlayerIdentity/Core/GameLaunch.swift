import Foundation

// MARK: - §29 Join the game

enum GameLaunchError: Error, Sendable, Equatable {
    /// `/Applications/Xash3D-FWGS.app` (or `~/Applications/…`) is missing.
    case appNotFound
    case invalidHost
    case invalidPort
    /// The profile gamedir is not a plain folder name.
    case invalidGamedir
    /// The hostname could not be resolved to an address.
    case resolutionFailed(ResolutionError)
    /// "Local machine" rows have no address to connect to.
    case noAddress
    /// The game is running and the user did not confirm closing it.
    case cancelled
    /// `open` could not be started or returned a non-zero status.
    case launchFailed(status: Int32)
    /// §75.13 a GoldSrc 48 launch needs the data root (`XASH3D_BASEDIR`, where `engine.log` is written).
    case noDataRoot
    /// §76.3 the Steam broker path is not set or not usable (Settings › Connection Paths).
    case steamBrokerNotConfigured
    /// §76.3 the Steam session is missing ("Steam oturumu gerekli").
    case steamSessionRequired
    /// §76.3 the broker is running but its port is not listening.
    case steamBrokerUnreachable
    /// §76.3 the broker binary could not be started.
    case steamBrokerStartFailed
}

/// `/usr/bin/open -a <Xash3D.app> --args -game <gamedir> +connect <ip>:<port>` (`source49` / `unknown`);
/// a GoldSrc 48 server: `/usr/bin/open --env XASH3D_BASEDIR=<data root> -a <Xash3D.app> --args -game <gamedir> -dev 1
/// -log +connect <ip>:<port> gs` (§75.4: the argument is `gs`, not `legacy`; §75.13: `-dev 1 -log` make the engine
/// write its console to `engine.log`, and `XASH3D_BASEDIR` puts that file in the data root the app reads — `open`
/// starts apps with the working directory `/`, where the engine would otherwise try to write it). No shell: every
/// element is one argument.
struct GameLaunchCommand: Sendable, Equatable {
    static let openPath = "/usr/bin/open"
    static let defaultGamedir = "valve"
    /// §75.4 the engine's GoldSrc protocol argument of `connect`.
    static let goldSrcArgument = "gs"
    /// §75.13 console to `engine.log` (developer level 1 + log file).
    static let goldSrcLogArguments = ["-dev", "1", "-log"]
    /// §75.13 `open --env` name of the engine's data root.
    static let baseDirVariable = "XASH3D_BASEDIR"
    /// §76.4 the only argument the Steam identity method adds (launch line only; no game file is written).
    static let steamArguments = ["+set", "cl_ticket_generator", "steam"]

    let app: URL
    let gamedir: String
    /// `1.2.3.4:27015` or `[2001:db8::1]:27015`.
    let connect: String
    /// §75.4 the protocol decision (only this changes the arguments; no user text is added).
    var serverProtocol: ServerProtocol = .unknown
    /// §75.13 the data root (`XASH3D_BASEDIR` of a GoldSrc launch; `engine.log` is written there).
    var dataRoot: URL?
    /// §76 the join identity; `.steamAuth` adds `steamArguments` before `+connect`, `.standard` changes nothing.
    var identity: JoinIdentity = .standard

    init(app: URL, gamedir: String, connect: String, serverProtocol: ServerProtocol = .unknown, dataRoot: URL? = nil,
         identity: JoinIdentity = .standard) {
        self.identity = identity
        self.app = app
        self.gamedir = gamedir
        self.connect = connect
        self.serverProtocol = serverProtocol
        self.dataRoot = dataRoot
    }

    /// A GoldSrc launch needs a data root; without one the command is not built (`GameLaunchError.noDataRoot`).
    var argv: [String] {
        let extra = identity == .steamAuth ? Self.steamArguments : []
        guard serverProtocol == .goldsrc48, let dataRoot else {
            return [Self.openPath, "-a", app.path, "--args", "-game", gamedir] + extra + ["+connect", connect]
        }
        return [Self.openPath, "--env", Self.baseDirVariable + "=" + dataRoot.standardizedFileURL.path, "-a", app.path,
                "--args", "-game", gamedir] + Self.goldSrcLogArguments + extra + ["+connect", connect, Self.goldSrcArgument]
    }

    /// Where the engine writes its console log for this launch (GoldSrc only).
    var engineLogURL: URL? {
        guard serverProtocol == .goldsrc48, let dataRoot else { return nil }
        return GoldSrcEngineLog.url(dataRoot: dataRoot.standardizedFileURL)
    }

    /// `+connect` argument; IPv6 in brackets so the port stays unambiguous.
    static func connectArgument(address: ServerAddress, port: Int) -> String? {
        guard HostValidator.isValidPort(port), let text = address.text else { return nil }
        switch address {
        case .ipv4: return "\(text):\(port)"
        case .ipv6: return "[\(text)]:\(port)"
        case .localMachine: return nil
        }
    }

    /// Profile gamedir; empty → `valve` (the engine default). Only a plain folder name is accepted.
    static func gamedirArgument(_ gamedir: String?) -> String? {
        let name = (gamedir ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return defaultGamedir }
        return GameLaunchAllowlist.isGamedir(name) ? name : nil
    }
}

/// The only argv the launcher may run (no shell, fixed shape).
enum GameLaunchAllowlist {
    /// Two exact shapes: `open -a <app> --args -game <dir> +connect <ip:port>` and (§75.13 GoldSrc 48)
    /// `open --env XASH3D_BASEDIR=<absolute data root> -a <app> --args -game <dir> -dev 1 -log +connect <ip:port> gs`.
    static func isAllowed(_ argv: [String]) -> Bool {
        // §76.4 the Steam identity method adds exactly `+set cl_ticket_generator steam` right before `+connect`.
        if let marker = argv.firstIndex(of: "+set") {
            let extra = GameLaunchCommand.steamArguments
            guard argv.count > marker + extra.count, Array(argv[marker..<(marker + extra.count)]) == extra,
                  argv[marker + extra.count] == "+connect" else { return false }
            var stripped = argv
            stripped.removeSubrange(marker..<(marker + extra.count))
            guard !stripped.contains("+set") else { return false }
            return isAllowed(stripped)
        }
        guard argv.first == GameLaunchCommand.openPath else { return false }
        if argv.count == 8 {
            return argv[1] == "-a" && isAppPath(argv[2]) && argv[3] == "--args" && argv[4] == "-game" && isGamedir(argv[5])
                && argv[6] == "+connect" && isConnect(argv[7])
        }
        guard argv.count == 14, argv[1] == "--env", isBaseDir(argv[2]), argv[3] == "-a", isAppPath(argv[4]),
              argv[5] == "--args", argv[6] == "-game", isGamedir(argv[7]) else { return false }
        return Array(argv[8..<11]) == GameLaunchCommand.goldSrcLogArguments && argv[11] == "+connect" && isConnect(argv[12])
            && argv[13] == GameLaunchCommand.goldSrcArgument
    }

    /// `XASH3D_BASEDIR=<absolute path>`: no newline/NUL, no `..` component, not the root.
    static func isBaseDir(_ text: String) -> Bool {
        let prefix = GameLaunchCommand.baseDirVariable + "="
        guard text.hasPrefix(prefix) else { return false }
        let path = String(text.dropFirst(prefix.count))
        return path.hasPrefix("/") && path.count > 1 && !path.contains("\n") && !path.contains("\0")
            && !path.split(separator: "/").contains("..")
    }

    static func isAppPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".app") && !path.contains("\n") && !path.contains("/../")
    }

    static func isGamedir(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.\-]{0,63}$"#, options: .regularExpression) != nil && name != ".."
    }

    static func isConnect(_ text: String) -> Bool {
        let pattern = #"^([0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:.]+\]):[0-9]{1,5}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Finds `Xash3D-FWGS.app` (§29: required in `/Applications`; `~/Applications` is also accepted).
struct GameAppLocator: Sendable {
    static let appName = "Xash3D-FWGS.app"

    let fileSystem: any FileSystemReading
    let homeDirectory: URL

    init(fileSystem: any FileSystemReading = LocalFileSystem(),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
    }

    var candidates: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(Self.appName, isDirectory: true),
         homeDirectory.appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(Self.appName, isDirectory: true)]
    }

    /// First existing app bundle; `nil` = not installed ("Oyuna gir" is hidden).
    func locate() -> URL? {
        candidates.first { fileSystem.isDirectory($0) }
    }
}

protocol GameLaunchRunning: Sendable {
    func run(_ argv: [String]) async throws -> CommandOutput
}

/// Default when nothing is injected (tests): never runs anything.
struct UnavailableGameLaunchRunner: GameLaunchRunning {
    init() {}
    func run(_ argv: [String]) async throws -> CommandOutput { throw CommandError.launchFailed }
}

/// Real runner: allowlisted argv only, run directly by `Process` (no shell).
struct ProcessGameLaunchRunner: GameLaunchRunning {
    init() {}

    func run(_ argv: [String]) async throws -> CommandOutput {
        guard GameLaunchAllowlist.isAllowed(argv) else { throw CommandError.notAllowed }
        return try await SystemProcess.run(argv)
    }
}

/// A ready command; `gameRunning` = confirm first ("the game is open; a new connection closes it").
struct GameLaunchPlan: Sendable, Equatable {
    let command: GameLaunchCommand
    let gameRunning: Bool
}

struct GameLauncher: Sendable {
    let locator: GameAppLocator
    let resolver: any ServerAddressResolver
    let detector: any GameProcessDetecting
    let runner: any GameLaunchRunning

    init(locator: GameAppLocator = GameAppLocator(), resolver: any ServerAddressResolver = SystemAddressResolver(),
         detector: any GameProcessDetecting = SystemGameProcessDetector(),
         runner: any GameLaunchRunning = ProcessGameLaunchRunner()) {
        self.locator = locator
        self.resolver = resolver
        self.detector = detector
        self.runner = runner
    }

    /// Whether the "Oyuna gir" action is shown.
    var isAvailable: Bool { locator.locate() != nil }

    /// Builds the command: app path, gamedir, and the IP to connect to (a hostname is resolved; IPv4 preferred).
    /// `known` = an address already resolved by the refresh (§20), used instead of a new lookup.
    /// `serverProtocol` = §75.4 the latest A2S protocol of the server (`unknown` launches like `source49`).
    func plan(host: String, port: Int, gamedir: String?, known: [String: HostResolution] = [:],
              serverProtocol: ServerProtocol = .unknown, dataRoot: URL? = nil,
              identity: JoinIdentity = .standard) async throws -> GameLaunchPlan {
        if serverProtocol == .goldsrc48, dataRoot == nil { throw GameLaunchError.noDataRoot }
        guard let app = locator.locate() else { throw GameLaunchError.appNotFound }
        guard HostValidator.isValidPort(port) else { throw GameLaunchError.invalidPort }
        guard let directory = GameLaunchCommand.gamedirArgument(gamedir) else { throw GameLaunchError.invalidGamedir }
        let address: ServerAddress
        switch HostValidator.classify(host) {
        case nil:
            throw GameLaunchError.invalidHost
        case .address(let literal)?:
            address = literal
        case .hostname(let name)?:
            if let cached = known[name]?.address {
                address = cached
            } else {
                do {
                    guard let picked = AddressPreference.pick(try await resolver.addresses(for: name)) else {
                        throw GameLaunchError.resolutionFailed(.notFound)
                    }
                    address = picked
                } catch let error as ResolutionError {
                    throw GameLaunchError.resolutionFailed(error)
                } catch let error as GameLaunchError {
                    throw error
                } catch {
                    throw GameLaunchError.resolutionFailed(.network)
                }
            }
        }
        guard let connect = GameLaunchCommand.connectArgument(address: address, port: port) else {
            throw GameLaunchError.noAddress
        }
        return GameLaunchPlan(command: GameLaunchCommand(app: app, gamedir: directory, connect: connect,
                                                         serverProtocol: serverProtocol, dataRoot: dataRoot,
                                                         identity: identity),
                              gameRunning: detector.isGameRunning())
    }

    /// Runs the command. If the game is running, `confirm` is asked first; `false` → `.cancelled`, nothing runs.
    func launch(_ plan: GameLaunchPlan, confirm: @Sendable () async -> Bool) async throws {
        if plan.gameRunning, !(await confirm()) { throw GameLaunchError.cancelled }
        let output: CommandOutput
        do {
            output = try await runner.run(plan.command.argv)
        } catch {
            throw GameLaunchError.launchFailed(status: -1)
        }
        guard output.status == 0 else { throw GameLaunchError.launchFailed(status: output.status) }
    }
}

// MARK: - §75.4 protocol of the latest A2S result

/// The protocol "Join Game" uses: the newest A2S result that decided a protocol (`source49` / `goldsrc48`). A newer
/// `unknown` result (time-out, damaged reply) never overrides it; a server whose host or port changed starts over.
/// Without any decided result the launch follows the `source49` default.
struct ServerProtocolMemory: Sendable, Equatable {
    struct Observation: Sendable, Equatable {
        let serverProtocol: ServerProtocol
        let at: Date
        let host: String
        let port: Int
    }

    private(set) var observations: [UUID: Observation] = [:]

    /// Records a result; `unknown` and results older than the kept one are ignored.
    mutating func record(_ serverProtocol: ServerProtocol, for id: UUID, host: String, port: Int, at date: Date) {
        guard serverProtocol != .unknown else { return }
        if let kept = observations[id], kept.host == host, kept.port == port, kept.at > date { return }
        observations[id] = Observation(serverProtocol: serverProtocol, at: date, host: host, port: port)
    }

    /// The newest decided protocol of the row: this memory or the row's saved A2S result (`banCheck.info`).
    func launchProtocol(for entry: ServerEntry) -> ServerProtocol {
        var candidates: [(ServerProtocol, Date)] = []
        if let kept = observations[entry.id], kept.host == entry.host, kept.port == entry.port {
            candidates.append((kept.serverProtocol, kept.at))
        }
        if let check = entry.banCheck, case let saved = StatusEvaluator.protocolOf(entry), saved != .unknown {
            candidates.append((saved, check.checkedAt))
        }
        return candidates.max { $0.1 < $1.1 }?.0 ?? .unknown
    }
}

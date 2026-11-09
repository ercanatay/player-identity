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
}

/// `/usr/bin/open -a <Xash3D.app> --args -game <gamedir> +connect <ip>:<port>`.
struct GameLaunchCommand: Sendable, Equatable {
    static let openPath = "/usr/bin/open"
    static let defaultGamedir = "valve"

    let app: URL
    let gamedir: String
    /// `1.2.3.4:27015` or `[2001:db8::1]:27015`.
    let connect: String

    var argv: [String] {
        [Self.openPath, "-a", app.path, "--args", "-game", gamedir, "+connect", connect]
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
    static func isAllowed(_ argv: [String]) -> Bool {
        guard argv.count == 8, argv[0] == GameLaunchCommand.openPath, argv[1] == "-a", argv[3] == "--args",
              argv[4] == "-game", argv[6] == "+connect" else { return false }
        return isAppPath(argv[2]) && isGamedir(argv[5]) && isConnect(argv[7])
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
    func plan(host: String, port: Int, gamedir: String?, known: [String: HostResolution] = [:]) async throws -> GameLaunchPlan {
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
        return GameLaunchPlan(command: GameLaunchCommand(app: app, gamedir: directory, connect: connect),
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

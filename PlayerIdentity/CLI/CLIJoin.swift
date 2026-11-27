import Foundation

// §76.7 `playeridentityctl join --server <host:port> [--identity standard|steam-auth]`.
// The game is started through the allowlisted launcher (`open`, no shell). Steam identity: the privacy text of §76.5
// is shown and confirmed (y/N, or `--yes`), the broker must already listen (the tool never starts it), and only the
// launch line differs (`+set cl_ticket_generator steam`); no game file is written.

extension CLIRunner {
    static func join(host: String, port: Int, identity: JoinIdentity, yes: Bool, json: Bool,
                     context: CLIContext) async -> CLIResult {
        let command = "join"
        let manager = SteamBrokerManager(environment: context.steamBrokerEnvironment)
        if identity == .steamAuth {
            let endpoint = SteamIdentityStore(paths: context.paths).loadEndpoint()
            guard manager.pathCheck(endpoint) == .valid else {
                return failure("steamBrokerNotConfigured", "the Steam broker is not configured: set the broker binary path "
                               + "in Settings > Connection Paths", command: command, json: json, code: CLIExit.usage)
            }
            guard context.steamBrokerEnvironment.isSteamClientRunning() else {
                return failure("steamSessionRequired", "Steam session required: start the Steam client", command: command,
                               json: json, code: CLIExit.network)
            }
            guard context.steamBrokerEnvironment.isPortListening(host: endpoint.host, port: endpoint.port) else {
                return failure("steamBrokerNotListening", "the Steam broker is not listening on \(endpoint.host):\(endpoint.port); "
                               + "start it first (this tool never starts it)", command: command, json: json,
                               code: CLIExit.network)
            }
            if manager.state(endpoint) == .stale {
                return failure("steamBrokerStale", GameLaunchText.error(.steamBrokerStale), command: command, json: json,
                               code: CLIExit.network)
            }
            guard yes || context.prompt.isInteractive else {
                return failure("notConfirmed", "no terminal to confirm on; pass --yes to accept that your SteamID is "
                               + "reported to the server", command: command, json: json, code: CLIExit.usage)
            }
            if !yes {
                let accepted = context.prompt.ask(L10n.text(.steamConsentMessage) + "\nConnect with your Steam identity? [y/N] ")
                guard accepted else {
                    return failure("notConfirmed", "not confirmed; nothing was started", command: command, json: json,
                                   code: CLIExit.usage)
                }
            }
        }
        let snapshot = SnapshotStore(fileURL: context.snapshotURL).load().snapshot
        let normalized = HostValidator.normalized(host)
        let known = snapshot?.servers.first { HostValidator.normalized($0.host) == normalized && $0.port == port }
            .map(StatusEvaluator.protocolOf) ?? .unknown
        let root = snapshot.flatMap { $0.dataRoot.isEmpty ? nil : URL(fileURLWithPath: $0.dataRoot, isDirectory: true) }
            ?? context.paths.defaultDataRoot
        let launcher = GameLauncher(locator: context.gameAppLocator, resolver: context.resolver,
                                    detector: context.gameProcessDetector, runner: context.gameLaunchRunner)
        let plan: GameLaunchPlan
        do {
            plan = try await launcher.plan(host: host, port: port, gamedir: snapshot?.gamedir, serverProtocol: known,
                                           dataRoot: root, identity: identity)
            let confirmed = yes || context.prompt.isInteractive
            try await launcher.launch(plan) { confirmed && (yes || context.prompt.ask("The game is running; replace it? [y/N] ")) }
        } catch let error as GameLaunchError {
            let (code, exit) = joinFailure(error)
            return failure(code, GameLaunchText.error(error), command: command, json: json, code: exit)
        } catch {
            return failure("launchFailed", "the game could not be started", command: command, json: json)
        }
        let store = SteamIdentityStore(paths: context.paths)
        var memory = store.loadMemory()
        memory.noteAttempt(identity: identity, host: host, port: port, at: context.now())
        try? store.saveMemory(memory)
        if json {
            return success(json: ["schemaVersion": CLIContext.jsonSchemaVersion, "command": command, "host": host, "port": port,
                                  "identity": identity.jsonName, "launched": true,
                                  "protocol": plan.command.serverProtocol.rawValue])
        }
        return CLIResult(exitCode: CLIExit.ok, stdout: "joining \(host):\(port) (\(identity.jsonName))\n", stderr: "")
    }

    private static func joinFailure(_ error: GameLaunchError) -> (String, Int32) {
        switch error {
        case .appNotFound: return ("appNotFound", CLIExit.network)
        case .invalidHost, .invalidPort, .noAddress: return ("invalidHost", CLIExit.usage)
        case .invalidGamedir, .noDataRoot: return ("invalidGamedir", CLIExit.network)
        case .resolutionFailed: return ("resolutionFailed", CLIExit.network)
        case .cancelled: return ("notConfirmed", CLIExit.usage)
        case .launchFailed: return ("launchFailed", CLIExit.network)
        case .steamBrokerNotConfigured: return ("steamBrokerNotConfigured", CLIExit.usage)
        case .steamSessionRequired: return ("steamSessionRequired", CLIExit.network)
        case .steamBrokerStale: return ("steamBrokerStale", CLIExit.network)
        case .steamBrokerUnreachable, .steamBrokerStartFailed: return ("steamBrokerNotListening", CLIExit.network)
        }
    }
}

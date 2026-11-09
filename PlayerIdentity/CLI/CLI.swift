import Foundation

// §34 `playeridentityctl`: argument parsing, commands and output. The tool is for terminals and scripts, so its
// texts are English and not localized; JSON output has stable field names (`schemaVersion: 1`). It never reads
// standard input and never writes any file.

/// Exit codes (§34).
enum CLIExit {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let network: Int32 = 2
    static let banned: Int32 = 3
}

struct CLIResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Everything the commands touch; tests pass fakes (no network, temp home).
struct CLIContext: Sendable {
    static let snapshotEnvironmentKey = "PLAYERIDENTITYCTL_SNAPSHOT"
    static let jsonSchemaVersion = 1

    var version: String
    var build: String
    var paths: AppPaths
    var environment: [String: String]
    var fileSystem: any FileSystemReading
    var resolver: any ServerAddressResolver
    var udpTransport: any UDPTransport
    var now: @Sendable () -> Date

    /// `profile.json` read by `status` (and for the identity/name defaults); `PLAYERIDENTITYCTL_SNAPSHOT` overrides it.
    var snapshotURL: URL {
        if let path = environment[Self.snapshotEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false)
        }
        return paths.snapshotFile
    }

    static func live(bundle: Bundle = .main,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> CLIContext {
        CLIContext(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                   build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                   paths: AppPaths(),
                   environment: environment,
                   fileSystem: LocalFileSystem(),
                   resolver: SystemAddressResolver(),
                   udpTransport: BSDUDPTransport(),
                   now: { Date() })
    }
}

// MARK: - Parsing

enum CLICommand: Sendable, Equatable {
    case help
    case version(json: Bool)
    case cid(host: String, rawID: UInt64?, json: Bool)
    case ban(host: String, port: Int, cid: String?, json: Bool, timeout: TimeInterval)
    case status(json: Bool)
}

struct CLIUsageError: Error, Sendable, Equatable {
    let message: String
}

enum CLIParser {
    static let defaultTimeout: TimeInterval = BanChecker.stepTimeout
    static let maxTimeout: TimeInterval = 30

    static func parse(_ arguments: [String]) -> Result<CLICommand, CLIUsageError> {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                positionals += arguments[index...]
                break
            }
            guard argument.hasPrefix("-"), argument.count > 1, !isNegativeNumber(argument) else {
                positionals.append(argument)
                continue
            }
            var name = argument
            var inlineValue: String?
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            switch name {
            case "--json", "--version", "--help", "-h":
                guard inlineValue == nil else { return .failure(CLIUsageError(message: "\(name) takes no value")) }
                flags.insert(name == "-h" ? "--help" : name)
            case "--raw-id", "--cid", "--timeout":
                guard options[name] == nil else { return .failure(CLIUsageError(message: "\(name) given twice")) }
                if let inlineValue {
                    options[name] = inlineValue
                } else {
                    guard index < arguments.count else { return .failure(CLIUsageError(message: "\(name) needs a value")) }
                    options[name] = arguments[index]
                    index += 1
                }
            default:
                return .failure(CLIUsageError(message: "unknown option \(name)"))
            }
        }

        let json = flags.contains("--json")
        if flags.contains("--help") || positionals.first == "help" { return .success(.help) }
        guard let command = positionals.first else {
            if flags.contains("--version") { return .success(.version(json: json)) }
            return .failure(CLIUsageError(message: "missing command"))
        }
        if flags.contains("--version") { return .failure(CLIUsageError(message: "--version takes no command")) }
        let rest = Array(positionals.dropFirst())
        func allow(_ allowed: Set<String>) -> CLIUsageError? {
            options.keys.first { !allowed.contains($0) }.map { CLIUsageError(message: "\($0) is not valid for \(command)") }
        }

        switch command {
        case "cid":
            if let error = allow(["--raw-id"]) { return .failure(error) }
            guard rest.count == 1 else { return .failure(CLIUsageError(message: "cid needs exactly one <ip>")) }
            guard HostValidator.classify(rest[0]) != nil else {
                return .failure(CLIUsageError(message: "invalid address: \(rest[0])"))
            }
            var rawID: UInt64?
            if let text = options["--raw-id"] {
                guard let value = parseRawID(text) else {
                    return .failure(CLIUsageError(message: "--raw-id must be 1 to 16 hex digits"))
                }
                rawID = value
            }
            return .success(.cid(host: HostValidator.normalized(rest[0]), rawID: rawID, json: json))

        case "ban":
            if let error = allow(["--cid", "--timeout"]) { return .failure(error) }
            guard rest.count == 1 else { return .failure(CLIUsageError(message: "ban needs exactly one <host:port>")) }
            guard let target = CLIHostPort.parse(rest[0]) else {
                return .failure(CLIUsageError(message: "invalid <host:port>: \(rest[0])"))
            }
            var cid: String?
            if let text = options["--cid"] {
                guard let value = parseCID(text) else { return .failure(CLIUsageError(message: "--cid must be 32 hex digits")) }
                cid = value
            }
            var timeout = defaultTimeout
            if let text = options["--timeout"] {
                guard let value = TimeInterval(text), value.isFinite, value > 0, value <= maxTimeout else {
                    return .failure(CLIUsageError(message: "--timeout must be a number of seconds between 0 and 30"))
                }
                timeout = value
            }
            return .success(.ban(host: target.host, port: target.port, cid: cid, json: json, timeout: timeout))

        case "status":
            if let error = allow([]) { return .failure(error) }
            guard rest.isEmpty else { return .failure(CLIUsageError(message: "status takes no arguments")) }
            return .success(.status(json: json))

        default:
            return .failure(CLIUsageError(message: "unknown command \(command)"))
        }
    }

    /// 1–16 hex digits, optional `0x`.
    static func parseRawID(_ text: String) -> UInt64? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.lowercased().hasPrefix("0x") { digits = String(digits.dropFirst(2)) }
        guard (1...16).contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt64(digits, radix: 16)
    }

    /// 32 hex digits → lowercase.
    static func parseCID(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count == 32, value.allSatisfy(\.isHexDigit) else { return nil }
        return value.lowercased()
    }

    private static func isNegativeNumber(_ text: String) -> Bool {
        Double(text) != nil
    }
}

/// `host:port`, `[ipv6]:port`, or a bare host / IPv6 address (port 27015).
enum CLIHostPort {
    static func parse(_ text: String) -> (host: String, port: Int)? {
        let value = text.trimmingCharacters(in: .whitespaces)
        var host = value
        var portText: String?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = String(rest.dropFirst())
            }
            guard case .address(.ipv6)? = HostValidator.classify(host) else { return nil }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            host = String(value[..<colon])
            portText = String(value[value.index(after: colon)...])
        }
        var port = ServerEntry.defaultPort
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
                  let parsed = Int(portText), HostValidator.isValidPort(parsed) else { return nil }
            port = parsed
        }
        guard HostValidator.classify(host) != nil else { return nil }
        return (HostValidator.normalized(host), port)
    }
}

// MARK: - Running

enum CLIRunner {
    static let usage = """
    usage: playeridentityctl <command> [options]

    commands:
      cid <ip> [--raw-id <hex>] [--json]                     CID for a server address
      ban <host:port> [--cid <hex>] [--json] [--timeout 4]   ban check of one server
      status [--json]                                        summary of the saved record
      --version                                              print the version

    exit codes: 0 ok, 1 usage error, 2 network or resolution error, 3 banned
    environment: PLAYERIDENTITYCTL_SNAPSHOT=<path> reads another profile.json

    """

    static func run(arguments: [String], context: CLIContext) async -> CLIResult {
        let command: CLICommand
        switch CLIParser.parse(arguments) {
        case .success(let parsed): command = parsed
        case .failure(let error):
            return CLIResult(exitCode: CLIExit.usage, stdout: "", stderr: "playeridentityctl: \(error.message)\n\n" + usage)
        }
        switch command {
        case .help:
            return CLIResult(exitCode: CLIExit.ok, stdout: usage, stderr: "")
        case .version(let json):
            if json {
                return success(json: ["schemaVersion": CLIContext.jsonSchemaVersion, "command": "version",
                                      "version": context.version, "build": context.build])
            }
            return CLIResult(exitCode: CLIExit.ok, stdout: "playeridentityctl \(context.version) (\(context.build))\n", stderr: "")
        case .cid(let host, let rawID, let json):
            return await cid(host: host, rawID: rawID, json: json, context: context)
        case .ban(let host, let port, let cid, let json, let timeout):
            return await ban(host: host, port: port, cid: cid, json: json, timeout: timeout, context: context)
        case .status(let json):
            return status(json: json, context: context)
        }
    }

    // MARK: cid

    private static func cid(host: String, rawID: UInt64?, json: Bool, context: CLIContext) async -> CLIResult {
        let identity = rawID.map { (value: $0, source: "argument") }
            ?? localRawID(context: context).map { (value: $0, source: "identityFile") }
        guard let identity else {
            return failure("identityMissing", "no identity file found (~/.config/.xash_id); pass --raw-id <hex>",
                           command: "cid", json: json)
        }
        let address: ServerAddress
        switch await resolve(host, context: context) {
        case .success(let resolved): address = resolved
        case .failure(let error): return resolutionFailure(error, host: host, command: "cid", json: json)
        }
        let cid = CIDCalculator.cid(rawID: identity.value, address: address)
        guard json else { return CLIResult(exitCode: CLIExit.ok, stdout: cid + "\n", stderr: "") }
        return success(json: ["schemaVersion": CLIContext.jsonSchemaVersion, "command": "cid", "host": host,
                              "address": address.text ?? host, "rawID": HexID.format(identity.value),
                              "rawIDSource": identity.source, "cid": cid])
    }

    // MARK: ban

    private static func ban(host: String, port: Int, cid: String?, json: Bool, timeout: TimeInterval,
                            context: CLIContext) async -> CLIResult {
        let address: ServerAddress
        switch await resolve(host, context: context) {
        case .success(let resolved): address = resolved
        case .failure(let error): return resolutionFailure(error, host: host, command: "ban", json: json)
        }
        let snapshot = SnapshotStore(fileURL: context.snapshotURL).load().snapshot
        let usedCID = cid ?? localRawID(context: context).map { CIDCalculator.cid(rawID: $0, address: address) }
        let name = snapshot.map(\.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? "player"
        let request = BanCheckRequest(serverID: UUID(), host: host, port: port,
                                      endpoint: UDPEndpoint(address: address, port: UInt16(port)), cid: usedCID, name: name)
        let checker = BanChecker(transport: context.udpTransport, now: context.now, stepTimeout: timeout)
        let check: BanCheck
        do {
            check = try await checker.check(request)
        } catch {
            return failure("cancelled", "ban check cancelled", command: "ban", json: json, code: CLIExit.network)
        }
        let banned = check.status == .ipBanned || check.status == .cidBanned
        let exitCode = banned ? CLIExit.banned : check.status == .unreachable ? CLIExit.network : CLIExit.ok
        let target = endpointText(address: address, host: host, port: port)
        if json {
            var object: [String: Any] = [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "ban", "host": host, "port": port,
                "address": address.text ?? host, "cid": usedCID ?? NSNull(), "status": check.status.rawValue,
                "banned": banned, "detail": check.detail, "checkedAt": iso(check.checkedAt),
                "server": NSNull(),
            ]
            if let info = check.info, !info.isEmpty {
                object["server"] = ["name": info.name ?? NSNull(), "map": info.map ?? NSNull(),
                                    "players": info.players ?? NSNull(), "maxPlayers": info.maxPlayers ?? NSNull(),
                                    "pingMillis": info.pingMillis ?? NSNull()] as [String: Any]
            }
            return CLIResult(exitCode: exitCode, stdout: CLIJSON.string(object), stderr: "")
        }
        var lines = ["\(target) \(check.status.rawValue)", "detail: \(check.detail)"]
        if usedCID == nil { lines.append("cid: none (IP check only)") }
        if let info = check.info, !info.isEmpty {
            var parts = [info.name, info.map].compactMap { $0 }
            if let players = info.players { parts.append("\(players)/\(info.maxPlayers.map(String.init) ?? "?")") }
            if let ping = info.pingMillis { parts.append("\(ping) ms") }
            lines.append("server: " + parts.joined(separator: " · "))
        }
        return CLIResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: status

    private static func status(json: Bool, context: CLIContext) -> CLIResult {
        let url = context.snapshotURL
        let snapshot: Snapshot
        switch SnapshotStore(fileURL: url).load() {
        case .loaded(let value): snapshot = value
        case .missing: return failure("snapshotMissing", "no saved record at \(url.path)", command: "status", json: json)
        case .corrupt: return failure("snapshotCorrupt", "the saved record cannot be read: \(url.path)",
                                      command: "status", json: json)
        case .unsupportedSchema(let version):
            return failure("snapshotUnsupported", "the saved record has schema \(version), this tool reads 1",
                           command: "status", json: json)
        }
        let bannedCount = snapshot.servers.filter { $0.banCheck?.status == .ipBanned || $0.banCheck?.status == .cidBanned }.count
        let exitCode = bannedCount > 0 ? CLIExit.banned : CLIExit.ok
        if json {
            let servers: [[String: Any]] = snapshot.servers.map { entry in
                var ban: Any = NSNull()
                if let check = entry.banCheck {
                    ban = ["status": check.status.rawValue, "checkedAt": iso(check.checkedAt), "detail": check.detail,
                           "banned": check.status == .ipBanned || check.status == .cidBanned] as [String: Any]
                }
                var appeal: Any = NSNull()
                if let value = entry.appeal {
                    appeal = ["status": value.status.rawValue, "channel": value.channel, "sentAt": iso(value.sentAt),
                              "followUpAt": value.followUpAt.map(iso) ?? NSNull()] as [String: Any]
                }
                return ["id": entry.id.uuidString, "label": entry.label, "host": entry.host, "port": entry.port,
                        "cid": entry.cid, "group": entry.group ?? NSNull(), "favorite": entry.favorite, "order": entry.order,
                        "lastCheckedAt": entry.lastCheckedAt.map(iso) ?? NSNull(), "ban": ban, "appeal": appeal]
            }
            let object: [String: Any] = [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "status", "version": context.version,
                "snapshot": ["path": url.path, "schemaVersion": snapshot.schemaVersion, "savedAt": iso(snapshot.savedAt)]
                    as [String: Any],
                "rawID": snapshot.rawID, "displayName": snapshot.displayName, "model": snapshot.model,
                "gamedir": snapshot.gamedir, "publicIP": snapshot.network.publicIP, "lanIPs": snapshot.network.lanIPs,
                "bannedCount": bannedCount, "servers": servers,
            ]
            return CLIResult(exitCode: exitCode, stdout: CLIJSON.string(object), stderr: "")
        }
        var lines = [
            "playeridentityctl \(context.version)",
            "record:     \(url.path) (saved \(iso(snapshot.savedAt)))",
            "raw ID:     \(snapshot.rawID.isEmpty ? "-" : snapshot.rawID)",
            "name:       \(snapshot.displayName.isEmpty ? "-" : snapshot.displayName)",
            "model:      \(snapshot.model.isEmpty ? "-" : snapshot.model)",
            "public IP:  \(snapshot.network.publicIP.isEmpty ? "-" : snapshot.network.publicIP)",
            "servers:    \(snapshot.servers.count), banned: \(bannedCount)",
        ]
        for entry in snapshot.servers {
            let ban = entry.banCheck.map { "\($0.status.rawValue) (\(iso($0.checkedAt)))" } ?? "not checked"
            let address = entry.host.contains(":") ? "[\(entry.host)]:\(entry.port)" : "\(entry.host):\(entry.port)"
            lines.append("  \(entry.label)  \(address)  ban: \(ban)")
        }
        return CLIResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: Helpers

    /// Raw ID from the identity files (home locations, then the saved gamedir).
    static func localRawID(context: CLIContext) -> UInt64? {
        var gamedir: URL?
        if let snapshot = SnapshotStore(fileURL: context.snapshotURL).load().snapshot, !snapshot.gamedir.isEmpty,
           !snapshot.dataRoot.isEmpty {
            gamedir = URL(fileURLWithPath: snapshot.dataRoot, isDirectory: true)
                .appendingPathComponent(snapshot.gamedir, isDirectory: true)
        }
        let reader = IdentityReader(fileSystem: context.fileSystem, homeDirectory: context.paths.home)
        return try? reader.read(gamedir: gamedir).get().rawID
    }

    private static func resolve(_ host: String, context: CLIContext) async -> Result<ServerAddress, ResolutionError> {
        switch HostValidator.classify(host) {
        case .address(let address)?: return .success(address)
        case nil: return .failure(.invalidHostname)
        case .hostname(let name)?:
            do {
                guard let address = AddressPreference.pick(try await context.resolver.addresses(for: name)) else {
                    return .failure(.notFound)
                }
                return .success(address)
            } catch let error as ResolutionError {
                return .failure(error)
            } catch {
                return .failure(.network)
            }
        }
    }

    private static func resolutionFailure(_ error: ResolutionError, host: String, command: String, json: Bool) -> CLIResult {
        switch error {
        case .invalidHostname: return failure("invalidHost", "invalid host: \(host)", command: command, json: json,
                                              code: CLIExit.usage)
        case .notFound: return failure("notFound", "host not found: \(host)", command: command, json: json)
        case .network: return failure("network", "could not resolve \(host) (network error)", command: command, json: json)
        }
    }

    private static func endpointText(address: ServerAddress, host: String, port: Int) -> String {
        if case .ipv6 = address, ServerAddress.parse(host) != nil { return "[\(host)]:\(port)" }
        return "\(host):\(port)"
    }

    private static func success(json object: [String: Any]) -> CLIResult {
        CLIResult(exitCode: CLIExit.ok, stdout: CLIJSON.string(object), stderr: "")
    }

    /// Runtime error: JSON on stdout with `--json`, a message on stderr otherwise. Exit 2 unless given.
    private static func failure(_ error: String, _ message: String, command: String, json: Bool,
                                code exitCode: Int32 = CLIExit.network) -> CLIResult {
        if json {
            let object: [String: Any] = ["schemaVersion": CLIContext.jsonSchemaVersion, "command": command,
                                         "error": error, "message": message]
            return CLIResult(exitCode: exitCode, stdout: CLIJSON.string(object), stderr: "")
        }
        return CLIResult(exitCode: exitCode, stdout: "", stderr: "playeridentityctl: \(message)\n")
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

enum CLIJSON {
    /// Pretty-printed, sorted keys, unescaped slashes; ends with a newline.
    static func string(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}\n"
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

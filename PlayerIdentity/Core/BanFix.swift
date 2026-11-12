import Foundation

// MARK: - Commands and allowlist (§17.2/3, §17.5)

/// Interface name read from the system (e.g. `en0`). Not user input; still strictly validated.
struct NetworkInterfaceName: Sendable, Equatable, CustomStringConvertible {
    let value: String

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...12).contains(text.count),
              text.range(of: "^[a-z]{2,8}[0-9]{1,3}$", options: .regularExpression) != nil else { return nil }
        value = text
    }

    var description: String { value }
}

/// The **only** set of commands the fix flow may run. There are no server commands (banid/removeid etc.).
enum NetworkCommand: Sendable, Equatable {
    /// `/sbin/route -n get default` (read-only: default route → interface, gateway)
    case routeGetDefault
    /// `/usr/sbin/networksetup -getairportpower <if>` (read-only: is the interface Wi-Fi)
    case airportPowerStatus(NetworkInterfaceName)
    /// `/usr/sbin/networksetup -setairportpower <if> on|off`
    case setAirportPower(NetworkInterfaceName, on: Bool)
    /// `ipconfig set <if> DHCP` — with administrator approval (macOS system dialog, `osascript … with administrator privileges`)
    case renewDHCP(NetworkInterfaceName)

    var argv: [String] {
        switch self {
        case .routeGetDefault:
            return ["/sbin/route", "-n", "get", "default"]
        case .airportPowerStatus(let interface):
            return ["/usr/sbin/networksetup", "-getairportpower", interface.value]
        case .setAirportPower(let interface, let on):
            return ["/usr/sbin/networksetup", "-setairportpower", interface.value, on ? "on" : "off"]
        case .renewDHCP(let interface):
            return ["/usr/bin/osascript", "-e",
                    "do shell script \"/usr/sbin/ipconfig set \(interface.value) DHCP\" with administrator privileges"]
        }
    }

    /// Whether it takes the interface down (requires restoring).
    var takesInterfaceDown: Bool {
        if case .setAirportPower(_, on: false) = self { return true }
        return false
    }
}

enum CommandAllowlist {
    private static let interfacePattern = "[a-z]{2,8}[0-9]{1,3}"

    /// Only argv arrays that exactly match a `NetworkCommand` shape pass.
    static func isAllowed(_ argv: [String]) -> Bool {
        func isInterface(_ text: String) -> Bool { NetworkInterfaceName(text)?.value == text }
        switch argv.count {
        case 4 where argv == ["/sbin/route", "-n", "get", "default"]:
            return true
        case 3 where argv[0] == "/usr/sbin/networksetup" && argv[1] == "-getairportpower":
            return isInterface(argv[2])
        case 4 where argv[0] == "/usr/sbin/networksetup" && argv[1] == "-setairportpower":
            return isInterface(argv[2]) && (argv[3] == "on" || argv[3] == "off")
        case 3 where argv[0] == "/usr/bin/osascript" && argv[1] == "-e":
            let script = argv[2]
            let pattern = "^do shell script \"/usr/sbin/ipconfig set \(interfacePattern) DHCP\" with administrator privileges$"
            return script.range(of: pattern, options: .regularExpression) != nil
        default:
            return false
        }
    }
}

struct CommandOutput: Sendable, Equatable {
    var status: Int32
    var output: String
}

enum CommandError: Error, Equatable {
    case notAllowed
    case launchFailed
    /// The process ran longer than its time limit and was stopped.
    case timedOut
    /// The task waiting for the process was cancelled and the process was stopped.
    case cancelled
}

protocol CommandRunning: Sendable {
    func run(_ command: NetworkCommand) async throws -> CommandOutput
}

/// Real runner: only allowlisted argv; no shell interpretation (`Process` runs it directly).
struct ProcessCommandRunner: CommandRunning {
    init() {}

    func run(_ command: NetworkCommand) async throws -> CommandOutput {
        let argv = command.argv
        guard CommandAllowlist.isAllowed(argv) else { throw CommandError.notAllowed }
        return try await SystemProcess.run(argv)
    }
}

protocol Sleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct TaskSleeper: Sleeping {
    init() {}
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}

// MARK: - Output parsing

struct DefaultRoute: Sendable, Equatable {
    let interface: NetworkInterfaceName
    /// IPv4 gateway only (for the router admin page link).
    let gateway: String?

    static func parse(_ output: String) -> DefaultRoute? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let interface = values["interface"].flatMap(NetworkInterfaceName.init) else { return nil }
        var gateway: String?
        if let raw = values["gateway"], case .ipv4? = ServerAddress.parse(raw) { gateway = raw }
        return DefaultRoute(interface: interface, gateway: gateway)
    }

    var routerURL: URL? { gateway.flatMap { URL(string: "http://\($0)") } }
}

enum AirportPowerStatus {
    /// `Wi-Fi Power (en0): On` → Wi-Fi; "… is not a Wi-Fi interface" → not Wi-Fi.
    static func isWiFi(_ output: CommandOutput) -> Bool {
        output.status == 0 && output.output.range(of: #"(Wi-Fi|AirPort) Power \("#, options: .regularExpression) != nil
    }
}

// MARK: - Outcomes (§17.2, §17.9.3)

enum FixProgress: Sendable, Equatable {
    case renewingIP
    case waitingForNetwork
    case rechecking

    var text: String {
        switch self {
        case .renewingIP: return L10n.text(.fixProgressRenewingIP)
        case .waitingForNetwork: return L10n.text(.fixProgressWaitingForNetwork)
        case .rechecking: return L10n.text(.fixProgressRechecking)
        }
    }
}

enum FixFailure: Sendable, Equatable {
    case publicIPUnavailable
    case noDefaultRoute
    case commandFailed
    case adminDeclined

    var text: String {
        switch self {
        case .publicIPUnavailable: return L10n.text(.fixFailurePublicIPUnavailable)
        case .noDefaultRoute: return L10n.text(.fixFailureNoDefaultRoute)
        case .commandFailed: return L10n.text(.fixFailureCommandFailed)
        case .adminDeclined: return L10n.text(.fixFailureAdminDeclined)
        }
    }
}

// MARK: - IP range (§17.10)

enum IPRange {
    /// Narrow (`/24` | `/64`) and wide (`/16` | `/48`) range; `nil` if unparsable.
    static func ranges(for ip: String) -> (narrow: String, wide: String)? {
        switch ServerAddress.parse(ip) {
        case .ipv4(let b)?: return (cidr(.ipv4, b, 24), cidr(.ipv4, b, 16))
        case .ipv6(let b)?: return (cidr(.ipv6, b, 64), cidr(.ipv6, b, 48))
        default: return nil
        }
    }

    /// Display text, e.g. `Range: 198.51.100.0/24 · 198.51.0.0/16`.
    static func displayText(for ip: String) -> String? {
        ranges(for: ip).map { L10n.format(.networkRangeValue, $0.narrow, $0.wide) }
    }

    /// The CIDR if both IPs are in the same family and the same wide range (IPv4 `/16`, IPv6 `/48`).
    static func sharedWideRange(_ a: String, _ b: String) -> String? {
        guard let ra = ranges(for: a), let rb = ranges(for: b), ra.wide == rb.wide else { return nil }
        return ra.wide
    }

    private static func cidr(_ family: AddressFamily, _ bytes: [UInt8], _ prefix: Int) -> String {
        var masked = bytes
        for i in 0..<masked.count where i >= prefix / 8 { masked[i] = 0 }
        return "\(IPText.string(family: family, bytes: masked) ?? "")/\(prefix)"
    }
}

enum IPFixOutcome: Sendable, Equatable {
    /// A ≠ B and the recheck shows no IP block.
    case resolved(old: String, new: String)
    /// A ≠ B but still `ipBanned`.
    case stillBanned(old: String, new: String)
    /// A ≠ B, still `ipBanned` and same `/16` (IPv6 `/48`): range ban (§17.10).
    case rangeBanned(old: String, new: String, cidr: String)
    /// A = B.
    case ipUnchanged(ip: String, routerURL: URL?)
    /// A ≠ B but the result could not be verified (no recheck / other result).
    case changedUnverified(old: String, new: String, status: BanStatus?)
    /// The network did not come back within 45 s.
    case networkTimeout
    case failed(FixFailure)
    case cancelled

    var isSuccess: Bool {
        if case .resolved = self { return true }
        return false
    }

    /// Stable identifier of the outcome (history `note`, §22).
    var code: String {
        switch self {
        case .resolved: return "resolved"
        case .stillBanned: return "stillBanned"
        case .rangeBanned: return "rangeBanned"
        case .ipUnchanged: return "ipUnchanged"
        case .changedUnverified: return "changedUnverified"
        case .networkTimeout: return "networkTimeout"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// Never falsely claims "resolved": only `resolved` uses that wording.
    var message: String {
        switch self {
        case .resolved(let old, let new):
            return L10n.format(.fixOutcomeResolved, old, new)
        case .stillBanned:
            return L10n.text(.fixOutcomeStillBanned)
        case .rangeBanned(_, _, let cidr):
            return L10n.format(.fixOutcomeRangeBanned, cidr)
        case .ipUnchanged:
            return L10n.text(.fixOutcomeIPUnchanged)
        case .changedUnverified(let old, let new, let status):
            if status == .cidBanned {
                return L10n.format(.fixOutcomeChangedCIDBanned, old, new)
            }
            return L10n.format(.fixOutcomeChangedUnverified, old, new)
        case .networkTimeout:
            return L10n.text(.fixOutcomeNetworkTimeout)
        case .failed(let failure):
            return failure.text
        case .cancelled:
            return L10n.text(.fixOutcomeCancelled)
        }
    }

    /// Next steps for `ipUnchanged` (§17.2/5).
    static var unchangedNextSteps: [String] {
        [L10n.text(.fixUnchangedStep1), L10n.text(.fixUnchangedStep2), L10n.text(.fixUnchangedStep3)]
    }

    /// `rangeBanned` suggestions (§17.10.3); there is no "renew IP" suggestion.
    static var rangeBannedSuggestions: [String] {
        [L10n.text(.fixRangeBannedSuggestion1), L10n.text(.fixRangeBannedSuggestion2),
         L10n.text(.fixRangeBannedSuggestion3)]
    }

    /// When the new IP in a different range is banned too (§17.10.2).
    static var outOfRangeText: String { L10n.text(.fixOutOfRange) }

    /// Possible causes for `stillBanned`, in order (§17.9.3). No automatic fix is suggested.
    static var stillBannedReasons: [String] {
        [L10n.text(.fixStillBannedCause1), L10n.text(.fixStillBannedCause2), L10n.text(.fixStillBannedCause3)]
    }
}

// MARK: - IP ban fixer (§17.2)

struct IPBanFixer: Sendable {
    static let networkWaitTimeout: TimeInterval = 45
    static let networkPollInterval: TimeInterval = 3
    static let wifiOffDuration: TimeInterval = 3

    let runner: any CommandRunning
    let sleeper: any Sleeping
    let now: @Sendable () -> Date
    let fetchPublicIP: @Sendable () async throws -> String
    /// Ban check for that server when A ≠ B; `nil` = could not run (e.g. setting disabled).
    let recheck: @Sendable () async -> BanCheck?
    let progress: @Sendable (FixProgress) async -> Void

    struct Result: Sendable, Equatable {
        let outcome: IPFixOutcome
        let newIP: String?
        let recheck: BanCheck?
    }

    func run() async -> Result {
        await progress(.renewingIP)
        // 2. Old IP (A)
        let oldIP: String
        do {
            oldIP = try await fetchPublicIP()
        } catch is CancellationError {
            return Result(outcome: .cancelled, newIP: nil, recheck: nil)
        } catch {
            return Result(outcome: .failed(.publicIPUnavailable), newIP: nil, recheck: nil)
        }

        // 3. Primary interface
        let route: DefaultRoute
        do {
            guard let parsed = DefaultRoute.parse(try await runner.run(.routeGetDefault).output) else {
                return Result(outcome: .failed(.noDefaultRoute), newIP: nil, recheck: nil)
            }
            route = parsed
        } catch is CancellationError {
            return Result(outcome: .cancelled, newIP: nil, recheck: nil)
        } catch {
            return Result(outcome: .failed(.noDefaultRoute), newIP: nil, recheck: nil)
        }
        let interface = route.interface
        let isWiFi = (try? await runner.run(.airportPowerStatus(interface))).map(AirportPowerStatus.isWiFi) ?? false

        var outcome: IPFixOutcome
        var newIP: String?
        var recheckResult: BanCheck?
        var interfaceMayBeDown = false
        do {
            if isWiFi {
                interfaceMayBeDown = true
                guard try await runner.run(.setAirportPower(interface, on: false)).status == 0 else {
                    throw FixStop.failure(.commandFailed)
                }
                try await sleeper.sleep(seconds: Self.wifiOffDuration)
                guard try await runner.run(.setAirportPower(interface, on: true)).status == 0 else {
                    throw FixStop.failure(.commandFailed)
                }
                interfaceMayBeDown = false
            } else {
                guard try await runner.run(.renewDHCP(interface)).status == 0 else {
                    throw FixStop.failure(.adminDeclined)
                }
            }

            // 4. Wait for the network: at most 45 s, public IP every 3 s
            await progress(.waitingForNetwork)
            let deadline = now().addingTimeInterval(Self.networkWaitTimeout)
            var fetched: String?
            while fetched == nil {
                try await sleeper.sleep(seconds: Self.networkPollInterval)
                do {
                    fetched = try await fetchPublicIP()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if now() >= deadline { throw FixStop.timeout }
                }
            }
            let ip = fetched ?? oldIP
            newIP = ip

            // 5. Compare
            if ip == oldIP {
                outcome = .ipUnchanged(ip: ip, routerURL: route.routerURL)
            } else {
                await progress(.rechecking)
                let check = await recheck()
                recheckResult = check
                switch check?.status {
                case .ipBanned?:
                    if let cidr = IPRange.sharedWideRange(oldIP, ip) {
                        outcome = .rangeBanned(old: oldIP, new: ip, cidr: cidr)
                    } else {
                        outcome = .stillBanned(old: oldIP, new: ip)
                    }
                case .ipOk?, .cidOk?, .cidNotApplicable?:
                    outcome = .resolved(old: oldIP, new: ip)
                default:
                    outcome = .changedUnverified(old: oldIP, new: ip, status: check?.status)
                }
            }
        } catch is CancellationError {
            outcome = .cancelled
        } catch FixStop.timeout {
            outcome = .networkTimeout
        } catch FixStop.failure(let failure) {
            outcome = .failed(failure)
        } catch {
            outcome = .failed(.commandFailed)
        }

        // 6. The interface is always left up: on error/cancellation/timeout `on` is retried.
        if isWiFi, interfaceMayBeDown || !(outcome.isSuccess || outcome.isComparison) {
            let runner = self.runner
            _ = await Task { try? await runner.run(.setAirportPower(interface, on: true)) }.value
        }
        return Result(outcome: outcome, newIP: newIP, recheck: recheckResult)
    }

    private enum FixStop: Error {
        case timeout
        case failure(FixFailure)
    }
}

private extension IPFixOutcome {
    /// Network renewal finished and the IP was compared (interface already up).
    var isComparison: Bool {
        switch self {
        case .resolved, .stillBanned, .rangeBanned, .ipUnchanged, .changedUnverified: return true
        case .networkTimeout, .failed, .cancelled: return false
        }
    }
}

// MARK: - Lock (§17.5)

/// One fix at a time; at least 60 s between two starts.
actor BanFixLock {
    static let interval: TimeInterval = 60

    private var active = false
    private var lastStart: Date?

    func acquire(now: Date) -> Bool {
        if active { return false }
        if let lastStart, now.timeIntervalSince(lastStart) < Self.interval { return false }
        active = true
        lastStart = now
        return true
    }

    func release() {
        active = false
    }
}

// MARK: - Fix kind and classification (§17.1, §17.9.2)

enum FixKind: Sendable, Equatable {
    case ipBan
    case cidBan
    case unreachable

    /// The Fix button appears only on `ipBanned`, `cidBanned`, `unreachable` rows.
    static func forStatus(_ status: BanStatus?) -> FixKind? {
        switch status {
        case .ipBanned?: return .ipBan
        case .cidBanned?: return .cidBan
        case .unreachable?: return .unreachable
        default: return nil
        }
    }
}

enum BanClassification: Sendable, Equatable {
    case engineIP
    case engineCID
    /// `cidUnknown` + `errormsg`/`disconnect`: server rejected, type unknown (could be plugin/SQL).
    case rejectedUnknownType(raw: String)
    case notBan
    case unknown

    static var unverifiedText: String { L10n.text(.banUnverified) }

    static func classify(_ check: BanCheck) -> BanClassification {
        switch check.status {
        case .ipBanned: return .engineIP
        case .cidBanned: return .engineCID
        case .unreachable: return .notBan
        case .cidUnknown:
            let raw = serverText(check.detail)
            let lower = raw.lowercased()
            return lower.hasPrefix("errormsg") || lower.hasPrefix("disconnect") ? .rejectedUnknownType(raw: raw) : .unknown
        case .ipOk, .cidOk, .cidNotApplicable, .unknown: return .unknown
        }
    }

    /// Raw server reply inside `detail` (`"ipOk → cidUnknown: <text>"` → `<text>`).
    static func serverText(_ detail: String) -> String {
        guard let range = detail.range(of: ": ") else { return "" }
        return String(detail[range.upperBound...])
    }

    /// Check type in the appeal text (§17.9.1).
    var checkTypeText: String {
        switch self {
        case .engineIP: return L10n.text(.appealCheckTypeEngineIP)
        case .engineCID: return L10n.text(.appealCheckTypeEngineCID)
        case .rejectedUnknownType, .notBan, .unknown: return L10n.text(.appealCheckTypeUnknown)
        }
    }
}

// MARK: - Server page and appeal text (§17.3, §17.9.1, §17.9.4)

enum GameTrackerLink {
    static func url(host: String, port: Int) -> URL? {
        guard ServerAddress.parse(host) != nil, (1...65_535).contains(port) else { return nil }
        return URL(string: "https://www.gametracker.com/server_info/\(host):\(port)/")
    }
}

struct AppealInput: Sendable, Equatable {
    var serverLabel: String
    var host: String
    var port: Int
    var checkedAt: Date
    var playerName: String
    var cid: String
    var publicIP: String
    var gamedir: String
    var check: BanCheck
    /// §17.10.4: suspected range ban (filled only after `rangeBanned`).
    var rangeBan: RangeBanInfo?
}

struct RangeBanInfo: Sendable, Equatable {
    var cidr: String
    var oldIP: String
    var newIP: String
}

enum AppealText {
    static var adminChecklist: [String] {
        [L10nKey.appealChecklistFind, .appealChecklistRemoveid, .appealChecklistRemoveip, .appealChecklistAmxx,
         .appealChecklistSQL, .appealChecklistFilterban, .appealChecklistRestart].map(L10n.text)
    }

    static func make(_ input: AppealInput, timeZone: TimeZone = .current) -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "tr_TR")
        local.timeZone = timeZone
        local.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let classification = BanClassification.classify(input.check)
        let raw = input.check.detail.isEmpty ? input.check.status.rawValue : input.check.detail
        let rangeLines = input.rangeBan.map {
            [L10n.format(.appealRangeBan, $0.cidr, $0.oldIP, $0.newIP), L10n.format(.appealRangeBanHint, $0.cidr)]
        } ?? []
        let checklist = adminChecklist.enumerated().map { "  \($0.offset + 1). \($0.element)" }
        let lines: [String] = [
            L10n.text(.appealGreeting),
            "",
            L10n.format(.appealServer, input.serverLabel, input.host, String(input.port)),
            L10n.format(.appealCheckedAt, local.string(from: input.checkedAt), utc.string(from: input.checkedAt)),
            L10n.format(.appealPlayerName, input.playerName),
            L10n.format(.appealCID, input.cid),
            L10n.format(.appealPublicIP, input.publicIP),
            L10n.format(.appealClient, input.gamedir),
            L10n.format(.appealServerReply, raw),
            L10n.format(.appealCheckType, classification.checkTypeText),
        ] + rangeLines + [
            "",
            L10n.text(.appealTimedBan),
            "",
            L10n.text(.appealChecklistTitle),
        ] + checklist
        return lines.joined(separator: "\n")
    }
}

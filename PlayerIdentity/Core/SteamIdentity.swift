import Darwin
import Foundation

// MARK: - §76 Join with a Steam identity (optional, generic)

/// §76.2 how the player identifies to a server. `standard` is the engine's own local identity path (the default and
/// the existing behaviour); `steamAuth` goes through a local Steam broker and is used only when the user picks it.
enum JoinIdentity: String, Codable, Sendable, CaseIterable {
    case standard
    case steamAuth

    /// §76.7 JSON `identity` value (`standard` / `steam_auth`).
    var jsonName: String { self == .standard ? "standard" : "steam_auth" }

    /// §76.7 CLI `--identity` value (`standard` / `steam-auth`).
    var cliName: String { self == .standard ? "standard" : "steam-auth" }

    init?(cliName: String) {
        switch cliName {
        case "standard": self = .standard
        case "steam-auth": self = .steamAuth
        default: return nil
        }
    }
}

/// §76.2 where the user's local Steam broker listens and which binary the app may run.
struct SteamBrokerEndpoint: Codable, Sendable, Equatable {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 27420

    var host: String = SteamBrokerEndpoint.defaultHost
    var port: Int = SteamBrokerEndpoint.defaultPort
    /// The broker binary the user chose (free text + picker); `nil` = not configured.
    var executablePath: String?

    var trimmedPath: String? {
        let text = (executablePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var isConfigured: Bool { trimmedPath != nil }

    /// §76.3 the single argument the broker is started with: `<host>:<port>` (fixed shape, no shell, no escaping).
    /// `nil` when the host is not a plain host name / IP literal or the port is out of range.
    var addressArgument: String? {
        guard HostValidator.isValidPort(port),
              host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}$"#, options: .regularExpression) != nil else { return nil }
        return "\(host):\(port)"
    }
}

/// §76.2 live state of the broker.
enum SteamBrokerState: String, Sendable, Equatable {
    case notConfigured
    case notRunning
    case listening
    case unreachable
    case steamSessionMissing
    /// §79 the broker started before the Steam client: its Steam session is outdated.
    case stale

    var title: String {
        switch self {
        case .notConfigured: return L10n.text(.steamStateNotConfigured)
        case .notRunning: return L10n.text(.steamStateNotRunning)
        case .listening: return L10n.text(.steamStateListening)
        case .unreachable: return L10n.text(.steamStateUnreachable)
        case .steamSessionMissing: return L10n.text(.steamStateSessionMissing)
        case .stale: return L10n.text(.steamStateStale)
        }
    }

    /// The "Join with Steam identity" entry can be used.
    var isUsable: Bool { self != .notConfigured }
}

/// §76.3 result of checking the broker binary path before it is ever run.
enum SteamBrokerPathCheck: Sendable, Equatable {
    case valid
    case empty
    case missing
    case notExecutable

    var message: String {
        switch self {
        case .valid: return L10n.text(.steamPathValid)
        case .empty: return L10n.text(.steamPathEmpty)
        case .missing: return L10n.text(.steamPathMissing)
        case .notExecutable: return L10n.text(.steamPathNotExecutable)
        }
    }
}

/// §76.2 what the engine log (or nothing) said about the last connection.
enum JoinOutcome: String, Codable, Sendable, Equatable {
    case success
    case rejected
    case unknown
}

/// §76.2 the last result of one method and when it was seen.
struct IdentityOutcome: Codable, Sendable, Equatable {
    var result: JoinOutcome
    var at: Date
}

/// §76.2 one server's remembered results: one slot per method, so an attempt with one method never erases the
/// result of the other.
struct ServerIdentityRecord: Codable, Sendable, Equatable {
    struct Outcomes: Codable, Sendable, Equatable {
        var standard: IdentityOutcome?
        var steamAuth: IdentityOutcome?

        subscript(identity: JoinIdentity) -> IdentityOutcome? {
            get { identity == .standard ? standard : steamAuth }
            set { if identity == .standard { standard = newValue } else { steamAuth = newValue } }
        }
    }

    var outcomes = Outcomes()
    var lastIdentity: JoinIdentity
    var lastAttemptAt: Date

    init(lastIdentity: JoinIdentity, lastAttemptAt: Date, outcomes: Outcomes = Outcomes()) {
        self.lastIdentity = lastIdentity
        self.lastAttemptAt = lastAttemptAt
        self.outcomes = outcomes
    }

    private enum CodingKeys: String, CodingKey {
        case outcomes, lastIdentity, lastAttemptAt
        /// Older schema: one result for the last method.
        case lastOutcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastIdentity = try container.decode(JoinIdentity.self, forKey: .lastIdentity)
        lastAttemptAt = try container.decode(Date.self, forKey: .lastAttemptAt)
        if let current = try container.decodeIfPresent(Outcomes.self, forKey: .outcomes) {
            outcomes = current
        } else if let legacy = try container.decodeIfPresent(JoinOutcome.self, forKey: .lastOutcome) {
            // The old result belongs to the method that was last used; the other method has none.
            outcomes[lastIdentity] = IdentityOutcome(result: legacy, at: lastAttemptAt)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcomes, forKey: .outcomes)
        try container.encode(lastIdentity, forKey: .lastIdentity)
        try container.encode(lastAttemptAt, forKey: .lastAttemptAt)
    }
}

/// §76.2 per server (normalized `host:port`): the result of each method, the last method and its date. Nothing else
/// is kept: no player name, no SteamID, no address of the player. Persisted in `identity-memory.json`.
struct ServerIdentityMemory: Codable, Sendable, Equatable {
    private(set) var records: [String: ServerIdentityRecord] = [:]

    /// Normalized `host:port` (lower case, IPv6 in brackets).
    static func key(host: String, port: Int) -> String {
        ServerAddressText.hostPort(host: HostValidator.normalized(host), port: port).lowercased()
    }

    func record(host: String, port: Int) -> ServerIdentityRecord? {
        records[Self.key(host: host, port: port)]
    }

    /// An attempt started: the last method and date move, every stored result stays (the answer comes later).
    mutating func noteAttempt(identity: JoinIdentity, host: String, port: Int, at date: Date) {
        let key = Self.key(host: host, port: port)
        var record = records[key] ?? ServerIdentityRecord(lastIdentity: identity, lastAttemptAt: date)
        record.lastIdentity = identity
        record.lastAttemptAt = date
        records[key] = record
    }

    /// The result of one method; the other method's result is untouched.
    mutating func record(identity: JoinIdentity, outcome: JoinOutcome, host: String, port: Int, at date: Date) {
        noteAttempt(identity: identity, host: host, port: port, at: date)
        let key = Self.key(host: host, port: port)
        records[key]?.outcomes[identity] = IdentityOutcome(result: outcome, at: date)
    }

    /// §76.6 `Steam ✓` / `Steam ✗` from the Steam method's own result only; `nil` = never tried (or undecided).
    func badge(host: String, port: Int) -> SteamBadge? {
        switch record(host: host, port: port)?.outcomes.steamAuth?.result {
        case .success?: return .accepted
        case .rejected?: return .refused
        case .unknown?, nil: return nil
        }
    }
}

enum SteamBadge: Sendable, Equatable {
    case accepted
    case refused

    var title: String { self == .accepted ? L10n.text(.steamBadgeOk) : L10n.text(.steamBadgeFailed) }
    var help: String { self == .accepted ? L10n.text(.steamBadgeOkHelp) : L10n.text(.steamBadgeFailedHelp) }
}

/// Reads and writes the two small JSON files of the app's data folder (atomic write; a damaged file reads as empty).
struct SteamIdentityStore: Sendable {
    let brokerFile: URL
    let memoryFile: URL

    init(paths: AppPaths) {
        brokerFile = paths.steamBrokerFile
        memoryFile = paths.identityMemoryFile
    }

    func loadEndpoint() -> SteamBrokerEndpoint {
        guard let data = try? Data(contentsOf: brokerFile),
              let value = try? JSONDecoder().decode(SteamBrokerEndpoint.self, from: data) else { return SteamBrokerEndpoint() }
        return value
    }

    func saveEndpoint(_ endpoint: SteamBrokerEndpoint) throws {
        try FileManager.default.createDirectory(at: brokerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(endpoint).write(to: brokerFile, options: .atomic)
    }

    func loadMemory() -> ServerIdentityMemory {
        guard let data = try? Data(contentsOf: memoryFile),
              let value = try? HistoryCoding.makeDecoder().decode(ServerIdentityMemory.self, from: data) else {
            return ServerIdentityMemory()
        }
        return value
    }

    func saveMemory(_ memory: ServerIdentityMemory) throws {
        try FileManager.default.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HistoryCoding.makeEncoder(pretty: true).encode(memory).write(to: memoryFile, options: .atomic)
    }
}

// MARK: - Broker environment (probes and process control)

/// Read-only probes the broker state is built from. Steam ID, tickets and cookies are never read: the Steam session
/// is only estimated from whether the Steam client process is running (§76.3.5).
protocol SteamBrokerEnvironment: Sendable {
    func pathCheck(_ path: String) -> SteamBrokerPathCheck
    func isPortListening(host: String, port: Int) -> Bool
    /// A process started from the given binary is running (matched by process name).
    func isBrokerProcessRunning(executablePath: String) -> Bool
    func isSteamClientRunning() -> Bool
    /// §79 start time of the Steam client process (`nil` = not running / unknown). Read-only.
    func steamClientStartTime() -> Date?
    /// §79 start time of the newest process of the broker binary (`nil` = not running / unknown). Read-only.
    func brokerProcessStartTime(executablePath: String) -> Date?
    /// §77.2 a regular, executable file (a symbolic link or folder is not); never throws, `false` when unreadable.
    func isExecutableRegularFile(_ path: String) -> Bool
}

/// Starts and stops the broker binary the user chose. It gets exactly one argument, `<host>:<port>` (§76.3).
protocol SteamBrokerProcessControlling: Sendable {
    /// `workingDirectory`: the folder of the broker binary (§78.3; the broker finds its library next to itself).
    func start(executablePath: String, address: String, workingDirectory: String) throws -> Int32
    func stop(pid: Int32)
}

/// Default when nothing is injected (tests): reports nothing and starts nothing.
struct UnavailableSteamBrokerEnvironment: SteamBrokerEnvironment {
    init() {}
    func pathCheck(_ path: String) -> SteamBrokerPathCheck { .missing }
    func isPortListening(host: String, port: Int) -> Bool { false }
    func isBrokerProcessRunning(executablePath: String) -> Bool { false }
    func isSteamClientRunning() -> Bool { false }
    func steamClientStartTime() -> Date? { nil }
    func brokerProcessStartTime(executablePath: String) -> Date? { nil }
    func isExecutableRegularFile(_ path: String) -> Bool { false }
}

struct UnavailableSteamBrokerProcessControl: SteamBrokerProcessControlling {
    init() {}
    func start(executablePath: String, address: String, workingDirectory: String) throws -> Int32 {
        throw CommandError.launchFailed
    }
    func stop(pid: Int32) {}
}

struct SystemSteamBrokerEnvironment: SteamBrokerEnvironment {
    /// The macOS Steam client's main process name.
    static let steamClientProcessName = "steam_osx"

    init() {}

    func pathCheck(_ path: String) -> SteamBrokerPathCheck {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing
        }
        return FileManager.default.isExecutableFile(atPath: expanded) ? .valid : .notExecutable
    }

    /// A TCP connect to the loopback port with a short time limit (nothing is sent).
    func isPortListening(host: String, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 500) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    func isBrokerProcessRunning(executablePath: String) -> Bool {
        let name = ((executablePath as NSString).expandingTildeInPath as NSString).lastPathComponent
        // `proc_name` truncates long names (16 bytes).
        let short = String(name.prefix(15))
        return Self.processNames().contains { $0 == name || $0 == short }
    }

    func isExecutableRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    func isSteamClientRunning() -> Bool {
        Self.processNames().contains(Self.steamClientProcessName)
    }

    func steamClientStartTime() -> Date? {
        Self.processes().filter { $0.name == Self.steamClientProcessName }.compactMap(\.start).max()
    }

    func brokerProcessStartTime(executablePath: String) -> Date? {
        let name = ((executablePath as NSString).expandingTildeInPath as NSString).lastPathComponent
        let short = String(name.prefix(15))
        return Self.processes().filter { $0.name == name || $0.name == short }.compactMap(\.start).max()
    }

    private static func processes() -> [(name: String, start: Date?)] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        var name = [CChar](repeating: 0, count: 256)
        var result: [(name: String, start: Date?)] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            let start = size == Int32(MemoryLayout<proc_bsdinfo>.size)
                ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
                : nil
            result.append((String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), start))
        }
        return result
    }

    private static func processNames() -> [String] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        var name = [CChar](repeating: 0, count: 256)
        var names: [String] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            names.append(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return names
    }
}

/// Runs the broker binary directly (no shell, one `host:port` argument, output discarded) and keeps the `Process` objects it
/// started so `stop` can only ever end a broker this app launched.
final class SystemSteamBrokerProcessControl: SteamBrokerProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]

    init() {}

    func start(executablePath: String, address: String, workingDirectory: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (executablePath as NSString).expandingTildeInPath)
        process.arguments = [address]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
        return process.processIdentifier
    }

    func stop(pid: Int32) {
        lock.lock()
        let process = processes.removeValue(forKey: pid)
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

// MARK: - §77 broker discovery and menu entry

enum SteamBrokerCandidates {
    /// §77.2 the known places, in order.
    static func paths(home: URL) -> [String] {
        [home.path + "/Documents/steam-broker/steam-broker",
         home.path + "/Applications/Steam Broker.app/Contents/MacOS/steam-broker",
         "/opt/homebrew/bin/steam-broker",
         "/usr/local/bin/steam-broker"]
    }

    /// The candidates that are executable regular files (read-only; nothing is created or changed).
    static func find(home: URL, environment: any SteamBrokerEnvironment) -> [String] {
        paths(home: home).filter { environment.isExecutableRegularFile($0) }
    }
}

/// §77.2 what discovery means for Settings.
enum SteamBrokerDiscovery: Sendable, Equatable {
    /// Nothing found.
    case none
    /// No path is set and a broker was found: "Use Found Broker" can write it (with the user's consent).
    case available(String)
    /// A path is set and another broker was found: information only, the path is never overwritten.
    case other(String)

    static func evaluate(found: [String], current: SteamBrokerEndpoint) -> SteamBrokerDiscovery {
        guard let first = found.first else { return .none }
        if !current.isConfigured { return .available(first) }
        if let other = found.first(where: { $0 != current.trimmedPath }) { return .other(other) }
        return .none
    }
}

/// §77.3 the "With Steam identity" entry of the row menu.
struct SteamMenuItem: Sendable, Equatable {
    var title: String
    var isEnabled: Bool
    /// Why the entry is disabled (shown as help text).
    var help: String?
    /// Selecting it starts the broker (after the consent).
    var startsBroker: Bool

    static func make(pathUsable: Bool, state: SteamBrokerState, recommended: Bool) -> SteamMenuItem {
        var parts: [String] = []
        guard pathUsable else {
            parts.append(L10n.text(.steamJoinSteamAuth))
            if recommended { parts.append(L10n.text(.steamJoinRecommended)) }
            return SteamMenuItem(title: parts.joined(separator: " · "), isEnabled: false,
                                 help: L10n.text(.steamJoinDisabledHint), startsBroker: false)
        }
        // §79: a stale broker (Steam restarted) is offered as a restart; §77: a stopped one as a start.
        let starts = state == .notRunning || state == .stale
        parts.append(L10n.text(state == .stale ? .steamJoinSteamAuthRestart
                               : state == .notRunning ? .steamJoinSteamAuthStart : .steamJoinSteamAuth))
        if recommended { parts.append(L10n.text(.steamJoinRecommended)) }
        if !starts { parts.append(state.title) }
        return SteamMenuItem(title: parts.joined(separator: " · "), isEnabled: true, help: nil, startsBroker: starts)
    }
}

// MARK: - Broker manager

/// A prepared broker: `startedByApp` decides whether `release` may stop it (§76.3.3).
struct SteamBrokerSession: Sendable, Equatable {
    let startedByApp: Bool
    let pid: Int32?
}

struct SteamBrokerManager: Sendable {
    /// Wait after starting the broker until its port listens.
    static let startWait: TimeInterval = 8
    static let startPoll: TimeInterval = 0.25
    /// Wait for a stopped (stale) broker to free its port.
    static let stopWait: TimeInterval = 4

    let environment: any SteamBrokerEnvironment
    let control: any SteamBrokerProcessControlling
    let sleep: @Sendable (TimeInterval) async -> Void

    init(environment: any SteamBrokerEnvironment = UnavailableSteamBrokerEnvironment(),
         control: any SteamBrokerProcessControlling = UnavailableSteamBrokerProcessControl(),
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.environment = environment
        self.control = control
        self.sleep = sleep
    }

    /// §78.3 the broker's working directory is the folder of its binary.
    static func workingDirectory(forBinary path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
    }

    func pathCheck(_ endpoint: SteamBrokerEndpoint) -> SteamBrokerPathCheck {
        guard let path = endpoint.trimmedPath else { return .empty }
        return environment.pathCheck(path)
    }

    /// §79.2 the broker is stale when its process started before the Steam client's. Without both start times the
    /// `markedStale` hint (a Steam quit was seen while the app ran) decides.
    static func isStale(brokerStart: Date?, steamStart: Date?, markedStale: Bool) -> Bool {
        guard let brokerStart, let steamStart else { return markedStale }
        return brokerStart < steamStart
    }

    /// §76.3: not configured (no usable path) / listening / Steam session missing (no Steam client process) /
    /// broker process without a listening port (`unreachable`) / not running; §79: `stale` for a listening broker
    /// that predates the Steam client. Read-only.
    func state(_ endpoint: SteamBrokerEndpoint, markedStale: Bool = false) -> SteamBrokerState {
        guard let path = endpoint.trimmedPath, environment.pathCheck(path) == .valid else { return .notConfigured }
        if environment.isPortListening(host: endpoint.host, port: endpoint.port) {
            guard environment.isSteamClientRunning() else { return .steamSessionMissing }
            let stale = Self.isStale(brokerStart: environment.brokerProcessStartTime(executablePath: path),
                                     steamStart: environment.steamClientStartTime(), markedStale: markedStale)
            return stale ? .stale : .listening
        }
        return environment.isBrokerProcessRunning(executablePath: path) ? .unreachable : .notRunning
    }

    /// Makes the broker ready for a join: Steam session present, broker found / started, port listening. A broker
    /// that already listens is the user's own and is never stopped by `release`.
    /// §79: a stale broker the app started itself (`owned`) is stopped and started again; a stale broker the user
    /// started is never touched (`steamBrokerStale`).
    func prepare(_ endpoint: SteamBrokerEndpoint, owned: SteamBrokerSession? = nil,
                 markedStale: Bool = false) async throws -> SteamBrokerSession {
        guard let path = endpoint.trimmedPath, environment.pathCheck(path) == .valid else {
            throw GameLaunchError.steamBrokerNotConfigured
        }
        guard environment.isSteamClientRunning() else { throw GameLaunchError.steamSessionRequired }
        if environment.isPortListening(host: endpoint.host, port: endpoint.port) {
            guard state(endpoint, markedStale: markedStale) == .stale else {
                return SteamBrokerSession(startedByApp: false, pid: nil)
            }
            guard let owned, owned.startedByApp, let oldPID = owned.pid else { throw GameLaunchError.steamBrokerStale }
            control.stop(pid: oldPID)
            var waited: TimeInterval = 0
            while environment.isPortListening(host: endpoint.host, port: endpoint.port), waited <= Self.stopWait {
                await sleep(Self.startPoll)
                waited += Self.startPoll
            }
            if environment.isPortListening(host: endpoint.host, port: endpoint.port) { throw GameLaunchError.steamBrokerStale }
        }
        if environment.isBrokerProcessRunning(executablePath: path) { throw GameLaunchError.steamBrokerUnreachable }
        guard let address = endpoint.addressArgument else { throw GameLaunchError.steamBrokerStartFailed }
        let pid: Int32
        do {
            pid = try control.start(executablePath: path, address: address,
                                    workingDirectory: Self.workingDirectory(forBinary: path))
        } catch {
            throw GameLaunchError.steamBrokerStartFailed
        }
        var waited: TimeInterval = 0
        while waited <= Self.startWait {
            if environment.isPortListening(host: endpoint.host, port: endpoint.port) {
                return SteamBrokerSession(startedByApp: true, pid: pid)
            }
            await sleep(Self.startPoll)
            waited += Self.startPoll
        }
        control.stop(pid: pid)
        throw GameLaunchError.steamBrokerUnreachable
    }

    /// Stops the broker only if this app started it.
    func release(_ session: SteamBrokerSession?) {
        guard let session, session.startedByApp, let pid = session.pid else { return }
        control.stop(pid: pid)
    }
}

// MARK: - Engine log evidence of a join

/// What the engine log says about the last connection to one server (§76.4.5).
enum JoinLogEvidence: Sendable, Equatable {
    case connected
    case disconnected(reason: String)
    case timedOut

    /// A timeout is not an answer of the server: it stays undecided.
    var outcome: JoinOutcome {
        switch self {
        case .connected: return .success
        case .disconnected: return .rejected
        case .timedOut: return .unknown
        }
    }
}

enum JoinLogReader {
    /// The last connection block of `text` for one of `addresses`: the engine entered the server, the server sent a
    /// disconnect reason, or the connection timed out. `nil` = no block (or a stale one: older than `notBefore`).
    /// Works on the console text only; a reason has its IP addresses masked.
    static func evidence(in text: String, addresses: Set<String>, notBefore: Date? = nil,
                         redactor: Redactor = Redactor()) -> JoinLogEvidence? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { GoldSrcEngineLog.clean(String($0)) }
        guard let start = lines.lastIndex(where: { line in
            line.hasPrefix("Connecting to ")
                && GoldSrcEngineLog.connectAddress(line).map { addresses.contains($0.lowercased()) } == true
        }) else { return nil }
        if let notBefore {
            var sessionStart: Date?
            for index in stride(from: start - 1, through: 0, by: -1) {
                if let date = GoldSrcEngineLog.sessionDate(lines[index]) { sessionStart = date; break }
            }
            // No session date at all, or one older than the attempt: no evidence for this attempt.
            guard let sessionStart, sessionStart >= notBefore.addingTimeInterval(-GoldSrcEngineLog.joinTolerance) else {
                return nil
            }
        }
        var timedOut = false
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if GoldSrcEngineLog.sessionDate(line) != nil { break }
            if line.hasPrefix("Connecting to "), let other = GoldSrcEngineLog.connectAddress(line),
               !addresses.contains(other.lowercased()) { break }
            if line.hasPrefix("Spooling demo header") || line.hasPrefix("Connection accepted") || line.hasPrefix("Connected to ") {
                return .connected
            }
            var reason: String?
            if let range = line.range(of: "Server issued disconnect. Reason:") {
                reason = String(line[range.upperBound...])
            } else if line == "Server message" {
                reason = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            } else if line.hasPrefix("Disconnected: ") {
                reason = String(line.dropFirst("Disconnected: ".count))
            }
            if let reason {
                let cleaned = GoldSrcReplies.serverMessage(EngineLogReader.redact(reason, redactor: redactor))
                return .disconnected(reason: cleaned)
            }
            let lowered = line.lowercased()
            if lowered.contains("timed out") || lowered.contains("timeout") || lowered.contains("failed after")
                || lowered.contains("no response") || lowered.contains("connection failed") {
                timedOut = true
            }
            index += 1
        }
        return timedOut ? .timedOut : nil
    }
}

// MARK: - Join flow

/// A started Steam join: the plan that ran and the broker session this app owns (if it started one).
struct SteamJoinHandle: Sendable, Equatable {
    let plan: GameLaunchPlan
    let session: SteamBrokerSession?
    let startedAt: Date
}

/// §76.4 the "Join with Steam identity" flow. The privacy consent comes first: when it is declined nothing is started
/// (no broker, no game). Game configuration files are never written; only the launch line differs.
struct SteamJoinCoordinator: Sendable {
    let launcher: GameLauncher
    let broker: SteamBrokerManager
    let fileSystem: any FileSystemReading
    let now: @Sendable () -> Date
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    /// Time between process checks while the game runs; how long to wait for the game process to appear.
    var pollInterval: TimeInterval = 2
    var appearWait: TimeInterval = 30

    func join(host: String, port: Int, gamedir: String?, known: [String: HostResolution], serverProtocol: ServerProtocol,
              dataRoot: URL?, endpoint: SteamBrokerEndpoint, owned: SteamBrokerSession? = nil,
              markedStale: Bool = false,
              consent: @Sendable () async -> Bool,
              confirmReplace: @Sendable () async -> Bool) async throws -> SteamJoinHandle {
        guard await consent() else { throw GameLaunchError.cancelled }
        let session = try await broker.prepare(endpoint, owned: owned, markedStale: markedStale)
        do {
            let plan = try await launcher.plan(host: host, port: port, gamedir: gamedir, known: known,
                                               serverProtocol: serverProtocol, dataRoot: dataRoot, identity: .steamAuth)
            let startedAt = now()
            try await launcher.launch(plan, confirm: confirmReplace)
            return SteamJoinHandle(plan: plan, session: session, startedAt: startedAt)
        } catch {
            broker.release(session)
            throw error
        }
    }

    /// Waits until the game closes, then stops the broker if this app started it (§76.4.7) and reads the engine log
    /// for the server's real answer (§76.4.5). Returns the outcome to remember.
    func finish(_ handle: SteamJoinHandle, addresses: Set<String>, dataRoot: URL?) async -> JoinOutcome {
        var appeared = false
        var waited: TimeInterval = 0
        while !Task.isCancelled {
            if launcher.detector.isGameRunning() {
                appeared = true
            } else if appeared || waited >= appearWait {
                break
            }
            await sleep(pollInterval)
            waited += pollInterval
        }
        broker.release(handle.session)
        guard let dataRoot else { return .unknown }
        guard case .data(let text) = GoldSrcEngineLog.read(dataRoot: dataRoot, fileSystem: fileSystem) else { return .unknown }
        return JoinLogReader.evidence(in: text, addresses: addresses, notBefore: handle.startedAt)?.outcome ?? .unknown
    }
}

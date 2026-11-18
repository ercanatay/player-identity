import Foundation

// MARK: - §72 Read-only RCON

/// The only commands the console can send (§72.2). There is no free-text input: the UI buttons send these fixed
/// commands and anything else is refused before a packet leaves the Mac.
enum RconCommand: String, CaseIterable, Sendable, Equatable {
    case status
    case stats
    case listip
    case banlist
    case users

    /// The allowlisted command for `text` (exact, lower-case, no arguments); `nil` for anything else.
    init?(allowlisted text: String) {
        self.init(rawValue: text)
    }

    var label: String {
        switch self {
        case .status: return L10n.text(.rconCommandStatus)
        case .stats: return L10n.text(.rconCommandStats)
        case .listip: return L10n.text(.rconCommandListip)
        case .banlist: return L10n.text(.rconCommandBanlist)
        case .users: return L10n.text(.rconCommandUsers)
        }
    }
}

/// One RCON packet: `size:int32, id:int32, type:int32, body, 0x00 0x00` (little-endian; `size` counts everything
/// after itself).
struct RconPacket: Sendable, Equatable {
    /// Auth request (body = password).
    static let typeAuth: Int32 = 3
    /// Command request; in a reply: command output / auth accepted (§72.1).
    static let typeCommand: Int32 = 2
    /// Reply: error.
    static let typeError: Int32 = 0
    /// Id of a refused auth.
    static let refusedID: Int32 = -1

    var id: Int32
    var type: Int32
    var body: [UInt8]

    var text: String { String(decoding: body, as: UTF8.self) }
}

enum RconPackets {
    /// Smallest valid packet: size + id + type + two NULs.
    static let minimumLength = 14

    static func encode(_ packet: RconPacket) -> [UInt8] {
        let size = Int32(4 + 4 + packet.body.count + 2)
        return le(size) + le(packet.id) + le(packet.type) + packet.body + [0x00, 0x00]
    }

    static func auth(id: Int32, password: String) -> [UInt8] {
        encode(RconPacket(id: id, type: RconPacket.typeAuth, body: Array(password.utf8)))
    }

    static func command(id: Int32, _ command: RconCommand) -> [UInt8] {
        encode(RconPacket(id: id, type: RconPacket.typeCommand, body: Array(command.rawValue.utf8)))
    }

    /// `nil` for anything that is not one well-formed RCON packet (short, wrong size, OOB `FF FF FF FF` reply…).
    static func decode(_ bytes: [UInt8]) -> RconPacket? {
        guard bytes.count >= minimumLength, let size = int32(bytes, at: 0), size >= 10,
              Int(size) + 4 <= bytes.count, let id = int32(bytes, at: 4), let type = int32(bytes, at: 8) else { return nil }
        let end = 4 + Int(size)
        guard bytes[end - 1] == 0, bytes[end - 2] == 0 else { return nil }
        var body = Array(bytes[12..<(end - 2)])
        while body.last == 0 { body.removeLast() }
        return RconPacket(id: id, type: type, body: body)
    }

    private static func le(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
    }

    private static func int32(_ bytes: [UInt8], at offset: Int) -> Int32? {
        guard bytes.count >= offset + 4 else { return nil }
        let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
        return Int32(bitPattern: bits)
    }
}

enum RconError: Error, Sendable, Equatable {
    /// Not on the allowlist (never sent).
    case notAllowed
    /// RCON is off for this server.
    case disabled
    case noPassword
    case keychain
    /// No usable address / invalid port / no socket.
    case unreachable
    /// Wrong password (id `-1` or an error reply to the auth).
    case authFailed
    /// No reply after the retries.
    case timeout
    /// The port refused RCON: the send failed or something other than an RCON packet came back.
    case closed
    /// The server answered the command with an error packet; its raw text is shown.
    case rejected(String)

    var text: String {
        switch self {
        case .notAllowed: return L10n.text(.rconErrorNotAllowed)
        case .disabled: return L10n.text(.rconErrorDisabled)
        case .noPassword: return L10n.text(.rconPasswordMissing)
        case .keychain: return L10n.text(.rconErrorKeychain)
        case .unreachable: return L10n.text(.rconErrorUnreachable)
        case .authFailed: return L10n.text(.rconErrorAuth)
        case .timeout: return L10n.text(.rconErrorTimeout)
        case .closed: return L10n.text(.rconErrorClosed)
        case .rejected: return L10n.text(.rconErrorRejected)
        }
    }

    /// Technical `ErrorLog(rcon)` text: the kind only — never the password, address or server text.
    var logMessage: String {
        switch self {
        case .notAllowed: return "notAllowed"
        case .disabled: return "disabled"
        case .noPassword: return "noPassword"
        case .keychain: return "keychain"
        case .unreachable: return "unreachable"
        case .authFailed: return "authFailed"
        case .timeout: return "timeout"
        case .closed: return "closed"
        case .rejected: return "rejected"
        }
    }
}

/// The joined command output of one run.
struct RconOutput: Sendable, Equatable {
    var command: RconCommand
    var text: String
    /// More than `RconClient.maxResponseBytes` arrived; the rest was dropped.
    var truncated: Bool
    var receivedAt: Date

    /// The server did not know the command (shown raw, never retried).
    var isUnknownCommand: Bool {
        // Engine text such as `Unknown command "users"` (matched by its words, any spacing).
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let index = words.firstIndex(of: "unknown"), index + 1 < words.count else { return false }
        return ["command", "cmd"].contains(words[index + 1])
    }
}

typealias RconOutcome = Result<RconOutput, RconError>

// MARK: Client

/// Auth then one allowlisted command on a UDP session (§72.1): 3 s per step, at most 2 retries when nothing comes
/// back, a split reply is joined (packets with the command id) up to 64 KB. A reply is never retried.
struct RconClient: Sendable {
    static let authTimeout: TimeInterval = 3
    static let commandTimeout: TimeInterval = 3
    static let maxRetries = 2
    static let maxResponseBytes = 64 * 1024
    /// Silence after a reply packet that ends a split reply.
    static let fragmentGap: TimeInterval = 0.3
    static let authID: Int32 = 1
    static let commandID: Int32 = 2

    let transport: any UDPTransport
    let now: @Sendable () -> Date

    /// Text entry point: anything not on the allowlist is refused before a socket is opened.
    func run(text: String, endpoint: UDPEndpoint, password: String) async throws -> RconOutcome {
        guard let command = RconCommand(allowlisted: text) else { return .failure(.notAllowed) }
        return try await run(command, endpoint: endpoint, password: password)
    }

    /// Throws only `CancellationError`.
    func run(_ command: RconCommand, endpoint: UDPEndpoint, password: String) async throws -> RconOutcome {
        guard !password.isEmpty else { return .failure(.noPassword) }
        guard let session = try? transport.makeSession(to: endpoint) else { return .failure(.unreachable) }
        defer { session.close() }
        if let error = try await authenticate(session, password: password) { return .failure(error) }
        return try await execute(command, session: session)
    }

    private enum Wait {
        case packet(RconPacket)
        case foreign
        case silence
    }

    /// The next reply within `timeout`: a decoded packet, a non-RCON reply, or silence.
    private func next(_ session: any UDPSession, timeout: TimeInterval) async throws -> Wait {
        guard timeout > 0 else { return .silence }
        let received: [UInt8]?
        do {
            received = try await session.receive(timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .foreign
        }
        guard let received else { return .silence }
        return RconPackets.decode(received).map(Wait.packet) ?? .foreign
    }

    private func authenticate(_ session: any UDPSession, password: String) async throws -> RconError? {
        for _ in 0...Self.maxRetries {
            try Task.checkCancellation()
            do { try session.send(RconPackets.auth(id: Self.authID, password: password)) } catch { return .closed }
            let deadline = now().addingTimeInterval(Self.authTimeout)
            waiting: while true {
                switch try await next(session, timeout: deadline.timeIntervalSince(now())) {
                case .silence: break waiting
                case .foreign: return .closed
                case .packet(let packet):
                    if packet.id == RconPacket.refusedID { return .authFailed }
                    guard packet.id == Self.authID else { continue }
                    if packet.type == RconPacket.typeCommand { return nil }
                    // An empty error-type packet may precede the auth answer; a non-empty one is a refusal.
                    if packet.type == RconPacket.typeError, packet.body.isEmpty { continue }
                    return .authFailed
                }
            }
        }
        return .timeout
    }

    private func execute(_ command: RconCommand, session: any UDPSession) async throws -> RconOutcome {
        for _ in 0...Self.maxRetries {
            try Task.checkCancellation()
            do { try session.send(RconPackets.command(id: Self.commandID, command)) } catch { return .failure(.closed) }
            let deadline = now().addingTimeInterval(Self.commandTimeout)
            var first: RconPacket?
            waiting: while first == nil {
                switch try await next(session, timeout: deadline.timeIntervalSince(now())) {
                case .silence: break waiting
                case .foreign: return .failure(.closed)
                case .packet(let packet):
                    if packet.id == RconPacket.refusedID { return .failure(.authFailed) }
                    if packet.id == Self.commandID { first = packet }
                }
            }
            guard let first else { continue }
            if first.type == RconPacket.typeError {
                return .failure(.rejected(String(decoding: first.body.prefix(Self.maxResponseBytes), as: UTF8.self)))
            }
            return .success(try await collect(command, first: first, session: session))
        }
        return .failure(.timeout)
    }

    /// Joins the output packets that follow the first one until a short silence (or the byte cap).
    private func collect(_ command: RconCommand, first: RconPacket, session: any UDPSession) async throws -> RconOutput {
        var body = first.body
        var truncated = false
        while !truncated {
            guard case .packet(let packet) = try await next(session, timeout: Self.fragmentGap) else { break }
            guard packet.id == Self.commandID, packet.type == RconPacket.typeCommand else { continue }
            body += packet.body
            if body.count > Self.maxResponseBytes { truncated = true }
        }
        if body.count > Self.maxResponseBytes {
            body = Array(body.prefix(Self.maxResponseBytes))
            truncated = true
        }
        return RconOutput(command: command, text: String(decoding: body, as: UTF8.self), truncated: truncated,
                          receivedAt: now())
    }
}

// MARK: Parsing

struct RconPlayer: Sendable, Equatable {
    var name: String
    var score: String
    var time: String
}

/// What the output panel shows (§72.2): a parsed view, or the raw text when the output cannot be parsed.
enum RconParsedOutput: Sendable, Equatable {
    case players([RconPlayer])
    case ips([String])
    /// Line count and the first `RconParser.banLineLimit` lines.
    case bans(count: Int, lines: [String])
    case raw(String)
}

enum RconParser {
    static let banLineLimit = 50

    static func parse(_ output: RconOutput) -> RconParsedOutput {
        if output.isUnknownCommand { return .raw(output.text) }
        let parsed: RconParsedOutput?
        switch output.command {
        case .status: parsed = status(output.text).map(RconParsedOutput.players)
        case .listip: parsed = listip(output.text).map(RconParsedOutput.ips)
        case .banlist: parsed = banlist(output.text).map { .bans(count: $0.count, lines: $0.lines) }
        case .stats, .users: parsed = nil
        }
        return parsed ?? .raw(output.text)
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `status`: the `#` header names the columns after `name` (GoldSrc `frag time …`, Source `uniqueid connected …`);
    /// every `# <n> "<name>" …` row is read against it. `nil` without such a header.
    static func status(_ text: String) -> [RconPlayer]? {
        let all = lines(text)
        guard let header = all.first(where: { $0.hasPrefix("#") && !$0.contains("\"") && $0.lowercased().contains("name") }) else {
            return nil
        }
        let columns = header.dropFirst().split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard let nameIndex = columns.firstIndex(of: "name") else { return nil }
        let after = Array(columns[(nameIndex + 1)...])
        let scoreIndex = after.firstIndex(of: "frag") ?? after.firstIndex(of: "score")
        let timeIndex = after.firstIndex(of: "time") ?? after.firstIndex(of: "connected")
        var players: [RconPlayer] = []
        for line in all where line.hasPrefix("#") && line != header {
            guard let open = line.firstIndex(of: "\""),
                  let close = line[line.index(after: open)...].firstIndex(of: "\"") else { continue }
            let name = String(line[line.index(after: open)..<close])
            let rest = line[line.index(after: close)...].split(whereSeparator: \.isWhitespace).map(String.init)
            func column(_ index: Int?) -> String {
                guard let index, index < rest.count else { return "—" }
                return rest[index]
            }
            players.append(RconPlayer(name: name.isEmpty ? "—" : name, score: column(scoreIndex), time: column(timeIndex)))
        }
        return players
    }

    /// `listip`: the IPv4 address at the start of each line (`1.2.3.4 : permanent`). An "IP filter list" header with
    /// no address = empty list; `nil` when neither is there.
    static func listip(_ text: String) -> [String]? {
        var ips: [String] = []
        for line in lines(text) {
            let token = line.prefix { $0.isNumber || $0 == "." || $0 == "/" }
            let address = token.split(separator: "/").first.map(String.init) ?? ""
            let octets = address.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { continue }
            ips.append(String(token))
        }
        if !ips.isEmpty { return ips }
        // The header of an empty list (`IP filter list: empty`).
        return text.lowercased().contains("filter") ? [] : nil
    }

    /// `banlist`: every non-empty line counts; the first 50 are shown. `nil` for an empty output.
    static func banlist(_ text: String) -> (count: Int, lines: [String])? {
        let all = lines(text)
        guard !all.isEmpty else { return nil }
        return (all.count, Array(all.prefix(banLineLimit)))
    }
}

/// One prepared run (endpoint + password read on the main actor); runs off the main actor.
struct RconRun: Sendable {
    let command: RconCommand
    let endpoint: UDPEndpoint
    let password: String
    let client: RconClient

    func run() async throws -> RconOutcome {
        try await client.run(command, endpoint: endpoint, password: password)
    }
}

/// Keychain account of a server's RCON password (§72.1).
enum RconKeychain {
    static let service = "tr.ercanatay.playeridentity.rcon"

    static func account(_ serverID: UUID) -> String { "rcon.\(serverID.uuidString)" }
}

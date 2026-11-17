import Foundation

// MARK: - §68.1 A2S_PLAYER and A2S_RULES

/// One player of an A2S_PLAYER reply.
struct ServerPlayer: Sendable, Equatable {
    var index: Int
    var name: String
    var score: Int
    /// Time on the server in seconds.
    var durationSec: Double
}

/// One cvar of an A2S_RULES reply.
struct ServerRule: Sendable, Equatable, Hashable {
    var name: String
    var value: String
}

struct ServerPlayersResult: Sendable, Equatable {
    var players: [ServerPlayer]
    /// The reply was over `ServerQueryParser.maxReplyBytes`, split, or ended before the announced count.
    var truncated: Bool
}

struct ServerRulesResult: Sendable, Equatable {
    /// Cvars shown first in the UI (§68.1).
    static let highlightNames = ["sv_password", "sv_cheats", "sv_lan", "sv_region", "mp_timelimit", "mp_friendlyfire",
                                 "maxplayers", "sv_maxplayers"]

    var rules: [ServerRule]
    var truncated: Bool

    func value(_ name: String) -> String? {
        rules.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `sv_password` set (the engine reports a protected cvar as `1`/`0`; a non-empty value other than `0`/`none`
    /// means a password). `nil` when the server did not report `sv_password`.
    var passwordProtected: Bool? {
        guard let raw = value("sv_password") else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !(value.isEmpty || value == "0" || value == "none")
    }

    /// The highlighted cvars the server reported, in `highlightNames` order.
    var highlights: [ServerRule] {
        Self.highlightNames.compactMap { name in value(name).map { ServerRule(name: name, value: $0) } }
    }
}

enum ServerQueryError: Error, Sendable, Equatable {
    /// No challenge after the `W` request and its single retry.
    case noChallenge
    case noReply
    /// The reply is not an A2S_PLAYER / A2S_RULES reply.
    case malformed
    /// No usable address or socket.
    case unreachable
}

enum ServerQueryPackets {
    /// `A2S_SERVERQUERY_GETCHALLENGE`: `FF FF FF FF 57`.
    static func challengeRequest() -> [UInt8] { BanPackets.header + [0x57] }
    /// `A2S_PLAYER`: `FF FF FF FF 55 <challenge>`.
    static func players(challenge: [UInt8]) -> [UInt8] { BanPackets.header + [0x55] + challenge }
    /// `A2S_RULES`: `FF FF FF FF 56 <challenge>`.
    static func rules(challenge: [UInt8]) -> [UInt8] { BanPackets.header + [0x56] + challenge }
}

/// Parses the replies; never traps on short or damaged input (the readable part is kept and `truncated` is set).
enum ServerQueryParser {
    /// Longest reply read; anything after it is cut and the result is marked `truncated` (§68.1).
    static let maxReplyBytes = 4096
    static let playersType: UInt8 = 0x44
    static let rulesType: UInt8 = 0x45
    static let challengeType: UInt8 = 0x41
    static let splitHeader: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF]

    /// 4-byte challenge of an `A` reply.
    static func challenge(_ reply: [UInt8]) -> [UInt8]? {
        guard BanReplies.type(reply) == challengeType, reply.count >= 9 else { return nil }
        return Array(reply[5..<9])
    }

    /// The single-packet payload (`FF FF FF FF <type> …`), at most `maxReplyBytes`; `cut` when anything was dropped.
    /// A GoldSrc split reply (`FE FF FF FF <id:4> <number/total:1>`) keeps only its first packet.
    static func payload(_ reply: [UInt8]) -> (bytes: [UInt8], cut: Bool) {
        var bytes = reply
        var cut = false
        if bytes.count > maxReplyBytes {
            bytes = Array(bytes.prefix(maxReplyBytes))
            cut = true
        }
        if bytes.starts(with: splitHeader) {
            guard bytes.count > 9 else { return ([], true) }
            let total = Int(bytes[8] & 0x0F)
            bytes = Array(bytes[9...])
            if total > 1 { cut = true }
        }
        return (bytes, cut)
    }

    static func parsePlayers(_ reply: [UInt8]) -> ServerPlayersResult? {
        let (bytes, cut) = payload(reply)
        guard BanReplies.type(bytes) == playersType else { return nil }
        var reader = ByteReader(bytes[5...])
        guard let count = reader.byte() else { return ServerPlayersResult(players: [], truncated: true) }
        var players: [ServerPlayer] = []
        for _ in 0..<Int(count) {
            guard let index = reader.byte(), let name = reader.string(), let score = reader.int32(),
                  let duration = reader.float32() else {
                return ServerPlayersResult(players: players, truncated: true)
            }
            players.append(ServerPlayer(index: Int(index), name: name, score: Int(score),
                                        durationSec: duration.isFinite ? max(0, Double(duration)) : 0))
        }
        return ServerPlayersResult(players: players, truncated: cut)
    }

    static func parseRules(_ reply: [UInt8]) -> ServerRulesResult? {
        let (bytes, cut) = payload(reply)
        guard BanReplies.type(bytes) == rulesType else { return nil }
        var reader = ByteReader(bytes[5...])
        guard let count = reader.uint16() else { return ServerRulesResult(rules: [], truncated: true) }
        var rules: [ServerRule] = []
        for _ in 0..<Int(count) {
            guard let name = reader.string(), let value = reader.string() else {
                return ServerRulesResult(rules: rules, truncated: true)
            }
            if !name.isEmpty { rules.append(ServerRule(name: name, value: value)) }
        }
        return ServerRulesResult(rules: rules, truncated: cut)
    }

    /// Little-endian reader over a reply.
    struct ByteReader {
        var bytes: ArraySlice<UInt8>

        init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

        mutating func byte() -> UInt8? {
            guard let first = bytes.first else { return nil }
            bytes = bytes.dropFirst()
            return first
        }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard bytes.count >= count else { return nil }
            let value = Array(bytes.prefix(count))
            bytes = bytes.dropFirst(count)
            return value
        }

        mutating func uint16() -> UInt16? {
            take(2).map { UInt16($0[0]) | UInt16($0[1]) << 8 }
        }

        mutating func int32() -> Int32? {
            take(4).map { Int32(bitPattern: $0.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }) }
        }

        mutating func float32() -> Float? {
            int32().map { Float(bitPattern: UInt32(bitPattern: $0)) }
        }

        /// NUL-terminated, printable, at most 128 characters; `nil` when unterminated.
        mutating func string() -> String? {
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            let raw = bytes[bytes.startIndex..<end]
            bytes = bytes[(end + 1)...]
            return BanReplies.printable(ServerInfoParser.decode(raw), limit: ServerInfoParser.maxStringLength)
        }
    }
}

/// Runs A2S_PLAYER / A2S_RULES over the existing UDP transport: `W` challenge (one retry when it gets none), then the
/// query; a fresh `A` challenge in reply re-sends the query once. Nothing is retried beyond that.
struct ServerQuerier: Sendable {
    /// Wait per packet.
    static let attemptTimeout: TimeInterval = 2

    let transport: any UDPTransport
    let now: @Sendable () -> Date
    let attempt: TimeInterval

    init(transport: any UDPTransport, now: @escaping @Sendable () -> Date,
         attemptTimeout: TimeInterval = ServerQuerier.attemptTimeout) {
        self.transport = transport
        self.now = now
        self.attempt = attemptTimeout
    }

    enum Kind: Sendable { case players, rules }

    private var checker: BanChecker { BanChecker(transport: transport, now: now, stepTimeout: attempt) }

    /// Challenge: `W`, and once more when it gets no `A` reply.
    func challenge(_ session: any UDPSession, until deadline: Date) async throws -> [UInt8]? {
        for _ in 0..<2 {
            let attemptDeadline = min(now().addingTimeInterval(attempt), deadline)
            guard now() < attemptDeadline else { return nil }
            if let reply = try await checker.exchange(session, ServerQueryPackets.challengeRequest(), until: attemptDeadline,
                                                      ignoreInfo: true),
               let value = ServerQueryParser.challenge(reply) {
                return value
            }
        }
        return nil
    }

    /// One query on an open session (the challenge is fetched first). Returns the raw reply.
    func reply(_ kind: Kind, session: any UDPSession, until deadline: Date) async throws -> Result<[UInt8], ServerQueryError> {
        guard var challenge = try await challenge(session, until: deadline) else { return .failure(.noChallenge) }
        for _ in 0..<2 {
            let packet = kind == .players ? ServerQueryPackets.players(challenge: challenge)
                                          : ServerQueryPackets.rules(challenge: challenge)
            let attemptDeadline = min(now().addingTimeInterval(attempt), deadline)
            guard let reply = try await checker.exchange(session, packet, until: attemptDeadline, ignoreInfo: true) else {
                return .failure(.noReply)
            }
            if let fresh = ServerQueryParser.challenge(reply) {
                challenge = fresh
                continue
            }
            return .success(reply)
        }
        return .failure(.noReply)
    }

    func players(_ session: any UDPSession, until deadline: Date) async throws -> Result<ServerPlayersResult, ServerQueryError> {
        try await reply(.players, session: session, until: deadline).flatMap { reply in
            ServerQueryParser.parsePlayers(reply).map { .success($0) } ?? .failure(.malformed)
        }
    }

    func rules(_ session: any UDPSession, until deadline: Date) async throws -> Result<ServerRulesResult, ServerQueryError> {
        try await reply(.rules, session: session, until: deadline).flatMap { reply in
            ServerQueryParser.parseRules(reply).map { .success($0) } ?? .failure(.malformed)
        }
    }

    /// "Sunucu ayrıntıları" → Refresh: players then rules on one session.
    func details(_ endpoint: UDPEndpoint) async throws -> ServerDetailsSnapshot {
        guard let session = try? transport.makeSession(to: endpoint) else {
            return ServerDetailsSnapshot(players: .failure(.unreachable), rules: .failure(.unreachable), at: now())
        }
        defer { session.close() }
        let players = try await self.players(session, until: now().addingTimeInterval(attempt * 4))
        let rules = try await self.rules(session, until: now().addingTimeInterval(attempt * 4))
        return ServerDetailsSnapshot(players: players, rules: rules, at: now())
    }
}

/// The last "Server details" query of one server (never saved).
struct ServerDetailsSnapshot: Sendable, Equatable {
    var players: Result<ServerPlayersResult, ServerQueryError>
    var rules: Result<ServerRulesResult, ServerQueryError>
    var at: Date
}

// MARK: - UI model

/// What the "Server details" section shows (§68.1): player rows, rules (first 50 matching the search), highlights,
/// empty and error texts. Pure, so tests read it without rendering.
struct ServerDetailsViewModel: Equatable {
    static let ruleLimit = 50

    struct PlayerRow: Equatable, Identifiable {
        let id: Int
        let name: String
        let score: String
        let time: String
    }

    var playerRows: [PlayerRow] = []
    var playersTitle: String
    var playersMessage: String?
    var rulesTitle: String
    var rules: [ServerRule] = []
    var rulesMessage: String?
    var moreRules: String?
    var highlights: [ServerRule] = []
    /// `sv_password` reported: `true` = password protected.
    var passwordProtected: Bool?
    var password: String?
    var truncated: Bool

    init(snapshot: ServerDetailsSnapshot, search: String = "") {
        switch snapshot.players {
        case .success(let result):
            playersTitle = L10n.format(.serverDetailsPlayers, String(result.players.count))
            playerRows = result.players.enumerated().map { offset, player in
                PlayerRow(id: offset, name: player.name.isEmpty ? "—" : player.name, score: String(player.score),
                          time: Self.duration(player.durationSec))
            }
            if result.players.isEmpty { playersMessage = L10n.text(.serverDetailsPlayersEmpty) }
        case .failure(let error):
            playersTitle = L10n.format(.serverDetailsPlayers, "—")
            playersMessage = Self.text(error)
        }
        var cut = (try? snapshot.players.get().truncated) ?? false
        switch snapshot.rules {
        case .success(let result):
            cut = cut || result.truncated
            rulesTitle = L10n.format(.serverDetailsRules, String(result.rules.count))
            highlights = result.highlights
            passwordProtected = result.passwordProtected
            password = result.passwordProtected.map { L10n.text($0 ? .serverDetailsPasswordOn : .serverDetailsPasswordOff) }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let matching = query.isEmpty ? result.rules : result.rules.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query)
            }
            rules = Array(matching.prefix(Self.ruleLimit))
            if result.rules.isEmpty {
                rulesMessage = L10n.text(.serverDetailsRulesEmpty)
            } else if matching.isEmpty {
                rulesMessage = L10n.format(.serverDetailsRulesNoMatch, query)
            } else if matching.count > Self.ruleLimit {
                moreRules = L10n.format(.serverDetailsRulesMore, String(Self.ruleLimit), String(matching.count))
            }
        case .failure(let error):
            rulesTitle = L10n.format(.serverDetailsRules, "—")
            rulesMessage = Self.text(error)
        }
        truncated = cut
    }

    static func text(_ error: ServerQueryError) -> String {
        switch error {
        case .noChallenge: return L10n.text(.serverDetailsErrorNoChallenge)
        case .noReply: return L10n.text(.serverDetailsErrorNoReply)
        case .malformed: return L10n.text(.serverDetailsErrorMalformed)
        case .unreachable: return L10n.text(.serverDetailsErrorUnreachable)
        }
    }

    /// `h:mm:ss` or `m:ss`.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

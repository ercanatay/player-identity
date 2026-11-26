import Foundation

/// §75.1 server protocol, decided by the A2S_INFO reply.
/// - `source49`: Source/Xash A2S_INFO reply (`0x49`) with protocol byte 49.
/// - `goldsrc48`: GoldSrc legacy A2S_INFO reply (`0x6D`) with the GoldSrc protocol byte, or a Source-layout reply
///   (`0x49`) with protocol byte 48 (HLDS/ReHLDS send both; §75.2, v5.4.3).
/// - `unknown`: no reply, a truncated, unrecognized or inconsistent reply, or an older record without the field.
enum ServerProtocol: String, Codable, Sendable, CaseIterable {
    case unknown
    case source49
    case goldsrc48

    /// An unknown value in a record (written by a newer version) reads as `unknown`, never as an error.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ServerProtocol(rawValue: raw) ?? .unknown
    }

    /// §75.3: the CID applies only on `source49`, never on `goldsrc48`; `unknown` makes no CID decision (`nil`).
    var cidApplicable: Bool? {
        switch self {
        case .source49: return true
        case .goldsrc48: return false
        case .unknown: return nil
        }
    }
}

/// Server info from the A2S_INFO reply of ban check step (a) (§21). Every field is optional.
struct ServerInfo: Codable, Sendable, Equatable {
    var name: String?
    var map: String?
    var players: Int?
    var maxPlayers: Int?
    /// Round-trip time of the A2S_INFO request that produced the reply.
    var pingMillis: Int?
    /// §75.1 protocol of the reply; `unknown` in older records (the field is absent there).
    var serverProtocol: ServerProtocol
    /// §75.2 protocol byte as sent by the server (`nil` when the reply ended before it).
    var protocolVersion: Int?
    /// Game folder (`gamedir`, e.g. `valve`) and game description (e.g. `Half-Life`).
    var folder: String?
    var game: String?
    /// §75.1 the address string of a GoldSrc legacy reply: kept in the model, never used to launch or connect.
    var reportedAddress: String?

    init(name: String? = nil, map: String? = nil, players: Int? = nil, maxPlayers: Int? = nil, pingMillis: Int? = nil,
         serverProtocol: ServerProtocol = .unknown, protocolVersion: Int? = nil, folder: String? = nil,
         game: String? = nil, reportedAddress: String? = nil) {
        self.name = name
        self.map = map
        self.players = players
        self.maxPlayers = maxPlayers
        self.pingMillis = pingMillis
        self.serverProtocol = serverProtocol
        self.protocolVersion = protocolVersion
        self.folder = folder
        self.game = game
        self.reportedAddress = reportedAddress
    }

    private enum CodingKeys: String, CodingKey {
        case name, map, players
        case maxPlayers = "max"
        case pingMillis
        case serverProtocol = "protocol"
        case protocolVersion, folder, game, reportedAddress
    }

    /// Records written before §75 have no protocol fields: they read as `unknown` (the record is kept).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        map = try container.decodeIfPresent(String.self, forKey: .map)
        players = try container.decodeIfPresent(Int.self, forKey: .players)
        maxPlayers = try container.decodeIfPresent(Int.self, forKey: .maxPlayers)
        pingMillis = try container.decodeIfPresent(Int.self, forKey: .pingMillis)
        serverProtocol = (try? container.decodeIfPresent(ServerProtocol.self, forKey: .serverProtocol)) ?? .unknown
        protocolVersion = try? container.decodeIfPresent(Int.self, forKey: .protocolVersion)
        folder = try? container.decodeIfPresent(String.self, forKey: .folder)
        game = try? container.decodeIfPresent(String.self, forKey: .game)
        reportedAddress = try? container.decodeIfPresent(String.self, forKey: .reportedAddress)
    }

    /// The new fields are written only when set, so records without a protocol stay byte-identical.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(map, forKey: .map)
        try container.encodeIfPresent(players, forKey: .players)
        try container.encodeIfPresent(maxPlayers, forKey: .maxPlayers)
        try container.encodeIfPresent(pingMillis, forKey: .pingMillis)
        if serverProtocol != .unknown { try container.encode(serverProtocol, forKey: .serverProtocol) }
        try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encodeIfPresent(game, forKey: .game)
        try container.encodeIfPresent(reportedAddress, forKey: .reportedAddress)
    }

    var isEmpty: Bool { name == nil && map == nil && players == nil && maxPlayers == nil && pingMillis == nil }
}

/// What `ServerInfoParser.inspect` saw: the (possibly partial) info, whether the layout was complete, and the
/// number of unexpected bytes after a complete GoldSrc legacy reply (§75.2: kept `goldsrc48`, reported as a warning).
struct ServerInfoInspection: Sendable, Equatable {
    var info: ServerInfo?
    /// The reply is an A2S_INFO reply but a field is missing, unterminated or inconsistent.
    var malformed: Bool
    var trailingBytes: Int
}

/// Parses GoldSrc (`0x6D`) and Source (`0x49`) A2S_INFO replies. Never traps on truncated or oversized input:
/// a field that cannot be read is `nil`, and so is everything after it; such a reply is `unknown` (§75.2).
enum ServerInfoParser {
    static let goldSrcType: UInt8 = 0x6D
    static let sourceType: UInt8 = 0x49
    /// Longest string kept from a reply (characters).
    static let maxStringLength = 128
    /// §75.2 protocol byte of a Source/Xash reply that makes it `source49`.
    static let sourceProtocol: UInt8 = 49
    /// §75.2 (v5.4.3) protocol byte of a Source-layout reply of a GoldSrc 48 server.
    static let sourceLayoutGoldSrcProtocol: UInt8 = 48
    /// §75.2 protocol bytes of a GoldSrc legacy (`0x6D`) reply that make it `goldsrc48`: GoldSrc network protocol 48
    /// servers (HLDS/ReHLDS) report 47 in this legacy reply (captured from a public server); 48 is accepted as well.
    static let goldSrcProtocols: Set<UInt8> = [47, 48]

    /// `nil` if the reply is not an A2S_INFO reply.
    static func parse(_ reply: [UInt8]) -> ServerInfo? {
        inspect(reply).info
    }

    /// §75.2: `0x6D` → legacy layout, `0x49` → Source layout, any other type → not an info reply (`nil`).
    static func inspect(_ reply: [UInt8]) -> ServerInfoInspection {
        guard let type = BanReplies.type(reply), type == goldSrcType || type == sourceType else {
            return ServerInfoInspection(info: nil, malformed: false, trailingBytes: 0)
        }
        var reader = Reader(bytes: reply[5...])
        return type == goldSrcType ? legacy(&reader) : source(&reader)
    }

    /// Legacy layout: address (ignored for connecting), name, map, folder, game, players, max, protocol, server type,
    /// environment, visibility, mod flag [mod fields: link, download link, null byte, version (4), size (4), type,
    /// dll], VAC, bots.
    private static func legacy(_ reader: inout Reader) -> ServerInfoInspection {
        var info = ServerInfo()
        func partial() -> ServerInfoInspection { ServerInfoInspection(info: info, malformed: true, trailingBytes: 0) }
        guard let address = reader.string() else { return partial() }
        info.reportedAddress = address.isEmpty ? nil : address
        info.name = reader.string().nonEmpty
        info.map = reader.string().nonEmpty
        guard let folder = reader.string() else { return partial() }
        info.folder = folder.isEmpty ? nil : folder
        guard let game = reader.string() else { return partial() }
        info.game = game.isEmpty ? nil : game
        info.players = reader.byte().map(Int.init)
        info.maxPlayers = reader.byte().map(Int.init)
        guard let protocolByte = reader.byte() else { return partial() }
        info.protocolVersion = Int(protocolByte)
        // server type, environment, visibility, mod flag
        guard reader.skip(3), let mod = reader.byte() else { return partial() }
        if mod == 1 {
            guard reader.string() != nil, reader.string() != nil, reader.skip(1 + 4 + 4 + 1 + 1) else { return partial() }
        }
        // VAC, bots
        guard reader.skip(2), !reader.failed else { return partial() }
        guard goldSrcProtocols.contains(protocolByte) else { return partial() }
        info.serverProtocol = .goldsrc48
        return ServerInfoInspection(info: info, malformed: false, trailingBytes: reader.bytes.count)
    }

    /// Source layout: protocol, name, map, folder, game, app id (2), players, max, … (the rest is not needed).
    private static func source(_ reader: inout Reader) -> ServerInfoInspection {
        var info = ServerInfo()
        func partial() -> ServerInfoInspection { ServerInfoInspection(info: info, malformed: true, trailingBytes: 0) }
        guard let protocolByte = reader.byte() else { return partial() }
        info.protocolVersion = Int(protocolByte)
        info.name = reader.string().nonEmpty
        info.map = reader.string().nonEmpty
        guard let folder = reader.string() else { return partial() }
        info.folder = folder.isEmpty ? nil : folder
        guard let game = reader.string() else { return partial() }
        info.game = game.isEmpty ? nil : game
        guard reader.skip(2) else { return partial() }
        info.players = reader.byte().map(Int.init)
        info.maxPlayers = reader.byte().map(Int.init)
        guard !reader.failed else { return partial() }
        // §75.2: 49 → `source49`; 48 → `goldsrc48` (a GoldSrc 48 server's Source-layout reply); anything else decides
        // nothing.
        switch protocolByte {
        case sourceProtocol: info.serverProtocol = .source49
        case sourceLayoutGoldSrcProtocol: info.serverProtocol = .goldsrc48
        default: return partial()
        }
        return ServerInfoInspection(info: info, malformed: false, trailingBytes: 0)
    }

    /// UTF-8 if valid, otherwise ISO Latin-1 (GoldSrc servers often send Latin-1 names).
    static func decode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let array = Array(bytes)
        return String(bytes: array, encoding: .utf8) ?? String(bytes: array, encoding: .isoLatin1) ?? ""
    }

    private struct Reader {
        var bytes: ArraySlice<UInt8>
        var failed = false

        /// NUL-terminated string (printable, truncated); `nil` and a failed reader if unterminated.
        mutating func string() -> String? {
            guard !failed, let end = bytes.firstIndex(of: 0) else { failed = true; return nil }
            let raw = bytes[bytes.startIndex..<end]
            bytes = bytes[(end + 1)...]
            return BanReplies.printable(ServerInfoParser.decode(raw), limit: ServerInfoParser.maxStringLength)
        }

        mutating func byte() -> UInt8? {
            guard !failed, let first = bytes.first else { failed = true; return nil }
            bytes = bytes.dropFirst()
            return first
        }

        mutating func skip(_ count: Int) -> Bool {
            guard !failed, bytes.count >= count else { failed = true; return false }
            bytes = bytes.dropFirst(count)
            return true
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

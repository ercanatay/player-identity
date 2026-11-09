import Foundation

/// Server info from the A2S_INFO reply of ban check step (a) (§21). Every field is optional.
struct ServerInfo: Codable, Sendable, Equatable {
    var name: String?
    var map: String?
    var players: Int?
    var maxPlayers: Int?
    /// Round-trip time of the A2S_INFO request that produced the reply.
    var pingMillis: Int?

    init(name: String? = nil, map: String? = nil, players: Int? = nil, maxPlayers: Int? = nil, pingMillis: Int? = nil) {
        self.name = name
        self.map = map
        self.players = players
        self.maxPlayers = maxPlayers
        self.pingMillis = pingMillis
    }

    private enum CodingKeys: String, CodingKey {
        case name, map, players
        case maxPlayers = "max"
        case pingMillis
    }

    var isEmpty: Bool { name == nil && map == nil && players == nil && maxPlayers == nil && pingMillis == nil }
}

/// Parses GoldSrc (`0x6D`) and Source (`0x49`) A2S_INFO replies. Never traps on truncated or oversized input:
/// a field that cannot be read is `nil`, and so is everything after it.
enum ServerInfoParser {
    static let goldSrcType: UInt8 = 0x6D
    static let sourceType: UInt8 = 0x49
    /// Longest string kept from a reply (characters).
    static let maxStringLength = 128

    /// `nil` if the reply is not an A2S_INFO reply.
    static func parse(_ reply: [UInt8]) -> ServerInfo? {
        guard let type = BanReplies.type(reply), type == goldSrcType || type == sourceType else { return nil }
        var reader = Reader(bytes: reply[5...])
        var info = ServerInfo()
        if type == goldSrcType {
            // address, name, map, folder, game, players, max, protocol, …
            guard reader.string() != nil else { return info }
            info.name = reader.string().nonEmpty
            info.map = reader.string().nonEmpty
            guard reader.string() != nil, reader.string() != nil else { return info }
        } else {
            // protocol, name, map, folder, game, app id (2), players, max, bots, …
            guard reader.byte() != nil else { return info }
            info.name = reader.string().nonEmpty
            info.map = reader.string().nonEmpty
            guard reader.string() != nil, reader.string() != nil, reader.skip(2) else { return info }
        }
        info.players = reader.byte().map(Int.init)
        info.maxPlayers = reader.byte().map(Int.init)
        return info
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

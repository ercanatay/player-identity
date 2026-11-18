import Foundation

// MARK: - §70.1 Master query

/// One server address of the GoldSrc master list (IPv4 + port, as sent by the master).
struct BrowserAddress: Hashable, Sendable, Comparable {
    /// 4 bytes, network order.
    let ip: [UInt8]
    let port: UInt16

    init(ip: [UInt8], port: UInt16) {
        self.ip = ip
        self.port = port
    }

    /// `a.b.c.d:port` (the master's request seed and the cache form); `nil` for anything else.
    init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 3, octet.allSatisfy(\.isASCII), let value = UInt8(octet) else { return nil }
            bytes.append(value)
        }
        self.init(ip: bytes, port: port)
    }

    /// `0.0.0.0:0`: the first request's seed and the master's end-of-list marker.
    static let zero = BrowserAddress(ip: [0, 0, 0, 0], port: 0)

    var isZero: Bool { self == .zero }
    var host: String { ip.map(String.init).joined(separator: ".") }
    /// `a.b.c.d:port`; also the `host:port` key that matches a saved server.
    var id: String { "\(host):\(port)" }
    var endpoint: UDPEndpoint { UDPEndpoint(address: .ipv4(ip), port: port) }

    static func < (lhs: BrowserAddress, rhs: BrowserAddress) -> Bool {
        lhs.ip.lexicographicallyPrecedes(rhs.ip) || (lhs.ip == rhs.ip && lhs.port < rhs.port)
    }
}

extension BrowserAddress: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let address = BrowserAddress(text: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "address")
        }
        self = address
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

/// Master server packets (§70.1).
enum MasterPackets {
    static let requestType: UInt8 = 0x31
    /// Region code: the whole world.
    static let regionAll: UInt8 = 0xFF
    static let replyHeader: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x66, 0x0A]
    static let recordSize = 6

    /// `31 FF "<last ip>:<port>" 00 <filter> 00`; the first request seeds with `0.0.0.0:0`. The filter is empty (the
    /// GoldSrc master only lists GoldSrc servers; no Source filters), but its terminator is part of the packet.
    static func request(after seed: BrowserAddress = .zero, filter: String = "") -> [UInt8] {
        [requestType, regionAll] + Array(seed.id.utf8) + [0x00] + Array(filter.utf8) + [0x00]
    }

    /// The 6-byte records (IP × 4, port × 2, big-endian) after the `FF FF FF FF 66 0A` header; a trailing partial
    /// record is ignored. `nil` when the header does not match.
    static func parse(_ reply: [UInt8]) -> [BrowserAddress]? {
        guard reply.starts(with: replyHeader) else { return nil }
        let body = reply.dropFirst(replyHeader.count)
        var addresses: [BrowserAddress] = []
        addresses.reserveCapacity(body.count / recordSize)
        var index = body.startIndex
        while body.endIndex - index >= recordSize {
            let ip = Array(body[index..<index + 4])
            let port = UInt16(body[index + 4]) << 8 | UInt16(body[index + 5])
            addresses.append(BrowserAddress(ip: ip, port: port))
            index += recordSize
        }
        return addresses
    }
}

enum MasterQueryError: Error, Sendable, Equatable {
    /// The master's name could not be resolved.
    case dns
    /// No socket, or the request could not be sent.
    case network
    /// No reply within the request / total limits.
    case timeout
}

struct MasterQueryResult: Sendable, Equatable {
    enum End: Sendable, Equatable {
        /// End-of-list marker, an empty page or a page with no new address.
        case complete
        /// `maxAddresses` reached.
        case limit
        /// A later page did not arrive in time (the earlier pages are kept).
        case timeout
    }

    var addresses: [BrowserAddress]
    var end: End
}

/// Pages through the GoldSrc master: one request per page seeded with the last address of the previous page; stops
/// on the end marker, an empty or repeated page, the address limit or the total time. Cancellable.
struct MasterServerQuery: Sendable {
    static let defaultHost = "hl1master.steampowered.com"
    static let defaultPort: UInt16 = 27010
    static let requestTimeout: TimeInterval = 2
    static let totalTimeout: TimeInterval = 30
    static let maxAddresses = 5000

    let transport: any UDPTransport
    let resolver: any ServerAddressResolver
    let now: @Sendable () -> Date
    var host = MasterServerQuery.defaultHost
    var port = MasterServerQuery.defaultPort
    var requestTimeout = MasterServerQuery.requestTimeout
    var totalTimeout = MasterServerQuery.totalTimeout
    var maxAddresses = MasterServerQuery.maxAddresses

    /// `host:port` of the master (the cache records which master it came from).
    var name: String { "\(host):\(port)" }

    func run(progress: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> MasterQueryResult {
        let start = now()
        let deadline = start.addingTimeInterval(totalTimeout)
        let address = try await resolve()
        try Task.checkCancellation()
        guard let session = try? transport.makeSession(to: UDPEndpoint(address: address, port: port)) else {
            throw MasterQueryError.network
        }
        defer { session.close() }

        var seed = BrowserAddress.zero
        var seen = Set<BrowserAddress>()
        var addresses: [BrowserAddress] = []
        while true {
            try Task.checkCancellation()
            guard now() < deadline else { return try partial(addresses) }
            do {
                try session.send(MasterPackets.request(after: seed))
            } catch {
                guard addresses.isEmpty else { return MasterQueryResult(addresses: addresses, end: .timeout) }
                throw MasterQueryError.network
            }
            guard let page = try await receivePage(session, until: min(now().addingTimeInterval(requestTimeout), deadline)) else {
                return try partial(addresses)
            }
            var fresh = 0
            var ended = false
            for record in page {
                if record.isZero { ended = true; break }
                guard seen.insert(record).inserted else { continue }
                addresses.append(record)
                fresh += 1
                if addresses.count >= maxAddresses {
                    await progress(addresses.count)
                    return MasterQueryResult(addresses: addresses, end: .limit)
                }
            }
            await progress(addresses.count)
            guard !ended, fresh > 0, let last = page.last(where: { !$0.isZero }), last != seed else {
                return MasterQueryResult(addresses: addresses, end: .complete)
            }
            seed = last
        }
    }

    /// A missing page: the earlier pages are the (partial) result; nothing at all is a timeout.
    private func partial(_ addresses: [BrowserAddress]) throws -> MasterQueryResult {
        guard !addresses.isEmpty else { throw MasterQueryError.timeout }
        return MasterQueryResult(addresses: addresses, end: .timeout)
    }

    /// IP literal as is; a name through the resolver (IPv4 only: the master lists IPv4 servers).
    private func resolve() async throws -> ServerAddress {
        switch HostValidator.classify(host) {
        case .address(let address):
            return address
        case .hostname(let name):
            let found: [ServerAddress]
            do {
                found = try await resolver.addresses(for: name)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MasterQueryError.dns
            }
            guard let address = found.first(where: { if case .ipv4 = $0 { return true } else { return false } }) ?? found.first else {
                throw MasterQueryError.dns
            }
            return address
        case nil:
            throw MasterQueryError.dns
        }
    }

    /// First master reply until the deadline (other datagrams are skipped).
    private func receivePage(_ session: any UDPSession, until deadline: Date) async throws -> [BrowserAddress]? {
        while true {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { return nil }
            let received: [UInt8]?
            do {
                received = try await session.receive(timeout: remaining)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            guard let reply = received else { return nil }
            if let page = MasterPackets.parse(reply) { return page }
        }
    }
}

// MARK: - §70.2 Server info

/// One server that answered A2S_INFO (kept in memory only).
struct BrowserServer: Identifiable, Equatable, Sendable {
    let address: BrowserAddress
    var name: String
    var map: String
    var players: Int
    var maxPlayers: Int
    var pingMillis: Int
    /// A2S_INFO `visibility`; `nil` when the reply ended before it.
    var passworded: Bool?

    var id: String { address.id }
    /// The name, or the address when the server sent none.
    var displayName: String { name.isEmpty ? address.id : name }
}

/// A2S_INFO reply → `BrowserServer` (name, map, players via `ServerInfoParser`; `visibility` read here).
enum BrowserInfoParser {
    static func parse(_ reply: [UInt8], address: BrowserAddress, pingMillis: Int) -> BrowserServer? {
        guard let info = ServerInfoParser.parse(reply) else { return nil }
        return BrowserServer(address: address, name: info.name ?? "", map: info.map ?? "", players: info.players ?? 0,
                             maxPlayers: info.maxPlayers ?? 0, pingMillis: max(0, pingMillis),
                             passworded: visibility(reply))
    }

    /// GoldSrc `0x6D`: address, name, map, folder, game, players, max, protocol, type, environment, **visibility**.
    /// Source `0x49`: protocol, name, map, folder, game, app id (2), players, max, bots, type, environment,
    /// **visibility**.
    static func visibility(_ reply: [UInt8]) -> Bool? {
        guard let type = BanReplies.type(reply) else { return nil }
        var reader = ServerQueryParser.ByteReader(reply[5...])
        switch type {
        case ServerInfoParser.goldSrcType:
            for _ in 0..<5 { guard reader.string() != nil else { return nil } }
            guard reader.take(5) != nil else { return nil }   // players, max, protocol, type, environment
        case ServerInfoParser.sourceType:
            guard reader.byte() != nil else { return nil }
            for _ in 0..<4 { guard reader.string() != nil else { return nil } }
            guard reader.take(7) != nil else { return nil }   // app id (2), players, max, bots, type, environment
        default:
            return nil
        }
        return reader.byte().map { $0 != 0 }
    }
}

/// Progress of a scan, for the window's progress line and the live table.
enum BrowserProgress: Sendable, Equatable {
    /// Master pages so far.
    case master(addresses: Int)
    /// A2S_INFO: `asked` of `total` finished, `answered` replied; `server` = the reply that just arrived.
    case servers(asked: Int, answered: Int, total: Int, server: BrowserServer?)
}

struct BrowserCollection: Sendable, Equatable {
    var servers: [BrowserServer]
    /// Addresses that were asked (the rest were skipped by the total time limit).
    var asked: Int
    var timedOut: Bool
}

/// A2S_INFO for the master's addresses: at most `concurrency` at a time, `perServer` seconds each, `total` seconds
/// for all (no new query starts after it); silent and malformed servers are dropped. Cancellable.
struct BrowserInfoCollector: Sendable {
    static let concurrency = 20
    static let perServer: TimeInterval = 2
    static let total: TimeInterval = 20

    let transport: any UDPTransport
    let now: @Sendable () -> Date
    var concurrency = BrowserInfoCollector.concurrency
    var perServer = BrowserInfoCollector.perServer
    var total = BrowserInfoCollector.total

    func collect(_ addresses: [BrowserAddress],
                 progress: @escaping @Sendable (BrowserProgress) async -> Void = { _ in }) async throws -> BrowserCollection {
        let deadline = now().addingTimeInterval(total)
        let limit = max(1, concurrency)
        return try await withThrowingTaskGroup(of: BrowserServer?.self) { group in
            var pending = addresses.makeIterator()
            var running = 0
            var started = 0
            var finished = 0
            var servers: [BrowserServer] = []
            while running < limit, now() < deadline, let next = pending.next() {
                group.addTask { try await query(next, until: deadline) }
                running += 1
                started += 1
            }
            while let result = try await group.next() {
                running -= 1
                finished += 1
                if let result { servers.append(result) }
                await progress(.servers(asked: finished, answered: servers.count, total: addresses.count, server: result))
                while running < limit, now() < deadline, let next = pending.next() {
                    group.addTask { try await query(next, until: deadline) }
                    running += 1
                    started += 1
                }
            }
            try Task.checkCancellation()
            return BrowserCollection(servers: servers, asked: started, timedOut: started < addresses.count)
        }
    }

    /// One A2S_INFO (a challenge reply re-sends it once, within the same time); `nil` = no usable reply.
    func query(_ address: BrowserAddress, until deadline: Date) async throws -> BrowserServer? {
        try Task.checkCancellation()
        guard let session = try? transport.makeSession(to: address.endpoint) else { return nil }
        defer { session.close() }
        let limit = min(now().addingTimeInterval(perServer), deadline)
        let checker = BanChecker(transport: transport, now: now, stepTimeout: perServer)
        var sentAt = now()
        guard var reply = try await checker.exchange(session, BanPackets.info(), until: limit, ignoreInfo: false) else {
            return nil
        }
        if case .challenge(let challenge) = BanReplies.classifyInfo(reply) {
            sentAt = now()
            guard let second = try await checker.exchange(session, BanPackets.info(challenge: challenge), until: limit,
                                                          ignoreInfo: false) else { return nil }
            reply = second
        }
        let ping = Int((now().timeIntervalSince(sentAt) * 1000).rounded())
        return BrowserInfoParser.parse(reply, address: address, pingMillis: ping)
    }
}

// MARK: - Filter and sort

enum BrowserSort: String, CaseIterable, Sendable {
    /// Most players first.
    case players
    /// Lowest ping first.
    case ping
    /// Name A → Z.
    case name
}

/// The window's filter bar (§70.2).
struct BrowserFilter: Equatable, Sendable {
    /// Rows shown at most; the rest asks to narrow the filter.
    static let displayLimit = 300

    var map = ""
    var name = ""
    var minPlayers: Int?
    var notEmpty = false
    var noPassword = false
    var maxPing: Int?
    var sort = BrowserSort.players

    var isActive: Bool {
        !map.trimmed.isEmpty || !name.trimmed.isEmpty || (minPlayers ?? 0) > 0 || notEmpty || noPassword || maxPing != nil
    }

    func matches(_ server: BrowserServer) -> Bool {
        let map = map.trimmed
        let name = name.trimmed
        if !map.isEmpty, !server.map.localizedCaseInsensitiveContains(map) { return false }
        if !name.isEmpty, !server.name.localizedCaseInsensitiveContains(name) { return false }
        if let minPlayers, server.players < minPlayers { return false }
        if notEmpty, server.players <= 0 { return false }
        if noPassword, server.passworded == true { return false }
        if let maxPing, server.pingMillis > maxPing { return false }
        return true
    }

    func sorted(_ servers: [BrowserServer]) -> [BrowserServer] {
        servers.sorted { lhs, rhs in
            switch sort {
            case .players:
                if lhs.players != rhs.players { return lhs.players > rhs.players }
                if lhs.pingMillis != rhs.pingMillis { return lhs.pingMillis < rhs.pingMillis }
            case .ping:
                if lhs.pingMillis != rhs.pingMillis { return lhs.pingMillis < rhs.pingMillis }
                if lhs.players != rhs.players { return lhs.players > rhs.players }
            case .name:
                let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return lhs.address < rhs.address
        }
    }

    func apply(_ servers: [BrowserServer]) -> BrowserListing {
        let matching = sorted(servers.filter(matches))
        return BrowserListing(rows: Array(matching.prefix(Self.displayLimit)), matched: matching.count, total: servers.count)
    }
}

struct BrowserListing: Equatable, Sendable {
    var rows: [BrowserServer]
    /// Servers that pass the filter (may exceed `rows`).
    var matched: Int
    /// Servers that answered.
    var total: Int

    var isCut: Bool { matched > rows.count }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - §70.4 Caches

/// `master-cache.json`: the master's addresses only (no names, maps or pings), kept 24 hours. A missing, damaged,
/// stale or foreign file is ignored and replaced by the next successful master query.
struct MasterCacheStore: Sendable {
    static let fileName = "master-cache.json"
    static let schemaVersion = 1
    static let maxAge: TimeInterval = 24 * 3600

    struct File: Codable, Equatable {
        var schemaVersion: Int
        var savedAt: Date
        var master: String
        var addresses: [BrowserAddress]
    }

    let fileURL: URL

    /// The cached addresses of `master` when younger than 24 hours.
    func load(master: String, now: Date) -> (addresses: [BrowserAddress], savedAt: Date)? {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? Self.decoder.decode(File.self, from: data),
              file.schemaVersion == Self.schemaVersion, file.master == master, !file.addresses.isEmpty else { return nil }
        let age = now.timeIntervalSince(file.savedAt)
        guard age >= 0, age < Self.maxAge else { return nil }
        return (file.addresses, file.savedAt)
    }

    func save(_ addresses: [BrowserAddress], master: String, at date: Date) throws {
        let file = File(schemaVersion: Self.schemaVersion, savedAt: date, master: master, addresses: addresses)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One finished scan (master list + replies). Lives in memory for 5 minutes; never written.
struct BrowserScan: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case master
        /// The master failed; the addresses came from `master-cache.json` saved at this time.
        case diskCache(Date)
    }

    var addresses: [BrowserAddress]
    var servers: [BrowserServer]
    var source: Source
    var masterEnd: MasterQueryResult.End
    var timedOut: Bool
    var finishedAt: Date

    /// The master stopped early (limit / time) or not every address could be asked.
    var isPartial: Bool { masterEnd != .complete || timedOut }
}

/// The in-memory result cache (5 minutes).
struct BrowserMemoryCache: Sendable, Equatable {
    static let maxAge: TimeInterval = 5 * 60

    private(set) var scan: BrowserScan?

    mutating func store(_ scan: BrowserScan) { self.scan = scan }
    mutating func clear() { scan = nil }

    func fresh(now: Date) -> BrowserScan? {
        guard let scan else { return nil }
        let age = now.timeIntervalSince(scan.finishedAt)
        return age >= 0 && age < Self.maxAge ? scan : nil
    }

    /// Replaces one server's row (row refresh); `nil` removes it (it no longer answers).
    mutating func update(_ address: BrowserAddress, with server: BrowserServer?) {
        guard var current = scan else { return }
        current.servers.removeAll { $0.address == address }
        if let server { current.servers.append(server) }
        scan = current
    }
}

/// Master query (with the disk cache as fallback) followed by the A2S_INFO collection.
struct ServerBrowserScanner: Sendable {
    let master: MasterServerQuery
    let collector: BrowserInfoCollector
    let cache: MasterCacheStore
    let now: @Sendable () -> Date

    /// Throws `MasterQueryError` only when the master failed and there is no usable cache; `CancellationError` when
    /// cancelled.
    func scan(progress: @escaping @Sendable (BrowserProgress) async -> Void = { _ in }) async throws -> BrowserScan {
        let list: MasterQueryResult
        var source = BrowserScan.Source.master
        do {
            list = try await master.run { count in await progress(.master(addresses: count)) }
            if !list.addresses.isEmpty {
                try? cache.save(list.addresses, master: master.name, at: now())
            }
        } catch let error as MasterQueryError {
            guard let cached = cache.load(master: master.name, now: now()) else { throw error }
            list = MasterQueryResult(addresses: cached.addresses, end: .complete)
            source = .diskCache(cached.savedAt)
            await progress(.master(addresses: cached.addresses.count))
        }
        let collection = try await collector.collect(list.addresses, progress: progress)
        return BrowserScan(addresses: list.addresses, servers: collection.servers, source: source, masterEnd: list.end,
                           timedOut: collection.timedOut, finishedAt: now())
    }
}

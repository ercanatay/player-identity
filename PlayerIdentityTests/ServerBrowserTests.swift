import Foundation
import XCTest
@testable import PlayerIdentity

/// Fake GoldSrc master + game servers for §70 (no network: every packet goes to `FakeUDPTransport`).
enum MasterFixture {
    static let masterIP = "192.0.2.1"
    static let masterEndpointPort: UInt16 = 27010

    static func address(_ index: Int, port: UInt16 = 27015) -> BrowserAddress {
        BrowserAddress(ip: [UInt8](arrayLiteral: 10, UInt8((index >> 16) & 0xFF), UInt8((index >> 8) & 0xFF),
                                   UInt8(index & 0xFF)), port: port)
    }

    static func reply(_ addresses: [BrowserAddress]) -> [UInt8] {
        var bytes: [UInt8] = MasterPackets.replyHeader
        for address in addresses {
            bytes += address.ip
            bytes += [UInt8](arrayLiteral: UInt8(address.port >> 8), UInt8(address.port & 0xFF))
        }
        return bytes
    }

    static func isMasterRequest(_ packet: [UInt8]) -> Bool { packet.first == MasterPackets.requestType }

    /// The `ip:port` seed of a master request.
    static func seed(_ packet: [UInt8]) -> BrowserAddress? {
        guard isMasterRequest(packet), packet.count > 2, let end = packet[2...].firstIndex(of: 0) else { return nil }
        return BrowserAddress(text: String(decoding: packet[2..<end], as: UTF8.self))
    }

    /// GoldSrc A2S_INFO reply with an explicit visibility byte.
    static func info(name: String, map: String, players: UInt8, max: UInt8, visibility: UInt8 = 0) -> [UInt8] {
        A2SFixture.header + [UInt8](arrayLiteral: 0x6D) + A2SFixture.cString("10.0.0.1:27015") + A2SFixture.cString(name)
            + A2SFixture.cString(map) + A2SFixture.cString("valve") + A2SFixture.cString("Half-Life")
            + [UInt8](arrayLiteral: players, max, 47, 0x64, 0x6C, visibility, 0x00)
    }

    /// Master pages of `pageSize` from `addresses` (seeded by the last address), then the end marker.
    static func pagedMaster(_ addresses: [BrowserAddress], pageSize: Int,
                            delay: TimeInterval = 0) -> @Sendable (BrowserAddress) -> [FakeReply] {
        { seed in
            let start = seed.isZero ? 0 : (addresses.firstIndex(of: seed).map { $0 + 1 } ?? addresses.count)
            var page = Array(addresses[min(start, addresses.count)..<min(start + pageSize, addresses.count)])
            if start + pageSize >= addresses.count { page.append(.zero) }
            return [FakeReply(bytes: reply(page), delay: delay)]
        }
    }

    /// One transport for the master (`masterIP`) and the game servers (`info` per address; `nil` = silence).
    static func transport(clock: TestClock?, waitsOnSilence: Bool = false,
                          master: @escaping @Sendable (BrowserAddress) -> [FakeReply],
                          info: @escaping @Sendable (BrowserAddress) -> FakeReply? = { address in
                              FakeReply(bytes: MasterFixture.info(name: "Server \(address.ip[3])", map: "crossfire",
                                                                  players: 3, max: 16), delay: 0.04)
                          }) -> FakeUDPTransport {
        FakeUDPTransport(clock: clock, waitsOnSilence: waitsOnSilence) { endpoint, packet in
            if isMasterRequest(packet) {
                guard let seed = seed(packet) else { return [] }
                return master(seed)
            }
            guard FakeServer.isInfo(packet), case .ipv4(let ip) = endpoint.address else { return [] }
            return info(BrowserAddress(ip: ip, port: endpoint.port)).map { [$0] } ?? []
        }
    }

    static func query(_ transport: FakeUDPTransport, clock: TestClock,
                      resolver: FakeAddressResolver = FakeAddressResolver()) -> MasterServerQuery {
        var query = MasterServerQuery(transport: transport, resolver: resolver, now: { clock.now })
        query.host = masterIP
        return query
    }

    static func server(_ index: Int, name: String, map: String = "crossfire", players: Int = 0, max: Int = 16,
                       ping: Int = 50, passworded: Bool? = false) -> BrowserServer {
        BrowserServer(address: address(index), name: name, map: map, players: players, maxPlayers: max,
                      pingMillis: ping, passworded: passworded)
    }
}

/// §70.5 (a)–(g): master query, A2S_INFO collection, filter/sort, row actions, caches and keys. No network.
final class ServerBrowserTests: XCTestCase {
    override func tearDown() {
        L10n.setting = .system
        super.tearDown()
    }

    // MARK: (a) Master request / reply

    func testMasterRequestEncoding() {
        XCTAssertEqual(MasterPackets.request(),
                       [UInt8](arrayLiteral: 0x31, 0xFF) + Array("0.0.0.0:0".utf8) + [UInt8](arrayLiteral: 0x00, 0x00))
        let seed = BrowserAddress(ip: [UInt8](arrayLiteral: 203, 0, 113, 9), port: 27_016)
        XCTAssertEqual(MasterPackets.request(after: seed),
                       [UInt8](arrayLiteral: 0x31, 0xFF) + Array("203.0.113.9:27016".utf8) + [UInt8](arrayLiteral: 0x00, 0x00))
        XCTAssertEqual(MasterFixture.seed(MasterPackets.request(after: seed)), seed)
    }

    func testMasterReplyDecoding() throws {
        let bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x66, 0x0A,
                              192, 0, 2, 10, 0x69, 0x87,       // 192.0.2.10:27015
                              198, 51, 100, 7, 0x69, 0x88,     // 198.51.100.7:27016
                              0, 0, 0, 0, 0, 0,                // end marker
                              1, 2, 3]                         // partial record (ignored)
        let parsed = try XCTUnwrap(MasterPackets.parse(bytes))
        XCTAssertEqual(parsed.map(\.id), ["192.0.2.10:27015", "198.51.100.7:27016", "0.0.0.0:0"])
        XCTAssertTrue(parsed[2].isZero)
        XCTAssertNil(MasterPackets.parse([UInt8](arrayLiteral: 0xFF, 0xFF, 0xFF, 0xFF, 0x67, 0x0A, 1, 2, 3, 4, 5, 6)))
        XCTAssertEqual(MasterPackets.parse(MasterPackets.replyHeader), [])
        XCTAssertEqual(BrowserAddress(text: "10.0.0.1:27015")?.id, "10.0.0.1:27015")
        for bad in ["10.0.0.1", "10.0.0:1", "10.0.0.256:1", "10.0.0.1:99999", "a.b.c.d:1", "::1:27015"] {
            XCTAssertNil(BrowserAddress(text: bad), bad)
        }
    }

    func testMasterPagesWithTheLastAddressUntilTheEndMarker() async throws {
        let clock = TestClock()
        let all = (1...7).map { MasterFixture.address($0) }
        let transport = MasterFixture.transport(clock: clock, master: MasterFixture.pagedMaster(all, pageSize: 3))
        let progress = LockedValue<[Int]>([])
        let result = try await MasterFixture.query(transport, clock: clock).run { count in
            progress.value.append(count)
        }
        XCTAssertEqual(result.addresses, all)
        XCTAssertEqual(result.end, .complete)
        let seeds = transport.sentPackets.compactMap(MasterFixture.seed)
        XCTAssertEqual(seeds, [BrowserAddress.zero, all[2], all[5]])
        XCTAssertEqual(progress.value, [3, 6, 7])
    }

    func testEmptyMasterReplyStopsWithNoServers() async throws {
        let clock = TestClock()
        let transport = MasterFixture.transport(clock: clock) { _ in [FakeReply(bytes: MasterFixture.reply([]))] }
        let result = try await MasterFixture.query(transport, clock: clock).run()
        XCTAssertEqual(result.addresses, [])
        XCTAssertEqual(result.end, .complete)
        XCTAssertEqual(transport.sentCount, 1)
    }

    func testRepeatedPageStops() async throws {
        let clock = TestClock()
        let page = (1...4).map { MasterFixture.address($0) }
        // A broken master that always returns the same page (no end marker).
        let transport = MasterFixture.transport(clock: clock) { _ in [FakeReply(bytes: MasterFixture.reply(page))] }
        let result = try await MasterFixture.query(transport, clock: clock).run()
        XCTAssertEqual(result.addresses, page)
        XCTAssertEqual(result.end, .complete)
        XCTAssertEqual(transport.sentCount, 2)
    }

    func testRepeatedLastAddressStops() async throws {
        let clock = TestClock()
        let first = (1...3).map { MasterFixture.address($0) }
        // The second page has one new address but ends with the seed again.
        let transport = MasterFixture.transport(clock: clock) { seed in
            seed.isZero ? [FakeReply(bytes: MasterFixture.reply(first))]
                        : [FakeReply(bytes: MasterFixture.reply([MasterFixture.address(9), seed]))]
        }
        let result = try await MasterFixture.query(transport, clock: clock).run()
        XCTAssertEqual(result.addresses, first + [MasterFixture.address(9)])
        XCTAssertEqual(transport.sentCount, 2)
    }

    func testAddressLimitIs5000() async throws {
        let clock = TestClock()
        let all = (1...6000).map { MasterFixture.address($0) }
        let transport = MasterFixture.transport(clock: clock, master: MasterFixture.pagedMaster(all, pageSize: 231))
        let result = try await MasterFixture.query(transport, clock: clock).run()
        XCTAssertEqual(MasterServerQuery.maxAddresses, 5000)
        XCTAssertEqual(result.addresses.count, 5000)
        XCTAssertEqual(result.addresses, Array(all.prefix(5000)))
        XCTAssertEqual(result.end, .limit)
        XCTAssertEqual(Set(result.addresses).count, 5000)
    }

    func testNoReplyIsATimeoutAndALaterSilenceKeepsThePages() async throws {
        let clock = TestClock()
        let silent = MasterFixture.transport(clock: clock) { _ in [] }
        do {
            _ = try await MasterFixture.query(silent, clock: clock).run()
            XCTFail("expected a timeout")
        } catch let error as MasterQueryError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertEqual(MasterServerQuery.requestTimeout, 2)

        let first = (1...3).map { MasterFixture.address($0) }
        let partial = MasterFixture.transport(clock: clock) { seed in
            seed.isZero ? [FakeReply(bytes: MasterFixture.reply(first))] : []
        }
        let result = try await MasterFixture.query(partial, clock: clock).run()
        XCTAssertEqual(result.addresses, first)
        XCTAssertEqual(result.end, .timeout)
    }

    func testTotalTimeIs30Seconds() async throws {
        let clock = TestClock()
        let start = clock.now
        let all = (1...3000).map { MasterFixture.address($0) }
        // Each page takes 1.9 s (under the 2 s request limit): only the pages within 30 s are read.
        let transport = MasterFixture.transport(clock: clock, master: MasterFixture.pagedMaster(all, pageSize: 10, delay: 1.9))
        let result = try await MasterFixture.query(transport, clock: clock).run()
        XCTAssertEqual(result.end, .timeout)
        XCTAssertEqual(transport.sentCount, 16)                 // 15 × 1.9 s = 28.5 s; the 16th page arrives at 30.4 s
        XCTAssertEqual(result.addresses.count, 150)
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(start), MasterServerQuery.totalTimeout + 2)
    }

    func testMasterNameResolutionFailureIsDNS() async throws {
        let clock = TestClock()
        let resolver = FakeAddressResolver(["master.example.com": .failure(.notFound)])
        let transport = MasterFixture.transport(clock: clock) { _ in [] }
        var query = MasterServerQuery(transport: transport, resolver: resolver, now: { clock.now })
        query.host = "master.example.com"
        do {
            _ = try await query.run()
            XCTFail("expected a DNS error")
        } catch let error as MasterQueryError {
            XCTAssertEqual(error, .dns)
        }
        XCTAssertEqual(transport.sentCount, 0)
        XCTAssertEqual(resolver.requestedNames, ["master.example.com"])
        XCTAssertEqual(MasterServerQuery.defaultHost, "hl1master.steampowered.com")
        XCTAssertEqual(MasterServerQuery.defaultPort, 27010)
    }

    func testMasterQueryIsCancellable() async throws {
        let transport = MasterFixture.transport(clock: nil, waitsOnSilence: true) { _ in [] }
        var query = MasterServerQuery(transport: transport, resolver: FakeAddressResolver(), now: { Date() })
        query.host = MasterFixture.masterIP
        let task = Task { try await query.run() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: (b) A2S_INFO collection

    func testCollectorKeepsAtMost20QueriesInFlight() async throws {
        let probe = ConcurrencyProbeTransport()
        let collector = BrowserInfoCollector(transport: probe, now: { Date() })
        let addresses = (1...65).map { MasterFixture.address($0) }
        let result = try await collector.collect(addresses)
        XCTAssertEqual(BrowserInfoCollector.concurrency, 20)
        XCTAssertEqual(result.servers.count, 65)
        XCTAssertEqual(result.asked, 65)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThanOrEqual(probe.maxActive, 20)
        XCTAssertGreaterThan(probe.maxActive, 1)
    }

    func testCollectorDropsSilentSlowAndMalformedServers() async throws {
        let clock = TestClock()
        let transport = MasterFixture.transport(clock: clock, master: { _ in [] }) { address in
            switch address.ip[3] {
            case 1: return FakeReply(bytes: MasterFixture.info(name: "Alpha", map: "de_dust2", players: 5, max: 20,
                                                               visibility: 1), delay: 0.05)
            case 2: return FakeReply(bytes: MasterFixture.info(name: "Slow", map: "x", players: 1, max: 2), delay: 2.5)
            case 3: return FakeReply(bytes: [UInt8](arrayLiteral: 0xFF, 0xFF, 0xFF, 0xFF, 0x70, 0x01))
            default: return nil
            }
        }
        // One at a time: the shared fake clock then measures each ping on its own.
        var collector = BrowserInfoCollector(transport: transport, now: { clock.now })
        collector.concurrency = 1
        let result = try await collector.collect((1...4).map { MasterFixture.address($0) })
        XCTAssertEqual(result.servers.count, 1)
        let server = try XCTUnwrap(result.servers.first)
        XCTAssertEqual(server.name, "Alpha")
        XCTAssertEqual(server.map, "de_dust2")
        XCTAssertEqual(server.players, 5)
        XCTAssertEqual(server.maxPlayers, 20)
        XCTAssertEqual(server.pingMillis, 50)
        XCTAssertEqual(server.passworded, true)
        XCTAssertEqual(BrowserInfoCollector.perServer, 2)
    }

    func testCollectorAnswersTheChallengeOnce() async throws {
        let clock = TestClock()
        let challenge: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        let transport = FakeUDPTransport(clock: clock) { _, packet in
            if packet == BanPackets.info() { return [FakeReply(bytes: FakeServer.oob(0x41, challenge))] }
            if packet == BanPackets.info(challenge: challenge) {
                return [FakeReply(bytes: MasterFixture.info(name: "Challenged", map: "c1a0", players: 2, max: 8))]
            }
            return []
        }
        let collector = BrowserInfoCollector(transport: transport, now: { clock.now })
        let server = try await collector.query(MasterFixture.address(1), until: clock.now.addingTimeInterval(20))
        XCTAssertEqual(server?.name, "Challenged")
        XCTAssertEqual(server?.passworded, false)
        XCTAssertEqual(transport.sentCount, 2)
    }

    func testCollectorStopsStartingQueriesAfter20Seconds() async throws {
        let clock = TestClock()
        let transport = MasterFixture.transport(clock: clock, master: { _ in [] }) { _ in nil }
        let collector = BrowserInfoCollector(transport: transport, now: { clock.now })
        let result = try await collector.collect((1...80).map { MasterFixture.address($0) })
        XCTAssertEqual(BrowserInfoCollector.total, 20)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(result.asked, 80)
        XCTAssertEqual(result.servers, [])
    }

    func testVisibilityOfGoldSrcAndSourceReplies() {
        XCTAssertEqual(BrowserInfoParser.visibility(MasterFixture.info(name: "A", map: "m", players: 1, max: 2, visibility: 1)), true)
        XCTAssertEqual(BrowserInfoParser.visibility(A2SFixture.goldSrc()), false)
        let source = A2SFixture.header + [UInt8](arrayLiteral: 0x49, 0x30) + A2SFixture.cString("S") + A2SFixture.cString("m")
            + A2SFixture.cString("cstrike") + A2SFixture.cString("CS") + [UInt8](arrayLiteral: 0x0A, 0x00, 4, 32, 0, 0x64, 0x6C, 1)
        XCTAssertEqual(BrowserInfoParser.visibility(source), true)
        // Ends before the visibility byte: unknown.
        let short = A2SFixture.header + [UInt8](arrayLiteral: 0x6D) + A2SFixture.cString("a") + A2SFixture.cString("n")
            + A2SFixture.cString("m") + A2SFixture.cString("f") + A2SFixture.cString("g") + [UInt8](arrayLiteral: 1, 2)
        XCTAssertNil(BrowserInfoParser.visibility(short))
        XCTAssertNil(BrowserInfoParser.parse(short, address: MasterFixture.address(1), pingMillis: 3)?.passworded)
    }

    // MARK: (c) Filter / sort

    private let sample: [BrowserServer] = [
        MasterFixture.server(1, name: "Zombie TR", map: "zm_dust", players: 12, ping: 80, passworded: false),
        MasterFixture.server(2, name: "Alpha DM", map: "crossfire", players: 0, ping: 20, passworded: false),
        MasterFixture.server(3, name: "Bravo Clan", map: "de_dust2", players: 5, ping: 140, passworded: true),
        MasterFixture.server(4, name: "", map: "stalkyard", players: 5, ping: 35, passworded: nil),
    ]

    func testFilterMatrix() {
        func ids(_ filter: BrowserFilter) -> [Int] { filter.apply(sample).rows.map { Int($0.address.ip[3]) } }
        XCTAssertEqual(ids(BrowserFilter()), [1, 4, 3, 2])
        XCTAssertEqual(ids(BrowserFilter(map: "DUST")), [1, 3])
        XCTAssertEqual(ids(BrowserFilter(name: "clan")), [3])
        XCTAssertEqual(ids(BrowserFilter(minPlayers: 6)), [1])
        XCTAssertEqual(ids(BrowserFilter(notEmpty: true)), [1, 4, 3])
        XCTAssertEqual(ids(BrowserFilter(noPassword: true)), [1, 4, 2])          // unknown stays
        XCTAssertEqual(ids(BrowserFilter(maxPing: 80)), [1, 4, 2])
        XCTAssertEqual(ids(BrowserFilter(map: "dust", notEmpty: true, noPassword: true, maxPing: 100)), [1])
        XCTAssertEqual(ids(BrowserFilter(map: "  ")), [1, 4, 3, 2])
        XCTAssertEqual(ids(BrowserFilter(name: "nothing")), [])
        XCTAssertFalse(BrowserFilter().isActive)
        XCTAssertTrue(BrowserFilter(maxPing: 50).isActive)
        XCTAssertFalse(BrowserFilter(sort: .name).isActive)
    }

    func testSortMatrix() {
        func ids(_ sort: BrowserSort) -> [Int] { BrowserFilter(sort: sort).apply(sample).rows.map { Int($0.address.ip[3]) } }
        XCTAssertEqual(ids(.players), [1, 4, 3, 2])     // 12, 5 (35 ms), 5 (140 ms), 0
        XCTAssertEqual(ids(.ping), [2, 4, 1, 3])
        XCTAssertEqual(ids(.name), [4, 2, 3, 1])        // no name → the address "10.0.0.4:27015" sorts first
    }

    func testListingShowsAtMost300Rows() {
        let many = (1...420).map { MasterFixture.server($0, name: "S\($0)", players: $0 % 7) }
        let listing = BrowserFilter().apply(many)
        XCTAssertEqual(BrowserFilter.displayLimit, 300)
        XCTAssertEqual(listing.rows.count, 300)
        XCTAssertEqual(listing.matched, 420)
        XCTAssertEqual(listing.total, 420)
        XCTAssertTrue(listing.isCut)
        let narrow = BrowserFilter(minPlayers: 6).apply(many)
        XCTAssertEqual(narrow.rows.count, 60)
        XCTAssertFalse(narrow.isCut)
    }

    // MARK: (d) Row actions

    @MainActor
    func testAddMarksAddedAndNeverDuplicates() throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "Saved", host: "10.0.0.2"))
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        let saved = MasterFixture.server(2, name: "Alpha DM")
        let fresh = MasterFixture.server(7, name: "  Fresh Server ")
        XCTAssertNotNil(model.savedServerID(for: saved.address))
        XCTAssertNil(model.savedServerID(for: fresh.address))

        XCTAssertEqual(model.addBrowserServer(saved), model.savedServerID(for: saved.address))
        XCTAssertEqual(model.servers.count, 1)
        XCTAssertFalse(model.hasUnsavedChanges)

        let id = try XCTUnwrap(model.addBrowserServer(fresh))
        XCTAssertEqual(model.servers.count, 2)
        let entry = try XCTUnwrap(model.servers.first { $0.id == id })
        XCTAssertEqual(entry.label, "Fresh Server")
        XCTAssertEqual(entry.host, "10.0.0.7")
        XCTAssertEqual(entry.port, 27015)
        XCTAssertTrue(model.hasUnsavedChanges)                     // "Unsaved"
        XCTAssertEqual(model.addBrowserServer(fresh), id)
        XCTAssertEqual(model.servers.count, 2)
        // Another port of the same host is another server.
        XCTAssertNil(model.savedServerID(for: MasterFixture.address(7, port: 27016)))
    }

    @MainActor
    func testSavedHostnameMatchesItsResolvedAddress() async throws {
        let env = try TestAppEnvironment()
        let resolver = FakeAddressResolver(["play.example.com": .success([TestAddresses.v4("10.0.0.9")])])
        let model = env.makeModel(resolver: resolver)
        model.addServer(ServerDraft(label: "Named", host: "play.example.com"))
        await model.waitForResolutions()
        XCTAssertNotNil(model.savedServerID(for: MasterFixture.address(9)))
        XCTAssertEqual(model.addBrowserServer(MasterFixture.server(9, name: "Named")), model.servers.first?.id)
        XCTAssertEqual(model.servers.count, 1)
    }

    @MainActor
    func testDiagnoseUsesTheExistingDiagnosisAndOpensTheDetails() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        let server = MasterFixture.server(5, name: "Diag")
        let task = try XCTUnwrap(model.diagnoseBrowserServer(server))
        let id = try XCTUnwrap(model.savedServerID(for: server.address))
        XCTAssertEqual(model.requestedServerDetail, id)
        XCTAssertEqual(model.diagnosis(for: id)?.serverID, id)
        await task.value
        XCTAssertNotNil(model.diagnosis(for: id)?.result)
        // Diagnosing again does not add another row.
        await model.diagnoseBrowserServer(server)?.value
        XCTAssertEqual(model.servers.count, 1)
    }

    @MainActor
    func testRowRefreshReplacesOrRemovesTheRow() async throws {
        let clock = TestClock()
        let players = LockedValue<UInt8?>(4)
        let transport = MasterFixture.transport(clock: clock, master: { _ in [] }) { _ in
            players.value.map { FakeReply(bytes: MasterFixture.info(name: "Row", map: "bounce", players: $0, max: 10)) }
        }
        let controller = Self.controller(transport: transport, clock: clock, cacheURL: try Self.tempFile())
        let address = MasterFixture.address(3)
        controller.show(BrowserScan(addresses: [address], servers: [MasterFixture.server(3, name: "Row", players: 1)],
                                    source: .master, masterEnd: .complete, timedOut: false, finishedAt: clock.now))
        await controller.refreshRow(address)?.value
        XCTAssertEqual(controller.servers.first?.players, 4)
        XCTAssertNil(controller.rowMessage)
        players.value = nil
        await controller.refreshRow(address)?.value
        XCTAssertEqual(controller.servers, [])
        XCTAssertNotNil(controller.rowMessage)
    }

    // MARK: (e) Caches

    @MainActor
    func testMemoryCacheIsReusedForFiveMinutes() async throws {
        let clock = TestClock()
        let all = (1...3).map { MasterFixture.address($0) }
        let transport = MasterFixture.transport(clock: clock, master: MasterFixture.pagedMaster(all, pageSize: 10))
        let controller = Self.controller(transport: transport, clock: clock, cacheURL: try Self.tempFile())
        await controller.start()?.value
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(controller.servers.count, 3)
        let masterRequests = { transport.sentPackets.filter(MasterFixture.isMasterRequest).count }
        XCTAssertEqual(masterRequests(), 1)

        clock.advance(4 * 60)
        XCTAssertNil(controller.start())                              // shown from memory, no network
        XCTAssertEqual(controller.servers.count, 3)
        XCTAssertEqual(masterRequests(), 1)

        await controller.start(force: true)?.value                    // "Reload List" always asks
        XCTAssertEqual(masterRequests(), 2)

        clock.advance(BrowserMemoryCache.maxAge + 1)
        await controller.start()?.value
        XCTAssertEqual(masterRequests(), 3)
    }

    func testDiskCacheHoldsOnlyAddressesFor24Hours() async throws {
        let clock = TestClock()
        let url = try Self.tempFile()
        let all = (1...4).map { MasterFixture.address($0) }
        let good = MasterFixture.transport(clock: clock, master: MasterFixture.pagedMaster(all, pageSize: 10))
        let scan = try await Self.scanner(transport: good, clock: clock, cacheURL: url).scan()
        XCTAssertEqual(scan.source, .master)
        XCTAssertEqual(scan.servers.count, 4)

        // Only the master and the addresses are written (no names, maps or pings).
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "savedAt", "master", "addresses"])
        XCTAssertEqual(json["addresses"] as? [String], all.map(\.id))
        XCTAssertEqual(MasterCacheStore.fileName, "master-cache.json")

        // The master is silent 23 h later: the cached addresses are used.
        clock.advance(23 * 3600)
        let silent = MasterFixture.transport(clock: clock, master: { _ in [] })
        let cached = try await Self.scanner(transport: silent, clock: clock, cacheURL: url).scan()
        guard case .diskCache = cached.source else { return XCTFail("expected the disk cache") }
        XCTAssertEqual(cached.addresses, all)
        XCTAssertEqual(cached.servers.count, 4)

        // 25 h: too old, the master's error is shown.
        clock.advance(2 * 3600)
        do {
            _ = try await Self.scanner(transport: silent, clock: clock, cacheURL: url).scan()
            XCTFail("expected a timeout")
        } catch let error as MasterQueryError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testDamagedOrForeignCacheIsIgnoredAndReplaced() async throws {
        let clock = TestClock()
        let url = try Self.tempFile()
        let store = MasterCacheStore(fileURL: url)
        for damaged in ["", "{", "[]", #"{"schemaVersion":1,"savedAt":"x","master":"m","addresses":[]}"#,
                        #"{"schemaVersion":1,"savedAt":"2026-11-18T10:00:00Z","master":"192.0.2.1:27010","addresses":["nope"]}"#] {
            try Data(damaged.utf8).write(to: url)
            XCTAssertNil(store.load(master: "192.0.2.1:27010", now: clock.now), damaged)
        }
        try store.save([MasterFixture.address(1)], master: "other:27010", at: clock.now)
        XCTAssertNil(store.load(master: "192.0.2.1:27010", now: clock.now))
        try store.save([MasterFixture.address(1)], master: "192.0.2.1:27010", at: clock.now.addingTimeInterval(60))
        XCTAssertNil(store.load(master: "192.0.2.1:27010", now: clock.now))      // from the future

        try Data("garbage".utf8).write(to: url)
        let silent = MasterFixture.transport(clock: clock, master: { _ in [] })
        do {
            _ = try await Self.scanner(transport: silent, clock: clock, cacheURL: url).scan()
            XCTFail("expected a timeout")
        } catch let error as MasterQueryError {
            XCTAssertEqual(error, .timeout)
        }
        let all = (1...2).map { MasterFixture.address($0) }
        let good = MasterFixture.transport(clock: clock, master: MasterFixture.pagedMaster(all, pageSize: 10))
        _ = try await Self.scanner(transport: good, clock: clock, cacheURL: url).scan()
        XCTAssertEqual(store.load(master: "192.0.2.1:27010", now: clock.now)?.addresses, all)
    }

    @MainActor
    func testErrorEmptyAndCancelStates() async throws {
        let clock = TestClock()
        let silent = MasterFixture.transport(clock: clock, master: { _ in [] })
        let failing = Self.controller(transport: silent, clock: clock, cacheURL: try Self.tempFile())
        await failing.start()?.value
        XCTAssertEqual(failing.phase, .failed(.timeout))
        XCTAssertEqual(BrowserText.error(.timeout), L10n.text(.serverBrowserErrorTimeout))

        let empty = MasterFixture.transport(clock: clock) { _ in [FakeReply(bytes: MasterFixture.reply([]))] }
        let emptyController = Self.controller(transport: empty, clock: clock, cacheURL: try Self.tempFile())
        await emptyController.start()?.value
        XCTAssertEqual(emptyController.phase, .finished)
        XCTAssertEqual(emptyController.servers, [])

        let hanging = MasterFixture.transport(clock: nil, waitsOnSilence: true, master: { _ in [] })
        var query = MasterServerQuery(transport: hanging, resolver: FakeAddressResolver(), now: { Date() })
        query.host = MasterFixture.masterIP
        let cancelled = ServerBrowserController(scanner: ServerBrowserScanner(
            master: query, collector: BrowserInfoCollector(transport: hanging, now: { Date() }),
            cache: MasterCacheStore(fileURL: try Self.tempFile()), now: { Date() }))
        let task = cancelled.start()
        XCTAssertTrue(cancelled.isRunning)
        cancelled.cancel()
        XCTAssertEqual(cancelled.phase, .cancelled)
        await task?.value
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.scan)
    }

    // MARK: (f) Keys in 26 languages

    func testServerBrowserKeysExistInEveryLanguage() throws {
        let keys = L10nKey.allCases.filter { $0.rawValue.hasPrefix("serverBrowser.") }
        XCTAssertEqual(keys.count, 38)
        let specifiers = { (text: String) in text.components(separatedBy: "%@").count }
        XCTAssertEqual(AppLanguage.allCases.count, 26)
        for language in AppLanguage.allCases {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                                                    localization: language.rawValue), language.rawValue)
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language.rawValue)
            let english = try XCTUnwrap(NSDictionary(contentsOf: try XCTUnwrap(Bundle.main.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(table[key.rawValue], "\(language.rawValue) \(key.rawValue)")
                XCTAssertFalse(value.isEmpty, "\(language.rawValue) \(key.rawValue)")
                XCTAssertEqual(specifiers(value), specifiers(english[key.rawValue] ?? ""), "\(language.rawValue) \(key.rawValue)")
            }
        }
    }

    // MARK: (g) No network: the app's browser runs on the injected fake transport

    @MainActor
    func testAppModelBrowserUsesOnlyTheInjectedTransport() async throws {
        let env = try TestAppEnvironment()
        let clock = env.clock
        let all = (1...5).map { MasterFixture.address($0) }
        let transport = MasterFixture.transport(clock: clock, master: MasterFixture.pagedMaster(all, pageSize: 2))
        let resolver = FakeAddressResolver(["hl1master.example.test": .success([TestAddresses.v4(MasterFixture.masterIP)])])
        let model = env.makeModel(udp: transport, resolver: resolver) { deps in
            deps.masterServerHost = "hl1master.example.test"
        }
        await model.serverBrowser.start()?.value
        XCTAssertEqual(model.serverBrowser.phase, .finished)
        XCTAssertEqual(model.serverBrowser.servers.count, 5)
        XCTAssertEqual(resolver.requestedNames, ["hl1master.example.test"])
        XCTAssertEqual(transport.sentPackets.filter(MasterFixture.isMasterRequest).count, 3)
        XCTAssertEqual(transport.sentPackets.filter(FakeServer.isInfo).count, 5)
        let cacheFile = AppPaths(home: env.home).masterCacheFile
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertEqual(cacheFile.deletingLastPathComponent(), AppPaths(home: env.home).snapshotFile.deletingLastPathComponent())
    }

    // MARK: Helpers

    static func tempFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ServerBrowserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(MasterCacheStore.fileName)
    }

    static func scanner(transport: FakeUDPTransport, clock: TestClock, cacheURL: URL) -> ServerBrowserScanner {
        ServerBrowserScanner(master: MasterFixture.query(transport, clock: clock),
                             collector: BrowserInfoCollector(transport: transport, now: { clock.now }),
                             cache: MasterCacheStore(fileURL: cacheURL), now: { clock.now })
    }

    @MainActor
    static func controller(transport: FakeUDPTransport, clock: TestClock, cacheURL: URL) -> ServerBrowserController {
        ServerBrowserController(scanner: scanner(transport: transport, clock: clock, cacheURL: cacheURL))
    }
}

/// Thread-safe box for fake responders.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Counts sessions open at the same time; each A2S_INFO is answered after a short real wait.
final class ConcurrencyProbeTransport: UDPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    var maxActive: Int { lock.withLock { peak } }

    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession {
        lock.withLock {
            active += 1
            peak = max(peak, active)
        }
        return Session(owner: self)
    }

    fileprivate func closed() { lock.withLock { active -= 1 } }

    private final class Session: UDPSession, @unchecked Sendable {
        let owner: ConcurrencyProbeTransport
        private let lock = NSLock()
        private var pending = false
        private var isClosed = false

        init(owner: ConcurrencyProbeTransport) { self.owner = owner }

        func send(_ packet: [UInt8]) throws { lock.withLock { pending = true } }

        func receive(timeout: TimeInterval) async throws -> [UInt8]? {
            try await Task.sleep(for: .milliseconds(15))
            let ready = lock.withLock { () -> Bool in
                defer { pending = false }
                return pending
            }
            return ready ? MasterFixture.info(name: "Probe", map: "datacore", players: 1, max: 8) : nil
        }

        func close() {
            let first = lock.withLock { () -> Bool in
                defer { isClosed = true }
                return !isClosed
            }
            if first { owner.closed() }
        }
    }
}

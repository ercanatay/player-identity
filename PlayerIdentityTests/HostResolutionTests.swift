import Darwin
import XCTest
@testable import PlayerIdentity

/// §20: hostname validation, resolution order, 5-minute cache, error kinds and use of the resolved address.
final class HostValidatorTests: XCTestCase {
    func testHostnameRules() {
        XCTAssertTrue(HostValidator.isValidHostname("example.com"))
        XCTAssertTrue(HostValidator.isValidHostname("Game-Server.Example.COM."))     // case, trailing root dot
        XCTAssertTrue(HostValidator.isValidHostname("localhost"))                    // single label
        XCTAssertTrue(HostValidator.isValidHostname("3com.net"))                     // label may start with a digit
        XCTAssertFalse(HostValidator.isValidHostname(""))
        XCTAssertFalse(HostValidator.isValidHostname("-bad.com"))
        XCTAssertFalse(HostValidator.isValidHostname("bad-.com"))
        XCTAssertFalse(HostValidator.isValidHostname("under_score.com"))
        XCTAssertFalse(HostValidator.isValidHostname("a..b"))
        XCTAssertFalse(HostValidator.isValidHostname("space here.com"))
        XCTAssertFalse(HostValidator.isValidHostname("evil.com/x"))
        XCTAssertFalse(HostValidator.isValidHostname("alan.adı"))                   // non-ASCII
        XCTAssertFalse(HostValidator.isValidHostname("999.1.1.1"))                   // dotted-decimal lookalike
    }

    func testLengthLimits() {
        let label63 = String(repeating: "a", count: 63)
        XCTAssertTrue(HostValidator.isValidHostname(label63 + ".com"))
        XCTAssertFalse(HostValidator.isValidHostname(label63 + "a.com"))
        // 4 × 63 + 3 dots = 255 > 253; 253 exactly is valid.
        let name253 = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                       String(repeating: "c", count: 63), String(repeating: "d", count: 61)].joined(separator: ".")
        XCTAssertEqual(name253.count, 253)
        XCTAssertTrue(HostValidator.isValidHostname(name253))
        XCTAssertFalse(HostValidator.isValidHostname(name253 + "d"))
    }

    func testClassify() {
        XCTAssertEqual(HostValidator.classify(" 51.68.190.91 "), .address(TestAddresses.v4("51.68.190.91")))
        XCTAssertEqual(HostValidator.classify("2001:db8::1"), .address(TestAddresses.v6("2001:db8::1")))
        XCTAssertEqual(HostValidator.classify(" Play.Example.com. "), .hostname("play.example.com"))
        XCTAssertNil(HostValidator.classify("not a host"))
    }

    func testPortValidation() {
        XCTAssertFalse(HostValidator.isValidPort(0))
        XCTAssertTrue(HostValidator.isValidPort(1))
        XCTAssertTrue(HostValidator.isValidPort(65_535))
        XCTAssertFalse(HostValidator.isValidPort(65_536))
        XCTAssertFalse(HostValidator.isValidPort(-1))
    }

    func testServerDraftRejectsInvalidHostWithExistingMessage() {
        XCTAssertTrue(ServerDraft(label: "a", host: "play.example.com").isValid)
        XCTAssertEqual(ServerDraft(label: "a", host: "bad host").problems, [.hostInvalid])
        XCTAssertEqual(ServerDraft(label: "a", host: "999.1.1.1", portText: "0").problems, [.hostInvalid, .portInvalid])
        XCTAssertEqual(ServerDraft.Problem.hostInvalid.text, MessageCode.invalidHost.text)
    }
}

final class HostResolutionCacheTests: XCTestCase {
    private let v4 = TestAddresses.v4("51.68.190.91")
    private let v4b = TestAddresses.v4("5.161.189.195")
    private let v6 = TestAddresses.v6("2001:db8::1")

    func testPreferenceFirstIPv4ElseFirstIPv6() {
        XCTAssertEqual(AddressPreference.pick([v6, v4, v4b]), v4)
        XCTAssertEqual(AddressPreference.pick([v6, TestAddresses.v6("2001:db8::2")]), v6)
        XCTAssertNil(AddressPreference.pick([]))
    }

    func testAAndAAAAPicksIPv4() async {
        let resolver = FakeAddressResolver(["dual.example": .success([v6, v4])])
        let cache = HostResolutionCache(resolver: resolver, now: { Date() })
        let resolution = await cache.resolve("Dual.Example")
        XCTAssertEqual(resolution, .resolved(v4))
        XCTAssertEqual(resolver.requestedNames, ["dual.example"])   // normalized
    }

    func testOnlyAAAAPicksIPv6() async {
        let cache = HostResolutionCache(resolver: FakeAddressResolver(["v6.example": .success([v6])]), now: { Date() })
        let resolution = await cache.resolve("v6.example")
        XCTAssertEqual(resolution, .resolved(v6))
    }

    func testEmptyAnswerAndNXDOMAINAreNotFound() async {
        let resolver = FakeAddressResolver(["empty.example": .success([]), "nx.example": .failure(.notFound)])
        let cache = HostResolutionCache(resolver: resolver, now: { Date() })
        let empty = await cache.resolve("empty.example")
        let nx = await cache.resolve("nx.example")
        XCTAssertEqual(empty, .failed(.notFound))
        XCTAssertEqual(nx, .failed(.notFound))
    }

    func testNetworkErrorIsDistinctAndNotCached() async {
        let resolver = FakeAddressResolver(["down.example": .failure(.network)])
        let cache = HostResolutionCache(resolver: resolver, now: { Date() })
        let first = await cache.resolve("down.example")
        XCTAssertEqual(first, .failed(.network))
        resolver.set("down.example", .success([v4]))
        let second = await cache.resolve("down.example")
        XCTAssertEqual(second, .resolved(v4))
        XCTAssertEqual(resolver.callCount, 2)
    }

    func testCacheTTLIsFiveMinutes() async {
        let clock = TestClock()
        let resolver = FakeAddressResolver(["ttl.example": .success([v4])])
        let cache = HostResolutionCache(resolver: resolver, now: { clock.now })
        _ = await cache.resolve("ttl.example")
        resolver.set("ttl.example", .success([v4b]))
        clock.advance(299)
        let cached = await cache.resolve("ttl.example")
        XCTAssertEqual(cached, .resolved(v4))
        XCTAssertEqual(resolver.callCount, 1)
        clock.advance(2)
        let fresh = await cache.resolve("ttl.example")
        XCTAssertEqual(fresh, .resolved(v4b))
        XCTAssertEqual(resolver.callCount, 2)
        XCTAssertEqual(HostResolutionCache.ttl, 300)
    }

    func testNotFoundIsCachedToo() async {
        let clock = TestClock()
        let resolver = FakeAddressResolver()
        let cache = HostResolutionCache(resolver: resolver, now: { clock.now })
        _ = await cache.resolve("missing.example")
        _ = await cache.resolve("missing.example")
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testLiteralsAndInvalidNamesNeverReachTheResolver() async {
        let resolver = FakeAddressResolver()
        let cache = HostResolutionCache(resolver: resolver, now: { Date() })
        let literal = await cache.resolve("51.68.190.91")
        let invalid = await cache.resolve("bad host")
        let all = await cache.resolveAll(["51.68.190.91", "bad host", "a.example", "A.example."])
        XCTAssertEqual(literal, .resolved(v4))
        XCTAssertEqual(invalid, .failed(.invalidHostname))
        XCTAssertEqual(Array(all.keys), ["a.example"])
        XCTAssertEqual(resolver.requestedNames, ["a.example"])
    }

    func testGetaddrinfoErrorKinds() {
        XCTAssertEqual(SystemAddressResolver.errorKind(EAI_NONAME), .notFound)
        XCTAssertEqual(SystemAddressResolver.errorKind(EAI_NODATA), .notFound)
        XCTAssertEqual(SystemAddressResolver.errorKind(EAI_AGAIN), .network)
        XCTAssertEqual(SystemAddressResolver.errorKind(EAI_FAIL), .network)
    }

    func testSystemResolverHandlesLiteralWithoutNetwork() {
        // getaddrinfo with a numeric host does not query DNS.
        XCTAssertEqual(try SystemAddressResolver.lookup("127.0.0.1").get(), [TestAddresses.v4("127.0.0.1")])
    }
}

/// §20: CID, row status, ban requests and snapshot use the resolved address.
final class HostAddressingTests: XCTestCase {
    private let resolved: [String: HostResolution] = [
        "game.example": .resolved(TestAddresses.v4("51.68.190.91")),
        "nx.example": .failed(.notFound),
        "down.example": .failed(.network),
    ]

    func testRowUsesResolvedAddressForCID() {
        let entry = ServerEntry(label: "G", host: "Game.Example", cid: "d9de0eb4419608a8423241430581e91c")
        let row = StatusEvaluator.serverRow(entry, rawID: 0, saved: nil, resolutions: resolved)
        XCTAssertEqual(row.currentCID, "d9de0eb4419608a8423241430581e91c")
        XCTAssertEqual(row.resolvedIP, "51.68.190.91")
        XCTAssertNil(row.resolutionFailure)
        XCTAssertNil(StatusEvaluator.serverRow(ServerEntry(label: "IP", host: "51.68.190.91"), rawID: 0, saved: nil).resolvedIP)
    }

    func testUnresolvableHostIsInvalidHostAndKeepsOverallStatus() {
        for (host, failure) in [("nx.example", HostResolutionFailure.notFound), ("down.example", .network),
                                ("pending.example", .pending), ("bad host", .invalid)] {
            let row = StatusEvaluator.serverRow(ServerEntry(label: "x", host: host), rawID: 0, saved: nil, resolutions: resolved)
            XCTAssertEqual(row.level, .red, host)
            XCTAssertEqual(row.message, .invalidHost, host)
            XCTAssertEqual(row.resolutionFailure, failure, host)
            XCTAssertNil(row.currentCID, host)
        }
        let identity = Identity(source: IdentitySource(location: .homeConfig, url: URL(fileURLWithPath: "/x")),
                                fileValue: 0x10331C2DCE4C91DB, rawID: 0)
        let current = CurrentState(identity: .success(identity), displayName: "n", model: "m", lanIPs: ["en0 · 192.0.2.10"],
                                   publicIP: "203.0.113.7", servers: [ServerEntry(label: "x", host: "nx.example")],
                                   resolutions: resolved)
        let report = StatusEvaluator.evaluate(current: current, snapshot: .missing)
        XCTAssertFalse(report.reasons.contains { $0.code == .invalidHost })
        XCTAssertEqual(report.overall, .orange)   // snapshot missing + raw ID 0 only
    }

    func testBanRequestsUseResolvedEndpointAndSkipFailures() {
        let servers = [ServerEntry(label: "g", host: "game.example", port: 27016),
                       ServerEntry(label: "nx", host: "nx.example"),
                       ServerEntry(label: "pending", host: "pending.example"),
                       ServerEntry(label: "port", host: "game.example", port: 70_000)]
        let requests = BanCheckRunner.requests(servers: servers, rawID: 0, name: "N", resolutions: resolved)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.host, "game.example")
        XCTAssertEqual(requests.first?.endpoint, UDPEndpoint(address: TestAddresses.v4("51.68.190.91"), port: 27016))
        XCTAssertEqual(requests.first?.cid, "d9de0eb4419608a8423241430581e91c")
    }

    func testSnapshotStoresCIDOfResolvedAddress() {
        let identity = Identity(source: IdentitySource(location: .homeConfig, url: URL(fileURLWithPath: "/x")),
                                fileValue: 0x10331C2DCE4C91DB, rawID: 0)
        let snapshot = SnapshotBuilder.make(savedAt: Date(), dataRoot: URL(fileURLWithPath: "/r"), gamedir: "valve",
                                            config: PlayerConfig(), identity: .success(identity), publicIP: nil,
                                            lanIPs: [], checkedAt: Date(),
                                            servers: [ServerEntry(label: "g", host: "game.example", lastCheckedAt: Date()),
                                                      ServerEntry(label: "nx", host: "nx.example", lastCheckedAt: Date())],
                                            resolutions: resolved)
        XCTAssertEqual(snapshot.servers.map(\.cid), ["d9de0eb4419608a8423241430581e91c", ""])
        XCTAssertEqual(snapshot.servers.first?.host, "game.example")   // the host text is kept, not the IP
    }
}

/// §20 in the refresh flow (fake resolver and UDP; no network).
@MainActor
final class AppModelHostnameTests: XCTestCase {
    private var temp: TempDirectory!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        temp = try TempDirectory()
        suiteName = "PlayerIdentityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        try temp.write("home/Library/Application Support/Xash3D FWGS/valve/config.cfg", "name \"N\"\nmodel \"gordon\"\n")
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        temp = nil
    }

    private func makeModel(resolver: FakeAddressResolver, udp: FakeUDPTransport, clock: TestClock) -> AppModel {
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        return AppModel(dependencies: AppDependencies(
            paths: AppPaths(home: home),
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: [LocalAddress(interface: "en0", family: .ipv4, address: "192.0.2.10")]),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: #"{"ip":"203.0.113.7"}"#))),
            snapshotStore: SnapshotStore(fileURL: AppPaths(home: home).snapshotFile),
            defaults: defaults,
            now: { clock.now },
            udpTransport: udp,
            gameProcessDetector: FakeGameDetector(),
            commandRunner: FakeCommandRunner(),
            sleeper: FakeSleeper(clock: clock),
            resolver: resolver))
    }

    func testRefreshResolvesOnceAndChecksTheResolvedIP() async throws {
        let clock = TestClock()
        let resolver = FakeAddressResolver(["game.example": .success([TestAddresses.v6("2001:db8::1"), TestAddresses.v4("51.68.190.91")])])
        let udp = FakeServer.healthy(clock: clock)
        let model = makeModel(resolver: resolver, udp: udp, clock: clock)
        model.addServer(ServerDraft(label: "G", host: "game.example"))
        await model.waitForResolutions()
        let id = try XCTUnwrap(model.servers.first?.id)

        await model.refresh().value
        XCTAssertEqual(model.rowStatus(id)?.currentCID, "d9de0eb4419608a8423241430581e91c")
        XCTAssertEqual(model.rowStatus(id)?.resolvedIP, "51.68.190.91")
        XCTAssertEqual(model.servers.first?.banCheck?.status, .cidOk)
        let connect = try XCTUnwrap(udp.sentPackets.first(where: FakeServer.isConnect))
        XCTAssertTrue(String(decoding: connect, as: UTF8.self).contains("uuid=d9de0eb4419608a8423241430581e91c"))

        clock.advance(60)
        await model.refresh().value
        XCTAssertEqual(resolver.callCount, 1)   // cached for 5 minutes
        clock.advance(300)
        await model.refresh().value
        XCTAssertEqual(resolver.callCount, 2)
    }

    func testAddedHostnameIsPendingThenResolvedOrInvalid() async throws {
        let clock = TestClock()
        let resolver = FakeAddressResolver(["ok.example": .success([TestAddresses.v4("127.0.0.1")]),
                                            "down.example": .failure(.network)])
        let model = makeModel(resolver: resolver, udp: FakeServer.healthy(clock: clock), clock: clock)
        await model.refresh().value

        model.addServer(ServerDraft(label: "ok", host: "ok.example"))
        let ok = try XCTUnwrap(model.servers.last?.id)
        XCTAssertEqual(model.rowStatus(ok)?.resolutionFailure, .pending)
        await model.waitForResolutions()
        XCTAssertEqual(model.rowStatus(ok)?.currentCID, "e3f650e2c5f1293838ba8e934ba3b796")
        XCTAssertEqual(model.rowStatus(ok)?.level, .orange)

        model.addServer(ServerDraft(label: "down", host: "down.example"))
        let down = try XCTUnwrap(model.servers.last?.id)
        await model.waitForResolutions()
        XCTAssertEqual(model.rowStatus(down)?.message, .invalidHost)
        XCTAssertEqual(model.rowStatus(down)?.resolutionFailure, .network)
        XCTAssertNil(model.appealText(for: down))
    }
}

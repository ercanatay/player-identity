import XCTest
@testable import PlayerIdentity

/// §42 watched servers: change detection, texts, watch off, first observation, dedupe, map, online threshold,
/// filter, persistence, old records.
@MainActor
final class WatchTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func check(_ status: BanStatus, at offset: TimeInterval = 0, map: String? = "de_dust2") -> BanCheck {
        BanCheck(status: status, checkedAt: Self.t0 + offset, detail: "",
                 info: status == .unreachable ? nil : ServerInfo(map: map, players: 3, maxPlayers: 16, pingMillis: 30))
    }

    private func run(_ checks: [BanCheck]) -> [[WatchEvent]] {
        var state: WatchSnapshot?
        return checks.map { check in
            let (next, events) = WatchTransitions.evaluate(previous: state, check: check)
            state = next
            return events
        }
    }

    // MARK: Detection

    func testFirstObservationHasNoEvent() {
        XCTAssertEqual(run([check(.ipBanned)]), [[]])
        XCTAssertEqual(run([check(.unreachable)]), [[]])
    }

    func testBanAppearedAndLifted() {
        let events = run([check(.cidOk), check(.ipBanned, at: 60), check(.ipBanned, at: 120), check(.cidBanned, at: 180),
                          check(.cidOk, at: 240), check(.cidUnknown, at: 300), check(.cidOk, at: 360)])
        XCTAssertEqual(events, [[], [.banAppeared(.ipBanned, previous: .cidOk)], [],
                                [.banAppeared(.cidBanned, previous: .ipBanned)],      // type changed
                                [.banLifted(previous: .cidBanned, now: .cidOk)],
                                [], []])                                               // undetermined keeps the baseline
    }

    func testOfflineAndOnlineThreshold() {
        // Short outage (5 min): offline is reported, "back online" is not.
        XCTAssertEqual(run([check(.cidOk), check(.unreachable, at: 60), check(.unreachable, at: 120), check(.cidOk, at: 360)]),
                       [[], [.offline], [], []])
        // Outage of 10 minutes or more: both.
        XCTAssertEqual(run([check(.cidOk), check(.unreachable, at: 60), check(.cidOk, at: 60 + 600)]),
                       [[], [.offline], [.online(after: 600)]])
        // Watching started while offline: the outage counts from the first offline observation.
        XCTAssertEqual(run([check(.unreachable), check(.cidOk, at: 900)]), [[], [.online(after: 900)]])
    }

    func testMapChangedOldToNew() {
        XCTAssertEqual(run([check(.cidOk, map: "de_dust2"), check(.cidOk, at: 60, map: "cs_office"),
                            check(.cidOk, at: 120, map: nil), check(.cidOk, at: 180, map: "cs_office")]),
                       [[], [.mapChanged(old: "de_dust2", new: "cs_office")], [], []])
        // A ban and a map change in the same check are both reported.
        XCTAssertEqual(run([check(.cidOk, map: "a"), check(.cidBanned, at: 60, map: "b")]),
                       [[], [.banAppeared(.cidBanned, previous: .cidOk), .mapChanged(old: "a", new: "b")]])
    }

    func testHistoryEntries() {
        let server = ServerEntry(label: "EU", host: "192.0.2.10")
        XCTAssertEqual(WatchTransitions.historyEntry(.banAppeared(.ipBanned, previous: .cidOk), server: server, at: Self.t0),
                       HistoryEntry(ts: Self.t0, kind: .watchBanAppeared, serverID: server.id, host: "192.0.2.10",
                                    old: "cidOk", new: "ipBanned"))
        XCTAssertEqual(WatchTransitions.historyEntry(.online(after: 900), server: server, at: Self.t0).note, "15")
        XCTAssertEqual(WatchTransitions.historyEntry(.mapChanged(old: "a", new: "b"), server: server, at: Self.t0).old, "a")
        XCTAssertEqual(WatchTransitions.historyEntry(.offline, server: server, at: Self.t0).kind, .watchOffline)
    }

    // MARK: Texts

    func testNotificationTextsInBothLanguages() throws {
        let server = ServerEntry(label: "Zombie TR", host: "192.0.2.10")
        let events: [WatchEvent] = [.banAppeared(.cidBanned, previous: .cidOk), .banLifted(previous: .ipBanned, now: .cidOk),
                                    .offline, .online(after: 1200), .mapChanged(old: "de_dust2", new: "cs_office")]
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            let texts = events.map { WatchNotificationText.content(for: $0, server: server) }
            XCTAssertEqual(texts[0].title, "İzlenen sunucuda ban: Zombie TR")
            XCTAssertTrue(texts[0].body.contains("CID ban"))
            XCTAssertEqual(texts[1].title, "Ban kalktı: Zombie TR")
            XCTAssertEqual(texts[2].title, "Sunucu erişilemez: Zombie TR")
            XCTAssertTrue(texts[3].body.contains("20"))
            XCTAssertEqual(texts[4].body, "de_dust2 → cs_office")
            XCTAssertEqual(HistoryText.kind(.watchMapChanged), "İzleme: harita değişti")
            XCTAssertEqual(HistoryText.note(HistoryEntry(ts: Self.t0, kind: .watchOnline, note: "15")), "15 dakika kesintiden sonra")
            XCTAssertEqual(HistoryText.change(HistoryEntry(ts: Self.t0, kind: .watchBanAppeared, old: "cidOk", new: "ipBanned")),
                           "Engel yok → IP ban")
            XCTAssertEqual(L10n.text(.serversFilterWatched), "Yalnız izlenenler")
            XCTAssertEqual(L10n.text(.watchToggleOn), "Bu sunucuyu izle")
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            let texts = events.map { WatchNotificationText.content(for: $0, server: server) }
            XCTAssertEqual(texts[0].title, "Ban on a watched server: Zombie TR")
            XCTAssertEqual(texts[3].title, "Server back online: Zombie TR")
            XCTAssertEqual(texts[4].title, "Map changed: Zombie TR")
            XCTAssertEqual(HistoryText.kind(.watchOnline), "Watch: back online")
        }
        // Dedupe keys: kind + server + value.
        let keys = events.map { WatchNotificationText.content(for: $0, server: server).key }
        XCTAssertEqual(Set(keys).count, 5)
        XCTAssertTrue(keys[0].hasPrefix("watchBanAppeared|\(server.id.uuidString)|cidBanned"))
    }

    // MARK: App model

    private func transport(_ status: @escaping @Sendable () -> (banned: Bool, offline: Bool, map: String),
                           clock: TestClock) -> FakeUDPTransport {
        FakeUDPTransport(clock: clock) { endpoint, packet in
            let state = status()
            if state.offline { return [] }
            let info = FakeReply(bytes: A2SFixture.goldSrc(map: state.map))
            let challenge = state.banned ? FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8)))
                                         : FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes))
            return FakeServer.scripted(info: info, challenge: challenge)(endpoint, packet)
        }
    }

    func testWatchedServerNotifiesChangesAndUnwatchedDoesNot() async throws {
        let env = try TestAppEnvironment()
        let server = ServerState()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(udp: transport(server.read, clock: env.clock), notifier: notifier)
        model.addServer(ServerDraft(label: "Watched", host: "192.0.2.10"))
        model.addServer(ServerDraft(label: "Other", host: "192.0.2.20"))
        let watched = try XCTUnwrap(model.servers.first?.id)
        model.setWatch(true, for: watched)
        XCTAssertTrue(model.hasWatchedServers)

        await model.refresh().value                      // first observation: nothing
        await model.waitForHistory()
        XCTAssertEqual(watchEntries(env), [])

        server.set(banned: true, map: "cs_office")
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(watchEntries(env).map(\.kind), [.watchBanAppeared, .watchMapChanged])
        XCTAssertTrue(watchEntries(env).allSatisfy { $0.serverID == watched })      // "Other" is not watched
        XCTAssertEqual(notifier.posts.count, 2)                                       // no duplicate legacy ban notification
        XCTAssertTrue(notifier.posts.contains { $0.key.hasPrefix("watchBanAppeared|") })
        XCTAssertFalse(notifier.posts.contains { $0.key.hasPrefix("banAppeared|") })
        XCTAssertTrue(env.historyStore.load().contains { $0.kind == .banAppeared })   // the regular history is kept

        server.set(offline: true)
        env.clock.advance(60)
        await model.refresh().value
        server.set(banned: true, map: "cs_office")                                   // back after 1 minute: no "online"
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(watchEntries(env).map(\.kind), [.watchBanAppeared, .watchMapChanged, .watchOffline])

        server.set(offline: true)                                                     // offline again within 10 min → deduped
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(watchEntries(env).filter { $0.kind == .watchOffline }.count, 2)   // history keeps both
        XCTAssertEqual(notifier.posts.filter { $0.key.hasPrefix("watchOffline|") }.count, 1)   // notified once

        server.set(banned: false, map: "cs_office")                                   // back after 11 minutes
        env.clock.advance(11 * 60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(Array(watchEntries(env).map(\.kind).suffix(2)), [.watchOnline, .watchBanLifted])
    }

    func testNotificationsOffStillWritesHistory() async throws {
        let env = try TestAppEnvironment()
        let server = ServerState()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(udp: transport(server.read, clock: env.clock), notifier: notifier)
        model.addServer(ServerDraft(label: "Watched", host: "192.0.2.10"))
        model.setWatch(true, for: try XCTUnwrap(model.servers.first?.id))
        model.notificationsEnabled = false
        await model.refresh().value
        server.set(offline: true)
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(watchEntries(env).map(\.kind), [.watchOffline])
        XCTAssertEqual(notifier.posts, [])
    }

    func testBaselineSurvivesARelaunchAndWatchIsSaved() async throws {
        let env = try TestAppEnvironment()
        let server = ServerState()
        let model = env.makeModel(udp: transport(server.read, clock: env.clock))
        model.addServer(ServerDraft(label: "Watched", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        model.setWatch(true, for: id)
        XCTAssertTrue(model.hasUnsavedChanges)
        await model.refresh().value
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        let saved = try XCTUnwrap(SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot)
        XCTAssertEqual(saved.servers.first?.watch, true)
        XCTAssertNotNil(WatchStateStore(fileURL: AppPaths(home: env.home).watchStateFile).load()[id])

        // Relaunch: the first check compares with the stored baseline.
        server.set(banned: true, map: "de_dust2")
        env.clock.advance(60)
        let relaunched = env.makeModel(udp: transport(server.read, clock: env.clock))
        XCTAssertEqual(relaunched.servers.first?.watch, true)
        await relaunched.refresh().value
        await relaunched.waitForHistory()
        XCTAssertEqual(watchEntries(env).map(\.kind), [.watchBanAppeared])

        relaunched.setWatch(false, for: id)
        XCTAssertEqual(relaunched.servers.first?.watch, false)
    }

    func testFilterAndOldRecords() throws {
        let watched = ServerEntry(label: "W", host: "192.0.2.10", watch: true)
        let favorite = ServerEntry(label: "F", host: "192.0.2.11", favorite: true)
        let both = ServerEntry(label: "B", host: "192.0.2.12", favorite: true, watch: true)
        func labels(_ filter: ServerListFilter) -> [String] {
            ServerOrganization.sections([watched, favorite, both], filter: filter).flatMap(\.servers).map(\.label)
        }
        XCTAssertEqual(labels(ServerListFilter(onlyWatched: true)), ["B", "W"])
        XCTAssertEqual(labels(ServerListFilter(onlyFavorites: true, onlyWatched: true)), ["B"])
        XCTAssertEqual(labels(ServerListFilter()).count, 3)

        let json = #"{"id":"1E390D91-9114-454E-A9B3-4AB1833ACD48","label":"A","host":"192.0.2.10","port":27015,"cid":""}"#
        let old = try SnapshotStore.makeDecoder().decode(ServerEntry.self, from: Data(json.utf8))
        XCTAssertFalse(old.watch)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotStore.makeEncoder().encode(watched)) as? [String: Any])
        XCTAssertEqual(encoded["watch"] as? Bool, true)
        XCTAssertNotEqual(EditableState(dataRoot: "/d", gamedir: nil, servers: [watched]),
                          EditableState(dataRoot: "/d", gamedir: nil, servers: [ServerEntry(id: watched.id, label: "W", host: "192.0.2.10")]))
    }

    private func watchEntries(_ env: TestAppEnvironment) -> [HistoryEntry] {
        let kinds: Set<HistoryKind> = [.watchBanAppeared, .watchBanLifted, .watchOffline, .watchOnline, .watchMapChanged]
        return env.historyStore.load().filter { kinds.contains($0.kind) }
    }
}

/// Mutable fake server state shared with the UDP responder.
final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var banned = false
    private var offline = false
    private var map = "de_dust2"

    func set(banned: Bool = false, offline: Bool = false, map: String = "de_dust2") {
        lock.withLock {
            self.banned = banned
            self.offline = offline
            self.map = map
        }
    }

    func read() -> (banned: Bool, offline: Bool, map: String) {
        lock.withLock { (banned, offline, map) }
    }
}

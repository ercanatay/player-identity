import XCTest
@testable import PlayerIdentity

/// §56 per-server notification thresholds: record compatibility, validation, thresholds and their boundaries,
/// mode × category × general switches, quiet-hours override, history kept while notifications are held back.
@MainActor
final class ServerNotificationThresholdTests: XCTestCase {
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    private static let categories: [NotificationCategory] = [.ban, .online, .map]

    // MARK: Record

    func testOldRecordsAndDefaultsInherit() throws {
        let decoder = SnapshotStore.makeDecoder()
        let base = #""id":"1E390D91-9114-454E-A9B3-4AB1833ACD48","label":"A","host":"192.0.2.10","port":27015,"cid":"""#
        func decode(_ extra: String) throws -> ServerEntry {
            try decoder.decode(ServerEntry.self, from: Data(("{" + base + extra + "}").utf8))
        }
        let old = try decode("")
        XCTAssertNil(old.notifications)
        XCTAssertFalse(old.watch)

        let empty = try decode(#","notifications":{}"#)
        XCTAssertEqual(empty.notifications, ServerNotificationSettings())
        XCTAssertEqual(empty.notifications?.isDefault, true)

        // Unknown values and out-of-range thresholds fall back instead of making the record unreadable.
        let tolerant = try decode(#","notifications":{"mode":"loud","pingThresholdMs":-5,"playersAtLeast":9999,"quietHoursOverride":"maybe"}"#)
        XCTAssertEqual(tolerant.notifications, ServerNotificationSettings())
        let partial = try decode(#","notifications":{"mode":"off","pingThresholdMs":"x"}"#)
        XCTAssertEqual(partial.notifications, ServerNotificationSettings(mode: .off))
        let broken = try decode(#","notifications":"x""#)
        XCTAssertNil(broken.notifications)
        XCTAssertEqual(broken.label, "A")

        // Round trip; no override → no key in the file.
        let settings = ServerNotificationSettings(mode: .bansOnly, pingThresholdMs: 80, playersAtLeast: 4,
                                                  quietHoursOverride: .off)
        let entry = ServerEntry(label: "S", host: "192.0.2.10", notifications: settings)
        let data = try SnapshotStore.makeEncoder().encode(entry)
        XCTAssertEqual(try decoder.decode(ServerEntry.self, from: data).notifications, settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(json["notifications"] as? [String: Any])
        XCTAssertEqual(stored["mode"] as? String, "bansOnly")
        XCTAssertEqual(stored["quietHoursOverride"] as? String, "off")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(
            with: SnapshotStore.makeEncoder().encode(ServerEntry(label: "S", host: "192.0.2.10"))) as? [String: Any])
        XCTAssertNil(plain["notifications"])
    }

    // MARK: Validation

    func testThresholdTextValidation() {
        XCTAssertEqual(ServerNotificationThresholds.parsePing(""), .success(0))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("  "), .success(0))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("0"), .success(0))
        XCTAssertEqual(ServerNotificationThresholds.parsePing(" 150 "), .success(150))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("00080"), .success(80))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("5000"), .success(5000))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("5001"), .failure(.tooLarge(max: 5000)))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("99999999999999999999999"), .failure(.tooLarge(max: 5000)))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("-1"), .failure(.notANumber))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("1.5"), .failure(.notANumber))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("80ms"), .failure(.notANumber))
        XCTAssertEqual(ServerNotificationThresholds.parsePing("١٢"), .failure(.notANumber))   // only ASCII digits
        XCTAssertEqual(ServerNotificationThresholds.parsePlayers("256"), .success(256))
        XCTAssertEqual(ServerNotificationThresholds.parsePlayers("257"), .failure(.tooLarge(max: 256)))

        XCTAssertTrue(ServerNotificationSettings(pingThresholdMs: 5000, playersAtLeast: 256).isValid)
        XCTAssertFalse(ServerNotificationSettings(pingThresholdMs: 5001).isValid)
        XCTAssertFalse(ServerNotificationSettings(playersAtLeast: -1).isValid)
    }

    func testDraftMapsFieldsAndRejectsInvalidThresholds() throws {
        let draft = ServerNotificationDraft(ServerNotificationSettings(mode: .all, pingThresholdMs: 0, playersAtLeast: 6))
        XCTAssertEqual(draft.pingText, "")            // 0 = off shows as an empty field
        XCTAssertEqual(draft.playersText, "6")
        XCTAssertEqual(draft.settings, ServerNotificationSettings(mode: .all, playersAtLeast: 6))
        XCTAssertEqual(ServerNotificationDraft(nil).settings, ServerNotificationSettings())

        let invalid = ServerNotificationDraft(mode: .all, pingText: "abc", playersText: "999", quietHours: .on)
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(invalid.settings)
        XCTAssertEqual(invalid.pingError, .notANumber)
        XCTAssertEqual(invalid.playersError, .tooLarge(max: 256))
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(ServerNotificationText.error(.tooLarge(max: 256)), "En fazla 256 olabilir.")
            XCTAssertEqual(L10n.text(.serverNotifyTitle), "Bildirimler")
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(ServerNotificationText.error(.notANumber), "Enter a whole number (empty or 0 = off).")
        }
    }

    // MARK: Thresholds

    func testThresholdBoundaries() {
        let ping = ServerNotificationSettings(pingThresholdMs: 100)
        let players = ServerNotificationSettings(playersAtLeast: 8)
        let map = WatchEvent.mapChanged(old: "a", new: "b")
        let online = WatchEvent.online(after: 900)
        for event in [map, online] {
            XCTAssertTrue(ServerNotificationRules.passesThresholds(event, settings: ping, info: ServerInfo(pingMillis: 100)))
            XCTAssertTrue(ServerNotificationRules.passesThresholds(event, settings: ping, info: ServerInfo(pingMillis: 0)))
            XCTAssertFalse(ServerNotificationRules.passesThresholds(event, settings: ping, info: ServerInfo(pingMillis: 101)))
            XCTAssertFalse(ServerNotificationRules.passesThresholds(event, settings: ping, info: ServerInfo(players: 30)))
            XCTAssertFalse(ServerNotificationRules.passesThresholds(event, settings: ping, info: nil))
            XCTAssertTrue(ServerNotificationRules.passesThresholds(event, settings: players, info: ServerInfo(players: 8)))
            XCTAssertFalse(ServerNotificationRules.passesThresholds(event, settings: players, info: ServerInfo(players: 7)))
            XCTAssertFalse(ServerNotificationRules.passesThresholds(event, settings: players, info: ServerInfo(pingMillis: 5)))
            // Both thresholds must hold.
            let both = ServerNotificationSettings(pingThresholdMs: 100, playersAtLeast: 8)
            XCTAssertTrue(ServerNotificationRules.passesThresholds(event, settings: both, info: ServerInfo(players: 8, pingMillis: 100)))
            XCTAssertFalse(ServerNotificationRules.passesThresholds(event, settings: both, info: ServerInfo(players: 8, pingMillis: 101)))
            XCTAssertFalse(ServerNotificationRules.passesThresholds(event, settings: both, info: ServerInfo(players: 7, pingMillis: 100)))
            // 0 = off, no override = no threshold.
            XCTAssertTrue(ServerNotificationRules.passesThresholds(event, settings: ServerNotificationSettings(), info: nil))
            XCTAssertTrue(ServerNotificationRules.passesThresholds(event, settings: nil, info: nil))
        }
        // Ban and offline events are never held back by a threshold.
        let strict = ServerNotificationSettings(pingThresholdMs: 1, playersAtLeast: 256)
        for event: WatchEvent in [.banAppeared(.ipBanned, previous: .ipOk), .banLifted(previous: .cidBanned, now: .cidOk), .offline] {
            XCTAssertTrue(ServerNotificationRules.passesThresholds(event, settings: strict, info: nil), "\(event)")
        }
    }

    // MARK: Mode × category × general switches

    func testModeCombinationsWithGeneralSwitches() {
        let noon = at(12)
        let allOn = NotificationPolicy()
        let allOff = NotificationPolicy(master: true, banChanges: false, onlineChanges: false, mapChanges: false)
        let masterOff = NotificationPolicy(master: false)
        for mode in ServerNotificationMode.allCases {
            let settings = ServerNotificationSettings(mode: mode)
            for category in Self.categories {
                let expectedOn: Bool, expectedOff: Bool
                switch mode {
                case .inherit: (expectedOn, expectedOff) = (true, false)
                case .all: (expectedOn, expectedOff) = (true, true)
                case .bansOnly: (expectedOn, expectedOff) = (category == .ban, category == .ban)
                case .off: (expectedOn, expectedOff) = (false, false)
                }
                XCTAssertEqual(ServerNotificationRules.allows(category, settings: settings, policy: allOn, at: noon),
                               expectedOn, "\(mode) \(category) switches on")
                XCTAssertEqual(ServerNotificationRules.allows(category, settings: settings, policy: allOff, at: noon),
                               expectedOff, "\(mode) \(category) switches off")
                // The master switch is never turned on by a server.
                XCTAssertFalse(ServerNotificationRules.allows(category, settings: settings, policy: masterOff, at: noon),
                               "\(mode) \(category) master off")
            }
        }
        // Inherit keeps a single category switch.
        let noMap = NotificationPolicy(mapChanges: false)
        XCTAssertFalse(ServerNotificationRules.allows(.map, settings: ServerNotificationSettings(), policy: noMap, at: noon))
        XCTAssertTrue(ServerNotificationRules.allows(.online, settings: ServerNotificationSettings(), policy: noMap, at: noon))
        XCTAssertEqual(noMap.applying(nil), noMap)
    }

    func testQuietHoursOverride() {
        var quietPolicy = NotificationPolicy()
        quietPolicy.quiet = QuietHours(enabled: true, start: "23:00", end: "08:00")
        let loud = NotificationPolicy()   // quiet hours off in Settings (window 23:00–08:00 kept)
        func allowed(_ override: QuietHoursOverride, _ policy: NotificationPolicy, _ hour: Int) -> Bool {
            ServerNotificationRules.allows(.ban, settings: ServerNotificationSettings(quietHoursOverride: override),
                                           policy: policy, at: at(hour))
        }
        XCTAssertFalse(allowed(.inherit, quietPolicy, 2))
        XCTAssertTrue(allowed(.inherit, quietPolicy, 12))
        XCTAssertTrue(allowed(.off, quietPolicy, 2))      // this server is never held back
        XCTAssertFalse(allowed(.on, quietPolicy, 2))
        XCTAssertTrue(allowed(.inherit, loud, 2))
        XCTAssertFalse(allowed(.on, loud, 2))             // the general window applies to this server
        XCTAssertFalse(allowed(.on, loud, 23))
        XCTAssertTrue(allowed(.on, loud, 8))              // window end is exclusive
        XCTAssertTrue(allowed(.off, loud, 2))
        // Override + mode together: bans-only with quiet hours off.
        let combined = ServerNotificationSettings(mode: .bansOnly, quietHoursOverride: .off)
        XCTAssertTrue(ServerNotificationRules.allows(.ban, settings: combined, policy: quietPolicy, at: at(3)))
        XCTAssertFalse(ServerNotificationRules.allows(.map, settings: combined, policy: quietPolicy, at: at(3)))
    }

    func testShouldNotifyCombinesThresholdsModeAndQuietHours() {
        let settings = ServerNotificationSettings(mode: .all, playersAtLeast: 5, quietHoursOverride: .on)
        let info = ServerInfo(map: "b", players: 5, pingMillis: 40)
        let map = WatchEvent.mapChanged(old: "a", new: "b")
        let policy = NotificationPolicy(mapChanges: false)
        XCTAssertTrue(ServerNotificationRules.shouldNotify(map, settings: settings, info: info, policy: policy, at: at(12)))
        XCTAssertFalse(ServerNotificationRules.shouldNotify(map, settings: settings, info: info, policy: policy, at: at(1)))
        XCTAssertFalse(ServerNotificationRules.shouldNotify(map, settings: settings, info: ServerInfo(players: 4),
                                                            policy: policy, at: at(12)))
        XCTAssertFalse(ServerNotificationRules.shouldNotify(map, settings: nil, info: info, policy: policy, at: at(12)))
    }

    func testDispatcherAppliesTheServerOverride() async {
        let time = at(12)
        func posted(_ contents: [NotificationContent], policy: NotificationPolicy?) async -> [String] {
            let dispatcher = NotificationDispatcher(notifier: FakeNotifier(status: .authorized), now: { time })
            return await dispatcher.handle(contents, enabled: true, policy: policy).map(\.key)
        }
        let off = ServerNotificationSettings(mode: .off)
        let bans = ServerNotificationSettings(mode: .bansOnly)
        let contents = [
            NotificationContent(key: "off-ban", title: "t", body: "b", category: .ban, server: off),
            NotificationContent(key: "bans-ban", title: "t", body: "b", category: .ban, server: bans),
            NotificationContent(key: "bans-map", title: "t", body: "b", category: .map, server: bans),
            NotificationContent(key: "plain-map", title: "t", body: "b", category: .map),
            NotificationContent(key: "general", title: "t", body: "b"),
        ]
        let general = await posted(contents, policy: NotificationPolicy())
        XCTAssertEqual(general, ["bans-ban", "plain-map", "general"])
        // Without a general policy the server override still applies.
        let withoutPolicy = await posted(contents, policy: nil)
        XCTAssertEqual(withoutPolicy, ["bans-ban", "plain-map", "general"])
    }

    // MARK: App model

    private func transport(_ server: ServerState, clock: TestClock) -> FakeUDPTransport {
        FakeUDPTransport(clock: clock) { endpoint, packet in
            let state = server.read()
            if state.offline { return [] }
            let info = FakeReply(bytes: A2SFixture.goldSrc(map: state.map))   // 9 players
            let challenge = state.banned ? FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8)))
                                         : FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes))
            return FakeServer.scripted(info: info, challenge: challenge)(endpoint, packet)
        }
    }

    private func entries(_ env: TestAppEnvironment, _ kind: HistoryKind) -> [HistoryEntry] {
        env.historyStore.load().filter { $0.kind == kind }
    }

    func testSetServerNotificationsValidatesStoresAndSaves() throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "S", host: "192.0.2.10"))
        model.save()
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertFalse(model.hasUnsavedChanges)

        XCTAssertFalse(model.setServerNotifications(ServerNotificationSettings(pingThresholdMs: 6000), for: id))
        XCTAssertNil(model.servers.first?.notifications)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.setServerNotifications(ServerNotificationSettings(mode: .off), for: UUID()))

        // Defaults stay `nil` (inherit) and are not an edit.
        XCTAssertTrue(model.setServerNotifications(ServerNotificationSettings(), for: id))
        XCTAssertNil(model.servers.first?.notifications)
        XCTAssertFalse(model.hasUnsavedChanges)

        let settings = ServerNotificationSettings(mode: .bansOnly, pingThresholdMs: 120, playersAtLeast: 3,
                                                  quietHoursOverride: .on)
        XCTAssertTrue(model.setServerNotifications(settings, for: id))
        XCTAssertEqual(model.servers.first?.notifications, settings)
        XCTAssertTrue(model.hasUnsavedChanges)
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(env.makeModel().servers.first?.notifications, settings)

        XCTAssertTrue(model.setServerNotifications(ServerNotificationSettings(), for: id))   // back to inherit
        XCTAssertNil(model.servers.first?.notifications)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testBelowThresholdIsNotNotifiedButHistoryIsWritten() async throws {
        let env = try TestAppEnvironment()
        let server = ServerState()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(udp: transport(server, clock: env.clock), notifier: notifier)
        model.addServer(ServerDraft(label: "Watched", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        model.setWatch(true, for: id)
        model.setServerNotifications(ServerNotificationSettings(playersAtLeast: 10), for: id)   // fixture has 9
        await model.refresh().value

        server.set(map: "cs_office")
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(entries(env, .watchMapChanged).count, 1)
        XCTAssertEqual(notifier.posts, [])

        // Boundary: "at least 9" lets the next change through.
        model.setServerNotifications(ServerNotificationSettings(playersAtLeast: 9), for: id)
        server.set(map: "de_nuke")
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(entries(env, .watchMapChanged).count, 2)
        XCTAssertEqual(notifier.posts.map(\.key), ["watchMapChanged|\(id.uuidString)|de_nuke"])
        XCTAssertEqual(notifier.posts.first?.server, ServerNotificationSettings(playersAtLeast: 9))

        // A ban is never held back by the threshold.
        model.setServerNotifications(ServerNotificationSettings(playersAtLeast: 200), for: id)
        server.set(banned: true, map: "de_nuke")
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(entries(env, .watchBanAppeared).count, 1)
        XCTAssertTrue(notifier.posts.contains { $0.key.hasPrefix("watchBanAppeared|") })
    }

    func testModesForWatchedAndUnwatchedServers() async throws {
        let env = try TestAppEnvironment()
        let server = ServerState()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(udp: transport(server, clock: env.clock), notifier: notifier)
        model.addServer(ServerDraft(label: "Bans only", host: "192.0.2.10"))
        model.addServer(ServerDraft(label: "Silent", host: "192.0.2.11"))
        model.addServer(ServerDraft(label: "Silent unwatched", host: "192.0.2.12"))
        model.addServer(ServerDraft(label: "Plain unwatched", host: "192.0.2.13"))
        let ids = model.servers.map(\.id)
        model.setWatch(true, for: ids[0])
        model.setWatch(true, for: ids[1])
        model.setServerNotifications(ServerNotificationSettings(mode: .bansOnly), for: ids[0])
        model.setServerNotifications(ServerNotificationSettings(mode: .off), for: ids[1])
        model.setServerNotifications(ServerNotificationSettings(mode: .off), for: ids[2])
        await model.refresh().value
        await model.waitForHistory()

        server.set(banned: true, map: "cs_office")                    // every server: ban + map change
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()

        // History is complete…
        XCTAssertEqual(Set(entries(env, .watchBanAppeared).compactMap(\.serverID)), [ids[0], ids[1]])
        XCTAssertEqual(Set(entries(env, .watchMapChanged).compactMap(\.serverID)), [ids[0], ids[1]])
        XCTAssertEqual(Set(entries(env, .banAppeared).compactMap(\.serverID)), Set(ids))
        // …but only the allowed notifications were posted (a first ban of an unwatched server is never notified).
        XCTAssertEqual(notifier.posts.map(\.key), ["watchBanAppeared|\(ids[0].uuidString)|ipBanned"])

        server.set(banned: false, map: "cs_office")                   // every ban lifted
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(Set(entries(env, .watchBanLifted).compactMap(\.serverID)), [ids[0], ids[1]])
        XCTAssertEqual(Set(entries(env, .banLifted).compactMap(\.serverID)), Set(ids))
        let keys = notifier.posts.map(\.key)
        XCTAssertEqual(keys.count, 3, "\(keys)")
        XCTAssertTrue(keys.contains { $0.hasPrefix("watchBanLifted|\(ids[0].uuidString)") }, "\(keys)")   // bans only
        XCTAssertTrue(keys.contains { $0.hasPrefix("banLifted|\(ids[3].uuidString)") }, "\(keys)")        // inherit
        XCTAssertFalse(keys.contains { $0.contains(ids[1].uuidString) })                                 // off (watched)
        XCTAssertFalse(keys.contains { $0.contains(ids[2].uuidString) })                                 // off (refresh ban)
        XCTAssertFalse(keys.contains { $0.hasPrefix("watchMapChanged|") })
    }
}

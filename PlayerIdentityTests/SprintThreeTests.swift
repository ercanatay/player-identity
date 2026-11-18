import XCTest
@testable import PlayerIdentity

// MARK: - Fakes

/// Ban record endpoint whose reply can change between lookups (ban lifted early, extended, …).
final class SwitchableBanRecordHTTP: BanRecordHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var body: String

    init(_ body: String) { self.body = body }

    func set(_ body: String) { lock.withLock { self.body = body } }

    func get(_ url: URL, bearerToken: String?, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        (Data(lock.withLock { body }.utf8), 200)
    }
}

final class RecordingWidgetReloader: WidgetReloading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reloads: Int { lock.withLock { count } }
    func reloadTimelines() { lock.withLock { count += 1 } }
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func banJSON(expires: Date?, permanent: Bool = false, created: Date? = nil) -> String {
    var fields = [#""reason":"Wallhack""#, #""admin":"Kerem""#]
    if let created { fields.append(#""created":"\#(iso(created))""#) }
    if let expires { fields.append(#""expires":"\#(iso(expires))""#) }
    if permanent { fields.append(#""permanent":true"#) }
    return #"{"bans":[{\#(fields.joined(separator: ","))}]}"#
}

// MARK: - §69.1 Planner

final class BanExpiryPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let server = UUID()

    private func result(_ entries: [BanRecordEntry]) -> BanRecordResult {
        BanRecordResult(entries: entries, fetchedAt: now)
    }

    private func timed(_ offset: TimeInterval) -> BanRecordEntry {
        BanRecordEntry(reason: nil, admin: nil, created: nil, expires: now.addingTimeInterval(offset), permanent: false,
                       playerIP: nil, playerID: nil)
    }

    func testExpiryOnlyForActiveTimedBansWithAKnownEnd() {
        XCTAssertEqual(BanExpiryPlanner.expiry(of: result([timed(3600)])), now.addingTimeInterval(3600))
        // Several timed bans: the ban is over when the last one ends.
        XCTAssertEqual(BanExpiryPlanner.expiry(of: result([timed(600), timed(7200)])), now.addingTimeInterval(7200))
        // Ended, permanent, mixed with permanent, empty: nothing to plan.
        XCTAssertNil(BanExpiryPlanner.expiry(of: result([timed(-60)])))
        let permanent = BanRecordEntry(reason: nil, admin: nil, created: nil, expires: nil, permanent: true,
                                       playerIP: nil, playerID: nil)
        XCTAssertNil(BanExpiryPlanner.expiry(of: result([permanent])))
        XCTAssertNil(BanExpiryPlanner.expiry(of: result([timed(3600), permanent])))
        XCTAssertNil(BanExpiryPlanner.expiry(of: result([])))
    }

    func testReconcilePlansKeepsAndReplaces() {
        let end = now.addingTimeInterval(3600)
        var watches = BanExpiryPlanner.reconcile([], serverID: server, cid: "c1", result: result([timed(3600)]),
                                                 notify: true, soonEnabled: true)
        XCTAssertEqual(watches.map(\.kind), [.soon, .ended])
        XCTAssertEqual(watches.map(\.expiresAt), [end, end])
        XCTAssertEqual(watches.first?.fireAt, end.addingTimeInterval(-600))
        // The same end keeps the records (and their `notifiedAt`).
        watches[0].notifiedAt = now
        let same = BanExpiryPlanner.reconcile(watches, serverID: server, cid: "c1", result: result([timed(3600)]),
                                              notify: true, soonEnabled: true)
        XCTAssertEqual(same, watches)
        // A new end (extended ban) or another CID plans again.
        let extended = BanExpiryPlanner.reconcile(watches, serverID: server, cid: "c1", result: result([timed(7200)]),
                                                  notify: true, soonEnabled: true)
        XCTAssertEqual(extended.map(\.notifiedAt), [nil, nil])
        XCTAssertEqual(BanExpiryPlanner.reconcile(watches, serverID: server, cid: "c2", result: result([timed(3600)]),
                                                  notify: true, soonEnabled: true).map(\.cid), ["c2", "c2"])
        // "10 minutes before" off: only the end.
        XCTAssertEqual(BanExpiryPlanner.reconcile([], serverID: server, cid: "c1", result: result([timed(3600)]),
                                                  notify: true, soonEnabled: false).map(\.kind), [.ended])
        // Early lift, switch off: the server's records go, other servers' stay.
        let other = BanExpiryWatch(serverID: UUID(), cid: "x", expiresAt: end, notifiedAt: nil, kind: .ended)
        XCTAssertEqual(BanExpiryPlanner.reconcile(watches + [other], serverID: server, cid: "c1", result: result([]),
                                                  notify: true, soonEnabled: true), [other])
        XCTAssertEqual(BanExpiryPlanner.reconcile(watches + [other], serverID: server, cid: "c1",
                                                  result: result([timed(3600)]), notify: false, soonEnabled: true), [other])
    }

    func testDueAtTheTenMinuteThresholdAndAtTheEnd() {
        let end = now.addingTimeInterval(3600)
        let watches = [BanExpiryWatch(serverID: server, cid: "c", expiresAt: end, notifiedAt: nil, kind: .soon),
                       BanExpiryWatch(serverID: server, cid: "c", expiresAt: end, notifiedAt: nil, kind: .ended)]
        XCTAssertEqual(BanExpiryPlanner.due(watches, now: end.addingTimeInterval(-601)), [])
        XCTAssertEqual(BanExpiryPlanner.due(watches, now: end.addingTimeInterval(-600)).map(\.kind), [.soon])
        XCTAssertEqual(BanExpiryPlanner.due(watches, now: end.addingTimeInterval(-1)).map(\.kind), [.soon])
        // At the end only the end notification is due; the overtaken `soon` is obsolete.
        XCTAssertEqual(BanExpiryPlanner.due(watches, now: end).map(\.kind), [.ended])
        XCTAssertEqual(BanExpiryPlanner.obsolete(watches, now: end).map(\.kind), [.soon])
        // Sent records are never due again.
        var sent = watches
        sent[1].notifiedAt = end
        XCTAssertEqual(BanExpiryPlanner.due(sent, now: end.addingTimeInterval(60)), [])
    }

    func testDecisionMasterBanSwitchServerOffAndQuietHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let noon = Date(timeIntervalSince1970: 1_795_003_200)   // 12:00 UTC
        var policy = NotificationPolicy()
        XCTAssertEqual(BanExpiryPlanner.decision(policy: policy, server: nil, at: noon, calendar: calendar), .post)
        policy.quiet = QuietHours(enabled: true, start: "11:00", end: "13:00")
        XCTAssertEqual(BanExpiryPlanner.decision(policy: policy, server: nil, at: noon, calendar: calendar), .postpone)
        // A server that ignores quiet hours posts.
        XCTAssertEqual(BanExpiryPlanner.decision(policy: policy, server: ServerNotificationSettings(quietHoursOverride: .off),
                                                 at: noon, calendar: calendar), .post)
        policy.quiet.enabled = false
        XCTAssertEqual(BanExpiryPlanner.decision(policy: policy, server: ServerNotificationSettings(mode: .off),
                                                 at: noon, calendar: calendar), .drop)
        policy.banChanges = false
        XCTAssertEqual(BanExpiryPlanner.decision(policy: policy, server: nil, at: noon, calendar: calendar), .drop)
        policy.banChanges = true
        policy.master = false
        XCTAssertEqual(BanExpiryPlanner.decision(policy: policy, server: ServerNotificationSettings(mode: .all),
                                                 at: noon, calendar: calendar), .drop)
    }

    func testTimerDelayPruneAndUpcoming() {
        let end = now.addingTimeInterval(3600)
        let soon = BanExpiryWatch(serverID: server, cid: "c", expiresAt: end, notifiedAt: nil, kind: .soon)
        let ended = BanExpiryWatch(serverID: server, cid: "c", expiresAt: end, notifiedAt: nil, kind: .ended)
        XCTAssertNil(BanExpiryPlanner.nextDelay([], now: now))
        XCTAssertEqual(BanExpiryPlanner.nextDelay([ended], now: end.addingTimeInterval(-120)), 120)
        XCTAssertEqual(BanExpiryPlanner.nextDelay([ended], now: now), BanExpiryPlanner.maxTimerDelay)
        // Due but held back (quiet hours): a minute, never a tight loop.
        XCTAssertEqual(BanExpiryPlanner.nextDelay([ended], now: end.addingTimeInterval(5)), BanExpiryPlanner.retryDelay)
        var sent = ended
        sent.notifiedAt = end
        XCTAssertNil(BanExpiryPlanner.nextDelay([sent], now: end))

        let gone = BanExpiryWatch(serverID: UUID(), cid: "c", expiresAt: end, notifiedAt: nil, kind: .ended)
        var old = sent
        old.notifiedAt = now.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(BanExpiryPlanner.prune([soon, ended, gone, old], serverIDs: [server], soonEnabled: false, now: now),
                       [ended])
        XCTAssertEqual(BanExpiryPlanner.prune([soon, ended], serverIDs: [server], soonEnabled: true, now: now), [soon, ended])

        let far = BanExpiryWatch(serverID: server, cid: "c", expiresAt: now.addingTimeInterval(86_401), notifiedAt: nil, kind: .ended)
        let near = BanExpiryWatch(serverID: server, cid: "c", expiresAt: now.addingTimeInterval(600), notifiedAt: nil, kind: .ended)
        XCTAssertEqual(BanExpiryPlanner.upcoming([far, soon, ended, near], now: now), [near, ended])
    }

    func testSnapshotKeepsTheWatchesAndOldRecordsStayReadable() throws {
        let watch = BanExpiryWatch(serverID: server, cid: "abc", expiresAt: Date(timeIntervalSince1970: 1_795_003_600),
                                   notifiedAt: nil, kind: .ended)
        var snapshot = Snapshot(savedAt: now, gamedir: "valve", dataRoot: "/x", displayName: "N", model: "m", rawID: "",
                                identitySource: "", network: NetworkInfo(publicIP: "", lanIPs: [], checkedAt: nil), servers: [])
        snapshot.banExpiryWatch = [watch]
        let data = try SnapshotStore.makeEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for field in ["\"banExpiryWatch\"", "\"serverID\"", "\"cid\"", "\"expiresAt\"", "\"kind\" : \"ended\""] {
            XCTAssertTrue(json.contains(field), field)
        }
        XCTAssertEqual(SnapshotStore.decode(data).snapshot?.banExpiryWatch, [watch])
        // A broken list never makes the record unreadable.
        let broken = json.replacingOccurrences(of: "\"kind\" : \"ended\"", with: "\"kind\" : 7")
        let decoded = try XCTUnwrap(SnapshotStore.decode(Data(broken.utf8)).snapshot)
        XCTAssertNil(decoded.banExpiryWatch)
    }
}

// MARK: - §69.1 App model

@MainActor
final class BanExpiryModelTests: XCTestCase {
    private let template = "https://bans.example.com/api/bans?cid={cid}"

    override func tearDown() async throws {
        L10n.setting = .system
    }

    /// A saved record with one server whose ban record reports a ban ending in `ends` seconds.
    private func makeModel(_ env: TestAppEnvironment, notifier: FakeNotifier, http: SwitchableBanRecordHTTP)
        async throws -> (AppModel, UUID) {
        let model = env.makeModel(notifier: notifier) { deps in
            deps.banRecordHTTP = http
            deps.secretStore = FakeSecretStore()
        }
        model.addServer(ServerDraft(label: "Zombie TR", host: "198.51.100.20"))
        await model.refresh().value
        model.save()
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertNil(model.setBanRecord(urlTemplate: template, enabled: true, token: nil, for: id))
        model.save()
        return (model, id)
    }

    private func savedWatches(_ env: TestAppEnvironment) -> [BanExpiryWatch] {
        SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot?.banExpiryWatch ?? []
    }

    func testLookupPlansPersistsAndAReloadKeepsThePlan() async throws {
        let env = try TestAppEnvironment()
        let end = env.clock.now.addingTimeInterval(2 * 3600)
        let notifier = FakeNotifier(status: .authorized)
        let (model, id) = try await makeModel(env, notifier: notifier, http: SwitchableBanRecordHTTP(banJSON(expires: end)))
        await model.refreshBanRecord(for: id)?.value
        XCTAssertEqual(model.banExpiryWatches.map(\.kind), [.soon, .ended])
        XCTAssertEqual(model.plannedBanExpiries(for: id).map(\.fireAt), [end.addingTimeInterval(-600), end])
        XCTAssertTrue(model.isBanExpiryNotifyOn(for: id))
        XCTAssertFalse(model.hasUnsavedChanges, "the plan is bookkeeping, not an edit")
        let saved = savedWatches(env)
        XCTAssertEqual(saved, model.banExpiryWatches)
        XCTAssertEqual(saved.first?.cid, model.rowStatus(id)?.currentCID)
        // Upcoming row (≤ 1 day).
        XCTAssertEqual(model.upcomingBanExpiries.map(\.label), ["Zombie TR"])
        // Relaunch: the plan comes back from profile.json.
        let again = env.makeModel(notifier: notifier)
        XCTAssertEqual(again.banExpiryWatches, saved)
        XCTAssertEqual(notifier.posts, [])
    }

    func testTenMinutesBeforeAndAtTheEndOnceEach() async throws {
        let env = try TestAppEnvironment()
        let end = env.clock.now.addingTimeInterval(3600)
        let notifier = FakeNotifier(status: .authorized)
        let (model, id) = try await makeModel(env, notifier: notifier, http: SwitchableBanRecordHTTP(banJSON(expires: end)))
        L10n.setting = .en
        await model.refreshBanRecord(for: id)?.value
        XCTAssertNil(model.checkBanExpiryNotifications(), "nothing is due an hour before the end")

        env.clock.advance(3600 - 600)
        await model.checkBanExpiryNotifications()?.value
        XCTAssertEqual(notifier.posts.map(\.title), ["Ban lifts in 10 minutes"])
        XCTAssertEqual(notifier.posts.first?.serverID, id)
        XCTAssertTrue(notifier.posts.first?.body.hasPrefix("Zombie TR: the ban ends at ") == true)
        XCTAssertNil(model.checkBanExpiryNotifications(), "no repeat")

        env.clock.advance(600)
        await model.checkBanExpiryNotifications()?.value
        XCTAssertEqual(notifier.posts.map(\.title), ["Ban lifts in 10 minutes", "Ban lifted"])
        XCTAssertEqual(notifier.posts.last?.body, "Zombie TR: the timed ban has ended")
        env.clock.advance(3600)
        XCTAssertNil(model.checkBanExpiryNotifications())
        XCTAssertEqual(notifier.posts.count, 2)
        // `notifiedAt` is saved: a relaunch does not notify again.
        XCTAssertTrue(savedWatches(env).allSatisfy { $0.notifiedAt != nil })
        let relaunched = env.makeModel(notifier: notifier)
        XCTAssertNil(relaunched.checkBanExpiryNotifications())
        XCTAssertEqual(notifier.posts.count, 2)
    }

    func testQuietHoursHoldBackAndOnlyOneNotificationFollows() async throws {
        let env = try TestAppEnvironment()
        let end = env.clock.now.addingTimeInterval(3600)
        let notifier = FakeNotifier(status: .authorized)
        let (model, id) = try await makeModel(env, notifier: notifier, http: SwitchableBanRecordHTTP(banJSON(expires: end)))
        await model.refreshBanRecord(for: id)?.value
        // Quiet from 20 minutes before the end to 20 minutes after it (local time, like the app).
        let parts = { (date: Date) -> String in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            return QuietHours.text(minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
        }
        model.quietHoursStart = parts(end.addingTimeInterval(-20 * 60))
        model.quietHoursEnd = parts(end.addingTimeInterval(20 * 60 + 60))
        model.quietHoursEnabled = true

        env.clock.advance(3600 - 600)
        XCTAssertNil(model.checkBanExpiryNotifications())
        env.clock.advance(600)
        XCTAssertNil(model.checkBanExpiryNotifications())
        XCTAssertEqual(notifier.posts, [])
        XCTAssertEqual(model.banExpiryWatches.map(\.kind), [.ended], "the overtaken 'soon' is dropped")

        env.clock.advance(25 * 60)
        await model.checkBanExpiryNotifications()?.value
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertEqual(notifier.posts.first?.category, .ban)
        XCTAssertNil(model.checkBanExpiryNotifications())
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func testServerModeOffAndBanSwitchOffSendNothing() async throws {
        let env = try TestAppEnvironment()
        let end = env.clock.now.addingTimeInterval(3600)
        let notifier = FakeNotifier(status: .authorized)
        let (model, id) = try await makeModel(env, notifier: notifier, http: SwitchableBanRecordHTTP(banJSON(expires: end)))
        await model.refreshBanRecord(for: id)?.value
        XCTAssertTrue(model.setServerNotifications(ServerNotificationSettings(mode: .off), for: id))
        env.clock.advance(3600)
        XCTAssertNil(model.checkBanExpiryNotifications())
        XCTAssertEqual(notifier.posts, [])
        XCTAssertEqual(model.banExpiryWatches, [], "dropped: it never fires later")

        let env2 = try TestAppEnvironment()
        let end2 = env2.clock.now.addingTimeInterval(3600)
        let (model2, id2) = try await makeModel(env2, notifier: notifier, http: SwitchableBanRecordHTTP(banJSON(expires: end2)))
        await model2.refreshBanRecord(for: id2)?.value
        model2.notifyBanChanges = false
        env2.clock.advance(3600)
        XCTAssertNil(model2.checkBanExpiryNotifications())
        XCTAssertEqual(notifier.posts, [])
    }

    func testEarlyLiftSwitchOffAndDeleteClearThePlan() async throws {
        let env = try TestAppEnvironment()
        let end = env.clock.now.addingTimeInterval(3600)
        let http = SwitchableBanRecordHTTP(banJSON(expires: end))
        let notifier = FakeNotifier(status: .authorized)
        let (model, id) = try await makeModel(env, notifier: notifier, http: http)
        await model.refreshBanRecord(for: id)?.value
        XCTAssertFalse(model.banExpiryWatches.isEmpty)
        // Lifted early: the next lookup finds nothing.
        http.set(#"{"bans":[]}"#)
        await model.refreshBanRecord(for: id)?.value
        XCTAssertEqual(model.banExpiryWatches, [])
        XCTAssertEqual(savedWatches(env), [])
        env.clock.advance(3600)
        XCTAssertNil(model.checkBanExpiryNotifications())
        XCTAssertEqual(notifier.posts, [])

        // The card switch: off removes, on plans again from the last lookup.
        http.set(banJSON(expires: env.clock.now.addingTimeInterval(7200)))
        await model.refreshBanRecord(for: id)?.value
        XCTAssertEqual(model.banExpiryWatches.count, 2)
        model.setBanExpiryNotify(false, for: id)
        XCTAssertFalse(model.isBanExpiryNotifyOn(for: id))
        XCTAssertEqual(model.banExpiryWatches, [])
        await model.refreshBanRecord(for: id)?.value
        XCTAssertEqual(model.banExpiryWatches, [], "stays off for the next lookups")
        model.setBanExpiryNotify(true, for: id)
        XCTAssertEqual(model.banExpiryWatches.count, 2)
        // "10 minutes before" off: only the end remains.
        model.banExpirySoonEnabled = false
        XCTAssertEqual(model.banExpiryWatches.map(\.kind), [.ended])
        model.banExpirySoonEnabled = true
        XCTAssertEqual(Set(model.banExpiryWatches.map(\.kind)), [.soon, .ended])
        // Permanent ban: nothing to notify.
        http.set(banJSON(expires: nil, permanent: true))
        await model.refreshBanRecord(for: id)?.value
        XCTAssertEqual(model.banExpiryWatches, [])
        // Deleting the server forgets its plan.
        http.set(banJSON(expires: env.clock.now.addingTimeInterval(7200)))
        await model.refreshBanRecord(for: id)?.value
        model.deleteServer(id: id)
        XCTAssertEqual(model.banExpiryWatches, [])
    }

    func testFailedLookupKeepsThePlan() async throws {
        let env = try TestAppEnvironment()
        let end = env.clock.now.addingTimeInterval(3600)
        let http = SwitchableBanRecordHTTP(banJSON(expires: end))
        let (model, id) = try await makeModel(env, notifier: FakeNotifier(status: .authorized), http: http)
        await model.refreshBanRecord(for: id)?.value
        let planned = model.banExpiryWatches
        XCTAssertFalse(planned.isEmpty)
        // A broken reply is not "no ban": the plan stays.
        http.set("not json")
        await model.refreshBanRecord(for: id)?.value
        XCTAssertEqual(model.banExpiryWatches, planned)
    }
}

// MARK: - §69.2 Widget

final class WidgetSnapshotTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_795_000_000)

    private func sample() -> WidgetSnapshot {
        WidgetSnapshot(updatedAt: date, status: .red, cidShort: "9f3a1c7e…d7b8",
                       servers: [WidgetSnapshot.Server(label: "A", host: "a.example.com", port: 27015, ban: "cidBanned", ping: 42),
                                 WidgetSnapshot.Server(label: "B", host: "198.51.100.2", port: 27016, ban: nil, ping: nil)])
    }

    func testEncodeDecodeRoundTripAndSchema() throws {
        let data = try WidgetSnapshotStore.encode(sample())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for field in ["\"schemaVersion\" : 1", "\"updatedAt\"", "\"status\" : \"red\"", "\"cidShort\"", "\"servers\"",
                      "\"label\"", "\"host\"", "\"port\"", "\"ban\"", "\"ping\""] {
            XCTAssertTrue(json.contains(field), field)
        }
        XCTAssertEqual(WidgetSnapshotStore.decode(data), sample())
        // Another schema version or broken JSON: no data.
        XCTAssertNil(WidgetSnapshotStore.decode(Data(json.replacingOccurrences(of: "\"schemaVersion\" : 1",
                                                                               with: "\"schemaVersion\" : 2").utf8)))
        XCTAssertNil(WidgetSnapshotStore.decode(Data("{\"schemaVersion\":1".utf8)))
        XCTAssertNil(WidgetSnapshotStore.decode(Data([UInt8]([0xFF, 0xFE, 0x00]))))
        // An unknown status reads as unknown; more than three servers are cut.
        let newer = json.replacingOccurrences(of: "\"status\" : \"red\"", with: "\"status\" : \"purple\"")
        XCTAssertEqual(WidgetSnapshotStore.decode(Data(newer.utf8))?.status, .unknown)
        let many = WidgetSnapshot(updatedAt: date, status: .green, cidShort: nil,
                                  servers: (0..<5).map { WidgetSnapshot.Server(label: "S\($0)", host: "h", port: 1, ban: nil, ping: nil) })
        XCTAssertEqual(many.servers.count, 3)
    }

    func testLoadMissingCorruptAndValidFiles() throws {
        let temp = try TempDirectory()
        let url = WidgetSnapshotStore.fileURL(home: temp.url)
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/tr.ercanatay.playeridentity/widget-snapshot.json"))
        XCTAssertEqual(AppPaths(home: temp.url).widgetSnapshotFile, url)
        XCTAssertEqual(WidgetSnapshotStore.load(from: url), .missing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(WidgetSnapshotStore.load(from: url), .corrupt)
        try Data().write(to: url)
        XCTAssertEqual(WidgetSnapshotStore.load(from: url), .corrupt)
        try WidgetSnapshotStore.save(sample(), to: url)
        XCTAssertEqual(WidgetSnapshotStore.load(from: url), .loaded(sample()))
    }

    func testTimelineEmptyAndFull() {
        let empty = WidgetTimeline.plan(.missing, now: date)
        XCTAssertNil(empty.snapshot)
        XCTAssertEqual(empty.date, date)
        XCTAssertEqual(empty.reloadAt, date.addingTimeInterval(15 * 60))
        XCTAssertNil(WidgetTimeline.plan(.corrupt, now: date).snapshot)
        let full = WidgetTimeline.plan(.loaded(sample()), now: date)
        XCTAssertEqual(full.snapshot, sample())
        XCTAssertEqual(full.reloadAt.timeIntervalSince(full.date), 900)
    }

    func testShortCID() {
        XCTAssertEqual(WidgetSnapshot.shortCID("9f3a1c7e5b2d4a6f8c0e1d3b5a7c9e1fd7b8"), "9f3a1c7e…d7b8")
        XCTAssertEqual(WidgetSnapshot.shortCID(" 0123456789ab "), "0123456789ab")
        XCTAssertEqual(WidgetSnapshot.shortCID("0123456789abc"), "01234567…9abc")
        XCTAssertEqual(WidgetSnapshot.shortCID(""), "")
    }

    func testBanMappingFollowsBanStatus() {
        for status in BanStatus.allCases {
            let server = WidgetSnapshot.Server(label: "x", host: "h", port: 1, ban: status.rawValue, ping: nil)
            XCTAssertEqual(L10n.text(server.banTextKey), status.label, status.rawValue)
            let expected: WidgetStatus = status.level == .red ? .red : status.level == .green ? .green : .orange
            XCTAssertEqual(server.banLevel, expected, status.rawValue)
        }
        let unchecked = WidgetSnapshot.Server(label: "x", host: "h", port: 1, ban: nil, ping: nil)
        XCTAssertEqual(unchecked.banLevel, .unknown)
        for level in StatusLevel.allCases {
            let status = WidgetStatus(rawValue: String(describing: level))
            XCTAssertEqual(status.map { L10n.text($0.textKey) }, level.label)
            XCTAssertEqual(status?.symbolName, level.symbolName)
        }
    }

    func testDeepLink() {
        XCTAssertEqual(WidgetTimeline.deepLink.absoluteString, "playeridentity://show")
        XCTAssertTrue(ServerLink.isShowLink(WidgetTimeline.deepLink))
        XCTAssertTrue(ServerLink.isShowLink(URL(string: "playeridentity:show")!))
        XCTAssertTrue(ServerLink.isShowLink(URL(string: "PLAYERIDENTITY://SHOW/")!))
        XCTAssertFalse(ServerLink.isShowLink(URL(string: "playeridentity://add?host=1.2.3.4")!))
        XCTAssertFalse(ServerLink.isShowLink(URL(string: "https://show")!))
    }

    @MainActor
    func testModelOpensShowLinksWithoutAnAlert() throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        XCTAssertNil(model.handleOpenURL(WidgetTimeline.deepLink))
        XCTAssertNil(model.serverLinkOutcome)
        XCTAssertEqual(model.handleOpenURL(URL(string: "playeridentity://add?host=192.0.2.1")!)?.added, 1)
    }

    @MainActor
    func testRefreshWritesTheSnapshotWithoutThePlayerIP() async throws {
        let env = try TestAppEnvironment()
        let reloader = RecordingWidgetReloader()
        let model = env.makeModel { $0.widgetReloader = reloader }
        for index in 1...4 { model.addServer(ServerDraft(label: "Server \(index)", host: "198.51.100.\(index)")) }
        await model.refresh().value
        let url = AppPaths(home: env.home).widgetSnapshotFile
        let snapshot = try XCTUnwrap(WidgetSnapshotStore.load(from: url).snapshot)
        XCTAssertEqual(snapshot.servers.map(\.label), ["Server 1", "Server 2", "Server 3"])
        XCTAssertEqual(snapshot.updatedAt, model.lastChecked)
        XCTAssertNotEqual(snapshot.status, .unknown)
        let cid = try XCTUnwrap(model.rowStatus(try XCTUnwrap(model.servers.first?.id))?.currentCID)
        XCTAssertEqual(snapshot.cidShort, WidgetSnapshot.shortCID(cid))
        XCTAssertNotEqual(snapshot.cidShort, cid)
        XCTAssertEqual(snapshot.servers.first?.ban, model.servers.first?.banCheck?.status.rawValue)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("203.0.113.7"), "no public IP")
        XCTAssertFalse(raw.contains("192.0.2.10"), "no LAN IP")
        XCTAssertFalse(raw.contains(cid), "no full CID")
        XCTAssertEqual(reloader.reloads, 1)
    }

    func testBuilderWithoutAReport() {
        let snapshot = WidgetSnapshotBuilder.make(report: nil, servers: [ServerEntry(label: "A", host: "a.example.com")],
                                                  updatedAt: date)
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertNil(snapshot.cidShort)
        XCTAssertEqual(snapshot.servers, [WidgetSnapshot.Server(label: "A", host: "a.example.com", port: 27015, ban: nil, ping: nil)])
    }
}

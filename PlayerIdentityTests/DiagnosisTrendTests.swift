import XCTest
@testable import PlayerIdentity

/// §65 diagnosis trend and menu bar diagnosis: window filters and their time limits, counts and strip order, the
/// empty state, the menu model (items/order, "running", result line), the single notification (ban verdicts only,
/// quiet hours and server overrides) and "no network" — fake carriers only.
final class DiagnosisTrendTests: XCTestCase {
    private let server = "198.51.100.20"
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    override func tearDown() {
        L10n.setting = .system
        super.tearDown()
    }

    private func run(_ id: UUID, _ verdict: String?, at ts: Date, kind: HistoryKind = .diagnose) -> HistoryEntry {
        HistoryEntry(ts: ts, kind: kind, serverID: id, host: "\(server):27015", new: verdict, note: "dns=ok")
    }

    // MARK: (a) windows and time limits

    func testWindowsAndTheirLimits() {
        XCTAssertEqual(DiagnosisTrendWindow.default, .week)
        XCTAssertEqual(DiagnosisTrendWindow.allCases, [.week, .month, .all])
        XCTAssertEqual(DiagnosisTrendWindow.week.duration, 7 * day)
        XCTAssertEqual(DiagnosisTrendWindow.month.duration, 30 * day)
        XCTAssertNil(DiagnosisTrendWindow.all.duration)
        // The start is inclusive: exactly 7 × 24 h ago counts, one second earlier does not.
        XCTAssertTrue(DiagnosisTrendWindow.week.includes(t0.addingTimeInterval(-7 * day), now: t0))
        XCTAssertFalse(DiagnosisTrendWindow.week.includes(t0.addingTimeInterval(-7 * day - 1), now: t0))
        XCTAssertTrue(DiagnosisTrendWindow.month.includes(t0.addingTimeInterval(-30 * day), now: t0))
        XCTAssertFalse(DiagnosisTrendWindow.month.includes(t0.addingTimeInterval(-30 * day - 1), now: t0))
        XCTAssertTrue(DiagnosisTrendWindow.all.includes(t0.addingTimeInterval(-89 * day), now: t0))
        // A line from the future (clock moved back) is not lost.
        XCTAssertTrue(DiagnosisTrendWindow.week.includes(t0.addingTimeInterval(3600), now: t0))

        let id = UUID()
        let entries = [
            run(id, "noBan", at: t0.addingTimeInterval(-40 * day)),
            run(id, "timeout", at: t0.addingTimeInterval(-30 * day - 1)),
            run(id, "ipBanned", at: t0.addingTimeInterval(-30 * day)),
            run(id, "cidBanned", at: t0.addingTimeInterval(-7 * day - 1)),
            run(id, "noBan", at: t0.addingTimeInterval(-7 * day)),
            run(id, "noBan", at: t0.addingTimeInterval(-60)),
        ]
        let week = DiagnosisTrend.make(entries: entries, serverID: id, window: .week, now: t0)
        let month = DiagnosisTrend.make(entries: entries, serverID: id, window: .month, now: t0)
        let all = DiagnosisTrend.make(entries: entries, serverID: id, window: .all, now: t0)
        XCTAssertEqual([week.runs, month.runs, all.runs], [2, 4, 6])
        XCTAssertEqual([week.totalRuns, month.totalRuns, all.totalRuns], [6, 6, 6])
        XCTAssertEqual(week.lastRun, t0.addingTimeInterval(-60))
        XCTAssertEqual(month.strip, [.ipBanned, .cidBanned, .noBan, .noBan])
    }

    // MARK: (b) counts and strip order

    func testCountsSkipZeroAndStripKeepsTheLastTenOldestFirst() {
        let id = UUID(), other = UUID()
        let verdicts: [DiagnosisVerdict] = [.noBan, .cidBanned, .timeout, .cidBanned, .noBan, .ipBanned,
                                            .cidBanned, .noBan, .rangeBanned, .noBan, .dnsFailure, .cidBanned]
        var entries = verdicts.enumerated().map { index, verdict in
            run(id, verdict.rawValue, at: t0.addingTimeInterval(TimeInterval(-3600 * (verdicts.count - index))))
        }
        // Noise: another server, another kind, an unknown or missing verdict.
        entries.append(run(other, "ipBanned", at: t0.addingTimeInterval(-10)))
        entries.append(run(id, "ipBanned", at: t0.addingTimeInterval(-10), kind: .banAppeared))
        entries.append(run(id, "bogusVerdict", at: t0.addingTimeInterval(-10)))
        entries.append(run(id, nil, at: t0.addingTimeInterval(-10)))
        entries.shuffle()

        let trend = DiagnosisTrend.make(entries: entries, serverID: id, window: .week, now: t0)
        XCTAssertEqual(trend.runs, 12)
        XCTAssertEqual(trend.lastRun, t0.addingTimeInterval(-3600))
        XCTAssertEqual(trend.counts.map(\.verdict), [.cidBanned, .noBan, .dnsFailure, .timeout, .ipBanned, .rangeBanned])
        XCTAssertEqual(trend.counts.map(\.count), [4, 4, 1, 1, 1, 1])
        XCTAssertFalse(trend.counts.contains { $0.count == 0 })
        XCTAssertEqual(trend.counts.map(\.count).reduce(0, +), trend.runs)
        XCTAssertEqual(trend.strip.count, DiagnosisTrend.stripLength)
        XCTAssertEqual(trend.strip, Array(verdicts.suffix(10)))      // oldest → newest (newest on the right)
        // Colours: green = no ban, red = ban, orange = unclear / error.
        XCTAssertEqual(trend.strip.map(\.level), [.orange, .red, .green, .red, .red, .green, .red, .green, .orange, .red])

        // Same time: the file order decides.
        let tie = [run(id, "noBan", at: t0), run(id, "cidBanned", at: t0)]
        XCTAssertEqual(DiagnosisTrend.make(entries: tie, serverID: id, window: .all, now: t0).strip, [.noBan, .cidBanned])

        try? L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(DiagnosisVerdict.cidBanned.shortLabel, "CID ban")
            XCTAssertEqual(L10n.format(.diagnoseTrendCount, DiagnosisVerdict.noBan.shortLabel, "4"), "No ban ×4")
            XCTAssertTrue(trend.stripAccessibilityValue.hasPrefix("Timeout, CID ban, No ban"))
        }
        XCTAssertEqual(Set(DiagnosisVerdict.allCases.map(\.shortLabel)).count, DiagnosisVerdict.allCases.count)
    }

    // MARK: (c) empty state

    func testEmptyStateTellsNoneYetFromNoneInThisPeriod() throws {
        let id = UUID()
        let none = DiagnosisTrend.make(entries: [], serverID: id, window: .week, now: t0)
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(none.lastRun)
        XCTAssertEqual(none.counts, [])
        XCTAssertEqual(none.strip, [])
        let old = DiagnosisTrend.make(entries: [run(id, "noBan", at: t0.addingTimeInterval(-20 * day))], serverID: id,
                                      window: .week, now: t0)
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(old.totalRuns, 1)
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(none.emptyText, "Bu sunucu için henüz teşhis yok")
            XCTAssertEqual(old.emptyText, "Bu aralıkta teşhis yok")
            XCTAssertEqual(L10n.text(.diagnoseTrendStart), "Teşhisi başlat")
        }
    }

    @MainActor
    func testModelTrendFollowsTheHistoryAndChangesNothing() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: server))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        let empty = await model.diagnosisTrend(for: id, window: .week)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.totalRuns, 0)
        let before = model.servers
        await model.startDiagnosis(for: id)?.value
        await model.waitForHistory()
        let trend = await model.diagnosisTrend(for: id, window: .week)
        XCTAssertEqual(trend.runs, 1)
        XCTAssertEqual(trend.strip, [.noBan])
        XCTAssertEqual(trend.lastRun, model.diagnosis(for: id)?.result?.startedAt)
        XCTAssertEqual(model.diagnosis(for: id)?.result?.verdict, .noBan, "the trend does not change the result")
        XCTAssertEqual(model.servers, before)
        // A week later the run leaves the 7-day window but stays in 30 days / all.
        env.clock.advance(8 * day)
        let week = await model.diagnosisTrend(for: id, window: .week)
        let month = await model.diagnosisTrend(for: id, window: .month)
        XCTAssertEqual([week.runs, month.runs], [0, 1])
    }

    // MARK: (d) menu model

    func testServerSubmenuItemsOrderRunningAndResultLine() throws {
        let id = UUID()
        L10n.setting = .tr
        let idle = MenuBarServerChoice(id: id, label: "Zombie TR", cid: "c", canRecheck: true)
        XCTAssertEqual(idle.title, "Zombie TR")
        XCTAssertEqual(idle.items, [.copyCID(enabled: true), .recheck(enabled: true), .diagnose(enabled: true)])

        let running = MenuBarServerChoice(id: id, label: "Zombie TR", cid: nil, canRecheck: false, diagnosis: .running)
        XCTAssertEqual(running.title, "Zombie TR · teşhis sürüyor…")
        XCTAssertEqual(running.items, [.copyCID(enabled: false), .recheck(enabled: false), .diagnose(enabled: false),
                                       .diagnosisLine("teşhis sürüyor…")])

        let done = MenuBarServerChoice(id: id, label: "Zombie TR", cid: "c", canRecheck: true,
                                       diagnosis: .finished(.cidBanned, durationMs: 1200))
        XCTAssertEqual(done.title, "Zombie TR")
        XCTAssertEqual(done.items.last, .diagnosisLine("CID ban · 1,2 sn"))
        XCTAssertEqual(done.items[2], .diagnose(enabled: true))
        let blocked = MenuBarServerChoice(id: id, label: "x", cid: "c", canRecheck: true, canDiagnose: false)
        XCTAssertEqual(blocked.items[2], .diagnose(enabled: false))

        L10n.setting = .en
        XCTAssertEqual(MenuBarDiagnosisText.line(.finished(.cidBanned, durationMs: 1200), language: .en), "CID ban · 1.2 s")
        XCTAssertEqual(MenuBarDiagnosisText.line(.running), "diagnosing…")
        XCTAssertEqual(MenuBarDiagnosisText.seconds(1249, language: .tr), "1,2")
        XCTAssertEqual(MenuBarDiagnosisText.seconds(20_000, language: .en), "20.0")
        XCTAssertEqual(MenuBarDiagnosisText.seconds(-5, language: .en), "0.0")

        // The quick menu passes the choices through unchanged; nothing while the menu bar mode is off.
        let items = MenuBarQuickMenu.items(enabled: true, statusTitle: "x", lastChecked: nil, servers: [done], selected: nil,
                                           rawID: "r", feedback: nil, now: t0)
        XCTAssertEqual(items.last, .servers([done]))
        XCTAssertEqual(MenuBarQuickMenu.items(enabled: false, statusTitle: "x", lastChecked: nil, servers: [done],
                                              selected: nil, rawID: "r", feedback: nil, now: t0), [])
    }

    @MainActor
    func testMenuBarDiagnosisRunsWritesHistoryAndNotifiesOnceForABan() async throws {
        L10n.setting = .tr
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let udp = FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: FakeServer.oob(0x49, [0x30]), delay: 0.4),
            challenge: FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes), delay: 0.4),
            connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned from this server (CID)"), delay: 0.4)))
        let model = env.makeModel(udp: udp, notifier: notifier)
        model.addServer(ServerDraft(label: "Zombie TR", host: server))
        await model.refresh().value
        await model.waitForHistory()
        let id = try XCTUnwrap(model.servers.first?.id)
        let postsBefore = notifier.posts.count
        XCTAssertEqual(postsBefore, 0, "a first observation is not notified")
        XCTAssertEqual(model.menuBarQuickItems, [], "menu bar mode off: no items")
        model.menuBarEnabled = true
        guard case .servers(let idle)? = model.menuBarQuickItems.last else { return XCTFail("no server submenu") }
        XCTAssertEqual(idle[0].items.map(MenuBarText.serverItemTitle).map(\.title),
                       ["CID'yi kopyala", "Yeniden kontrol et", "Teşhis et"])
        let before = model.servers
        let sentBefore = udp.sentCount

        let task = model.startMenuBarDiagnosis(for: id)
        XCTAssertEqual(model.menuBarDiagnoses[id], .running)
        XCTAssertFalse(model.canDiagnoseFromMenuBar(id))
        XCTAssertNil(model.startMenuBarDiagnosis(for: id), "no second run while one is running")
        guard case .servers(let busy)? = model.menuBarQuickItems.last else { return XCTFail("no server submenu") }
        XCTAssertEqual(busy[0].title, "Zombie TR · teşhis sürüyor…")
        XCTAssertEqual(busy[0].items.last, .diagnosisLine("teşhis sürüyor…"))
        await task?.value
        await model.waitForHistory()

        XCTAssertEqual(model.menuBarDiagnoses[id], .finished(.cidBanned, durationMs: 1200))
        guard case .servers(let done)? = model.menuBarQuickItems.last else { return XCTFail("no server submenu") }
        XCTAssertEqual(done[0].items.last, .diagnosisLine("CID ban · 1,2 sn"))
        XCTAssertEqual(model.servers, before, "the server entry is not changed")
        XCTAssertNil(model.diagnosis(for: id), "the details' diagnosis is untouched")
        let lines = env.historyStore.load().filter { $0.kind == .diagnose }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.new, "cidBanned")
        XCTAssertEqual(lines.first?.serverID, id)
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertEqual(notifier.posts.first?.title, "Teşhis: ban bulundu")
        XCTAssertEqual(notifier.posts.first?.category, .ban)
        XCTAssertTrue(notifier.posts.first?.body.contains("Zombie TR") == true)
        XCTAssertEqual(udp.sentCount - sentBefore, 3)

        // A second run notifies once more (one notification per run, not per step).
        env.clock.advance(60)
        await model.startMenuBarDiagnosis(for: id)?.value
        await model.waitForHistory()
        XCTAssertEqual(notifier.posts.count, 2)
        XCTAssertEqual(env.historyStore.load().filter { $0.kind == .diagnose }.count, 2)
        let trend = await model.diagnosisTrend(for: id, window: .week)
        XCTAssertEqual(trend.strip, [.cidBanned, .cidBanned])
    }

    // MARK: (e) notification only for bans, with quiet hours and server overrides

    func testNotificationOnlyForBanVerdicts() {
        let entry = ServerEntry(label: "A", host: server, port: 27015)
        for verdict in DiagnosisVerdict.allCases {
            let content = MenuBarDiagnosisText.notification(verdict: verdict, server: entry, at: t0)
            XCTAssertEqual(content != nil, [.ipBanned, .cidBanned, .rangeBanned].contains(verdict), verdict.rawValue)
            XCTAssertEqual(content?.category ?? .ban, .ban)
        }
        var withOverride = entry
        withOverride.notifications = ServerNotificationSettings(mode: .bansOnly, pingThresholdMs: 50)
        XCTAssertEqual(MenuBarDiagnosisText.notification(verdict: .ipBanned, server: withOverride, at: t0)?.server,
                       withOverride.notifications)
        let a = MenuBarDiagnosisText.notification(verdict: .ipBanned, server: entry, at: t0)?.key
        let b = MenuBarDiagnosisText.notification(verdict: .ipBanned, server: entry, at: t0.addingTimeInterval(30))?.key
        XCTAssertNotEqual(a, b)
    }

    func testQuietHoursSwitchesAndServerOverridesGateTheNotification() async {
        let clock = TestClock()
        let hour = Calendar.current.component(.hour, from: clock.now)
        let quiet = QuietHours(enabled: true, start: QuietHours.text(minutes: hour * 60),
                               end: QuietHours.text(minutes: ((hour + 1) % 24) * 60))
        var entry = ServerEntry(label: "A", host: server, port: 27015)
        func posts(_ policy: NotificationPolicy, enabled: Bool = true, settings: ServerNotificationSettings? = nil) async -> Int {
            entry.notifications = settings
            let notifier = FakeNotifier(status: .authorized)
            let dispatcher = NotificationDispatcher(notifier: notifier, now: { clock.now })
            let content = MenuBarDiagnosisText.notification(verdict: .rangeBanned, server: entry, at: clock.now)
            await dispatcher.handle(content.map { [$0] } ?? [], enabled: enabled, policy: policy)
            return notifier.posts.count
        }
        let base = NotificationPolicy()
        var quietPolicy = base
        quietPolicy.quiet = quiet
        var noBanSwitch = base
        noBanSwitch.banChanges = false
        var mutedQuiet = quiet
        mutedQuiet.enabled = false
        var quietOff = base
        quietOff.quiet = mutedQuiet

        let general = await posts(base)
        let masterOff = await posts(base, enabled: false)
        let inQuiet = await posts(quietPolicy)
        let banSwitchOff = await posts(noBanSwitch)
        let serverOff = await posts(base, settings: ServerNotificationSettings(mode: .off))
        let serverBansOnly = await posts(noBanSwitch, settings: ServerNotificationSettings(mode: .bansOnly))
        let serverIgnoresQuiet = await posts(quietPolicy, settings: ServerNotificationSettings(quietHoursOverride: .off))
        let serverForcesQuiet = await posts(quietOff, settings: ServerNotificationSettings(quietHoursOverride: .on))
        let thresholds = await posts(base, settings: ServerNotificationSettings(pingThresholdMs: 1, playersAtLeast: 200))
        XCTAssertEqual(general, 1)
        XCTAssertEqual(masterOff, 0)
        XCTAssertEqual(inQuiet, 0)
        XCTAssertEqual(banSwitchOff, 0)
        XCTAssertEqual(serverOff, 0)
        XCTAssertEqual(serverBansOnly, 1)
        XCTAssertEqual(serverIgnoresQuiet, 1)
        XCTAssertEqual(serverForcesQuiet, 0)
        XCTAssertEqual(thresholds, 1, "ping/player thresholds never hold back a ban")
    }

    @MainActor
    func testMenuBarDiagnosisWithoutBanOrInQuietHoursPostsNothingButWritesHistory() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(udp: FakeServer.healthy(clock: env.clock), notifier: notifier)
        model.addServer(ServerDraft(label: "A", host: server))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        model.menuBarEnabled = true
        await model.startMenuBarDiagnosis(for: id)?.value
        await model.waitForHistory()
        guard case .finished(.noBan, _)? = model.menuBarDiagnoses[id] else { return XCTFail("expected noBan") }
        XCTAssertEqual(notifier.posts.count, 0)
        XCTAssertEqual(notifier.requestCount, 0)

        // Ban, but inside quiet hours: history yes, notification no.
        let env2 = try TestAppEnvironment()
        let notifier2 = FakeNotifier(status: .authorized)
        let model2 = env2.makeModel(udp: FakeUDPTransport(clock: env2.clock, responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned"))) ), notifier: notifier2)
        model2.addServer(ServerDraft(label: "B", host: server))
        let id2 = try XCTUnwrap(model2.servers.first?.id)
        let hour = Calendar.current.component(.hour, from: env2.clock.now)
        model2.quietHoursEnabled = true
        model2.quietHoursStart = QuietHours.text(minutes: hour * 60)
        model2.quietHoursEnd = QuietHours.text(minutes: ((hour + 1) % 24) * 60)
        await model2.startMenuBarDiagnosis(for: id2)?.value
        await model2.waitForHistory()
        guard case .finished(let verdict, _)? = model2.menuBarDiagnoses[id2] else { return XCTFail("no result") }
        XCTAssertTrue(verdict.isBan)
        XCTAssertEqual(notifier2.posts.count, 0)
        XCTAssertEqual(env2.historyStore.load().filter { $0.kind == .diagnose }.map(\.new), [verdict.rawValue])
    }

    // MARK: (f) no network

    @MainActor
    func testNoNetworkMenuBarDiagnosisIsATimeoutWithoutNotification() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(notifier: notifier) { $0.udpTransport = OfflineTransport() }
        model.addServer(ServerDraft(label: "A", host: server))
        let id = try XCTUnwrap(model.servers.first?.id)
        model.menuBarEnabled = true
        await model.startMenuBarDiagnosis(for: id)?.value
        await model.waitForHistory()
        guard case .finished(.timeout, _)? = model.menuBarDiagnoses[id] else {
            return XCTFail("expected timeout, got \(String(describing: model.menuBarDiagnoses[id]))")
        }
        XCTAssertEqual(notifier.posts.count, 0)
        XCTAssertEqual(env.historyStore.load().filter { $0.kind == .diagnose }.map(\.new), ["timeout"])
    }

    @MainActor
    func testCancelledOrMissingServerLeavesNoLine() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel(udp: FakeUDPTransport(waitsOnSilence: true,
                                                        responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil)))
        XCTAssertNil(model.startMenuBarDiagnosis(for: UUID()), "unknown server")
        model.addServer(ServerDraft(label: "A", host: server))
        let id = try XCTUnwrap(model.servers.first?.id)
        let task = model.startMenuBarDiagnosis(for: id)
        try await Task.sleep(for: .milliseconds(100))
        task?.cancel()
        await task?.value
        await model.waitForHistory()
        XCTAssertNil(model.menuBarDiagnoses[id])
        XCTAssertTrue(model.canDiagnoseFromMenuBar(id))
        XCTAssertFalse(env.historyStore.load().contains { $0.kind == .diagnose })
    }
}

/// No network: every socket fails to open (like `ENETUNREACH`).
private struct OfflineTransport: UDPTransport {
    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession {
        throw UDPSocketError.system(51)
    }
}

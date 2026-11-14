import XCTest
@testable import PlayerIdentity

/// §66 the diagnosis follow-up: (a) the ban matrix "Last 7 days" column (filled/empty, narrow window, CSV),
/// (b) the `rangeBanned` card text, notification and action, (c) the report history table, masking and period,
/// (d) the intents' parameters and result texts, (e) key parity, (f) no network — fake carriers only.
final class DiagnosisFollowUpTests: XCTestCase {
    private let server = "198.51.100.20"
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private let utc = TimeZone(identifier: "UTC")!

    override func tearDown() {
        L10n.setting = .system
        super.tearDown()
    }

    private func en<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en")), operation: body)
    }

    private func tr<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr")), operation: body)
    }

    private func run(_ id: UUID, _ verdict: DiagnosisVerdict, at ts: Date, ms: Int? = nil) -> HistoryEntry {
        HistoryEntry(ts: ts, kind: .diagnose, serverID: id, host: "\(server):27015", new: verdict.rawValue,
                     note: "dns=ok", durationMs: ms)
    }

    // MARK: (a) ban matrix column

    func testRecentSummaryCountsTheLastSevenDaysAndPicksTheDominantVerdict() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [
            run(a, .cidBanned, at: t0.addingTimeInterval(-8 * day)),         // outside the window
            run(a, .cidBanned, at: t0.addingTimeInterval(-6 * day)),
            run(a, .noBan, at: t0.addingTimeInterval(-5 * day)),
            run(a, .cidBanned, at: t0.addingTimeInterval(-60)),
            run(b, .noBan, at: t0.addingTimeInterval(-30 * day)),            // only old runs
            HistoryEntry(ts: t0, kind: .refresh, serverID: a),
        ]
        let recent = BanMatrixRecent.make(entries: entries, serverIDs: [a, b, c], now: t0)
        XCTAssertEqual(recent[a], BanMatrixRecent(runs: 3, dominant: .cidBanned, banRuns: 2))
        XCTAssertEqual(recent[b], .empty)
        XCTAssertEqual(recent[c], .empty)
        try en {
            XCTAssertEqual(recent[a]?.text, "3 · CID ban")
            XCTAssertEqual(recent[b]?.text, "—")
            XCTAssertEqual(BanMatrixText.recent(nil), "—")
        }
        try tr { XCTAssertEqual(recent[a]?.text, "3 · CID ban") }
        // Tie: allCases order decides (ipBanned before noBan).
        let tie = BanMatrixRecent.make(entries: [run(a, .noBan, at: t0), run(a, .ipBanned, at: t0)], serverIDs: [a], now: t0)
        XCTAssertEqual(tie[a]?.dominant, .ipBanned)
    }

    func testRecentColumnSortsWithinARankAndGoesIntoTheCSV() throws {
        let checked = BanCheck(status: .cidOk, checkedAt: t0, detail: "")
        let quiet = ServerEntry(label: "Quiet", host: "192.0.2.1", banCheck: checked)
        let noisy = ServerEntry(label: "Noisy", host: "192.0.2.2", banCheck: checked)
        let banned = ServerEntry(label: "Banned", host: "192.0.2.3", banCheck: BanCheck(status: .ipBanned, checkedAt: t0, detail: ""))
        let recent: [UUID: BanMatrixRecent] = [noisy.id: BanMatrixRecent(runs: 4, dominant: .cidBanned, banRuns: 3),
                                               quiet.id: .empty]
        let rows = BanMatrix.rows(servers: [quiet, noisy, banned], recent: recent)
        XCTAssertEqual(rows.map(\.label), ["Banned", "Noisy", "Quiet"], "rank first, then ban runs of the last 7 days")
        XCTAssertEqual(BanMatrix.rows(servers: [quiet, noisy]).map(\.label), ["Quiet", "Noisy"], "no trend: order kept")

        try en {
            let table = BanMatrixText.tableWithRecent(rows, timeZone: utc)
            XCTAssertEqual(table[0], ["Server", "Address", "IP ban", "CID ban", "Range", "Last check", "Last 7 days"])
            XCTAssertEqual(table[2].last, "4 · CID ban")
            XCTAssertEqual(table[3].last, "—")
            XCTAssertEqual(table[1].last, "—", "no summary computed")
            XCTAssertTrue(CSV.encode(table).contains("Last 7 days"))
            XCTAssertTrue(CSV.tabSeparated(table).contains("4 · CID ban"))
            // The original six-column table stays as it was.
            XCTAssertEqual(BanMatrixText.table(rows)[0].count, 6)
        }
    }

    func testRecentColumnIsHiddenInNarrowWindowsAndShownInWideOnes() throws {
        let all = BanMatrixColumn.withRecent
        XCTAssertEqual(all.last, .recent)
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: BanMatrixLayout.requiredWidth(all), recent: true), all)
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: 1200, recent: true), all)
        // The default 860 pt window (828 pt table): no room, the base five stay.
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: 828, recent: true), BanMatrixColumn.allCases)
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: 488, recent: true), [.server, .ipBan, .cidBan])
        XCTAssertFalse(BanMatrixLayout.columns(tableWidth: 1200).contains(.recent), "base callers never get it")

        var row = BanMatrix.row(for: ServerEntry(label: "Zombie TR", host: server), range: nil)
        row.recent = BanMatrixRecent(runs: 3, dominant: .cidBanned, banRuns: 3)
        try en {
            let narrow = BanMatrixLayout.tooltip(row, columns: BanMatrixColumn.allCases)
            XCTAssertTrue(narrow.hasSuffix("Last 7 days: 3 · CID ban"), narrow)
            XCTAssertFalse(BanMatrixLayout.tooltip(row, columns: all).contains("Last 7 days"))
            XCTAssertEqual(BanMatrixColumn.recent.title, "Last 7 days")
        }
        try tr { XCTAssertEqual(BanMatrixColumn.recent.title, "Son 7 gün") }
    }

    @MainActor
    func testModelMatrixRowsCarryTheTrend() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: server))
        model.addServer(ServerDraft(label: "B", host: "198.51.100.21"))
        let a = try XCTUnwrap(model.servers.first?.id)
        let now = env.clock.now
        try env.historyStore.append([run(a, .cidBanned, at: now.addingTimeInterval(-3600)),
                                     run(a, .cidBanned, at: now.addingTimeInterval(-60)),
                                     run(a, .noBan, at: now.addingTimeInterval(-8 * day))])
        let rows = await model.banMatrixRows()
        XCTAssertEqual(rows.first { $0.serverID == a }?.recent, BanMatrixRecent(runs: 2, dominant: .cidBanned, banRuns: 2))
        XCTAssertEqual(rows.first { $0.serverID != a }?.recent, .empty)
    }

    // MARK: (b) range ban

    private func diagnosis(_ verdict: DiagnosisVerdict, range: String? = nil, cid: String? = nil,
                           steps: [DiagnosisStep] = []) -> ConnectionDiagnosis {
        var facts = DiagnosisFacts()
        facts.knownRange = range
        let probe = ConnectionProbeResult(steps: steps, facts: facts, verdict: verdict, address: server, cid: cid)
        return ConnectionDiagnosis(serverID: UUID(), label: "Zombie TR", host: server, port: 27015, startedAt: t0,
                                   probe: probe, engineLog: EngineLogReport(status: .missing),
                                   publicIP: "203.0.113.7", durationMs: 1234)
    }

    func testRangeBanNoteExplainsAndHintsOnlyForRangeBans() throws {
        try en {
            let note = try XCTUnwrap(RangeBanNote(diagnosis(.rangeBanned, range: "198.51.0.0/16")))
            XCTAssertTrue(note.explanation.contains("/24 or /16"))
            XCTAssertTrue(note.explanation.contains("renewing your IP"))
            XCTAssertEqual(note.range, "Blocked range: 198.51.0.0/16")
            XCTAssertEqual(note.hintTitle, "Change network")
            XCTAssertTrue(note.hint.contains("mobile hotspot"))
            XCTAssertTrue(note.hint.contains("VPN"))
            XCTAssertEqual(note.lines.count, 4)
            XCTAssertNil(RangeBanNote(diagnosis(.rangeBanned))?.range)
        }
        try tr { XCTAssertEqual(RangeBanNote(diagnosis(.rangeBanned))?.hintTitle, "Ağı değiştir") }
        for verdict in DiagnosisVerdict.allCases where verdict != .rangeBanned {
            XCTAssertNil(RangeBanNote(diagnosis(verdict)), verdict.rawValue)
        }
    }

    func testRangeBanNotificationHasItsTextAndTheCopyAction() throws {
        let entry = ServerEntry(label: "A", host: server, port: 27015)
        try en {
            let range = try XCTUnwrap(MenuBarDiagnosisText.notification(verdict: .rangeBanned, server: entry, at: t0,
                                                                        appeal: "Hello admin"))
            XCTAssertEqual(range.title, "Range ban detected — change your network")
            XCTAssertEqual(range.copyText, "Hello admin")
            XCTAssertEqual(range.serverID, entry.id)
            XCTAssertEqual(range.category, .ban)
            XCTAssertEqual(NotificationActions.categoryIdentifier(range), NotificationActions.copyCategory)
            XCTAssertEqual(NotificationActions.userInfo(range),
                           [NotificationActions.serverKey: entry.id.uuidString, NotificationActions.copyTextKey: "Hello admin"])
            // Without a message: no action; other bans: the §65 title and no action.
            let bare = try XCTUnwrap(MenuBarDiagnosisText.notification(verdict: .rangeBanned, server: entry, at: t0))
            XCTAssertNil(bare.copyText)
            XCTAssertNil(NotificationActions.categoryIdentifier(bare))
            let cid = try XCTUnwrap(MenuBarDiagnosisText.notification(verdict: .cidBanned, server: entry, at: t0, appeal: "x"))
            XCTAssertEqual(cid.title, "Diagnosis: ban found")
            XCTAssertNil(cid.copyText)
        }
        try tr {
            XCTAssertEqual(MenuBarDiagnosisText.notification(verdict: .rangeBanned, server: entry, at: t0)?.title,
                           "Aralık banı algılandı — ağı değiştirin")
        }
    }

    func testNotificationResponseRoutes() {
        let id = UUID()
        let info: [AnyHashable: Any] = [NotificationActions.serverKey: id.uuidString, NotificationActions.copyTextKey: "msg"]
        XCTAssertEqual(NotificationActions.route(actionIdentifier: NotificationActions.copyAction, userInfo: info), .copy("msg"))
        // A tap opens the details and copies nothing.
        XCTAssertEqual(NotificationActions.route(actionIdentifier: UNNotificationDefaultActionIdentifierForTests, userInfo: info),
                       .openServer(id))
        XCTAssertEqual(NotificationActions.route(actionIdentifier: "dismiss", userInfo: info), .none)
        XCTAssertEqual(NotificationActions.route(actionIdentifier: NotificationActions.copyAction, userInfo: [:]), .none)
        XCTAssertEqual(NotificationActions.route(actionIdentifier: UNNotificationDefaultActionIdentifierForTests, userInfo: [:]), .none)
    }

    @MainActor
    private func rangeBannedModel(notifier: FakeNotifier, pasteboard: RecordingPasteboard? = nil,
                                  env: TestAppEnvironment) throws -> (AppModel, UUID) {
        let model = env.makeModel(udp: FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oobText("9You are banned from this server")))), notifier: notifier) { deps in
            if let pasteboard { deps.pasteboard = pasteboard }
        }
        model.addServer(ServerDraft(label: "Zombie TR", host: server))
        let id = try XCTUnwrap(model.servers.first?.id)
        // A fix attempt found the range ban earlier (old and new IP share a /16).
        try env.historyStore.append([HistoryEntry(ts: env.clock.now.addingTimeInterval(-600), kind: .fixAttempt, serverID: id,
                                                  host: server, old: "198.51.100.7", new: "198.51.2.9", note: "rangeBanned")])
        return (model, id)
    }

    @MainActor
    func testMenuBarRangeBanPostsOneNotificationWithTheCopyAction() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let pasteboard = RecordingPasteboard()
        let (model, id) = try rangeBannedModel(notifier: notifier, pasteboard: pasteboard, env: env)
        model.menuBarEnabled = true
        await model.startMenuBarDiagnosis(for: id)?.value
        await model.waitForHistory()
        guard case .finished(.rangeBanned, _)? = model.menuBarDiagnoses[id] else {
            return XCTFail("expected rangeBanned, got \(String(describing: model.menuBarDiagnoses[id]))")
        }
        XCTAssertEqual(notifier.posts.count, 1, "one notification per run")
        let post = try XCTUnwrap(notifier.posts.first)
        XCTAssertEqual(post.title, L10n.text(.notifyRangeBanTitle))
        let appeal = try XCTUnwrap(post.copyText)
        XCTAssertFalse(appeal.isEmpty)
        XCTAssertEqual(post.serverID, id)

        // Tap: the details open, nothing is copied. Action: the message is copied.
        XCTAssertTrue(model.handleNotificationRoute(.openServer(id)))
        XCTAssertEqual(model.requestedServerDetail, id)
        XCTAssertEqual(pasteboard.written, [])
        XCTAssertTrue(model.handleNotificationRoute(.copy(appeal)))
        XCTAssertEqual(pasteboard.written, [appeal])
        XCTAssertFalse(model.handleNotificationRoute(.openServer(UUID())), "unknown server")
        XCTAssertFalse(model.handleNotificationRoute(.none))
        pasteboard.fails = true
        XCTAssertFalse(model.handleNotificationRoute(.copy(appeal)))
    }

    @MainActor
    func testRangeBanNotificationKeepsQuietHours() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let (model, id) = try rangeBannedModel(notifier: notifier, env: env)
        let hour = Calendar.current.component(.hour, from: env.clock.now)
        model.quietHoursEnabled = true
        model.quietHoursStart = QuietHours.text(minutes: hour * 60)
        model.quietHoursEnd = QuietHours.text(minutes: ((hour + 1) % 24) * 60)
        await model.startMenuBarDiagnosis(for: id)?.value
        await model.waitForHistory()
        XCTAssertEqual(notifier.posts.count, 0)
        XCTAssertEqual(env.historyStore.load().filter { $0.kind == .diagnose }.map(\.new), ["rangeBanned"])
    }

    // MARK: (c) report history

    func testReportHistoryTableIsNewestFirstLimitedAndNamesThePeriod() throws {
        let id = UUID()
        var entries = (0..<12).map { index in
            run(id, index.isMultiple(of: 2) ? .noBan : .cidBanned, at: t0.addingTimeInterval(TimeInterval(-3600 * (12 - index))),
                ms: 1000 + index)
        }
        entries.append(run(id, .timeout, at: t0.addingTimeInterval(-10 * day)))     // only in 30 days
        entries.append(run(UUID(), .ipBanned, at: t0))                               // other server
        let week = DiagnosisReportHistory.make(entries: entries, serverID: id, window: .week, now: t0)
        XCTAssertEqual(week.runs.count, 10)
        XCTAssertEqual(week.runs.first?.durationMs, 1011, "newest first")
        XCTAssertEqual(week.runs.last?.durationMs, 1002)
        let month = DiagnosisReportHistory.make(entries: entries, serverID: id, window: .month, now: t0)
        XCTAssertEqual(month.runs.count, 10)
        XCTAssertFalse(month.runs.contains { $0.verdict == .timeout }, "the oldest falls out of the last 10")

        let cid = "0123456789abcdef0123456789abcdef"
        let diagnosis = diagnosis(.cidBanned, cid: cid,
                                  steps: [DiagnosisStep(step: .connect49, status: .failed, durationMs: 40,
                                                        target: "\(server):27015", detail: "banned: \(cid) 203.0.113.7")])
        try en {
            let report = DiagnosisReport.markdown(diagnosis, appVersion: "9.9.9", timeZone: utc, history: week)
            XCTAssertTrue(report.contains("- Period: 7 days"))
            XCTAssertTrue(report.contains("## History (last 10 runs)"))
            XCTAssertTrue(report.contains("| Time | Verdict | Duration |"))
            XCTAssertTrue(report.contains("| 2026-10-26T06:33:20Z | `cidBanned` (CID ban) | 1011 ms |"), report)
            XCTAssertEqual(report.components(separatedBy: "| `").count - 1, 10 + 1, "10 history rows + 1 step row")
            // Masking is unchanged: no full CID, no full public IP anywhere.
            XCTAssertFalse(report.contains(cid))
            XCTAssertFalse(report.contains("203.0.113.7"))
            XCTAssertTrue(report.contains(DiagnosisReport.maskCID(cid)))
            // The history comes after the diagnosis (steps and engine log).
            let historyAt = try XCTUnwrap(report.range(of: "## History")).lowerBound
            XCTAssertLessThan(try XCTUnwrap(report.range(of: "## Steps")).lowerBound, historyAt)
            XCTAssertLessThan(try XCTUnwrap(report.range(of: "## Engine log")).lowerBound, historyAt)

            let all = DiagnosisReport.markdown(diagnosis, appVersion: "9.9.9", timeZone: utc,
                                               history: DiagnosisReportHistory(window: .all, runs: []))
            XCTAssertTrue(all.contains("- Period: All"))
            XCTAssertTrue(all.contains("No diagnosis in this period"))
            let old = DiagnosisReport.markdown(diagnosis, appVersion: "9.9.9", timeZone: utc,
                                               history: DiagnosisReportHistory(window: .month, runs: [
                                                DiagnosisRun(ts: t0, verdict: .noBan, durationMs: nil)]))
            XCTAssertTrue(old.contains("- Period: 30 days"))
            XCTAssertTrue(old.contains("| `noBan` (No ban) | — |"), "older lines have no duration")
            // Without history the report is the §64 one.
            XCTAssertFalse(DiagnosisReport.markdown(diagnosis, appVersion: "9.9.9").contains("## History"))
        }
        try tr {
            let report = DiagnosisReport.markdown(diagnosis, appVersion: "9.9.9", timeZone: utc, history: week)
            XCTAssertTrue(report.contains("- Aralık: 7 gün"))
            XCTAssertTrue(report.contains("## Geçmiş (son 10 çalışma)"))
        }
    }

    @MainActor
    func testModelReportUsesTheHistoryOfTheChosenPeriodAndDurations() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: server))
        let id = try XCTUnwrap(model.servers.first?.id)
        try env.historyStore.append([run(id, .timeout, at: env.clock.now.addingTimeInterval(-20 * day), ms: 900)])
        await model.startDiagnosis(for: id)?.value
        await model.waitForHistory()
        let line = try XCTUnwrap(env.historyStore.load().last { $0.kind == .diagnose })
        XCTAssertNotNil(line.durationMs, "§66.3: the diagnose line carries its duration")
        XCTAssertEqual(model.diagnosis(for: id)?.result?.durationMs, line.durationMs)
        let weekText = await model.diagnosisReport(for: id, window: .week)
        let monthText = await model.diagnosisReport(for: id, window: .month)
        let week = try XCTUnwrap(weekText)
        let month = try XCTUnwrap(monthText)
        XCTAssertFalse(week.contains("`timeout`"))
        XCTAssertTrue(month.contains("`timeout`"))
        XCTAssertTrue(month.contains("900 ms"))
        let none = await model.diagnosisReport(for: UUID(), window: .week)
        XCTAssertNil(none)
    }

    // MARK: (d) intents

    func testIntentResultTextIsVerdictAndDuration() throws {
        L10n.setting = .en
        XCTAssertEqual(DiagnosisIntentText.result(diagnosis(.cidBanned)), "CID ban · 1.2 s")
        XCTAssertEqual(DiagnosisIntentText.dialog(label: "Zombie TR", diagnosis(.noBan)), "Zombie TR: No ban · 1.2 s")
        L10n.setting = .tr
        XCTAssertEqual(DiagnosisIntentText.result(diagnosis(.rangeBanned)), "Aralık banı · 1,2 sn")
        XCTAssertEqual(DiagnosisIntentText.dialog(label: "Zombie TR", diagnosis(.cidBanned)), "Zombie TR: CID ban · 1,2 sn")
        L10n.setting = .system
        XCTAssertEqual(DiagnosisTrendWindow.caseDisplayRepresentations.count, DiagnosisTrendWindow.allCases.count)
        XCTAssertEqual(DiagnosisTrendWindow.default, .week)
        for failure: IntentFailure in [.noDiagnosis, .noNetwork, .clipboard] {
            XCTAssertFalse(String(localized: IntentError(failure: failure).localizedStringResource).isEmpty)
        }
    }

    @MainActor
    func testIntentDiagnoseAndCopyReport() async throws {
        let env = try TestAppEnvironment()
        let pasteboard = RecordingPasteboard()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(udp: FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(
            connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned (CID)")))), notifier: notifier) {
            $0.pasteboard = pasteboard
        }
        model.addServer(ServerDraft(label: "Zombie TR", host: server))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        let entryBefore = model.servers[0]

        // Copy before any diagnosis: a clear error.
        let early = await model.copyDiagnosisReportForIntent(id)
        XCTAssertEqual(early, .failure(.noDiagnosis))
        let unknown = await model.copyDiagnosisReportForIntent(UUID())
        if case .failure(.serverNotFound) = unknown {} else { XCTFail("expected serverNotFound, got \(unknown)") }

        let result = try await model.diagnoseForIntent(id)
        await model.waitForHistory()
        XCTAssertEqual(result.verdict, .cidBanned)
        XCTAssertNotNil(result.durationMs)
        XCTAssertEqual(model.servers[0], entryBefore, "the server entry is not changed")
        XCTAssertEqual(env.historyStore.load().filter { $0.kind == .diagnose }.map(\.new), ["cidBanned"])
        XCTAssertEqual(notifier.posts.count, 0, "the intent answers itself, no notification")

        let copied = await model.copyDiagnosisReportForIntent(id, window: .month)
        XCTAssertEqual(copied, .success("Zombie TR"))
        let text = try XCTUnwrap(pasteboard.written.last)
        XCTAssertTrue(text.contains("`cidBanned`"))
        XCTAssertTrue(text.contains(L10n.text(.diagnoseReportHistory)))
        XCTAssertTrue(text.contains(DiagnosisTrendWindow.month.title))
        XCTAssertTrue(text.contains(L10n.text(.diagnoseReportMasked)), "masked by default")
        XCTAssertFalse(text.contains("203.0.113.7"))
        let unmasked = await model.copyDiagnosisReportForIntent(id, masked: false)
        XCTAssertEqual(unmasked, .success("Zombie TR"))
        XCTAssertTrue(try XCTUnwrap(pasteboard.written.last).contains("203.0.113.7"))

        pasteboard.fails = true
        let refused = await model.copyDiagnosisReportForIntent(id)
        XCTAssertEqual(refused, .failure(.clipboard))

        do {
            _ = try await model.diagnoseForIntent(UUID())
            XCTFail("expected serverNotFound")
        } catch let failure as IntentFailure {
            guard case .serverNotFound = failure else { return XCTFail("\(failure)") }
        }
    }

    // MARK: (f) no network

    @MainActor
    func testIntentDiagnoseWithoutNetworkIsAnError() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel { $0.udpTransport = NoSocketTransport() }
        model.addServer(ServerDraft(label: "A", host: server))
        let id = try XCTUnwrap(model.servers.first?.id)
        do {
            _ = try await model.diagnoseForIntent(id)
            XCTFail("expected noNetwork")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .noNetwork)
        }
        await model.waitForHistory()
        XCTAssertEqual(env.historyStore.load().filter { $0.kind == .diagnose }.map(\.new), ["timeout"])
        // The copy still works on that run (the report explains it).
        XCTAssertNotNil(model.lastDiagnoses[id])

        // DNS without network is "no network" too; a plain DNS failure is not.
        var steps = [DiagnosisStep(step: .dns, status: .failed, durationMs: 1, target: "cs.example", detail: "network")]
        XCTAssertTrue(diagnosis(.dnsFailure, steps: steps).networkUnavailable)
        steps[0].detail = "notFound"
        XCTAssertFalse(diagnosis(.dnsFailure, steps: steps).networkUnavailable)
        XCTAssertFalse(diagnosis(.noBan).networkUnavailable)
    }

    // MARK: (e) parity of the new keys

    func testNewKeysExistInEveryLanguage() throws {
        let keys = ["banMatrix.recent", "banMatrix.recentValue", "diagnose.rangeBan.explanation", "diagnose.rangeBan.range",
                    "diagnose.rangeBan.hintTitle", "diagnose.rangeBan.hint", "notify.rangeBan.title", "diagnose.report.history",
                    "diagnose.column.time", "intent.diagnose.title", "intent.copyReport.title", "intent.short.diagnose",
                    "intent.short.copyReport", "intent.parameter.masked", "intent.dialog.diagnose", "intent.dialog.copyReport",
                    "intent.error.noDiagnosis", "intent.error.noNetwork", "intent.error.clipboard"]
        let all = Set(L10nKey.allCases.map(\.rawValue))
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(L10n.languageBundle(language.rawValue), language.rawValue)
            for key in keys {
                XCTAssertTrue(all.contains(key), key)
                let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
                XCTAssertNotEqual(value, "\u{0}", "\(language.rawValue): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language.rawValue): \(key)")
            }
        }
    }
}

/// `UNNotificationDefaultActionIdentifier` without importing UserNotifications in the test.
private let UNNotificationDefaultActionIdentifierForTests = "com.apple.UNNotificationDefaultActionIdentifier"

/// No network: every socket fails to open (like `ENETUNREACH`).
private struct NoSocketTransport: UDPTransport {
    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession {
        throw UDPSocketError.system(51)
    }
}

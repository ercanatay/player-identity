import XCTest
@testable import PlayerIdentity

/// v2.2 interface binding: appeal reminders (§36), texts of interfaces/matrix/ban list (§37, §38, §40),
/// intents and Shortcuts localization (§41).
@MainActor
final class InterfaceV22Tests: XCTestCase {
    private func tr<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr")), operation: body)
    }

    private func en<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en")), operation: body)
    }

    // MARK: §36 reminders

    func testReminderIsPostedOnceAndNotifiedAtIsNotAnUnsavedChange() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(notifier: notifier)
        model.addServer(ServerDraft(label: "POLIGON", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertNil(model.saveAppeal(Appeal(sentAt: env.clock.now, channel: .discord,
                                             followUpAt: env.clock.now.addingTimeInterval(3600)), for: id))
        await model.refresh().value
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.checkAppealReminders())                       // not due yet

        env.clock.advance(3600)
        await model.refresh().value                                       // refresh checks the reminders
        try await Task.sleep(for: .milliseconds(50))
        await waitUntil { notifier.posts.count == 1 }
        XCTAssertTrue(notifier.posts[0].title.hasSuffix("POLIGON"))
        XCTAssertNotNil(model.servers[0].appeal?.notifiedAt)
        XCTAssertFalse(model.hasUnsavedChanges)                           // bookkeeping, not an edit
        let saved = try XCTUnwrap(SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot)
        XCTAssertNotNil(saved.servers[0].appeal?.notifiedAt)              // survives a relaunch

        XCTAssertNil(model.checkAppealReminders())                        // once
        let relaunched = env.makeModel(notifier: notifier)
        XCTAssertEqual(relaunched.dueAppealReminders(), [])

        // Postponing arms it again; the menu bar timer checks between refreshes.
        XCTAssertNil(model.postponeFollowUp(byDays: 1, for: id))
        env.clock.advance(2 * 86_400)
        model.menuBarEnabled = true
        model.runMenuBarTick()   // refresh due → the refresh checks
        await model.waitForRefresh()
        await waitUntil { notifier.posts.count == 2 }
        XCTAssertEqual(notifier.posts.count, 2)
    }

    func testRemindersOffWithNotificationsOff() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let model = env.makeModel(notifier: notifier)
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        XCTAssertNil(model.saveAppeal(Appeal(sentAt: env.clock.now, channel: .forum, followUpAt: env.clock.now),
                                      for: try XCTUnwrap(model.servers.first?.id)))
        model.notificationsEnabled = false
        XCTAssertNil(model.checkAppealReminders())
        XCTAssertNil(model.servers[0].appeal?.notifiedAt)
        model.notificationsEnabled = true
        await model.checkAppealReminders()?.value
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func testReminderTexts() throws {
        let due = AppealReminder.Due(serverID: UUID(), label: "Zombie TR", followUpAt: Date(timeIntervalSince1970: 1_793_000_000))
        try tr {
            let content = AppealReminderText.content(for: due, status: .sent)
            XCTAssertEqual(content.title, "İtiraz takibi: Zombie TR")
            XCTAssertTrue(content.body.contains("Gönderildi"))
            XCTAssertTrue(content.key.contains(due.serverID.uuidString))
            XCTAssertEqual(HistoryText.kind(.note), "Not değişti")
            XCTAssertEqual(L10n.text(.appealPostpone), "Takip tarihini ertele")
        }
        try en {
            XCTAssertEqual(AppealReminderText.content(for: due, status: .answered).title, "Appeal follow-up: Zombie TR")
            XCTAssertEqual(HistoryText.kind(.note), "Note changed")
        }
    }

    // MARK: §37 / §38 / §39 / §40 texts

    func testInterfaceMatrixMetricsAndBanListTexts() throws {
        XCTAssertEqual(InterfacesSection.egressText(publicIP: "203.0.113.7", interface: "utun4"), "203.0.113.7 · utun4")
        XCTAssertEqual(InterfacesSection.egressText(publicIP: nil, interface: nil), "— · —")

        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let servers = [ServerEntry(label: "Odd, server", host: "2001:db8::1",
                                   banCheck: BanCheck(status: .cidUnknown, checkedAt: t0, detail: "ipOk → cidUnknown: errormsg x")),
                       ServerEntry(label: "IP", host: "192.0.2.10", banCheck: BanCheck(status: .ipBanned, checkedAt: t0, detail: ""))]
        try tr {
            XCTAssertEqual(L10n.text(.networkVPNWarning), "VPN aktif — ban sonucu VPN çıkışına aittir.")
            let table = BanMatrixText.table(BanMatrix.rows(servers: servers))
            XCTAssertEqual(table[0], ["Sunucu", "Adres", "IP banı", "CID banı", "Aralık", "Son kontrol"])
            XCTAssertEqual(Array(table[1].prefix(5)), ["IP", "192.0.2.10:27015", "Ban var", "Belirsiz", "—"])
            XCTAssertEqual(table[2][1], "[2001:db8::1]:27015")
            XCTAssertEqual(table[2][3], BanClassification.unverifiedText)          // "Ban türü doğrulanamadı"
            XCTAssertTrue(CSV.encode(table).contains("\"Odd, server\""))
            XCTAssertEqual(BanMatrixText.lastCheck(nil), "—")
            XCTAssertEqual(BanListText.error(.unknownPlaceholder("steamid")), "Bilinmeyen yer tutucu: {steamid}")
            XCTAssertNil(ServerDetailSheet.validationText(""))
            XCTAssertNil(ServerDetailSheet.validationText("https://x.example/?q={cid}"))
            XCTAssertEqual(ServerDetailSheet.validationText("http://x.example/?q={cid}"), "Adres https:// ile başlamalı.")
            XCTAssertTrue(MetricsText.percent(0.5).contains("50"))
        }
        let errors: [BanListTemplateError] = [.empty, .notHTTPS, .noPlaceholder, .unknownPlaceholder("x"), .invalidURL,
                                              .missingValue(.cid)]
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                for error in errors { XCTAssertFalse(BanListText.error(error).isEmpty, "\(language) \(error)") }
                for cell in BanMatrixCell.allCases { XCTAssertFalse(BanMatrixText.cell(cell).isEmpty) }
                XCTAssertEqual(Set(BanMatrixText.header).count, 6)
            }
        }
    }

    // MARK: §41 intents and Shortcuts

    func testIntentTextsAndShortcutPhrasesAreLocalized() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let metadata = resources.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        let actions = try XCTUnwrap(object["actions"] as? [String: Any])
        XCTAssertEqual(Set(actions.keys), ["CheckServerBanIntent", "ShowCIDIntent", "RefreshIntent"])
        let shortcuts = try XCTUnwrap(object["autoShortcuts"] as? [[String: Any]])
        XCTAssertEqual(shortcuts.count, 3)
        let phraseKeys = shortcuts.flatMap { ($0["phraseTemplates"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String } }
        let shortTitles = shortcuts.compactMap { ($0["shortTitle"] as? [String: Any])?["key"] as? String }
        XCTAssertEqual(phraseKeys.count, 6)                    // 2 phrases per shortcut
        XCTAssertTrue(shortcuts.allSatisfy { ($0["phraseTemplates"] as? [Any])?.count == 2 })

        let keys = Set(L10nKey.allCases.map(\.rawValue))
        for key in shortTitles + ["intent.checkBan.title", "intent.showCID.title", "intent.refresh.title", "intent.server.type",
                                  "intent.parameter.server", "intent.error.noRecord", "intent.error.resolution"] {
            XCTAssertTrue(keys.contains(key), key)
        }
        for language in ["tr", "en"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "AppShortcuts", withExtension: "strings",
                                                    subdirectory: nil, localization: language))
            let phrases = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            XCTAssertEqual(Set(phrases.keys), Set(phraseKeys), language)
            for (key, value) in phrases {
                XCTAssertTrue(value.contains("${applicationName}"), "\(language) \(key)")
                XCTAssertFalse(value.hasPrefix("intent."), "\(language) \(key)")
            }
            XCTAssertEqual(Set(phrases.values).count, 6, language)   // all different
            let expected = language == "tr"
                ? ["sunucu banını kontrol et", "ban kontrolü", "CID'imi göster", "oyuncu kimliğimi göster",
                   "durumunu yenile", "ban durumumu yenile"]
                : ["Check server ban", "ban check", "Show my CID", "Show my player identity", "Refresh ", "Refresh my ban status"]
            for fragment in expected {
                XCTAssertTrue(phrases.values.contains { $0.contains(fragment) }, "\(language): \(fragment)")
            }
        }
        try tr {
            XCTAssertEqual(L10n.text(.intentCheckBanTitle), "Sunucu banını kontrol et")
            XCTAssertEqual(L10n.text(.intentShowCIDTitle), "CID'imi göster")
        }
        try en { XCTAssertEqual(L10n.text(.intentRefreshTitle), "Refresh") }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

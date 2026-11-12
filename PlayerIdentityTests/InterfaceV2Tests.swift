import AppKit
import XCTest
@testable import PlayerIdentity

/// v2.0 interface binding: join the game (§29), menu bar + launch at login (§30), groups (§31),
/// notes/appeal (§32), share card (§33) and their texts.
@MainActor
final class InterfaceV2Tests: XCTestCase {
    private static let app = "/Applications/Xash3D-FWGS.app"

    private func installGame(_ deps: inout AppDependencies, runner: FakeGameLaunchRunner) {
        deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]),
                                             homeDirectory: URL(fileURLWithPath: "/Users/test"))
        deps.gameLaunchRunner = runner
    }

    // MARK: §29

    func testJoinGameRunsTheCommandWhenTheGameIsClosed() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let model = env.makeModel { self.installGame(&$0, runner: runner) }
        XCTAssertTrue(model.isGameAppInstalled)
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10", portText: "27016"))
        await model.refresh().value
        await model.joinGame(try XCTUnwrap(model.servers.first?.id))?.value
        XCTAssertNil(model.pendingJoin)
        XCTAssertNil(model.joinError)
        XCTAssertEqual(runner.commands, [["/usr/bin/open", "-a", Self.app, "--args", "-game", "valve",
                                          "+connect", "192.0.2.10:27016"]])
    }

    func testJoinGameAsksWhenTheGameIsRunningAndCancelRunsNothing() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let model = env.makeModel(game: FakeGameDetector(running: true)) { self.installGame(&$0, runner: runner) }
        model.addServer(ServerDraft(label: "POLIGON", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)

        await model.joinGame(id)?.value
        XCTAssertEqual(model.pendingJoin?.label, "POLIGON")
        XCTAssertEqual(runner.commands, [])
        model.cancelJoin()
        XCTAssertNil(model.pendingJoin)
        XCTAssertEqual(runner.commands, [])

        await model.joinGame(id)?.value
        await model.confirmJoin()?.value
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testJoinGameHiddenWithoutXash3DAndErrors() async throws {
        let env = try TestAppEnvironment()
        let hidden = env.makeModel()
        XCTAssertFalse(hidden.isGameAppInstalled)
        hidden.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        await hidden.joinGame(try XCTUnwrap(hidden.servers.first?.id))?.value
        XCTAssertEqual(hidden.joinError, .appNotFound)

        let runner = FakeGameLaunchRunner()
        runner.status = 1
        let failing = env.makeModel { self.installGame(&$0, runner: runner) }
        failing.addServer(ServerDraft(label: "B", host: "missing.example.test"))
        await failing.joinGame(try XCTUnwrap(failing.servers.last?.id))?.value
        XCTAssertEqual(failing.joinError, .resolutionFailed(.notFound))
        failing.addServer(ServerDraft(label: "C", host: "192.0.2.11"))
        await failing.joinGame(try XCTUnwrap(failing.servers.last?.id))?.value
        XCTAssertEqual(failing.joinError, .launchFailed(status: 1))

        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(GameLaunchText.error(.appNotFound), "Xash3D bulunamadı. /Applications/Xash3D-FWGS.app gerekli.")
            XCTAssertEqual(L10n.text(.gameJoinConfirmTitle), "Oyun açık; yeni bağlantı mevcut oyunu kapatır")
            XCTAssertEqual(L10n.text(.gameJoin), "Oyuna gir")
        }
        let errors: [GameLaunchError] = [.appNotFound, .invalidHost, .invalidPort, .invalidGamedir,
                                         .resolutionFailed(.network), .noAddress, .cancelled, .launchFailed(status: 3)]
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                for error in errors { XCTAssertFalse(GameLaunchText.error(error).isEmpty, "\(language) \(error)") }
                XCTAssertTrue(GameLaunchText.error(.launchFailed(status: 3)).contains("3"))
            }
        }
    }

    // MARK: §30

    func testMenuBarModeTimerAndWindowClosing() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        XCTAssertFalse(model.menuBarEnabled)
        XCTAssertNil(model.runMenuBarTick())                      // off: no timer, no refresh
        XCTAssertTrue(TerminationPolicy.quitsAfterLastWindowClosed(menuBarEnabled: false))

        model.menuBarEnabled = true
        XCTAssertTrue(MenuBarPreferences(defaults: env.defaults).showInMenuBar)
        XCTAssertFalse(TerminationPolicy.quitsAfterLastWindowClosed(menuBarEnabled: true))
        XCTAssertEqual(model.menuBarPresentation.tint, .neutral)

        XCTAssertEqual(model.runMenuBarTick(), MenuBarRefreshSchedule.interval)   // never checked → refresh now
        XCTAssertTrue(model.isRefreshing)
        await model.waitForRefresh()
        XCTAssertNotNil(model.lastChecked)
        XCTAssertNotNil(model.report)
        XCTAssertEqual(model.menuBarPresentation, MenuBarPresentation.make(overall: model.report?.overall))

        env.clock.advance(600)
        XCTAssertEqual(try XCTUnwrap(model.runMenuBarTick()), 1200, accuracy: 1)  // 20 min left, no refresh
        XCTAssertFalse(model.isRefreshing)
        env.clock.advance(1200)
        XCTAssertEqual(model.runMenuBarTick(), MenuBarRefreshSchedule.interval)
        XCTAssertTrue(model.isRefreshing)
        await model.waitForRefresh()

        model.menuBarEnabled = false
        XCTAssertNil(model.runMenuBarTick())
        XCTAssertFalse(env.makeModel().menuBarEnabled)
        model.menuBarEnabled = true
        XCTAssertTrue(env.makeModel().menuBarEnabled)                  // persisted
    }

    func testLaunchAtLoginSwitch() throws {
        let env = try TestAppEnvironment()
        let item = FakeLoginItem()
        let model = env.makeModel { $0.loginItem = item }
        XCTAssertTrue(model.isLoginItemAvailable)
        XCTAssertFalse(model.loginItemStatus.isOn)
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemStatus, .enabled)
        XCTAssertNil(model.loginItemError)
        model.setLaunchAtLogin(false)
        XCTAssertEqual(model.loginItemStatus, .notRegistered)

        item.fails = true
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemError, .registerFailed(detail: "Operation not permitted"))
        XCTAssertFalse(model.loginItemStatus.isOn)
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(LoginItemText.error(model.loginItemError!), "Açılışta başlat açılamadı: Operation not permitted")
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(LoginItemText.error(.unregisterFailed(detail: "x")), "Could not turn off launch at login: x")
        }

        let unavailable = env.makeModel()
        XCTAssertFalse(unavailable.isLoginItemAvailable)
        unavailable.setLaunchAtLogin(true)
        XCTAssertNil(unavailable.loginItemError)
    }

    func testMenuBarIconColors() {
        let red = MenuBarIcon.image(for: .make(overall: .red))
        XCTAssertFalse(red.isTemplate)
        XCTAssertGreaterThan(red.size.width, 0)
        XCTAssertTrue(MenuBarIcon.image(for: .make(overall: nil)).isTemplate)
        XCTAssertEqual(MenuBarIcon.color(.green), .systemGreen)
        XCTAssertNil(MenuBarIcon.color(.neutral))
    }

    // MARK: §31

    func testServerFormGroupChoiceAndFilterState() throws {
        XCTAssertEqual(ServerFormSheet.groupName(.none, newName: "x"), "")
        XCTAssertEqual(ServerFormSheet.groupName(.existing("Europe"), newName: "x"), "Europe")
        XCTAssertEqual(ServerFormSheet.groupName(.new, newName: " Asia "), " Asia ")
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10", group: " Asia "))
        XCTAssertEqual(model.serverGroups, ["Asia"])
        model.serverFilter.onlyFavorites = true
        XCTAssertEqual(model.serverSections(filter: model.serverFilter), [])
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(L10n.text(.serversOther), "Diğer")
            XCTAssertEqual(L10n.text(.serversFilterBanned), "Yalnız banlıları göster")
            XCTAssertEqual(L10n.text(.serversFilterFavorites), "Yalnız favoriler")
        }
    }

    // MARK: §32

    func testAppealDraftAndFollowUpReminder() throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        var draft = AppealDraft(now: t0)
        XCTAssertEqual(draft.appeal, Appeal(sentAt: t0, channel: .discord))
        draft.channel = .email
        draft.hasFollowUp = true
        draft.followUpAt = t0.addingTimeInterval(86_400)
        draft.summary = "ozet"
        let appeal = draft.appeal
        XCTAssertEqual(appeal.channel, "email")
        XCTAssertEqual(appeal.followUpAt, t0.addingTimeInterval(86_400))
        XCTAssertEqual(AppealDraft(appeal, now: t0), draft)

        // A free-text channel from an older record is kept.
        let custom = Appeal(sentAt: t0, channel: "Steam")
        XCTAssertEqual(AppealDraft(custom, now: t0).appeal.channel, "Steam")
        XCTAssertEqual(AppealDraft.statusOptions(for: nil), AppealStatus.allCases)
        XCTAssertEqual(AppealDraft.statusOptions(for: Appeal(sentAt: t0, channel: .forum, status: .rejected)), [.sent, .rejected])
        XCTAssertEqual(AppealDraft.statusOptions(for: Appeal(sentAt: t0, channel: .forum, status: .accepted)), [.accepted])

        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertNil(model.saveAppeal(Appeal(sentAt: env.clock.now, channel: .discord,
                                             followUpAt: env.clock.now.addingTimeInterval(3600)), for: id))
        XCTAssertFalse(model.isFollowUpDue(try XCTUnwrap(model.servers.first)))
        env.clock.advance(3600)
        XCTAssertTrue(model.isFollowUpDue(try XCTUnwrap(model.servers.first)))
    }

    func testAppealTextsAndHistoryLabel() throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let entry = HistoryEntry(ts: t0, kind: .appeal, old: "sent", new: "accepted", note: "email")
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(HistoryText.kind(.appeal), "İtiraz")
            XCTAssertEqual(HistoryText.change(entry), "Gönderildi → Kabul edildi")
            XCTAssertEqual(HistoryText.note(entry), "E-posta")
            XCTAssertEqual(HistoryText.note(HistoryEntry(ts: t0, kind: .appeal, new: "sent", note: "Steam")), "Steam")
            XCTAssertEqual(AppealEditError.transitionNotAllowed(from: .accepted, to: .sent).text,
                           "Bu durum değişikliğine izin verilmiyor: Kabul edildi → Gönderildi")
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(HistoryText.kind(.appeal), "Appeal")
            XCTAssertEqual(HistoryText.change(entry), "Sent → Accepted")
        }
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                XCTAssertEqual(Set(AppealStatus.allCases.map(\.label)).count, 4)
                XCTAssertEqual(Set(AppealChannel.allCases.map(\.label)).count, 5)
                for problem in Appeal.Problem.allCases { XCTAssertFalse(problem.text.isEmpty) }
                XCTAssertFalse(AppealEditError.noteTooLong.text.isEmpty)
                XCTAssertEqual(Set(HistoryKind.allCases.map(HistoryText.kind)).count, HistoryKind.allCases.count)
            }
        }
    }

    // MARK: §33

    func testShareCardContentCopyAndFileName() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        model.addServer(ServerDraft(label: "V6", host: "2001:db8::1", portText: "27016"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            let content = try XCTUnwrap(model.shareCardContent(for: id, icon: nil))
            XCTAssertEqual(content.cid, "d9de0eb4419608a8423241430581e91c")
            XCTAssertEqual(content.hostPort, "51.68.190.91:27015")
            XCTAssertEqual(content.playerName, "N")
            XCTAssertEqual(content.labels.server, "Sunucu")
            XCTAssertEqual(content.labels.title, "Cybokron Oyuncu Kimlik Kartı")
            XCTAssertFalse(content.dateText.isEmpty)
        }
        let v6 = try XCTUnwrap(model.shareCardContent(for: try XCTUnwrap(model.servers.last?.id), icon: nil))
        XCTAssertEqual(v6.hostPort, "[2001:db8::1]:27016")
        XCTAssertNil(model.shareCardContent(for: UUID(), icon: nil))

        let png = try XCTUnwrap(ShareCardRenderer.png(try XCTUnwrap(model.shareCardContent(for: id, icon: nil))))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlayerIdentityTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        ShareCardPasteboard.write(png, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))

        XCTAssertEqual(ShareCardPasteboard.fileName(label: "EU/1: Main"), "PlayerIdentity-EU-1- Main.png")
        XCTAssertEqual(ShareCardPasteboard.fileName(label: "  "), "PlayerIdentity.png")
    }
}

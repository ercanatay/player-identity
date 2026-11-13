import XCTest
@testable import PlayerIdentity

/// Login item controller fake: keeps the status, optionally fails.
final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    private let lock = NSLock()
    private var current: LoginItemStatus
    private var calls: [String] = []
    var fails = false
    var registersAs: LoginItemStatus = .enabled

    init(_ status: LoginItemStatus = .notRegistered) {
        current = status
    }

    var log: [String] { lock.withLock { calls } }

    func status() -> LoginItemStatus { lock.withLock { current } }

    func register() throws {
        lock.withLock { calls.append("register") }
        if fails { throw Failure() }
        lock.withLock { current = registersAs }
    }

    func unregister() throws {
        lock.withLock { calls.append("unregister") }
        if fails { throw Failure() }
        lock.withLock { current = .notRegistered }
    }
}

/// §30 menu bar: status → icon/title, 30-minute timer, launch at login.
final class MenuBarTests: XCTestCase {
    func testStatusToIconAndTitle() throws {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            let green = MenuBarPresentation.make(overall: .green)
            XCTAssertEqual(green.symbolName, StatusLevel.green.symbolName)
            XCTAssertEqual(green.tint, .green)
            XCTAssertEqual(green.title, StatusLevel.green.label)
            XCTAssertEqual(MenuBarPresentation.make(overall: .orange).tint, .orange)
            XCTAssertEqual(MenuBarPresentation.make(overall: .orange).symbolName, "exclamationmark.triangle.fill")
            XCTAssertEqual(MenuBarPresentation.make(overall: .red).tint, .red)
            XCTAssertEqual(MenuBarPresentation.make(overall: .red).title, StatusLevel.red.label)
            let unchecked = MenuBarPresentation.make(overall: nil)
            XCTAssertEqual(unchecked.tint, .neutral)
            XCTAssertEqual(unchecked.symbolName, MenuBarPresentation.uncheckedSymbol)
            XCTAssertEqual(unchecked.title, L10n.text(.topbarNotChecked))
        }
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                for level in [StatusLevel.green, .orange, .red, nil] {
                    XCTAssertFalse(MenuBarPresentation.make(overall: level).title.isEmpty, "\(language) \(String(describing: level))")
                }
            }
        }
    }

    func testThirtyMinuteTimerOnlyInMenuBarMode() {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertEqual(MenuBarRefreshSchedule.interval, 1800)
        XCTAssertFalse(MenuBarRefreshSchedule.isDue(lastRefresh: nil, now: t0, enabled: false))
        XCTAssertNil(MenuBarRefreshSchedule.delay(lastRefresh: t0, now: t0, enabled: false))
        XCTAssertTrue(MenuBarRefreshSchedule.isDue(lastRefresh: nil, now: t0, enabled: true))
        XCTAssertEqual(MenuBarRefreshSchedule.delay(lastRefresh: nil, now: t0, enabled: true), 0)

        XCTAssertFalse(MenuBarRefreshSchedule.isDue(lastRefresh: t0, now: t0.addingTimeInterval(1799), enabled: true))
        XCTAssertEqual(MenuBarRefreshSchedule.delay(lastRefresh: t0, now: t0.addingTimeInterval(600), enabled: true), 1200)
        XCTAssertTrue(MenuBarRefreshSchedule.isDue(lastRefresh: t0, now: t0.addingTimeInterval(1800), enabled: true))
        XCTAssertEqual(MenuBarRefreshSchedule.delay(lastRefresh: t0, now: t0.addingTimeInterval(4000), enabled: true), 0)
        // Clock moved back: refresh now instead of waiting.
        XCTAssertTrue(MenuBarRefreshSchedule.isDue(lastRefresh: t0, now: t0.addingTimeInterval(-60), enabled: true))
    }

    func testMenuBarPreferenceDefaultsOff() throws {
        let suite = "MenuBarTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MenuBarPreferences(defaults: defaults).showInMenuBar)
        MenuBarPreferences(showInMenuBar: true).save(to: defaults)
        XCTAssertTrue(MenuBarPreferences(defaults: defaults).showInMenuBar)
        XCTAssertTrue(defaults.bool(forKey: DefaultsKey.showInMenuBar))
    }

    func testLoginItemRegisterAndUnregister() {
        let item = FakeLoginItem()
        XCTAssertEqual(LoginItemSwitch.set(true, using: item), .success(.enabled))
        XCTAssertEqual(LoginItemSwitch.set(true, using: item), .success(.enabled))     // already on: no call
        XCTAssertEqual(LoginItemSwitch.set(false, using: item), .success(.notRegistered))
        XCTAssertEqual(item.log, ["register", "unregister"])

        let approval = FakeLoginItem()
        approval.registersAs = .requiresApproval
        XCTAssertEqual(LoginItemSwitch.set(true, using: approval), .success(.requiresApproval))
        XCTAssertTrue(LoginItemStatus.requiresApproval.isOn)
        XCTAssertFalse(LoginItemStatus.notFound.isOn)
    }

    func testLoginItemErrorCarriesTheSystemText() {
        let item = FakeLoginItem()
        item.fails = true
        XCTAssertEqual(LoginItemSwitch.set(true, using: item), .failure(.registerFailed(detail: "Operation not permitted")))
        XCTAssertEqual(item.status(), .notRegistered)
        let on = FakeLoginItem(.enabled)
        on.fails = true
        XCTAssertEqual(LoginItemSwitch.set(false, using: on), .failure(.unregisterFailed(detail: "Operation not permitted")))
    }

    func testRealLoginItemReportsAStatus() {
        // Reads the status only; never registers in tests.
        XCTAssertNotNil(MainAppLoginItem().status() as LoginItemStatus?)
    }

    // MARK: §60 quick CID

    private func choice(_ label: String, cid: String? = "c", recheck: Bool = true) -> MenuBarServerChoice {
        MenuBarServerChoice(id: UUID(), label: label, cid: cid, canRecheck: recheck)
    }

    func testQuickMenuItemsAndOrder() throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let a = choice("A"), b = choice("B", cid: nil, recheck: false)
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            let items = MenuBarQuickMenu.items(enabled: true, statusTitle: "All good", lastChecked: nil, servers: [a, b],
                                               selected: nil, rawID: "10331C2DCE4C91DB", feedback: nil, now: t0)
            XCTAssertEqual(items, [
                .status(L10n.format(.menuBarStatusLine, "All good", L10n.format(.topbarLastCheck, "—"))),
                .copyCID(serverID: a.id, label: "A", enabled: true),
                .copyRawID(enabled: true),
                .servers([a, b]),
            ])
            // Selected row without a CID: the item is there but disabled.
            let selectedB = MenuBarQuickMenu.items(enabled: true, statusTitle: "x", lastChecked: t0, servers: [a, b],
                                                   selected: b.id, rawID: nil, feedback: nil, now: t0)
            XCTAssertEqual(selectedB[1], .copyCID(serverID: b.id, label: "B", enabled: false))
            XCTAssertEqual(selectedB[2], .copyRawID(enabled: false))
            // No servers: disabled "Copy CID", no submenu.
            let empty = MenuBarQuickMenu.items(enabled: true, statusTitle: "x", lastChecked: t0, servers: [], selected: nil,
                                               rawID: "r", feedback: nil, now: t0)
            XCTAssertEqual(empty.count, 3)
            XCTAssertEqual(empty[1], .copyCID(serverID: nil, label: nil, enabled: false))
            XCTAssertEqual(MenuBarText.copyCID(label: nil), "Copy CID")
            XCTAssertEqual(MenuBarText.copyCID(label: "A"), "Copy CID (A)")
        }
        // Menu bar mode off: no items at all.
        XCTAssertEqual(MenuBarQuickMenu.items(enabled: false, statusTitle: "x", lastChecked: t0, servers: [a], selected: a.id,
                                              rawID: "r", feedback: .failed(.rawID, at: t0), now: t0), [])
    }

    func testCIDSourceIsSelectedOrFirst() {
        let a = UUID(), b = UUID(), gone = UUID()
        XCTAssertEqual(MenuBarQuickMenu.cidServer(selected: b, servers: [a, b]), b)
        XCTAssertEqual(MenuBarQuickMenu.cidServer(selected: nil, servers: [a, b]), a)
        XCTAssertEqual(MenuBarQuickMenu.cidServer(selected: gone, servers: [a, b]), a)   // deleted selection
        XCTAssertNil(MenuBarQuickMenu.cidServer(selected: gone, servers: []))
    }

    func testCopiedConfirmationLastsTwoSeconds() {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let copied = MenuBarCopyFeedback.copied(.rawID, at: t0)
        XCTAssertEqual(MenuBarCopyFeedback.confirmationDuration, 2)
        XCTAssertTrue(copied.isVisible(now: t0))
        XCTAssertTrue(copied.isVisible(now: t0.addingTimeInterval(1.9)))
        XCTAssertFalse(copied.isVisible(now: t0.addingTimeInterval(2)))
        XCTAssertFalse(copied.isVisible(now: t0.addingTimeInterval(-1)))
        XCTAssertTrue(MenuBarCopyFeedback.failed(.rawID, at: t0).isVisible(now: t0.addingTimeInterval(3600)))
        let items = { (feedback: MenuBarCopyFeedback, now: Date) in
            MenuBarQuickMenu.items(enabled: true, statusTitle: "x", lastChecked: nil, servers: [], selected: nil, rawID: "r",
                                   feedback: feedback, now: now)
        }
        XCTAssertEqual(items(copied, t0).last, .copied)
        XCTAssertEqual(items(copied, t0.addingTimeInterval(2)).count, 3)
        XCTAssertEqual(items(.failed(.rawID, at: t0), t0.addingTimeInterval(10)).last, .copyFailed)
    }

    @MainActor
    func testModelCopiesCIDAndRawID() async throws {
        let env = try TestAppEnvironment()
        let pasteboard = RecordingPasteboard()
        let model = env.makeModel { $0.pasteboard = pasteboard }
        model.addServer(ServerDraft(label: "A", host: "51.68.190.91"))
        model.addServer(ServerDraft(label: "B", host: "51.68.190.92"))
        let ids = model.servers.map(\.id)
        XCTAssertEqual(model.menuBarQuickItems, [])                       // menu bar mode off
        model.menuBarEnabled = true
        XCTAssertEqual(model.menuBarQuickItems[1], .copyCID(serverID: ids[0], label: "A", enabled: false))   // no refresh yet
        XCTAssertFalse(model.menuBarCopy(.cid(ids[0])))
        XCTAssertEqual(pasteboard.written, [])
        XCTAssertNil(model.menuBarCopyFeedback)

        await model.refresh().value
        let cidA = try XCTUnwrap(model.rowStatus(ids[0])?.currentCID)
        let cidB = try XCTUnwrap(model.rowStatus(ids[1])?.currentCID)
        XCTAssertEqual(model.menuBarQuickItems[1], .copyCID(serverID: ids[0], label: "A", enabled: true))
        XCTAssertTrue(model.menuBarCopy(.cid(ids[0])))
        XCTAssertEqual(pasteboard.written, [cidA])
        XCTAssertEqual(model.menuBarCopyFeedback, .copied(.cid(ids[0]), at: env.clock.now))
        XCTAssertTrue(model.menuBarQuickItems.contains(.copied))

        model.selectedServerID = ids[1]
        XCTAssertEqual(model.menuBarQuickItems[1], .copyCID(serverID: ids[1], label: "B", enabled: true))
        XCTAssertTrue(model.menuBarCopy(.cid(ids[1])))
        XCTAssertTrue(model.menuBarCopy(.rawID))
        let rawID = try XCTUnwrap(model.menuBarRawID)
        XCTAssertEqual(rawID, try model.identity?.get().rawIDHex)       // same text as the profile card
        XCTAssertEqual(pasteboard.written, [cidA, cidB, rawID])

        // The confirmation goes away after 2 seconds.
        for _ in 0..<20 where model.menuBarCopyFeedback != nil { await Task.yield() }
        XCTAssertNil(model.menuBarCopyFeedback)
        XCTAssertFalse(model.menuBarQuickItems.contains(.copied))

        // Server submenu: every server, with copy + recheck.
        guard case .servers(let choices)? = model.menuBarQuickItems.last else { return XCTFail("no server submenu") }
        XCTAssertEqual(choices.map(\.label), ["A", "B"])
        XCTAssertEqual(choices.map(\.cid), [cidA, cidB])
        XCTAssertEqual(choices.map(\.canRecheck), [true, true])
        model.banCheckEnabled = false
        XCTAssertFalse(model.canRecheckServer(ids[0]))

        model.menuBarEnabled = false
        XCTAssertEqual(model.menuBarQuickItems, [])
        XCTAssertTrue(model.errorLog.entries.isEmpty)
    }

    @MainActor
    func testClipboardFailureIsShownAndLogged() async throws {
        let env = try TestAppEnvironment()
        let pasteboard = RecordingPasteboard()
        pasteboard.fails = true
        let model = env.makeModel { $0.pasteboard = pasteboard }
        model.addServer(ServerDraft(label: "A", host: "51.68.190.91"))
        model.menuBarEnabled = true
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)

        XCTAssertFalse(model.menuBarCopy(.cid(id)))
        XCTAssertEqual(model.menuBarCopyFeedback, .failed(.cid(id), at: env.clock.now))
        XCTAssertTrue(model.menuBarQuickItems.contains(.copyFailed))
        XCTAssertFalse(model.menuBarQuickItems.contains(.copied))
        let entry = try XCTUnwrap(model.errorLog.entries.last)
        XCTAssertEqual(entry.area, .clipboard)
        XCTAssertTrue(entry.message.contains("cid"))
        // The error line stays (it is not a 2-second confirmation) …
        env.clock.advance(60)
        XCTAssertTrue(model.menuBarQuickItems.contains(.copyFailed))
        // … until the next copy succeeds.
        pasteboard.fails = false
        XCTAssertTrue(model.menuBarCopy(.rawID))
        XCTAssertFalse(model.menuBarQuickItems.contains(.copyFailed))
        XCTAssertTrue(model.menuBarQuickItems.contains(.copied))
        // Default dependency (nothing injected): the write fails and is reported, never silent.
        let bare = env.makeModel()
        await bare.refresh().value
        XCTAssertFalse(bare.menuBarCopy(.rawID))
        XCTAssertEqual(bare.menuBarCopyFeedback, .failed(.rawID, at: env.clock.now))
    }
}

/// Clipboard fake: records the texts, optionally refuses them.
final class RecordingPasteboard: PasteboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var failing = false
    var written: [String] { lock.withLock { texts } }
    var fails: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    @MainActor func write(_ text: String) -> Bool {
        lock.withLock {
            guard !failing else { return false }
            texts.append(text)
            return true
        }
    }
}

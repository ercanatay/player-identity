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
}

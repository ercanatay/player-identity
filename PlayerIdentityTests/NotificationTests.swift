import XCTest
@testable import PlayerIdentity

/// §23: transition → notification mapping, first run, 10-minute dedupe, setting, permission timing.
final class NotificationPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let server = UUID()

    private func entry(_ kind: HistoryKind, old: String? = "a", new: String? = "b", note: String? = nil) -> HistoryEntry {
        HistoryEntry(ts: t0, kind: kind, serverID: server, host: "51.68.190.91", old: old, new: new, note: note)
    }

    func testMappingOfKinds() throws {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            let ban = NotificationPlanner.content(for: entry(.banAppeared, old: nil, new: "ipBanned"), serverLabel: "POLIGON")
            XCTAssertNil(ban)   // first observation
            let appeared = try XCTUnwrap(NotificationPlanner.content(for: entry(.banAppeared, old: "ipBanned", new: "cidBanned"),
                                                                     serverLabel: "POLIGON"))
            XCTAssertEqual(appeared.title, "Ban başladı")
            XCTAssertEqual(appeared.body, "POLIGON: CID ban")
            let lifted = try XCTUnwrap(NotificationPlanner.content(for: entry(.banLifted, old: "ipBanned", new: "ipOk"),
                                                                   serverLabel: nil))
            XCTAssertEqual(lifted.title, "Ban kalktı")
            XCTAssertEqual(lifted.body, "51.68.190.91: Engel yok")
            let ip = try XCTUnwrap(NotificationPlanner.content(for: entry(.ipChanged, old: "1.1.1.1", new: "2.2.2.2"),
                                                               serverLabel: nil))
            XCTAssertEqual(ip.title, "Genel IP değişti")
            XCTAssertEqual(ip.body, "1.1.1.1 → 2.2.2.2")
            XCTAssertEqual(NotificationPlanner.content(for: entry(.identityChanged), serverLabel: nil)?.title, "Kimlik değişti")
            let fix = try XCTUnwrap(NotificationPlanner.content(for: entry(.fixAttempt, old: nil, new: nil, note: "resolved"),
                                                                serverLabel: "S", fixMessage: "Çözüldü"))
            XCTAssertEqual(fix.body, "S: Çözüldü")   // a fix result is never a "first observation"
            for kind in [HistoryKind.refresh, .nameChanged, .modelChanged, .apply, .appUpdateAvailable] {
                XCTAssertNil(NotificationPlanner.content(for: entry(kind), serverLabel: nil), "\(kind)")
            }
        }
    }

    func testEnglishTexts() throws {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            let content = NotificationPlanner.content(for: entry(.ipChanged, old: "1.1.1.1", new: "2.2.2.2"), serverLabel: nil)
            XCTAssertEqual(content?.title, "Public IP changed")
        }
    }
}

final class NotificationDispatcherTests: XCTestCase {
    private let content = NotificationContent(key: "ipChanged||2.2.2.2|", title: "t", body: "b")

    func testDisabledPostsNothingAndAsksNothing() async {
        let notifier = FakeNotifier()
        let dispatcher = NotificationDispatcher(notifier: notifier, now: { Date() })
        let posted = await dispatcher.handle([content], enabled: false)
        XCTAssertEqual(posted, [])
        XCTAssertEqual(notifier.requestCount, 0)
        XCTAssertEqual(notifier.posts, [])
    }

    func testPermissionIsRequestedOnlyBeforeTheFirstNotification() async {
        let notifier = FakeNotifier(status: .notDetermined)
        let dispatcher = NotificationDispatcher(notifier: notifier, now: { Date() })
        let none = await dispatcher.handle([], enabled: true)
        XCTAssertEqual(none, [])
        XCTAssertEqual(notifier.requestCount, 0)
        await dispatcher.handle([content], enabled: true)
        await dispatcher.handle([NotificationContent(key: "other", title: "t", body: "b")], enabled: true)
        XCTAssertEqual(notifier.requestCount, 1)
        XCTAssertEqual(notifier.posts.count, 2)
    }

    func testDeniedPermissionPostsNothing() async {
        let notifier = FakeNotifier(status: .notDetermined, grant: false)
        let dispatcher = NotificationDispatcher(notifier: notifier, now: { Date() })
        await dispatcher.handle([content], enabled: true)
        XCTAssertEqual(notifier.posts, [])
    }

    func testSameEventIsNotRepeatedWithinTenMinutes() async {
        let clock = TestClock()
        let notifier = FakeNotifier(status: .authorized)
        let dispatcher = NotificationDispatcher(notifier: notifier, now: { clock.now })
        await dispatcher.handle([content], enabled: true)
        clock.advance(599)
        let repeated = await dispatcher.handle([content], enabled: true)
        XCTAssertEqual(repeated, [])
        clock.advance(1)
        let later = await dispatcher.handle([content], enabled: true)
        XCTAssertEqual(later, [content])
        XCTAssertEqual(notifier.posts.count, 2)
        XCTAssertEqual(NotificationDispatcher.dedupeInterval, 600)
    }
}

@MainActor
final class AppModelNotificationTests: XCTestCase {
    func testFirstRunIsSilentThenIPChangeNotifies() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let script = HTTPScript(bodies: [1: #"{"ip":"203.0.113.7"}"#], defaultBody: #"{"ip":"198.51.100.1"}"#)
        let model = env.makeModel(publicIPs: script, notifier: notifier)
        XCTAssertTrue(model.notificationsEnabled)

        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(notifier.posts, [])   // first run

        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(notifier.posts.map(\.body), ["203.0.113.7 → 198.51.100.1"])

        await model.refresh().value   // same state again
        await model.waitForHistory()
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func testSettingOffPostsNothingAndPersists() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .notDetermined)
        let script = HTTPScript(bodies: [1: #"{"ip":"203.0.113.7"}"#], defaultBody: #"{"ip":"198.51.100.1"}"#)
        let model = env.makeModel(publicIPs: script, notifier: notifier)
        model.notificationsEnabled = false
        XCTAssertEqual(env.defaults.object(forKey: DefaultsKey.notificationsEnabled) as? Bool, false)
        XCTAssertFalse(env.makeModel().notificationsEnabled)

        await model.refresh().value
        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(notifier.posts, [])
        XCTAssertEqual(notifier.requestCount, 0)
        XCTAssertTrue(env.historyStore.load().contains { $0.kind == .ipChanged && $0.old != nil })   // still recorded
    }
}

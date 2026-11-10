import XCTest
@testable import PlayerIdentity

/// §44 downloaded model previews.
final class DownloadedPreviewTests: XCTestCase {
    private var temp: TempDirectory!
    private var gamedir: URL { temp.url.appendingPathComponent("gearbox", isDirectory: true) }

    override func setUpWithError() throws { temp = try TempDirectory() }
    override func tearDown() { temp = nil }

    func testLocalWinsOverDownloaded() throws {
        try temp.write("gearbox/models/player/ann/ann.bmp", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("valve_downloads/models/player/ann/ann.bmp", BMPFixture.paletted(width: 6, height: 5))
        try temp.write("gearbox_downloads/models/player/ann/ann.bmp", BMPFixture.paletted(width: 8, height: 5))
        XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: "ann").image?.pixelWidth, 4)
    }

    func testValveDownloadsBeforeGamedirDownloads() throws {
        try temp.write("valve_downloads/models/player/ann/ann.bmp", BMPFixture.paletted(width: 6, height: 5))
        try temp.write("gearbox_downloads/models/player/ann/ann.bmp", BMPFixture.paletted(width: 8, height: 5))
        let image = try XCTUnwrap(ModelPreview.load(gamedir: gamedir, model: "ann").image)
        XCTAssertEqual(image.pixelWidth, 6)
        XCTAssertTrue(image.url.path.contains("valve_downloads"))   // source path for the tooltip
    }

    func testFoundInGamedirDownloadsAndUppercaseExtension() throws {
        try temp.write("gearbox/models/player/ann/ann.mdl", "mdl")   // local folder without a BMP → keep searching
        try temp.write("gearbox_downloads/models/player/ann/ANN.BMP", BMPFixture.paletted(width: 8, height: 5))
        let image = try XCTUnwrap(ModelPreview.load(gamedir: gamedir, model: "ann").image)
        XCTAssertEqual(image.pixelWidth, 8)
        XCTAssertEqual(image.url.lastPathComponent, "ANN.BMP")
    }

    func testValveGamedirHasNoExtraDownloadsFolder() throws {
        let valve = temp.url.appendingPathComponent("valve", isDirectory: true)
        XCTAssertEqual(ModelPreviewLocator.folders(gamedir: valve, model: "x").count, 2)
        XCTAssertEqual(ModelPreviewLocator.folders(gamedir: gamedir, model: "x").count, 3)
    }

    func testMissingEverywhereIsPlaceholder() {
        XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: "ann"), .placeholder)
    }

    func testCacheRefreshesWhenDownloadedFileChanges() async throws {
        let file = try temp.write("valve_downloads/models/player/ann/ann.bmp", BMPFixture.paletted(width: 4, height: 5))
        let cache = ModelPreviewCache()
        let first = await cache.previews(gamedir: gamedir, models: ["ann"])
        XCTAssertEqual(first["ann"]?.image?.pixelWidth, 4)
        try BMPFixture.paletted(width: 9, height: 5).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path)
        let second = await cache.previews(gamedir: gamedir, models: ["ann"])
        XCTAssertEqual(second["ann"]?.image?.pixelWidth, 9)
    }
}

/// §45 granular notifications and quiet hours.
final class QuietNotificationTests: XCTestCase {
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    private func content(_ key: String, _ category: NotificationCategory) -> NotificationContent {
        NotificationContent(key: key, title: "t", body: "b", category: category)
    }

    private func sent(_ policy: NotificationPolicy, hour: Int, minute: Int = 0, master: Bool = true,
                      _ category: NotificationCategory) async -> Int {
        let notifier = FakeNotifier(status: .authorized)
        let time = at(hour, minute)
        let dispatcher = NotificationDispatcher(notifier: notifier, now: { time })
        return await dispatcher.handle([content("k", category)], enabled: master, policy: policy).count
    }

    func testQuietHoursDefaultsAndMidnightCrossing() {
        let quiet = QuietHours(enabled: true, start: "23:00", end: "08:00")
        XCTAssertTrue(quiet.contains(at(23)))
        XCTAssertTrue(quiet.contains(at(23, 59)))
        XCTAssertTrue(quiet.contains(at(0)))
        XCTAssertTrue(quiet.contains(at(7, 59)))
        XCTAssertFalse(quiet.contains(at(8)))
        XCTAssertFalse(quiet.contains(at(12)))
        XCTAssertFalse(quiet.contains(at(22, 59)))
    }

    func testSameDayWindowAndDisabledAndEmpty() {
        let day = QuietHours(enabled: true, start: "13:00", end: "15:30")
        XCTAssertTrue(day.contains(at(13)))
        XCTAssertTrue(day.contains(at(15, 29)))
        XCTAssertFalse(day.contains(at(15, 30)))
        XCTAssertFalse(day.contains(at(3)))
        XCTAssertFalse(QuietHours(enabled: false, start: "23:00", end: "08:00").contains(at(2)))
        XCTAssertFalse(QuietHours(enabled: true, start: "10:00", end: "10:00").contains(at(10)))
        XCTAssertEqual(QuietHours.minutes("08:05"), 485)
        XCTAssertNil(QuietHours.minutes("24:00"))
        XCTAssertNil(QuietHours.minutes("x"))
        XCTAssertEqual(QuietHours.text(minutes: 485), "08:05")
    }

    func testEachCategorySwitchSilencesOnlyItsOwnEvents() async {
        for off in [NotificationCategory.ban, .online, .map] {
            var policy = NotificationPolicy()
            switch off {
            case .ban: policy.banChanges = false
            case .online: policy.onlineChanges = false
            case .map: policy.mapChanges = false
            case .general: break
            }
            for category in [NotificationCategory.ban, .online, .map, .general] {
                let count = await sent(policy, hour: 12, category)
                XCTAssertEqual(count, category == off ? 0 : 1, "\(off) off, \(category)")
            }
        }
    }

    func testQuietHoursBlockEveryCategoryIncludingBanLifted() async {
        var policy = NotificationPolicy()
        policy.quiet = QuietHours(enabled: true, start: "23:00", end: "08:00")
        for category in [NotificationCategory.ban, .online, .map, .general] {
            let inside = await sent(policy, hour: 2, category)
            let outside = await sent(policy, hour: 12, category)
            XCTAssertEqual(inside, 0, "\(category)")
            XCTAssertEqual(outside, 1, "\(category)")
        }
        let lifted = WatchNotificationText.content(for: .banLifted(previous: .ipBanned, now: .ipOk), server: ServerEntry(label: "S", host: "192.0.2.1"))
        XCTAssertEqual(lifted.category, .ban)
    }

    func testMasterSwitchOffSendsNothing() async {
        let policy = NotificationPolicy(master: false)
        let count = await sent(policy, hour: 12, master: true, .general)
        XCTAssertEqual(count, 0)
        let masterArg = await sent(NotificationPolicy(), hour: 12, master: false, .ban)
        XCTAssertEqual(masterArg, 0)
    }

    func testWatchEventCategories() {
        XCTAssertEqual(WatchNotificationText.category(of: .offline), .online)
        XCTAssertEqual(WatchNotificationText.category(of: .online(after: 700)), .online)
        XCTAssertEqual(WatchNotificationText.category(of: .mapChanged(old: "a", new: "b")), .map)
        XCTAssertEqual(WatchNotificationText.category(of: .banAppeared(.ipBanned, previous: nil)), .ban)
    }

    @MainActor
    func testSettingsDefaultsAndPersistence() throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        XCTAssertTrue(model.notifyBanChanges)
        XCTAssertTrue(model.notifyOnlineChanges)
        XCTAssertTrue(model.notifyMapChanges)
        XCTAssertFalse(model.quietHoursEnabled)
        XCTAssertEqual(model.quietHoursStart, "23:00")
        XCTAssertEqual(model.quietHoursEnd, "08:00")
        model.notifyBanChanges = false
        model.notifyMapChanges = false
        model.quietHoursEnabled = true
        model.quietHoursStart = "22:15"
        model.quietHoursEnd = "07:45"
        let reloaded = env.makeModel()
        XCTAssertFalse(reloaded.notifyBanChanges)
        XCTAssertTrue(reloaded.notifyOnlineChanges)
        XCTAssertFalse(reloaded.notifyMapChanges)
        XCTAssertTrue(reloaded.quietHoursEnabled)
        XCTAssertEqual(reloaded.notificationPolicy.quiet, QuietHours(enabled: true, start: "22:15", end: "07:45"))
    }
}

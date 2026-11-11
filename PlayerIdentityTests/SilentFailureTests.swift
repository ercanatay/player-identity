import XCTest
@testable import PlayerIdentity

/// Failures that used to be swallowed: automatic backups (§49.3), appeal reminders and notification permission
/// (§36, §23), update error texts (§27), watch state (§42) and metric writes (§39).
@MainActor
final class SilentFailureTests: XCTestCase {
    private var lockedFolders: [URL] = []

    override func tearDown() async throws {
        for folder in lockedFolders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        lockedFolders = []
    }

    private func tr<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr")), operation: body)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: §49.3 automatic backups

    func testFailedAutomaticBackupTakesBackTheDayMarkAndShowsTheError() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.7.0")
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        env.defaults.set("20000101", forKey: DefaultsKey.autoBackupLastRun)
        // `backups` is a file: the folder cannot be created, the attempt fails.
        try Data("x".utf8).write(to: paths.fullBackups)

        let failed = await model.runAutomaticBackupIfDue()?.value
        guard case .failure(let error)? = failed else { return XCTFail("\(String(describing: failed))") }
        XCTAssertEqual(model.autoBackupLastError, error)
        XCTAssertEqual(env.defaults.string(forKey: DefaultsKey.autoBackupLastRun), "20000101", "the day is not marked")
        XCTAssertNil(model.latestAutomaticBackup)
        try tr {
            let line = FullBackupText.automaticFailure(error)
            XCTAssertTrue(line.hasPrefix("Son otomatik yedek başarısız: "), line)
            XCTAssertFalse(line.contains("Dosyalar yerine konamadı"), "not the restore wording")
            XCTAssertEqual(L10n.text(.actionRetry), "Yeniden dene")
        }

        // Still due today: "Try Again" makes another attempt (and fails again while the cause remains).
        let again = await model.retryAutomaticBackup()?.value
        guard case .failure? = again else { return XCTFail("\(String(describing: again))") }
        XCTAssertNotNil(model.autoBackupLastError)

        // Next launch, cause gone: the attempt is made and succeeds.
        try FileManager.default.removeItem(at: paths.fullBackups)
        let relaunched = env.makeModel(appVersion: "2.7.0")
        let created = await relaunched.runAutomaticBackupIfDue()?.value
        guard case .success(.created)? = created else { return XCTFail("\(String(describing: created))") }
        XCTAssertNil(relaunched.autoBackupLastError)
        XCTAssertEqual(env.defaults.string(forKey: DefaultsKey.autoBackupLastRun), FullBackupNaming.day(env.clock.now))
        XCTAssertNil(relaunched.runAutomaticBackupIfDue(), "done for today")

        // The old window's retry also clears its error once it works (the file of today already exists).
        env.defaults.removeObject(forKey: DefaultsKey.autoBackupLastRun)
        let retried = await model.retryAutomaticBackup()?.value
        XCTAssertEqual(retried, .some(.success(.alreadyToday)))
        XCTAssertNil(model.autoBackupLastError)
        await model.waitForRefresh()
        await relaunched.waitForRefresh()
    }

    func testFailedAutomaticBackupWithoutAPreviousRunRemovesTheMark() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.7.0")
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        try Data("x".utf8).write(to: paths.fullBackups)
        _ = await model.runAutomaticBackupIfDue()?.value
        XCTAssertNil(env.defaults.string(forKey: DefaultsKey.autoBackupLastRun))
        XCTAssertNotNil(model.autoBackupLastError)
    }

    func testAutomaticBackupFailureRowIsInTheDataSettings() throws {
        let views = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("App/Views", isDirectory: true)
        let source = try String(contentsOf: views.appendingPathComponent("FullBackupViews.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("model.autoBackupLastError"))
        XCTAssertTrue(source.contains("model.retryAutomaticBackup()"))
        XCTAssertTrue(source.contains("Palette.redText"))
    }

    // MARK: §23 dispatcher

    func testFailedPostIsNotDedupedAndIsPostedOnTheNextAttempt() async {
        let content = NotificationContent(key: "k", title: "t", body: "b")
        let notifier = FakeNotifier(status: .authorized)
        let dispatcher = NotificationDispatcher(notifier: notifier, now: { Date(timeIntervalSince1970: 1_793_000_000) })
        notifier.failsPosts = true
        let failed = await dispatcher.handle([content], enabled: true)
        XCTAssertEqual(failed, [])
        XCTAssertEqual(notifier.postAttempts, 1)
        notifier.failsPosts = false
        let retried = await dispatcher.handle([content], enabled: true)   // same second: not held back by the dedupe
        XCTAssertEqual(retried, [content])
        let repeated = await dispatcher.handle([content], enabled: true)  // now it is deduped
        XCTAssertEqual(repeated, [])
        XCTAssertEqual(notifier.posts, [content])
    }

    func testDeniedPermissionIsReportedAndNothingIsRecorded() async {
        let content = NotificationContent(key: "k", title: "t", body: "b")
        let notifier = FakeNotifier(status: .denied)
        let dispatcher = NotificationDispatcher(notifier: notifier, now: { Date(timeIntervalSince1970: 1_793_000_000) })
        let lastBefore = await dispatcher.lastAuthorization
        XCTAssertNil(lastBefore)
        let denied = await dispatcher.handle([content], enabled: true)
        XCTAssertEqual(denied, [])
        let lastDenied = await dispatcher.lastAuthorization
        XCTAssertEqual(lastDenied, .denied)
        notifier.setStatus(.authorized)
        let allowed = await dispatcher.handle([content], enabled: true)
        XCTAssertEqual(allowed, [content], "a refused attempt does not start the dedupe interval")
        let lastAllowed = await dispatcher.lastAuthorization
        XCTAssertEqual(lastAllowed, .authorized)
    }

    // MARK: §36 appeal reminders

    private func modelWithDueAppeal(_ env: TestAppEnvironment, notifier: FakeNotifier) async throws -> (AppModel, UUID) {
        let model = env.makeModel(notifier: notifier)
        model.addServer(ServerDraft(label: "POLIGON", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertNil(model.saveAppeal(Appeal(sentAt: env.clock.now, channel: .discord,
                                             followUpAt: env.clock.now.addingTimeInterval(3600)), for: id))
        model.save()
        env.clock.advance(3600)
        return (model, id)
    }

    private func savedNotifiedAt(_ env: TestAppEnvironment) throws -> Date? {
        try XCTUnwrap(SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot).servers[0].appeal?.notifiedAt
    }

    func testDeniedPermissionLeavesTheReminderPendingAndWarnsInSettings() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .denied)
        let (model, id) = try await modelWithDueAppeal(env, notifier: notifier)

        await model.checkAppealReminders()?.value
        XCTAssertEqual(notifier.posts, [])
        XCTAssertNil(model.servers[0].appeal?.notifiedAt, "not marked without permission")
        XCTAssertNil(try savedNotifiedAt(env))
        XCTAssertTrue(model.notificationPermissionDenied)
        try tr {
            XCTAssertEqual(NotificationSettingsText.warnings(model), [L10n.text(.settingsNotificationsDenied)])
            XCTAssertTrue(L10n.text(.settingsNotificationsDenied).hasPrefix("Bildirim izni yok"))
        }
        model.notificationsEnabled = false
        XCTAssertEqual(NotificationSettingsText.warnings(model), [], "no warning while notifications are off")
        model.notificationsEnabled = true

        // Permission given later: the next check posts it and marks it.
        notifier.setStatus(.authorized)
        await model.checkAppealReminders()?.value
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertNotNil(model.servers.first { $0.id == id }?.appeal?.notifiedAt)
        XCTAssertNotNil(try savedNotifiedAt(env))
        XCTAssertFalse(model.notificationPermissionDenied)
        XCTAssertNil(model.checkAppealReminders())
    }

    func testFailedPostLeavesTheReminderPending() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        notifier.failsPosts = true
        let (model, _) = try await modelWithDueAppeal(env, notifier: notifier)

        await model.checkAppealReminders()?.value
        XCTAssertEqual(notifier.postAttempts, 1)
        XCTAssertNil(model.servers[0].appeal?.notifiedAt)
        XCTAssertNil(try savedNotifiedAt(env))
        XCTAssertFalse(model.notificationPermissionDenied)

        notifier.failsPosts = false
        await model.checkAppealReminders()?.value
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertNotNil(model.servers[0].appeal?.notifiedAt)
        XCTAssertNotNil(try savedNotifiedAt(env))
    }

    func testReminderIsNotOfferedTwiceWhileBeingPosted() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let (model, _) = try await modelWithDueAppeal(env, notifier: notifier)
        let first = model.checkAppealReminders()
        XCTAssertNotNil(first)
        XCTAssertNil(model.checkAppealReminders(), "in flight")
        await first?.value
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertNil(model.checkAppealReminders())
    }

    func testMarkThatCannotBeSavedIsTakenBackInMemory() async throws {
        let env = try TestAppEnvironment()
        let notifier = FakeNotifier(status: .authorized)
        let (model, id) = try await modelWithDueAppeal(env, notifier: notifier)
        let folder = AppPaths(home: env.home).snapshotFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        lockedFolders.append(folder)

        XCTAssertFalse(model.markAppealsNotified([id]))
        XCTAssertNil(model.servers[0].appeal?.notifiedAt, "memory and disk agree: still pending")
        XCTAssertEqual(model.dueAppealReminders().map(\.serverID), [id])
        XCTAssertFalse(model.hasUnsavedChanges)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertTrue(model.markAppealsNotified([id]))
        XCTAssertNotNil(model.servers[0].appeal?.notifiedAt)
        XCTAssertNotNil(try savedNotifiedAt(env))
    }

    // MARK: §27 update error texts

    func testInstallFailureTextsAreHonest() throws {
        let path = "/b/PlayerIdentity-1.1.0.app"
        let backup = URL(fileURLWithPath: path)
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                let rolledBack = UpdateStatusText.error(.installFailed(rolledBack: true, backup: nil))
                let notRolledBack = UpdateStatusText.error(.installFailed(rolledBack: false, backup: nil))
                XCTAssertEqual(rolledBack, L10n.text(.updateErrorRolledBack))
                XCTAssertNotEqual(notRolledBack, rolledBack, "\(language): false must not claim a rollback")
                XCTAssertEqual(notRolledBack, L10n.text(.updateErrorNotRolledBack))
                XCTAssertTrue(UpdateStatusText.error(.installFailed(rolledBack: true, backup: backup)).contains(path))
                XCTAssertTrue(UpdateStatusText.error(.installFailed(rolledBack: false, backup: backup)).contains(path))
            }
        }
        try tr {
            XCTAssertTrue(UpdateStatusText.error(.installFailed(rolledBack: false, backup: nil)).contains("geri yüklenemedi"))
            XCTAssertEqual(UpdateStatusText.error(.cancelledByUser),
                           "Kurulum iptal edildi: yönetici onayı verilmedi; hiçbir şey değiştirilmedi.")
        }
    }

    // MARK: §42 watch state

    func testWatchStateWriteFailureIsShownOnceAndClearedAfterAWrite() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let file = AppPaths(home: env.home).watchStateFile
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)   // cannot be replaced

        await model.refresh().value
        let error = try XCTUnwrap(model.watchStateSaveError)
        try tr {
            let warnings = NotificationSettingsText.warnings(model)
            XCTAssertEqual(warnings.count, 1)
            XCTAssertTrue(warnings[0].hasPrefix("İzleme durumu kaydedilemedi: "), warnings[0])
            XCTAssertTrue(warnings[0].contains(error))
        }

        try FileManager.default.removeItem(at: file)
        env.clock.advance(3600)
        await model.refresh().value
        XCTAssertNil(model.watchStateSaveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(NotificationSettingsText.warnings(model), [])
    }

    // MARK: §39 metrics

    func testRecorderReportsConsecutiveWriteFailures() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("metrics.jsonl")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let clock = TestClock()
        let recorder = MetricsRecorder(store: MetricsStore(fileURL: file), now: { clock.now })
        let id = UUID()
        let sample = { MetricSample(ts: clock.now, serverID: id, host: "h", online: true, ping: 10) }

        let firstState = await recorder.record([sample()])
        let first = try XCTUnwrap(firstState)
        XCTAssertEqual(first.count, 1)
        XCTAssertNil(MetricsChart.writeFailureText(first, now: clock.now), "one failure is not shown")
        let since = first.since
        clock.advance(2 * 3600 + 60)
        let secondState = await recorder.record([sample()])
        let second = try XCTUnwrap(secondState)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.since, since)
        try tr {
            let text = try XCTUnwrap(MetricsChart.writeFailureText(second, now: clock.now))
            XCTAssertTrue(text.hasPrefix("Son 3 saatte ölçüm örnekleri yazılamadı (2 başarısız deneme)"), text)
        }

        try FileManager.default.removeItem(at: file)
        clock.advance(60)
        let recovered = await recorder.record([sample()])
        XCTAssertNil(recovered)
        let state = await recorder.writeFailure
        XCTAssertNil(state)
    }

    func testModelExposesMetricWriteFailures() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let file = AppPaths(home: env.home).metricsFile
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        await model.refresh().value
        _ = await model.loadMetrics()
        XCTAssertEqual(model.metricsWriteFailure?.count, 1)
        env.clock.advance(3600)
        await model.refresh().value
        _ = await model.loadMetrics()
        XCTAssertEqual(model.metricsWriteFailure?.count, 2)
        XCTAssertNotNil(MetricsChart.writeFailureText(model.metricsWriteFailure, now: model.now))

        try FileManager.default.removeItem(at: file)
        env.clock.advance(3600)
        await model.refresh().value
        _ = await model.loadMetrics()
        XCTAssertNil(model.metricsWriteFailure)
    }
}

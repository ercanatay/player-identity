import XCTest
@testable import PlayerIdentity

/// Settings redesign (Claude Design S1–S15): reset / erase, import preview differences, update check errors and the
/// Updates status card content.
@MainActor
final class SettingsRedesignTests: XCTestCase {
    override func tearDown() async throws {
        L10n.setting = .system
    }

    private func inLanguage<T>(_ language: String, _ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language)), operation: body)
    }

    // MARK: Reset settings

    func testResetSettingsRestoresDefaultsAndKeepsServersAndDataRoot() async throws {
        let env = try TestAppEnvironment()
        let login = FakeLoginItem(.enabled)
        let model = env.makeModel { $0.loginItem = login }
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        let root = env.home.appendingPathComponent("Games/Xash", isDirectory: true)
        model.setDataRoot(root)
        await model.waitForRefresh()
        model.appLanguage = .tr
        model.banCheckEnabled = false
        model.notificationsEnabled = false
        model.notifyMapChanges = false
        model.quietHoursEnabled = true
        model.quietHoursStart = "21:30"
        model.menuBarEnabled = true
        model.updates.preferences = UpdatePreferences(autoCheck: false, autoDownload: true)

        model.resetSettings()

        XCTAssertEqual(model.appLanguage, .system)
        XCTAssertTrue(model.banCheckEnabled)
        XCTAssertTrue(model.notificationsEnabled)
        XCTAssertTrue(model.notifyMapChanges)
        XCTAssertFalse(model.quietHoursEnabled)
        XCTAssertEqual(model.quietHoursStart, QuietHours.defaultStart)
        XCTAssertEqual(model.quietHoursEnd, QuietHours.defaultEnd)
        XCTAssertFalse(model.menuBarEnabled)
        XCTAssertEqual(model.updates.preferences, UpdatePreferences())
        XCTAssertEqual(login.log.last, "unregister")
        // Kept: servers, data root (also in UserDefaults).
        XCTAssertEqual(model.servers.map(\.label), ["A"])
        XCTAssertEqual(model.dataRoot, root.standardizedFileURL)
        XCTAssertEqual(env.defaults.string(forKey: DefaultsKey.dataRoot), root.standardizedFileURL.path)
        // Persisted defaults.
        XCTAssertEqual(env.defaults.object(forKey: DefaultsKey.banCheckEnabled) as? Bool, true)
        XCTAssertEqual(UpdatePreferences(defaults: env.defaults), UpdatePreferences())
        await model.waitForRefresh()
    }

    func testDefaultsCarryEveryPreferenceButTheFolders() {
        let defaults = ArchivedSettings.defaults
        XCTAssertEqual(defaults.count(includingDataRoot: true), 14)   // + automatic backups (2.9.2)
        XCTAssertEqual(defaults.autoBackupEnabled, true)
        XCTAssertNil(defaults.gamedir)
        XCTAssertNil(defaults.dataRoot)
        XCTAssertEqual(defaults.language, AppLanguageSetting.system.rawValue)
    }

    // MARK: Erase all data

    func testEraseAllDataRemovesOnlyTheAppFolderAndStartsOver() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.setWatch(true, for: model.servers[0].id)
        await model.refresh().value
        model.save()
        await model.waitForHistory()
        try DataBackupStore(paths: paths, defaultsDomain: env.suiteName)
            .create(from: "2.5.0", to: "2.4.1", now: env.clock.now, defaults: env.defaults)
        _ = try RecordBackup.make(of: paths.snapshotFile, at: env.clock.now)
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/updates/backup/PlayerIdentity-2.4.0.app/x", "app")

        let inventory = model.eraseInventory
        XCTAssertEqual(inventory.backups, 3)   // data backup + previous app version + record backup
        XCTAssertGreaterThan(inventory.items, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
        model.banCheckEnabled = false

        let error = await model.eraseAllData()
        XCTAssertNil(error)
        await model.waitForRefresh()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: model.appDataFolder.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.updatesDirectory.path))
        XCTAssertFalse(remaining.contains { $0.contains(RecordBackup.suffix) }, "\(remaining)")
        XCTAssertEqual(model.eraseInventory.backups, 0)
        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertEqual(model.snapshotState, .missing)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.updates.dataBackupCount, 0)
        // Game files, identity and preferences are untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.valveDir.appendingPathComponent("config.cfg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.home.appendingPathComponent(".config/.xash_id").path))
        XCTAssertFalse(model.banCheckEnabled)
        XCTAssertEqual(model.appDataFolder.lastPathComponent, UpdateInstaller.bundleID)
    }

    func testEraserOnAnEmptyHomeRemovesNothing() throws {
        let temp = try TempDirectory()
        let eraser = AppDataEraser(paths: AppPaths(home: temp.url))
        XCTAssertEqual(eraser.inventory(), AppDataEraser.Inventory())
        XCTAssertEqual(try eraser.erase(), 0)
    }

    // MARK: Import preview

    func testImportPreviewCountsDifferingSettings() {
        var current = ArchivedSettings.defaults
        current.gamedir = "valve"
        current.dataRoot = "/a"
        var incoming = current
        XCTAssertEqual(incoming.differences(from: current, includingDataRoot: true), 0)
        incoming.language = "en"
        incoming.quietHoursEnabled = true
        incoming.dataRoot = "/b"
        incoming.notifyMapChanges = nil   // not carried → not counted
        XCTAssertEqual(incoming.differences(from: current, includingDataRoot: false), 2)
        XCTAssertEqual(incoming.differences(from: current, includingDataRoot: true), 3)
    }

    // MARK: Update check (§25 silent, §27.3 status line)

    func testManualCheckFailureShowsAnErrorAutomaticStaysSilent() async throws {
        let env = try TestAppEnvironment()
        let failing = env.makeModel(updates: HTTPScript(defaultBody: nil), appVersion: "1.0")
        await failing.checkForUpdates()?.value
        XCTAssertEqual(failing.updates.status, .idle)
        await failing.checkForUpdates(manual: true)?.value
        XCTAssertEqual(failing.updates.status, .failed(.feedUnavailable))

        let (json, _) = UpdateControllerTests.feed(["1.0.0"])
        let script = HTTPScript(bodies: [1: "x"], defaultBody: json)   // first call: not JSON → error
        let model = env.makeModel(updates: script, appVersion: "1.0.0")
        await model.checkForUpdates(manual: true)?.value
        XCTAssertEqual(model.updates.status, .failed(.feedUnavailable))
        await model.checkForUpdates(manual: true)?.value   // Try Again
        XCTAssertEqual(model.updates.status, .upToDate)
    }

    // MARK: Status card content

    private func release(_ version: String, notes: String = "", size: Int = 14_050_000) -> AppRelease {
        let (base, _) = UpdateFixture.release(version, zipSize: size)
        return AppRelease(version: base.version, versionString: base.versionString, tag: base.tag,
                          pageURL: URL(string: "https://github.com/ercanatay/player-identity/releases/tag/v\(version)"),
                          notes: notes, publishedAt: nil, zip: base.zip, sums: base.sums)
    }

    func testStatusCardCoversEveryState() throws {
        let newer = release("2.5.0", notes: "## Changes\n- Faster **ban** checks\n- `FWGS` 0.21 support\n- 14 fixes\n- More")
        let update = AppUpdate(version: "2.5.0", url: try XCTUnwrap(newer.pageURL))
        func card(_ status: UpdateController.Status, update: AppUpdate? = nil, active: AppRelease? = nil,
                  lastCheck: Date? = nil) -> UpdateCardContent {
            UpdateCardContent.make(status: status, availableUpdate: update, availableRelease: update == nil ? nil : newer,
                                   activeRelease: active, lastCheck: lastCheck, appVersion: "2.4.1")
        }
        try inLanguage("en") {
            let available = card(.idle, update: update)
            XCTAssertEqual(available.title, "Version 2.5.0 is available")
            XCTAssertTrue(available.body.hasPrefix("Faster ban checks · FWGS 0.21 support · 14 fixes · "), available.body)
            XCTAssertEqual(available.actions, [.install, .releaseNotes])
            XCTAssertEqual(available.tone, .accent)

            let downloading = card(.downloading(0.62), update: update, active: newer)
            XCTAssertEqual(downloading.title, "Downloading 2.5.0…")
            XCTAssertEqual(downloading.progress ?? 0, 0.62, accuracy: 0.0001)
            XCTAssertTrue(try XCTUnwrap(downloading.percent).contains("62"))
            XCTAssertTrue(downloading.body.contains(" of "), downloading.body)
            XCTAssertEqual(downloading.actions, [.cancel])

            XCTAssertEqual(card(.upToDate).title, "Cybokron Player Identity is up to date")
            XCTAssertEqual(card(.upToDate).body, "Version 2.4.1 is the latest release.")
            XCTAssertEqual(card(.idle, lastCheck: Date()).tone, .green)
            XCTAssertEqual(card(.idle).title, "Not checked yet")

            let failed = card(.failed(.feedUnavailable))
            XCTAssertEqual(failed.title, "Couldn't check for updates")
            XCTAssertEqual(failed.actions, [.retryCheck])
            XCTAssertEqual(failed.symbol, "xmark.octagon.fill")
            XCTAssertEqual(card(.failed(.checksumMismatch), update: update).actions, [.retryInstall])
            XCTAssertEqual(card(.verifying, active: newer).actions, [.cancel])
            XCTAssertTrue(card(.installing, active: newer).isIndeterminate)
            XCTAssertEqual(card(.ready("2.5.0")).actions, [.install, .releaseNotes])
            XCTAssertEqual(card(.cancelled, update: update).actions, [.install, .releaseNotes])
            XCTAssertTrue(card(.checking).isIndeterminate)
            XCTAssertFalse(card(.backupFailed("disk full")).body.isEmpty)
        }
        try inLanguage("tr") {
            XCTAssertEqual(card(.idle, update: update).title, "2.5.0 sürümü hazır")
            XCTAssertEqual(card(.downloading(0.62), active: newer).title, "2.5.0 indiriliyor…")
            XCTAssertEqual(card(.failed(.feedUnavailable)).title, "Güncellemeler denetlenemedi")
            XCTAssertEqual(card(.upToDate).body, "2.4.1 en son sürüm.")
        }
    }

    func testNotesItemsStripMarkdownAndFallBackToTheFirstLine() {
        XCTAssertEqual(UpdateCardContent.notesItems("# Title\n* One\n+ Two", limit: 3), ["One", "Two"])
        XCTAssertEqual(UpdateCardContent.notesItems("## 2.5.0\nPlain **text** line\nsecond", limit: 1), ["Plain text line"])
        XCTAssertEqual(UpdateCardContent.notesItems("", limit: 1), [])
    }

    func testControllerTracksTheActiveRelease() async throws {
        let env = try TestAppEnvironment()
        let (json, files) = UpdateControllerTests.feed(["1.2.0"])
        let downloader = FakeUpdateDownloader(files)
        downloader.cancelOn = files.keys.first { $0.lastPathComponent.hasSuffix(".zip") }
        let model = env.makeModel(updates: HTTPScript(defaultBody: json), appVersion: "1.1.0") {
            $0.updateDownloader = downloader
            $0.appBuild = "42"
        }
        XCTAssertEqual(model.updates.appBuild, "42")
        await model.checkForUpdates()?.value
        XCTAssertEqual(model.updates.availableRelease?.versionString, "1.2.0")
        model.updates.requestInstallOfAvailableUpdate()
        await model.updates.confirmInstall()?.value
        XCTAssertEqual(model.updates.activeRelease?.versionString, "1.2.0")
        XCTAssertEqual(model.updates.status, .cancelled)
    }
}

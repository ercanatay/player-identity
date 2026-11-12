import XCTest
@testable import PlayerIdentity

/// §27/§28 in the app: feed banner, install/downgrade flow, automatic download, schedule, restore offer.
@MainActor
final class UpdateControllerTests: XCTestCase {
    private var env: TestAppEnvironment!
    private var installed: URL!

    override func setUp() async throws {
        env = try TestAppEnvironment()
        installed = try env.temp.makeDirectory("Applications").appendingPathComponent("PlayerIdentity.app", isDirectory: true)
        try UpdateFixture.makeApp(at: installed, bundleID: UpdateInstaller.bundleID, version: "1.1.0", marker: "old")
    }

    override func tearDown() async throws {
        env = nil
    }

    /// `/releases` JSON whose asset URLs match `UpdateFixture.release`.
    static func feed(_ versions: [String], zip: Data = Data("zip-bytes".utf8)) -> (String, [URL: Data]) {
        var files: [URL: Data] = [:]
        var items: [String] = []
        for version in versions {
            let (release, data) = UpdateFixture.release(version, zip: zip)
            files.merge(data) { first, _ in first }
            let zipAsset = release.zip!
            let sums = release.sums!
            items.append("""
            {"tag_name":"v\(version)","html_url":"https://github.com/ercanatay/player-identity/releases/tag/v\(version)",
             "body":"Notes for \(version)","draft":false,"prerelease":false,"published_at":"2026-11-09T07:25:00Z",
             "assets":[{"name":"\(zipAsset.name)","size":\(zipAsset.size),"browser_download_url":"\(zipAsset.downloadURL.absoluteString)"},
                       {"name":"\(sums.name)","size":\(sums.size),"browser_download_url":"\(sums.downloadURL.absoluteString)"}]}
            """)
        }
        return ("[\(items.joined(separator: ","))]", files)
    }

    private func makeModel(feed: String?, files: [URL: Data] = [:], runner: FakeUpdateRunner = FakeUpdateRunner(),
                           relauncher: FakeRelauncher = FakeRelauncher(), downloader: FakeUpdateDownloader? = nil,
                           appVersion: String = "1.1.0", feedBodies: [Int: String] = [:]) -> (AppModel, FakeUpdateDownloader) {
        let downloader = downloader ?? FakeUpdateDownloader(files)
        let clock = env.clock
        let paths = AppPaths(home: env.home)
        var deps = AppDependencies(
            paths: paths,
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: []),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: nil))),
            snapshotStore: SnapshotStore(fileURL: paths.snapshotFile),
            defaults: env.defaults,
            now: { clock.now },
            udpTransport: FakeServer.healthy(clock: clock),
            gameProcessDetector: FakeGameDetector(),
            commandRunner: FakeCommandRunner(),
            sleeper: FakeSleeper(clock: clock),
            resolver: FakeAddressResolver())
        deps.updateHTTP = ScriptedHTTPClient(script: HTTPScript(bodies: feedBodies, defaultBody: feed))
        deps.appVersion = appVersion
        deps.installedApp = installed
        deps.updateDownloader = downloader
        deps.updateRunner = runner
        deps.relauncher = relauncher
        deps.defaultsDomain = env.suiteName
        return (AppModel(dependencies: deps), downloader)
    }

    // MARK: Feed + banner + install

    func testBannerInstallFlowFromTheFeed() async throws {
        let (json, files) = Self.feed(["1.2.0", "1.1.0", "1.0.0"])
        let relauncher = FakeRelauncher()
        let (model, _) = makeModel(feed: json, files: files, relauncher: relauncher)
        await model.checkForUpdates()?.value
        XCTAssertEqual(model.availableUpdate?.version, "1.2.0")
        XCTAssertEqual(model.updates.history.map(\.versionString), ["1.2.0", "1.1.0", "1.0.0"])

        XCTAssertNil(model.updates.requestInstallOfAvailableUpdate())
        let request = try XCTUnwrap(model.updates.pendingInstall)
        XCTAssertEqual(request.change, .upgrade)
        XCTAssertEqual(request.origin, .banner)
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old")   // nothing before confirmation

        await model.updates.confirmInstall()?.value
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
        XCTAssertEqual(relauncher.relaunched, [installed])
        XCTAssertEqual(model.updates.status, .relaunching)
        XCTAssertEqual(model.updates.dataBackupCount, 0)   // upgrades do not back up data
    }

    func testInstallFailureIsShownAndNothingChanges() async throws {
        let (json, _) = Self.feed(["1.2.0"])
        var (_, files) = Self.feed(["1.2.0"])
        let zipURL = try XCTUnwrap(files.keys.first { $0.lastPathComponent.hasSuffix(".zip") })
        files[zipURL] = Data("tampered!".utf8)   // same size, different hash
        let (model, _) = makeModel(feed: json, files: files)
        await model.checkForUpdates()?.value
        model.updates.requestInstallOfAvailableUpdate()
        await model.updates.confirmInstall()?.value
        XCTAssertEqual(model.updates.status, .failed(.checksumMismatch))
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old")
        XCTAssertEqual(UpdateStatusText.text(model.updates.status), UpdateStatusText.error(.checksumMismatch))
    }

    // MARK: Downgrade (§28)

    func testDowngradeBacksUpDataFirstByDefault() async throws {
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", #"{"schemaVersion":1}"#)
        let (json, files) = Self.feed(["1.1.0", "1.0.0"])
        let runner = FakeUpdateRunner()
        runner.appVersion = "1.0.0"
        let (model, _) = makeModel(feed: json, files: files, runner: runner)
        await model.checkForUpdates(manual: true)?.value
        let older = try XCTUnwrap(model.updates.history.first { $0.versionString == "1.0.0" })
        let current = try XCTUnwrap(model.updates.history.first { $0.versionString == "1.1.0" })

        model.updates.request(current)
        XCTAssertNil(model.updates.pendingInstall)   // same version: disabled

        model.updates.request(older)
        XCTAssertEqual(model.updates.pendingInstall?.change, .downgrade)
        XCTAssertEqual(model.updates.pendingInstall?.backupData, true)
        await model.updates.confirmInstall()?.value
        XCTAssertEqual(model.updates.dataBackupCount, 1)
        let backup = try XCTUnwrap(DataBackupStore(paths: AppPaths(home: env.home), defaultsDomain: env.suiteName).list().first)
        XCTAssertEqual(backup.info.fromVersion, "1.1.0")
        XCTAssertEqual(backup.info.toVersion, "1.0.0")
        XCTAssertEqual(backup.info.schemaVersion, 1)
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
    }

    func testDowngradeWithoutBackupAndUninstallableRelease() async throws {
        let (json, files) = Self.feed(["1.1.0", "1.0.0"])
        let runner = FakeUpdateRunner()
        runner.appVersion = "1.0.0"
        let (model, _) = makeModel(feed: json, files: files, runner: runner)
        await model.checkForUpdates(manual: true)?.value
        model.updates.request(try XCTUnwrap(model.updates.history.last))
        model.updates.pendingInstall?.backupData = false
        await model.updates.confirmInstall()?.value
        XCTAssertEqual(model.updates.dataBackupCount, 0)

        let bare = AppRelease(version: SemanticVersion("0.9.0")!, versionString: "0.9.0", tag: "v0.9.0", pageURL: nil,
                              notes: "", publishedAt: nil, zip: nil, sums: nil)
        model.updates.request(bare)
        XCTAssertNil(model.updates.pendingInstall)
        XCTAssertEqual(model.updates.status, .failed(.missingAsset))
    }

    // MARK: Automatic download (off by default)

    func testAutomaticDownloadPreparesButNeverInstalls() async throws {
        let (json, files) = Self.feed(["1.2.0"])
        let relauncher = FakeRelauncher()
        let (model, downloader) = makeModel(feed: json, files: files, relauncher: relauncher)
        XCTAssertFalse(model.updates.preferences.autoDownload)
        XCTAssertTrue(model.updates.preferences.autoCheck)
        model.updates.preferences.autoDownload = true
        XCTAssertEqual(UpdatePreferences(defaults: env.defaults).autoDownload, true)

        await model.checkForUpdates()?.value
        await model.updates.waitForTasks()
        XCTAssertEqual(model.updates.status, .ready("1.2.0"))
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old")
        XCTAssertEqual(relauncher.relaunched, [])
        let downloads = downloader.requestedURLs.count

        model.updates.requestInstallOfAvailableUpdate()
        await model.updates.confirmInstall()?.value
        XCTAssertEqual(downloader.requestedURLs.count, downloads)   // installed from the prepared download
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
    }

    func testNoDownloadWithoutAutomaticDownload() async throws {
        let (json, files) = Self.feed(["1.2.0"])
        let (model, downloader) = makeModel(feed: json, files: files)
        await model.checkForUpdates()?.value
        await model.updates.waitForTasks()
        XCTAssertEqual(downloader.requestedURLs, [])
        XCTAssertEqual(model.updates.status, .idle)
    }

    func testCancelDuringDownload() async throws {
        let (json, files) = Self.feed(["1.2.0"])
        let downloader = FakeUpdateDownloader(files)
        downloader.cancelOn = files.keys.first { $0.lastPathComponent.hasSuffix(".zip") }
        let (model, _) = makeModel(feed: json, downloader: downloader)
        await model.checkForUpdates()?.value
        model.updates.requestInstallOfAvailableUpdate()
        await model.updates.confirmInstall()?.value
        XCTAssertEqual(model.updates.status, .cancelled)
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old")
    }

    // MARK: Schedule (§27.2)

    func testAutomaticChecksOffAndPeriodicCounter() async throws {
        let (json, files) = Self.feed(["1.2.0"])
        let (model, _) = makeModel(feed: json, files: files)
        model.updates.preferences.autoCheck = false
        XCTAssertNil(model.checkForUpdates())                       // launch check skipped
        await model.checkForUpdates(manual: true)?.value            // manual still works
        XCTAssertEqual(model.availableUpdate?.version, "1.2.0")
        model.updates.preferences.autoCheck = true

        env.clock.advance(5 * 3600)
        XCTAssertEqual(model.updates.runPeriodicCheckIfDue(), 3600, accuracy: 1)   // not yet: 1 h left
        env.clock.advance(3600)
        let before = model.updates.lastCheck
        XCTAssertEqual(model.updates.runPeriodicCheckIfDue(), UpdateSchedule.periodicInterval)
        await model.updates.waitForTasks()
        XCTAssertGreaterThan(try XCTUnwrap(model.updates.lastCheck), try XCTUnwrap(before))
        XCTAssertNil(model.checkForUpdates())                       // launch counter is still 24 h
    }

    func testSettingsCheckShowsStatusInsteadOfAlert() async throws {
        let (json, files) = Self.feed(["1.1.0"])
        let (model, _) = makeModel(feed: json, files: files)
        await model.updates.checkForUpdates(manual: true)?.value
        XCTAssertEqual(model.updates.status, .upToDate)
        XCTAssertNil(model.availableUpdate)
    }

    // MARK: Restore offer (§28.2/5)

    func testRestoreBannerAppearsForAnUnsupportedSchemaAndRestores() async throws {
        let paths = AppPaths(home: env.home)
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json",
                           #"{"schemaVersion":1,"gamedir":"valve"}"#)
        let store = DataBackupStore(paths: paths, defaultsDomain: env.suiteName)
        try store.create(from: "1.1.0", to: "2.0.0", now: env.clock.now, defaults: env.defaults)
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", #"{"schemaVersion":2}"#)

        let relauncher = FakeRelauncher()
        let (model, _) = makeModel(feed: nil, relauncher: relauncher)
        XCTAssertEqual(model.snapshotState, .unsupportedSchema(2))
        XCTAssertNotNil(model.updates.restoreOffer)

        await model.updates.confirmRestore()?.value
        XCTAssertEqual(DataBackupStore.schemaVersion(try Data(contentsOf: paths.snapshotFile)), 1)
        XCTAssertEqual(relauncher.relaunched, [installed])
        XCTAssertNil(model.updates.restoreOffer)
        XCTAssertEqual(model.updates.dataBackupCount, 2)   // + the safety backup of the current data

        model.updates.removeDataBackups()
        XCTAssertEqual(model.updates.dataBackupCount, 0)
    }

    func testFailedRelaunchAfterRestoreKeepsTheBannerWithALocalizedErrorAndARelaunchAction() async throws {
        let paths = AppPaths(home: env.home)
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json",
                           #"{"schemaVersion":1,"gamedir":"valve"}"#)
        let store = DataBackupStore(paths: paths, defaultsDomain: env.suiteName)
        try store.create(from: "1.1.0", to: "2.0.0", now: env.clock.now, defaults: env.defaults)
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", #"{"schemaVersion":2}"#)

        let relauncher = FakeRelauncher()
        relauncher.fails = true
        let (model, _) = makeModel(feed: nil, relauncher: relauncher)
        let updates = model.updates
        XCTAssertNotNil(updates.restoreOffer)

        await updates.confirmRestore()?.value
        XCTAssertEqual(DataBackupStore.schemaVersion(try Data(contentsOf: paths.snapshotFile)), 1)   // files are back
        XCTAssertNotNil(updates.restoreOffer, "the banner stays until the relaunch worked")
        XCTAssertTrue(updates.restoredAwaitingRelaunch)
        let backupsAfterRestore = updates.dataBackupCount
        let expected = UpdateStatusText.error(.installFailed(rolledBack: false, backup: nil))
        XCTAssertEqual(updates.restoreError, expected, "localized, not String(describing:)")
        XCTAssertFalse(try XCTUnwrap(updates.restoreError).contains("installFailed"))
        let backup = try XCTUnwrap(updates.restoreOffer)
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(RestoreBanner.title(updates, backup: backup), L10n.text(.restoreRestoredRelaunch))
            XCTAssertTrue(try XCTUnwrap(RestoreBanner.errorText(updates)).hasPrefix("Uygulama yeniden başlatılamadı: "))
            XCTAssertEqual(L10n.text(.restoreRelaunch), "Yeniden başlat")
        }
        // A model reload does not take the offer away while the relaunch is pending.
        updates.evaluateRestore(snapshot: .missing)
        XCTAssertNotNil(updates.restoreOffer)

        // "Relaunch" again: the stale error is cleared, the data is not restored a second time.
        relauncher.fails = false
        await updates.relaunchAfterRestore()?.value
        XCTAssertNil(updates.restoreError)
        XCTAssertNil(updates.restoreOffer)
        XCTAssertFalse(updates.restoredAwaitingRelaunch)
        XCTAssertEqual(relauncher.relaunched, [installed, installed])
        XCTAssertEqual(updates.dataBackupCount, backupsAfterRestore, "no second safety backup")
        XCTAssertNil(updates.relaunchAfterRestore())
    }

    func testRestoreErrorTextsAreLocalized() throws {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(UpdateController.errorText(UpdateError.notWritable), L10n.text(.updateErrorNotWritable))
            XCTAssertEqual(UpdateController.errorText(FullBackupError.busy), L10n.text(.restoreErrorBusy))
            let cocoa = CocoaError(.fileWriteNoPermission)
            XCTAssertEqual(UpdateController.errorText(cocoa), cocoa.localizedDescription)
        }
    }

    func testNoRestoreBannerForReadableRecord() throws {
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", #"{"schemaVersion":1}"#)
        let (model, _) = makeModel(feed: nil)
        XCTAssertNil(model.updates.restoreOffer)
    }

    // MARK: Texts

    func testStatusTextsInBothLanguages() throws {
        let statuses: [UpdateController.Status] = [.checking, .upToDate, .downloading(0.42), .verifying, .ready("1.2.0"),
                                                    .installing, .relaunching, .cancelled, .backupFailed("x")]
        let errors: [UpdateError] = [.feedUnavailable, .insecureURL, .missingAsset, .sameVersion, .downloadFailed,
                                     .sizeMismatch(expected: 1, actual: 2), .checksumMissing, .checksumMismatch, .unzipFailed,
                                     .appMissing, .signatureInvalid, .teamMismatch(found: nil), .bundleMismatch(found: nil),
                                     .versionMismatch(found: nil), .notWritable, .installFailed(rolledBack: true, backup: nil),
                                     .installFailed(rolledBack: false, backup: URL(fileURLWithPath: "/b/PlayerIdentity-1.1.0.app")),
                                     .cancelled]
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                XCTAssertNil(UpdateStatusText.text(.idle))
                for status in statuses { XCTAssertFalse((UpdateStatusText.text(status) ?? "").isEmpty, "\(language) \(status)") }
                for error in errors { XCTAssertFalse(UpdateStatusText.error(error).isEmpty, "\(language) \(error)") }
                XCTAssertTrue(UpdateStatusText.error(.installFailed(rolledBack: false,
                                                                    backup: URL(fileURLWithPath: "/b/PlayerIdentity-1.1.0.app")))
                                .contains("/b/PlayerIdentity-1.1.0.app"))
            }
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(L10n.text(.updateInstall), "Yükle")
            XCTAssertEqual(L10n.text(.updateCheckNow), "Şimdi denetle")
            XCTAssertEqual(L10n.text(.updateDowngrade), "Bu sürüme dön")
            XCTAssertEqual(L10n.text(.updateConfirmBackupData), "Önce veriyi yedekle")
            XCTAssertEqual(L10n.text(.restoreAction), "Yedekten geri yükle")
            XCTAssertEqual(L10n.text(.updateHistory), "Sürüm geçmişi")
        }
        XCTAssertTrue(UpdateStatusText.percent(0.42).contains("42"))
    }
}

// MARK: - Hardening: the pre-update backup runs in the background

extension UpdateControllerTests {
    func testPreUpdateBackupRunsInTheBackgroundAndAFailureStopsTheInstall() async throws {
        let paths = AppPaths(home: env.home)
        // `backups` is a file: the pre-update backup cannot be written.
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/backups", "not a folder")
        let (json, files) = Self.feed(["1.2.0", "1.1.0"])
        let (model, downloader) = makeModel(feed: json, files: files)
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        XCTAssertNil(model.saveErrorMessage)
        await model.checkForUpdates()?.value
        model.updates.requestInstallOfAvailableUpdate()

        let failed = try XCTUnwrap(model.updates.confirmInstall())
        // Returned at once: the backup is written off the main thread while the status says so.
        XCTAssertEqual(model.updates.status, .backingUp)
        XCTAssertTrue(model.updates.status.isUpdating)
        XCTAssertFalse(model.updates.status.isCancellable)
        XCTAssertNil(model.updates.confirmInstall(), "no second install while backing up")
        let restore = await model.restoreFullBackup(ParsedFullBackup(manifest: FullBackupManifest(
            appVersion: "1.1.0", createdAt: Date(), kind: .manual, counts: .init(), files: [], contentSHA256: ""),
            files: [:], counts: .init(), recordSavedAt: nil))
        XCTAssertEqual(restore, .failure(.updateRunning))
        await failed.value
        guard case .backupFailed(let reason) = model.updates.status else { return XCTFail("\(model.updates.status)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(downloader.requestedURLs, [], "nothing was downloaded")
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old")

        // With a writable folder the same install backs up first, then installs.
        try FileManager.default.removeItem(at: paths.fullBackups)
        model.updates.requestInstallOfAvailableUpdate()
        let install = try XCTUnwrap(model.updates.confirmInstall())
        XCTAssertEqual(model.updates.status, .backingUp)
        await install.value
        XCTAssertEqual(FullBackupStore(paths: paths, appVersion: "1.1.0").list(.preUpdate).count, 1)
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
    }
}

// MARK: - Hardening: blocked confirmation, stale prepared downloads, background data backup

extension UpdateControllerTests {
    private func leftovers(_ paths: AppPaths) -> [String] {
        let downloads = (try? FileManager.default.contentsOfDirectory(atPath: paths.updateDownloads.path)) ?? []
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: paths.updateStaging.path)) ?? []
        return (downloads + staging).sorted()
    }

    func testConfirmWhileADataOperationRunsKeepsTheSheetWithAReason() async throws {
        let (json, files) = Self.feed(["1.2.0", "1.1.0"])
        let (model, downloader) = makeModel(feed: json, files: files)
        await model.checkForUpdates()?.value
        model.updates.requestInstallOfAvailableUpdate()
        XCTAssertNil(model.updates.installBlockedReason)

        XCTAssertTrue(model.beginDataOperation(.restore))
        XCTAssertNil(model.updates.confirmInstall())
        XCTAssertNotNil(model.updates.pendingInstall, "the sheet stays open instead of silently doing nothing")
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(model.updates.installBlockedReason, L10n.text(.updateConfirmBlockedData))
            XCTAssertTrue(try XCTUnwrap(model.updates.installBlockedReason).hasPrefix("Bir veri işlemi"))
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertTrue(try XCTUnwrap(model.updates.installBlockedReason).hasPrefix("Can't install"))
            XCTAssertFalse(L10n.text(.updateConfirmBlockedBusy).isEmpty)
        }
        XCTAssertEqual(downloader.requestedURLs, [])
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old")

        model.endDataOperation()
        XCTAssertNil(model.updates.installBlockedReason)
        let install = try XCTUnwrap(model.updates.confirmInstall())
        XCTAssertNil(model.updates.pendingInstall)
        // While backing up another confirmation is blocked by the running update.
        model.updates.request(try XCTUnwrap(model.updates.availableRelease))
        XCTAssertEqual(model.updates.installBlockedReason, L10n.text(.updateConfirmBlockedBusy))
        XCTAssertNil(model.updates.confirmInstall())
        model.updates.cancelRequest()
        await install.value
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
    }

    func testAPreparedDownloadForAnotherReleaseIsRemovedAndTheDowngradeBacksUpTheDefaults() async throws {
        let paths = AppPaths(home: env.home)
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", #"{"schemaVersion":1}"#)
        env.defaults.set("marker-value", forKey: "hardeningMarker")
        let (json, files) = Self.feed(["1.2.0", "1.1.0", "1.0.0"])
        let runner = FakeUpdateRunner()
        let (model, _) = makeModel(feed: json, files: files, runner: runner)
        model.updates.preferences.autoDownload = true
        await model.checkForUpdates()?.value
        await model.updates.waitForTasks()
        XCTAssertEqual(model.updates.status, .ready("1.2.0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.updateStaging.appendingPathComponent("1.2.0").path))
        XCTAssertFalse(leftovers(paths).isEmpty)

        // Revert to 1.0.0 instead: the 1.2.0 download is not used and must not stay on disk.
        runner.appVersion = "1.0.0"
        model.updates.request(try XCTUnwrap(model.updates.history.first { $0.versionString == "1.0.0" }))
        XCTAssertEqual(model.updates.pendingInstall?.change, .downgrade)
        await model.updates.confirmInstall()?.value
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")
        XCTAssertEqual(leftovers(paths), [], "no downloads or staged apps are left behind")

        // The small data backup (preferences read on the main actor, written in the background) is complete.
        let backup = try XCTUnwrap(DataBackupStore(paths: paths, defaultsDomain: env.suiteName).list().first)
        XCTAssertEqual(backup.info.toVersion, "1.0.0")
        XCTAssertEqual(backup.info.schemaVersion, 1)
        XCTAssertTrue(Set(backup.info.files).isSuperset(of: [DataBackupStore.profileFile, DataBackupStore.defaultsFile]))
        let plist = try Data(contentsOf: backup.directory.appendingPathComponent(DataBackupStore.defaultsFile))
        let domain = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(domain["hardeningMarker"] as? String, "marker-value")
        XCTAssertEqual(model.updates.dataBackupCount, 1)
    }

    func testANewerAutomaticDownloadReplacesTheOlderPreparedOne() async throws {
        let paths = AppPaths(home: env.home)
        let (first, firstFiles) = Self.feed(["1.2.0", "1.1.0"])
        let (second, secondFiles) = Self.feed(["1.3.0", "1.2.0", "1.1.0"])
        let runner = FakeUpdateRunner()
        let (model, _) = makeModel(feed: second, files: firstFiles.merging(secondFiles) { a, _ in a }, runner: runner,
                                   feedBodies: [1: first])
        model.updates.preferences.autoDownload = true
        await model.checkForUpdates()?.value
        await model.updates.waitForTasks()
        XCTAssertEqual(model.updates.status, .ready("1.2.0"))
        let oldStaging = paths.updateStaging.appendingPathComponent("1.2.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldStaging.path))

        // The next check finds 1.3.0: the unused 1.2.0 files are removed before the new download starts.
        runner.appVersion = "1.3.0"
        await model.checkForUpdates(manual: true)?.value
        await model.updates.waitForTasks()
        XCTAssertEqual(model.updates.status, .ready("1.3.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.updateDownloads.appendingPathComponent(AppRelease.zipName(version: "1.2.0")).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.updateStaging.appendingPathComponent("1.3.0").path))
    }

    func testDataBackupFromExportedDefaultsWorksOffTheMainThread() async throws {
        let paths = AppPaths(home: env.home)
        env.defaults.set(42, forKey: "offMainMarker")
        let store = DataBackupStore(paths: paths, defaultsDomain: env.suiteName)
        let plist = try DataBackupStore.defaultsPlist(env.defaults, domain: env.suiteName)
        let now = env.clock.now
        let (onMain, backup) = try await Task.detached { () throws -> (Bool, DataBackup) in
            (isMainThread(), try store.create(from: "1.1.0", to: "1.0.0", now: now, defaultsPlist: plist))
        }.value
        XCTAssertFalse(onMain)
        XCTAssertEqual(backup.info.files, [DataBackupStore.defaultsFile])
        let written = try Data(contentsOf: backup.directory.appendingPathComponent(DataBackupStore.defaultsFile))
        XCTAssertEqual(written, plist)
        // Same content as the UserDefaults overload.
        let direct = try store.create(from: "1.1.0", to: "0.9.0", now: now, defaults: env.defaults)
        XCTAssertEqual(try Data(contentsOf: direct.directory.appendingPathComponent(DataBackupStore.defaultsFile)), plist)
    }
}

/// `Thread.isMainThread` is unavailable in async contexts; a synchronous helper reads it.
private func isMainThread() -> Bool { Thread.isMainThread }

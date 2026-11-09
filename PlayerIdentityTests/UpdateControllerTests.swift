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
                           appVersion: String = "1.1.0") -> (AppModel, FakeUpdateDownloader) {
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
        deps.updateHTTP = ScriptedHTTPClient(script: HTTPScript(defaultBody: feed))
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
        await model.updates.checkForUpdates(manual: true, announce: false)?.value
        XCTAssertFalse(model.manualCheckUpToDate)
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

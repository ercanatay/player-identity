import XCTest
@testable import PlayerIdentity

/// §28.4: older versions in the feed, downgrade choice, data backup content, schema-mismatch restore,
/// same-version refusal, signature/team errors, pruning to 10 backups.
final class DowngradeTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: AppPaths!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    override func setUp() async throws {
        temp = try TempDirectory()
        paths = AppPaths(home: try temp.makeDirectory("home"))
        suiteName = "PlayerIdentityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set("/root", forKey: DefaultsKey.dataRoot)
        defaults.set(["A", "B"], forKey: DefaultsKey.recentNames)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        temp = nil
    }

    private var store: DataBackupStore { DataBackupStore(paths: paths, defaultsDomain: suiteName) }

    private func writeData(schema: Int = 1, history: String = "{\"kind\":\"apply\",\"ts\":\"2026-11-09T07:00:00Z\"}\n") throws {
        try FileManager.default.createDirectory(at: paths.snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":\(schema),\"gamedir\":\"valve\"}".utf8).write(to: paths.snapshotFile)
        try Data(history.utf8).write(to: paths.historyFile)
    }

    // MARK: Choice

    func testOlderStableVersionsAreDowngradeCandidates() {
        let releases = ["1.3.0", "1.2.0", "1.1.0", "1.0.0"].map { UpdateFixture.release($0).0 }
        XCTAssertEqual(DowngradePlanner.candidates(in: releases, currentVersion: "1.2.0").map(\.versionString), ["1.1.0", "1.0.0"])
        XCTAssertEqual(DowngradePlanner.change(to: releases[2], currentVersion: "1.2.0"), .downgrade)
        XCTAssertEqual(DowngradePlanner.change(to: releases[0], currentVersion: "1.2.0"), .upgrade)
        XCTAssertNil(DowngradePlanner.change(to: releases[1], currentVersion: "1.2.0"))   // same version: disabled
        XCTAssertEqual(DowngradePlanner.candidates(in: releases, currentVersion: "x"), [])
    }

    func testDowngradeInstallChecksTheTargetVersionAndRefusesTheSameVersion() async throws {
        let installed = try temp.makeDirectory("Applications").appendingPathComponent("PlayerIdentity.app", isDirectory: true)
        try UpdateFixture.makeApp(at: installed, bundleID: UpdateInstaller.bundleID, version: "1.2.0", marker: "new")
        func installer(_ files: [URL: Data], runner: FakeUpdateRunner) -> UpdateInstaller {
            UpdateInstaller(paths: paths, installedApp: installed, currentVersion: "1.2.0", downloader: FakeUpdateDownloader(files),
                            fileManager: LocalUpdateFileManager(), runner: runner, relauncher: FakeRelauncher())
        }

        let (older, files) = UpdateFixture.release("1.1.0")
        let wrongTeam = FakeUpdateRunner()
        wrongTeam.appVersion = "1.1.0"
        wrongTeam.teamID = nil   // e.g. an old ad-hoc build
        do {
            _ = try await installer(files, runner: wrongTeam).install(older)
            XCTFail("expected a team error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .teamMismatch(found: "not set"))
        }
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")

        let mismatch = FakeUpdateRunner()
        mismatch.appVersion = "1.2.0"   // the zip contains a different version than the chosen target
        do {
            _ = try await installer(files, runner: mismatch).install(older)
            XCTFail("expected a version error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .versionMismatch(found: "1.2.0"))
        }

        let ok = FakeUpdateRunner()
        ok.appVersion = "1.1.0"
        let result = try await installer(files, runner: ok).install(older)
        XCTAssertEqual(result.version, "1.1.0")
        XCTAssertEqual(UpdateFixture.marker(of: installed), "new")   // fixture marker of the unzipped app
        XCTAssertEqual(result.backup.lastPathComponent, "PlayerIdentity-1.2.0.app")

        let (same, sameFiles) = UpdateFixture.release("1.2.0")
        do {
            _ = try await installer(sameFiles, runner: FakeUpdateRunner()).install(same)
            XCTFail("expected same-version refusal")
        } catch {
            XCTAssertEqual(error as? UpdateError, .sameVersion)
        }
    }

    // MARK: Data backup

    func testDataBackupContents() throws {
        try writeData()
        let backup = try store.create(from: "1.2.0", to: "1.1.0", now: t0, defaults: defaults)
        XCTAssertEqual(backup.directory.lastPathComponent, "data-1.2.0-to-1.1.0-20261026T073320Z")
        XCTAssertEqual(backup.directory.deletingLastPathComponent(), paths.dataBackups)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: backup.directory.path))
        XCTAssertEqual(names, ["profile.json", "history.jsonl", "defaults.plist", "snapshot-info.json"])
        XCTAssertEqual(try Data(contentsOf: backup.directory.appendingPathComponent("profile.json")),
                       try Data(contentsOf: paths.snapshotFile))
        let plist = try Data(contentsOf: backup.directory.appendingPathComponent("defaults.plist"))
        let domain = try XCTUnwrap(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(domain[DefaultsKey.dataRoot] as? String, "/root")
        XCTAssertEqual(domain[DefaultsKey.recentNames] as? [String], ["A", "B"])
        XCTAssertEqual(backup.info, DataBackupInfo(fromVersion: "1.2.0", toVersion: "1.1.0", createdAt: t0, schemaVersion: 1,
                                                   files: ["profile.json", "history.jsonl", "defaults.plist"], bundleID: suiteName))
        XCTAssertEqual(store.list(), [backup])
    }

    func testBackupWithoutDataStillExportsDefaults() throws {
        let backup = try store.create(from: "1.2.0", to: "1.1.0", now: t0, defaults: defaults)
        XCTAssertEqual(backup.info.files, ["defaults.plist"])
        XCTAssertNil(backup.info.schemaVersion)
    }

    func testPruneKeepsTenNewestAndRemoveAll() throws {
        try writeData()
        for index in 0..<12 {
            try store.create(from: "1.2.0", to: "1.\(index).0", now: t0.addingTimeInterval(Double(index) * 60), defaults: defaults)
        }
        let kept = store.list()
        XCTAssertEqual(kept.count, 10)
        XCTAssertEqual(kept.first?.info.toVersion, "1.11.0")
        XCTAssertEqual(kept.last?.info.toVersion, "1.2.0")   // 1.0.0 and 1.1.0 (oldest) were removed
        try store.removeAll()
        XCTAssertEqual(store.list(), [])
    }

    // MARK: Schema mismatch → restore

    func testRestoreIsOfferedOnlyForAnUnsupportedSchema() throws {
        try writeData(schema: 1)
        let compatible = try store.create(from: "1.1.0", to: "2.0.0", now: t0, defaults: defaults)
        try writeData(schema: 2)
        let newer = try store.create(from: "2.0.0", to: "1.1.0", now: t0.addingTimeInterval(60), defaults: defaults)
        let backups = store.list()
        XCTAssertEqual(backups.map(\.info.schemaVersion), [2, 1])

        XCTAssertEqual(RestoreAdvisor.backupToOffer(snapshot: .unsupportedSchema(2), backups: backups), compatible)
        XCTAssertNil(RestoreAdvisor.backupToOffer(snapshot: .loaded(Snapshot(savedAt: t0, gamedir: "", dataRoot: "", displayName: "",
                                                                            model: "", rawID: "", identitySource: "",
                                                                            network: NetworkInfo(publicIP: "", lanIPs: []),
                                                                            servers: [])), backups: backups))
        XCTAssertNil(RestoreAdvisor.backupToOffer(snapshot: .missing, backups: backups))
        XCTAssertNil(RestoreAdvisor.backupToOffer(snapshot: .unsupportedSchema(2), backups: [newer]))
    }

    func testRestorePutsFilesBackAndBacksUpTheCurrentDataFirst() throws {
        try writeData(schema: 1, history: "old-history\n")
        let backup = try store.create(from: "1.1.0", to: "2.0.0", now: t0, defaults: defaults)
        // The newer version rewrote the data.
        try writeData(schema: 2, history: "new-history\n")
        defaults.set("/changed", forKey: DefaultsKey.dataRoot)

        let safety = try store.restore(backup, currentVersion: "1.1.0", now: t0.addingTimeInterval(120), defaults: defaults)
        XCTAssertEqual(DataBackupStore.schemaVersion(try Data(contentsOf: paths.snapshotFile)), 1)
        XCTAssertEqual(try String(contentsOf: paths.historyFile, encoding: .utf8), "old-history\n")
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.dataRoot), "/root")
        XCTAssertEqual(safety.info.toVersion, "restore")
        XCTAssertEqual(safety.info.schemaVersion, 2)
        XCTAssertEqual(try String(contentsOf: safety.directory.appendingPathComponent("history.jsonl"), encoding: .utf8),
                       "new-history\n")
    }
}

// MARK: - §58.2 Partial data backups

extension DowngradeTests {
    /// Makes `url` unreadable for the test; the permissions are restored by the returned closure.
    private func makeUnreadable(_ url: URL) throws -> () -> Void {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    }

    func testAnUnreadableFileMakesThePartialBackupWithCountAndRedactedPath() throws {
        try writeData()
        let restore = try makeUnreadable(paths.historyFile)
        defer { restore() }
        let backup = try store.create(from: "1.2.0", to: "1.1.0", now: t0, defaults: defaults)
        XCTAssertTrue(backup.info.isPartial)
        XCTAssertEqual(backup.info.partial, true)
        XCTAssertEqual(backup.info.skippedCount, 1)
        XCTAssertEqual(backup.info.files, ["profile.json", "defaults.plist"])
        let item = try XCTUnwrap(backup.info.skipped?.first)
        XCTAssertEqual(item.file, "history.jsonl")
        XCTAssertEqual(item.reason, .unreadable)
        XCTAssertEqual(item.path, "~/Library/Application Support/tr.ercanatay.playeridentity/history.jsonl")
        XCTAssertFalse(item.path.contains(paths.home.path), "home folder is redacted")
        XCTAssertEqual(backup.skipReport.skippedCount, 1)
        XCTAssertEqual(backup.skipReport.items, [item])
        // Written to snapshot-info.json and read back by `list`.
        XCTAssertEqual(store.list().first?.info, backup.info)
        let json = try String(contentsOf: backup.directory.appendingPathComponent("snapshot-info.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"partial\" : true"), json)
        XCTAssertTrue(json.contains("\"skippedCount\" : 1"), json)

        // A complete backup carries no partial fields.
        restore()
        let complete = try store.create(from: "1.2.0", to: "1.1.0", now: t0.addingTimeInterval(60), defaults: defaults)
        XCTAssertFalse(complete.info.isPartial)
        XCTAssertNil(complete.info.partial)
        XCTAssertNil(complete.info.skipped)
        XCTAssertFalse(complete.skipReport.isPartial)
    }

    func testRestoringAPartialBackupKeepsTheFileItCouldNotBackUp() throws {
        try writeData()
        let restore = try makeUnreadable(paths.historyFile)
        let backup = try store.create(from: "1.2.0", to: "1.1.0", now: t0, defaults: defaults)
        restore()
        let current = try Data(contentsOf: paths.historyFile)
        try store.restore(backup, currentVersion: "1.1.0", now: t0.addingTimeInterval(60), defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: paths.historyFile), current, "the skipped file is not removed")
    }

    func testPartialBackupsArePrunedFirstAndTheNewOneIsKept() throws {
        try writeData()
        // Two partial backups (oldest and in the middle), then complete ones up to the limit.
        let restore = try makeUnreadable(paths.historyFile)
        try store.create(from: "1.2.0", to: "0.0.1", now: t0, defaults: defaults)
        restore()
        for index in 1...4 {
            try store.create(from: "1.2.0", to: "1.\(index).0", now: t0.addingTimeInterval(Double(index) * 60), defaults: defaults)
        }
        let restoreAgain = try makeUnreadable(paths.historyFile)
        try store.create(from: "1.2.0", to: "0.0.2", now: t0.addingTimeInterval(300), defaults: defaults)
        restoreAgain()
        for index in 6...9 {
            try store.create(from: "1.2.0", to: "1.\(index).0", now: t0.addingTimeInterval(Double(index) * 60), defaults: defaults)
        }
        XCTAssertEqual(store.list().count, 10)
        // One more complete backup: the partial ones go first, not the oldest complete one.
        try store.create(from: "1.2.0", to: "1.10.0", now: t0.addingTimeInterval(600), defaults: defaults)
        var versions = store.list().map(\.info.toVersion)
        XCTAssertEqual(versions.count, 10)
        XCTAssertFalse(versions.contains("0.0.1"))
        XCTAssertTrue(versions.contains("0.0.2"))
        XCTAssertTrue(versions.contains("1.1.0"))
        try store.create(from: "1.2.0", to: "1.11.0", now: t0.addingTimeInterval(660), defaults: defaults)
        versions = store.list().map(\.info.toVersion)
        XCTAssertFalse(versions.contains("0.0.2"))
        XCTAssertTrue(versions.contains("1.1.0"))
        // A new partial backup is never pruned itself, even with only partial candidates left to remove.
        let restoreLast = try makeUnreadable(paths.historyFile)
        defer { restoreLast() }
        let newest = try store.create(from: "1.2.0", to: "0.0.3", now: t0.addingTimeInterval(720), defaults: defaults)
        XCTAssertTrue(store.list().map(\.directory).contains(newest.directory))
        XCTAssertEqual(store.list().count, 10)
        XCTAssertFalse(store.list().map(\.info.toVersion).contains("1.1.0"))   // then the oldest complete one
    }

    func testSkipReportCountsEachFileOnceAndListsAtMostFive() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        var report = BackupSkipReport()
        for index in 0..<7 {
            report.add(file: "f\(index)", at: home.appendingPathComponent("data/f\(index)"), reason: .unreadable, home: home)
        }
        report.add(file: "f0", at: home.appendingPathComponent("data/f0"), reason: .unreadable, home: home)
        XCTAssertEqual(report.skippedCount, 7)
        XCTAssertEqual(report.items.count, BackupSkipReport.listedLimit)
        XCTAssertEqual(report.items.first?.path, "~/data/f0")
        var other = BackupSkipReport()
        other.add(file: "f1", at: home.appendingPathComponent("data/f1"), reason: .unreadable, home: home)
        other.add(file: "g", at: home.appendingPathComponent("data/g"), reason: .unreadable, home: home)
        report.merge(other)
        XCTAssertEqual(report.skippedCount, 8)
        XCTAssertEqual(report.items.count, 5)
    }
}

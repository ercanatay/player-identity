import XCTest
@testable import PlayerIdentity

/// §49 full data backup / restore and automatic backups. Everything runs on temporary homes; no network.
@MainActor
final class FullBackupTests: XCTestCase {
    private static let allNames = [FullBackupManifest.fileName] + FullBackupFile.allCases.map(\.rawValue)

    override func tearDown() async throws {
        L10n.setting = .system
    }

    // MARK: Fixtures

    /// Writes a record with `servers` servers, history, metrics and (optionally) a watch state into `paths`.
    @discardableResult
    private func seed(_ paths: AppPaths, servers: Int = 2, history: Int = 3, metrics: Int = 4, watch: Bool = true,
                      now: Date = Date(timeIntervalSince1970: 1_793_000_000)) throws -> [ServerEntry] {
        let entries = (0..<servers).map { ServerEntry(label: "Server \($0)", host: "192.0.2.\(20 + $0)", watch: $0 == 0) }
        let snapshot = Snapshot(savedAt: now, gamedir: "valve", dataRoot: paths.defaultDataRoot.path, displayName: "N",
                                model: "gordon", rawID: "0", identitySource: "~/.config/.xash_id",
                                network: NetworkInfo(publicIP: "203.0.113.7", lanIPs: ["192.0.2.10"], checkedAt: now),
                                servers: entries)
        try SnapshotStore(fileURL: paths.snapshotFile).save(snapshot)
        if history > 0 {
            try HistoryStore(fileURL: paths.historyFile).append((0..<history).map {
                HistoryEntry(ts: now.addingTimeInterval(Double($0)), kind: .refresh, note: "n\($0)")
            })
        }
        if metrics > 0, let id = entries.first?.id {
            try MetricsStore(fileURL: paths.metricsFile).append((0..<metrics).map {
                MetricSample(ts: now.addingTimeInterval(Double($0) * 60), serverID: id, host: "192.0.2.20", online: true,
                             ping: 40 + $0, players: $0, maxPlayers: 32, map: "de_dust2")
            })
        }
        if watch, let id = entries.first?.id {
            try WatchStateStore(fileURL: paths.watchStateFile).save([id: WatchSnapshot(status: .ipOk, online: true, map: "de_dust2",
                                                                                         offlineSince: nil, observedAt: now)])
        }
        return entries
    }

    private func files(_ paths: AppPaths) -> [String: Data] {
        var result: [String: Data] = [:]
        for file in FullBackupFile.allCases {
            if let data = try? Data(contentsOf: file.url(in: paths)) { result[file.rawValue] = data }
        }
        return result
    }

    private func entries(_ url: URL) throws -> [ZipEntry] {
        try XCTUnwrap(ZipArchive.read(Data(contentsOf: url)))
    }

    /// Rebuilds a backup ZIP with changed entries (the manifest is re-encoded unless given raw).
    private func rewrite(_ data: Data, manifest: ((inout FullBackupManifest) -> Void)? = nil,
                         replacing: [String: Data] = [:], adding: [ZipEntry] = [], dropping: Set<String> = []) throws -> Data {
        var list = try XCTUnwrap(ZipArchive.read(data))
        if let manifest {
            let index = try XCTUnwrap(list.firstIndex { $0.name == FullBackupManifest.fileName })
            var decoded = try HistoryCoding.makeDecoder().decode(FullBackupManifest.self, from: list[index].data)
            manifest(&decoded)
            list[index] = ZipEntry(name: FullBackupManifest.fileName, data: try FullBackupManifest.makeEncoder().encode(decoded))
        }
        list = list.filter { !dropping.contains($0.name) }.map { ZipEntry(name: $0.name, data: replacing[$0.name] ?? $0.data) }
        return ZipArchive.make(list + adding, modified: Date(timeIntervalSince1970: 1_793_000_000))
    }

    private func backupData(_ paths: AppPaths, appVersion: String = "2.7.0") throws -> Data {
        try FullBackupStore(paths: paths, appVersion: appVersion).archive(kind: .manual, now: Date(timeIntervalSince1970: 1_793_000_000)).data
    }

    // MARK: Manifest and content

    func testManualBackupFileNameAndManifestFields() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths, servers: 3, history: 5, metrics: 7)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let url = temp.url.appendingPathComponent(FullBackupNaming.manualFileName(now: now))
        let manifest = try FullBackupStore(paths: paths, appVersion: "2.7.0").write(to: url, now: now)

        XCTAssertNotNil(url.lastPathComponent.range(of: #"^playeridentity-backup-\d{8}-\d{6}\.zip$"#, options: .regularExpression))
        let zip = try entries(url)
        XCTAssertEqual(zip.map(\.name), Self.allNames)
        let stored = try HistoryCoding.makeDecoder().decode(FullBackupManifest.self, from: zip[0].data)
        XCTAssertEqual(stored, manifest)
        XCTAssertEqual(stored.schemaVersion, 1)
        XCTAssertEqual(stored.appVersion, "2.7.0")
        XCTAssertEqual(stored.createdAt, now)
        XCTAssertEqual(stored.kind, .manual)
        XCTAssertEqual(stored.recordSavedAt, now)
        XCTAssertEqual(stored.counts, FullBackupManifest.Counts(servers: 3, historyEntries: 5, metricSamples: 7, watchedServers: 1))
        XCTAssertEqual(stored.files.map(\.name), FullBackupFile.allCases.map(\.rawValue))
        XCTAssertEqual(stored.files.first { $0.name == "history.jsonl" }?.lines, 5)
        XCTAssertEqual(stored.files.first { $0.name == "metrics.jsonl" }?.lines, 7)
        XCTAssertNil(stored.files.first { $0.name == "profile.json" }?.lines)
        // The files are copied byte for byte; the raw manifest has the spec's field names.
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: zip.dropFirst().map { ($0.name, $0.data) }), files(paths))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: zip[0].data) as? [String: Any])
        for key in ["schemaVersion", "appVersion", "createdAt", "counts", "files", "contentSHA256"] {
            XCTAssertNotNil(raw[key], key)
        }
    }

    func testWatchStateIsOnlyIncludedWhenItExistsAndNoDataIsRefused() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")
        XCTAssertThrowsError(try store.archive(kind: .manual, now: Date())) { XCTAssertEqual($0 as? FullBackupError, .nothingToBackUp) }
        XCTAssertNil(try store.create(.preRestore, now: Date()))

        try seed(paths, watch: false)
        let names = try XCTUnwrap(ZipArchive.read(store.archive(kind: .manual, now: Date()).data)).map(\.name)
        XCTAssertEqual(names, [FullBackupManifest.fileName, "profile.json", "history.jsonl", "metrics.jsonl"])
    }

    func testBackupNeverContainsGameFilesRecordBackupsUpdatesOrLogs() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths)
        _ = try RecordBackup.make(of: paths.snapshotFile, at: Date())
        try temp.write("Library/Application Support/tr.ercanatay.playeridentity/updates/backup/PlayerIdentity-2.6.0.app/x", "app")
        try temp.write("Library/Application Support/tr.ercanatay.playeridentity/updates/downloads/PlayerIdentity-2.8.0.zip", "zip")
        try temp.write("Library/Application Support/tr.ercanatay.playeridentity/app.log", "log")
        try temp.write("Library/Application Support/Xash3D FWGS/valve/config.cfg", "name \"N\"\n")
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")
        try store.create(.preUpdate, now: Date())   // an earlier backup in backups/ is not nested either

        let names = try XCTUnwrap(ZipArchive.read(store.archive(kind: .manual, now: Date()).data)).map(\.name)
        XCTAssertEqual(names, Self.allNames)
        XCTAssertFalse(names.contains { $0.contains("appbak") || $0.contains("updates") || $0.contains(".cfg")
            || $0.contains(".log") || $0.contains(".zip") || $0.contains("/") })
    }

    func testPartialAndCorruptLinesAreLeftOutSoTheBackupStaysRestorable() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths, history: 2, metrics: 0, watch: false)
        let handle = try FileHandle(forWritingTo: paths.historyFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"ts\":\"2026".utf8))   // corrupt + cut-short line
        try handle.close()

        let data = try backupData(paths)
        guard case .success(let parsed) = FullBackupParser.parse(data) else { return XCTFail("backup not restorable") }
        XCTAssertEqual(parsed.manifest.counts.historyEntries, 2)
        XCTAssertEqual(FullBackupValidator.lineCount(try XCTUnwrap(parsed.data(.history))), 2)
    }

    // MARK: Roundtrip

    func testRoundtripPutsEveryFileBackAndBacksUpTheCurrentDataFirst() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths, servers: 2)
        let original = files(paths)
        let backup = try backupData(paths)

        // The data changes afterwards: other record, more history, no metrics.
        try seed(paths, servers: 5, history: 1, metrics: 0, watch: false)
        try FileManager.default.removeItem(at: paths.metricsFile)
        try FileManager.default.removeItem(at: paths.watchStateFile)
        let changed = files(paths)

        guard case .success(let parsed) = FullBackupParser.parse(backup) else { return XCTFail("parse") }
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")
        let safety = try XCTUnwrap(try store.create(.preRestore, now: Date(timeIntervalSince1970: 1_793_000_100)))
        try store.restore(parsed)

        XCTAssertEqual(files(paths), original)
        XCTAssertNotNil(safety.lastPathComponent.range(of: #"^pre-restore-\d{8}-\d{6}\.zip$"#, options: .regularExpression))
        guard case .success(let previous) = FullBackupParser.parse(try Data(contentsOf: safety)) else { return XCTFail("safety") }
        XCTAssertEqual(previous.files, changed)
        XCTAssertEqual(previous.manifest.kind, .preRestore)
        // No staging folder is left behind.
        let folder = try FileManager.default.contentsOfDirectory(atPath: paths.snapshotFile.deletingLastPathComponent().path)
        XCTAssertFalse(folder.contains { $0.hasPrefix(".restore-") }, "\(folder)")
    }

    func testModelRestoreReloadsTheRecordAndKeepsAPreRestoreBackup() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.7.0")
        model.addServer(ServerDraft(label: "Original A", host: "192.0.2.30"))
        model.addServer(ServerDraft(label: "Original B", host: "192.0.2.31"))
        await model.refresh().value   // the record carries the detected game folder, as after any launch
        model.save()
        let url = env.temp.url.appendingPathComponent("backup.zip")
        guard case .success(let manifest) = await model.writeFullBackup(to: url) else { return XCTFail("backup") }
        XCTAssertEqual(manifest.counts.servers, 2)

        model.deleteServer(id: model.servers[0].id)
        model.addServer(ServerDraft(label: "Later", host: "192.0.2.40"))
        model.save()
        XCTAssertEqual(model.servers.map(\.label), ["Original B", "Later"])

        guard case .chosen(let candidate) = FullBackupPicker.load(url) else { return XCTFail("load") }
        let preview = model.fullBackupPreview(candidate.backup)
        XCTAssertEqual(preview.counts.servers, 2)
        XCTAssertEqual(preview.compatibility, .sameVersion)
        let result = await model.restoreFullBackup(candidate.backup)
        await model.waitForRefresh()

        guard case .success(let outcome) = result, let safety = outcome.safetyBackup else { return XCTFail("restore: \(result)") }
        XCTAssertNil(outcome.keptPrevious)
        XCTAssertEqual(model.servers.map(\.label), ["Original A", "Original B"])
        XCTAssertNotNil(model.snapshotState.snapshot)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.isRestoring)
        XCTAssertFalse(model.updates.isDataOperationRunning)
        XCTAssertEqual(FullBackupStore(paths: paths, appVersion: "2.7.0").list(.preRestore), [safety])
        guard case .success(let previous) = FullBackupParser.read(safety) else { return XCTFail("safety") }
        XCTAssertEqual(previous.manifest.counts.servers, 2)
        let labels = (SnapshotStore.decode(try XCTUnwrap(previous.data(.profile))).snapshot?.servers ?? []).map(\.label)
        XCTAssertEqual(labels, ["Original B", "Later"])
    }

    func testPreviewReportsDatesCountsAndVersionCompatibility() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        let saved = Date(timeIntervalSince1970: 1_792_000_000)
        try seed(paths, servers: 4, history: 6, metrics: 8, now: saved)
        guard case .success(let parsed) = FullBackupParser.parse(try backupData(paths, appVersion: "2.7.0")) else {
            return XCTFail("parse")
        }
        let same = FullBackupPreview.make(parsed, currentVersion: "2.7.0")
        XCTAssertEqual(same.recordSavedAt, saved)
        XCTAssertEqual(same.createdAt, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(same.counts, FullBackupManifest.Counts(servers: 4, historyEntries: 6, metricSamples: 8, watchedServers: 1))
        XCTAssertEqual(same.compatibility, .sameVersion)
        XCTAssertEqual(FullBackupPreview.make(parsed, currentVersion: "2.9.0").compatibility, .olderVersion)
        XCTAssertEqual(FullBackupPreview.make(parsed, currentVersion: "2.6.0").compatibility, .newerVersion)
    }

    // MARK: Validation: the current data is kept

    func testInvalidBackupsAreRejectedWithoutTouchingTheCurrentData() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths)
        let good = try backupData(paths)
        let before = files(paths)

        func expect(_ data: Data, _ error: FullBackupError, file: StaticString = #filePath, line: UInt = #line) throws {
            let url = temp.url.appendingPathComponent("candidate-\(UUID().uuidString).zip")
            try data.write(to: url)
            switch FullBackupParser.read(url) {
            case .success: XCTFail("accepted", file: file, line: line)
            case .failure(let found): XCTAssertEqual(found, error, file: file, line: line)
            }
            guard case .failed(let text) = FullBackupPicker.load(url) else { return XCTFail("picker", file: file, line: line) }
            XCTAssertFalse(text.isEmpty, file: file, line: line)
            XCTAssertEqual(files(paths), before, file: file, line: line)
        }

        // The ZIP cannot be opened.
        try expect(Data("PK not really a zip".utf8), .unreadableArchive)
        try expect(Data(), .unreadableArchive)
        var damaged = good
        let note = try XCTUnwrap(good.range(of: Data("\"n1\"".utf8)))
        damaged[note.lowerBound + 1] ^= 0x20   // a byte inside history.jsonl: CRC mismatch
        try expect(damaged, .unreadableArchive)
        // Manifest missing, corrupt, other schema, not matching the files.
        try expect(try rewrite(good, dropping: [FullBackupManifest.fileName]), .missingManifest)
        try expect(try rewrite(good, replacing: [FullBackupManifest.fileName: Data("{ not json".utf8)]), .corruptManifest)
        try expect(try rewrite(good, replacing: [FullBackupManifest.fileName: Data(#"{"appVersion":"2.7.0"}"#.utf8)]), .corruptManifest)
        try expect(try rewrite(good, manifest: { $0.schemaVersion = 2 }), .unsupportedSchema(2))
        try expect(try rewrite(good, dropping: ["metrics.jsonl"]), .corruptManifest)
        try expect(try rewrite(good, manifest: { $0.contentSHA256 = String(repeating: "0", count: 64) }), .corruptManifest)
        // Unexpected entries (game files, path traversal, duplicates).
        try expect(try rewrite(good, adding: [ZipEntry(name: "valve/config.cfg", data: Data("x".utf8))]),
                   .unexpectedEntry("valve/config.cfg"))
        try expect(try rewrite(good, adding: [ZipEntry(name: "../profile.json", data: Data("{}".utf8))]),
                   .unexpectedEntry("../profile.json"))
        try expect(try rewrite(good, adding: [ZipEntry(name: "history.jsonl", data: Data())]), .unexpectedEntry("history.jsonl"))
        // A file differs from its manifest record.
        try expect(try rewrite(good, replacing: ["metrics.jsonl": Data()]), .corruptFile("metrics.jsonl"))
    }

    func testCorruptJSONAndJSONLInsideTheBackupAreRejected() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths)
        let good = try backupData(paths)

        /// Replaces a file and updates its manifest record, so only the content check can catch it.
        func forged(_ name: String, _ content: Data, lines: Int? = nil) throws -> Data {
            try rewrite(good, manifest: { manifest in
                let index = manifest.files.firstIndex { $0.name == name }!
                manifest.files[index].bytes = content.count
                manifest.files[index].sha256 = FullBackupContent.sha256(content)
                if manifest.files[index].lines != nil { manifest.files[index].lines = lines ?? FullBackupValidator.lineCount(content) }
                var all = (try? XCTUnwrap(ZipArchive.read(good)))?.filter { $0.name != FullBackupManifest.fileName } ?? []
                all = all.map { $0.name == name ? ZipEntry(name: name, data: content) : $0 }
                manifest.contentSHA256 = FullBackupContent.combinedSHA256(all.map { ($0.name, $0.data) })
            }, replacing: [name: content])
        }

        let history = try XCTUnwrap(try? Data(contentsOf: paths.historyFile))
        XCTAssertEqual(FullBackupParser.parse(try forged("history.jsonl", history + Data("{broken\n".utf8))),
                       .failure(.corruptFile("history.jsonl")))
        XCTAssertEqual(FullBackupParser.parse(try forged("metrics.jsonl", Data("[1,2]\n".utf8))),
                       .failure(.corruptFile("metrics.jsonl")))
        XCTAssertEqual(FullBackupParser.parse(try forged("history.jsonl", history, lines: 99)),
                       .failure(.corruptFile("history.jsonl")))
        XCTAssertEqual(FullBackupParser.parse(try forged("profile.json", Data("{\"schemaVersion\":1".utf8))),
                       .failure(.corruptFile("profile.json")))
        XCTAssertEqual(FullBackupParser.parse(try forged("profile.json", Data(#"{"schemaVersion":7}"#.utf8))),
                       .failure(.unsupportedRecordSchema(7)))
        XCTAssertEqual(FullBackupParser.parse(try forged("watch-state.json", Data("[]".utf8))),
                       .failure(.corruptFile("watch-state.json")))
        // The untouched forgery helper produces a valid backup.
        guard case .success = FullBackupParser.parse(try forged("history.jsonl", history)) else { return XCTFail("forgery") }
    }

    func testFailedRestoreKeepsTheCurrentData() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.7.0")
        model.addServer(ServerDraft(label: "Keep", host: "192.0.2.30"))
        model.save()
        guard case .success(let backup) = FullBackupParser.parse(try backupData(paths)) else { return XCTFail("parse") }
        let before = files(paths)

        let folder = paths.snapshotFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let result = await model.restoreFullBackup(backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

        guard case .failure(let error) = result else { return XCTFail("restore should fail") }
        if case .preRestoreBackupFailed = error {} else if case .writeFailed = error {} else { XCTFail("\(error)") }
        XCTAssertFalse(error.text.isEmpty)
        XCTAssertEqual(files(paths), before)
        XCTAssertEqual(model.servers.map(\.label), ["Keep"])
        XCTAssertFalse(model.isRestoring)
    }

    // MARK: Locks

    func testRestoreIsRefusedWhileAnUpdateDownloadsAndAnInstallBacksUpFirst() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let downloader = GatedUpdateDownloader(fraction: 0.4)
        let model = env.makeModel(updates: HTTPScript(defaultBody: SettingsEvidenceTests.feedJSON(["2.5.0", "2.4.1"])),
                                  appVersion: "2.4.1") { $0.updateDownloader = downloader }
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        guard case .success(let backup) = FullBackupParser.parse(try backupData(paths)) else { return XCTFail("parse") }

        await model.checkForUpdates(manual: true)?.value
        await model.updates.requestInstallOfAvailableUpdate()?.value
        let install = model.updates.confirmInstall()
        XCTAssertNotNil(install)
        for _ in 0..<250 where model.updates.status != .downloading(0.4) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(model.updates.status.isUpdating)
        // §49.3: a full backup was written before the install started.
        let store = FullBackupStore(paths: paths, appVersion: "2.4.1")
        XCTAssertEqual(store.list(.preUpdate).count, 1)

        let before = files(paths)
        let result = await model.restoreFullBackup(backup)
        XCTAssertEqual(result, .failure(.updateRunning))
        XCTAssertEqual(files(paths), before)
        XCTAssertTrue(store.list(.preRestore).isEmpty)
        XCTAssertFalse(model.isRestoring)

        downloader.release()
        await install?.value
        XCTAssertFalse(model.updates.status.isUpdating)
    }

    func testRestoreLockBlocksRefreshInstallEraseAndASecondRestore() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel(appVersion: "2.7.0")
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        guard case .success(let backup) = FullBackupParser.parse(try backupData(AppPaths(home: env.home))) else {
            return XCTFail("parse")
        }

        XCTAssertTrue(model.beginRestoreLock())
        XCTAssertFalse(model.beginRestoreLock())
        await model.refresh().value
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.lastChecked, "no refresh while restoring")
        let second = await model.restoreFullBackup(backup)
        XCTAssertEqual(second, .failure(.busy))
        let erase = await model.eraseAllData()
        XCTAssertEqual(erase, L10n.text(.restoreErrorBusy))
        XCTAssertNil(model.runAutomaticBackupIfDue())
        XCTAssertTrue(model.updates.isDataOperationRunning)
        model.endRestoreLock()

        await model.refresh().value
        XCTAssertNotNil(model.lastChecked)
    }

    // MARK: Automatic backups

    func testAutomaticBackupRunsOncePerDaySkipsUnchangedContentAndCanBeTurnedOff() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.7.0")
        XCTAssertTrue(model.autoBackupEnabled, "on by default")
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")

        let first = await model.runAutomaticBackupIfDue()?.value
        guard case .success(.created(let url))? = first else { return XCTFail("\(String(describing: first))") }
        XCTAssertEqual(url.lastPathComponent, "auto-\(FullBackupNaming.day(env.clock.now)).zip")
        XCTAssertEqual(store.list(.automatic), [url])
        XCTAssertEqual(model.automaticBackupCount, 1)
        XCTAssertNotNil(model.latestAutomaticBackup)
        // Same day: not due again (also directly on the store).
        XCTAssertNil(model.runAutomaticBackupIfDue())
        XCTAssertEqual(try store.createAutomatic(now: env.clock.now), .alreadyToday)

        // Next day, nothing changed: no new file.
        env.clock.advance(86_400)
        let unchanged = await model.runAutomaticBackupIfDue()?.value
        XCTAssertEqual(unchanged, .some(.success(.unchanged)))
        XCTAssertEqual(store.list(.automatic).count, 1)

        // Next day with a change: a new file.
        env.clock.advance(86_400)
        model.addServer(ServerDraft(label: "B", host: "192.0.2.31"))
        model.save()
        let changed = await model.runAutomaticBackupIfDue()?.value
        guard case .success(.created)? = changed else { return XCTFail("\(String(describing: changed))") }
        XCTAssertEqual(store.list(.automatic).count, 2)

        // Off: nothing runs.
        env.clock.advance(86_400)
        model.autoBackupEnabled = false
        XCTAssertEqual(env.defaults.object(forKey: DefaultsKey.autoBackupEnabled) as? Bool, false)
        XCTAssertNil(model.runAutomaticBackupIfDue())
        model.resetSettings()
        XCTAssertTrue(model.autoBackupEnabled)
        await model.waitForRefresh()
    }

    func testAutomaticBackupsKeepTheFiveNewest() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var created: [URL] = []
        for day in 0..<7 {
            try seed(paths, servers: day + 1)   // the content changes every day
            let now = start.addingTimeInterval(Double(day) * 86_400)
            guard case .created(let url) = try store.createAutomatic(now: now) else { return XCTFail("day \(day)") }
            created.append(url)
        }
        let kept = store.list(.automatic)
        XCTAssertEqual(kept.count, FullBackupStore.maxPerKind)
        XCTAssertEqual(kept, Array(created.suffix(5).reversed()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created[1].path))
        // An empty data folder never produces an automatic backup.
        let empty = try TempDirectory()
        XCTAssertEqual(try FullBackupStore(paths: AppPaths(home: empty.url), appVersion: "2.7.0").createAutomatic(now: start), .empty)
    }

    func testEraseInventoryCountsFullBackups() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths)
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")
        try store.create(.preUpdate, now: Date())
        _ = try store.createAutomatic(now: Date())
        XCTAssertEqual(AppDataEraser(paths: paths).inventory().backups, 2)
    }

    // MARK: Texts and view source

    func testBackupTextsExistInBothLanguagesAndViewsUseTheTheme() throws {
        let errors: [FullBackupError] = [.nothingToBackUp, .unreadableArchive, .tooLarge, .unexpectedEntry("x"),
                                         .missingManifest, .corruptManifest, .unsupportedSchema(2), .corruptFile("x"),
                                         .unsupportedRecordSchema(3), .updateRunning, .busy,
                                         .preRestoreBackupFailed("x"), .writeFailed("x"), .noUsableData(["x"])]
        for language in ["tr", "en"] {
            let texts = try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) { errors.map(\.text) }
            XCTAssertEqual(Set(texts).count, errors.count, language)
            XCTAssertFalse(texts.contains { $0.hasPrefix("fullRestore.") || $0.hasPrefix("fullBackup.") }, language)
        }
        let tr = try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            [L10n.text(.fullBackupCreate), L10n.text(.fullBackupRestore), L10n.text(.fullBackupAuto)]
        }
        XCTAssertEqual(tr, ["Tüm verileri yedekle…", "Yedekten geri yükle…", "Otomatik yedekler"])

        let views = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("App/Views", isDirectory: true)
        let source = try String(contentsOf: views.appendingPathComponent("FullBackupViews.swift"), encoding: .utf8)
        let violations = ThemeScanner.violations(in: source)
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }
}

/// Blocks the first `write` (the restore's staging step) until released and records whether any call ran on the
/// main thread.
final class GatedDataFiles: DataFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private let real = LocalDataFileOperations()
    private let gate = DispatchSemaphore(value: 0)
    private var waiting = false
    private var gated = false
    private var mainThreadCalls = 0

    var isWaiting: Bool { lock.withLock { waiting } }
    var callsOnTheMainThread: Int { lock.withLock { mainThreadCalls } }

    func release() { gate.signal() }

    private func note() {
        let main = Thread.isMainThread
        lock.withLock { if main { mainThreadCalls += 1 } }
    }

    func exists(_ url: URL) -> Bool { note(); return real.exists(url) }
    func createDirectory(_ url: URL) throws { note(); try real.createDirectory(url) }

    func write(_ data: Data, to url: URL) throws {
        note()
        let first = lock.withLock { () -> Bool in
            defer { gated = true }
            if !gated { waiting = true }
            return !gated
        }
        if first {
            _ = gate.wait(timeout: .now() + 10)   // never hangs the suite, even if the test fails
            lock.withLock { waiting = false }
        }
        try real.write(data, to: url)
    }

    func move(_ source: URL, to destination: URL) throws { note(); try real.move(source, to: destination) }
    func remove(_ url: URL) throws { note(); try real.remove(url) }
    func contents(_ url: URL) throws -> [URL] { note(); return try real.contents(url) }
}

// MARK: - Hardening: background restore, recounted manifests, pruning by date, unusable data

extension FullBackupTests {
    func testRestoreRunsOffTheMainThreadAndReportsItsStep() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let files = GatedDataFiles()
        let model = env.makeModel(appVersion: "2.7.0") { $0.dataFileOperations = files }
        model.addServer(ServerDraft(label: "Backed up", host: "192.0.2.30"))
        model.save()
        guard case .success(let backup) = FullBackupParser.parse(try backupData(paths)) else { return XCTFail("parse") }
        model.addServer(ServerDraft(label: "Later", host: "192.0.2.31"))
        model.save()
        XCTAssertNil(model.restoreStep)

        let restore = Task { await model.restoreFullBackup(backup) }
        // The main actor keeps running (this loop) while the restore is held inside its file step.
        for _ in 0..<250 where !files.isWaiting { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(files.isWaiting, "the restore reached its staging step")
        XCTAssertEqual(model.restoreStep, .replacing)
        XCTAssertTrue(model.isRestoring)
        XCTAssertEqual(FullBackupStore(paths: paths, appVersion: "2.7.0").list(.preRestore).count, 1,
                       "the pre-restore backup was written first")
        files.release()

        guard case .success = await restore.value else { return XCTFail("restore") }
        await model.waitForRefresh()
        XCTAssertEqual(files.callsOnTheMainThread, 0)
        XCTAssertNil(model.restoreStep)
        XCTAssertFalse(model.isRestoring)
        XCTAssertEqual(model.servers.map(\.label), ["Backed up"])
    }

    func testRestoreSheetShowsTheBackupStep() throws {
        let views = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("App/Views", isDirectory: true)
        let source = try String(contentsOf: views.appendingPathComponent("FullBackupViews.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("model.restoreStep == .backingUp ? .fullRestoreWorkingBackup : .fullRestoreWorking"))
        for language in ["tr", "en"] {
            let text = try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) { L10n.text(.fullRestoreWorkingBackup) }
            XCTAssertFalse(text.isEmpty || text.hasPrefix("fullRestore."), language)
        }
    }

    func testPreviewCountsComeFromTheFilesAndAManifestThatSaysOtherwiseIsRefused() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        let saved = Date(timeIntervalSince1970: 1_792_000_000)
        try seed(paths, servers: 3, history: 5, metrics: 7, now: saved)
        let data = try backupData(paths)
        guard case .success(let parsed) = FullBackupParser.parse(data) else { return XCTFail("parse") }
        let real = FullBackupManifest.Counts(servers: 3, historyEntries: 5, metricSamples: 7, watchedServers: 1)
        XCTAssertEqual(parsed.counts, real)
        XCTAssertEqual(parsed.recordSavedAt, saved)
        XCTAssertEqual(FullBackupPreview.make(parsed, currentVersion: "2.7.0").counts, real)

        let forgeries: [(String, (inout FullBackupManifest) -> Void)] = [
            ("servers", { $0.counts.servers = 99 }),
            ("history", { $0.counts.historyEntries = 1 }),
            ("metrics", { $0.counts.metricSamples = 0 }),
            ("watched", { $0.counts.watchedServers = 3 }),
            ("record date", { $0.recordSavedAt = Date(timeIntervalSince1970: 1_700_000_000) }),
            ("no record date", { $0.recordSavedAt = nil }),
        ]
        for (name, forge) in forgeries {
            let forged = try rewrite(data, manifest: forge)
            XCTAssertEqual(FullBackupParser.parse(forged), .failure(.corruptManifest), name)
        }
    }

    func testListSortsByModificationDateAndPruneNeverRemovesTheNewBackup() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths)
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.directory, withIntermediateDirectories: true)
        func place(_ name: String, modified: Date) throws -> URL {
            let url = store.directory.appendingPathComponent(name)
            try Data("old".utf8).write(to: url)
            try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        // The name sorts later but the file is older: the modification date decides.
        let laterName = try place("auto-20991231.zip", modified: Date(timeIntervalSince1970: 1_600_000_000))
        let newer = try place("auto-20200101.zip", modified: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(store.list(.automatic), [newer, laterName])

        // Five backups made before the clock was set back: names and dates in the future.
        let future = Date(timeIntervalSince1970: 4_000_000_000)
        var existing: [URL] = []
        for index in 0..<FullBackupStore.maxPerKind {
            existing.append(try place("pre-restore-2096100\(index)-000000.zip", modified: future.addingTimeInterval(Double(index))))
        }
        let created = try store.createBackup(.preRestore, now: Date(timeIntervalSince1970: 1_793_000_000))
        let url = try XCTUnwrap(created.url)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path), "the backup just written is never pruned")
        let kept = store.list(.preRestore)
        XCTAssertEqual(kept.count, FullBackupStore.maxPerKind)
        XCTAssertTrue(kept.contains(url))
        XCTAssertFalse(fileManager.fileExists(atPath: existing[0].path), "the oldest other backup goes instead")
        XCTAssertEqual(Set(kept), Set([url] + existing.dropFirst()))
    }

    func testUnreadableDataIsReportedInsteadOfNothingToBackUp() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try FileManager.default.createDirectory(at: paths.snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: paths.snapshotFile)
        try Data("garbage\nmore garbage\n".utf8).write(to: paths.historyFile)
        let store = FullBackupStore(paths: paths, appVersion: "2.7.0")
        let expected = FullBackupError.noUsableData(["profile.json", "history.jsonl"])

        XCTAssertThrowsError(try store.archive(kind: .manual, now: Date())) { XCTAssertEqual($0 as? FullBackupError, expected) }
        XCTAssertThrowsError(try store.write(to: temp.url.appendingPathComponent("b.zip"), now: Date())) {
            XCTAssertEqual($0 as? FullBackupError, expected)
        }
        XCTAssertThrowsError(try store.createAutomatic(now: Date())) { XCTAssertEqual($0 as? FullBackupError, expected) }
        // The pre-restore backup reports the skipped files (the restore then keeps the previous files).
        let created = try store.createBackup(.preRestore, now: Date())
        XCTAssertNil(created.url)
        XCTAssertEqual(created.skipped.map(\.file), ["profile.json", "history.jsonl"])
        XCTAssertTrue(store.list(.automatic).isEmpty)

        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            let (text, isError) = FullBackupText.result(.failure(expected), url: temp.url)
            XCTAssertTrue(isError)
            XCTAssertEqual(text, "2 dosya okunamadı (profile.json, history.jsonl); yedek oluşturulamadı.")
            XCTAssertNotEqual(text, L10n.text(.backupNothing))
            XCTAssertTrue(FullBackupText.automaticFailure(expected).contains("2 dosya okunamadı"))
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(expected.text, "2 files could not be read (profile.json, history.jsonl); no backup was created.")
        }
        // An empty data folder still says there is nothing to back up.
        let empty = FullBackupStore(paths: AppPaths(home: try TempDirectory().url), appVersion: "2.7.0")
        XCTAssertThrowsError(try empty.archive(kind: .manual, now: Date())) { XCTAssertEqual($0 as? FullBackupError, .nothingToBackUp) }
    }
}

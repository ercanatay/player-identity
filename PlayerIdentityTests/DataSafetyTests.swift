import XCTest
@testable import PlayerIdentity

/// File operations that fail chosen steps (§47.2 erase, §49 restore): the n-th `move`, removes or listings that match.
/// Every call is logged as `"<op> <file name>"`.
final class FaultyDataFiles: DataFileOperating, @unchecked Sendable {
    struct Injected: LocalizedError {
        var errorDescription: String? { "injected failure" }
    }

    private let lock = NSLock()
    private let real = LocalDataFileOperations()
    private var moveCount = 0
    private var calls: [String] = []
    private var probeResults: [Bool] = []
    /// 1-based numbers of the `move` calls that fail.
    var failingMoves: Set<Int> = []
    var failsRemove: @Sendable (URL) -> Bool = { _ in false }
    var failsContents = false
    /// Evaluated on every remove (e.g. whether the data lock is held).
    var probe: (@Sendable () -> Bool)?

    var log: [String] { lock.withLock { calls } }
    var probes: [Bool] { lock.withLock { probeResults } }

    private func record(_ entry: String) { lock.withLock { calls.append(entry) } }

    func exists(_ url: URL) -> Bool { real.exists(url) }
    func createDirectory(_ url: URL) throws { try real.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try real.write(data, to: url) }

    func move(_ source: URL, to destination: URL) throws {
        let number = lock.withLock { () -> Int in
            moveCount += 1
            return moveCount
        }
        record("move \(source.lastPathComponent) \(destination.deletingLastPathComponent().lastPathComponent)")
        if failingMoves.contains(number) { throw Injected() }
        try real.move(source, to: destination)
    }

    func remove(_ url: URL) throws {
        record("remove \(url.lastPathComponent)")
        if let probe { lock.withLock { probeResults.append(probe()) } }
        if failsRemove(url) { throw Injected() }
        try real.remove(url)
    }

    func contents(_ url: URL) throws -> [URL] {
        if failsContents { throw Injected() }
        return try real.contents(url)
    }
}

/// Review findings on data integrity: restore rollback, incomplete backups, erase and the data operation lock.
@MainActor
final class DataSafetyTests: XCTestCase {
    override func tearDown() async throws {
        L10n.setting = .system
    }

    // MARK: Fixtures

    /// Record with `servers` servers, history, metrics and a watch state.
    private func seed(_ paths: AppPaths, servers: Int = 2, history: Int = 3, metrics: Int = 2, watch: Bool = true) throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
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
    }

    private func files(_ paths: AppPaths) -> [String: Data] {
        var result: [String: Data] = [:]
        for file in FullBackupFile.allCases {
            if let data = try? Data(contentsOf: file.url(in: paths)) { result[file.rawValue] = data }
        }
        return result
    }

    private func parsedBackup(_ paths: AppPaths) throws -> ParsedFullBackup {
        let data = try FullBackupStore(paths: paths, appVersion: "2.9.0").archive(kind: .manual, now: Date()).data
        guard case .success(let parsed) = FullBackupParser.parse(data) else {
            XCTFail("backup not parseable")
            throw CancellationError()
        }
        return parsed
    }

    private func stagingFolders(_ paths: AppPaths) -> [URL] {
        let folder = paths.snapshotFile.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(".restore-") }.map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    private func store(_ paths: AppPaths, _ faults: FaultyDataFiles) -> FullBackupStore {
        var store = FullBackupStore(paths: paths, appVersion: "2.9.0")
        store.fileOperations = faults
        return store
    }

    // MARK: 1 · Restore rollback

    /// A failure at any of the 8 moves (4 files moved aside + 4 put in place) puts every previous file back,
    /// reports `writeFailed` and leaves no staging folder (it only held copies of the backup).
    func testRestoreFailingAtEachMoveRollsBackEveryPreviousFile() throws {
        for failing in 1...8 {
            let temp = try TempDirectory()
            let paths = AppPaths(home: temp.url)
            try seed(paths, servers: 2)
            let backup = try parsedBackup(paths)
            try seed(paths, servers: 5, history: 1, metrics: 4)
            let before = files(paths)
            let faults = FaultyDataFiles()
            faults.failingMoves = [failing]

            XCTAssertThrowsError(try store(paths, faults).restore(backup), "move \(failing)") { error in
                guard case .writeFailed = error as? FullBackupError else { return XCTFail("move \(failing): \(error)") }
                XCTAssertTrue((error as? FullBackupError)?.keptCurrentData == true)
            }
            XCTAssertEqual(files(paths), before, "move \(failing)")
            XCTAssertEqual(stagingFolders(paths), [], "move \(failing)")
        }
    }

    /// Rollback order: every moved-aside file goes back before a placed new file (no previous version) is removed.
    func testRollbackMovesPreviousFilesBackBeforeRemovingNewOnes() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths, servers: 2)
        let backup = try parsedBackup(paths)   // all 4 files
        try seed(paths, servers: 3, history: 1, metrics: 0, watch: false)
        try FileManager.default.removeItem(at: paths.metricsFile)
        try FileManager.default.removeItem(at: paths.watchStateFile)
        let before = files(paths)
        XCTAssertEqual(Set(before.keys), ["profile.json", "history.jsonl"])
        // Moves: 1 profile aside, 2 profile in, 3 history aside, 4 history in, 5 metrics in, 6 watch in (fails).
        let faults = FaultyDataFiles()
        faults.failingMoves = [6]

        XCTAssertThrowsError(try store(paths, faults).restore(backup)) { error in
            guard case .writeFailed = error as? FullBackupError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(files(paths), before)
        let log = faults.log
        let lastMoveBack = try XCTUnwrap(log.lastIndex { $0.hasPrefix("move ") })
        let removeNew = try XCTUnwrap(log.firstIndex(of: "remove metrics.jsonl"))
        XCTAssertGreaterThan(removeNew, lastMoveBack, "\(log)")
        XCTAssertEqual(Array(log[6...9]), ["move profile.json new", "move profile.json tr.ercanatay.playeridentity",
                                           "move history.jsonl new", "move history.jsonl tr.ercanatay.playeridentity"])
    }

    /// A rollback step that fails keeps the staging folder (the only copy of a previous file) and says where it is.
    func testFailedRollbackKeepsTheStagingFolderAndReportsItsPath() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths, servers: 2)
        let backup = try parsedBackup(paths)
        try seed(paths, servers: 5, history: 1, metrics: 4)
        let before = files(paths)
        // Moves: 1 profile aside, 2 profile in, 3 history aside, 4 history in (fails) → rollback: 5 profile new→staged,
        // 6 previous profile back, 7 previous history back (fails).
        let faults = FaultyDataFiles()
        faults.failingMoves = [4, 7]

        var reported: URL?
        XCTAssertThrowsError(try store(paths, faults).restore(backup)) { error in
            guard case .rollbackFailed(let staging, let reason)? = error as? FullBackupError else { return XCTFail("\(error)") }
            reported = staging
            XCTAssertEqual(reason, "injected failure")
            XCTAssertFalse((error as? FullBackupError)?.keptCurrentData ?? true)
            XCTAssertTrue((error as? FullBackupError)?.text.contains(staging.path) == true)
        }
        let staging = try XCTUnwrap(reported)
        XCTAssertEqual(stagingFolders(paths).map(\.lastPathComponent), [staging.lastPathComponent])
        // The previous history is only in the staging folder; it was never deleted.
        let kept = staging.appendingPathComponent("previous/history.jsonl")
        XCTAssertEqual(try Data(contentsOf: kept), before["history.jsonl"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.historyFile.path))
        XCTAssertEqual(files(paths)["profile.json"], before["profile.json"])
        XCTAssertEqual(files(paths)["metrics.jsonl"], before["metrics.jsonl"])
    }

    /// Through the model: `rollbackFailed` is reported as such and the sheet never says the data was unchanged.
    func testModelReportsRollbackFailureWithoutClaimingTheDataIsUnchanged() async throws {
        let faults = FaultyDataFiles()
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.9.0") { $0.dataFileOperations = faults }
        model.addServer(ServerDraft(label: "Keep", host: "192.0.2.30"))
        model.save()
        let backup = try parsedBackup(paths)
        faults.failingMoves = [2, 3]   // profile in fails; putting the previous profile back fails too

        let result = await model.restoreFullBackup(backup)
        guard case .failure(let error) = result, case .rollbackFailed(let staging, _) = error else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(FullBackupText.failureLines(error), [error.text, L10n.text(.fullRestoreCheckData)])
        XCTAssertFalse(FullBackupText.failureLines(error).contains(L10n.text(.fullRestoreKept)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("previous/profile.json").path))
        XCTAssertFalse(model.isDataOperationRunning)
        XCTAssertFalse(model.updates.isDataOperationRunning)

        // A rollback that works keeps the "unchanged" text.
        let writeFailed = FullBackupError.writeFailed("x")
        XCTAssertEqual(FullBackupText.failureLines(writeFailed), [writeFailed.text, L10n.text(.fullRestoreKept)])
    }

    /// Files the pre-restore backup could not include are kept next to the data after the restore.
    func testRestoreKeepsPreviousFilesThePreRestoreBackupCouldNotInclude() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.9.0")
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        let backup = try parsedBackup(paths)
        try Data("damaged".utf8).write(to: paths.watchStateFile)

        let result = await model.restoreFullBackup(backup)
        await model.waitForRefresh()
        guard case .success(let outcome) = result, let kept = outcome.keptPrevious else { return XCTFail("\(result)") }
        XCTAssertNotNil(outcome.safetyBackup)
        XCTAssertEqual(try Data(contentsOf: kept.appendingPathComponent("previous/watch-state.json")), Data("damaged".utf8))
        XCTAssertEqual(stagingFolders(paths), [kept])
    }

    // MARK: 2 · Incomplete backups

    func testBackupListsUnreadableAndCorruptFilesAndWarns() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths)
        let handle = try FileHandle(forWritingTo: paths.historyFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try FileManager.default.removeItem(at: paths.metricsFile)
        try FileManager.default.createDirectory(at: paths.metricsFile, withIntermediateDirectories: false)   // unreadable
        try Data("{ damaged".utf8).write(to: paths.watchStateFile)

        let url = temp.url.appendingPathComponent("backup.zip")
        let manifest = try FullBackupStore(paths: paths, appVersion: "2.9.0").write(to: url, now: Date())
        XCTAssertEqual(manifest.warnings, [.init(file: "history.jsonl", reason: .corruptLines, lines: 1),
                                           .init(file: "metrics.jsonl", reason: .unreadable),
                                           .init(file: "watch-state.json", reason: .corrupt)])
        XCTAssertEqual(manifest.missingFiles, ["metrics.jsonl", "watch-state.json"])
        XCTAssertEqual(manifest.files.map(\.name), ["profile.json", "history.jsonl"])

        // The result says the backup is incomplete.
        let (text, isError) = FullBackupText.result(.success(manifest), url: url)
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains(L10n.format(.fullBackupSkipped, "2", "metrics.jsonl, watch-state.json")), text)
        XCTAssertTrue(text.contains(L10n.format(.fullBackupDroppedLines, "history.jsonl", "1")), text)

        // The manifest carries `skipped: [{file, reason}]`; the backup stays restorable and the preview warns.
        let zip = try XCTUnwrap(ZipArchive.read(Data(contentsOf: url)))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: zip[0].data) as? [String: Any])
        let skipped = try XCTUnwrap(raw["skipped"] as? [[String: Any]])
        XCTAssertEqual(skipped.compactMap { $0["file"] as? String }, ["history.jsonl", "metrics.jsonl", "watch-state.json"])
        XCTAssertEqual(skipped.compactMap { $0["reason"] as? String }, ["corrupt-lines", "unreadable", "corrupt"])
        guard case .chosen(let candidate) = FullBackupPicker.load(url) else { return XCTFail("not restorable") }
        let preview = FullBackupPreview.make(candidate.backup, currentVersion: "2.9.0")
        XCTAssertEqual(preview.missingFiles, ["metrics.jsonl", "watch-state.json"])
        let confirmation = FullBackupText.restoreConfirmation(preview, hasUnsavedChanges: false)
        XCTAssertTrue(confirmation.contains(L10n.format(.fullRestoreMissingNote, "metrics.jsonl, watch-state.json")),
                      confirmation)
        XCTAssertFalse(confirmation.contains(L10n.text(.fullRestoreUnsavedNote)))
    }

    /// A file that does not exist is not a warning, and a complete backup has no `skipped` field (older versions
    /// read it unchanged; manifests without the field decode).
    func testMissingFilesAreNotWarningsAndCompleteBackupsHaveNoSkippedField() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths, metrics: 0, watch: false)
        let (data, manifest) = try FullBackupStore(paths: paths, appVersion: "2.9.0").archive(kind: .manual, now: Date())
        XCTAssertNil(manifest.skipped)
        XCTAssertEqual(FullBackupText.result(.success(manifest), url: temp.url).1, false)
        let zip = try XCTUnwrap(ZipArchive.read(data))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: zip[0].data) as? [String: Any])
        XCTAssertNil(raw["skipped"])
        guard case .success(let parsed) = FullBackupParser.parse(data) else { return XCTFail("parse") }
        XCTAssertEqual(FullBackupPreview.make(parsed, currentVersion: "2.9.0").missingFiles, [])
    }

    /// A manifest whose `skipped` list names unknown files or contradicts the archive is rejected.
    func testInconsistentSkippedListIsRejected() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try seed(paths)
        let good = try FullBackupStore(paths: paths, appVersion: "2.9.0").archive(kind: .manual, now: Date()).data
        func forged(_ skipped: [FullBackupManifest.SkippedFile]) throws -> Data {
            var entries = try XCTUnwrap(ZipArchive.read(good))
            var manifest = try HistoryCoding.makeDecoder().decode(FullBackupManifest.self, from: entries[0].data)
            manifest.skipped = skipped
            entries[0] = ZipEntry(name: FullBackupManifest.fileName, data: try FullBackupManifest.makeEncoder().encode(manifest))
            return ZipArchive.make(entries, modified: Date())
        }
        XCTAssertEqual(FullBackupParser.parse(try forged([.init(file: "../x", reason: .corrupt)])), .failure(.corruptManifest))
        XCTAssertEqual(FullBackupParser.parse(try forged([.init(file: "profile.json", reason: .unreadable)])),
                       .failure(.corruptManifest))   // listed as missing but present
        guard case .success = FullBackupParser.parse(try forged([.init(file: "history.jsonl", reason: .corruptLines, lines: 2)])) else {
            return XCTFail("dropped lines of an included file are valid")
        }
    }

    // MARK: 3 · Erase

    func testEraseInventoryFailureThrowsAndRemovesNothing() async throws {
        let faults = FaultyDataFiles()
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel { $0.dataFileOperations = faults }
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        model.addServer(ServerDraft(label: "Unsaved", host: "192.0.2.31"))
        let before = files(paths)
        faults.failsContents = true

        XCTAssertThrowsError(try AppDataEraser(paths: paths, fileOperations: faults).erase())
        let erased = await model.eraseAllData()
        let error = try XCTUnwrap(erased)
        XCTAssertEqual(error, L10n.format(.eraseFailed, "injected failure"))
        XCTAssertEqual(files(paths), before)
        XCTAssertEqual(model.servers.map(\.label), ["A", "Unsaved"])
        XCTAssertTrue(model.hasUnsavedChanges, "nothing was erased, so the edits stay")
        XCTAssertFalse(model.isDataOperationRunning)
    }

    func testPartialEraseNamesWhatIsLeftAndReloadsTheModelFromDisk() async throws {
        let faults = FaultyDataFiles()
        faults.failsRemove = { $0.lastPathComponent == "history.jsonl" }
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel { $0.dataFileOperations = faults }
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        await model.refresh().value
        model.save()
        await model.waitForHistory()
        try HistoryStore(fileURL: paths.historyFile).append([HistoryEntry(ts: env.clock.now, kind: .refresh, note: "kept")])

        let erased = await model.eraseAllData()
        let error = try XCTUnwrap(erased)
        await model.waitForRefresh()
        XCTAssertTrue(error.contains("history.jsonl"), error)
        XCTAssertTrue(error.hasPrefix(L10n.format(.eraseIncomplete, "", "").components(separatedBy: ":")[0]), error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.historyFile.path))
        XCTAssertEqual(model.snapshotState, .missing)
        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.isDataOperationRunning)
        // A later save writes the reloaded (erased) state, never the old server list.
        model.save()
        XCTAssertEqual(SnapshotStore(fileURL: paths.snapshotFile).load().snapshot?.servers, [])
    }

    func testPartialEraseThatKeepsTheRecordReloadsIt() async throws {
        let faults = FaultyDataFiles()
        faults.failsRemove = { $0.lastPathComponent == "profile.json" }
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel { $0.dataFileOperations = faults }
        model.addServer(ServerDraft(label: "Saved", host: "192.0.2.30"))
        await model.refresh().value   // the record carries the detected game folder, as after any launch
        model.save()
        model.addServer(ServerDraft(label: "Unsaved", host: "192.0.2.31"))

        let erased = await model.eraseAllData()
        let error = try XCTUnwrap(erased)
        await model.waitForRefresh()
        XCTAssertTrue(error.contains("profile.json"), error)
        XCTAssertNotNil(model.snapshotState.snapshot)
        XCTAssertEqual(model.servers.map(\.label), ["Saved"])
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
    }

    func testEraseHoldsTheDataOperationLockWhileRemoving() async throws {
        let faults = FaultyDataFiles()
        let env = try TestAppEnvironment()
        let model = env.makeModel { $0.dataFileOperations = faults }
        faults.probe = { MainActor.assumeIsolated { model.dataOperation == .erase && model.updates.isDataOperationRunning } }
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()

        let error = await model.eraseAllData()
        await model.waitForRefresh()
        XCTAssertNil(error)
        XCTAssertFalse(faults.probes.isEmpty)
        XCTAssertEqual(Set(faults.probes), [true])
        XCTAssertNil(model.dataOperation)
        XCTAssertFalse(model.updates.isDataOperationRunning)
    }

    /// Erase, restore, save, data root, refresh and automatic backups all respect the one data operation lock.
    func testDataOperationLockRefusesRestoreSaveDataRootAndErase() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.9.0")
        model.addServer(ServerDraft(label: "A", host: "192.0.2.30"))
        model.save()
        let backup = try parsedBackup(paths)
        let record = try Data(contentsOf: paths.snapshotFile)
        let root = model.dataRoot

        XCTAssertTrue(model.beginDataOperation(.erase))
        XCTAssertFalse(model.beginDataOperation(.restore))
        XCTAssertFalse(model.beginRestoreLock())
        XCTAssertFalse(model.isRestoring)
        XCTAssertTrue(model.isDataOperationRunning)
        let restore = await model.restoreFullBackup(backup)
        XCTAssertEqual(restore, .failure(.busy))
        let erase = await model.eraseAllData()
        XCTAssertEqual(erase, L10n.text(.restoreErrorBusy))
        model.addServer(ServerDraft(label: "B", host: "192.0.2.31"))
        model.save()
        XCTAssertEqual(model.saveErrorMessage, L10n.text(.saveBusy))
        XCTAssertEqual(try Data(contentsOf: paths.snapshotFile), record)
        await model.setDataRoot(env.temp.url.appendingPathComponent("elsewhere", isDirectory: true)).value
        XCTAssertEqual(model.dataRoot, root)
        await model.refresh().value
        XCTAssertNil(model.lastChecked)
        XCTAssertNil(model.runAutomaticBackupIfDue())
        XCTAssertNil(model.updates.confirmInstall())
        model.endDataOperation()

        model.saveErrorMessage = nil
        model.save()
        XCTAssertNil(model.saveErrorMessage)
        XCTAssertNotEqual(try Data(contentsOf: paths.snapshotFile), record)
    }

    // MARK: 4 · Unsaved changes and restore

    func testRestoreConfirmationWarnsAboutUnsavedChangesAndSaveFirstKeepsThem() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.9.0")
        model.addServer(ServerDraft(label: "Backed up", host: "192.0.2.30"))
        model.save()
        let backup = try parsedBackup(paths)
        model.addServer(ServerDraft(label: "Unsaved", host: "192.0.2.31"))
        XCTAssertTrue(model.hasUnsavedChanges)
        let preview = model.fullBackupPreview(backup)
        XCTAssertTrue(FullBackupText.restoreConfirmation(preview, hasUnsavedChanges: model.hasUnsavedChanges)
            .contains(L10n.text(.fullRestoreUnsavedNote)))

        let result = await model.restoreFullBackup(backup, saveFirst: true)
        await model.waitForRefresh()
        guard case .success(let outcome) = result, let safety = outcome.safetyBackup else { return XCTFail("\(result)") }
        XCTAssertEqual(model.servers.map(\.label), ["Backed up"])
        guard case .success(let previous) = FullBackupParser.read(safety) else { return XCTFail("safety") }
        let labels = (SnapshotStore.decode(try XCTUnwrap(previous.data(.profile))).snapshot?.servers ?? []).map(\.label)
        XCTAssertEqual(labels, ["Backed up", "Unsaved"], "the unsaved change is in the pre-restore backup")
    }

    func testRestoreWithoutSaveFirstDropsUnsavedChanges() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.9.0")
        model.addServer(ServerDraft(label: "Backed up", host: "192.0.2.30"))
        await model.refresh().value
        model.save()
        let backup = try parsedBackup(paths)
        model.addServer(ServerDraft(label: "Unsaved", host: "192.0.2.31"))

        let result = await model.restoreFullBackup(backup)
        await model.waitForRefresh()
        guard case .success(let outcome) = result, let safety = outcome.safetyBackup else { return XCTFail("\(result)") }
        guard case .success(let previous) = FullBackupParser.read(safety) else { return XCTFail("safety") }
        let labels = (SnapshotStore.decode(try XCTUnwrap(previous.data(.profile))).snapshot?.servers ?? []).map(\.label)
        XCTAssertEqual(labels, ["Backed up"])
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testFailedSaveFirstStopsTheRestore() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        let model = env.makeModel(appVersion: "2.9.0")
        model.addServer(ServerDraft(label: "Backed up", host: "192.0.2.30"))
        model.save()
        let backup = try parsedBackup(paths)
        model.addServer(ServerDraft(label: "Unsaved", host: "192.0.2.31"))
        let before = files(paths)
        let folder = paths.snapshotFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let result = await model.restoreFullBackup(backup, saveFirst: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        guard case .failure(.saveFailed(let reason)) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(model.saveErrorMessage)
        XCTAssertEqual(files(paths), before)
        XCTAssertEqual(model.servers.map(\.label), ["Backed up", "Unsaved"])
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.isDataOperationRunning)
        XCTAssertTrue(FullBackupStore(paths: paths, appVersion: "2.9.0").list(.preRestore).isEmpty)
    }

    // MARK: Texts

    func testNewTextsExistInBothLanguages() throws {
        let staging = URL(fileURLWithPath: "/tmp/.restore-x", isDirectory: true)
        let errors: [FullBackupError] = [.saveFailed("x"), .writeFailed("x"), .rollbackFailed(staging: staging, reason: "x")]
        let keys: [L10nKey] = [.saveBusy, .eraseIncomplete, .fullBackupSkipped, .fullBackupDroppedLines, .fullRestoreMissingNote,
                               .fullRestoreUnsavedNote, .fullRestoreSaveFirst, .fullRestoreDoneKept, .fullRestoreIncompleteTitle,
                               .fullRestoreCheckData, .restoreErrorRollback, .restoreErrorSave]
        for language in ["tr", "en"] {
            let bundle = try XCTUnwrap(L10n.languageBundle(language))
            let texts = L10n.$bundle.withValue(bundle) { errors.map(\.text) + keys.map { L10n.text($0) } }
            XCTAssertEqual(Set(texts).count, texts.count, language)
            XCTAssertFalse(texts.contains { $0.contains(".") && !$0.contains(" ") }, "\(language): \(texts)")
            XCTAssertTrue(texts[2].contains(staging.path), language)
        }
    }
}

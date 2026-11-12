import XCTest
@testable import PlayerIdentity

/// §54 diagnostics error log: ring buffer, redaction, `errors.json` in the diagnostics ZIP and the app's error points.
@MainActor
final class ErrorLogTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testRecordsInOrderAndKeepsTheLastFifty() {
        let log = ErrorLog()
        XCTAssertEqual(log.entries, [])
        for index in 0..<(ErrorLog.capacity + 7) {
            log.record(index.isMultiple(of: 2) ? .update : .backup, "error\(index)", at: Self.t0 + Double(index))
        }
        let entries = log.entries
        XCTAssertEqual(entries.count, ErrorLog.capacity)
        XCTAssertEqual(entries.first?.message, "error7")     // the 7 oldest were dropped
        XCTAssertEqual(entries.last?.message, "error56")
        XCTAssertEqual(entries.last?.area, .update)
        XCTAssertEqual(entries.last?.ts, Self.t0 + 56)
        XCTAssertEqual(entries.map(\.ts), entries.map(\.ts).sorted())

        log.record(.login, String(repeating: "x", count: ErrorLog.maxMessageLength + 50), at: Self.t0)
        XCTAssertEqual(log.entries.last?.message.count, ErrorLog.maxMessageLength)
        log.removeAll()
        XCTAssertEqual(log.entries, [])
    }

    func testDiagnosticsJSONIsRedacted() throws {
        let redactor = Redactor(home: URL(fileURLWithPath: "/Users/alice"))
        let entries = [
            ErrorLogEntry(ts: Self.t0, area: .watch, message: "watchState: /Users/alice/Library/x.json not writable"),
            ErrorLogEntry(ts: Self.t0 + 1, area: .update, message: "update: download from 198.51.100.7 and [2001:db8::1]:443"),
        ]
        let data = ErrorLog.diagnosticsJSON(entries, redactor: redactor)
        let text = String(decoding: data, as: UTF8.self)
        for leaked in ["/Users/alice", "198.51.100.7", "2001:db8::1"] { XCTAssertFalse(text.contains(leaked), leaked) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["capacity"] as? Int, 50)
        let errors = try XCTUnwrap(object["errors"] as? [[String: Any]])
        XCTAssertEqual(errors.count, 2)
        XCTAssertEqual(errors[0]["area"] as? String, "watch")
        XCTAssertEqual(errors[0]["message"] as? String, "watchState: ~/Library/x.json not writable")
        XCTAssertEqual(errors[1]["message"] as? String, "update: download from 198.51.x.x and [2001:db8::x]:443")
        XCTAssertEqual(errors[1]["ts"] as? String, ISO8601DateFormatter().string(from: Self.t0 + 1))
    }

    func testDiagnosticsZipCarriesErrorsJSON() throws {
        let temp = try TempDirectory()
        let suite = "ErrorLogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        let input = DiagnosticsInput(appInfo: .current(), paths: AppPaths(home: home), defaults: defaults, now: Self.t0,
                                     errors: [ErrorLogEntry(ts: Self.t0, area: .metrics,
                                                            message: "metricsWrite: \(home.path)/m.jsonl 203.0.113.9")])
        let files = try XCTUnwrap(ZipArchive.read(DiagnosticsBundle.archive(input)))
        XCTAssertEqual(files.map(\.name), DiagnosticsBundle.fileNames)
        XCTAssertEqual(files.last?.name, "errors.json")
        let text = String(decoding: try XCTUnwrap(files.last).data, as: UTF8.self)
        XCTAssertTrue(text.contains("metricsWrite: ~/m.jsonl 203.0.x.x"), text)
        XCTAssertFalse(text.contains(home.path))

        // Without errors the file is still there, with an empty list.
        let empty = DiagnosticsInput(appInfo: .current(), paths: AppPaths(home: home), defaults: defaults, now: Self.t0)
        let emptyFiles = try XCTUnwrap(ZipArchive.read(DiagnosticsBundle.archive(empty)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(emptyFiles.last).data) as? [String: Any])
        XCTAssertEqual((object["errors"] as? [Any])?.count, 0)
    }

    // MARK: Persistence

    func testRecordsArePersistedAndReloaded() throws {
        let temp = try TempDirectory()
        let file = AppPaths(home: temp.url).errorsFile
        XCTAssertEqual(file.lastPathComponent, "errors.json")
        let log = ErrorLog(fileURL: file)
        log.record(.update, "update: feedUnavailable", at: Self.t0)
        log.record(.backup, "manualBackup: x", at: Self.t0 + 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(log.status, .ok)

        let reloaded = ErrorLog(fileURL: file)
        XCTAssertEqual(reloaded.entries, log.entries)
        XCTAssertEqual(reloaded.entries.map(\.area), [.update, .backup])   // oldest first, same as in memory
        reloaded.record(.login, "loginItem: y", at: Self.t0 + 9)
        XCTAssertEqual(ErrorLog(fileURL: file).entries.map(\.message), ["update: feedUnavailable", "manualBackup: x", "loginItem: y"])
    }

    func testFiftyFirstRecordDropsTheOldestOnDiskToo() throws {
        let temp = try TempDirectory()
        let file = AppPaths(home: temp.url).errorsFile
        let log = ErrorLog(fileURL: file)
        for index in 0...ErrorLog.capacity {
            log.record(.metrics, "error\(index)", at: Self.t0 + Double(index))
        }
        let reloaded = ErrorLog(fileURL: file).entries
        XCTAssertEqual(reloaded.count, 50)
        XCTAssertEqual(reloaded.first?.message, "error1")
        XCTAssertEqual(reloaded.last?.message, "error50")
    }

    func testDamagedFileIsIgnoredAndOverwritten() throws {
        let temp = try TempDirectory()
        let file = AppPaths(home: temp.url).errorsFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        let log = ErrorLog(fileURL: file)
        XCTAssertEqual(log.entries, [])
        XCTAssertEqual(log.status, .ok)
        log.record(.watch, "watchState: z", at: Self.t0)
        XCTAssertEqual(ErrorLog(fileURL: file).entries.map(\.message), ["watchState: z"])
    }

    func testAtomicWriteLeavesOnlyErrorsJSON() throws {
        let temp = try TempDirectory()
        let file = AppPaths(home: temp.url).errorsFile
        let log = ErrorLog(fileURL: file)
        for index in 0..<10 { log.record(.update, "e\(index)", at: Self.t0 + Double(index)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["errors.json"], "no temporary files are left behind")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["errors"] as? [Any])?.count, 10)
    }

    func testWriteFailureIsReportedInTheDiagnosticsManifest() throws {
        let temp = try TempDirectory()
        // The log's folder is a regular file, so the write cannot succeed.
        let blocker = temp.url.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let log = ErrorLog(fileURL: blocker.appendingPathComponent("errors.json"))
        log.record(.backup, "manualBackup: x", at: Self.t0)
        XCTAssertEqual(log.status, .writeFailed)
        XCTAssertEqual(log.entries.count, 1, "the entry stays in memory")

        let suite = "ErrorLogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func manifest(_ status: ErrorLogStatus) throws -> [String: Any] {
            let input = DiagnosticsInput(appInfo: .current(), paths: AppPaths(home: temp.url), defaults: defaults, now: Self.t0,
                                         errors: log.entries, errorLogStatus: status)
            let files = try XCTUnwrap(ZipArchive.read(DiagnosticsBundle.archive(input)))
            let info = try XCTUnwrap(files.first { $0.name == "app-info.json" })
            return try XCTUnwrap(JSONSerialization.jsonObject(with: info.data) as? [String: Any])
        }
        XCTAssertEqual(try manifest(log.status)["errorLogStatus"] as? String, "writeFailed")
        XCTAssertEqual(try manifest(.ok)["errorLogStatus"] as? String, "ok")
    }

    func testDiagnosticsZipCarriesPersistedRecords() throws {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        ErrorLog(fileURL: paths.errorsFile).record(.update, "update: from \(temp.url.path) 203.0.113.9", at: Self.t0)
        let reloaded = ErrorLog(fileURL: paths.errorsFile)   // as after a restart
        let suite = "ErrorLogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = DiagnosticsInput(appInfo: .current(), paths: paths, defaults: defaults, now: Self.t0,
                                     errors: reloaded.entries, errorLogStatus: reloaded.status)
        let files = try XCTUnwrap(ZipArchive.read(DiagnosticsBundle.archive(input)))
        let text = String(decoding: try XCTUnwrap(files.first { $0.name == "errors.json" }).data, as: UTF8.self)
        XCTAssertTrue(text.contains("update: from ~ 203.0.x.x"), text)
        XCTAssertFalse(text.contains(temp.url.path))
    }

    func testRemoveAllDeletesTheFile() throws {
        let temp = try TempDirectory()
        let file = AppPaths(home: temp.url).errorsFile
        let log = ErrorLog(fileURL: file)
        log.record(.update, "x", at: Self.t0)
        log.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(ErrorLog(fileURL: file).entries, [])
    }

    // MARK: App error points

    func testAppErrorsAreLoggedWithoutNewUserMessages() async throws {
        let env = try TestAppEnvironment()
        let login = FakeLoginItem()
        login.fails = true
        let model = env.makeModel(updates: HTTPScript(defaultBody: nil)) { $0.loginItem = login }

        // Launch at login refused (Settings already shows this error; the log only adds a diagnostics line).
        model.setLaunchAtLogin(true)
        // Manual update check without the feed (Settings shows the failure).
        await model.checkForUpdates(manual: true)?.value
        // Manual backup into a folder that does not exist.
        let missing = env.temp.url.appendingPathComponent("nope/backup.zip")
        try env.historyStore.append([HistoryEntry(ts: Self.t0, kind: .ipChanged, old: "a", new: "b")])
        let result = await model.writeFullBackup(to: missing)
        guard case .failure = result else { return XCTFail("expected a backup failure") }

        let entries = model.errorLog.entries
        XCTAssertEqual(entries.map(\.area), [.login, .update, .backup], entries.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(entries[0].message.hasPrefix("loginItem: "))
        XCTAssertEqual(entries[1].message, "update: feedUnavailable")
        XCTAssertTrue(entries[2].message.hasPrefix("manualBackup: "))
        XCTAssertTrue(entries.allSatisfy { $0.ts == env.clock.now })
        XCTAssertNil(model.serverLinkOutcome)
        XCTAssertNil(model.saveErrorMessage)

        // The diagnostics package of the model carries them.
        let zip = await model.diagnosticsArchive(appInfo: DiagnosticsAppInfo(version: "1.0", build: "1", osVersion: "x",
                                                                            architecture: "arm64", language: "en"))
        let files = try XCTUnwrap(ZipArchive.read(zip))
        let errors = try XCTUnwrap(files.first { $0.name == "errors.json" })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: errors.data) as? [String: Any])
        XCTAssertEqual((object["errors"] as? [[String: Any]])?.compactMap { $0["area"] as? String }, ["login", "update", "backup"])
    }

    func testRestoreAndAutomaticBackupFailuresAreLogged() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        // A history file that exists but holds no decodable line: the automatic backup has no usable data.
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/history.jsonl", "not json\n")
        let automatic = await model.runAutomaticBackupIfDue()?.value
        guard case .failure(.noUsableData)? = automatic else { return XCTFail("expected noUsableData, got \(String(describing: automatic))") }

        XCTAssertTrue(model.beginDataOperation(.erase))
        let busy = await model.restoreFullBackup(try XCTUnwrap(sampleBackup()))
        model.endDataOperation()
        XCTAssertEqual(busy, .failure(.busy))

        let entries = model.errorLog.entries
        XCTAssertEqual(entries.map(\.area), [.backup], "the busy refusal happens before the restore starts")
        XCTAssertTrue(entries[0].message.hasPrefix("autoBackup: noUsableData"), entries[0].message)
    }

    private func sampleBackup() throws -> ParsedFullBackup? {
        let temp = try TempDirectory()
        let paths = AppPaths(home: temp.url)
        try HistoryStore(fileURL: paths.historyFile).append([HistoryEntry(ts: Self.t0, kind: .ipChanged, old: "a", new: "b")])
        let (data, _) = try FullBackupStore(paths: paths, appVersion: "1.0").archive(kind: .manual, now: Self.t0)
        return try FullBackupParser.parse(data).get()
    }
}

import XCTest
@testable import PlayerIdentity

/// §46.3: settings / server export-import.
@MainActor
final class SettingsArchiveTests: XCTestCase {
    override func tearDown() {
        L10n.setting = .system
        super.tearDown()
    }

    private func draft(_ label: String, _ host: String, _ port: Int = 27015, group: String = "", favorite: Bool = false) -> ServerDraft {
        ServerDraft(label: label, host: host, portText: String(port), group: group, favorite: favorite)
    }

    private func parse(_ archive: SettingsArchive) throws -> ParsedSettingsArchive {
        try SettingsArchiveParser.parse(archive.encoded()).get()
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func validObject(servers: Any? = nil) -> [String: Any] {
        var object: [String: Any] = ["schemaVersion": 1, "appVersion": "2.6.0", "exportedAt": "2026-11-10T10:00:00Z",
                                     "scope": "settingsAndServers", "settings": ["language": "tr"]]
        if let servers { object["servers"] = servers }
        return object
    }

    // MARK: Roundtrip

    func testRoundtripSettingsOnly() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.appLanguage = .tr
        model.notifyMapChanges = false
        model.quietHoursEnabled = true
        model.quietHoursStart = "22:30"
        model.banCheckEnabled = false
        model.addServer(draft("A", "a.example.com"))
        let archive = model.settingsArchive(scope: .settingsOnly, includeDataRoot: false)
        XCTAssertNil(archive.servers)
        XCTAssertNil(archive.settings.dataRoot)
        let parsed = try parse(archive)
        XCTAssertEqual(parsed.archive.settings, archive.settings)
        XCTAssertEqual(parsed.archive.scope, .settingsOnly)
        XCTAssertEqual(parsed.invalidCount, 0)
        XCTAssertEqual(parsed.archive.exportedAt.timeIntervalSince1970, archive.exportedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testRoundtripSettingsAndServersFieldsExact() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.addServer(draft("Alpha", "alpha.example.com", 27016, group: "RPG", favorite: true))
        model.addServer(draft("Beta", "192.0.2.5"))
        let id = try XCTUnwrap(model.servers.first { $0.label == "Alpha" }?.id)
        XCTAssertNil(model.setNote("Not", for: id))
        let appeal = Appeal(sentAt: Date(timeIntervalSince1970: 1_700_000_000), channel: "discord", summary: "özet")
        XCTAssertNil(model.saveAppeal(appeal, for: id))
        let archive = model.settingsArchive(scope: .settingsAndServers, includeDataRoot: false)
        let parsed = try parse(archive)
        let rows = try XCTUnwrap(parsed.archive.servers)
        XCTAssertEqual(rows, archive.servers)
        XCTAssertEqual(rows.count, 2)
        let alpha = try XCTUnwrap(rows.first { $0.label == "Alpha" })
        XCTAssertEqual(alpha.host, "alpha.example.com")
        XCTAssertEqual(alpha.port, 27016)
        XCTAssertEqual(alpha.group, "RPG")
        XCTAssertTrue(alpha.favorite)
        XCTAssertEqual(alpha.note, "Not")
        XCTAssertEqual(alpha.appeal?.channel, "discord")
    }

    func testExportNeverContainsCIDOrIdentityOrHistory() async throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.addServer(draft("A", "a.example.com"))
        await model.refresh().value
        model.save()
        let text = try String(decoding: model.settingsArchive(scope: .settingsAndServers, includeDataRoot: true).encoded(), as: UTF8.self)
        for forbidden in ["\"cid\"", "rawID", "10331C2DCE4C91DB", "\"banCheck\"", "lastCheckedAt", "history", "metrics"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testFileNameFormat() {
        let name = SettingsArchive.defaultFileName(now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "playeridentity-settings-20231114-221320.json")
    }

    // MARK: Schema validation

    func testMissingVersionRejected() throws {
        var object = validObject()
        object["schemaVersion"] = nil
        XCTAssertEqual(SettingsArchiveParser.parse(try json(object)), .failure(.missingVersion))
    }

    func testUnknownVersionRejected() throws {
        var object = validObject()
        object["schemaVersion"] = 2
        XCTAssertEqual(SettingsArchiveParser.parse(try json(object)), .failure(.unsupportedVersion(2)))
    }

    func testBrokenJSONRejected() {
        XCTAssertEqual(SettingsArchiveParser.parse(Data("{not json".utf8)), .failure(.notJSON))
        XCTAssertEqual(SettingsArchiveParser.parse(Data("[1,2]".utf8)), .failure(.notJSON))
    }

    func testWrongTypesRejected() throws {
        var object = validObject()
        object["settings"] = ["notificationsEnabled": "yes"]
        XCTAssertEqual(SettingsArchiveParser.parse(try json(object)), .failure(.invalid))
        object = validObject()
        object["schemaVersion"] = "1"
        XCTAssertEqual(SettingsArchiveParser.parse(try json(object)), .failure(.invalid))
        object = validObject()
        object["servers"] = "nope"
        XCTAssertEqual(SettingsArchiveParser.parse(try json(object)), .failure(.invalid))
        object = validObject()
        object["scope"] = "everything"
        XCTAssertEqual(SettingsArchiveParser.parse(try json(object)), .failure(.invalid))
        object = validObject()
        object["settings"] = nil
        XCTAssertEqual(SettingsArchiveParser.parse(try json(object)), .failure(.invalid))
    }

    func testUnknownFieldsIgnored() throws {
        var object = validObject(servers: [["label": "A", "host": "a.example.com", "port": 27015, "future": [1, 2]]])
        object["extra"] = ["x": 1]
        object["settings"] = ["language": "en", "somethingNew": true]
        let parsed = try SettingsArchiveParser.parse(json(object)).get()
        XCTAssertEqual(parsed.archive.settings.language, "en")
        XCTAssertEqual(parsed.archive.servers?.count, 1)
        XCTAssertEqual(parsed.invalidCount, 0)
    }

    func testInvalidRowsAndValuesCounted() throws {
        let rows: [Any] = [
            ["label": "OK", "host": "ok.example.com", "port": 27015],
            ["label": "", "host": "x.example.com", "port": 27015],
            ["label": "Bad host", "host": "bad host!", "port": 27015],
            ["label": "Bad port", "host": "p.example.com", "port": 70000],
            ["label": "Missing", "host": "m.example.com"],
            "text",
            ["label": "Bad url", "host": "u.example.com", "port": 1, "banListURL": "http://insecure.example/{cid}"],
        ]
        var object = validObject(servers: rows)
        object["settings"] = ["language": "klingon", "quietHoursStart": "25:99", "gamedir": "../etc", "dataRoot": "relative"]
        let parsed = try SettingsArchiveParser.parse(json(object)).get()
        XCTAssertEqual(parsed.archive.servers?.count, 1)
        XCTAssertEqual(parsed.invalidServers, 6)
        XCTAssertEqual(parsed.invalidSettings, 4)
        XCTAssertEqual(parsed.archive.settings.count(includingDataRoot: true), 0)
    }

    func testFileReadRefusesSymlinkNonJSONAndOversize() throws {
        let temp = try TempDirectory()
        let data = try json(validObject())
        let real = try temp.write("real.json", data)
        XCTAssertNotNil(try? SettingsArchiveParser.read(real).get())
        let link = temp.url.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(SettingsArchiveParser.read(link), .failure(.symbolicLink))
        let txt = try temp.write("file.txt", data)
        XCTAssertEqual(SettingsArchiveParser.read(txt), .failure(.notJSON))
        let big = try temp.write("big.json", Data(repeating: 0x20, count: SettingsArchive.maxFileSize + 1))
        XCTAssertEqual(SettingsArchiveParser.read(big), .failure(.tooLarge))
        XCTAssertEqual(SettingsArchiveParser.read(temp.url.appendingPathComponent("none.json")), .failure(.unreadable))
    }

    // MARK: Merge

    private func archive(_ servers: [ArchivedServer]?, settings: ArchivedSettings = ArchivedSettings()) -> ParsedSettingsArchive {
        ParsedSettingsArchive(archive: SettingsArchive(appVersion: "2.6.0", exportedAt: Date(),
                                                       scope: servers == nil ? .settingsOnly : .settingsAndServers,
                                                       settings: settings, servers: servers),
                              invalidSettings: 0, invalidServers: 0)
    }

    func testMergeAddsUpdatesKeepsLocalAndCountsConflicts() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.addServer(draft("Local only", "local.example.com"))
        model.addServer(draft("Old label", "shared.example.com", 27015, group: "Eski"))
        let sharedID = try XCTUnwrap(model.servers.first { $0.host == "shared.example.com" }?.id)
        let incoming = [
            ArchivedServer(label: "New label", host: "SHARED.example.com", port: 27015, group: "Yeni", favorite: true,
                           watch: true, note: "n", banListURL: "https://bans.example.com/{cid}"),
            ArchivedServer(label: "Fresh", host: "fresh.example.com", port: 27016),
            ArchivedServer(label: "Dup", host: "fresh.example.com", port: 27016),
        ]
        let parsed = archive(incoming)
        let preview = model.importPreview(parsed, includeDataRoot: false)
        XCTAssertEqual(preview.conflictCount, 1)
        XCTAssertEqual(preview.serverCount, 3)
        let summary = try model.importSettings(parsed, mode: .merge, includeDataRoot: false).get()
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(model.servers.count, 3)
        XCTAssertNotNil(model.servers.first { $0.label == "Local only" })
        let shared = try XCTUnwrap(model.servers.first { $0.id == sharedID })
        XCTAssertEqual(shared.label, "New label")
        XCTAssertEqual(shared.group, "Yeni")
        XCTAssertTrue(shared.favorite)
        XCTAssertTrue(shared.watch)
        XCTAssertEqual(shared.note, "n")
        XCTAssertEqual(shared.banListURL, "https://bans.example.com/{cid}")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertNil(model.snapshotState.snapshot)
    }

    func testMergeIdenticalRowIsSkipped() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.addServer(draft("A", "a.example.com"))
        let parsed = try parse(model.settingsArchive(scope: .settingsAndServers, includeDataRoot: false))
        let summary = try model.importSettings(parsed, mode: .merge, includeDataRoot: false).get()
        XCTAssertEqual([summary.added, summary.updated, summary.skipped], [0, 0, 1])
    }

    func testInvalidRowsCountAsSkipped() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        var parsed = archive([ArchivedServer(label: "A", host: "a.example.com", port: 1)])
        parsed.invalidServers = 2
        let summary = try model.importSettings(parsed, mode: .merge, includeDataRoot: false).get()
        XCTAssertEqual([summary.added, summary.updated, summary.skipped], [1, 0, 2])
    }

    func testSettingsOnlyArchiveLeavesServersAlone() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.addServer(draft("A", "a.example.com"))
        let summary = try model.importSettings(archive(nil), mode: .replace, includeDataRoot: false).get()
        XCTAssertEqual(model.servers.count, 1)
        XCTAssertNil(summary.backupFile)
    }

    // MARK: Replace

    func testReplaceBacksUpRecordAndReplacesList() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.addServer(draft("Gone", "gone.example.com"))
        model.addServer(draft("Kept", "kept.example.com"))
        model.save()
        let keptID = try XCTUnwrap(model.servers.first { $0.host == "kept.example.com" }?.id)
        let record = AppPaths(home: environment.home).snapshotFile
        let original = try Data(contentsOf: record)
        let parsed = archive([ArchivedServer(label: "Kept new", host: "kept.example.com", port: 27015),
                              ArchivedServer(label: "Brand new", host: "brand.example.com", port: 27015)])
        let summary = try model.importSettings(parsed, mode: .replace, includeDataRoot: false).get()
        let backup = try XCTUnwrap(summary.backupFile)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("profile.json.appbak-"))
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(Set(model.servers.map(\.host)), ["kept.example.com", "brand.example.com"])
        XCTAssertEqual(model.servers.first { $0.host == "kept.example.com" }?.id, keptID)
        XCTAssertEqual(model.servers.first { $0.host == "kept.example.com" }?.label, "Kept new")
        XCTAssertEqual([summary.added, summary.updated], [1, 1])
        // No undo: the record on disk is untouched until Save, the list in memory is the new one.
        XCTAssertEqual(try Data(contentsOf: record), original)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testReplaceBackupFailureChangesNothing() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.addServer(draft("A", "a.example.com"))
        model.save()
        let record = AppPaths(home: environment.home).snapshotFile
        // A read-only record folder makes the backup copy impossible.
        let folder = record.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let result = model.importSettings(archive([ArchivedServer(label: "Z", host: "z.example.com", port: 1)]),
                                          mode: .replace, includeDataRoot: false)
        guard case .failure(.backupFailed) = result else { return XCTFail("expected backup failure") }
        XCTAssertEqual(model.servers.map(\.host), ["a.example.com"])
    }

    func testReplaceWithoutRecordHasNoBackup() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        let summary = try model.importSettings(archive([ArchivedServer(label: "Z", host: "z.example.com", port: 1)]),
                                               mode: .replace, includeDataRoot: false).get()
        XCTAssertNil(summary.backupFile)
        XCTAssertEqual(model.servers.count, 1)
    }

    func testBackupNameFormat() {
        let url = RecordBackup.backupURL(for: URL(fileURLWithPath: "/tmp/x/profile.json"),
                                         at: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(url.path, "/tmp/x/profile.json.appbak-20231114-221320")
    }

    // MARK: dataRoot

    func testDataRootExcludedByDefaultAndKeptOnImport() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        let before = model.dataRoot
        XCTAssertNil(model.settingsArchive(scope: .settingsOnly, includeDataRoot: false).settings.dataRoot)
        XCTAssertNotNil(model.settingsArchive(scope: .settingsOnly, includeDataRoot: true).settings.dataRoot)
        var settings = ArchivedSettings()
        settings.dataRoot = "/tmp/elsewhere"
        let parsed = archive(nil, settings: settings)
        XCTAssertEqual(model.importPreview(parsed, includeDataRoot: false).settingCount, 0)
        XCTAssertEqual(model.importPreview(parsed, includeDataRoot: true).settingCount, 1)
        _ = try model.importSettings(parsed, mode: .merge, includeDataRoot: false).get()
        XCTAssertEqual(model.dataRoot, before)
        _ = try model.importSettings(parsed, mode: .merge, includeDataRoot: true).get()
        XCTAssertEqual(model.dataRoot.path, "/tmp/elsewhere")
        XCTAssertEqual(environment.defaults.string(forKey: DefaultsKey.dataRoot), "/tmp/elsewhere")
    }

    // MARK: Applying values

    func testSettingsValuesApplyAndPersist() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        let settings = ArchivedSettings(language: "en", notificationsEnabled: false, notifyBanChanges: false,
                                        notifyOnlineChanges: false, notifyMapChanges: false, quietHoursEnabled: true,
                                        quietHoursStart: "21:15", quietHoursEnd: "07:45", showInMenuBar: true,
                                        autoCheckUpdates: false, autoDownloadUpdates: true, banCheckEnabled: false)
        let summary = try model.importSettings(archive(nil, settings: settings), mode: .merge, includeDataRoot: false).get()
        XCTAssertEqual(summary.settingsApplied, 12)
        XCTAssertEqual(model.appLanguage, .en)
        XCTAssertEqual(L10n.setting, .en)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertFalse(model.notifyBanChanges)
        XCTAssertFalse(model.notifyOnlineChanges)
        XCTAssertFalse(model.notifyMapChanges)
        XCTAssertTrue(model.quietHoursEnabled)
        XCTAssertEqual(model.quietHoursStart, "21:15")
        XCTAssertEqual(model.quietHoursEnd, "07:45")
        XCTAssertTrue(model.menuBarEnabled)
        XCTAssertFalse(model.updates.preferences.autoCheck)
        XCTAssertTrue(model.updates.preferences.autoDownload)
        XCTAssertFalse(model.banCheckEnabled)
        let defaults = environment.defaults
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.appLanguage), "en")
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.quietHoursStart), "21:15")
        XCTAssertEqual(defaults.bool(forKey: DefaultsKey.showInMenuBar), true)
        XCTAssertEqual(defaults.object(forKey: UpdatePreferences.Key.autoDownload) as? Bool, true)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testMissingSettingsAreNotTouched() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.notifyMapChanges = false
        _ = try model.importSettings(archive(nil, settings: ArchivedSettings(notifyBanChanges: false)),
                                     mode: .merge, includeDataRoot: false).get()
        XCTAssertFalse(model.notifyMapChanges)
        XCTAssertFalse(model.notifyBanChanges)
        XCTAssertTrue(model.notificationsEnabled)
    }

    func testFullFileRoundtripBetweenModels() throws {
        let source = try TestAppEnvironment()
        let from = source.makeModel()
        from.appLanguage = .tr
        from.quietHoursEnabled = true
        from.addServer(draft("A", "a.example.com", 27020, group: "G"))
        let temp = try TempDirectory()
        let file = try temp.write("out.json", from.settingsArchive(scope: .settingsAndServers, includeDataRoot: false).encoded())
        let target = try TestAppEnvironment()
        let into = target.makeModel()
        let parsed = try SettingsArchiveParser.read(file).get()
        _ = try into.importSettings(parsed, mode: .merge, includeDataRoot: false).get()
        XCTAssertEqual(into.appLanguage, .tr)
        XCTAssertTrue(into.quietHoursEnabled)
        XCTAssertEqual(into.servers.map(\.host), ["a.example.com"])
        XCTAssertEqual(into.servers.first?.port, 27020)
        XCTAssertEqual(into.servers.first?.group, "G")
    }

    // MARK: l10n

    func testErrorTextsAreLocalized() {
        L10n.setting = .tr
        for error in [SettingsArchiveError.unreadable, .tooLarge, .symbolicLink, .notJSON, .missingVersion,
                      .unsupportedVersion(9), .invalid] {
            XCTAssertFalse(error.text.isEmpty)
            XCTAssertFalse(error.text.contains("import.error"))
        }
        XCTAssertEqual(SettingsArchiveError.notJSON.text, "Dosya geçerli bir JSON değil.")
        L10n.setting = .en
        XCTAssertEqual(SettingsArchiveError.notJSON.text, "The file is not valid JSON.")
    }
}

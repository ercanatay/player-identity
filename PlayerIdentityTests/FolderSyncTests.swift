import XCTest
@testable import PlayerIdentity

/// §71 folder-based sync: (a) merge matrix, (b) sensitive fields never written, (c) atomic write and damaged file
/// backup, (d) debounce / quit sync with a fake clock, (e) folder access errors, (f) the new keys in every language.
@MainActor
final class FolderSyncTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private static let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func record(_ id: UUID, _ label: String?, at seconds: TimeInterval) -> SyncRecord<SyncServer> {
        let stamp = Self.t0.addingTimeInterval(seconds)
        return SyncRecord(id: id, updatedAt: stamp, deletedAt: label == nil ? stamp : nil,
                          value: label.map { SyncServer(label: $0, host: "10.0.0.1", port: 27015, group: nil,
                                                        favorite: false, order: 0, notifications: nil) })
    }

    // MARK: (a) merge matrix

    func testMergeMatrix() {
        struct Case {
            let name: String
            let local: SyncRecord<SyncServer>?
            let remote: SyncRecord<SyncServer>?
            let expected: SyncRecord<SyncServer>?
            let conflicts: Int
        }
        let id = Self.idA
        let cases = [
            Case(name: "local only (new)", local: record(id, "L", at: 1), remote: nil, expected: record(id, "L", at: 1), conflicts: 0),
            Case(name: "remote only (new)", local: nil, remote: record(id, "R", at: 1), expected: record(id, "R", at: 1), conflicts: 0),
            Case(name: "same copy", local: record(id, "S", at: 1), remote: record(id, "S", at: 1), expected: record(id, "S", at: 1), conflicts: 0),
            Case(name: "local newer", local: record(id, "L", at: 2), remote: record(id, "R", at: 1), expected: record(id, "L", at: 2), conflicts: 0),
            Case(name: "remote newer", local: record(id, "L", at: 1), remote: record(id, "R", at: 2), expected: record(id, "R", at: 2), conflicts: 0),
            Case(name: "remote tombstone newer", local: record(id, "L", at: 1), remote: record(id, nil, at: 2), expected: record(id, nil, at: 2), conflicts: 0),
            Case(name: "local tombstone newer", local: record(id, nil, at: 3), remote: record(id, "R", at: 2), expected: record(id, nil, at: 3), conflicts: 0),
            Case(name: "re-added after tombstone", local: record(id, "L", at: 4), remote: record(id, nil, at: 3), expected: record(id, "L", at: 4), conflicts: 0),
            Case(name: "tombstone only remote", local: nil, remote: record(id, nil, at: 1), expected: record(id, nil, at: 1), conflicts: 0),
            Case(name: "same stamp, different content", local: record(id, "L", at: 5), remote: record(id, "R", at: 5), expected: record(id, "L", at: 5), conflicts: 1),
            Case(name: "same stamp, deleted vs alive", local: record(id, "L", at: 5), remote: record(id, nil, at: 5), expected: record(id, "L", at: 5), conflicts: 1),
        ]
        for item in cases {
            let result = FolderSyncMerge.merge(local: item.local.map { [$0] } ?? [], remote: item.remote.map { [$0] } ?? [])
            XCTAssertEqual(result.records, item.expected.map { [$0] } ?? [], item.name)
            XCTAssertEqual(result.conflicts, item.conflicts, item.name)
        }
    }

    func testStampKeepsUnchangedStampsAndTombstonesDeletions() {
        let ledger = [record(Self.idA, "A", at: 1), record(Self.idB, "B", at: 1)]
        let value = ledger[0].value!
        let now = Self.t0.addingTimeInterval(10)
        // A unchanged, B deleted locally.
        let stamped = FolderSyncMerge.stamp([Self.idA: value], ledger, now: now, allowDeletions: true)
        XCTAssertEqual(stamped.first { $0.id == Self.idA }, ledger[0])
        let tombstone = stamped.first { $0.id == Self.idB }
        XCTAssertEqual(tombstone?.isDeleted, true)
        XCTAssertNil(tombstone?.value)
        XCTAssertEqual(tombstone?.updatedAt, now)
        // A changed: new stamp.
        var changed = value
        changed.label = "A2"
        let edited = FolderSyncMerge.stamp([Self.idA: changed], ledger, now: now, allowDeletions: true)
        XCTAssertEqual(edited.first { $0.id == Self.idA }?.updatedAt, now)
        // No local record yet: nothing is deleted, the ledger rows are left to the remote side.
        let fresh = FolderSyncMerge.stamp([:], ledger, now: now, allowDeletions: false)
        XCTAssertTrue(fresh.isEmpty)
        // A clock that did not move still produces a later stamp than the previous one.
        let same = FolderSyncMerge.stamp([Self.idA: changed], ledger, now: Self.t0.addingTimeInterval(1), allowDeletions: true)
        XCTAssertGreaterThan(same[0].updatedAt, ledger[0].updatedAt)
    }

    func testRebaseKeepsRowsEditedSinceBase() {
        let a = ServerEntry(id: Self.idA, label: "A", host: "10.0.0.1")
        let b = ServerEntry(id: Self.idB, label: "B", host: "10.0.0.2")
        let base = SyncLocalData.make(profiles: [], servers: [a, b], settings: nil)
        var remoteA = a
        remoteA.label = "A remote"
        var editedB = b
        editedB.label = "B edited locally"
        let newID = UUID()
        let merged = SyncLocalData.make(profiles: [], servers: [remoteA, ServerEntry(id: newID, label: "N", host: "10.0.0.3")],
                                        settings: nil)
        // A takes the merged value, B was edited (kept even though merged deleted it), N is new.
        let result = FolderSyncApply.servers(current: [a, editedB], base: base, merged: merged)
        XCTAssertEqual(result.map(\.label), ["A remote", "B edited locally", "N"])
        // Unedited B is removed when merged deleted it.
        XCTAssertEqual(FolderSyncApply.servers(current: [a, b], base: base, merged: merged).map(\.id), [Self.idA, newID])
    }

    // MARK: (b) sensitive fields

    func testSyncFileNeverCarriesSecretsOrHistory() async throws {
        let env = try TestAppEnvironment()
        let folder = try makeFolder(env)
        var entry = ServerEntry(label: "Secret", host: "10.0.0.9", cid: "CIDVALUE1234", lastCheckedAt: Self.t0,
                                note: "note text", banListURL: "https://bans.example/list?cid={cid}&key=LISTTOKEN",
                                watch: true, banRecord: BanRecordConfig(urlTemplate: "https://api.example/{cid}", enabled: true))
        entry.appeal = Appeal(sentAt: Self.t0, channel: "Discord", notifiedAt: Self.t0)
        try writeRecord(env, servers: [entry])
        let secrets = InMemorySecretStore(["banRecord.\(entry.id.uuidString)": "BEARERTOKEN"])
        let model = env.makeModel { $0.secretStore = secrets }
        model.logError(.watch, "diagnosis history line")
        await model.setSyncFolder(folder).value
        XCTAssertNil(model.syncError)

        let data = try Data(contentsOf: folder.appendingPathComponent(SyncFile.fileName))
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["CIDVALUE1234", "LISTTOKEN", "BEARERTOKEN", "banListURL", "banRecord", "urlTemplate", "cid",
                          "lastCheckedAt", "banCheck", "rawID", "publicIP", "lanIPs", "rcon", "password", "token",
                          "history", "metrics", "diagnosis", "notifiedAt", "dataRootDefaults"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()), "sync file contains \(forbidden)")
        }
        // Only the §71.1 top-level fields.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "deviceID", "updatedAt", "profiles", "servers", "watched",
                                          "settings", "notes"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertTrue(text.contains("note text"))
        XCTAssertTrue(text.contains("Discord"))
        // Every record carries `updatedAt`.
        for key in ["profiles", "servers", "watched", "notes"] {
            for item in try XCTUnwrap(object[key] as? [[String: Any]]) { XCTAssertNotNil(item["updatedAt"], key) }
        }
    }

    // MARK: Two devices

    func testTwoDevicesShareServersDeletionsAndSettings() async throws {
        let shared = try TempDirectory()
        let folder = shared.url.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let envA = try TestAppEnvironment(), envB = try TestAppEnvironment()
        let a = envA.makeModel(), b = envB.makeModel()

        a.addServer(ServerDraft(label: "Zombie", host: "10.0.0.11"))
        a.save()
        let id = try XCTUnwrap(a.servers.first?.id)
        XCTAssertNil(a.setNote("ask admin", for: id))
        a.setWatch(true, for: id)
        a.save()
        a.notifyMapChanges = false
        await a.setSyncFolder(folder).value
        XCTAssertNil(a.syncError)

        envB.clock.advance(60)
        await b.setSyncFolder(folder).value
        XCTAssertNil(b.syncError)
        XCTAssertEqual(b.servers.map(\.label), ["Zombie"])
        XCTAssertEqual(b.servers.first?.note, "ask admin")
        XCTAssertEqual(b.servers.first?.watch, true)
        XCTAssertFalse(b.notifyMapChanges)
        XCTAssertFalse(b.hasUnsavedChanges)
        // Saved on B as well.
        XCTAssertEqual(SnapshotStore(fileURL: AppPaths(home: envB.home).snapshotFile).load().snapshot?.servers.count, 1)

        // B deletes the server: the tombstone removes it on A too.
        envB.clock.advance(60)
        b.deleteServer(id: id)
        b.save()
        await b.syncNow().value
        envA.clock.advance(180)
        await a.syncNow().value
        XCTAssertTrue(a.servers.isEmpty)
        let file = try readFile(folder)
        XCTAssertEqual(file.servers.first { $0.id == id }?.isDeleted, true)
        XCTAssertEqual(a.syncConflictCount, 0)
    }

    func testEqualStampWithDifferentContentKeepsLocalAndCountsConflict() async throws {
        let env = try TestAppEnvironment()
        let folder = try makeFolder(env)
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "Local", host: "10.0.0.1"))
        model.save()
        await model.setSyncFolder(folder).value
        // Another device wrote the same record with the same stamp but another label.
        var file = try readFile(folder)
        file.servers[0].value?.label = "Remote"
        file.deviceID = "other"
        try SyncCoding.encode(file).write(to: folder.appendingPathComponent(SyncFile.fileName))
        await model.syncNow().value
        XCTAssertEqual(model.servers.map(\.label), ["Local"])
        XCTAssertEqual(model.syncConflictCount, 1)
        XCTAssertEqual(try readFile(folder).servers[0].value?.label, "Local")
    }

    // MARK: (c) atomic write and damaged file

    func testAtomicWriteReplacesWithoutLeftovers() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent(SyncFile.fileName)
        let access = LocalSyncFolderAccess()
        try access.writeAtomically(Data("one".utf8), to: url)
        try access.writeAtomically(Data("two".utf8), to: url)
        XCTAssertEqual(try access.read(url), Data("two".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path), [SyncFile.fileName])
        XCTAssertNil(try access.read(temp.url.appendingPathComponent("missing.json")))
    }

    func testDamagedFileIsBackedUpAndLocalDataStays() async throws {
        let env = try TestAppEnvironment()
        let folder = try makeFolder(env)
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "Keep", host: "10.0.0.1"))
        model.save()
        let damaged: [UInt8] = [0x7B, 0x22, 0x73, 0x63, 0x68]   // `{"sch` — cut short
        try Data(damaged).write(to: folder.appendingPathComponent(SyncFile.fileName))
        await model.setSyncFolder(folder).value

        let backupName = "\(SyncFile.fileName).corrupt-" + FullBackupNaming.formatter("yyyyMMdd-HHmmss", timeZone: .current)
            .string(from: env.clock.now)
        XCTAssertEqual(model.syncError, .corrupt(backup: backupName))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(backupName)), Data(damaged))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(SyncFile.fileName).path))
        XCTAssertEqual(model.servers.map(\.label), ["Keep"])
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.errorLog.entries.last?.area, .sync)
        XCTAssertTrue(model.syncError?.text.contains(backupName) ?? false)

        // The next sync writes a fresh file from the local data.
        await model.syncNow().value
        XCTAssertNil(model.syncError)
        XCTAssertEqual(try readFile(folder).servers.compactMap(\.value?.label), ["Keep"])
    }

    func testNewerSchemaIsLeftUntouched() async throws {
        let env = try TestAppEnvironment()
        let folder = try makeFolder(env)
        let model = env.makeModel()
        let newer = Data(#"{"schemaVersion": 2, "servers": []}"#.utf8)
        let url = folder.appendingPathComponent(SyncFile.fileName)
        try newer.write(to: url)
        await model.setSyncFolder(folder).value
        XCTAssertEqual(model.syncError, .unsupportedVersion(2))
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }

    func testSecondPassWhenAnotherDeviceWritesMeanwhile() {
        let access = RacingAccess()
        let engine = FolderSyncEngine(access: access)
        let local = SyncLocalData(servers: [Self.idA: record(Self.idA, "A", at: 0).value!])
        let result = engine.run(folder: URL(fileURLWithPath: "/sync"), local: local, ledger: nil, deviceID: "me",
                                now: Self.t0, allowDeletions: true)
        guard case .success(let outcome) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(outcome.passes, 2)
        // The other device's record survived the race.
        XCTAssertEqual(Set(outcome.merged.servers.map(\.id)), [Self.idA, Self.idB])
    }

    // MARK: (d) debounce and quit

    func testDebounceMath() {
        var debounce = SyncDebounce()
        XCTAssertNil(debounce.remaining(now: Self.t0))
        debounce.schedule(now: Self.t0)
        XCTAssertEqual(debounce.remaining(now: Self.t0.addingTimeInterval(2)), 3)
        debounce.schedule(now: Self.t0.addingTimeInterval(3))   // a second write pushes it back
        XCTAssertFalse(debounce.fire(now: Self.t0.addingTimeInterval(5)))
        XCTAssertTrue(debounce.fire(now: Self.t0.addingTimeInterval(8)))
        XCTAssertFalse(debounce.fire(now: Self.t0.addingTimeInterval(9)))
        XCTAssertEqual(SyncDebounce.delay, 5)
        XCTAssertEqual(SyncDebounce.quitBudget, 2)
    }

    func testSavesAreDebouncedIntoOneSync() async throws {
        let env = try TestAppEnvironment()
        let folder = try makeFolder(env)
        let model = env.makeModel()
        await model.setSyncFolder(folder).value
        let runs = model.syncRunCount
        let start = env.clock.now
        model.addServer(ServerDraft(label: "One", host: "10.0.0.1"))
        model.save()
        model.addServer(ServerDraft(label: "Two", host: "10.0.0.2"))
        model.save()
        let timer = try XCTUnwrap(model.pendingSyncTimer)
        await timer.value
        XCTAssertEqual(model.syncRunCount, runs + 1)
        XCTAssertGreaterThanOrEqual(env.clock.now.timeIntervalSince(start), SyncDebounce.delay)
        XCTAssertEqual(try readFile(folder).servers.compactMap(\.value?.label).sorted(), ["One", "Two"])
        // Without a folder nothing is planned.
        model.removeSyncFolder()
        model.save()
        XCTAssertNil(model.pendingSyncTimer)
    }

    func testQuitSyncWritesAndIsBoundedByTwoSeconds() async throws {
        let env = try TestAppEnvironment()
        let folder = try makeFolder(env)
        // A slow sleeper: the sync finishes long before the 2 s budget.
        let model = env.makeModel { $0.sleeper = FakeSleeper(clock: env.clock, blocking: true) }
        model.addServer(ServerDraft(label: "Quit", host: "10.0.0.1"))
        model.save()
        await model.setSyncFolder(folder).value
        model.addServer(ServerDraft(label: "Late", host: "10.0.0.2"))
        model.save()
        let finished = await model.syncBeforeQuit()
        XCTAssertTrue(finished)
        XCTAssertNil(model.pendingSyncTimer)
        XCTAssertEqual(try readFile(folder).servers.compactMap(\.value?.label).sorted(), ["Late", "Quit"])

        // A disk that never answers: quitting waits only the budget (the fake clock moves 2 s).
        let stuckEnv = try TestAppEnvironment()
        let gate = BlockingAccess()
        let stuck = stuckEnv.makeModel { $0.syncFolderAccess = gate }
        stuck.addServer(ServerDraft(label: "S", host: "10.0.0.1"))
        stuck.save()
        stuck.removeSyncFolder()
        _ = stuck.setSyncFolder(URL(fileURLWithPath: "/sync"))
        let before = stuckEnv.clock.now
        let result = await stuck.syncBeforeQuit()
        XCTAssertFalse(result)
        XCTAssertEqual(stuckEnv.clock.now.timeIntervalSince(before), SyncDebounce.quitBudget)
        gate.release()
    }

    // MARK: (e) access errors

    func testFolderErrorsStopSyncAndKeepLocalData() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "Local", host: "10.0.0.1"))
        model.save()
        let saved = try Data(contentsOf: AppPaths(home: env.home).snapshotFile)

        await model.setSyncFolder(env.temp.url.appendingPathComponent("gone", isDirectory: true)).value
        XCTAssertEqual(model.syncError, .folderMissing)
        XCTAssertEqual(model.errorLog.entries.last?.area, .sync)
        XCTAssertEqual(model.errorLog.entries.last?.message, "folderMissing")

        let file = try env.temp.write("plain-file", "x")
        await model.setSyncFolder(file).value
        XCTAssertEqual(model.syncError, .folderMissing)

        let denied = env.makeModel { $0.syncFolderAccess = FailingAccess(state: .notAccessible, readFails: false) }
        await denied.setSyncFolder(URL(fileURLWithPath: "/sync")).value
        guard case .folderNotAccessible = denied.syncError else { return XCTFail("\(String(describing: denied.syncError))") }

        let unreadable = env.makeModel { $0.syncFolderAccess = FailingAccess(state: .ready, readFails: true) }
        await unreadable.setSyncFolder(URL(fileURLWithPath: "/sync")).value
        guard case .folderNotAccessible = unreadable.syncError else { return XCTFail() }
        XCTAssertFalse(unreadable.syncError?.text.isEmpty ?? true)

        XCTAssertEqual(model.servers.map(\.label), ["Local"])
        XCTAssertEqual(try Data(contentsOf: AppPaths(home: env.home).snapshotFile), saved)
    }

    func testRemovingTheFolderKeepsLocalDataAndTheFile() async throws {
        let env = try TestAppEnvironment()
        let folder = try makeFolder(env)
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "Stay", host: "10.0.0.1"))
        model.save()
        await model.setSyncFolder(folder).value
        model.removeSyncFolder()
        XCTAssertNil(model.syncFolder)
        XCTAssertNil(env.defaults.string(forKey: DefaultsKey.syncFolder))
        XCTAssertEqual(model.servers.map(\.label), ["Stay"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(SyncFile.fileName).path))
        // The folder choice survives a relaunch.
        await model.setSyncFolder(folder).value
        XCTAssertEqual(env.makeModel().syncFolder?.path, folder.standardizedFileURL.path)
    }

    // MARK: (f) keys

    func testSyncKeysExistInEveryLanguage() throws {
        let keys = L10nKey.allCases.filter { $0.rawValue.hasPrefix("sync.") }
        XCTAssertEqual(keys.count, 19)
        for language in AppLanguage.allCases {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                    subdirectory: nil, localization: language.rawValue))
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys { XCTAssertFalse(table[key.rawValue]?.isEmpty ?? true, "\(language.rawValue): \(key.rawValue)") }
        }
    }

    // MARK: Helpers

    private func makeFolder(_ env: TestAppEnvironment) throws -> URL {
        let folder = env.temp.url.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func readFile(_ folder: URL) throws -> SyncFile {
        let data = try Data(contentsOf: folder.appendingPathComponent(SyncFile.fileName))
        guard case .file(let file) = SyncCoding.decode(data) else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }

    private func writeRecord(_ env: TestAppEnvironment, servers: [ServerEntry]) throws {
        let snapshot = Snapshot(savedAt: Self.t0, gamedir: "valve", dataRoot: "", displayName: "N", model: "gordon",
                                rawID: "10331C2DCE4C91DB", identitySource: "", network: NetworkInfo(publicIP: "203.0.113.7",
                                                                                                   lanIPs: ["192.0.2.10"]),
                                servers: servers)
        try SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).save(snapshot)
    }
}

/// The folder is fine, but reading fails, or the folder cannot be accessed at all.
private struct FailingAccess: SyncFolderAccessing {
    let state: SyncFolderState
    let readFails: Bool

    func state(of folder: URL) -> SyncFolderState { state }
    func read(_ url: URL) throws -> Data? {
        if readFails { throw CocoaError(.fileReadNoPermission) }
        return nil
    }
    func writeAtomically(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    func move(_ source: URL, to destination: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

/// A disk that does not answer until released.
private final class BlockingAccess: SyncFolderAccessing, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func release() { semaphore.signal() }
    func state(of folder: URL) -> SyncFolderState {
        semaphore.wait()
        semaphore.signal()
        return .missing
    }
    func read(_ url: URL) throws -> Data? { nil }
    func writeAtomically(_ data: Data, to url: URL) throws {}
    func move(_ source: URL, to destination: URL) throws {}
}

/// In-memory folder where another device replaces the file right after our first write.
private final class RacingAccess: SyncFolderAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var content: Data?
    private var writes = 0

    func state(of folder: URL) -> SyncFolderState { .ready }
    func read(_ url: URL) throws -> Data? { lock.withLock { content } }
    func move(_ source: URL, to destination: URL) throws {}

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.withLock {
            writes += 1
            guard writes == 1 else {
                content = data
                return
            }
            // The other device's write lands over ours.
            let stamp = Date(timeIntervalSince1970: 1_793_000_001)
            var other = SyncFile(deviceID: "other", updatedAt: stamp)
            other.servers = [SyncRecord(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, updatedAt: stamp,
                                        deletedAt: nil, value: SyncServer(label: "B", host: "10.0.0.2", port: 27015,
                                                                          group: nil, favorite: false, order: 1,
                                                                          notifications: nil))]
            content = try? SyncCoding.encode(other)
        }
    }
}

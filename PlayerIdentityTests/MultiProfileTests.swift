import XCTest
@testable import PlayerIdentity

/// §61 multiple profiles: migration of a v2.10 record, add / rename / delete / make default, persistence of the active
/// profile, recomputation on a switch (no network), the delete limit, the duplicate pair, the game-running lock and
/// the profile stamp on history and metrics (older lines stay readable).
@MainActor
final class MultiProfileTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private static let legacyHome = "/Users/me"

    private func legacyFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: MultiProfileTests.self).url(forResource: "legacy-profile-v2.10", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// The v2.10 fixture with its home folder moved into the test environment.
    private func writeLegacyRecord(_ env: TestAppEnvironment) throws {
        let text = String(decoding: try legacyFixture(), as: UTF8.self)
            .replacingOccurrences(of: Self.legacyHome, with: env.home.path)
        let url = AppPaths(home: env.home).snapshotFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func recordJSON(_ env: TestAppEnvironment) throws -> [String: Any] {
        let data = try Data(contentsOf: AppPaths(home: env.home).snapshotFile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func defaultRoot(_ env: TestAppEnvironment) -> URL { AppPaths(home: env.home).defaultDataRoot }

    /// A second data root with a `cstrike` game folder.
    private func makeOtherRoot(_ env: TestAppEnvironment, identity: String? = nil) throws -> URL {
        _ = try env.temp.write("other root/cstrike/config.cfg", "name \"Other\"\nmodel \"leet\"\n")
        if let identity { _ = try env.temp.write("other root/cstrike/.xash_id", identity) }
        return env.temp.url.appendingPathComponent("other root", isDirectory: true)
    }

    // MARK: Migration

    func testLegacyRecordDecodesWithoutProfilesAndMigratesIntoDefault() throws {
        guard case .loaded(let snapshot) = SnapshotStore.decode(try legacyFixture()) else {
            return XCTFail("the v2.10 record must stay readable")
        }
        XCTAssertNil(snapshot.profiles)
        XCTAssertNil(snapshot.activeProfileID)
        XCTAssertEqual(snapshot.servers.count, 2)

        let defaultRoot = URL(fileURLWithPath: "/Users/me/Library/Application Support/Xash3D FWGS", isDirectory: true)
        let list = ProfileList.resolve(snapshot: snapshot, storedDataRoot: nil, defaultDataRoot: defaultRoot, now: Self.t0)
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.active.name, "Default")
        XCTAssertNil(list.active.dataRoot, "the default data root is stored as nil")
        XCTAssertEqual(list.active.gamedir, "valve")
        XCTAssertEqual(list.active.createdAt, Self.t0)
        XCTAssertEqual(list.defaultProfile.id, list.activeID)

        // Another default folder: the record's data root is kept explicitly.
        let elsewhere = ProfileList.resolve(snapshot: snapshot, storedDataRoot: nil,
                                            defaultDataRoot: URL(fileURLWithPath: "/tmp/none"), now: Self.t0)
        XCTAssertEqual(elsewhere.active.dataRoot, "/Users/me/Library/Application Support/Xash3D FWGS")
        // The UserDefaults data root wins (as in older versions).
        let stored = ProfileList.resolve(snapshot: snapshot, storedDataRoot: "/Volumes/Games/Xash",
                                         defaultDataRoot: defaultRoot, now: Self.t0)
        XCTAssertEqual(stored.active.dataRoot, "/Volumes/Games/Xash")
        // No record at all: a single Default on the default data root with automatic gamedir.
        let fresh = ProfileList.resolve(snapshot: nil, storedDataRoot: nil, defaultDataRoot: defaultRoot, now: Self.t0)
        XCTAssertEqual(fresh.profiles.map(\.name), ["Default"])
        XCTAssertEqual(fresh.active.gamedir, "")
    }

    func testBrokenProfileListKeepsTheRecordReadable() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try legacyFixture()) as? [String: Any])
        object["profiles"] = [["id": "not-a-uuid", "name": 5]]
        object["activeProfileID"] = "nope"
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .loaded(let snapshot) = SnapshotStore.decode(data) else { return XCTFail("record must load") }
        XCTAssertNil(snapshot.profiles)
        XCTAssertNil(snapshot.activeProfileID)
        XCTAssertEqual(snapshot.gamedir, "valve")
    }

    func testAppMigratesTheRealV210RecordAndWritesTheNewStructure() async throws {
        let env = try TestAppEnvironment()
        try writeLegacyRecord(env)
        let before = try Data(contentsOf: AppPaths(home: env.home).snapshotFile)
        let model = env.makeModel()

        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.activeProfile.name, "Default")
        XCTAssertEqual(model.activeProfile.gamedir, "valve")
        XCTAssertNil(model.activeProfile.dataRoot)
        XCTAssertEqual(model.dataRoot.path, defaultRoot(env).standardizedFileURL.path)
        XCTAssertEqual(model.selectedGamedir, "valve")
        XCTAssertEqual(model.servers.count, 2, "the shared server list comes from the record")
        XCTAssertFalse(model.hasUnsavedChanges, "the migration is not a user edit")
        XCTAssertEqual(try Data(contentsOf: AppPaths(home: env.home).snapshotFile), before, "launch writes nothing")

        // The next record write carries the new structure; the old fields stay for older readers.
        model.save()
        let json = try recordJSON(env)
        let profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0]["name"] as? String, "Default")
        XCTAssertEqual(profiles[0]["gamedir"] as? String, "valve")
        XCTAssertEqual(json["activeProfileID"] as? String, model.activeProfile.id.uuidString)
        XCTAssertEqual(json["gamedir"] as? String, "valve")
        XCTAssertNotNil(json["dataRoot"] as? String)

        // Reloading keeps the same profile (no second migration).
        let reloaded = env.makeModel()
        XCTAssertEqual(reloaded.profiles, model.profiles)
        XCTAssertEqual(reloaded.activeProfile.id, model.activeProfile.id)
    }

    // MARK: Add / rename / delete / default

    func testAddRenameMakeDefaultAndDeleteArePersisted() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.save()
        let other = try makeOtherRoot(env)
        let original = model.activeProfile.id

        XCTAssertNil(model.addProfile(name: "  Turnuva  ", dataRoot: other, gamedir: "cstrike"))
        XCTAssertEqual(model.profiles.map(\.name), ["Default", "Turnuva"])
        let added = model.profiles[1]
        XCTAssertEqual(added.dataRoot, other.standardizedFileURL.path)
        XCTAssertEqual(added.gamedir, "cstrike")
        XCTAssertEqual(model.activeProfile.id, original, "adding does not switch")
        XCTAssertEqual(model.addProfile(name: "   ", dataRoot: nil, gamedir: "x"), .nameEmpty)

        XCTAssertNil(model.renameProfile(added.id, to: "LAN"))
        XCTAssertEqual(model.renameProfile(added.id, to: ""), .nameEmpty)
        XCTAssertEqual(model.renameProfile(UUID(), to: "x"), .notFound)
        XCTAssertNil(model.makeDefaultProfile(added.id))
        XCTAssertEqual(model.defaultProfileID, added.id)
        XCTAssertEqual(model.profiles.map(\.name), ["LAN", "Default"])

        var reloaded = env.makeModel()
        XCTAssertEqual(reloaded.profiles.map(\.name), ["LAN", "Default"])
        XCTAssertEqual(reloaded.defaultProfileID, added.id)
        XCTAssertEqual(reloaded.activeProfile.id, original)

        XCTAssertNil(model.deleteProfile(added.id))
        XCTAssertEqual(model.profiles.map(\.id), [original])
        reloaded = env.makeModel()
        XCTAssertEqual(reloaded.profiles.map(\.id), [original])
        XCTAssertFalse(model.hasUnsavedChanges, "profile list changes are written at once")
    }

    func testDeleteLimitAndActiveFallsBackToDefault() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.save()
        let only = model.activeProfile.id
        XCTAssertEqual(model.deleteProfile(only), .lastProfile)
        XCTAssertEqual(model.profileError, .lastProfile)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.deleteProfile(UUID()), .notFound)

        let other = try makeOtherRoot(env)
        XCTAssertNil(model.addProfile(name: "Other", dataRoot: other, gamedir: "cstrike"))
        let otherID = model.profiles[1].id
        XCTAssertNil(model.activateProfile(otherID))
        await model.waitForRefresh()
        XCTAssertEqual(model.dataRoot.path, other.standardizedFileURL.path)

        // Deleting the active profile returns to the default one (and its files).
        XCTAssertNil(model.deleteProfile(otherID))
        await model.waitForRefresh()
        XCTAssertEqual(model.activeProfile.id, only)
        XCTAssertEqual(model.dataRoot.path, defaultRoot(env).standardizedFileURL.path)
        XCTAssertEqual(model.selectedGamedir, "valve")
        XCTAssertEqual(env.makeModel().activeProfile.id, only)
    }

    func testDuplicateDataRootAndGamedirIsRejected() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        await model.refresh().value   // Default resolves to the valve folder
        XCTAssertEqual(model.activeProfile.gamedir, "valve")
        // Same pair spelled with an explicit default data root (and a trailing slash).
        XCTAssertEqual(model.addProfile(name: "Copy", dataRoot: URL(fileURLWithPath: defaultRoot(env).path + "/"),
                                        gamedir: "valve"), .duplicateCombination)
        XCTAssertEqual(model.addProfile(name: "Copy", dataRoot: nil, gamedir: " valve "), .duplicateCombination)
        XCTAssertEqual(model.profiles.count, 1)
        // Another gamedir on the same data root is a different profile.
        XCTAssertNil(model.addProfile(name: "CS", dataRoot: nil, gamedir: "cstrike"))
        XCTAssertEqual(model.addProfile(name: "CS again", dataRoot: nil, gamedir: "cstrike"), .duplicateCombination)
        XCTAssertEqual(model.profiles.count, 2)
    }

    // MARK: Active profile persistence and the switch

    func testActiveProfileSurvivesARelaunch() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.save()
        let other = try makeOtherRoot(env)
        XCTAssertNil(model.addProfile(name: "Other", dataRoot: other, gamedir: "cstrike"))
        let otherID = model.profiles[1].id
        XCTAssertNil(model.activateProfile(otherID))
        await model.waitForRefresh()

        let reloaded = env.makeModel()
        XCTAssertEqual(reloaded.activeProfile.id, otherID)
        XCTAssertEqual(reloaded.dataRoot.path, other.standardizedFileURL.path)
        XCTAssertEqual(reloaded.selectedGamedir, "cstrike")
        await reloaded.refresh().value
        XCTAssertEqual(reloaded.config.name, "Other")
    }

    func testSwitchRereadsIdentityAndRecomputesCIDsWithoutNetwork() async throws {
        let env = try TestAppEnvironment()
        // Identity per game folder (no home identity file), so each profile has its own raw ID.
        try FileManager.default.removeItem(at: env.home.appendingPathComponent(".config/.xash_id"))
        _ = try env.temp.write("home/Library/Application Support/Xash3D FWGS/valve/.xash_id", "10331C2DCE4C91DB")
        let other = try makeOtherRoot(env, identity: "2A4B6C8D0E1F2A3B")
        let ipScript = HTTPScript(defaultBody: #"{"ip":"203.0.113.7"}"#)
        let model = env.makeModel(publicIPs: ipScript)
        model.addServer(ServerDraft(label: "EU", host: "192.0.2.20"))
        await model.refresh().value
        model.save()
        let serverID = model.servers[0].id
        let firstRaw = try XCTUnwrap(try? model.identity?.get().rawID)
        let firstCID = try XCTUnwrap(model.rowStatus(serverID)?.currentCID)
        let networkCalls = await ipScript.calls

        XCTAssertNil(model.addProfile(name: "Other", dataRoot: other, gamedir: "cstrike"))
        XCTAssertNil(model.activateProfile(model.profiles[1].id))
        await model.waitForRefresh()

        let secondRaw = try XCTUnwrap(try? model.identity?.get().rawID)
        XCTAssertNotEqual(secondRaw, firstRaw)
        XCTAssertEqual(model.selectedGamedir, "cstrike")
        XCTAssertEqual(model.gamedirs, ["cstrike"])
        XCTAssertEqual(model.config.name, "Other")
        let secondCID = try XCTUnwrap(model.rowStatus(serverID)?.currentCID)
        XCTAssertNotEqual(secondCID, firstCID)
        XCTAssertEqual(secondCID, CIDCalculator.cid(rawID: secondRaw, address: try XCTUnwrap(model.address(for: model.servers[0]))))
        let callsAfter = await ipScript.calls
        XCTAssertEqual(callsAfter, networkCalls, "a profile switch sends no network request")
        XCTAssertEqual(model.servers.map(\.id), [serverID], "the server list is shared")

        // Back to the default profile: the first identity and CID again.
        XCTAssertNil(model.activateProfile(model.profiles[0].id))
        await model.waitForRefresh()
        XCTAssertEqual(try? model.identity?.get().rawID, firstRaw)
        XCTAssertEqual(model.rowStatus(serverID)?.currentCID, firstCID)
    }

    func testSwitchIsRefusedWhileTheGameRuns() async throws {
        let env = try TestAppEnvironment()
        let game = FakeGameDetector(running: false)
        let model = env.makeModel(game: game)
        model.save()
        let other = try makeOtherRoot(env)
        XCTAssertNil(model.addProfile(name: "Other", dataRoot: other, gamedir: "cstrike"))
        let defaultID = model.activeProfile.id
        let otherID = model.profiles[1].id

        game.isRunning = true
        XCTAssertEqual(model.activateProfile(otherID), .gameRunning)
        XCTAssertEqual(model.profileError, .gameRunning)
        XCTAssertTrue(model.isGameRunning, "the read-only warning shows")
        XCTAssertEqual(model.activeProfile.id, defaultID)
        XCTAssertEqual(model.dataRoot.path, defaultRoot(env).standardizedFileURL.path)
        // Deleting the active profile would switch too; a passive profile can still be removed or renamed.
        XCTAssertEqual(model.deleteProfile(defaultID), .gameRunning)
        XCTAssertNil(model.renameProfile(otherID, to: "Renamed"))
        XCTAssertEqual(env.makeModel().activeProfile.id, defaultID)

        game.isRunning = false
        XCTAssertNil(model.activateProfile(otherID))
        XCTAssertNil(model.profileError)
        XCTAssertEqual(model.activeProfile.id, otherID)
    }

    func testDataRootAndGamedirChangesFollowTheActiveProfile() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.save()
        let other = try makeOtherRoot(env)
        await model.setDataRoot(other).value
        XCTAssertEqual(model.activeProfile.dataRoot, other.standardizedFileURL.path)
        XCTAssertEqual(model.activeProfile.gamedir, "cstrike")
        XCTAssertEqual(env.makeModel().activeProfile.dataRoot, other.standardizedFileURL.path)
    }

    // MARK: History and metrics stamps

    func testHistoryAndMetricsAreTaggedAndOlderLinesStayReadable() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "EU", host: "192.0.2.20"))
        await model.refresh().value
        await model.waitForHistory()
        let profile = model.activeProfile

        let entries = env.historyStore.load()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { $0.profileID == profile.id && $0.profileName == profile.name })
        let samples = await model.loadMetrics()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.profileID == profile.id && $0.profileName == "Default" })

        // The name is a snapshot: a renamed profile stamps its new name on the next rows only.
        XCTAssertNil(model.renameProfile(profile.id, to: "Ana"))
        env.clock.advance(60)
        await model.refresh().value
        await model.waitForHistory()
        let newer = await model.loadMetrics()
        XCTAssertEqual(newer.last?.profileName, "Ana")
        XCTAssertEqual(newer.first?.profileName, "Default")

        // Lines written before §61 carry no stamp and are still read.
        let legacyHistory = #"{"kind":"ipChanged","new":"203.0.113.9","ts":"2026-11-09T20:01:18Z"}"#
        let legacyMetric = #"{"host":"192.0.2.20","online":true,"ping":40,"serverID":"1E390D91-9114-454E-A9B3-4AB1833ACD48","ts":"2026-11-09T20:01:18Z"}"#
        let history = HistoryCoding.decodeLines(Data((legacyHistory + "\n").utf8))
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history[0].profileID)
        XCTAssertNil(history[0].profileName)
        let metrics = MetricsStore.decodeLines(Data((legacyMetric + "\n").utf8))
        XCTAssertEqual(metrics.count, 1)
        XCTAssertNil(metrics[0].profileID)
        // An untagged entry encodes without the new keys (older readers see the same line).
        let line = String(decoding: try HistoryCoding.encodeLine(history[0]), as: UTF8.self)
        XCTAssertFalse(line.contains("profile"))
    }

    func testHistoryRecorderStampsOnlyWhenAProfileIsSet() async throws {
        let temp = try TempDirectory()
        let store = HistoryStore(fileURL: temp.url.appendingPathComponent("history.jsonl"))
        let start = Self.t0
        let recorder = HistoryRecorder(store: store, now: { start })
        await recorder.record(HistoryEntry(ts: Self.t0, kind: .apply, note: "a"))
        let tag = ProfileTag(id: UUID(), name: "LAN")
        await recorder.setProfile(tag)
        await recorder.record(HistoryEntry(ts: Self.t0, kind: .apply, note: "b"))
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.profileID), [nil, tag.id])
        XCTAssertEqual(loaded.map(\.profileName), [nil, "LAN"])
    }
}

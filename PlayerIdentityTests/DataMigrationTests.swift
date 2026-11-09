import XCTest
@testable import PlayerIdentity

/// §19.4: one-time migration from the legacy bundle on a fixture home (never the user's real data).
@MainActor
final class DataMigrationTests: XCTestCase {
    private var temp: TempDirectory!
    private var defaults: UserDefaults!
    private var legacyDefaults: UserDefaults!
    private var suiteName = ""
    private var legacySuiteName = ""

    override func setUp() async throws {
        temp = try TempDirectory()
        suiteName = "PlayerIdentityTests-\(UUID().uuidString)"
        legacySuiteName = "PlayerIdentityTests-legacy-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        legacyDefaults = UserDefaults(suiteName: legacySuiteName)
        _ = try temp.makeDirectory("home")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        legacyDefaults.removePersistentDomain(forName: legacySuiteName)
        temp = nil
    }

    private var paths: AppPaths { AppPaths(home: temp.url.appendingPathComponent("home", isDirectory: true)) }

    private func makeMigration(legacy: UserDefaults?? = nil) -> DataMigration {
        DataMigration(legacySnapshotFile: paths.legacySnapshotFile,
                      snapshotFile: paths.snapshotFile,
                      defaults: defaults,
                      legacyDefaults: legacy ?? legacyDefaults)
    }

    private let legacyServerID = UUID(uuidString: "1E390D91-9114-454E-A9B3-4AB1833ACD48")!

    private func legacySnapshot() -> Snapshot {
        Snapshot(savedAt: Date(timeIntervalSince1970: 1_793_000_000),
                 gamedir: "valve",
                 dataRoot: "/fixture/Xash3D FWGS",
                 displayName: "Legacy Player",
                 model: "barney",
                 rawID: "0000000000000000",
                 identitySource: "/fixture/.config/.xash_id",
                 network: NetworkInfo(publicIP: "203.0.113.7", lanIPs: ["en0 · 192.0.2.10"], checkedAt: nil),
                 servers: [ServerEntry(id: legacyServerID, label: "Legacy server", host: "51.68.190.91", port: 27015,
                                       cid: "d9de0eb4419608a8423241430581e91c")])
    }

    @discardableResult
    private func writeLegacySnapshot() throws -> Data {
        let data = try SnapshotStore.makeEncoder().encode(legacySnapshot())
        try write(data, to: paths.legacySnapshotFile)
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    // MARK: Paths

    func testPathsUseNewAndLegacyBundleFolders() {
        XCTAssertTrue(paths.snapshotFile.path.hasSuffix("Library/Application Support/tr.ercanatay.playeridentity/profile.json"))
        XCTAssertTrue(paths.legacySnapshotFile.path.hasSuffix("Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json"))
        XCTAssertEqual(DataMigration.completedKey, "migration.v2.completed")
        XCTAssertEqual(DataMigration.migratedKeys,
                       [AppModel.dataRootDefaultsKey, AppModel.banCheckDefaultsKey, AppModel.recentNamesDefaultsKey])
    }

    // MARK: Snapshot

    func testLegacySnapshotIsCopiedWithIdenticalContentAndLegacyFileUntouched() throws {
        let legacyData = try writeLegacySnapshot()
        let legacyDateBefore = try modificationDate(paths.legacySnapshotFile)

        XCTAssertEqual(makeMigration().run(), .completed(snapshot: .copied, copiedKeys: []))

        XCTAssertEqual(try Data(contentsOf: paths.snapshotFile), legacyData)
        XCTAssertEqual(try Data(contentsOf: paths.legacySnapshotFile), legacyData)
        XCTAssertEqual(try modificationDate(paths.legacySnapshotFile), legacyDateBefore)
        XCTAssertTrue(defaults.bool(forKey: DataMigration.completedKey))
        // No temporary file is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.snapshotFile.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["profile.json"])
    }

    func testExistingTargetIsNotOverwritten() throws {
        let legacyData = try writeLegacySnapshot()
        let existing = Data("{\"schemaVersion\":1,\"existing\":true}".utf8)
        try write(existing, to: paths.snapshotFile)

        XCTAssertEqual(makeMigration().run(), .completed(snapshot: .targetExists, copiedKeys: []))

        XCTAssertEqual(try Data(contentsOf: paths.snapshotFile), existing)
        XCTAssertEqual(try Data(contentsOf: paths.legacySnapshotFile), legacyData)
    }

    func testCorruptLegacySnapshotIsSkippedWithoutCrash() throws {
        let corrupt = Data("{ corrupt".utf8)
        try write(corrupt, to: paths.legacySnapshotFile)

        XCTAssertEqual(makeMigration().run(), .completed(snapshot: .legacyInvalid, copiedKeys: []))

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
        XCTAssertEqual(try Data(contentsOf: paths.legacySnapshotFile), corrupt)
    }

    func testUnsupportedLegacySchemaIsSkipped() throws {
        try write(Data("{\"schemaVersion\":99}".utf8), to: paths.legacySnapshotFile)
        XCTAssertEqual(makeMigration().migrateSnapshot(), .legacyInvalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
    }

    func testNoLegacyDataCompletesWithoutChanges() {
        XCTAssertEqual(makeMigration().run(), .completed(snapshot: .noLegacyFile, copiedKeys: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
        XCTAssertTrue(defaults.bool(forKey: DataMigration.completedKey))
    }

    func testCopyFailureLeavesFlagUnsetAndRetriesOnNextLaunch() throws {
        try writeLegacySnapshot()
        // A regular file where the target folder should be makes directory creation fail.
        try write(Data(), to: paths.snapshotFile.deletingLastPathComponent())

        guard case .failed(snapshot: .failed, copiedKeys: []) = makeMigration().run() else {
            return XCTFail("expected a failed migration")
        }
        XCTAssertFalse(defaults.bool(forKey: DataMigration.completedKey))

        try FileManager.default.removeItem(at: paths.snapshotFile.deletingLastPathComponent())
        XCTAssertEqual(makeMigration().run(), .completed(snapshot: .copied, copiedKeys: []))
        XCTAssertTrue(defaults.bool(forKey: DataMigration.completedKey))
    }

    // MARK: Defaults

    func testDefaultsAreCopiedAndNotMigratedAgainOnSecondRun() throws {
        legacyDefaults.set("/legacy/Xash3D FWGS", forKey: DefaultsKey.dataRoot)
        legacyDefaults.set(false, forKey: DefaultsKey.banCheckEnabled)
        legacyDefaults.set(["Old One", "Old Two"], forKey: DefaultsKey.recentNames)

        XCTAssertEqual(makeMigration().run(),
                       .completed(snapshot: .noLegacyFile, copiedKeys: DataMigration.migratedKeys))
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.dataRoot), "/legacy/Xash3D FWGS")
        XCTAssertEqual(defaults.object(forKey: DefaultsKey.banCheckEnabled) as? Bool, false)
        XCTAssertEqual(defaults.stringArray(forKey: DefaultsKey.recentNames), ["Old One", "Old Two"])

        // Second run: the flag prevents another migration even if the legacy data changes or the user cleared a value.
        legacyDefaults.set("/changed", forKey: DefaultsKey.dataRoot)
        defaults.removeObject(forKey: DefaultsKey.recentNames)
        try writeLegacySnapshot()
        XCTAssertEqual(makeMigration().run(), .alreadyCompleted)
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.dataRoot), "/legacy/Xash3D FWGS")
        XCTAssertNil(defaults.stringArray(forKey: DefaultsKey.recentNames))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFile.path))
    }

    func testExistingNewValuesAreKept() {
        legacyDefaults.set("/legacy", forKey: DefaultsKey.dataRoot)
        legacyDefaults.set(["Old"], forKey: DefaultsKey.recentNames)
        defaults.set("/new", forKey: DefaultsKey.dataRoot)

        XCTAssertEqual(makeMigration().run(), .completed(snapshot: .noLegacyFile, copiedKeys: [DefaultsKey.recentNames]))
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.dataRoot), "/new")
        XCTAssertEqual(defaults.stringArray(forKey: DefaultsKey.recentNames), ["Old"])
    }

    func testMissingLegacyDomainStillCompletes() throws {
        try writeLegacySnapshot()
        XCTAssertEqual(makeMigration(legacy: .some(nil)).run(), .completed(snapshot: .copied, copiedKeys: []))
    }

    // MARK: App after migration

    func testAppModelShowsLegacyDataAfterMigration() throws {
        try writeLegacySnapshot()
        legacyDefaults.set(["Legacy Player"], forKey: DefaultsKey.recentNames)
        makeMigration().run()

        let model = AppModel(dependencies: AppDependencies(
            paths: paths,
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: []),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: nil))),
            snapshotStore: SnapshotStore(fileURL: paths.snapshotFile),
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_793_000_000) },
            udpTransport: FakeServer.healthy(),
            gameProcessDetector: FakeGameDetector(),
            commandRunner: FakeCommandRunner(),
            sleeper: FakeSleeper(clock: TestClock()),
            resolver: FakeAddressResolver()))

        let snapshot = try XCTUnwrap(model.snapshotState.snapshot)
        XCTAssertEqual(snapshot.displayName, "Legacy Player")
        XCTAssertEqual(snapshot.model, "barney")
        XCTAssertEqual(snapshot.network.publicIP, "203.0.113.7")
        XCTAssertEqual(model.servers.map(\.id), [legacyServerID])
        XCTAssertEqual(model.servers.first?.label, "Legacy server")
        XCTAssertEqual(model.selectedGamedir, "valve")
        XCTAssertEqual(model.dataRoot.path, "/fixture/Xash3D FWGS")
        XCTAssertEqual(model.recentNames, ["Legacy Player"])
        XCTAssertFalse(model.hasUnsavedChanges)
    }
}

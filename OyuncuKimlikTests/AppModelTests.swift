import XCTest
@testable import OyuncuKimlik

/// Ağa çıkmayan, çağrı sayan ve istenen çağrıyı bekletebilen sahte HTTP betiği.
actor HTTPScript {
    private(set) var calls = 0
    private var bodies: [Int: String]
    private let defaultBody: String?
    private let gatedCall: Int?
    private var gate: CheckedContinuation<Void, Never>?
    private var gatedStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// `bodies[n]` = n. çağrının gövdesi; yoksa `defaultBody`; `nil` → bağlantı hatası.
    init(bodies: [Int: String] = [:], defaultBody: String?, gatedCall: Int? = nil) {
        self.bodies = bodies
        self.defaultBody = defaultBody
        self.gatedCall = gatedCall
    }

    func respond() async throws -> (data: Data, statusCode: Int) {
        calls += 1
        let call = calls
        if call == gatedCall {
            gatedStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { gate = $0 }
        }
        guard let body = bodies[call] ?? defaultBody else { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), 200)
    }

    func waitUntilGatedCallStarted() async {
        if gatedStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseGate() {
        gate?.resume()
        gate = nil
    }
}

struct ScriptedHTTPClient: HTTPClient {
    let script: HTTPScript
    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        try await script.respond()
    }
}

struct FixedLocalIPProvider: LocalIPProviding {
    let addresses: [LocalAddress]
    func localAddresses() -> [LocalAddress] { addresses }
}

@MainActor
final class AppModelTests: XCTestCase {
    private var temp: TempDirectory!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let lan = [LocalAddress(interface: "en0", family: .ipv4, address: "192.0.2.10")]

    override func setUp() async throws {
        temp = try TempDirectory()
        suiteName = "OyuncuKimlikTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        _ = try temp.makeDirectory("home")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        temp = nil
    }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
    private var dataRoot: URL { home.appendingPathComponent("Library/Application Support/Xash3D FWGS", isDirectory: true) }
    private var snapshotURL: URL { home.appendingPathComponent("Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json") }
    private let rootPath = "home/Library/Application Support/Xash3D FWGS"

    private func json(_ ip: String) -> String { #"{"ip":"\#(ip)"}"# }

    private func makeModel(script: HTTPScript, lan: [LocalAddress]? = nil) -> AppModel {
        AppModel(dependencies: AppDependencies(
            paths: AppPaths(home: home),
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: lan ?? self.lan),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: script)),
            snapshotStore: SnapshotStore(fileURL: snapshotURL),
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_793_000_000) }))
    }

    private func writeGame(name: String = "Oyuncu", model: String = "gordon", idFile: String? = "10331C2DCE4C91DB") throws {
        try temp.write("\(rootPath)/valve/config.cfg", "name \"\(name)\"\nmodel \"\(model)\"\n")
        try temp.write("\(rootPath)/gearbox/config.cfg", "name \"Kutu\"\nmodel \"helmet\"\n")
        if let idFile { try temp.write("home/.config/.xash_id", idFile) }
    }

    private func codes(_ model: AppModel) -> Set<MessageCode> {
        Set(model.report?.reasons.map(\.code) ?? [])
    }

    // MARK: Yenileme

    func testRefreshRawIDZeroWithoutSnapshotIsOrangeAndDoesNotWrite() async throws {
        try writeGame()
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        XCTAssertNil(model.report)
        await model.refresh().value

        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.selectedGamedir, "valve")
        XCTAssertEqual(model.gamedirs, ["gearbox", "valve"])
        XCTAssertEqual(model.config, PlayerConfig(name: "Oyuncu", model: "gordon"))
        XCTAssertEqual(model.publicIP, "203.0.113.7")
        XCTAssertEqual(model.lanAddresses.map(\.display), ["en0 · 192.0.2.10"])
        XCTAssertNotNil(model.lastChecked)
        XCTAssertEqual(model.report?.overall, .orange)
        XCTAssertEqual(codes(model), [.rawIDZero, .snapshotMissing])
        // Yenile snapshot'ı yazmaz.
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testSaveThenReloadIsGreen() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        let script = HTTPScript(defaultBody: json("203.0.113.7"))
        let model = makeModel(script: script)
        model.addServer(ServerDraft(label: "Test", host: "95.173.174.175"))
        XCTAssertTrue(model.hasUnsavedChanges)
        await model.refresh().value
        model.save()

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.report?.overall, .green)
        XCTAssertEqual(model.report?.reasons, [])

        // Kapatıp açma: değerler yüklenir, kayıtla eşleşiyorsa yeşil.
        let reopened = makeModel(script: script)
        XCTAssertEqual(reopened.servers.map(\.host), ["95.173.174.175"])
        XCTAssertEqual(reopened.selectedGamedir, "valve")
        XCTAssertFalse(reopened.hasUnsavedChanges)
        await reopened.refresh().value
        XCTAssertEqual(reopened.report?.overall, .green)
        XCTAssertEqual(reopened.rowStatus(reopened.servers[0].id)?.level, .green)
    }

    func testPublicIPChangeInSnapshotIsOrange() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await model.refresh().value
        model.save()

        // Kayıttaki IP elle değiştirilir (§11.7).
        var snapshot = try XCTUnwrap(SnapshotStore(fileURL: snapshotURL).load().snapshot)
        snapshot.network.publicIP = "198.51.100.99"
        try SnapshotStore(fileURL: snapshotURL).save(snapshot)

        let reopened = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await reopened.refresh().value
        XCTAssertEqual(reopened.report?.overall, .orange)
        XCTAssertEqual(codes(reopened), [.publicIPChanged])
    }

    func testIdentityMissingIsRedAndOtherStepsContinue() async throws {
        try writeGame(idFile: nil)
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await model.refresh().value
        XCTAssertEqual(model.report?.overall, .red)
        XCTAssertTrue(codes(model).contains(.identityMissing))
        // Kısmi sonuç: config ve ağ yine okunmuş.
        XCTAssertEqual(model.config.name, "Oyuncu")
        XCTAssertEqual(model.publicIP, "203.0.113.7")
    }

    func testPublicIPFailureIsRedWithoutCrash() async throws {
        try writeGame()
        let script = HTTPScript(defaultBody: nil)   // çevrimdışı
        let model = makeModel(script: script)
        await model.refresh().value
        let calls = await script.calls
        XCTAssertEqual(calls, 2)   // birincil + yedek
        XCTAssertNil(model.publicIP)
        XCTAssertEqual(model.report?.overall, .red)
        XCTAssertTrue(codes(model).contains(.publicIPFailed))
        XCTAssertTrue(codes(model).contains(.rawIDZero))
        XCTAssertFalse(model.isRefreshing)
    }

    func testNewerRefreshWinsAndLateResultIgnored() async throws {
        try writeGame()
        let script = HTTPScript(bodies: [1: json("1.1.1.1"), 2: json("2.2.2.2")], defaultBody: nil, gatedCall: 1)
        let model = makeModel(script: script)

        let first = model.refresh()
        await script.waitUntilGatedCallStarted()
        XCTAssertTrue(model.isRefreshing)

        let second = model.refresh()
        await second.value
        XCTAssertEqual(model.publicIP, "2.2.2.2")
        XCTAssertFalse(model.isRefreshing)

        await script.releaseGate()
        await first.value
        XCTAssertEqual(model.publicIP, "2.2.2.2")
        XCTAssertFalse(model.isRefreshing)
    }

    // MARK: Anlık yeniden değerlendirme

    func testServerEditsReevaluateWithoutNetwork() async throws {
        try writeGame()
        let script = HTTPScript(defaultBody: json("203.0.113.7"))
        let model = makeModel(script: script)
        await model.refresh().value
        let callsAfterRefresh = await script.calls

        model.addServer(ServerDraft(label: "Bozuk", host: "alan.adi"))
        let bad = try XCTUnwrap(model.servers.last)
        XCTAssertEqual(model.rowStatus(bad.id)?.level, .red)
        XCTAssertEqual(model.rowStatus(bad.id)?.message, .invalidHost)

        model.updateServer(id: bad.id, with: ServerDraft(label: "İyi", host: "127.0.0.1", portText: "27016"))
        XCTAssertEqual(model.servers.last?.port, 27016)
        XCTAssertEqual(model.rowStatus(bad.id)?.level, .orange)
        XCTAssertEqual(model.rowStatus(bad.id)?.currentCID, "e3f650e2c5f1293838ba8e934ba3b796")

        model.deleteServer(id: bad.id)
        XCTAssertNil(model.rowStatus(bad.id))
        XCTAssertTrue(model.servers.isEmpty)

        let calls = await script.calls
        XCTAssertEqual(calls, callsAfterRefresh)
    }

    func testInvalidFormIsRejected() {
        let model = makeModel(script: HTTPScript(defaultBody: nil))
        model.addServer(ServerDraft(label: "", host: "1.2.3.4"))
        model.addServer(ServerDraft(label: "a", host: "1.2.3.4", portText: "70000"))
        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testGamedirChangeRereadsLocalFilesWithoutNetwork() async throws {
        try writeGame()
        let script = HTTPScript(defaultBody: json("203.0.113.7"))
        let model = makeModel(script: script)
        await model.refresh().value
        let callsAfterRefresh = await script.calls

        await model.selectGamedir("gearbox")?.value
        XCTAssertEqual(model.selectedGamedir, "gearbox")
        XCTAssertEqual(model.config, PlayerConfig(name: "Kutu", model: "helmet"))
        XCTAssertTrue(model.hasUnsavedChanges)
        let calls = await script.calls
        XCTAssertEqual(calls, callsAfterRefresh)
    }

    // MARK: Veri kökü

    func testDataRootSelectionPersistsAndRediscovers() async throws {
        try writeGame()
        try temp.write("fixture/bshift/config.cfg", "name \"Fixture\"\nmodel \"x\"\n")
        let fixtureRoot = temp.url.appendingPathComponent("fixture", isDirectory: true)
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await model.refresh().value
        XCTAssertEqual(model.selectedGamedir, "valve")

        await model.setDataRoot(fixtureRoot).value
        XCTAssertEqual(model.gamedirs, ["bshift"])
        XCTAssertEqual(model.selectedGamedir, "bshift")
        XCTAssertEqual(model.config.name, "Fixture")
        XCTAssertEqual(defaults.string(forKey: AppModel.dataRootDefaultsKey), fixtureRoot.standardizedFileURL.path)

        let reopened = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        XCTAssertEqual(reopened.dataRoot.standardizedFileURL.path, fixtureRoot.standardizedFileURL.path)
    }

    func testFixtureDataRootWithoutIdentityIsRed() async throws {
        // §11.8: veri kökü fixture'a çevrilir, kimlik dosyası görünmez → kırmızı + identityMissing.
        try temp.write("fixture/valve/config.cfg", "name \"F\"\nmodel \"m\"\n")
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await model.setDataRoot(temp.url.appendingPathComponent("fixture")).value
        XCTAssertEqual(model.report?.overall, .red)
        XCTAssertTrue(codes(model).contains(.identityMissing))
    }

    func testCorruptSnapshotIsRedAndSaveRecovers() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        try temp.write("home/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json", "{ bozuk")
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        XCTAssertEqual(model.snapshotState, .corrupt)
        await model.refresh().value
        XCTAssertEqual(model.report?.overall, .red)
        XCTAssertTrue(codes(model).contains(.snapshotCorrupt))

        model.save()
        XCTAssertEqual(model.report?.overall, .green)
        XCTAssertNotNil(SnapshotStore(fileURL: snapshotURL).load().snapshot)
    }
}

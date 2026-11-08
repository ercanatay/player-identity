import XCTest
@testable import PlayerIdentity

/// Fake HTTP script that never hits the network, counts calls and can hold a chosen call.
actor HTTPScript {
    private(set) var calls = 0
    private var bodies: [Int: String]
    private let defaultBody: String?
    private let gatedCall: Int?
    private var gate: CheckedContinuation<Void, Never>?
    private var gatedStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// `bodies[n]` = body of the n-th call; otherwise `defaultBody`; `nil` → connection error.
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
        suiteName = "PlayerIdentityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        _ = try temp.makeDirectory("home")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        temp = nil
    }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
    private var dataRoot: URL { home.appendingPathComponent("Library/Application Support/Xash3D FWGS", isDirectory: true) }
    private var snapshotURL: URL { home.appendingPathComponent("Library/Application Support/tr.ercanatay.playeridentity/profile.json") }
    private let rootPath = "home/Library/Application Support/Xash3D FWGS"

    private func json(_ ip: String) -> String { #"{"ip":"\#(ip)"}"# }

    private func makeModel(script: HTTPScript, lan: [LocalAddress]? = nil,
                           udp: FakeUDPTransport = FakeServer.healthy(), clock: TestClock? = nil,
                           game: FakeGameDetector = FakeGameDetector(),
                           runner: FakeCommandRunner = FakeCommandRunner()) -> AppModel {
        let now: @Sendable () -> Date
        if let clock {
            now = { clock.now }
        } else {
            now = { Date(timeIntervalSince1970: 1_793_000_000) }
        }
        return AppModel(dependencies: AppDependencies(
            paths: AppPaths(home: home),
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: lan ?? self.lan),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: script)),
            snapshotStore: SnapshotStore(fileURL: snapshotURL),
            defaults: defaults,
            now: now,
            udpTransport: udp,
            gameProcessDetector: game,
            commandRunner: runner,
            sleeper: FakeSleeper(clock: clock ?? TestClock())))
    }

    private func writeGame(name: String = "Oyuncu", model: String = "gordon", idFile: String? = "10331C2DCE4C91DB") throws {
        try temp.write("\(rootPath)/valve/config.cfg", "name \"\(name)\"\nmodel \"\(model)\"\n")
        try temp.write("\(rootPath)/gearbox/config.cfg", "name \"Kutu\"\nmodel \"helmet\"\n")
        if let idFile { try temp.write("home/.config/.xash_id", idFile) }
    }

    private func codes(_ model: AppModel) -> Set<MessageCode> {
        Set(model.report?.reasons.map(\.code) ?? [])
    }

    // MARK: Refresh

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
        // Refresh does not write the snapshot.
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

        // Close and reopen: values are loaded; green if they match the record.
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

        // The IP in the record is edited by hand (§11.7).
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
        // Partial result: config and network were still read.
        XCTAssertEqual(model.config.name, "Oyuncu")
        XCTAssertEqual(model.publicIP, "203.0.113.7")
    }

    func testPublicIPFailureIsRedWithoutCrash() async throws {
        try writeGame()
        let script = HTTPScript(defaultBody: nil)   // offline
        let model = makeModel(script: script)
        await model.refresh().value
        let calls = await script.calls
        XCTAssertEqual(calls, 2)   // primary + fallback
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

    // MARK: Instant re-evaluation

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

    // MARK: Data root

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
        // §11.8: data root switched to a fixture, identity file hidden → red + identityMissing.
        try temp.write("fixture/valve/config.cfg", "name \"F\"\nmodel \"m\"\n")
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await model.setDataRoot(temp.url.appendingPathComponent("fixture")).value
        XCTAssertEqual(model.report?.overall, .red)
        XCTAssertTrue(codes(model).contains(.identityMissing))
    }

    func testCorruptSnapshotIsRedAndSaveRecovers() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        try temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", "{ bozuk")
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        XCTAssertEqual(model.snapshotState, .corrupt)
        await model.refresh().value
        XCTAssertEqual(model.report?.overall, .red)
        XCTAssertTrue(codes(model).contains(.snapshotCorrupt))

        model.save()
        XCTAssertEqual(model.report?.overall, .green)
        XCTAssertNotNil(SnapshotStore(fileURL: snapshotURL).load().snapshot)
    }

    // MARK: Ban check (§13)

    func testBanCheckEnabledByDefaultAndPersists() {
        let model = makeModel(script: HTTPScript(defaultBody: nil))
        XCTAssertTrue(model.banCheckEnabled)
        model.banCheckEnabled = false
        XCTAssertEqual(defaults.object(forKey: AppModel.banCheckDefaultsKey) as? Bool, false)
        XCTAssertFalse(makeModel(script: HTTPScript(defaultBody: nil)).banCheckEnabled)
    }

    func testBanCheckDisabledSendsNoUDPPackets() async throws {
        try writeGame()
        defaults.set(false, forKey: AppModel.banCheckDefaultsKey)
        let udp = FakeServer.healthy()
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), udp: udp)
        model.addServer(ServerDraft(label: "A", host: "51.68.190.91"))
        model.addServer(ServerDraft(label: "B", host: "5.161.189.195"))
        await model.refresh().value
        XCTAssertEqual(udp.sentCount, 0)
        XCTAssertEqual(udp.sessionCount, 0)
        XCTAssertTrue(model.servers.allSatisfy { $0.banCheck == nil })
    }

    func testBanResultTurnsOverallRedAndIsSaved() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        let udp = FakeUDPTransport(responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oobText("lYou are banned from this server\n"))))
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), udp: udp)
        model.addServer(ServerDraft(label: "Ban", host: "51.68.190.91"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertEqual(model.servers.first?.banCheck?.status, .ipBanned)
        XCTAssertEqual(model.rowStatus(id)?.ban?.status, .ipBanned)
        XCTAssertEqual(model.report?.overall, .red)
        XCTAssertEqual(model.report?.reasons.first { $0.code == .ipBanned }?.message, "Sunucu bu IP'yi banlamış.")

        model.save()
        let text = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"banCheck\""))
        XCTAssertTrue(text.contains("\"ipBanned\""))
        let reopened = makeModel(script: HTTPScript(defaultBody: nil))
        XCTAssertEqual(reopened.servers.first?.banCheck?.status, .ipBanned)
    }

    func testHealthyServerIsGreenWithNoBlock() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        let udp = FakeServer.healthy()
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), udp: udp)
        model.addServer(ServerDraft(label: "Ok", host: "5.161.189.195"))
        await model.refresh().value
        model.save()
        XCTAssertEqual(model.servers.first?.banCheck?.status, .cidOk)
        XCTAssertEqual(model.servers.first?.banCheck?.status.label, "Engel yok")
        XCTAssertEqual(model.report?.overall, .green)
        // The uuid in the connect packet is the row's CID, name is the profile name.
        let connect = String(decoding: try XCTUnwrap(udp.sentPackets.last).dropFirst(4), as: UTF8.self)
        let rawID = try XCTUnwrap(try model.identity?.get().rawID)
        XCTAssertTrue(connect.contains("uuid=\(CIDCalculator.cid(rawID: rawID, host: "5.161.189.195")!);"))
        XCTAssertTrue(connect.hasSuffix("\"name=Oyuncu\"\n"))
    }

    func testUnreachableServerIsOrange() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        let udp = FakeUDPTransport { _, _ in [] }
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), udp: udp)
        model.addServer(ServerDraft(label: "Kapalı", host: "5.161.189.195"))
        await model.refresh().value
        model.save()
        XCTAssertEqual(model.servers.first?.banCheck?.status, .unreachable)
        XCTAssertEqual(model.report?.overall, .orange)
        XCTAssertEqual(model.report?.reasons.map(\.code), [.unreachable])
    }

    func testSameServerNotCheckedAgainWithinTenSeconds() async throws {
        try writeGame()
        let clock = TestClock()
        let udp = FakeServer.healthy(clock: clock)
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), udp: udp, clock: clock)
        model.addServer(ServerDraft(label: "A", host: "5.161.189.195"))
        await model.refresh().value
        let afterFirst = udp.sentCount
        XCTAssertEqual(afterFirst, 3)
        let firstCheck = model.servers.first?.banCheck

        clock.advance(5)
        await model.refresh().value
        XCTAssertEqual(udp.sentCount, afterFirst)               // 10 s not elapsed → no packet
        XCTAssertEqual(model.servers.first?.banCheck, firstCheck) // previous result kept

        clock.advance(6)
        await model.refresh().value
        XCTAssertEqual(udp.sentCount, afterFirst * 2)
    }

    func testEditingHostClearsBanResult() async throws {
        try writeGame()
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        model.addServer(ServerDraft(label: "A", host: "5.161.189.195"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertNotNil(model.servers.first?.banCheck)
        model.updateServer(id: id, with: ServerDraft(label: "A2", host: "5.161.189.195"))
        XCTAssertNotNil(model.servers.first?.banCheck)          // only the label changed
        model.updateServer(id: id, with: ServerDraft(label: "A2", host: "51.68.190.91"))
        XCTAssertNil(model.servers.first?.banCheck)
    }

    // MARK: Name/model editing (§15)

    private var valveDir: URL { dataRoot.appendingPathComponent("valve", isDirectory: true) }

    func testDropdownsSourcesAndApplyFlow() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        try temp.write("\(rootPath)/valve/userconfig.cfg", "name \"Oyuncu\"\n")
        try temp.write("\(rootPath)/valve/config.cfg.bak", "oyun yedeği\n")
        for name in ["gordon", "barney", "gina"] { _ = try temp.makeDirectory("\(rootPath)/valve/models/player/\(name)") }
        let game = FakeGameDetector()
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), game: game)
        await model.refresh().value
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)

        XCTAssertEqual(model.configSources, ConfigSources(name: .userconfig, model: .config))
        XCTAssertEqual(model.modelOptions.map(\.value), ["barney", "gina", "gordon"])
        XCTAssertFalse(model.allowsManualModelEntry)
        XCTAssertEqual(model.nameOptions, ["Oyuncu"])
        XCTAssertEqual(model.nameDraft, "Oyuncu")
        XCTAssertFalse(model.canApply)                      // no changes

        model.nameDraft = "Yeni \"Ad"
        XCTAssertEqual(model.nameError, .nameInvalid)
        XCTAssertFalse(model.canApply)
        model.nameDraft = "  Yeni Ad "
        model.modelDraft = "gina"
        XCTAssertNil(model.nameError)
        XCTAssertTrue(model.canApply)

        await model.apply()?.value
        guard case .success(let text)? = model.applyStatus else { return XCTFail("\(String(describing: model.applyStatus))") }
        XCTAssertTrue(text.hasPrefix("Uygulandı · "))
        XCTAssertTrue(text.hasSuffix(" · config.cfg + userconfig.cfg"))
        XCTAssertEqual(model.config, PlayerConfig(name: "Yeni Ad", model: "gina"))
        XCTAssertEqual(model.configSources.name, .userconfig)
        XCTAssertEqual(model.nameDraft, "Yeni Ad")
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.hasUnsavedChanges)              // Apply → "unsaved"
        XCTAssertEqual(model.recentNames.first, "Yeni Ad")
        XCTAssertEqual(defaults.stringArray(forKey: AppModel.recentNamesDefaultsKey), ["Yeni Ad"])
        XCTAssertTrue(model.nameOptions.contains("Oyuncu"))  // the saved name stays in the options

        let config = try String(contentsOf: valveDir.appendingPathComponent("config.cfg"), encoding: .utf8)
        let user = try String(contentsOf: valveDir.appendingPathComponent("userconfig.cfg"), encoding: .utf8)
        XCTAssertEqual(config, "name \"Yeni Ad\"\nmodel \"gina\"\n")
        XCTAssertEqual(user, "name \"Yeni Ad\"\n")
        XCTAssertEqual(try String(contentsOf: valveDir.appendingPathComponent("config.cfg.bak"), encoding: .utf8), "oyun yedeği\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: valveDir.appendingPathComponent("config.cfg.appbak").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: valveDir.appendingPathComponent("userconfig.cfg.appbak").path))

        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        let saved = try XCTUnwrap(SnapshotStore(fileURL: snapshotURL).load().snapshot)
        XCTAssertEqual(saved.displayName, "Yeni Ad")
        XCTAssertEqual(saved.model, "gina")
    }

    func testApplyRefusedWhileGameRunning() async throws {
        try writeGame()
        let game = FakeGameDetector(running: true)
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), game: game)
        await model.refresh().value
        XCTAssertTrue(model.isGameRunning)                  // warning banner
        let before = try Data(contentsOf: valveDir.appendingPathComponent("config.cfg"))
        model.modelDraft = "barney"
        await model.apply()?.value
        XCTAssertEqual(model.applyStatus, .failure(.gameRunning))
        XCTAssertEqual(try Data(contentsOf: valveDir.appendingPathComponent("config.cfg")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valveDir.appendingPathComponent("config.cfg.appbak").path))
        XCTAssertEqual(model.config.model, "gordon")

        game.isRunning = false
        await model.apply()?.value
        XCTAssertEqual(model.config.model, "barney")
        XCTAssertFalse(model.isGameRunning)
    }

    func testManualModelEntryWhenFolderMissingAndGamedirSwitchReloads() async throws {
        try writeGame()
        _ = try temp.makeDirectory("\(rootPath)/gearbox/models/player/beret")
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await model.refresh().value
        XCTAssertNil(model.availableModels)
        XCTAssertTrue(model.allowsManualModelEntry)
        XCTAssertEqual(model.modelOptions.map(\.label), ["gordon (mevcut)"])

        await model.selectGamedir("gearbox")?.value
        XCTAssertEqual(model.availableModels, ["beret"])
        XCTAssertEqual(model.modelOptions.map(\.label), ["helmet (mevcut)", "beret"])
        XCTAssertEqual(model.modelDraft, "helmet")
        XCTAssertEqual(model.nameDraft, "Kutu")
        model.modelDraft = "bad model"
        XCTAssertEqual(model.modelError, .modelInvalid)
        XCTAssertFalse(model.canApply)
    }

    func testApplyWritesToSelectedGamedirAndReportsMissingConfig() async throws {
        try writeGame()
        try temp.write("\(rootPath)/bshift/.xash_id", "0000000000000000")   // no config.cfg
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        await model.refresh().value
        await model.selectGamedir("bshift")?.value
        model.nameDraft = "Ad"
        await model.apply()?.value
        XCTAssertEqual(model.applyStatus, .failure(.configMissing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("bshift/config.cfg").path))
        XCTAssertEqual(try String(contentsOf: valveDir.appendingPathComponent("config.cfg"), encoding: .utf8),
                       "name \"Oyuncu\"\nmodel \"gordon\"\n")
    }

    // MARK: Fix (§17)

    private final class BanSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var banned: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func switchableIPBanServer(_ banSwitch: BanSwitch, clock: TestClock) -> FakeUDPTransport {
        let healthy = FakeServer.scripted()
        return FakeUDPTransport(clock: clock) { endpoint, packet in
            if banSwitch.banned, FakeServer.isGetChallenge(packet) {
                return [FakeReply(bytes: FakeServer.oobText("lYou have been banned from this server.\n"))]
            }
            return healthy(endpoint, packet)
        }
    }

    func testIPFixFlowUpdatesRowMarksUnsavedAndLocks() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        let clock = TestClock()
        let banSwitch = BanSwitch()
        let runner = FakeCommandRunner()
        let script = HTTPScript(bodies: [1: json("1.1.1.1"), 2: json("1.1.1.1")], defaultBody: json("2.2.2.2"))
        let model = makeModel(script: script, udp: switchableIPBanServer(banSwitch, clock: clock), clock: clock, runner: runner)
        model.addServer(ServerDraft(label: "POLIGON RPG", host: "51.68.190.91"))
        await model.refresh().value
        model.save()
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertEqual(model.servers.first?.banCheck?.status, .ipBanned)
        XCTAssertEqual(model.fixKind(for: id), .ipBan)
        XCTAssertFalse(model.hasUnsavedChanges)

        model.beginFix(id)                                   // only the sheet opens; no command
        XCTAssertEqual(model.fixSession?.phase, .ready)
        XCTAssertEqual(runner.commands, [])

        banSwitch.banned = false                             // as if the ban were lifted for the new IP
        await model.startIPFix()?.value
        guard case .finished(let outcome, _)? = model.fixSession?.phase else {
            return XCTFail("\(String(describing: model.fixSession))")
        }
        XCTAssertEqual(outcome, .resolved(old: "1.1.1.1", new: "2.2.2.2"))
        XCTAssertEqual(model.publicIP, "2.2.2.2")
        XCTAssertEqual(model.servers.first?.banCheck?.status, .cidOk)
        XCTAssertNil(model.fixKind(for: id))                 // ban lifted → Fix hidden
        XCTAssertTrue(model.hasUnsavedChanges)               // §17.2/7
        let en0 = NetworkInterfaceName("en0")!
        XCTAssertEqual(runner.commands, [.routeGetDefault, .airportPowerStatus(en0),
                                         .setAirportPower(en0, on: false), .setAirportPower(en0, on: true)])

        // Retrying before 60 s → the lock refuses, no command runs.
        model.fixSession?.phase = .ready
        await model.startIPFix()?.value
        XCTAssertEqual(model.fixSession?.note, AppModel.fixLockedText)
        XCTAssertEqual(runner.commands.count, 4)
    }

    func testCIDBanFixRunsNoNetworkCommands() async throws {
        try writeGame(idFile: "0123456789ABCDEF")
        let clock = TestClock()
        let runner = FakeCommandRunner()
        let udp = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            connect: FakeReply(bytes: FakeServer.oobText("errormsg\nYou are banned (CID)\n"))))
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")), udp: udp, clock: clock, runner: runner)
        model.addServer(ServerDraft(label: "CID Sunucu", host: "5.161.189.195"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertEqual(model.fixKind(for: id), .cidBan)

        model.beginFix(id)
        XCTAssertEqual(model.fixSession?.kind, .cidBan)
        XCTAssertNil(model.startIPFix())                     // no IP renewal in the CID flow
        let appeal = try XCTUnwrap(model.appealText(for: id))
        let rawID = try XCTUnwrap(try model.identity?.get().rawID)
        XCTAssertTrue(appeal.contains(CIDCalculator.cid(rawID: rawID, host: "5.161.189.195")!))
        XCTAssertTrue(appeal.contains("Kontrol türü: engine CID (connect 49)"))
        XCTAssertTrue(appeal.contains("203.0.113.7"))
        XCTAssertEqual(model.serverPageURL(for: id)?.absoluteString,
                       "https://www.gametracker.com/server_info/5.161.189.195:27015/")

        // Recheck: 10 s throttle, then ban check only (no network command).
        let packetsBefore = udp.sentCount
        model.recheckServer(id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.fixSession?.note, AppModel.recheckThrottledText)
        clock.advance(11)
        await model.recheckServer(id)?.value
        XCTAssertGreaterThan(udp.sentCount, packetsBefore)
        XCTAssertTrue(model.fixSession?.note?.hasPrefix("Yeniden kontrol: CID ban") ?? false)
        XCTAssertEqual(runner.commands, [])
    }

    func testFixNotOfferedForOtherStatuses() async throws {
        try writeGame()
        let model = makeModel(script: HTTPScript(defaultBody: json("203.0.113.7")))
        model.addServer(ServerDraft(label: "Ok", host: "5.161.189.195"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertEqual(model.servers.first?.banCheck?.status, .cidOk)
        XCTAssertNil(model.fixKind(for: id))
        model.beginFix(id)
        XCTAssertNil(model.fixSession)
    }
}

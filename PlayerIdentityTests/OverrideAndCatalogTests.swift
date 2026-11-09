import XCTest
@testable import PlayerIdentity

/// §43: `userconfig.cfg` override warning/removal and the multi-source model catalog.
@MainActor
final class OverrideAndCatalogTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private var gamedir: URL { temp.url.appendingPathComponent("root/valve", isDirectory: true) }
    private var root: URL { temp.url.appendingPathComponent("root", isDirectory: true) }

    private func remover(running: Bool = false) -> UserconfigOverrideRemover {
        let detector = FakeGameDetector(running: running)
        return UserconfigOverrideRemover(detector: detector, now: { Date(timeIntervalSince1970: 1_793_000_000) })
    }

    private let user = "// header\nname \"Eski Ad\"\nbind \"w\" \"+forward\"\n  model \"keyturk1\"\r\nname \"Ikinci\"\nsensitivity 3\n"

    // MARK: Removal (§43.1)

    func testRemovalBacksUpCommentsOnlyOverrideLinesAndKeepsOthers() throws {
        try temp.write("root/valve/userconfig.cfg", user)
        let outcome = try remover().remove(gamedir: gamedir, keys: ["name"])
        XCTAssertEqual(outcome.keys, ["name"])
        XCTAssertEqual(outcome.backupURL.lastPathComponent,
                       UserconfigOverrideRemover.backupName(at: Date(timeIntervalSince1970: 1_793_000_000)))
        XCTAssertTrue(outcome.backupURL.lastPathComponent.hasPrefix("userconfig.cfg.appbak-"))
        XCTAssertNotNil(outcome.backupURL.lastPathComponent.range(of: #"^userconfig\.cfg\.appbak-\d{8}-\d{6}$"#,
                                                                   options: .regularExpression))
        XCTAssertEqual(try String(contentsOf: outcome.backupURL, encoding: .utf8), user)   // byte-identical backup
        let after = try String(contentsOf: gamedir.appendingPathComponent("userconfig.cfg"), encoding: .utf8)
        XCTAssertEqual(after, "// header\n// name \"Eski Ad\"\nbind \"w\" \"+forward\"\n  model \"keyturk1\"\r\n// name \"Ikinci\"\nsensitivity 3\n")
    }

    func testRemovalOfBothKeysAndEffectiveValueFallsBackToConfig() throws {
        try temp.write("root/valve/config.cfg", "name \"Config\"\nmodel \"gordon\"\n")
        try temp.write("root/valve/userconfig.cfg", "name \"U\"\nmodel \"keyturk1\"\n")
        XCTAssertEqual(ConfigReader().readEffective(gamedir: gamedir).sources, ConfigSources(name: .userconfig, model: .userconfig))
        let outcome = try remover().remove(gamedir: gamedir, keys: ["name", "model"])
        XCTAssertEqual(outcome.keys, ["name", "model"])
        let effective = ConfigReader().readEffective(gamedir: gamedir)
        XCTAssertEqual(effective.config, PlayerConfig(name: "Config", model: "gordon"))
        XCTAssertEqual(effective.sources, ConfigSources(name: .config, model: .config))
        XCTAssertEqual(try String(contentsOf: gamedir.appendingPathComponent("config.cfg"), encoding: .utf8),
                       "name \"Config\"\nmodel \"gordon\"\n")                       // config.cfg untouched
    }

    func testRemovalRefusedWhileGameRunningAndWithoutLine() throws {
        try temp.write("root/valve/userconfig.cfg", user)
        XCTAssertThrowsError(try remover(running: true).remove(gamedir: gamedir, keys: ["name"])) {
            XCTAssertEqual($0 as? EditMessage, .gameRunning)
        }
        XCTAssertEqual(try String(contentsOf: gamedir.appendingPathComponent("userconfig.cfg"), encoding: .utf8), user)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: gamedir.path), ["userconfig.cfg"])   // no backup
        try temp.write("root/valve/userconfig.cfg", "// name \"x\"\nsensitivity 3\n")
        XCTAssertThrowsError(try remover().remove(gamedir: gamedir, keys: ["name"])) {
            XCTAssertEqual($0 as? EditMessage, .overrideMissing)
        }
        try temp.remove("root/valve/userconfig.cfg")
        XCTAssertThrowsError(try remover().remove(gamedir: gamedir, keys: ["name"])) {
            XCTAssertEqual($0 as? EditMessage, .overrideMissing)
        }
    }

    // MARK: AppModel (§43.1)

    func testWarningOnlyWhenOverridePresentAndRemovalFlow() async throws {
        let env = try TestAppEnvironment()
        let game = FakeGameDetector()
        let model = env.makeModel(game: game)
        await model.refresh().value
        XCTAssertFalse(model.hasConfigOverride)                       // userconfig.cfg absent → no warning
        XCTAssertNil(model.removeOverride())

        try Data("sensitivity 3\n".utf8).write(to: env.valveDir.appendingPathComponent("userconfig.cfg"))
        await model.refresh().value
        XCTAssertFalse(model.hasConfigOverride)                       // file without name/model → no warning

        try Data("sensitivity 3\nname \"Ezen\"\n".utf8).write(to: env.valveDir.appendingPathComponent("userconfig.cfg"))
        await model.refresh().value
        XCTAssertTrue(model.hasConfigOverride)
        XCTAssertEqual(model.overriddenKeys, ["name"])
        XCTAssertEqual(model.config.name, "Ezen")

        game.isRunning = true
        await model.removeOverride()?.value
        XCTAssertEqual(model.applyStatus, .failure(.gameRunning))
        XCTAssertTrue(model.hasConfigOverride)

        game.isRunning = false
        await model.removeOverride()?.value
        guard case .success(let text)? = model.applyStatus else { return XCTFail("\(String(describing: model.applyStatus))") }
        XCTAssertTrue(text.contains("userconfig.cfg.appbak-"))
        XCTAssertFalse(model.hasConfigOverride)
        XCTAssertEqual(model.config.name, "N")                        // now from config.cfg
        XCTAssertEqual(model.configSources.name, .config)
        XCTAssertEqual(try String(contentsOf: env.valveDir.appendingPathComponent("userconfig.cfg"), encoding: .utf8),
                       "sensitivity 3\n// name \"Ezen\"\n")
        await model.waitForHistory()
        let entry = try XCTUnwrap(env.historyStore.load().first { $0.kind == .configOverrideRemoved })
        XCTAssertEqual(entry.new, "name")
        XCTAssertTrue(entry.note?.hasPrefix("userconfig.cfg.appbak-") ?? false)
    }

    // MARK: Catalog (§43.2)

    private func folders(_ paths: [String]) throws {
        for path in paths { _ = try temp.makeDirectory("root/\(path)") }
    }

    func testCatalogUnionDedupeSortAndSources() throws {
        try folders(["valve/models/player/gordon", "valve/models/player/Barney", "valve/models/player/keyturk1",
                     "valve_downloads/models/player/keyturk1", "valve_downloads/models/player/keyturk2",
                     "gearbox_downloads/models/player/keyturk2", "gearbox_downloads/models/player/tbo",
                     "gearbox/models/player/helmet", "gearbox_downloads/models/player/.hidden"])
        try temp.write("root/valve_downloads/models/player/file.txt", "x")                  // plain files are ignored

        let valve = try XCTUnwrap(ModelCatalog.entries(dataRoot: root, gamedir: "valve"))
        XCTAssertEqual(valve.map(\.name), ["Barney", "gordon", "keyturk1", "keyturk2"])      // gearbox_downloads not read
        XCTAssertEqual(valve.first { $0.name == "keyturk1" }?.sources, [.local, .downloaded])
        XCTAssertEqual(valve.first { $0.name == "keyturk2" }?.sources, [.downloaded])

        let gearbox = try XCTUnwrap(ModelCatalog.entries(dataRoot: root, gamedir: "gearbox"))
        XCTAssertEqual(gearbox.map(\.name), ["helmet", "keyturk1", "keyturk2", "tbo"])       // three sources, deduplicated
        XCTAssertEqual(gearbox.first { $0.name == "keyturk2" }?.sources, [.downloaded])
        XCTAssertEqual(gearbox.first { $0.name == "helmet" }?.sources, [.local])
    }

    func testCatalogDownloadsOnlyEmptyAndUnreadable() throws {
        _ = try temp.makeDirectory("root/valve")
        XCTAssertNil(ModelCatalog.entries(dataRoot: root, gamedir: "valve"))                  // nothing readable
        try folders(["valve/models/player"])
        XCTAssertEqual(ModelCatalog.entries(dataRoot: root, gamedir: "valve"), [])            // empty folder
        try folders(["valve_downloads/models/player/tbo"])
        XCTAssertEqual(ModelCatalog.entries(dataRoot: root, gamedir: "valve")?.map(\.name), ["tbo"])
        try temp.remove("root/valve/models")
        XCTAssertEqual(ModelCatalog.entries(dataRoot: root, gamedir: "valve")?.first?.sources, [.downloaded])
    }

    func testOptionsCurrentFirstAndSourceTooltip() {
        let sources: [String: [ModelSource]] = ["a": [.local, .downloaded], "b": [.downloaded]]
        let options = PlayerOptions.modelOptions(available: ["a", "b"], current: "zzz", sources: sources)
        XCTAssertEqual(options.map(\.value), ["zzz", "a", "b"])
        XCTAssertNil(options[0].sourceTooltip)
        XCTAssertEqual(options[1].sourceTooltip, "Kaynak: Yerel, İndirilen")
        XCTAssertEqual(options[2].sourceTooltip, "Kaynak: İndirilen")
        XCTAssertEqual(ModelSource.local.label, "Yerel")
        XCTAssertEqual(ModelSource.downloaded.label, "İndirilen")
    }

    func testProfileLoaderAndAppModelUseAllSources() async throws {
        let env = try TestAppEnvironment()
        let data = env.valveDir.deletingLastPathComponent()
        for path in ["valve/models/player/gordon", "valve_downloads/models/player/keyturk1",
                     "valve_downloads/models/player/keyturk2", "valve_downloads/models/player/tbo"] {
            try FileManager.default.createDirectory(at: data.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let model = env.makeModel()
        await model.refresh().value
        XCTAssertEqual(model.modelOptions.map(\.value), ["gordon", "keyturk1", "keyturk2", "tbo"])
        XCTAssertEqual(model.modelOptions.map(\.sources), [[.local], [.downloaded], [.downloaded], [.downloaded]])
        XCTAssertFalse(model.allowsManualModelEntry)
        model.modelDraft = "keyturk2"
        XCTAssertEqual(model.pendingModel, "keyturk2")               // selection goes to the `model` key
        XCTAssertTrue(model.canApply)
    }

    // MARK: i18n (§43)

    func testNewKeysAreBilingualAndNoteMatchesSpec() throws {
        XCTAssertEqual(L10n.text(.profileModelServerNote),
                       "Bazı sunucular modeli kendi tarafında zorlar; bu durumda seçim o sunucuda görünmez.")
        XCTAssertEqual(HistoryText.kind(.configOverrideRemoved), "Override satırı kaldırıldı")
        XCTAssertEqual(L10n.text(.configOverrideRemove), "Satırı kaldır")
        XCTAssertEqual(EditMessage.allCases.count, 6)
    }
}

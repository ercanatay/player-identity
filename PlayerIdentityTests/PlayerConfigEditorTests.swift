import XCTest
@testable import PlayerIdentity

/// §15.9/1: only the target lines change, the remaining bytes stay the same.
final class ConfigEditorTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Lines other than `changed` (body + line ending) must be byte-identical.
    private func assertOnlyLinesChanged(_ before: [UInt8], _ after: [UInt8], changed: Set<Int>,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let a = ConfigEditor.split(before)
        let b = ConfigEditor.split(after)
        XCTAssertEqual(a.count, b.count, "satır sayısı", file: file, line: line)
        for index in 0..<min(a.count, b.count) {
            if changed.contains(index) {
                XCTAssertNotEqual(a[index].body, b[index].body, "satır \(index) değişmeliydi", file: file, line: line)
                XCTAssertEqual(a[index].ending, b[index].ending, "satır \(index) satır sonu", file: file, line: line)
            } else {
                XCTAssertEqual(a[index], b[index], "satır \(index) aynı kalmalıydı", file: file, line: line)
            }
        }
    }

    func testSplitJoinRoundtripIsByteExact() {
        for text in ["", "a", "a\n", "a\r\nb\n", "a\nb", "a\r", "\n\n", "x\r\n\r\ny"] {
            XCTAssertEqual(ConfigEditor.join(ConfigEditor.split(bytes(text))), bytes(text), text.debugDescription)
        }
    }

    func testLFFile() {
        let before = bytes("bind \"w\" \"+forward\"\nname \"Eski\"\nmodel \"gordon\"\nsensitivity \"3\"\n")
        let after = ConfigEditor.set("name", to: "Yeni Ad", in: before)
        XCTAssertEqual(after, bytes("bind \"w\" \"+forward\"\nname \"Yeni Ad\"\nmodel \"gordon\"\nsensitivity \"3\"\n"))
        assertOnlyLinesChanged(before, after, changed: [1])
    }

    func testCRLFFile() {
        let before = bytes("bind \"w\" \"+forward\"\r\nmodel \"gordon\"\r\nname \"Eski\"\r\n")
        let after = ConfigEditor.set("model", to: "barney", in: before)
        XCTAssertEqual(after, bytes("bind \"w\" \"+forward\"\r\nmodel \"barney\"\r\nname \"Eski\"\r\n"))
        assertOnlyLinesChanged(before, after, changed: [1])
    }

    func testMissingKeyIsAppendedWithNewline() {
        let lf = bytes("bind \"w\" \"+forward\"\n")
        XCTAssertFalse(ConfigEditor.contains("name", in: lf))
        XCTAssertEqual(ConfigEditor.append("name", value: "Ad", to: lf), bytes("bind \"w\" \"+forward\"\nname \"Ad\"\n"))

        let noTrailingNewline = bytes("bind \"w\" \"+forward\"")
        XCTAssertEqual(ConfigEditor.append("name", value: "Ad", to: noTrailingNewline),
                       bytes("bind \"w\" \"+forward\"\nname \"Ad\"\n"))

        let crlf = bytes("a \"1\"\r\nb \"2\"\r\n")
        XCTAssertEqual(ConfigEditor.append("model", value: "gina", to: crlf), bytes("a \"1\"\r\nb \"2\"\r\nmodel \"gina\"\r\n"))

        XCTAssertEqual(ConfigEditor.append("name", value: "Ad", to: []), bytes("name \"Ad\"\n"))
    }

    func testMixedLineEndingsUseDominantStyleForAppend() {
        let mixed = bytes("a \"1\"\r\nb \"2\"\r\nc \"3\"\nd \"4\"")
        XCTAssertEqual(ConfigEditor.dominantEnding(ConfigEditor.split(mixed)), ConfigEditor.crlf)
        let after = ConfigEditor.append("name", value: "Ad", to: mixed)
        XCTAssertEqual(after, mixed + bytes("\r\nname \"Ad\"\r\n"))
    }

    func testAllOccurrencesAreUpdated() {
        let before = bytes("name \"Bir\"\nbind \"a\" \"+moveleft\"\nname \"İki\"\n  name\t\"Üç\"   // yorum\n")
        let after = ConfigEditor.set("name", to: "Tek", in: before)
        XCTAssertEqual(after, bytes("name \"Tek\"\nbind \"a\" \"+moveleft\"\nname \"Tek\"\n  name\t\"Tek\"   // yorum\n"))
        assertOnlyLinesChanged(before, after, changed: [0, 2, 3])
        XCTAssertEqual(ConfigParser.parse(String(decoding: after, as: UTF8.self)).name, "Tek")
    }

    func testQuotedValueWithSpacesAndOtherKeysUntouched() {
        let before = bytes("name \"  Boşluklu   Ad \"\nnamex \"dokunma\"\n// name \"yorum\"\ncl_name \"x\"\n")
        let after = ConfigEditor.set("name", to: "A B  C", in: before)
        XCTAssertEqual(after, bytes("name \"A B  C\"\nnamex \"dokunma\"\n// name \"yorum\"\ncl_name \"x\"\n"))
        assertOnlyLinesChanged(before, after, changed: [0])
    }

    func testUnquotedAndUnterminatedValues() {
        XCTAssertEqual(ConfigEditor.set("model", to: "gina", in: bytes("model gordon  \n")), bytes("model \"gina\"  \n"))
        XCTAssertEqual(ConfigEditor.set("model", to: "gina", in: bytes("model \"gord\n")), bytes("model \"gina\"\n"))
        XCTAssertFalse(ConfigEditor.contains("name", in: bytes("name\n")))   // a line without a value does not match (same as the parser)
    }

    func testNonUTF8BytesElsewherePreserved() {
        let before: [UInt8] = bytes("say \"") + [0xFE, 0xFF, 0x80] + bytes("\"\nname \"x\"\n")
        let after = ConfigEditor.set("name", to: "y", in: before)
        XCTAssertEqual(after, bytes("say \"") + [0xFE, 0xFF, 0x80] + bytes("\"\nname \"y\"\n"))
    }
}

/// §15.5 validation.
final class PlayerValueValidatorTests: XCTestCase {
    func testNameLengthLimitsIncludingTurkishBytes() {
        XCTAssertEqual(PlayerValueValidator.normalizedName(String(repeating: "a", count: 31)), String(repeating: "a", count: 31))
        XCTAssertNil(PlayerValueValidator.normalizedName(String(repeating: "a", count: 32)))
        // "ş" is 2 bytes in UTF-8: 15 × ş + a = 31 bytes is valid; 16 × ş = 32 bytes (16 characters) is invalid.
        let ok = String(repeating: "ş", count: 15) + "a"
        XCTAssertEqual(ok.utf8.count, 31)
        XCTAssertEqual(PlayerValueValidator.normalizedName(ok), ok)
        let tooManyBytes = String(repeating: "ş", count: 16)
        XCTAssertEqual(tooManyBytes.count, 16)
        XCTAssertNil(PlayerValueValidator.normalizedName(tooManyBytes))
        XCTAssertNil(PlayerValueValidator.normalizedName("Çağrı Öztürk Şişli Ünlüoğlu"))   // 27 characters, 37 bytes
    }

    func testNameEmptyTrimAndForbiddenCharacters() {
        XCTAssertNil(PlayerValueValidator.normalizedName(""))
        XCTAssertNil(PlayerValueValidator.normalizedName("   "))
        XCTAssertEqual(PlayerValueValidator.normalizedName("  TestOyuncu  "), "TestOyuncu")
        for bad in ["a\"b", "a\\b", "a\nb", "a\rb", "a\u{07}b", "a\u{1B}b", "ad\n"] {
            XCTAssertNil(PlayerValueValidator.normalizedName(bad), bad.debugDescription)
        }
        XCTAssertEqual(PlayerValueValidator.normalizedName("TestOyuncu"), "TestOyuncu")
    }

    func testModelRules() {
        for good in ["gordon", "bbbbarney", "Model_1", "a-b", String(repeating: "m", count: 32)] {
            XCTAssertTrue(PlayerValueValidator.isValidModel(good), good)
        }
        for bad in ["", "two words", "q\"x", "çocuk", "a.b", "a/b", String(repeating: "m", count: 33)] {
            XCTAssertFalse(PlayerValueValidator.isValidModel(bad), bad)
        }
    }

    func testMessagesAreVerbatim() {
        XCTAssertEqual(EditMessage.nameInvalid.text, "Kullanıcı adı 1–31 karakter olmalı; tırnak ve satır sonu kullanılamaz.")
        XCTAssertEqual(EditMessage.modelInvalid.text, "Model adı yalnız harf, rakam, alt çizgi ve tire içerebilir.")
        XCTAssertEqual(EditMessage.gameRunning.text, "Oyun açık. Değişiklikler çıkışta ezilir; önce oyunu kapatın.")
        XCTAssertEqual(EditMessage.writeFailed.text, "Dosya yazılamadı. Yedekten geri yüklemek için tekrar deneyin.")
        XCTAssertEqual(EditMessage.configMissing.text, "config.cfg bulunamadı; seçili gamedir doğru mu?")
        XCTAssertEqual(ConfigFileKind.userconfig.note, "userconfig.cfg (config.cfg'yi ezer)")
        XCTAssertEqual(ConfigFileKind.config.note, "config.cfg")
    }
}

/// §15.2 effective value, §15.3–15.4 options.
final class PlayerOptionsTests: XCTestCase {
    func testUserconfigOverridesConfig() {
        let (config, sources) = PlayerConfigResolver.resolve(
            configText: "name \"Config Ad\"\nmodel \"gordon\"\n",
            userconfigText: "cl_advertise_engine_in_name \"0\"\nname \"User Ad\"\n")
        XCTAssertEqual(config, PlayerConfig(name: "User Ad", model: "gordon"))
        XCTAssertEqual(sources, ConfigSources(name: .userconfig, model: .config))

        let none = PlayerConfigResolver.resolve(configText: "bind \"w\" \"+forward\"\n", userconfigText: nil)
        XCTAssertEqual(none.sources, ConfigSources(name: nil, model: nil))
        XCTAssertEqual(none.config, PlayerConfig())

        // An empty value in userconfig also counts as the key and overrides.
        let empty = PlayerConfigResolver.resolve(configText: "name \"A\"\n", userconfigText: "name \"\"\n")
        XCTAssertEqual(empty.config.name, "")
        XCTAssertEqual(empty.sources.name, .userconfig)
    }

    func testReaderAndLoaderShowEffectiveValue() throws {
        let temp = try TempDirectory()
        try temp.write("root/valve/config.cfg", "name \"Config\"\nmodel \"gordon\"\n")
        try temp.write("root/valve/userconfig.cfg", "name \"Userconfig\"\n")
        let gamedir = temp.url.appendingPathComponent("root/valve")
        XCTAssertEqual(ConfigReader().read(gamedir: gamedir).name, "Userconfig")
        _ = try temp.makeDirectory("home")
        let profile = ProfileLoader(fileSystem: LocalFileSystem(), homeDirectory: temp.url.appendingPathComponent("home"))
            .load(dataRoot: temp.url.appendingPathComponent("root"), preferredGamedir: "valve")
        XCTAssertEqual(profile.config, PlayerConfig(name: "Userconfig", model: "gordon"))
        XCTAssertEqual(profile.configSources, ConfigSources(name: .userconfig, model: .config))
    }

    func testModelCatalogListsFoldersAlphabetically() throws {
        let temp = try TempDirectory()
        for name in ["zombie", "Gordon", "barney", ".hidden"] { _ = try temp.makeDirectory("valve/models/player/\(name)") }
        try temp.write("valve/models/player/readme.txt", "dosya")
        let gamedir = temp.url.appendingPathComponent("valve")
        XCTAssertEqual(ModelCatalog.load(gamedir: gamedir), ["barney", "Gordon", "zombie"])
        XCTAssertNil(ModelCatalog.load(gamedir: temp.url.appendingPathComponent("yok")))
    }

    func testModelOptionsMarkCurrentWhenMissing() {
        XCTAssertEqual(PlayerOptions.modelOptions(available: ["barney", "gina"], current: "custom"), [
            ModelOption(value: "custom", label: "custom (mevcut)"),
            ModelOption(value: "barney", label: "barney"),
            ModelOption(value: "gina", label: "gina"),
        ])
        XCTAssertEqual(PlayerOptions.modelOptions(available: ["barney"], current: "barney").map(\.label), ["barney"])
        XCTAssertEqual(PlayerOptions.modelOptions(available: [], current: ""), [])
    }

    func testNameOptionsAndRecentNames() {
        XCTAssertEqual(PlayerOptions.nameOptions(current: "A", saved: "B", recent: ["C", "A", "", "D"]), ["A", "B", "C", "D"])
        XCTAssertEqual(PlayerOptions.nameOptions(current: "", saved: nil, recent: []), [])
        var recent = (1...10).map { "Ad\($0)" }
        recent = PlayerOptions.updatedRecentNames(recent, adding: "Yeni")
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first, "Yeni")
        XCTAssertEqual(PlayerOptions.updatedRecentNames(["X", "Y"], adding: "Y"), ["Y", "X"])
    }
}

/// §15.2, §15.6, §15.9/3, §15.9/5: writer on a temporary fixture gamedir.
final class PlayerConfigWriterTests: XCTestCase {
    private var temp: TempDirectory!
    private var gamedir: URL { temp.url.appendingPathComponent("valve", isDirectory: true) }

    override func setUpWithError() throws {
        temp = try TempDirectory()
        _ = try temp.makeDirectory("valve")
    }

    override func tearDown() {
        temp = nil
    }

    private func read(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: gamedir.appendingPathComponent(name)))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: gamedir.appendingPathComponent(name).path)
    }

    private let configText = "bind \"w\" \"+forward\"\r\nmodel \"gordon\"\r\nname \"Eski\"\r\nsensitivity \"3\"\r\n"
    private let userText = "// kullanıcı ayarları\ncl_advertise_engine_in_name \"0\"\nname \"Eski\"   // ad\n"

    func testWritesBothFilesBacksUpAndLeavesGameBakUntouched() throws {
        try temp.write("valve/config.cfg", configText)
        try temp.write("valve/userconfig.cfg", userText)
        try temp.write("valve/config.cfg.bak", "oyunun yedeği\n")
        let bakBefore = try read("config.cfg.bak")

        let writer = PlayerConfigWriter(detector: FakeGameDetector())
        let outcome = try writer.apply(gamedir: gamedir, name: "Yeni Ad", model: nil)
        XCTAssertEqual(outcome.changedFiles, [.config, .userconfig])
        XCTAssertEqual(outcome.summary, "config.cfg + userconfig.cfg")

        XCTAssertEqual(try read("config.cfg"),
                       Array("bind \"w\" \"+forward\"\r\nmodel \"gordon\"\r\nname \"Yeni Ad\"\r\nsensitivity \"3\"\r\n".utf8))
        XCTAssertEqual(try read("userconfig.cfg"),
                       Array("// kullanıcı ayarları\ncl_advertise_engine_in_name \"0\"\nname \"Yeni Ad\"   // ad\n".utf8))
        XCTAssertEqual(try read("config.cfg.appbak"), Array(configText.utf8))
        XCTAssertEqual(try read("userconfig.cfg.appbak"), Array(userText.utf8))
        XCTAssertEqual(try read("config.cfg.bak"), bakBefore)

        let effective = ConfigReader().readEffective(gamedir: gamedir)
        XCTAssertEqual(effective.config.name, "Yeni Ad")
        XCTAssertEqual(effective.sources.name, .userconfig)
        // No temporary file is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: gamedir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testKeyOnlyInConfigWritesOnlyConfig() throws {
        try temp.write("valve/config.cfg", configText)
        try temp.write("valve/userconfig.cfg", userText)
        let userBefore = try read("userconfig.cfg")
        let outcome = try PlayerConfigWriter(detector: FakeGameDetector()).apply(gamedir: gamedir, name: nil, model: "barney")
        XCTAssertEqual(outcome.changedFiles, [.config])
        XCTAssertEqual(try read("userconfig.cfg"), userBefore)
        XCTAssertFalse(exists("userconfig.cfg.appbak"))
        XCTAssertEqual(ConfigReader().read(gamedir: gamedir).model, "barney")
    }

    func testMissingKeysAreAppendedToConfig() throws {
        try temp.write("valve/config.cfg", "bind \"w\" \"+forward\"\n")
        let outcome = try PlayerConfigWriter(detector: FakeGameDetector()).apply(gamedir: gamedir, name: "Ad", model: "gina")
        XCTAssertEqual(outcome.changedFiles, [.config])
        XCTAssertEqual(try read("config.cfg"), Array("bind \"w\" \"+forward\"\nname \"Ad\"\nmodel \"gina\"\n".utf8))
    }

    func testUserconfigOnlyKeyIsWrittenThere() throws {
        try temp.write("valve/config.cfg", "model \"gordon\"\n")
        try temp.write("valve/userconfig.cfg", "name \"Eski\"\n")
        let outcome = try PlayerConfigWriter(detector: FakeGameDetector()).apply(gamedir: gamedir, name: "Yeni", model: nil)
        XCTAssertEqual(outcome.changedFiles, [.userconfig])
        XCTAssertEqual(try read("config.cfg"), Array("model \"gordon\"\n".utf8))
        XCTAssertEqual(try read("userconfig.cfg"), Array("name \"Yeni\"\n".utf8))
    }

    func testBackupRollsToLatestOriginal() throws {
        try temp.write("valve/config.cfg", "name \"Bir\"\n")
        let writer = PlayerConfigWriter(detector: FakeGameDetector())
        _ = try writer.apply(gamedir: gamedir, name: "İki", model: nil)
        _ = try writer.apply(gamedir: gamedir, name: "Üç", model: nil)
        XCTAssertEqual(try read("config.cfg.appbak"), Array("name \"İki\"\n".utf8))
        XCTAssertEqual(try read("config.cfg"), Array("name \"Üç\"\n".utf8))
    }

    func testGameRunningRefusesWithoutTouchingFiles() throws {
        try temp.write("valve/config.cfg", configText)
        let detector = FakeGameDetector(running: true)
        XCTAssertThrowsError(try PlayerConfigWriter(detector: detector).apply(gamedir: gamedir, name: "Yeni", model: nil)) {
            XCTAssertEqual($0 as? EditMessage, .gameRunning)
        }
        XCTAssertEqual(try read("config.cfg"), Array(configText.utf8))
        XCTAssertFalse(exists("config.cfg.appbak"))
    }

    func testValidationAndMissingConfig() throws {
        let writer = PlayerConfigWriter(detector: FakeGameDetector())
        XCTAssertThrowsError(try writer.apply(gamedir: gamedir, name: "Ad", model: nil)) {
            XCTAssertEqual($0 as? EditMessage, .configMissing)
        }
        try temp.write("valve/config.cfg", configText)
        XCTAssertThrowsError(try writer.apply(gamedir: gamedir, name: "a\"b", model: nil)) {
            XCTAssertEqual($0 as? EditMessage, .nameInvalid)
        }
        XCTAssertThrowsError(try writer.apply(gamedir: gamedir, name: nil, model: "iki kelime")) {
            XCTAssertEqual($0 as? EditMessage, .modelInvalid)
        }
        XCTAssertEqual(try read("config.cfg"), Array(configText.utf8))
    }
}

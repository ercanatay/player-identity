import XCTest
@testable import PlayerIdentity

/// §62: the 24-language set — tables, format specifiers, empty values, system fallback, literal scan and live switching.
@MainActor
final class MultiLanguageTests: XCTestCase {
    private static let codes = ["tr", "en", "de", "fr", "es", "it", "pt", "nl", "sv", "pl", "cs", "ro", "hu", "el", "bg",
                                "uk", "ru", "ar", "fa", "hi", "zh-Hans", "ja", "ko", "id"]
    private static let nativeNames = ["Türkçe", "English", "Deutsch", "Français", "Español", "Italiano", "Português",
                                      "Nederlands", "Svenska", "Polski", "Čeština", "Română", "Magyar", "Ελληνικά",
                                      "Български", "Українська", "Русский", "العربية", "فارسی", "हिन्दी", "简体中文",
                                      "日本語", "한국어", "Bahasa Indonesia"]
    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#)

    override func tearDown() {
        L10n.setting = .system
        L10n.preferredLanguagesOverride = nil
        super.tearDown()
    }

    private func table(_ name: String, _ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "strings", subdirectory: nil,
                                                localization: language), "\(language).lproj/\(name).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) \(name)")
    }

    private func specifiers(_ text: String) -> [String] {
        Self.specifier.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .filter { $0 != "%" }
            .sorted()
    }

    // MARK: Language set

    func testTwentyFourLanguagesWithNativeNames() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), Self.codes)
        XCTAssertEqual(AppLanguage.allCases.map(\.nativeName), Self.nativeNames)
        XCTAssertEqual(AppLanguageSetting.allCases.map(\.rawValue), ["system"] + Self.codes)
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguageSetting(language).rawValue, language.rawValue)
            XCTAssertEqual(AppLanguageSetting(language).resolved(preferredLanguages: ["sw-KE"]), language)
        }
        XCTAssertEqual(Set(Bundle.main.localizations).intersection(Self.codes), Set(Self.codes))
    }

    // MARK: Tables (a, b, c)

    func testEveryLanguageHasTheEnglishKeySet() throws {
        let reference = Set(try table("Localizable", "en").keys)
        XCTAssertEqual(reference, Set(L10nKey.allCases.map(\.rawValue)))
        for language in Self.codes {
            let keys = Set(try table("Localizable", language).keys)
            XCTAssertEqual(reference.subtracting(keys), [], "\(language): missing keys")
            XCTAssertEqual(keys.subtracting(reference), [], "\(language): extra keys")
        }
    }

    func testFormatSpecifiersMatchEnglish() throws {
        let reference = try table("Localizable", "en")
        XCTAssertEqual(specifiers("%@ %d %1$@ %2$ld 100%%"), ["@", "@", "d", "d"])
        for language in Self.codes {
            let values = try table("Localizable", language)
            for (key, english) in reference {
                XCTAssertEqual(specifiers(values[key] ?? ""), specifiers(english), "\(language) \(key)")
            }
        }
    }

    func testNoEmptyValues() throws {
        for language in Self.codes {
            for (key, value) in try table("Localizable", language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) \(key)")
            }
        }
    }

    func testProductNamePerLanguage() throws {
        for language in Self.codes {
            let expected = language == "tr" ? "Cybokron Oyuncu Kimlik Kartı" : "Cybokron Player Identity"
            let info = try table("InfoPlist", language)
            XCTAssertEqual(info["CFBundleDisplayName"], expected, language)
            XCTAssertEqual(info["CFBundleName"], expected, language)
        }
    }

    // MARK: System language (d)

    func testUnsupportedSystemLanguageFallsBackToEnglish() {
        for preferred in [["sw-KE"], ["zh-Hant-TW", "tr-TR"], ["zh-TW"], ["nb-NO"], ["klingon"], []] {
            XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: preferred), .en, "\(preferred)")
        }
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["pt-BR"]), .pt)
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["zh_CN"]), .zhHans)
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["ar-SA"]), .ar)
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["id-ID"]), .id)
        L10n.setting = .system
        L10n.preferredLanguagesOverride = ["sw-KE"]
        XCTAssertEqual(L10n.currentLanguage, .en)
        XCTAssertEqual(L10n.text(.actionSave), "Save")
    }

    func testMissingKeyFallsBackToEnglish() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-\(UUID().uuidString)/xx.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data("\"action.refresh\" = \"R\";\n".utf8).write(to: folder.appendingPathComponent("Localizable.strings"))
        let partial = try XCTUnwrap(Bundle(path: folder.path))
        L10n.$bundle.withValue(partial) {
            XCTAssertEqual(L10n.text(.actionRefresh), "R")
            XCTAssertEqual(L10n.text(.actionSave), "Save")
            XCTAssertEqual(L10n.format(.topbarLastCheck, "12:00:00"), "Last check: 12:00:00")
        }
    }

    // MARK: Literal scan (e)

    func testNativeNamesAreNotLiteralsInSources() throws {
        let resources = try XCTUnwrap(Bundle(for: MultiLanguageTests.self).resourceURL)
        var files: [URL] = []
        for folder in ["App", "Core"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: resources.appendingPathComponent(folder),
                                                                          includingPropertiesForKeys: nil), folder)
            files += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        XCTAssertGreaterThan(files.count, 20)
        let names = Self.nativeNames.filter { $0.unicodeScalars.contains { $0.value > 127 } }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for name in names { XCTAssertFalse(source.contains(name), "\(file.lastPathComponent): \(name)") }
            XCTAssertEqual(LiteralScanner.violations(in: source), [], file.lastPathComponent)
        }
    }

    // MARK: Live switching (f)

    func testSwitchingToANewLanguageAppliesAtOnce() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        for language in AppLanguage.allCases {
            model.appLanguage = AppLanguageSetting(language)
            XCTAssertEqual(L10n.currentLanguage, language)
            let expected = try table("Localizable", language.rawValue)[L10nKey.actionRefresh.rawValue]
            XCTAssertEqual(L10n.text(.actionRefresh), expected, language.rawValue)
        }
        XCTAssertEqual(environment.defaults.string(forKey: DefaultsKey.appLanguage), "id")
        model.appLanguage = .zhHans
        XCTAssertEqual(environment.makeModel().appLanguage, .zhHans)
        model.appLanguage = .tr
        XCTAssertEqual(L10n.text(.actionRefresh), "Yenile")
    }
}

import XCTest
@testable import PlayerIdentity

/// §35.4: language resolution matrix, persistence, live switching and key parity.
@MainActor
final class LanguageSelectorTests: XCTestCase {
    override func tearDown() {
        L10n.setting = .system
        L10n.preferredLanguagesOverride = nil
        super.tearDown()
    }

    func testResolutionMatrix() {
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["tr-TR"]), .tr)
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["tr"]), .tr)
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["en-US"]), .en)
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["sw-KE", "tr-TR"]), .en)   // §62: unsupported first
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: ["de-DE", "tr-TR"]), .de)   // §62: German shipped
        XCTAssertEqual(AppLanguageSetting.system.resolved(preferredLanguages: []), .en)
        XCTAssertEqual(AppLanguageSetting.tr.resolved(preferredLanguages: ["en-US"]), .tr)
        XCTAssertEqual(AppLanguageSetting.en.resolved(preferredLanguages: ["tr-TR"]), .en)
        XCTAssertEqual(AppLanguageSetting(stored: "sw"), .system)
        XCTAssertEqual(AppLanguageSetting(stored: "fr"), .fr)   // §62
        XCTAssertEqual(AppLanguageSetting(stored: nil), .system)
        XCTAssertEqual(AppLanguageSetting(stored: "tr"), .tr)
    }

    func testInvalidStoredValueFallsBackToSystem() throws {
        let environment = try TestAppEnvironment()
        environment.defaults.set("klingon", forKey: DefaultsKey.appLanguage)
        XCTAssertEqual(environment.makeModel().appLanguage, .system)
    }

    func testPersistenceAndReload() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        XCTAssertEqual(model.appLanguage, .system)
        model.appLanguage = .en
        XCTAssertEqual(environment.defaults.string(forKey: DefaultsKey.appLanguage), "en")
        XCTAssertEqual(environment.makeModel().appLanguage, .en)
        XCTAssertEqual(L10n.setting, .en)
    }

    func testChangingLanguageSwitchesTextsImmediately() throws {
        let environment = try TestAppEnvironment()
        let model = environment.makeModel()
        model.appLanguage = .tr
        XCTAssertEqual(L10n.text(.actionRefresh), "Yenile")
        XCTAssertEqual(StatusLevel.green.label, "Tümü tamam")
        model.appLanguage = .en
        XCTAssertEqual(L10n.text(.actionRefresh), "Refresh")
        XCTAssertEqual(StatusLevel.green.label, "All good")
        model.appLanguage = .tr
        XCTAssertEqual(L10n.text(.actionRefresh), "Yenile")
    }

    func testSystemFollowsPreferredLanguages() {
        L10n.setting = .system
        L10n.preferredLanguagesOverride = ["tr-TR"]
        XCTAssertEqual(L10n.text(.actionSave), "Kaydet")
        L10n.preferredLanguagesOverride = ["sw-KE"]   // §62: unsupported → English
        XCTAssertEqual(L10n.text(.actionSave), "Save")
    }

    func testLanguageLabelsAreNativeAndKeysComplete() throws {
        L10n.setting = .en
        XCTAssertEqual(L10n.text(.languageTurkish), "Türkçe")
        XCTAssertEqual(L10n.text(.languageEnglish), "English")
        XCTAssertEqual(L10n.format(.languageSystemResolved, "Türkçe"), "System (Türkçe)")
        L10n.setting = .tr
        XCTAssertEqual(L10n.format(.languageSystemResolved, "English"), "Sistem (English)")
        XCTAssertEqual(L10n.text(.settingsLanguage), "Dil / Language")
        for language in ["tr", "en"] {
            let bundle = try XCTUnwrap(L10n.languageBundle(language))
            for key in [L10nKey.settingsLanguage, .languageSystem, .languageSystemResolved, .languageTurkish,
                        .languageEnglish, .settingsLanguageNote] {
                let value = bundle.localizedString(forKey: key.rawValue, value: "", table: nil)
                XCTAssertFalse(value.isEmpty, "\(language) \(key.rawValue)")
            }
        }
    }

    func testKeyCountsEqualAcrossLanguages() throws {
        func count(_ language: String) throws -> Int {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                    subdirectory: nil, localization: language))
            return try XCTUnwrap(NSDictionary(contentsOf: url)).count
        }
        XCTAssertEqual(try count("tr"), try count("en"))
        XCTAssertEqual(try count("tr"), L10nKey.allCases.count)
    }
}

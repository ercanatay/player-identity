import Foundation

/// Language the UI texts are shown in (§35, §62). `rawValue` is the `<code>.lproj` folder name.
enum AppLanguage: String, CaseIterable, Sendable {
    case tr
    case en
    case de
    case fr
    case es
    case it
    case pt
    case nl
    case sv
    case pl
    case cs
    case ro
    case hu
    case el
    case bg
    case uk
    case ru
    case ar
    case fa
    case hi
    case zhHans = "zh-Hans"
    case ja
    case ko
    case id

    /// The language's own name (Deutsch, Nederlands, …; §62) from the unlocalized `LanguageNames.strings`.
    var nativeName: String { Self.nativeNames[rawValue] ?? rawValue }

    private static let nativeNames: [String: String] = {
        guard let url = Bundle.main.url(forResource: "LanguageNames", withExtension: "strings"),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return table
    }()

    /// Supported language for one preferred-language identifier (`de-DE`, `pt_BR`, `zh-Hans-CN`); `nil` if none.
    /// Only Simplified Chinese is shipped: `zh-Hant`, `zh-TW`, `zh-HK` and `zh-MO` do not match.
    static func matching(_ identifier: String) -> AppLanguage? {
        let parts = identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let code = parts.first else { return nil }
        guard code == "zh" else { return AppLanguage(rawValue: code) }
        if parts.contains("hans") { return .zhHans }
        if parts.contains("hant") { return nil }
        guard let region = parts.dropFirst().first else { return .zhHans }
        return ["cn", "sg"].contains(region) ? .zhHans : nil
    }
}

/// The stored `appLanguage` choice: follow the system or force one language (§35.1, §62).
enum AppLanguageSetting: String, CaseIterable, Sendable {
    case system
    case tr
    case en
    case de
    case fr
    case es
    case it
    case pt
    case nl
    case sv
    case pl
    case cs
    case ro
    case hu
    case el
    case bg
    case uk
    case ru
    case ar
    case fa
    case hi
    case zhHans = "zh-Hans"
    case ja
    case ko
    case id

    /// Missing or corrupt values count as `system`.
    init(stored: String?) {
        self = stored.flatMap(AppLanguageSetting.init(rawValue:)) ?? .system
    }

    init(defaults: UserDefaults) {
        self.init(stored: defaults.string(forKey: DefaultsKey.appLanguage))
    }

    /// The explicit choice for `language` (both enums share the raw values; checked by the tests).
    init(_ language: AppLanguage) {
        self = AppLanguageSetting(rawValue: language.rawValue) ?? .system
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: DefaultsKey.appLanguage)
    }

    /// Explicit choice wins; `system` uses the first preferred language when it is supported, else English.
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let language = AppLanguage(rawValue: rawValue) { return language }
        return preferredLanguages.first.flatMap(AppLanguage.matching) ?? .en
    }
}

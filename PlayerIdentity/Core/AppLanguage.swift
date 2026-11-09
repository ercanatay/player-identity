import Foundation

/// Language the UI texts are shown in (§35).
enum AppLanguage: String, CaseIterable, Sendable {
    case tr
    case en

    /// Own-language label key (always written in that language, §35.2).
    var labelKey: L10nKey { self == .tr ? .languageTurkish : .languageEnglish }
}

/// The stored `appLanguage` choice: follow the system or force one language (§35.1).
enum AppLanguageSetting: String, CaseIterable, Sendable {
    case system
    case tr
    case en

    /// Missing or corrupt values count as `system`.
    init(stored: String?) {
        self = stored.flatMap(AppLanguageSetting.init(rawValue:)) ?? .system
    }

    init(defaults: UserDefaults) {
        self.init(stored: defaults.string(forKey: DefaultsKey.appLanguage))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: DefaultsKey.appLanguage)
    }

    /// Explicit choice wins; `system` uses the first preferred language (`tr*` → Turkish, else English).
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .tr: return .tr
        case .en: return .en
        case .system:
            let first = preferredLanguages.first?.lowercased() ?? ""
            return first == "tr" || first.hasPrefix("tr-") || first.hasPrefix("tr_") ? .tr : .en
        }
    }
}

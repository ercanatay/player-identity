import Foundation

/// Type-safe access to localized texts (§18). Keys are `L10nKey` cases, so a typo fails to compile.
///
/// The lookup bundle is the `.lproj` of the language chosen in Settings (§35; cached). Tests can still resolve
/// texts in a specific language with `L10n.$bundle.withValue(…)`, which overrides the selection.
enum L10n {
    @TaskLocal static var bundle: Bundle?

    private struct State {
        var setting: AppLanguageSetting = .system
        var preferredLanguages: [String]?
        var cache: [AppLanguage: Bundle] = [:]
    }
    private static let state = NSLockedState()

    private final class NSLockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = State()
        func withLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&value)
        }
    }

    /// The stored choice currently in effect.
    static var setting: AppLanguageSetting {
        get { state.withLock { $0.setting } }
        set { state.withLock { $0.setting = newValue } }
    }

    /// Test hook: replaces `Locale.preferredLanguages` for the `system` choice; `nil` restores the real list.
    static var preferredLanguagesOverride: [String]? {
        get { state.withLock { $0.preferredLanguages } }
        set { state.withLock { $0.preferredLanguages = newValue } }
    }

    /// Language the texts are currently shown in.
    static var currentLanguage: AppLanguage {
        let (setting, preferred) = state.withLock { ($0.setting, $0.preferredLanguages) }
        return setting.resolved(preferredLanguages: preferred ?? Locale.preferredLanguages)
    }

    private static var activeBundle: Bundle {
        if let override = bundle { return override }
        let language = currentLanguage
        if let cached = state.withLock({ $0.cache[language] }) { return cached }
        let resolved = languageBundle(language.rawValue) ?? .main
        state.withLock { $0.cache[language] = resolved }
        return resolved
    }

    static func text(_ key: L10nKey) -> String {
        activeBundle.localizedString(forKey: key.rawValue, value: nil, table: nil)
    }

    /// Format string with `%@` placeholders, filled in order.
    static func format(_ key: L10nKey, _ arguments: String...) -> String {
        String(format: text(key), arguments: arguments.map { $0 as NSString })
    }

    /// Bundle of one `<language>.lproj` folder inside `bundle`; `nil` if the app has no such localization.
    static func languageBundle(_ language: String, in bundle: Bundle = .main) -> Bundle? {
        bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

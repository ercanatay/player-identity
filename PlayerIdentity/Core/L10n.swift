import Foundation

/// Type-safe access to localized texts (§18). Keys are `L10nKey` cases, so a typo fails to compile.
///
/// The lookup bundle is a task-local value: the app uses `Bundle.main` (system language, falling back to
/// English), tests can resolve texts in a specific language with `L10n.$bundle.withValue(…)`.
enum L10n {
    @TaskLocal static var bundle: Bundle = .main

    static func text(_ key: L10nKey) -> String {
        bundle.localizedString(forKey: key.rawValue, value: nil, table: nil)
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

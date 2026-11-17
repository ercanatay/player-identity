import SwiftUI

extension View {
    /// Mirrors the layout for right-to-left app languages (`ar`, `fa`), independent of the system language.
    func appLayoutDirection(_ setting: AppLanguageSetting,
                            preferredLanguages: [String] = Locale.preferredLanguages) -> some View {
        environment(\.layoutDirection,
                    setting.resolved(preferredLanguages: preferredLanguages).isRightToLeft ? .rightToLeft : .leftToRight)
    }
}

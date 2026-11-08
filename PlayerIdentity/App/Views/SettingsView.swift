import SwiftUI

/// Settings (§13.1): "Ban check" toggle, on by default.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle("Ban kontrolü", isOn: $model.banCheckEnabled)
        }
        .padding(20)
        .frame(width: 320)
    }
}

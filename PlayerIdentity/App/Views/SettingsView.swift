import SwiftUI

/// Settings (§13.1, §23): "Ban check" and "Notifications" toggles, both on by default.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle(L10n.text(.settingsBanCheck), isOn: $model.banCheckEnabled)
            Toggle(L10n.text(.settingsNotifications), isOn: $model.notificationsEnabled)
        }
        .padding(20)
        .frame(width: 320)
    }
}

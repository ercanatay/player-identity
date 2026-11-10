import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings: General (§13.1 ban check, §23 notifications) and Updates (§27.3, §28.2).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label(L10n.text(.settingsTabGeneral), systemImage: "gearshape") }

            UpdateSettingsView(updates: model.updates)
                .tabItem { Label(L10n.text(.settingsTabUpdates), systemImage: "arrow.down.circle") }
        }
        .frame(width: 600)
    }
}

/// Settings > General: ban check, notifications, menu bar mode and launch at login (§13.1, §23, §30).
struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    /// `HH:mm` string ↔ Date (today at that time) for a DatePicker.
    private func quietBinding(_ keyPath: ReferenceWritableKeyPath<AppModel, String>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = QuietHours.minutes(model[keyPath: keyPath]) ?? 0
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model[keyPath: keyPath] = QuietHours.text(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            })
    }

    var body: some View {
        Form {
            Toggle(L10n.text(.settingsBanCheck), isOn: $model.banCheckEnabled)
            Toggle(L10n.text(.settingsNotifications), isOn: $model.notificationsEnabled)
            Toggle(L10n.text(.settingsNotifyBan), isOn: $model.notifyBanChanges)
                .disabled(!model.notificationsEnabled)
            Toggle(L10n.text(.settingsNotifyOnline), isOn: $model.notifyOnlineChanges)
                .disabled(!model.notificationsEnabled)
            Toggle(L10n.text(.settingsNotifyMap), isOn: $model.notifyMapChanges)
                .disabled(!model.notificationsEnabled)
            Toggle(L10n.text(.settingsQuietHours), isOn: $model.quietHoursEnabled)
                .disabled(!model.notificationsEnabled)
            HStack {
                DatePicker(L10n.text(.settingsQuietFrom), selection: quietBinding(\.quietHoursStart),
                           displayedComponents: .hourAndMinute)
                DatePicker(L10n.text(.settingsQuietTo), selection: quietBinding(\.quietHoursEnd),
                           displayedComponents: .hourAndMinute)
            }
            .disabled(!model.notificationsEnabled || !model.quietHoursEnabled)
            Text(L10n.text(.settingsQuietNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: $model.appLanguage) {
                    Text(L10n.format(.languageSystemResolved,
                                     L10n.text(AppLanguageSetting.system.resolved().labelKey)))
                        .tag(AppLanguageSetting.system)
                    Text(L10n.text(.languageTurkish)).tag(AppLanguageSetting.tr)
                    Text(L10n.text(.languageEnglish)).tag(AppLanguageSetting.en)
                } label: {
                    Text(L10n.text(.settingsLanguage))
                }
                .accessibilityIdentifier("settingsLanguage")
                Text(L10n.text(.settingsLanguageNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Toggle(L10n.text(.settingsMenuBar), isOn: $model.menuBarEnabled)
                    .accessibilityIdentifier("settingsMenuBar")
                Text(L10n.text(.settingsMenuBarHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(L10n.text(.settingsLaunchAtLogin), isOn: Binding(
                    get: { model.loginItemStatus.isOn },
                    set: { model.setLaunchAtLogin($0) }))
                    .disabled(!model.isLoginItemAvailable)
                    .accessibilityIdentifier("settingsLaunchAtLogin")
                if model.loginItemStatus == .requiresApproval {
                    Text(L10n.text(.settingsLaunchAtLoginApproval))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.loginItemError {
                    Text(LoginItemText.error(error))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("loginItemError")
                }
            }
            Divider()
            DiagnosticsSettingsRow(model: model)
        }
        .padding(20)
        .onAppear { model.refreshLoginItemStatus() }
    }
}

/// §41 "Teşhis paketi oluştur…": ZIP via NSSavePanel; the note says what is masked.
struct DiagnosticsSettingsRow: View {
    @Bindable var model: AppModel
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(L10n.text(.diagnosticsCreate), action: create)
                    .disabled(isWorking)
                    .accessibilityIdentifier("diagnosticsCreate")
                if isWorking { ProgressView().controlSize(.small) }
            }
            Text(L10n.text(.diagnosticsNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("diagnosticsMessage")
            }
        }
    }

    private func create() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = DiagnosticsBundle.defaultFileName(now: model.now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task {
            let data = await model.diagnosticsArchive()
            do {
                try data.write(to: url, options: .atomic)
                message = L10n.format(.diagnosticsSaved, url.path)
                isError = false
            } catch {
                message = L10n.format(.diagnosticsFailed, error.localizedDescription)
                isError = true
            }
            isWorking = false
        }
    }
}

/// Settings > Updates: version, last check, switches, "Check Now", status/progress, version history.
struct UpdateSettingsView: View {
    @Bindable var updates: UpdateController
    @State private var confirmsBackupRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.text(.updateCurrentVersion)).foregroundStyle(.secondary)
                    Text(verbatim: updates.appVersion).monospacedDigit()
                }
                GridRow {
                    Text(L10n.text(.updateLastCheck)).foregroundStyle(.secondary)
                    Text(updates.lastCheck.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
                         ?? L10n.text(.updateNever))
                }
            }
            Toggle(L10n.text(.updateAutoCheck), isOn: $updates.preferences.autoCheck)
            Toggle(L10n.text(.updateAutoDownload), isOn: $updates.preferences.autoDownload)
            HStack {
                Button(L10n.text(.updateCheckNow)) { updates.checkForUpdates(manual: true) }
                    .disabled(updates.status.isBusy)
                Spacer()
            }
            UpdateStatusRow(updates: updates)
                .frame(minHeight: 18, alignment: .leading)

            Divider()
            Text(L10n.text(.updateHistory)).font(.headline)
            if updates.history.isEmpty {
                Text(L10n.text(.updateHistoryEmpty)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(updates.history, id: \.tag) { release in
                            VersionRow(updates: updates, release: release)
                            Divider()
                        }
                    }
                }
                .frame(height: 220)
            }

            Divider()
            HStack {
                Text(L10n.format(.updateBackupsCount, String(updates.dataBackupCount))).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text(.updateBackupsClear)) { confirmsBackupRemoval = true }
                    .disabled(updates.dataBackupCount == 0)
            }
        }
        .padding(20)
        .sheet(item: Binding(
            get: { updates.pendingInstall?.origin == .settings ? updates.pendingInstall : nil },
            set: { if $0 == nil { updates.cancelRequest() } })
        ) { request in
            InstallConfirmSheet(updates: updates, request: request)
        }
        .alert(L10n.text(.updateBackupsClearConfirm), isPresented: $confirmsBackupRemoval) {
            Button(L10n.text(.actionCancel), role: .cancel) {}
            Button(L10n.text(.actionDelete), role: .destructive) { updates.removeDataBackups() }
        }
    }
}

/// One stable release in the version history: current marked, "Install" for newer, "Revert" for older.
private struct VersionRow: View {
    @Bindable var updates: UpdateController
    let release: AppRelease

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: release.versionString)
                .font(.body.monospacedDigit())
                .fontWeight(updates.change(to: release) == nil ? .bold : .regular)
                .frame(width: 70, alignment: .leading)
            if let date = release.publishedAt {
                Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
                    .foregroundStyle(.secondary)
            }
            if updates.change(to: release) == nil {
                Text(L10n.text(.updateCurrentBadge))
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
            Spacer()
            if let page = release.pageURL {
                Button(L10n.text(.updateReleaseNotes)) { NSWorkspace.shared.open(page) }
                    .buttonStyle(.link)
            }
            switch updates.change(to: release) {
            case .downgrade?:
                Button(L10n.text(.updateDowngrade)) { updates.request(release) }
                    .disabled(!release.isInstallable || updates.status.isBusy)
            case .upgrade?:
                Button(L10n.text(.updateInstall)) { updates.request(release) }
                    .disabled(!release.isInstallable || updates.status.isBusy)
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
    }
}

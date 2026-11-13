import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (Claude Design S1–S15): native `Settings { TabView }` with General and Updates, 600 × 520; each tab
/// is a scroll view of grouped cards. Window chrome and the tab toolbar are the system ones.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            UpdateSettingsView(updates: model.updates)
                .tabItem { Label(SettingsTab.updates.title, systemImage: SettingsTab.updates.symbol) }
                .tag(SettingsTab.updates)
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

/// Settings > General: ban checks (§13.1), notifications (§23, §45), language (§35), menu bar and launch at login
/// (§30), data (data root, export/import §46, full backup §49, diagnostics §41) and the separate Reset group.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPage {
            banChecks
            NotificationSettingsSection(model: model)
            language
            app
            SettingsSection(title: L10n.text(.dataSectionTitle)) {
                DataRootRow(model: model)
                SettingsDivider()
                DataSettingsRow(model: model)
                SettingsDivider()
                FullBackupSettingsRows(model: model)
                SettingsDivider()
                DiagnosticsSettingsRow(model: model)
            }
            ResetSettingsSection(model: model)
        }
        .onAppear { model.refreshLoginItemStatus() }
    }

    private var banChecks: some View {
        SettingsSection(title: L10n.text(.settingsSectionBanChecks)) {
            SettingsSwitchRow(title: L10n.text(.settingsBanCheckAuto), caption: L10n.text(.settingsBanCheckCaption),
                              isOn: $model.banCheckEnabled, identifier: "settingsBanCheck")
        }
    }

    private var language: some View {
        SettingsSection(title: L10n.text(.settingsSectionLanguage)) {
            SettingsRow(title: L10n.text(.settingsLanguageLabel), caption: L10n.text(.settingsLanguageCaption)) {
                Picker(L10n.text(.settingsLanguageLabel), selection: $model.appLanguage) {
                    Text(L10n.text(.languageSystem)).tag(AppLanguageSetting.system)
                    Text(L10n.text(.languageTurkish)).tag(AppLanguageSetting.tr)
                    Text(L10n.text(.languageEnglish)).tag(AppLanguageSetting.en)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(L10n.format(.languageSystemResolved, L10n.text(AppLanguageSetting.system.resolved().labelKey)))
                .accessibilityLabel(L10n.text(.settingsLanguageLabel))
                .accessibilityIdentifier("settingsLanguage")
            }
        }
    }

    private var app: some View {
        SettingsSection(title: L10n.text(.settingsSectionApp)) {
            SettingsSwitchRow(symbol: "menubar.rectangle", title: L10n.text(.settingsMenuBar),
                              caption: L10n.text(.settingsMenuBarHint), isOn: $model.menuBarEnabled,
                              identifier: "settingsMenuBar")
            SettingsDivider()
            SettingsSwitchRow(symbol: "power", title: L10n.text(.settingsLaunchAtLogin), isOn: Binding(
                get: { model.loginItemStatus.isOn },
                set: { model.setLaunchAtLogin($0) }), identifier: "settingsLaunchAtLogin")
                .disabled(!model.isLoginItemAvailable)
            if model.loginItemStatus == .requiresApproval {
                Text(L10n.text(.settingsLaunchAtLoginApproval))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
                    .padding(.bottom, Space.s2)
            }
            if let error = model.loginItemError {
                Text(LoginItemText.error(error))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 28)
                    .padding(.bottom, Space.s2)
                    .accessibilityIdentifier("loginItemError")
            }
        }
    }
}

/// Notifications: master switch; ban / online / map checkboxes and quiet hours indent 20 and dim while it is off.
struct NotificationSettingsSection: View {
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
        SettingsSection(title: L10n.text(.settingsNotifications)) {
            SettingsSwitchRow(title: L10n.text(.settingsNotificationsAllow),
                              caption: L10n.text(.settingsNotificationsCaption),
                              isOn: $model.notificationsEnabled, identifier: "settingsNotifications")
            ForEach(NotificationSettingsText.warnings(model), id: \.self) { warning in
                SettingsMessage(text: warning, isError: true)
                    .padding(.bottom, Space.s2)
                    .accessibilityIdentifier("settingsNotificationsWarning")
            }
            VStack(alignment: .leading, spacing: 0) {
                SettingsDivider()
                SettingsCheckboxRow(symbol: "checkmark.shield.fill", title: L10n.text(.settingsNotifyBan),
                                    isOn: $model.notifyBanChanges)
                SettingsDivider()
                SettingsCheckboxRow(symbol: "bell", title: L10n.text(.settingsNotifyOnline),
                                    isOn: $model.notifyOnlineChanges)
                SettingsDivider()
                SettingsCheckboxRow(symbol: "globe", title: L10n.text(.settingsNotifyMap), isOn: $model.notifyMapChanges)
                SettingsDivider()
                SettingsRow(symbol: "moon.fill", title: L10n.text(.settingsQuietHours),
                            caption: L10n.text(.settingsQuietCaption), indent: 20) {
                    HStack(spacing: 6) {
                        quietPicker(\.quietHoursStart, label: .settingsQuietFrom)
                        Text(verbatim: "–").foregroundStyle(Palette.text2).accessibilityHidden(true)
                        quietPicker(\.quietHoursEnd, label: .settingsQuietTo)
                    }
                    .disabled(!model.quietHoursEnabled)
                    SettingsSwitch(title: L10n.text(.settingsQuietHours), hint: L10n.text(.settingsQuietNote),
                                   isOn: $model.quietHoursEnabled, identifier: "settingsQuietHours")
                }
            }
            .disabled(!model.notificationsEnabled)
            .opacity(model.notificationsEnabled ? 1 : 0.45)
            .help(model.notificationsEnabled ? "" : L10n.text(.settingsNotificationsOffNote))
        }
        .task(id: model.notificationsEnabled) {
            if model.notificationsEnabled { await model.refreshNotificationPermission() }
        }
    }

    private func quietPicker(_ keyPath: ReferenceWritableKeyPath<AppModel, String>, label: L10nKey) -> some View {
        DatePicker(L10n.text(label), selection: quietBinding(keyPath), displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .labelsHidden()
            .monospacedDigit()
            .fixedSize()
            .accessibilityLabel(L10n.text(label))
    }
}

/// Red lines under the notifications switch: macOS refused the permission (§23), the watch state could not be
/// written (§42).
enum NotificationSettingsText {
    @MainActor
    static func warnings(_ model: AppModel) -> [String] {
        var lines: [String] = []
        if model.notificationsEnabled, model.notificationPermissionDenied {
            lines.append(L10n.text(.settingsNotificationsDenied))
        }
        if let error = model.watchStateSaveError { lines.append(L10n.format(.watchStateSaveFailed, error)) }
        return lines
    }
}

/// Data root: path (mono, middle-truncated, tooltip) in an inset field + Show in Finder + Change…
struct DataRootRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.profileDataRoot)).font(TypeScale.body)
                Text(L10n.text(.settingsDataRootCaption))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s2) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .accessibilityHidden(true)
                    Text(verbatim: SettingsFormat.abbreviated(model.dataRoot.path, home: model.homeDirectory))
                        .font(TypeScale.mono)
                        .middleTruncated(model.dataRoot.path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Space.s2)
                .frame(height: Metrics.control)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.inset))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.border, lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.text(.profileDataRoot))
                .accessibilityValue(model.dataRoot.path)
                Button(L10n.text(.profileShowInFinder)) { Finder.reveal(model.dataRoot) }
                    .fixedSize()
                Button(L10n.text(.settingsChange)) { DataRootPanel.choose(model) }
                    .fixedSize()
                    .accessibilityIdentifier("settingsDataRootChange")
            }
        }
        .padding(.vertical, Space.s2)
    }
}

/// Folder panel for the data root (shared by the profile card and Settings).
enum DataRootPanel {
    @MainActor
    static func choose(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = model.dataRoot
        panel.prompt = L10n.text(.profilePanelPrompt)
        panel.message = L10n.text(.profilePanelMessage)
        if panel.runModal() == .OK, let url = panel.url {
            model.setDataRoot(url)
        }
    }
}

/// §41 diagnostics package (ZIP via NSSavePanel; the note says what is masked) and the history window.
struct DiagnosticsSettingsRow: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            SettingsActionRow(title: L10n.text(.settingsDiagnostics), caption: L10n.text(.diagnosticsNote)) {
                if isWorking { ProgressView().controlSize(.small) }
                SymbolButton(title: L10n.text(.diagnosticsCreate), symbol: "waveform.path.ecg", action: create)
                    .disabled(isWorking)
                    .accessibilityIdentifier("diagnosticsCreate")
                Button(L10n.text(.settingsOpenHistory)) { openWindow(id: "history") }
                    .fixedSize()
            }
            if let message {
                SettingsMessage(text: message, isError: isError)
                    .padding(.bottom, Space.s2)
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

/// Separate "Reset" group at the bottom of General: Reset Settings… and Erase All Data…, both confirmed with a
/// destructive alert (Cancel is the default); Erase offers "Export settings first".
struct ResetSettingsSection: View {
    @Bindable var model: AppModel
    @State private var confirmation: Confirmation?
    @State private var exportFirst = true
    @State private var pendingAction: Confirmation.Kind?
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false

    struct Confirmation: Identifiable {
        enum Kind { case reset, erase }
        let id = UUID()
        let kind: Kind
        /// Erase only: what will be removed.
        var servers = 0
        var backups = 0
        var folder = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection(title: L10n.text(.settingsSectionReset), caption: L10n.text(.settingsResetCaption)) {
                row(L10n.text(.settingsResetSettingsCaption)) {
                    Button(L10n.text(.settingsResetSettings)) { confirmation = Confirmation(kind: .reset) }
                        .fixedSize()
                        .accessibilityIdentifier("settingsResetSettings")
                }
                SettingsDivider()
                row(L10n.text(.settingsEraseCaption)) {
                    if isWorking { ProgressView().controlSize(.small) }
                    SymbolButton(title: L10n.text(.settingsErase), symbol: "trash", role: .destructive,
                                 tint: Palette.redText, action: askErase)
                        .fontWeight(.medium)
                        .disabled(isWorking || model.updates.status.isBusy)
                        .accessibilityIdentifier("settingsErase")
                }
            }
            if let message {
                SettingsMessage(text: message, isError: isError)
                    .accessibilityIdentifier("resetMessage")
            }
        }
        .padding(.top, Space.s4)
        .overlay(alignment: .top) { ThemedDivider() }
        .padding(.top, Space.s2)
        .sheet(item: $confirmation, onDismiss: runPendingAction) { item in
            sheet(item)
        }
    }

    /// Caption-styled description (12 secondary) on the left, the button on the right.
    private func row<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Space.s3) {
            Text(text)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, Space.s2)
        .frame(minHeight: 36)
    }

    @ViewBuilder
    private func sheet(_ item: Confirmation) -> some View {
        switch item.kind {
        case .reset:
            DestructiveConfirmSheet(title: L10n.text(.resetConfirmTitle), message: L10n.text(.resetConfirmBody),
                                    confirmTitle: L10n.text(.resetConfirmAction), checkbox: .constant(false),
                                    onCancel: { confirmation = nil },
                                    onConfirm: { pendingAction = .reset; confirmation = nil })
        case .erase:
            DestructiveConfirmSheet(title: L10n.text(.eraseConfirmTitle),
                                    message: L10n.format(.eraseConfirmBody, String(item.servers), String(item.backups),
                                                         item.folder),
                                    confirmTitle: L10n.text(.eraseConfirmAction),
                                    checkboxTitle: L10n.text(.eraseExportFirst), checkbox: $exportFirst,
                                    onCancel: { confirmation = nil },
                                    onConfirm: { pendingAction = .erase; confirmation = nil })
        }
    }

    private func askErase() {
        let inventory = model.eraseInventory
        confirmation = Confirmation(kind: .erase, servers: model.servers.count, backups: inventory.backups,
                                    folder: SettingsFormat.abbreviated(model.appDataFolder.path, home: model.homeDirectory))
    }

    /// Runs after the alert is gone, so the save panel (Export settings first) never stacks on the sheet.
    private func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .reset:
            model.resetSettings()
            message = L10n.text(.resetDone)
            isError = false
        case .erase:
            if exportFirst {
                switch SettingsExportWriter.save(model: model, scope: .settingsAndServers, includeDataRoot: true) {
                case .saved:
                    break
                case .cancelled:
                    message = L10n.text(.eraseExportCancelled)
                    isError = false
                    return
                case .failed(let text):
                    message = text
                    isError = true
                    return
                }
            }
            isWorking = true
            Task {
                let error = await model.eraseAllData()
                message = error ?? L10n.text(.eraseDone)
                isError = error != nil
                isWorking = false
            }
        }
    }
}

// MARK: - Updates

/// Settings > Updates: app header (icon, name, version, last check, Check Now), status card, automatic switches,
/// version history with Downgrade… and the backup note (§27.3, §28.2).
struct UpdateSettingsView: View {
    @Bindable var updates: UpdateController
    @State private var confirmsBackupRemoval = false

    var body: some View {
        SettingsPage {
            header
            UpdateStatusCard(updates: updates)
            SettingsSection(title: L10n.text(.updatesSectionAutomatic)) {
                SettingsSwitchRow(title: L10n.text(.updateAutoCheck), caption: L10n.text(.updatesAutoCheckCaption),
                                  isOn: $updates.preferences.autoCheck, identifier: "updatesAutoCheck")
                SettingsDivider()
                SettingsSwitchRow(title: L10n.text(.updatesAutoDownloadLabel),
                                  caption: L10n.text(.updatesAutoDownloadCaption),
                                  isOn: $updates.preferences.autoDownload, identifier: "updatesAutoDownload")
            }
            history
        }
        .sheet(item: Binding(
            get: { updates.pendingInstall?.origin == .settings ? updates.pendingInstall : nil },
            set: { if $0 == nil { updates.cancelRequest() } })
        ) { request in
            InstallConfirmSheet(updates: updates, request: request)
        }
        .modifier(PartialBackupAlert(updates: updates, origin: .settings))
        .alert(L10n.text(.updateBackupsClearConfirm), isPresented: $confirmsBackupRemoval) {
            Button(L10n.text(.actionCancel), role: .cancel) {}
            Button(L10n.text(.actionDelete), role: .destructive) { updates.removeDataBackups() }
        }
    }

    private var versionText: String {
        updates.appBuild.isEmpty ? L10n.format(.updatesVersion, updates.appVersion)
            : L10n.format(.updatesVersionBuild, updates.appVersion, updates.appBuild)
    }

    private var header: some View {
        HStack(spacing: Space.s4) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.appWindowTitle))
                    .font(TypeScale.title)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(versionText).monospacedDigit().textSelection(.enabled)
                Text(L10n.format(.topbarLastCheck, updates.lastCheck.map(SettingsFormat.lastCheck)
                                 ?? L10n.text(.updateNever)))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SymbolButton(title: L10n.text(.updateCheckNow), symbol: "arrow.clockwise") {
                updates.checkForUpdates(manual: true)
            }
            .disabled(updates.status.isBusy)
            .accessibilityIdentifier("updatesCheckNow")
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var history: some View {
        SettingsSection(title: L10n.text(.updateHistory)) {
            if updates.history.isEmpty {
                Text(L10n.text(.updateHistoryEmpty))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .padding(.vertical, Space.s3)
            } else {
                ForEach(Array(updates.history.enumerated()), id: \.element.tag) { index, release in
                    if index > 0 { SettingsDivider() }
                    VersionRow(updates: updates, release: release)
                }
            }
            SettingsNote(symbol: "externaldrive", text: L10n.text(.updatesBackupNote)) {
                VStack(alignment: .trailing, spacing: Space.s1) {
                    Text(L10n.format(.updateBackupsCount, String(updates.dataBackupCount)))
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .monospacedDigit()
                        .fixedSize()
                    Button(L10n.text(.updateBackupsClear)) { confirmsBackupRemoval = true }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(updates.dataBackupCount == 0)
                }
            }
            .padding(.top, Space.s1)
            .padding(.bottom, Space.s3)
        }
    }
}

/// One stable release: version (mono 13 semibold) | date + first note line | Installed / Available badge or
/// Downgrade… / Install… (small). Release notes are in the context menu and the tooltip.
struct VersionRow: View {
    @Bindable var updates: UpdateController
    let release: AppRelease

    private var notesLine: String {
        UpdateCardContent.notesItems(release.notes, limit: 1).first ?? L10n.text(.updateNotesEmpty)
    }

    var body: some View {
        let change = updates.change(to: release)
        HStack(spacing: Space.s3) {
            Text(verbatim: release.versionString)
                .font(TypeScale.monoStrong)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                if let date = release.publishedAt {
                    Text(SettingsFormat.day(date))
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .lineLimit(1)
                }
                Text(notesLine)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(release.notes.isEmpty ? notesLine : release.notes)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(change)
        }
        .padding(.vertical, Space.s1)
        .frame(minHeight: 40)
        .contextMenu {
            if let page = release.pageURL {
                Button(L10n.text(.updateReleaseNotes)) { NSWorkspace.shared.open(page) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(release.versionString)
    }

    @ViewBuilder
    private func trailing(_ change: VersionChange?) -> some View {
        switch change {
        case nil:
            TintBadge(text: L10n.text(.updatesBadgeInstalled), foreground: Palette.greenText, background: Palette.greenTint,
                      symbol: "checkmark")
        case .upgrade?:
            if release.versionString == updates.availableUpdate?.version {
                TintBadge(text: L10n.text(isDownloading ? .updatesBadgeDownloading : .updatesBadgeAvailable),
                          foreground: Palette.accentText, background: Palette.accentTint, symbol: "arrow.down.circle")
            } else {
                Button(L10n.text(.updatesInstallButton)) { updates.request(release) }
                    .controlSize(.small)
                    .disabled(!release.isInstallable || updates.status.isBusy)
            }
        case .downgrade?:
            Button { updates.request(release) } label: {
                HStack(spacing: Space.s1) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10)).accessibilityHidden(true)
                    Text(L10n.text(.updatesDowngradeButton))
                }
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(!release.isInstallable || updates.status.isBusy)
            .accessibilityIdentifier("downgrade-\(release.versionString)")
        }
    }

    private var isDownloading: Bool {
        guard updates.activeRelease == release else { return false }
        switch updates.status {
        case .downloading, .verifying: return true
        default: return false
        }
    }
}

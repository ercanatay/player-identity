import AppKit
import SwiftUI

// MARK: - §61 Profile picker (main window toolbar)

/// Toolbar menu: the profiles (the active one checked) and "Manage Profiles…" (opens Settings > General > Data).
/// A refused switch (game running, data operation) is shown as an alert; nothing changes.
struct ProfilePickerMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var error: ProfileError?

    var body: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Button {
                    error = model.activateProfile(profile.id)
                } label: {
                    if profile.id == model.activeProfile.id {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: profile.name)
                    }
                }
                .accessibilityIdentifier("profilePickerItem")
            }
            if model.isGameRunning {
                Divider()
                Text(L10n.text(.profilesGameRunningNote))
            }
            Divider()
            Button(L10n.text(.profilesManage)) { openSettings() }
                .accessibilityIdentifier("profilePickerManage")
        } label: {
            ProfilePickerLabel(name: model.activeProfile.name)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(model.isDataOperationRunning)
        .help(L10n.text(.profilesPickerHelp))
        .accessibilityLabel(L10n.format(.profilesPicker, model.activeProfile.name))
        .accessibilityIdentifier("toolbarProfilePicker")
        .alert(L10n.text(.profilesErrorTitle), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text(.actionOK)) { error = nil }
        } message: {
            Text(verbatim: error?.text ?? "")
        }
    }
}

/// Person symbol + active profile name (truncated at 160 pt).
struct ProfilePickerLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: Space.s1) {
            Image(systemName: "person.crop.circle")
                .accessibilityHidden(true)
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
                .fixedSize()
        }
    }
}

// MARK: - §61 Settings > General > Data: profile list

/// Profile list: name with Active / Default badges, data root and gamedir; per-row actions (Activate, Rename…,
/// Make Default, Delete…) and "Add Profile…". Deleting asks first and cannot be undone.
struct ProfilesSettingsRows: View {
    @Bindable var model: AppModel
    @State private var editor: ProfileEditorSheet.Mode?
    @State private var pendingDelete: Profile?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsActionRow(title: L10n.text(.profilesTitle), caption: L10n.text(.profilesCaption)) {
                SymbolButton(title: L10n.text(.profilesAdd), symbol: "plus") { editor = .add }
                    .disabled(model.isDataOperationRunning)
                    .accessibilityIdentifier("profilesAdd")
            }
            ForEach(model.profiles) { profile in
                SettingsDivider(indent: 20)
                ProfileRow(model: model, profile: profile,
                           onActivate: { report(model.activateProfile(profile.id)) },
                           onRename: { editor = .rename(profile) },
                           onMakeDefault: { report(model.makeDefaultProfile(profile.id)) },
                           onDelete: { pendingDelete = profile })
            }
            if model.isGameRunning {
                SettingsMessage(text: L10n.text(.profilesGameRunningNote))
                    .padding(.vertical, Space.s2)
                    .accessibilityIdentifier("profilesGameRunning")
            }
            if let message {
                SettingsMessage(text: message, isError: true)
                    .padding(.bottom, Space.s2)
                    .accessibilityIdentifier("profilesMessage")
            }
        }
        .sheet(item: $editor) { mode in
            ProfileEditorSheet(model: model, mode: mode) { editor = nil }
        }
        .sheet(item: $pendingDelete) { profile in
            DestructiveConfirmSheet(
                title: L10n.format(.profilesDeleteTitle, profile.name),
                message: profile.id == model.activeProfile.id
                    ? L10n.text(.profilesDeleteMessage) + " " + L10n.text(.profilesDeleteActiveNote)
                    : L10n.text(.profilesDeleteMessage),
                confirmTitle: L10n.text(.actionDelete), checkbox: .constant(false),
                onCancel: { pendingDelete = nil },
                onConfirm: {
                    pendingDelete = nil
                    report(model.deleteProfile(profile.id))
                })
        }
    }

    private func report(_ error: ProfileError?) {
        message = error?.text
    }
}

/// One profile: name + badges, `data root · gamedir` (mono, abbreviated), the actions menu.
struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: Profile
    let onActivate: () -> Void
    let onRename: () -> Void
    let onMakeDefault: () -> Void
    let onDelete: () -> Void

    private var isActive: Bool { profile.id == model.activeProfile.id }
    private var isDefault: Bool { profile.id == model.defaultProfileID }

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.system(size: 14))
                .foregroundStyle(isActive ? Palette.accentFill : Palette.text2)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s1) {
                    Text(verbatim: profile.name)
                        .font(TypeScale.body)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    if isActive {
                        TintBadge(text: L10n.text(.profilesActive), foreground: Palette.greenText, background: Palette.greenTint)
                    }
                    if isDefault {
                        TintBadge(text: L10n.text(.profilesDefault), foreground: Palette.text2, background: Palette.inset)
                    }
                }
                Text(verbatim: ProfileText.location(profile, model: model))
                    .font(TypeScale.mono)
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button(L10n.text(.profilesActivate), action: onActivate).disabled(isActive)
                Button(L10n.text(.profilesRename), action: onRename)
                Button(L10n.text(.profilesMakeDefault), action: onMakeDefault).disabled(isDefault)
                Divider()
                Button(L10n.text(.profilesDelete), role: .destructive, action: onDelete).disabled(model.profiles.count < 2)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isDataOperationRunning)
            .accessibilityLabel(L10n.text(.profilesActions))
            .accessibilityIdentifier("profileActions")
        }
        .padding(.vertical, Space.s2)
        .padding(.leading, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profileRow")
    }
}

/// Texts of a profile row.
@MainActor
enum ProfileText {
    /// `~/…/Xash3D FWGS · valve` (default data root and automatic gamedir spelled out).
    static func location(_ profile: Profile, model: AppModel) -> String {
        let root = profile.dataRoot.map { SettingsFormat.abbreviated($0, home: model.homeDirectory) }
            ?? L10n.text(.profilesDataRootDefault)
        let gamedir = profile.gamedir.isEmpty ? L10n.text(.profilesGamedirAuto) : profile.gamedir
        return root + " · " + gamedir
    }
}

/// Add (name + data root + gamedir) or rename (name only) sheet. A refused change stays in the sheet with its reason.
struct ProfileEditorSheet: View {
    enum Mode: Identifiable {
        case add
        case rename(Profile)

        var id: String {
            switch self {
            case .add: return "add"
            case .rename(let profile): return profile.id.uuidString
            }
        }
    }

    @Bindable var model: AppModel
    let mode: Mode
    let onClose: () -> Void

    @State private var name: String
    @State private var dataRoot: URL?
    @State private var gamedir = ""
    @State private var error: ProfileError?

    init(model: AppModel, mode: Mode, onClose: @escaping () -> Void) {
        self.model = model
        self.mode = mode
        self.onClose = onClose
        if case .rename(let profile) = mode {
            _name = State(initialValue: profile.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    private var isAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(isAdd ? .profilesAddTitle : .profilesRenameTitle)).font(TypeScale.headline)
            Form {
                TextField(L10n.text(.profilesFieldName), text: $name)
                    .accessibilityIdentifier("profileName")
                if isAdd {
                    LabeledContent(L10n.text(.profileDataRoot)) {
                        HStack(spacing: Space.s2) {
                            Text(verbatim: dataRoot.map { SettingsFormat.abbreviated($0.path, home: model.homeDirectory) }
                                 ?? L10n.text(.profilesDataRootDefault))
                                .font(TypeScale.mono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(L10n.text(.profileChooseFolder), action: chooseFolder)
                                .accessibilityIdentifier("profileChooseDataRoot")
                            if dataRoot != nil {
                                Button(L10n.text(.profilesDataRootReset)) { dataRoot = nil }
                            }
                        }
                    }
                    TextField(L10n.text(.profileGamedir), text: $gamedir, prompt: Text(L10n.text(.profilesGamedirPlaceholder)))
                        .accessibilityIdentifier("profileGamedir")
                }
            }
            if let error {
                Label(error.text, systemImage: StatusLevel.red.symbolName)
                    .foregroundStyle(Palette.redText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profileEditorError")
            }
            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(isAdd ? .actionAdd : .actionSave), action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("profileEditorConfirm")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func confirm() {
        switch mode {
        case .add: error = model.addProfile(name: name, dataRoot: dataRoot, gamedir: gamedir)
        case .rename(let profile): error = model.renameProfile(profile.id, to: name)
        }
        if error == nil { onClose() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = dataRoot ?? model.defaultDataRoot
        panel.prompt = L10n.text(.profilePanelPrompt)
        panel.message = L10n.text(.profilePanelMessage)
        if panel.runModal() == .OK, let url = panel.url { dataRoot = url.standardizedFileURL }
    }
}

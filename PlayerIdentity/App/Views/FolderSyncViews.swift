import AppKit
import SwiftUI

/// §71 Settings > Data > "Sync Folder": the chosen folder, Choose / Remove / Sync Now, the last result and the
/// "file is not encrypted" warning (§71.3).
struct SyncFolderSettingsRows: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            SettingsActionRow(title: L10n.text(.syncFolderTitle), caption: L10n.text(.syncFolderCaption)) {
                if model.isSyncing { ProgressView().controlSize(.small) }
                if model.syncFolder != nil {
                    SymbolButton(title: L10n.text(.syncNow), symbol: "arrow.triangle.2.circlepath") { model.syncNow() }
                        .disabled(model.isSyncing || model.isDataOperationRunning)
                        .accessibilityIdentifier("syncNow")
                    Button(L10n.text(.syncRemove)) { model.removeSyncFolder() }
                        .fixedSize()
                        .help(L10n.text(.syncRemoveHint))
                        .accessibilityIdentifier("syncRemove")
                }
                Button(L10n.text(.syncChoose)) { SyncFolderPanel.choose(model) }
                    .fixedSize()
                    .accessibilityIdentifier("syncChoose")
            }
            folderField
            if let error = model.syncError {
                SettingsMessage(text: error.text, isError: true)
                    .accessibilityIdentifier("syncError")
            } else if model.syncFolder != nil {
                SettingsMessage(text: statusText)
                    .accessibilityIdentifier("syncStatus")
            }
            SettingsNote(symbol: "lock.open", text: L10n.text(.syncUnencrypted))
                .padding(.bottom, Space.s2)
                .accessibilityIdentifier("syncUnencrypted")
        }
    }

    private var folderField: some View {
        let path = model.syncFolder?.path
        return HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .accessibilityHidden(true)
            Group {
                if let path {
                    Text(verbatim: SettingsFormat.abbreviated(path, home: model.homeDirectory))
                        .font(TypeScale.mono)
                        .middleTruncated(path)
                } else {
                    Text(L10n.text(.syncFolderNone))
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.s2)
        .frame(height: Metrics.control)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text(.syncFolderTitle))
        .accessibilityValue(path ?? L10n.text(.syncFolderNone))
        .accessibilityIdentifier("syncFolderPath")
    }

    private var statusText: String {
        if model.isSyncing { return L10n.text(.syncRunning) }
        guard let date = model.syncLastSuccess else { return L10n.text(.syncNever) }
        var text = L10n.format(.syncLast, SettingsFormat.lastCheck(date))
        if model.syncConflictCount > 0 {
            text += " · " + L10n.format(.syncConflicts, String(model.syncConflictCount))
        }
        return text
    }
}

/// Folder panel of the sync folder (may create a folder, e.g. in iCloud Drive).
enum SyncFolderPanel {
    @MainActor
    static func choose(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.syncFolder
        panel.prompt = L10n.text(.syncPanelPrompt)
        panel.message = L10n.text(.syncPanelMessage)
        if panel.runModal() == .OK, let url = panel.url {
            model.setSyncFolder(url)
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §46 Settings > General > "Data": Export… and Import… with their sheets.
struct DataSettingsRow: View {
    @Bindable var model: AppModel
    @State private var showsExport = false
    @State private var candidate: ImportCandidate?
    @State private var errorText: String?

    struct ImportCandidate: Identifiable {
        let id = UUID()
        let fileName: String
        let parsed: ParsedSettingsArchive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(.dataSectionTitle)).font(.headline)
            HStack {
                Button(L10n.text(.dataExport)) { showsExport = true }
                    .accessibilityIdentifier("dataExport")
                Button(L10n.text(.dataImport), action: chooseFile)
                    .accessibilityIdentifier("dataImport")
            }
            Text(L10n.text(.dataNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("importError")
            }
        }
        .sheet(isPresented: $showsExport) {
            SettingsExportSheet(model: model) { showsExport = false }
        }
        .sheet(item: $candidate) { item in
            SettingsImportSheet(model: model, candidate: item) { candidate = nil }
        }
    }

    private func chooseFile() {
        errorText = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch SettingsArchiveParser.read(url) {
        case .success(let parsed):
            candidate = ImportCandidate(fileName: url.lastPathComponent, parsed: parsed)
        case .failure(let error):
            errorText = error.text
        }
    }
}

struct SettingsExportSheet: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    @State private var scope = SettingsArchiveScope.settingsAndServers
    @State private var includeDataRoot = false
    @State private var message: String?
    @State private var isError = false
    @State private var isDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(.exportTitle)).font(.title3.bold())
            Picker(L10n.text(.exportScope), selection: $scope) {
                Text(L10n.text(.exportScopeSettings)).tag(SettingsArchiveScope.settingsOnly)
                Text(L10n.text(.exportScopeServers)).tag(SettingsArchiveScope.settingsAndServers)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("exportScope")
            Toggle(L10n.text(.exportIncludeDataRoot), isOn: $includeDataRoot)
                .accessibilityIdentifier("exportIncludeDataRoot")
            Text(L10n.text(.exportDataRootNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text(.dataNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(isDone ? L10n.text(.actionClose) : L10n.text(.actionCancel), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.exportAction), action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDone)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SettingsArchive.defaultFileName(now: model.now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try model.settingsArchive(scope: scope, includeDataRoot: includeDataRoot).encoded()
            try data.write(to: url, options: .atomic)
            message = L10n.format(.exportSaved, url.path)
            isError = false
            isDone = true
        } catch {
            message = L10n.format(.exportFailed, error.localizedDescription)
            isError = true
        }
    }
}

struct SettingsImportSheet: View {
    @Bindable var model: AppModel
    let candidate: DataSettingsRow.ImportCandidate
    let onClose: () -> Void

    @State private var mode = SettingsImportMode.merge
    @State private var includeDataRoot = false
    @State private var summary: SettingsImportSummary?
    @State private var errorText: String?

    init(model: AppModel, candidate: DataSettingsRow.ImportCandidate, initialSummary: SettingsImportSummary? = nil,
         onClose: @escaping () -> Void) {
        self.model = model
        self.candidate = candidate
        self.onClose = onClose
        _summary = State(initialValue: initialSummary)
    }

    private var preview: SettingsImportPreview {
        model.importPreview(candidate.parsed, includeDataRoot: includeDataRoot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(.importTitle)).font(.title3.bold())
            Text(L10n.format(.importFile, candidate.fileName))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let summary {
                resultView(summary)
            } else {
                previewView
            }
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("importFailure")
            }
            HStack {
                Spacer()
                Button(summary == nil ? L10n.text(.actionCancel) : L10n.text(.actionClose), action: onClose)
                    .keyboardShortcut(.cancelAction)
                if summary == nil {
                    Button(L10n.text(.importAction), action: apply)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("importApply")
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var previewView: some View {
        let stats = preview
        return VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(.importPreview)).font(.headline)
                    Text(L10n.format(.importSettingsCount, String(stats.settingCount)))
                    if stats.hasServers {
                        Text(L10n.format(.importServersCount, String(stats.serverCount)))
                        Text(L10n.format(.importConflicts, String(stats.conflictCount)))
                    } else {
                        Text(L10n.text(.importNoServers)).foregroundStyle(.secondary)
                    }
                    Text(L10n.format(.importInvalid, String(stats.invalidCount)))
                        .foregroundStyle(stats.invalidCount > 0 ? Color.orange : Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .accessibilityIdentifier("importPreview")
            }
            if stats.hasServers {
                Picker(L10n.text(.importMode), selection: $mode) {
                    Text(L10n.text(.importModeMerge)).tag(SettingsImportMode.merge)
                    Text(L10n.text(.importModeReplace)).tag(SettingsImportMode.replace)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("importMode")
                Text(mode == .merge ? L10n.text(.importModeMergeNote) : L10n.text(.importModeReplaceNote))
                    .font(.caption)
                    .foregroundStyle(mode == .merge ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if candidate.parsed.hasDataRoot {
                Toggle(L10n.text(.importIncludeDataRoot), isOn: $includeDataRoot)
                    .accessibilityIdentifier("importIncludeDataRoot")
            }
        }
    }

    private func resultView(_ result: SettingsImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(.importDone)).font(.headline)
            Text(L10n.format(.importSettingsApplied, String(result.settingsApplied)))
            Text(L10n.format(.importSummary, String(result.added), String(result.updated), String(result.skipped)))
                .accessibilityIdentifier("importSummary")
            if let backup = result.backupFile {
                Text(L10n.format(.importBackupFile, backup.lastPathComponent)).foregroundStyle(.secondary)
            }
            Text(L10n.text(.importUnsavedNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apply() {
        switch model.importSettings(candidate.parsed, mode: mode, includeDataRoot: includeDataRoot) {
        case .success(let result):
            summary = result
            errorText = nil
        case .failure(let error):
            errorText = error.text
        }
    }
}

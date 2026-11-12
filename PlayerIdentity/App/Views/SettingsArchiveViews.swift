import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §46 Settings > General > Data > "Settings transfer": Import… and Export… with their sheets (Claude Design S12–S13).
struct DataSettingsRow: View {
    @Bindable var model: AppModel
    @State private var showsExport = false
    @State private var candidate: ImportCandidate?
    @State private var errorText: String?

    struct ImportCandidate: Identifiable {
        let id = UUID()
        let fileName: String
        /// File size in bytes (shown in the import sheet).
        var fileSize: Int?
        let parsed: ParsedSettingsArchive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            SettingsActionRow(title: L10n.text(.settingsTransfer), caption: L10n.text(.dataNote)) {
                SymbolButton(title: L10n.text(.dataImport), symbol: "square.and.arrow.down", action: chooseFile)
                    .accessibilityIdentifier("dataImport")
                SymbolButton(title: L10n.text(.dataExport), symbol: "square.and.arrow.up") { showsExport = true }
                    .accessibilityIdentifier("dataExport")
            }
            if let errorText {
                SettingsMessage(text: errorText, isError: true)
                    .padding(.bottom, Space.s2)
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
        switch SettingsImportPicker.choose() {
        case .chosen(let item): candidate = item
        case .failed(let text): errorText = text
        case .cancelled: break
        }
    }
}

/// NSOpenPanel + parse for an import file.
enum SettingsImportPicker {
    enum Outcome {
        case chosen(DataSettingsRow.ImportCandidate)
        case failed(String)
        case cancelled
    }

    @MainActor
    static func choose() -> Outcome {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return load(url)
    }

    static func load(_ url: URL) -> Outcome {
        switch SettingsArchiveParser.read(url) {
        case .success(let parsed):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return .chosen(DataSettingsRow.ImportCandidate(fileName: url.lastPathComponent, fileSize: size, parsed: parsed))
        case .failure(let error):
            return .failed(error.text)
        }
    }
}

/// NSSavePanel + write for an export (shared by the export sheet and "Export settings first").
enum SettingsExportWriter {
    enum Outcome: Equatable {
        case saved(URL)
        case cancelled
        case failed(String)
    }

    @MainActor
    static func save(model: AppModel, scope: SettingsArchiveScope, includeDataRoot: Bool) -> Outcome {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SettingsArchive.defaultFileName(now: model.now)
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return write(model: model, scope: scope, includeDataRoot: includeDataRoot, to: url)
    }

    @MainActor
    static func write(model: AppModel, scope: SettingsArchiveScope, includeDataRoot: Bool, to url: URL) -> Outcome {
        do {
            let data = try model.settingsArchive(scope: scope, includeDataRoot: includeDataRoot).encoded()
            try data.write(to: url, options: .atomic)
            return .saved(url)
        } catch {
            return .failed(L10n.format(.exportFailed, error.localizedDescription))
        }
    }
}

/// Export sheet (460 wide): what to include as checkbox rows in an inset box — preferences (always), server list,
/// data root, identity history (never exported, with the reason) — then the file name and Cancel / Export….
struct SettingsExportSheet: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    @State private var includeServers = true
    @State private var includeDataRoot = false
    @State private var message: String?
    @State private var isError = false
    @State private var isDone = false

    /// `initialResult` shows a finished export (evidence renders); normally `nil`.
    init(model: AppModel, initialResult: SettingsExportWriter.Outcome? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        switch initialResult {
        case .saved(let url):
            _message = State(initialValue: L10n.format(.exportSaved, url.path))
            _isDone = State(initialValue: true)
        case .failed(let text):
            _message = State(initialValue: text)
            _isError = State(initialValue: true)
        case .cancelled, nil:
            break
        }
    }

    private var scope: SettingsArchiveScope { includeServers ? .settingsAndServers : .settingsOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(L10n.text(.exportTitle)).font(TypeScale.headline).accessibilityAddTraits(.isHeader)
                Text(L10n.text(.exportBody))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ExportOptionRow(title: L10n.text(.exportRowPreferences),
                                caption: L10n.format(.exportRowPreferencesCaption,
                                                     String(model.currentArchivedSettings().count(includingDataRoot: false))),
                                isOn: .constant(true))
                    .disabled(true)
                SettingsDivider()
                ExportOptionRow(title: L10n.text(.exportRowServers),
                                caption: L10n.format(.exportRowServersCaption, String(model.servers.count),
                                                     String(model.serverSections().count)),
                                isOn: $includeServers)
                    .accessibilityIdentifier("exportScope")
                SettingsDivider()
                ExportOptionRow(title: L10n.text(.exportIncludeDataRoot), caption: L10n.text(.exportDataRootNote),
                                isOn: $includeDataRoot)
                    .accessibilityIdentifier("exportIncludeDataRoot")
                SettingsDivider()
                ExportOptionRow(title: L10n.text(.exportRowHistory), caption: L10n.text(.exportRowHistoryCaption),
                                isOn: .constant(false), warning: true)
                    .disabled(true)
            }
            .padding(.vertical, Space.s1)
            .padding(.horizontal, Space.s3)
            .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
            .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
            HStack(spacing: Space.s2) {
                Text(L10n.text(.exportFileLabel)).font(TypeScale.callout).foregroundStyle(Palette.text2)
                let file = SettingsArchive.defaultFileName(now: model.now)
                Text(verbatim: file).font(TypeScale.monoSmall).middleTruncated(file)
            }
            if let message {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? Palette.red : Palette.green)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(TypeScale.callout)
                        .foregroundStyle(isError ? Palette.redText : Palette.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("exportMessage")
            }
            HStack(spacing: Space.s2) {
                Spacer()
                Button(isDone ? L10n.text(.actionClose) : L10n.text(.actionCancel), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.dataExport), action: export)
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDone)
                    .accessibilityIdentifier("exportAction")
            }
        }
        .font(TypeScale.body)
        .foregroundStyle(Palette.text)
        .padding(20)
        .frame(width: 460)
        .background(Palette.raised)
    }

    private func export() {
        switch SettingsExportWriter.save(model: model, scope: scope, includeDataRoot: includeDataRoot) {
        case .saved(let url):
            message = L10n.format(.exportSaved, url.path)
            isError = false
            isDone = true
        case .failed(let text):
            message = text
            isError = true
        case .cancelled:
            break
        }
    }
}

/// Checkbox + title + caption (orange with a warning symbol when `warning`).
private struct ExportOptionRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var warning = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(TypeScale.body).foregroundStyle(Palette.text)
                HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                    if warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.orange)
                            .accessibilityHidden(true)
                    }
                    Text(caption)
                        .font(TypeScale.callout)
                        .foregroundStyle(warning ? Palette.orangeText : Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
        }
        .toggleStyle(.checkbox)
        .tint(Palette.accentFill)
        .padding(.vertical, Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Import sheet (480 wide): the chosen file (name, origin version, date, size, Choose…), a per-category summary of
/// what would change, the merge/replace mode, the backup note, then Cancel / Import. After importing, the result.
struct SettingsImportSheet: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    @State private var candidate: DataSettingsRow.ImportCandidate
    @State private var mode = SettingsImportMode.merge
    @State private var includeDataRoot = false
    @State private var summary: SettingsImportSummary?
    @State private var errorText: String?

    init(model: AppModel, candidate: DataSettingsRow.ImportCandidate, initialSummary: SettingsImportSummary? = nil,
         onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _candidate = State(initialValue: candidate)
        _summary = State(initialValue: initialSummary)
    }

    /// A restore, an erase or an update runs: importing is refused (the reason is shown above the buttons).
    private var isBlocked: Bool { model.isDataOperationRunning || model.updates.status.isUpdating }

    private var preview: SettingsImportPreview {
        model.importPreview(candidate.parsed, includeDataRoot: includeDataRoot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(L10n.text(.importTitle)).font(TypeScale.headline).accessibilityAddTraits(.isHeader)
                Text(L10n.text(.importBody))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fileBox
            if let summary {
                resultView(summary)
            } else {
                previewTable
                modeAndNote
            }
            if let message = errorText ?? (summary == nil && isBlocked ? SettingsImportError.busy.text : nil) {
                Text(message)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.redText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("importFailure")
            }
            HStack(spacing: Space.s2) {
                Spacer()
                Button(summary == nil ? L10n.text(.actionCancel) : L10n.text(.actionClose), action: onClose)
                    .keyboardShortcut(.cancelAction)
                if summary == nil {
                    Button(L10n.text(.importAction), action: apply)
                        .prominentButton()
                        .disabled(isBlocked)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("importApply")
                }
            }
        }
        .font(TypeScale.body)
        .foregroundStyle(Palette.text)
        .padding(20)
        .frame(width: 480)
        .background(Palette.raised)
    }

    private var fileBox: some View {
        let archive = candidate.parsed.archive
        let meta = L10n.format(.importMeta, archive.appVersion, SettingsFormat.day(archive.exportedAt),
                               candidate.fileSize.map(SettingsFormat.size) ?? "—")
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 16))
                .foregroundStyle(Palette.text2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: candidate.fileName).font(TypeScale.monoSmall).middleTruncated(candidate.fileName)
                Text(meta).font(TypeScale.callout).foregroundStyle(Palette.text2).lineLimit(1).help(meta)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if summary == nil {
                Button(L10n.text(.importChooseOther), action: chooseOther)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var previewTable: some View {
        let stats = preview
        let settings = candidate.parsed.archive.settings
        let differ = settings.differences(from: model.currentArchivedSettings(), includingDataRoot: includeDataRoot)
        return VStack(alignment: .leading, spacing: 0) {
            ImportSummaryRow(symbol: differ > 0 ? "arrow.clockwise" : "checkmark",
                             color: differ > 0 ? Palette.orange : Palette.text2,
                             title: L10n.text(.exportRowPreferences),
                             value: L10n.format(.importRowPreferencesValue, String(stats.settingCount), String(differ)))
            SettingsDivider()
            if stats.hasServers {
                let added = max(0, stats.serverCount - stats.conflictCount)
                ImportSummaryRow(symbol: added > 0 ? "plus" : "checkmark",
                                 color: added > 0 ? Palette.accentText : Palette.text2,
                                 title: L10n.text(.importRowServers),
                                 value: L10n.format(.importRowServersValue, String(stats.serverCount), String(added),
                                                    String(stats.conflictCount)))
            } else {
                ImportSummaryRow(symbol: "xmark", color: Palette.text3, title: L10n.text(.importRowServers),
                                 value: L10n.text(.importNotInFile))
            }
            if candidate.parsed.hasDataRoot, let root = settings.dataRoot {
                SettingsDivider()
                HStack(spacing: 10) {
                    Toggle(L10n.text(.importIncludeDataRoot), isOn: $includeDataRoot)
                        .toggleStyle(.checkbox)
                        .tint(Palette.accentFill)
                        .fixedSize()
                        .accessibilityIdentifier("importIncludeDataRoot")
                    Text(verbatim: SettingsFormat.abbreviated(root, home: model.homeDirectory))
                        .font(TypeScale.monoSmall)
                        .foregroundStyle(Palette.text2)
                        .middleTruncated(root)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(minHeight: 32)
            }
            if stats.dataRootInvalid {
                SettingsDivider()
                ImportSummaryRow(symbol: "exclamationmark.triangle.fill", color: Palette.orange,
                                 title: L10n.text(.profileDataRoot),
                                 value: L10n.text(.importDataRootInvalidPreview))
            }
            if stats.invalidCount > 0 {
                SettingsDivider()
                ImportSummaryRow(symbol: "exclamationmark.triangle.fill", color: Palette.orange,
                                 title: L10n.text(.importRowInvalid),
                                 value: L10n.format(.importRowInvalidValue, String(stats.invalidCount)))
            }
            SettingsDivider()
            ImportSummaryRow(symbol: "xmark", color: Palette.text3, title: L10n.text(.importRowHistory),
                             value: L10n.text(.importNotInFile))
        }
        .padding(.horizontal, Space.s3)
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importPreview")
    }

    @ViewBuilder
    private var modeAndNote: some View {
        if preview.hasServers {
            HStack(spacing: Space.s3) {
                Text(L10n.text(.importModeLabel)).frame(maxWidth: .infinity, alignment: .leading)
                Picker(L10n.text(.importMode), selection: $mode) {
                    Text(L10n.text(.importModeMerge)).tag(SettingsImportMode.merge)
                    Text(L10n.text(.importModeReplace)).tag(SettingsImportMode.replace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L10n.text(.importModeLabel))
                .accessibilityIdentifier("importMode")
            }
            HStack(alignment: .top, spacing: Space.s2) {
                Image(systemName: mode == .merge ? "externaldrive" : StatusLevel.orange.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(mode == .merge ? Palette.text2 : Palette.orange)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(mode == .merge ? L10n.text(.importModeMergeNote) : L10n.text(.importModeReplaceNote))
                    .font(TypeScale.callout)
                    .foregroundStyle(mode == .merge ? Palette.text2 : Palette.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func resultView(_ result: SettingsImportSummary) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Palette.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(L10n.text(.importDone)).font(TypeScale.label)
                ForEach(Self.settingsLines(result, home: model.homeDirectory), id: \.self) { line in
                    Text(line).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.format(.importSummary, String(result.added), String(result.updated), String(result.skipped)))
                    .monospacedDigit()
                    .accessibilityIdentifier("importSummary")
                if let backup = result.backupFile {
                    Text(L10n.format(.importBackupFile, backup.lastPathComponent))
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .middleTruncated(backup.path)
                }
                Text(L10n.text(.importUnsavedNote))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// Result lines about the settings: applied, skipped, invalid, then the side effects (data root, launch at login).
    static func settingsLines(_ result: SettingsImportSummary, home: URL? = nil) -> [String] {
        var lines = [L10n.format(.importSettingsApplied, String(result.settingsApplied))]
        if result.settingsSkipped > 0 { lines.append(L10n.format(.importSettingsSkipped, String(result.settingsSkipped))) }
        if result.invalidSettings > 0 { lines.append(L10n.format(.importSettingsInvalid, String(result.invalidSettings))) }
        if let root = result.dataRootChanged {
            lines.append(L10n.format(.importDataRootChanged, SettingsFormat.abbreviated(root, home: home)))
        }
        if let root = result.dataRootRejected {
            lines.append(L10n.format(.importDataRootRejected, SettingsFormat.abbreviated(root, home: home)))
        }
        switch result.launchAtLoginChanged {
        case true?: lines.append(L10n.text(.importLaunchAtLoginOn))
        case false?: lines.append(L10n.text(.importLaunchAtLoginOff))
        case nil: break
        }
        return lines
    }

    private func chooseOther() {
        switch SettingsImportPicker.choose() {
        case .chosen(let item):
            candidate = item
            includeDataRoot = false
            errorText = nil
        case .failed(let text):
            errorText = text
        case .cancelled:
            break
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

/// Import summary row: symbol 14 | category | value (12 secondary). Min height 32.
private struct ImportSummaryRow: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.tail).help(title)
            Spacer(minLength: Space.s2)
            Text(value)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }
}

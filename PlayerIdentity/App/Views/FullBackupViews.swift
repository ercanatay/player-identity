import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §49 Settings > General > Data: "Back Up All Data…", "Restore from Backup…" and the "Automatic backups" switch.
struct FullBackupSettingsRows: View {
    @Bindable var model: AppModel
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false
    @State private var candidate: FullRestoreCandidate?

    /// `initialMessage` shows a finished backup or an error (evidence renders); normally `nil`.
    init(model: AppModel, initialMessage: String? = nil, initialIsError: Bool = false) {
        self.model = model
        _message = State(initialValue: initialMessage)
        _isError = State(initialValue: initialIsError)
    }

    private var isLocked: Bool { isWorking || model.isDataOperationRunning || model.updates.status.isUpdating }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            SettingsActionRow(title: L10n.text(.fullBackupTitle), caption: L10n.text(.fullBackupCaption)) {
                if isWorking { ProgressView().controlSize(.small) }
                SymbolButton(title: L10n.text(.fullBackupCreate), symbol: "archivebox", action: backUp)
                    .disabled(isLocked)
                    .accessibilityIdentifier("fullBackupCreate")
                SymbolButton(title: L10n.text(.fullBackupRestore), symbol: "clock.arrow.circlepath", action: chooseRestore)
                    .disabled(isLocked)
                    .accessibilityIdentifier("fullBackupRestore")
            }
            if let message {
                SettingsMessage(text: message, isError: isError)
                    .padding(.bottom, Space.s2)
                    .accessibilityIdentifier("fullBackupMessage")
            }
        }
        .sheet(item: $candidate) { item in
            FullRestoreSheet(model: model, candidate: item) { candidate = nil }
        }
        SettingsDivider()
        VStack(alignment: .leading, spacing: 0) {
            SettingsSwitchRow(symbol: "clock.badge.checkmark", title: L10n.text(.fullBackupAuto),
                              caption: L10n.text(.fullBackupAutoCaption), isOn: $model.autoBackupEnabled,
                              identifier: "fullBackupAuto")
            Text(lastAutomaticText)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text3)
                .padding(.leading, Space.s6 + Space.s1)
                .padding(.bottom, Space.s2)
                .accessibilityIdentifier("fullBackupAutoLast")
        }
    }

    private var lastAutomaticText: String {
        guard let date = model.latestAutomaticBackup else { return L10n.text(.fullBackupAutoNone) }
        return L10n.format(.fullBackupAutoLast, SettingsFormat.lastCheck(date))
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = FullBackupNaming.manualFileName(now: model.now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task {
            let result = await model.writeFullBackup(to: url)
            (message, isError) = FullBackupText.result(result, url: url)
            isWorking = false
        }
    }

    private func chooseRestore() {
        message = nil
        switch FullBackupPicker.choose() {
        case .chosen(let item): candidate = item
        case .failed(let text):
            message = text
            isError = true
        case .cancelled: break
        }
    }
}

/// Result texts of the manual backup.
enum FullBackupText {
    /// An incomplete backup is shown as an error: "N files skipped, this backup is incomplete" and dropped lines.
    static func result(_ result: Result<FullBackupManifest, FullBackupError>, url: URL) -> (String, Bool) {
        switch result {
        case .success(let manifest):
            let counts = manifest.counts
            let summary = L10n.format(.fullBackupSummary, String(counts.servers), String(counts.historyEntries),
                                      String(counts.metricSamples))
            let lines = [L10n.format(.fullBackupSaved, url.path), summary] + warnings(manifest)
            return (lines.joined(separator: "\n"), !manifest.warnings.isEmpty)
        case .failure(.nothingToBackUp):
            return (L10n.text(.backupNothing), true)
        case .failure(.writeFailed(let reason)):
            return (L10n.format(.fullBackupFailed, reason), true)
        case .failure(let error):
            return (L10n.format(.fullBackupFailed, error.text), true)
        }
    }

    /// Warning lines of a backup that could not include everything (empty when it is complete).
    static func warnings(_ manifest: FullBackupManifest) -> [String] {
        var lines: [String] = []
        let missing = manifest.missingFiles
        if !missing.isEmpty {
            lines.append(L10n.format(.fullBackupSkipped, String(missing.count), missing.joined(separator: ", ")))
        }
        for skipped in manifest.warnings where !skipped.isMissingFromBackup {
            lines.append(L10n.format(.fullBackupDroppedLines, skipped.file, String(skipped.lines ?? 0)))
        }
        return lines
    }

    /// Confirmation text of a restore: the backup date and servers, then the warnings (files the backup leaves out
    /// whose current versions are removed; unsaved changes that are lost unless saved first).
    static func restoreConfirmation(_ preview: FullBackupPreview, hasUnsavedChanges: Bool) -> String {
        var parts = [L10n.format(.fullRestoreConfirmBody, SettingsFormat.lastCheck(preview.createdAt),
                                 String(preview.counts.servers))]
        if !preview.missingFiles.isEmpty {
            parts.append(L10n.format(.fullRestoreMissingNote, preview.missingFiles.joined(separator: ", ")))
        }
        if hasUnsavedChanges { parts.append(L10n.text(.fullRestoreUnsavedNote)) }
        return parts.joined(separator: "\n\n")
    }

    /// Result lines of a failed restore: the error, then whether the current data is unchanged or where the copy
    /// of the previous files is.
    static func failureLines(_ error: FullBackupError) -> [String] {
        [error.text, L10n.text(error.keptCurrentData ? .fullRestoreKept : .fullRestoreCheckData)]
    }
}

/// A validated backup chosen for a restore.
struct FullRestoreCandidate: Identifiable {
    let id = UUID()
    let fileName: String
    var fileSize: Int?
    let backup: ParsedFullBackup
}

/// NSOpenPanel + validation for a restore file. Nothing is written until the user confirms.
enum FullBackupPicker {
    enum Outcome {
        case chosen(FullRestoreCandidate)
        case failed(String)
        case cancelled
    }

    @MainActor
    static func choose() -> Outcome {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return load(url)
    }

    static func load(_ url: URL) -> Outcome {
        switch FullBackupParser.read(url) {
        case .success(let backup):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return .chosen(FullRestoreCandidate(fileName: url.lastPathComponent, fileSize: size, backup: backup))
        case .failure(let error):
            return .failed(error.text)
        }
    }
}

/// Restore sheet (480 wide): preview (file, dates, counts, version) → confirmation → working → result or error.
struct FullRestoreSheet: View {
    enum Phase: Equatable {
        case preview
        case confirm
        case working
        /// Pre-restore backup and the folder with previous files that could not be backed up.
        case done(URL?, kept: URL? = nil)
        case failed(FullBackupError)
    }

    @Bindable var model: AppModel
    let candidate: FullRestoreCandidate
    let onClose: () -> Void
    @State private var phase: Phase
    /// "Save first" in the confirmation (shown only with unsaved changes; on by default).
    @State private var saveFirst = true

    init(model: AppModel, candidate: FullRestoreCandidate, initialPhase: Phase = .preview, onClose: @escaping () -> Void) {
        self.model = model
        self.candidate = candidate
        self.onClose = onClose
        _phase = State(initialValue: initialPhase)
    }

    private var preview: FullBackupPreview { model.fullBackupPreview(candidate.backup) }

    var body: some View {
        if phase == .confirm {
            let unsaved = model.hasUnsavedChanges
            DestructiveConfirmSheet(title: L10n.text(.fullRestoreConfirmTitle),
                                    message: FullBackupText.restoreConfirmation(preview, hasUnsavedChanges: unsaved),
                                    confirmTitle: L10n.text(.fullRestoreConfirmAction),
                                    checkboxTitle: unsaved ? L10n.text(.fullRestoreSaveFirst) : nil, checkbox: $saveFirst,
                                    onCancel: { phase = .preview }, onConfirm: restore)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(L10n.text(.fullRestoreTitle)).font(TypeScale.headline).accessibilityAddTraits(.isHeader)
                Text(L10n.text(.fullRestoreBody))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fileBox
            switch phase {
            case .preview, .confirm:
                previewTable
                notes
            case .working:
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text(.fullRestoreWorking)).foregroundStyle(Palette.text2)
                }
                .accessibilityElement(children: .combine)
            case .done(let safety, let kept):
                result(symbol: "checkmark.circle.fill", color: Palette.green, title: L10n.text(.fullRestoreDone),
                       lines: [safety.map { L10n.format(.fullRestoreDoneBackup, $0.lastPathComponent) }
                               ?? L10n.text(.fullRestoreDoneNoBackup)]
                           + (kept.map { [L10n.format(.fullRestoreDoneKept, $0.path)] } ?? []))
            case .failed(let error):
                result(symbol: "xmark.octagon.fill", color: Palette.red,
                       title: L10n.text(error.keptCurrentData ? .fullRestoreFailedTitle : .fullRestoreIncompleteTitle),
                       lines: FullBackupText.failureLines(error), isError: true)
            }
            buttons
        }
        .font(TypeScale.body)
        .foregroundStyle(Palette.text)
        .padding(Space.s6)
        .frame(width: Metrics.backupSheet)
        .background(Palette.raised)
    }

    private var fileBox: some View {
        let meta = L10n.format(.importMeta, candidate.backup.manifest.appVersion,
                               SettingsFormat.day(candidate.backup.manifest.createdAt),
                               candidate.fileSize.map(SettingsFormat.size) ?? "—")
        return HStack(spacing: Space.s3) {
            Image(systemName: "doc.zipper")
                .font(TypeScale.headline)
                .foregroundStyle(Palette.text2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: candidate.fileName).font(TypeScale.monoSmall).middleTruncated(candidate.fileName)
                Text(meta).font(TypeScale.callout).foregroundStyle(Palette.text2).lineLimit(1).help(meta)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .contain)
    }

    private var previewTable: some View {
        let stats = preview
        let counts = stats.counts
        return VStack(alignment: .leading, spacing: 0) {
            BackupPreviewRow(symbol: "calendar", title: L10n.text(.fullRestoreCreated),
                             value: SettingsFormat.lastCheck(stats.createdAt))
            SettingsDivider()
            BackupPreviewRow(symbol: "doc.text", title: L10n.text(.fullRestoreRecordSaved),
                             value: stats.recordSavedAt.map(SettingsFormat.lastCheck) ?? L10n.text(.fullRestoreNoRecord))
            SettingsDivider()
            BackupPreviewRow(symbol: "server.rack", title: L10n.text(.importRowServers), value: String(counts.servers))
            SettingsDivider()
            BackupPreviewRow(symbol: "clock", title: L10n.text(.importRowHistory),
                             value: L10n.format(.fullRestoreLines, String(counts.historyEntries)))
            SettingsDivider()
            BackupPreviewRow(symbol: "chart.xyaxis.line", title: L10n.text(.fullRestoreMetrics),
                             value: L10n.format(.fullRestoreLines, String(counts.metricSamples)))
            SettingsDivider()
            BackupPreviewRow(symbol: "eye", title: L10n.text(.fullRestoreWatched), value: String(counts.watchedServers))
            SettingsDivider()
            BackupPreviewRow(symbol: stats.compatibility == .newerVersion ? "exclamationmark.triangle.fill" : "checkmark",
                             color: stats.compatibility == .newerVersion ? Palette.orange : Palette.text2,
                             title: L10n.text(.fullRestoreVersion), value: versionText(stats))
        }
        .padding(.horizontal, Space.s3)
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fullRestorePreview")
    }

    private func versionText(_ stats: FullBackupPreview) -> String {
        switch stats.compatibility {
        case .sameVersion: return L10n.format(.fullRestoreVersionSame, stats.appVersion)
        case .olderVersion: return L10n.format(.fullRestoreVersionOlder, stats.appVersion)
        case .newerVersion: return L10n.format(.fullRestoreVersionNewer, stats.appVersion)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if preview.compatibility == .newerVersion {
                note(symbol: StatusLevel.orange.symbolName, text: L10n.text(.fullRestoreNewerNote), warning: true)
            }
            if !preview.missingFiles.isEmpty {
                note(symbol: StatusLevel.orange.symbolName,
                     text: L10n.format(.fullRestoreMissingNote, preview.missingFiles.joined(separator: ", ")), warning: true)
            }
            note(symbol: "externaldrive", text: L10n.text(.fullRestoreNote), warning: false)
        }
    }

    private func note(symbol: String, text: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Image(systemName: symbol)
                .font(TypeScale.callout)
                .foregroundStyle(warning ? Palette.orange : Palette.text2)
                .accessibilityHidden(true)
            Text(text)
                .font(TypeScale.callout)
                .foregroundStyle(warning ? Palette.orangeText : Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func result(symbol: String, color: Color, title: String, lines: [String], isError: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: symbol)
                .font(TypeScale.title)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title).font(TypeScale.label)
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(TypeScale.callout)
                        .foregroundStyle(isError && index == 0 ? Palette.redText : Palette.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullRestoreResult")
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: Space.s2) {
            Spacer()
            switch phase {
            case .preview, .confirm:
                Button(L10n.text(.actionCancel), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.fullRestoreAction)) { phase = .confirm }
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.updates.status.isUpdating || model.isDataOperationRunning)
                    .accessibilityIdentifier("fullRestoreApply")
            case .working:
                Button(L10n.text(.actionClose), action: onClose).disabled(true)
            case .done, .failed:
                Button(L10n.text(.actionClose), action: onClose)
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func restore() {
        let saveFirst = model.hasUnsavedChanges && saveFirst
        phase = .working
        Task {
            switch await model.restoreFullBackup(candidate.backup, saveFirst: saveFirst) {
            case .success(let outcome): phase = .done(outcome.safetyBackup, kept: outcome.keptPrevious)
            case .failure(let error): phase = .failed(error)
            }
        }
    }
}

/// Preview row: symbol | title | value (12 secondary).
private struct BackupPreviewRow: View {
    let symbol: String
    var color = Palette.text2
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: symbol)
                .font(TypeScale.captionStrong)
                .foregroundStyle(color)
                .frame(width: Metrics.backupSymbol)
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
        .frame(minHeight: Metrics.backupRow)
        .accessibilityElement(children: .combine)
    }
}

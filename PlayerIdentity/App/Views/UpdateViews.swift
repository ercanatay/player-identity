import AppKit
import SwiftUI

/// Texts of the update status line and errors (§27.3).
enum UpdateStatusText {
    static func text(_ status: UpdateController.Status) -> String? {
        switch status {
        case .idle: return nil
        case .checking: return L10n.text(.updateStatusChecking)
        case .upToDate: return L10n.text(.updateStatusUpToDate)
        case .downloading(let fraction): return L10n.format(.updateStatusDownloading, percent(fraction))
        case .verifying: return L10n.text(.updateStatusVerifying)
        case .ready(let version): return L10n.format(.updateStatusReady, version)
        case .installing: return L10n.text(.updateStatusInstalling)
        case .relaunching: return L10n.text(.updateStatusRelaunching)
        case .cancelled: return L10n.text(.updateStatusCancelled)
        case .failed(let error): return self.error(error)
        case .backupFailed(let reason): return L10n.format(.updateErrorDataBackup, reason)
        }
    }

    static func isError(_ status: UpdateController.Status) -> Bool {
        switch status {
        case .failed, .backupFailed: return true
        default: return false
        }
    }

    static func error(_ error: UpdateError) -> String {
        switch error {
        case .feedUnavailable: return L10n.text(.updateErrorFeed)
        case .insecureURL: return L10n.text(.updateErrorInsecure)
        case .missingAsset: return L10n.text(.updateErrorMissingAsset)
        case .sameVersion: return L10n.text(.updateErrorSameVersion)
        case .downloadFailed: return L10n.text(.updateErrorDownload)
        case .sizeMismatch: return L10n.text(.updateErrorSize)
        case .checksumMissing, .checksumMismatch: return L10n.text(.updateErrorChecksum)
        case .unzipFailed, .appMissing: return L10n.text(.updateErrorUnpack)
        case .signatureInvalid: return L10n.text(.updateErrorSignature)
        case .teamMismatch: return L10n.text(.updateErrorTeam)
        case .bundleMismatch: return L10n.text(.updateErrorBundle)
        case .versionMismatch: return L10n.text(.updateErrorVersion)
        case .notWritable: return L10n.text(.updateErrorNotWritable)
        case .installFailed(true, _): return L10n.text(.updateErrorRolledBack)
        case .installFailed(false, let backup?): return L10n.format(.updateErrorBackupLocation, backup.path)
        case .installFailed(false, nil): return L10n.text(.updateErrorRolledBack)
        case .cancelled: return L10n.text(.updateStatusCancelled)
        }
    }

    static func percent(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: min(max(fraction, 0), 1))) ?? String(Int(fraction * 100))
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Status line with progress and cancel (banner and Settings).
struct UpdateStatusRow: View {
    @Bindable var updates: UpdateController
    /// Single line (banner); the Settings tab wraps long error texts.
    var compact = false

    var body: some View {
        if let text = UpdateStatusText.text(updates.status) {
            HStack(spacing: 8) {
                switch updates.status {
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 140)
                case .checking, .verifying, .installing, .relaunching:
                    ProgressView().controlSize(.small)
                default:
                    EmptyView()
                }
                Text(text)
                    .foregroundStyle(UpdateStatusText.isError(updates.status) ? Color.red : Color.secondary)
                    .lineLimit(compact ? 1 : nil)
                    .fixedSize(horizontal: compact, vertical: true)
                    .textSelection(.enabled)
                if updates.status.isCancellable {
                    Button(L10n.text(.actionAbort), action: updates.cancelInstall)
                        .fixedSize()
                }
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("updateStatus")
        }
    }
}

/// §27.3 banner: version + "Install" + "Release notes" + "Ignore"; shows the progress while installing.
struct UpdateBanner: View {
    @Bindable var updates: UpdateController
    let update: AppUpdate

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(L10n.format(.updateAvailable, update.version))
                .fontWeight(.medium)
            UpdateStatusRow(updates: updates, compact: true)
            Spacer()
            Button(L10n.text(.updateInstall)) { updates.requestInstallOfAvailableUpdate() }
                .disabled(updates.status.isBusy)
            Button(L10n.text(.updateReleaseNotes)) { NSWorkspace.shared.open(update.url) }
                .help(update.url.absoluteString)
            Button(L10n.text(.updateIgnore), action: updates.ignoreUpdate)
                .disabled(updates.status.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("updateBanner")
    }
}

/// §28.2/5 banner: the record cannot be read by this version and a compatible backup exists.
struct RestoreBanner: View {
    @Bindable var updates: UpdateController
    let backup: DataBackup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format(.restoreBanner, RestoreBanner.date(backup.info.createdAt)))
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = updates.restoreError {
                    Text(L10n.format(.restoreFailed, error)).font(.callout).foregroundStyle(.red)
                }
            }
            Spacer()
            Button(L10n.text(.restoreAction)) { updates.pendingRestore = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("restoreBanner")
        .alert(L10n.text(.restoreConfirmTitle), isPresented: $updates.pendingRestore) {
            Button(L10n.text(.actionCancel), role: .cancel) {}
            Button(L10n.text(.restoreAction)) { updates.confirmRestore() }
        } message: {
            Text(L10n.format(.restoreConfirmMessage, RestoreBanner.date(backup.info.createdAt)))
        }
    }

    static func date(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}

/// §27.3 / §28.2/2 confirmation before installing another version.
struct InstallConfirmSheet: View {
    @Bindable var updates: UpdateController
    let request: UpdateController.InstallRequest

    var body: some View {
        let release = request.release
        let downgrade = request.change == .downgrade
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format(downgrade ? .updateConfirmDowngradeTitle : .updateConfirmInstallTitle, release.versionString))
                .font(.title3.bold())
            if let size = release.zip?.size {
                Text(L10n.format(.updateConfirmSize, UpdateStatusText.size(size))).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(release.notes.isEmpty ? L10n.text(.updateNotesEmpty) : release.notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 100, maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            if downgrade {
                Label(L10n.text(.updateConfirmDowngradeWarning), systemImage: StatusLevel.orange.symbolName)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.text(.updateConfirmBackupData), isOn: Binding(
                    get: { updates.pendingInstall?.backupData ?? request.backupData },
                    set: { updates.pendingInstall?.backupData = $0 }))
            }
            Text(L10n.text(.updateConfirmRelaunch)).font(.callout).foregroundStyle(.secondary)
            HStack {
                if let page = release.pageURL {
                    Button(L10n.text(.updateReleaseNotes)) { NSWorkspace.shared.open(page) }
                }
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: updates.cancelRequest)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(downgrade ? .updateDowngrade : .updateInstall)) { updates.confirmInstall() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// §24 preview of the lines Apply would write: per file `-`/`+` lines with line numbers.
struct ApplyPreviewSheet: View {
    let preview: AppModel.ApplyPreview
    let onWrite: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(.diffTitle)).font(.title3.bold())
            Text(L10n.text(.diffMessage))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(preview.diffs.enumerated()), id: \.offset) { _, diff in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: diff.file.fileName).font(.headline.monospaced())
                            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.diffWrite), action: onWrite)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct DiffLineRow: View {
    let line: ConfigDiffLine

    var body: some View {
        let removed = line.kind == .removed
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: String(line.number))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(verbatim: removed ? "-" : "+")
                .foregroundStyle(removed ? Color.red : Color.green)
            Text(verbatim: line.text)
                .foregroundStyle(removed ? Color.red : Color.green)
                .textSelection(.enabled)
        }
        .font(.callout.monospaced())
        .padding(.vertical, 1)
        .background((removed ? Color.red : Color.green).opacity(0.08))
    }
}

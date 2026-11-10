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

/// §27.3 banner: full-width strip under the toolbar (accent tint, padding 8/16): icon, title + status,
/// Release Notes → Install (prominent) → Ignore (xmark). Shows the progress while installing.
struct UpdateBanner: View {
    @Bindable var updates: UpdateController
    let update: AppUpdate

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(L10n.format(.updateAvailable, update.version))
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .fixedSize()
                UpdateStatusRow(updates: updates, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text(.updateReleaseNotes)) { NSWorkspace.shared.open(update.url) }
                .help(update.url.absoluteString)
            Button(L10n.text(.updateInstall)) { updates.requestInstallOfAvailableUpdate() }
                .prominentButton()
                .disabled(updates.status.isBusy)
            IconButton(symbol: "xmark", label: L10n.text(.updateIgnore),
                       size: CGSize(width: Metrics.control, height: Metrics.control), symbolSize: 11,
                       action: updates.ignoreUpdate)
                .disabled(updates.status.isBusy)
        }
        .font(TypeScale.body)
        .padding(.leading, Space.s4)
        .padding(.trailing, Space.s3)
        .padding(.vertical, Space.s2)
        .background(Palette.accentTint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format(.updateAvailable, update.version))
        .accessibilityIdentifier("updateBanner")
    }
}

/// §28.2/5 banner: the record cannot be read by this version and a compatible backup exists.
struct RestoreBanner: View {
    @Bindable var updates: UpdateController
    let backup: DataBackup

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16))
                .foregroundStyle(Palette.orangeText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format(.restoreBanner, RestoreBanner.date(backup.info.createdAt)))
                    .font(TypeScale.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = updates.restoreError {
                    Text(L10n.format(.restoreFailed, error)).font(TypeScale.callout).foregroundStyle(Palette.redText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text(.restoreAction)) { updates.pendingRestore = true }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .background(Palette.orangeTint)
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
                ReleaseNotesText(notes: release.notes)
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

/// §24 preview of the lines Apply would write: per file an inset box with the file name and −/+ counts, then
/// rows of line number | sign | text (mono 12, red/green tints). Cancel (Esc) / Write (Return).
struct ApplyPreviewSheet: View {
    let preview: AppModel.ApplyPreview
    let onWrite: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(L10n.text(.diffTitle)).font(TypeScale.headline)
                Text(L10n.text(.diffMessage))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    ForEach(Array(preview.diffs.enumerated()), id: \.offset) { _, diff in
                        DiffFileBox(diff: diff)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s2) {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.diffWrite), action: onWrite)
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Space.s1)
        }
        .font(TypeScale.body)
        .foregroundStyle(Palette.text)
        .padding(20)
        .frame(width: 560)
        .background(Palette.raised)
    }
}

/// One file of the diff: header (file name, −N +N) and the numbered lines.
private struct DiffFileBox: View {
    let diff: ConfigFileDiff

    var body: some View {
        let removed = diff.lines.filter { $0.kind == .removed }.count
        let added = diff.lines.count - removed
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s2) {
                Image(systemName: "folder").font(.system(size: 11)).accessibilityHidden(true)
                Text(verbatim: diff.file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "−" + String(removed))
                    .foregroundStyle(Palette.redText)
                    .accessibilityLabel(L10n.text(.diffRemoved) + " " + String(removed))
                Text(verbatim: "+" + String(added))
                    .foregroundStyle(Palette.greenText)
                    .accessibilityLabel(L10n.text(.diffAdded) + " " + String(added))
            }
            .font(TypeScale.monoSmall)
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(alignment: .bottom) { ThemedDivider() }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line)
                }
            }
            .padding(.vertical, Space.s1)
        }
        .background(Palette.inset)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
    }
}

private struct DiffLineRow: View {
    let line: ConfigDiffLine

    var body: some View {
        let removed = line.kind == .removed
        HStack(spacing: 0) {
            Text(verbatim: String(line.number))
                .foregroundStyle(Palette.text3)
                .padding(.trailing, Space.s2)
                .frame(width: 40, alignment: .trailing)
            Text(verbatim: removed ? "−" : "+")
                .fontWeight(.bold)
                .foregroundStyle(removed ? Palette.redText : Palette.greenText)
                .frame(width: 20)
                .accessibilityLabel(L10n.text(removed ? .diffRemoved : .diffAdded))
            Text(verbatim: line.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(TypeScale.monoSmall)
        .frame(height: 20)
        .background(removed ? Palette.redTint : Palette.greenTint)
        .accessibilityElement(children: .combine)
    }
}

/// Release notes rendered from Markdown (headings, bold, code, links); empty body → localized placeholder.
struct ReleaseNotesText: View {
    let notes: String

    var body: some View {
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(L10n.text(.updateNotesEmpty))
        } else {
            Text(Self.styled(ReleaseNotesFormatter.attributed(notes)))
        }
    }

    static func styled(_ input: AttributedString) -> AttributedString {
        var out = input
        for run in out.runs {
            if run.presentationIntent != nil {
                out[run.range].font = .headline
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                out[run.range].font = .system(.body, design: .monospaced)
            } else if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                out[run.range].font = .callout.bold()
            }
        }
        return out
    }
}

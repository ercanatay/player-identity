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
        case .backingUp: return L10n.text(.updateStatusBackingUp)
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
        case .gatekeeperRejected: return L10n.text(.updateErrorGatekeeper)
        case .processTimedOut(let tool): return L10n.format(.updateErrorTimeout, tool)
        case .notWritable: return L10n.text(.updateErrorNotWritable)
        case .cancelledByUser: return L10n.text(.updateErrorCancelledByUser)
        case .adminPromptFailed: return L10n.text(.updateErrorAdminPrompt)
        case .installFailed(true, nil): return L10n.text(.updateErrorRolledBack)
        case .installFailed(true, let backup?): return L10n.format(.updateErrorRolledBackCopy, backup.path)
        case .installFailed(false, let backup?): return L10n.format(.updateErrorBackupLocation, backup.path)
        case .installFailed(false, nil): return L10n.text(.updateErrorNotRolledBack)
        case .cancelled: return L10n.text(.updateStatusCancelled)
        }
    }

    static func percent(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = SettingsFormat.locale   // "62 %" / "%62", in the in-app language
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: min(max(fraction, 0), 1))) ?? String(Int(fraction * 100))
    }

    static func size(_ bytes: Int) -> String {
        SettingsFormat.size(bytes)
    }
}

/// Status line with progress and cancel (update banner).
struct UpdateStatusRow: View {
    @Bindable var updates: UpdateController
    /// Single line (banner); elsewhere long error texts wrap.
    var compact = false

    var body: some View {
        if let text = UpdateStatusText.text(updates.status) {
            HStack(spacing: Space.s2) {
                switch updates.status {
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                        .tint(Palette.accentFill)
                        .frame(width: 140)
                        .accessibilityLabel(L10n.text(.a11yUpdateProgress))
                        .accessibilityValue(UpdateStatusText.percent(fraction))
                case .checking, .backingUp, .verifying, .installing, .relaunching:
                    ProgressView().controlSize(.small)
                default:
                    EmptyView()
                }
                Text(text)
                    .font(TypeScale.callout)
                    .foregroundStyle(UpdateStatusText.isError(updates.status) ? Palette.redText : Palette.text2)
                    .monospacedDigit()
                    .lineLimit(compact ? 1 : nil)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: !compact)
                    .help(text)
                    .textSelection(.enabled)
                if updates.status.isCancellable {
                    Button(L10n.text(.actionAbort), action: updates.cancelInstall)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("updateStatus")
        }
    }
}

/// What the Updates tab status card shows for the controller state (Claude Design S7–S10): available, downloading
/// (progress, size), working (verifying/installing), ready, up to date, cancelled, never checked, error.
struct UpdateCardContent: Equatable {
    enum Tone: Equatable {
        case accent, green, red, neutral
    }

    enum Action: Hashable {
        /// Opens the install confirmation for the available release.
        case install
        case releaseNotes
        case cancel
        /// Check again (the feed could not be loaded).
        case retryCheck
        /// Request the install again (download or verification failed).
        case retryInstall
    }

    var symbol: String
    var tone: Tone
    var title: String
    var body: String
    /// Determinate progress (downloading).
    var progress: Double?
    var isIndeterminate = false
    var percent: String?
    var actions: [Action] = []

    static func make(status: UpdateController.Status, availableUpdate: AppUpdate?, availableRelease: AppRelease?,
                     activeRelease: AppRelease?, lastCheck: Date?, appVersion: String) -> UpdateCardContent {
        let busySymbol = "arrow.down.circle.fill"
        let version = activeRelease?.versionString ?? availableUpdate?.version ?? ""
        switch status {
        case .checking:
            return UpdateCardContent(symbol: "arrow.clockwise", tone: .neutral, title: L10n.text(.updateStatusChecking),
                                     body: "", isIndeterminate: true)
        case .downloading(let fraction):
            let clamped = min(max(fraction, 0), 1)
            var body = ""
            if let size = activeRelease?.zip?.size, size > 0 {
                body = L10n.format(.updatesDownloadedOf, SettingsFormat.size(Int(Double(size) * clamped)),
                                   SettingsFormat.size(size))
            }
            return UpdateCardContent(symbol: busySymbol, tone: .accent,
                                     title: L10n.format(.updatesDownloadingTitle, version), body: body,
                                     progress: clamped, percent: UpdateStatusText.percent(clamped), actions: [.cancel])
        case .backingUp, .verifying, .installing, .relaunching:
            return UpdateCardContent(symbol: busySymbol, tone: .accent, title: UpdateStatusText.text(status) ?? "",
                                     body: version.isEmpty ? "" : L10n.format(.updatesVersion, version),
                                     isIndeterminate: true, actions: status.isCancellable ? [.cancel] : [])
        case .ready(let ready):
            return UpdateCardContent(symbol: busySymbol, tone: .accent, title: L10n.format(.updatesReadyTitle, ready),
                                     body: L10n.format(.updateStatusReady, ready), actions: [.install, .releaseNotes])
        case .failed(let error):
            let checkFailed = error == .feedUnavailable
            return UpdateCardContent(symbol: "xmark.octagon.fill", tone: .red,
                                     title: L10n.text(checkFailed ? .updatesCheckFailedTitle : .updatesInstallFailedTitle),
                                     body: UpdateStatusText.error(error),
                                     actions: [checkFailed || availableUpdate == nil ? .retryCheck : .retryInstall])
        case .backupFailed:
            return UpdateCardContent(symbol: "xmark.octagon.fill", tone: .red,
                                     title: L10n.text(.updatesInstallFailedTitle), body: UpdateStatusText.text(status) ?? "")
        case .cancelled:
            return UpdateCardContent(symbol: "xmark.circle", tone: .neutral, title: L10n.text(.updateStatusCancelled),
                                     body: L10n.text(.updatesCancelledBody),
                                     actions: availableUpdate == nil ? [] : [.install, .releaseNotes])
        case .upToDate:
            return upToDate(appVersion)
        case .idle:
            if let update = availableUpdate {
                return UpdateCardContent(symbol: busySymbol, tone: .accent,
                                         title: L10n.format(.updatesAvailableTitle, update.version),
                                         body: availableRelease.map(summary) ?? "", actions: [.install, .releaseNotes])
            }
            if lastCheck != nil { return upToDate(appVersion) }
            return UpdateCardContent(symbol: "arrow.down.circle", tone: .neutral, title: L10n.text(.updateNever),
                                     body: L10n.text(.updatesNeverBody))
        }
    }

    private static func upToDate(_ version: String) -> UpdateCardContent {
        UpdateCardContent(symbol: "checkmark.circle.fill", tone: .green, title: L10n.text(.updatesUpToDateTitle),
                          body: L10n.format(.updatesUpToDateBody, version))
    }

    /// "Faster ban checks · FWGS 0.21 support · 13.4 MB": up to three items of the release notes plus the size.
    static func summary(_ release: AppRelease) -> String {
        var parts = notesItems(release.notes, limit: 3)
        if let size = release.zip?.size { parts.append(SettingsFormat.size(size)) }
        return parts.joined(separator: " · ")
    }

    /// Bullet items of Markdown notes (or the first plain line), without Markdown marks.
    static func notesItems(_ notes: String, limit: Int) -> [String] {
        let lines = notes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let clean: (String) -> String = { line in
            var text = line
            while let first = text.first, "#-*+>".contains(first) { text.removeFirst() }
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("+ ") }.map(clean)
        let items = bullets.isEmpty ? lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.prefix(1).map(clean) : bullets
        return Array(items.filter { !$0.isEmpty }.prefix(limit))
    }

    var color: Color {
        switch tone {
        case .accent: return Palette.accent
        case .green: return Palette.green
        case .red: return Palette.red
        case .neutral: return Palette.text2
        }
    }
}

/// Updates tab status card (`role: status`): symbol 24 in the state colour, title 13 semibold (+ percentage),
/// progress bar, 12 pt body and the state's buttons. Min height 92 so switching state never reflows the tab.
struct UpdateStatusCard: View {
    @Bindable var updates: UpdateController

    private var content: UpdateCardContent {
        UpdateCardContent.make(status: updates.status, availableUpdate: updates.availableUpdate,
                               availableRelease: updates.availableRelease, activeRelease: updates.activeRelease,
                               lastCheck: updates.lastCheck, appVersion: updates.appVersion)
    }

    var body: some View {
        let content = self.content
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: content.symbol)
                .font(.system(size: 22))
                .foregroundStyle(content.color)
                .frame(width: 24, height: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(content.title)
                        .font(TypeScale.label)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let percent = content.percent {
                        Text(verbatim: percent)
                            .monospacedDigit()
                            .foregroundStyle(Palette.text2)
                    }
                }
                if let progress = content.progress {
                    TokenProgressBar(value: progress, label: L10n.text(.a11yUpdateProgress),
                                     valueText: content.percent ?? "")
                } else if content.isIndeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Palette.accentFill)
                        .accessibilityLabel(content.title)
                }
                if !content.body.isEmpty {
                    Text(content.body)
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(content.body)
                }
                if !content.actions.isEmpty {
                    HStack(spacing: Space.s2) {
                        ForEach(content.actions, id: \.self) { action in
                            button(action)
                        }
                    }
                    .padding(.top, Space.s1)
                }
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.body.isEmpty ? content.title : content.title + ". " + content.body)
        .accessibilityIdentifier("updateStatus")
    }

    @ViewBuilder
    private func button(_ action: UpdateCardContent.Action) -> some View {
        switch action {
        case .install:
            Button(L10n.text(.updatesDownloadAndInstall)) { updates.requestInstallOfAvailableUpdate() }
                .prominentButton()
                .disabled(updates.status.isBusy)
                .accessibilityIdentifier("updateInstall")
        case .releaseNotes:
            if let url = updates.availableRelease?.pageURL ?? updates.availableUpdate?.url {
                Button(L10n.text(.updateReleaseNotes)) { NSWorkspace.shared.open(url) }
                    .help(url.absoluteString)
            }
        case .cancel:
            Button(L10n.text(.actionCancel), action: updates.cancelInstall)
                .disabled(!updates.status.isCancellable)
                .accessibilityIdentifier("updateCancel")
        case .retryCheck:
            Button(L10n.text(.actionRetry)) { updates.checkForUpdates(manual: true) }
                .prominentButton()
        case .retryInstall:
            Button(L10n.text(.actionRetry)) { updates.requestInstallOfAvailableUpdate() }
                .prominentButton()
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
                Text(RestoreBanner.title(updates, backup: backup))
                    .font(TypeScale.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = RestoreBanner.errorText(updates) {
                    Text(error)
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.redText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("restoreError")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if updates.restoredAwaitingRelaunch {
                Button(L10n.text(.restoreRelaunch)) { updates.relaunchAfterRestore() }
                    .disabled(updates.isRelaunchingAfterRestore)
                    .accessibilityIdentifier("restoreRelaunch")
            } else {
                Button(L10n.text(.restoreAction)) { updates.pendingRestore = true }
            }
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

    /// Offer, or "restored, relaunch needed" once the files are back.
    @MainActor
    static func title(_ updates: UpdateController, backup: DataBackup) -> String {
        updates.restoredAwaitingRelaunch ? L10n.text(.restoreRestoredRelaunch)
                                         : L10n.format(.restoreBanner, date(backup.info.createdAt))
    }

    /// Red line: the restore failed, or the files are back but the relaunch failed.
    @MainActor
    static func errorText(_ updates: UpdateController) -> String? {
        guard let error = updates.restoreError else { return nil }
        return L10n.format(updates.restoredAwaitingRelaunch ? .restoreRelaunchFailed : .restoreFailed, error)
    }
}

/// §27.3 / §28.2/2 confirmation before installing another version (sheet: 520 wide, padding 20, spacing 12; notes in an
/// inset box; Release Notes on the left, Cancel (Esc) then the default button (Return) on the right).
struct InstallConfirmSheet: View {
    @Bindable var updates: UpdateController
    let request: UpdateController.InstallRequest

    var body: some View {
        let release = request.release
        let downgrade = request.change == .downgrade
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(L10n.format(downgrade ? .updateConfirmDowngradeTitle : .updateConfirmInstallTitle, release.versionString))
                    .font(TypeScale.headline)
                    .foregroundStyle(Palette.text)
                if let size = release.zip?.size {
                    Text(L10n.format(.updateConfirmSize, UpdateStatusText.size(size)))
                        .foregroundStyle(Palette.text2)
                        .monospacedDigit()
                }
            }
            ScrollView {
                ReleaseNotesText(notes: release.notes)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s3)
            }
            .frame(minHeight: 100, maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
            .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
            if downgrade {
                NoticeBox(symbol: StatusLevel.orange.symbolName, symbolColor: Palette.orange,
                          text: L10n.text(.updateConfirmDowngradeWarning), textColor: Palette.orangeText,
                          background: Palette.orangeTint)
                Toggle(L10n.text(.updateConfirmBackupData), isOn: Binding(
                    get: { updates.pendingInstall?.backupData ?? request.backupData },
                    set: { updates.pendingInstall?.backupData = $0 }))
                    .toggleStyle(.checkbox)
                    .tint(Palette.accentFill)
            }
            Text(L10n.text(.updateConfirmRelaunch))
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s2) {
                if let page = release.pageURL {
                    Button(L10n.text(.updateReleaseNotes)) { NSWorkspace.shared.open(page) }
                        .help(page.absoluteString)
                }
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: updates.cancelRequest)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(downgrade ? .updateDowngrade : .updateInstall)) { updates.confirmInstall() }
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Space.s1)
        }
        .font(TypeScale.body)
        .foregroundStyle(Palette.text)
        .padding(20)
        .frame(width: 520)
        .background(Palette.raised)
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

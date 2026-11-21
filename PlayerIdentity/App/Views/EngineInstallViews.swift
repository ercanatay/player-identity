import AppKit
import SwiftUI

// MARK: - §74 "Install Compatible Engine": pure presentation + views (card section, confirmation sheet, backups row)

/// What the macOS identity card shows for the install flow. Pure (testable without rendering); never holds a raw
/// identity, a full CID or an identity checksum (only masked CIDs from the core).
struct EngineInstallPresentation: Equatable {
    enum ButtonState: Equatable {
        case hidden
        case enabled
        /// Disabled with its reason (also read by VoiceOver).
        case disabled(String)
    }

    enum LineKind: Equatable {
        case info
        case success
        case warning
        case error
        case critical
    }

    struct Line: Equatable, Hashable {
        let text: String
        let kind: LineKind
    }

    struct Progress: Equatable {
        let text: String
        /// 0…1 while downloading (bytes / total); `nil` = indeterminate.
        let fraction: Double?
        let cancellable: Bool
        let cancelling: Bool
    }

    let installButton: ButtonState
    /// "Official release page" as a secondary link (the install is the primary action).
    let showsReleasePageLink: Bool
    let fetching: Bool
    let progress: Progress?
    let lines: [Line]
    let showsOpenEngine: Bool
    let showsDismiss: Bool

    /// The line VoiceOver announces for the current step / result.
    var announcement: String? {
        if let progress { return L10n.format(.engineInstallA11yProgress, progress.text) }
        if fetching { return L10n.text(.engineInstallFetching) }
        return lines.first?.text
    }

    init(availability: EngineInstallAvailability, flow: EngineInstallFlow, awaitingVerification: Bool,
         launchStatus: EngineInstallLaunchStatus?, home: URL? = nil) {
        switch availability {
        case .hidden: installButton = .hidden
        case .enabled: installButton = .enabled
        case .disabled(let block): installButton = .disabled(Self.text(block))
        }
        showsReleasePageLink = availability != .hidden
        fetching = flow == .fetchingRelease

        var lines: [Line] = []
        var progress: Progress?
        switch flow {
        case .idle, .fetchingRelease, .confirming:
            break
        case .installing(let step, let cancelling):
            progress = Progress(text: cancelling ? L10n.text(.engineInstallProgressCancelling) : Self.text(step),
                                fraction: Self.fraction(step), cancellable: step.phase.isCancellable && !cancelling,
                                cancelling: cancelling)
            if !step.phase.isCancellable { lines.append(Line(text: L10n.text(.engineInstallProgressNoCancel), kind: .info)) }
        case .fetchFailed(let failure):
            lines.append(Line(text: L10n.format(.engineInstallResultFetchFailed, Self.text(failure)), kind: .error))
        case .blocked(let block):
            lines.append(Line(text: Self.text(block), kind: .error))
        case .finished(let finish):
            lines += Self.lines(finish, awaitingVerification: awaitingVerification, home: home)
        }
        if awaitingVerification, flow.finish != nil {
            switch launchStatus {
            case .launched?:
                lines.append(Line(text: L10n.text(.macIdentityRegenerateLaunched), kind: .info))
            case .engineRunning?:
                lines.append(Line(text: L10n.text(.engineInstallBlockedRunning), kind: .error))
            case .processUnavailable?:
                lines.append(Line(text: L10n.text(.engineInstallBlockedUnavailable), kind: .error))
            case .failed(let reason)?:
                lines.append(Line(text: L10n.format(.macIdentityRegenerateFailed, reason), kind: .error))
                lines.append(Line(text: L10n.text(.engineInstallResultGatekeeper), kind: .warning))
            case nil:
                break
            }
        }
        self.lines = lines
        self.progress = progress
        showsOpenEngine = awaitingVerification && flow.finish != nil && launchStatus != .launched
        switch flow {
        case .finished: showsDismiss = !awaitingVerification
        case .fetchFailed, .blocked: showsDismiss = true
        default: showsDismiss = false
        }
    }

    private static func lines(_ finish: EngineInstallFinish, awaitingVerification: Bool, home: URL?) -> [Line] {
        let report = finish.report
        var lines: [Line] = []
        switch finish.outcome {
        case .installed:
            switch finish.verification?.verification {
            case .identityRepaired?:
                lines.append(Line(text: L10n.text(.engineInstallResultRepaired), kind: .success))
            case .alreadyHealthy?:
                lines.append(Line(text: L10n.text(.engineInstallResultAlreadyHealthy), kind: .success))
            case .notVerified?:
                lines.append(Line(text: L10n.text(.engineInstallResultNotVerified), kind: .warning))
            case nil:
                lines.append(Line(text: L10n.text(.engineInstallResultInstalled), kind: .info))
            }
            if let verification = finish.verification, verification.cidChanged,
               let before = verification.cidBefore, let after = verification.cidAfter {
                lines.append(Line(text: L10n.format(.engineInstallResultCidChanged, before, after), kind: .warning))
            }
            if awaitingVerification {
                lines.append(Line(text: L10n.text(.engineInstallResultInstructions), kind: .info))
                lines.append(Line(text: L10n.text(.engineInstallResultGatekeeper), kind: .info))
            }
        case .failed(let failure):
            lines.append(Line(text: L10n.format(.engineInstallResultFailed, text(failure)), kind: .error))
        case .rolledBack(let failure):
            lines.append(Line(text: L10n.format(.engineInstallResultRolledBack, text(failure)), kind: .error))
        case .rollbackIncomplete(let failure):
            lines.append(Line(text: L10n.format(.engineInstallResultRollbackIncomplete, text(failure)), kind: .critical))
        case .cancelled:
            lines.append(Line(text: L10n.text(.engineInstallResultCancelled), kind: .info))
        }
        if let backup = report.backup {
            var kind = LineKind.info
            if case .rollbackIncomplete = finish.outcome { kind = .critical }
            lines.append(Line(text: L10n.format(.engineInstallResultBackup, path(backup.root.path, home: home) + " · " + backup.stamp),
                              kind: kind))
        }
        if !report.skippedLibraries.isEmpty {
            let list = report.skippedLibraries.map { "\($0.path) (\($0.reason.rawValue))" }.joined(separator: ", ")
            lines.append(Line(text: L10n.format(.engineInstallResultSkipped, list), kind: .info))
        }
        if !report.quarantineFailures.isEmpty {
            lines.append(Line(text: L10n.format(.engineInstallResultQuarantine,
                                                report.quarantineFailures.joined(separator: ", ")), kind: .warning))
        }
        if report.identityFilesChanged {
            lines.append(Line(text: L10n.text(.engineInstallResultIdentityFilesChanged), kind: .warning))
        }
        if !report.leftovers.isEmpty {
            lines.append(Line(text: L10n.format(.engineInstallResultLeftovers,
                                                report.leftovers.map { path($0, home: home) }.joined(separator: ", ")),
                              kind: .warning))
        }
        return lines
    }

    private static func path(_ path: String, home: URL?) -> String {
        SettingsFormat.abbreviated(path, home: home)
    }

    /// "<reason> (code: <code>)": the localized reason and the exact `EngineInstallFailure.code` (AC-E8).
    static func text(_ failure: EngineInstallFailure) -> String {
        let reason: String
        switch EngineInstallFailureGroup(failure) {
        case .network: reason = L10n.text(.engineInstallReasonNetwork)
        case .verification: reason = L10n.text(.engineInstallReasonVerification)
        case .archive: reason = L10n.text(.engineInstallReasonArchive)
        case .permission: reason = L10n.text(.engineInstallReasonPermission)
        case .running: reason = L10n.text(.engineInstallReasonRunning)
        case .locked: reason = L10n.text(.engineInstallReasonLocked)
        case .target: reason = L10n.text(.engineInstallReasonTarget)
        case .cancelled: reason = L10n.text(.engineInstallReasonCancelled)
        case .other: reason = L10n.text(.engineInstallReasonOther)
        }
        return L10n.format(.engineInstallFailure, reason, failure.code)
    }

    static func text(_ block: EngineInstallBlock) -> String {
        switch block {
        case .engineRunning: return L10n.text(.engineInstallBlockedRunning)
        case .processUnavailable: return L10n.text(.engineInstallBlockedUnavailable)
        case .architecture: return L10n.text(.engineInstallBlockedArchitecture)
        case .busy: return L10n.text(.engineInstallBlockedBusy)
        case .notOffered: return L10n.text(.macIdentityTextUnsupported)
        }
    }

    static func fraction(_ progress: EngineInstallProgress) -> Double? {
        guard progress.phase == .downloading, progress.total > 0 else { return nil }
        return min(max(Double(progress.bytes) / Double(progress.total), 0), 1)
    }

    /// The step as text; downloading shows bytes, total and the percentage (AC-E6: never colour alone).
    static func text(_ progress: EngineInstallProgress) -> String {
        switch progress.phase {
        case .downloading:
            let done = ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file)
            let base = L10n.format(.engineInstallPhaseDownloading, done, total)
            guard let fraction = fraction(progress) else { return base }
            return base + " (" + fraction.formatted(.percent.precision(.fractionLength(0)).locale(SettingsFormat.locale)) + ")"
        case .verifyingDigest: return L10n.text(.engineInstallPhaseVerifyingDigest)
        case .extracting: return L10n.text(.engineInstallPhaseExtracting)
        case .verifyingSignature: return L10n.text(.engineInstallPhaseVerifyingSignature)
        case .preflightPermission, .preflightProcess: return L10n.text(.engineInstallPhasePreflight)
        case .backingUp: return L10n.text(.engineInstallPhaseBackingUp)
        case .rollingBack: return L10n.text(.engineInstallPhaseRollingBack)
        default: return L10n.text(.engineInstallPhaseInstalling)
        }
    }
}

/// The lines of the confirmation screen (AC-E2, AC-E2a, AC-E15, G8). Pure.
struct EngineInstallConfirmationContent: Equatable {
    let title: String
    let details: [String]
    let cidLine: String
    let warning: String
    let acceptLabel: String
    let firstLaunch: String
    let license: String

    init(summary: EngineInstallPlanSummary, home: URL?) {
        title = L10n.text(.engineInstallConfirmTitle)
        let release = summary.release
        var details = [
            L10n.text(.engineInstallConfirmSource),
            L10n.format(.engineInstallConfirmCommit, release.commitSHA),
            L10n.format(.engineInstallConfirmAsset, release.asset.name, summary.sizeText),
            L10n.format(.engineInstallConfirmEngine, SettingsFormat.abbreviated(summary.targetApp.path, home: home)),
            L10n.text(.engineInstallConfirmFiles),
        ]
        details += summary.gameLibraries.map { "• " + SettingsFormat.abbreviated($0.path, home: home) }
        details.append(L10n.format(.engineInstallConfirmBackup, SettingsFormat.abbreviated(summary.backupRoot.path,
                                                                                           home: home)))
        self.details = details
        cidLine = L10n.format(.engineInstallConfirmCid, summary.cidMasked ?? L10n.text(.engineInstallConfirmCidNone))
        warning = L10n.text(.engineInstallConfirmCidWarning)
        acceptLabel = L10n.text(.engineInstallConfirmAccept)
        firstLaunch = L10n.text(.engineInstallConfirmFirstLaunch)
        license = L10n.format(.engineInstallConfirmLicense, release.commitURL.absoluteString)
    }
}

/// The install part of the identity card: button (primary) + release page (secondary), progress with Cancel while it
/// is allowed, result lines with their kind as text colour *and* symbol, "Open Engine" and Close.
struct EngineInstallSection: View {
    @Bindable var model: AppModel

    private var presentation: EngineInstallPresentation {
        EngineInstallPresentation(availability: model.engineInstallAvailability, flow: model.engineInstall,
                                  awaitingVerification: model.engineInstallAwaitingVerification,
                                  launchStatus: model.engineInstallLaunchStatus, home: model.homeDirectory)
    }

    var body: some View {
        let presentation = presentation
        VStack(alignment: .leading, spacing: Space.s2) {
            if presentation.installButton != .hidden {
                installButton(presentation)
            }
            if presentation.fetching {
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text(.engineInstallFetching)).font(TypeScale.callout).foregroundStyle(Palette.text2)
                    Button(L10n.text(.actionAbort)) { model.cancelEngineInstall() }
                        .controlSize(.small)
                        .accessibilityIdentifier("engineInstallCancelFetch")
                }
                .accessibilityElement(children: .combine)
            }
            if let progress = presentation.progress {
                progressView(progress)
            }
            ForEach(presentation.lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                    Image(systemName: Self.symbol(line.kind))
                        .foregroundStyle(Self.color(line.kind))
                        .accessibilityHidden(true)
                    Text(line.text)
                        .font(line.kind == .critical ? TypeScale.label : TypeScale.callout)
                        .foregroundStyle(Self.textColor(line.kind))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            if presentation.showsOpenEngine || presentation.showsDismiss {
                HStack(spacing: Space.s2) {
                    if presentation.showsOpenEngine {
                        Button {
                            model.openEngineAfterInstall()
                        } label: {
                            Label(L10n.text(.macIdentityRegenerateConfirmAction), systemImage: "play.circle")
                        }
                        .accessibilityHint(L10n.text(.engineInstallResultInstructions))
                        .accessibilityIdentifier("engineInstallOpenEngine")
                    }
                    if presentation.showsDismiss {
                        Button(L10n.text(.actionClose)) { model.dismissEngineInstallResult() }
                            .accessibilityIdentifier("engineInstallDismiss")
                    }
                }
            }
        }
        .accessibilityIdentifier("engineInstallSection")
        .onChange(of: presentation.announcement) { _, text in
            // AC-E5: every step and result is announced.
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .onDisappear { model.engineInstallWindowWillClose() }
        .sheet(item: Binding(
            get: { model.engineInstall.offer.map(OfferBox.init) },
            set: { if $0 == nil { model.declineEngineInstall() } }
        )) { box in
            EngineInstallConfirmSheet(model: model, offer: box.offer)
        }
    }

    private struct OfferBox: Identifiable {
        let offer: EngineInstallOffer
        var id: String { offer.summary.release.commitSHA + offer.summary.targetApp.path }
    }

    @ViewBuilder
    private func installButton(_ presentation: EngineInstallPresentation) -> some View {
        let reason: String? = {
            if case .disabled(let text) = presentation.installButton { return text }
            return nil
        }()
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Button {
                    model.requestEngineInstall()
                } label: {
                    Label(L10n.text(.engineInstallActionInstall), systemImage: "arrow.down.app")
                }
                .disabled(presentation.installButton != .enabled)
                .help(reason ?? L10n.text(.engineInstallActionInstallHint))
                .accessibilityHint(reason ?? L10n.text(.engineInstallActionInstallHint))
                .accessibilityIdentifier("engineInstallButton")
                if presentation.showsReleasePageLink {
                    Button(L10n.text(.engineInstallActionReleasePage)) { model.openCompatibleEngineDownload() }
                        .buttonStyle(.link)
                        .help(L10n.text(.macIdentityActionDownloadHint))
                        .accessibilityHint(L10n.text(.macIdentityActionDownloadHint))
                        .accessibilityIdentifier("engineInstallReleasePage")
                }
            }
            if let reason {
                Text(reason)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text(.engineInstallActionInstallHint))
                .font(TypeScale.caption)
                .foregroundStyle(Palette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressView(_ progress: EngineInstallPresentation.Progress) -> some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Palette.text2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(progress.text)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if progress.cancellable {
                Button(L10n.text(.actionAbort)) { model.cancelEngineInstall() }
                    .controlSize(.small)
                    .accessibilityIdentifier("engineInstallCancel")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format(.engineInstallA11yProgress, progress.text))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("engineInstallProgress")
    }

    static func symbol(_ kind: EngineInstallPresentation.LineKind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private static func color(_ kind: EngineInstallPresentation.LineKind) -> Color {
        switch kind {
        case .info: return Palette.text3
        case .success: return Palette.green
        case .warning: return Palette.orange
        case .error, .critical: return Palette.red
        }
    }

    private static func textColor(_ kind: EngineInstallPresentation.LineKind) -> Color {
        switch kind {
        case .info: return Palette.text2
        case .success: return Palette.greenText
        case .warning: return Palette.orangeText
        case .error, .critical: return Palette.redText
        }
    }
}

/// Confirmation sheet: release, files, backup location, masked CID and the CID warning that must be accepted. The
/// default (Return) action is Cancel (AC-E56); Install stays disabled until the warning is accepted.
struct EngineInstallConfirmSheet: View {
    @Bindable var model: AppModel
    let offer: EngineInstallOffer
    @State private var accepted = false

    var body: some View {
        let content = EngineInstallConfirmationContent(summary: offer.summary, home: model.homeDirectory)
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(content.title)
                .font(TypeScale.headline)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s1) {
                    ForEach(content.details, id: \.self) { line in
                        Text(verbatim: line)
                            .font(TypeScale.callout)
                            .foregroundStyle(Palette.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Text(verbatim: content.license)
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.text3)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Text(verbatim: content.cidLine)
                .font(TypeScale.mono)
                .accessibilityIdentifier("engineInstallConfirmCID")
            HStack(alignment: .top, spacing: Space.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.orange)
                    .accessibilityHidden(true)
                Text(content.warning)
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("engineInstallConfirmWarning")
            Toggle(content.acceptLabel, isOn: $accepted)
                .toggleStyle(.checkbox)
                .accessibilityHint(content.warning)
                .accessibilityIdentifier("engineInstallConfirmAccept")
            Text(content.firstLaunch)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel) { model.declineEngineInstall() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("engineInstallConfirmCancel")
                Button(L10n.text(.engineInstallConfirmInstall)) {
                    model.confirmEngineInstall(acceptedCIDWarning: accepted)
                }
                .disabled(!accepted)
                .accessibilityHint(content.warning)
                .accessibilityIdentifier("engineInstallConfirmInstall")
            }
        }
        .padding(Space.s6)
        .frame(width: 520)
    }
}

/// Settings > Data > "Engine backups": inventory (newest 3 kept), location, "Delete Older Backups…" with an explicit
/// confirmation; partial failures and a changed folder are shown. Nothing is deleted without the confirmation.
struct EngineBackupsRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.engineBackupsTitle)).font(TypeScale.body)
                Text(L10n.format(.engineBackupsCaption,
                                 SettingsFormat.abbreviated(model.engineBackupStore.root.path, home: model.homeDirectory)))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(EngineBackupsPresentation(inventory: model.engineBackups).rows, id: \.self) { row in
                Text(verbatim: row)
                    .font(TypeScale.monoSmall)
                    .foregroundStyle(Palette.text2)
            }
            HStack(spacing: Space.s2) {
                Text(EngineBackupsPresentation(inventory: model.engineBackups).summary)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.text(.engineBackupsDelete)) { model.requestEngineBackupDeletion() }
                    .fixedSize()
                    .disabled((model.engineBackups?.pruneCandidates.isEmpty ?? true) || model.isEngineInstallRunning)
                    .accessibilityIdentifier("settingsEngineBackupsDelete")
            }
            ForEach(EngineBackupsPresentation.messages(loadError: model.engineBackupsError,
                                                       deletion: model.engineBackupDeletion,
                                                       deletionError: model.engineBackupDeletionError), id: \.text) { line in
                Text(line.text)
                    .font(TypeScale.callout)
                    .foregroundStyle(line.isError ? Palette.redText : Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Space.s2)
        .onAppear { model.loadEngineBackups() }
        .alert(L10n.text(.engineBackupsConfirmTitle), isPresented: Binding(
            get: { model.showsEngineBackupDeletionConfirmation },
            set: { if !$0 { model.cancelEngineBackupDeletion() } }
        )) {
            Button(L10n.text(.actionCancel), role: .cancel) { model.cancelEngineBackupDeletion() }
            Button(L10n.text(.actionDelete), role: .destructive) { model.confirmEngineBackupDeletion() }
        } message: {
            Text(L10n.format(.engineBackupsConfirmMessage,
                             String(model.engineBackups?.pruneCandidates.count ?? 0)))
        }
    }
}

/// Texts of the backups row (pure).
struct EngineBackupsPresentation: Equatable {
    let rows: [String]
    let summary: String

    init(inventory: EngineBackupInventory?) {
        guard let inventory, !inventory.groups.isEmpty else {
            rows = []
            summary = L10n.text(.engineBackupsEmpty)
            return
        }
        let kept = Set(inventory.kept.map(\.stamp))
        rows = inventory.groups.map { group in
            group.stamp + " — " + (kept.contains(group.stamp) ? L10n.text(.engineBackupsKept) : L10n.text(.engineBackupsOlder))
        }
        summary = L10n.format(.engineBackupsSummary, String(inventory.groups.count), String(inventory.pruneCandidates.count))
    }

    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    static func messages(loadError: EngineInstallFailure?, deletion: EngineBackupDeletionReport?,
                         deletionError: EngineInstallFailure?) -> [Message] {
        var messages: [Message] = []
        if let loadError { messages.append(Message(text: L10n.format(.engineBackupsError, loadError.code), isError: true)) }
        if let deletion {
            if deletion.status == .partialFailure {
                let failed = deletion.failed.keys.sorted().map { "\($0): \(deletion.failed[$0]!.rawValue)" }
                messages.append(Message(text: L10n.format(.engineBackupsPartial, failed.joined(separator: ", ")),
                                        isError: true))
            }
            if !deletion.removed.isEmpty {
                messages.append(Message(text: L10n.format(.engineBackupsDeleted, String(deletion.removed.count)),
                                        isError: false))
            }
        }
        switch deletionError {
        case .confirmationRequired?:
            messages.append(Message(text: L10n.text(.engineBackupsStale), isError: true))
        case .locked?:
            messages.append(Message(text: L10n.text(.engineBackupsBusy), isError: true))
        case let failure?:
            messages.append(Message(text: L10n.format(.engineBackupsError, failure.code), isError: true))
        case nil:
            break
        }
        return messages
    }
}

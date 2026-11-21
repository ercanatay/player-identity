import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §73 what the macOS identity card shows for a report. Pure (testable without rendering); never holds the raw identity
/// or a full CID.
struct MacIdentityPresentation: Equatable {
    enum Tone: Equatable {
        case good
        case warning
        case critical
        case neutral
    }

    struct RegenerateButton: Equatable {
        let enabled: Bool
        /// Why it is disabled (also read by VoiceOver); `nil` when enabled.
        let blockedReason: String?
    }

    let stateLabel: String
    let symbol: String
    let tone: Tone
    let message: String
    /// Extra lines under the message (shared zero CID, diagnostics hint).
    let notes: [String]
    /// Masked CID, static evidence count, engine path.
    let details: [String]
    /// `nil` = the action is not offered.
    let regenerate: RegenerateButton?
    let showsDownload: Bool
    /// Result of the last action (launched / failed), with whether it is an error.
    let actionFeedback: (text: String, isError: Bool)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stateLabel == rhs.stateLabel && lhs.symbol == rhs.symbol && lhs.tone == rhs.tone && lhs.message == rhs.message
            && lhs.notes == rhs.notes && lhs.details == rhs.details && lhs.regenerate == rhs.regenerate
            && lhs.showsDownload == rhs.showsDownload && lhs.actionFeedback?.text == rhs.actionFeedback?.text
            && lhs.actionFeedback?.isError == rhs.actionFeedback?.isError
    }

    /// VoiceOver status line ("macOS hardware identity status: Indicators found. …").
    var accessibilityStatus: String {
        L10n.format(.macIdentityA11yStatus, stateLabel) + ". " + message
    }

    /// - Parameters:
    ///   - checking: a refresh is running; it hides the previous result, details and actions completely.
    ///   - engineRunning: the app-wide engine flag (`AppModel.isGameRunning`, kept in sync with the identity report;
    ///     also set after a successful "Regenerate Identity" launch).
    ///   - processState: the latest tri-state of the engine process (`nil` = only the report is known).
    ///   - overrideRejection: the engine override that was refused (shown as a visible note).
    init(report: MacIdentityReport?, checking: Bool, engineRunning: Bool, processState: EngineProcessState? = nil,
         regenerateStatus: AppModel.MacIdentityRegenerateStatus? = nil, downloadFailed: Bool = false,
         overrideRejection: EnginePathError? = nil, home: URL? = nil, installVerificationPending: Bool = false) {
        guard let report, !checking else {
            stateLabel = L10n.text(.macIdentityStateChecking)
            symbol = "hourglass"
            tone = .neutral
            message = checking ? L10n.text(.macIdentityStateChecking) : L10n.text(.topbarNotChecked)
            notes = []
            details = []
            regenerate = nil
            showsDownload = false
            actionFeedback = nil
            return
        }
        // §74 (AC-E45, AC-E87a): after "Install Compatible Engine" nothing is called supported until the core
        // verification said identityRepaired / alreadyHealthy.
        let pendingInstall = installVerificationPending && report.state == .supported
        switch report.state {
        case .supported where pendingInstall:
            stateLabel = L10n.text(.engineInstallStateVerifying)
            symbol = "hourglass.circle.fill"
            tone = .warning
        case .supported:
            stateLabel = L10n.text(.macIdentityStateSupported)
            symbol = "checkmark.circle.fill"
            tone = .good
        case .unsupported:
            stateLabel = L10n.text(.macIdentityStateUnsupported)
            symbol = "xmark.octagon.fill"
            tone = .critical
        case .unknown:
            stateLabel = L10n.text(.macIdentityStateUnknown)
            if report.finding == .engineRunning {
                symbol = "pause.circle.fill"
                tone = .neutral
            } else {
                symbol = "questionmark.circle.fill"
                tone = .warning
            }
        }
        message = pendingInstall ? L10n.text(.engineInstallResultInstalled) : Self.message(report.finding)

        var notes: [String] = []
        if let overrideRejection {
            notes.append(L10n.format(.macIdentityOverrideRejected, Self.text(overrideRejection)))
        }
        if report.rawState == .zero { notes.append(L10n.text(.macIdentityZeroShared)) }
        if report.state == .unknown { notes.append(L10n.text(.macIdentityDiagnosticHint)) }
        self.notes = notes

        var details: [String] = []
        if let cid = report.cidMasked { details.append(L10n.format(.macIdentityCidMasked, cid)) }
        if report.staticChecked, report.staticSupport != .unknown {
            details.append(L10n.format(.macIdentityEvidence, String(report.evidence.count)))
        }
        details.append(L10n.format(.macIdentityEngine, SettingsFormat.abbreviated(report.engineApp.path, home: home)))
        self.details = details

        if report.action == .regenerate {
            let state = processState ?? report.processState
            if engineRunning || state == .running {
                regenerate = RegenerateButton(enabled: false, blockedReason: L10n.text(.macIdentityRegenerateCloseEngine))
            } else if state == .unavailable {
                regenerate = RegenerateButton(enabled: false,
                                              blockedReason: L10n.text(.macIdentityTextProcessUnavailable))
            } else {
                regenerate = RegenerateButton(enabled: true, blockedReason: nil)
            }
        } else {
            regenerate = nil
        }
        showsDownload = report.action == .downloadEngine

        switch regenerateStatus {
        case .launched?:
            actionFeedback = (L10n.text(.macIdentityRegenerateLaunched), false)
        case .failed(let error)?:
            actionFeedback = (Self.text(error), true)
        case nil:
            actionFeedback = downloadFailed ? (L10n.text(.macIdentityActionDownloadFailed), true) : nil
        }
    }

    static func message(_ finding: MacIdentityFinding) -> String {
        switch finding {
        case .healthy: return L10n.text(.macIdentityTextHealthy)
        case .nonzeroWithoutEvidence: return L10n.text(.macIdentityTextNonzeroWithoutEvidence)
        case .zero, .notGenerated: return L10n.text(.macIdentityTextZero)
        case .unsupported: return L10n.text(.macIdentityTextUnsupported)
        case .engineNotFound: return L10n.text(.macIdentityTextEngineNotFound)
        case .engineUnverifiable: return L10n.text(.macIdentityTextEngineUnverifiable)
        case .identityUnreadable: return L10n.text(.macIdentityTextIdentityUnreadable)
        case .engineRunning: return L10n.text(.macIdentityTextEngineRunning)
        case .processUnavailable: return L10n.text(.macIdentityTextProcessUnavailable)
        }
    }

    static func text(_ error: MacIdentityRegenerateError) -> String {
        switch error {
        case .notOffered: return L10n.text(.macIdentityRegenerateNotOffered)
        case .engineRunning: return L10n.text(.macIdentityRegenerateCloseEngine)
        case .processUnavailable: return L10n.text(.macIdentityTextProcessUnavailable)
        case .engineUnavailable: return L10n.text(.macIdentityRegenerateUnavailable)
        case .launchFailed(let reason): return L10n.format(.macIdentityRegenerateFailed, reason)
        }
    }

    static func text(_ error: EnginePathError) -> String {
        switch error {
        case .notFound: return L10n.text(.macIdentityOverrideNotFound)
        case .notAppBundle: return L10n.text(.macIdentityOverrideNotAppBundle)
        case .symbolicLink: return L10n.text(.macIdentityOverrideSymbolicLink)
        case .missingExecutable: return L10n.text(.macIdentityOverrideMissingExecutable)
        case .insideDataFolder: return L10n.text(.macIdentityOverrideInsideDataFolder)
        case .unreadable: return L10n.text(.macIdentityOverrideUnreadable)
        }
    }
}

/// §73 card "macOS Hardware Identity": state (icon + label + text, colour never alone), masked CID, static evidence,
/// engine path, and the one action of the state ("Regenerate Identity" / "Download Compatible Engine"). Indicators
/// are never presented as proof of uniqueness. There is no random identity change; the note under the card says why.
struct MacIdentityCard: View {
    @Bindable var model: AppModel

    private var presentation: MacIdentityPresentation {
        MacIdentityPresentation(report: model.macIdentity, checking: model.isCheckingMacIdentity,
                                engineRunning: model.isGameRunning, processState: model.engineProcessState,
                                regenerateStatus: model.macIdentityRegenerateStatus,
                                downloadFailed: model.engineDownloadFailed,
                                overrideRejection: model.engineOverrideRejection
                                    ?? model.engineResolution.rejectedOverride,
                                home: model.homeDirectory,
                                installVerificationPending: model.engineInstallAwaitingVerification)
    }

    var body: some View {
        let presentation = presentation
        ThemedCard {
            CardHeader(symbol: "cpu", title: L10n.text(.macIdentityTitle)) {
                if model.isCheckingMacIdentity { ProgressView().controlSize(.small) }
                Button {
                    model.refreshMacIdentity()
                } label: {
                    Label(L10n.text(.actionRefresh), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.isCheckingMacIdentity)
                .accessibilityHint(L10n.text(.macIdentityDiagnosticHint))
                .accessibilityIdentifier("macIdentityRefresh")
            }
        } content: {
            HStack(alignment: .top, spacing: Space.s2) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(color(presentation.tone))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(presentation.stateLabel)
                        .font(TypeScale.label)
                        .foregroundStyle(textColor(presentation.tone))
                    Text(presentation.message)
                        .font(TypeScale.body)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityStatus)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("macIdentityStatus")

            ForEach(presentation.notes, id: \.self) { note in
                Text(note)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !presentation.details.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(presentation.details, id: \.self) { line in
                        Text(verbatim: line)
                            .font(TypeScale.monoSmall)
                            .foregroundStyle(Palette.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            actions(presentation)
            if let feedback = presentation.actionFeedback {
                Text(feedback.text)
                    .font(TypeScale.callout)
                    .foregroundStyle(feedback.isError ? Palette.redText : Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("macIdentityFeedback")
            }
            Text(L10n.text(.macIdentityRotationNote))
                .font(TypeScale.caption)
                .foregroundStyle(Palette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(L10n.text(.macIdentityTitle))
        .onChange(of: model.isCheckingMacIdentity) { _, _ in
            // §73 T-I4: "checking" and every new result are announced.
            AccessibilityNotification.Announcement(self.presentation.accessibilityStatus).post()
        }
        .alert(L10n.text(.macIdentityRegenerateConfirmTitle), isPresented: Binding(
            get: { model.showsMacIdentityRegenerateConfirmation },
            set: { if !$0 { model.cancelMacIdentityRegeneration() } }
        )) {
            Button(L10n.text(.actionCancel), role: .cancel) { model.cancelMacIdentityRegeneration() }
            Button(L10n.text(.macIdentityRegenerateConfirmAction)) { model.confirmMacIdentityRegeneration() }
        } message: {
            Text(L10n.text(.macIdentityRegenerateConfirmMessage))
        }
    }

    @ViewBuilder
    private func actions(_ presentation: MacIdentityPresentation) -> some View {
        if let regenerate = presentation.regenerate {
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s2) {
                    Button {
                        model.requestMacIdentityRegeneration()
                    } label: {
                        Label(L10n.text(.macIdentityActionRegenerate), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!regenerate.enabled || model.isRegeneratingMacIdentity)
                    .help(regenerate.blockedReason ?? L10n.text(.macIdentityActionRegenerateHint))
                    .accessibilityHint(regenerate.blockedReason ?? L10n.text(.macIdentityActionRegenerateHint))
                    .accessibilityIdentifier("macIdentityRegenerate")
                    if model.isRegeneratingMacIdentity { ProgressView().controlSize(.small) }
                }
                if let reason = regenerate.blockedReason {
                    Text(reason)
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.orangeText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // §74: for `unsupported` "Install Compatible Engine" is the primary action and the release page a secondary link
        // inside it; the plain page button stays for the other states that recommend a compatible engine.
        EngineInstallSection(model: model)
        if presentation.showsDownload, model.engineInstallAvailability == .hidden {
            VStack(alignment: .leading, spacing: Space.s1) {
                Button {
                    model.openCompatibleEngineDownload()
                } label: {
                    Label(L10n.text(.macIdentityActionDownload), systemImage: "safari")
                }
                .help(L10n.text(.macIdentityActionDownloadHint))
                .accessibilityHint(L10n.text(.macIdentityActionDownloadHint))
                .accessibilityIdentifier("macIdentityDownload")
                Text(verbatim: EngineDownloadLink.url.absoluteString)
                    .font(TypeScale.monoSmall)
                    .foregroundStyle(Palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(L10n.text(.macIdentityActionDownloadHint))
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(_ tone: MacIdentityPresentation.Tone) -> Color {
        switch tone {
        case .good: return Palette.green
        case .warning: return Palette.orange
        case .critical: return Palette.red
        case .neutral: return Palette.text3
        }
    }

    private func textColor(_ tone: MacIdentityPresentation.Tone) -> Color {
        switch tone {
        case .good: return Palette.greenText
        case .warning: return Palette.orangeText
        case .critical: return Palette.redText
        case .neutral: return Palette.text2
        }
    }
}

/// §73.6.2 Settings > Data > "Engine app": the path the identity check inspects, Change… (an `.app` only) and Use
/// Default; a refused choice shows its reason (nothing is stored).
struct EngineAppRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.macIdentitySettingsTitle)).font(TypeScale.body)
                Text(L10n.format(.macIdentitySettingsCaption, EnginePaths.defaultApp.path))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s2) {
                Text(verbatim: SettingsFormat.abbreviated(model.engineResolution.app.path, home: model.homeDirectory))
                    .font(TypeScale.mono)
                    .middleTruncated(model.engineResolution.app.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s2)
                    .frame(height: Metrics.control)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.inset))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.border, lineWidth: 1))
                    .accessibilityLabel(L10n.text(.macIdentitySettingsTitle))
                    .accessibilityValue(model.engineResolution.app.path)
                Button(L10n.text(.settingsChange)) { EngineAppPanel.choose(model) }
                    .fixedSize()
                    .accessibilityIdentifier("settingsEngineAppChange")
                Button(L10n.text(.macIdentitySettingsReset)) { model.setEngineApp(nil) }
                    .fixedSize()
                    .disabled(model.engineAppOverride == nil)
                    .accessibilityIdentifier("settingsEngineAppReset")
            }
            if let error = model.engineOverrideRejection ?? model.engineResolution.rejectedOverride {
                Text(L10n.format(.macIdentityOverrideRejected, MacIdentityPresentation.text(error)))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settingsEngineAppRejected")
            }
        }
        .padding(.vertical, Space.s2)
    }
}

/// Open panel for the engine app (application bundles only).
enum EngineAppPanel {
    @MainActor
    static func choose(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = EnginePaths.defaultApp.deletingLastPathComponent()
        panel.message = L10n.text(.macIdentitySettingsPanelMessage)
        if panel.runModal() == .OK, let url = panel.url {
            model.setEngineApp(url)
        }
    }
}

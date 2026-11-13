import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §64.4 "Diagnose Connection" in the server details: live step marks → verdict card → step list → engine log
/// matches → actions. Every text is localized; the verdict and each step read as label + value in VoiceOver.
struct ConnectionDiagnosisSection: View {
    @Bindable var model: AppModel
    let serverID: UUID

    @State private var copiedAppeal = false
    @State private var copiedReport = false
    @State private var unmasked = false
    @State private var confirmUnmasked = false
    @State private var saveError: String?

    private var session: AppModel.DiagnosisSession? { model.diagnosis(for: serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.text(.diagnoseTitle)).font(.headline)
                Spacer()
                if session?.isRunning == true {
                    Button(L10n.text(.actionAbort)) { model.cancelDiagnosis() }
                        .accessibilityIdentifier("diagnoseCancel")
                }
                Button {
                    restart()
                } label: {
                    Label(L10n.text(.diagnoseAction), systemImage: "stethoscope")
                }
                .keyboardShortcut("d", modifiers: .command)
                .help(L10n.text(.diagnoseHelp))
                .disabled(session?.isRunning == true)
                .accessibilityIdentifier("diagnoseStart")
            }
            if session == nil {
                Text(L10n.text(.diagnoseIntro))
                    .font(.caption)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let session {
                if let result = session.result {
                    verdictCard(result)
                } else if session.isRunning {
                    Label(L10n.text(.diagnoseRunning), systemImage: "hourglass")
                        .foregroundStyle(Palette.text2)
                        .accessibilityIdentifier("diagnoseRunning")
                } else if session.cancelled {
                    Label(L10n.text(.diagnoseCancelled), systemImage: "xmark.circle")
                        .foregroundStyle(Palette.orangeText)
                        .accessibilityIdentifier("diagnoseCancelled")
                }
                stepList(session)
                if let result = session.result {
                    engineLogSection(result.engineLog)
                    actions(result)
                }
            }
        }
        .accessibilityIdentifier("diagnoseSection")
        .alert(L10n.text(.diagnoseUnmaskedTitle), isPresented: $confirmUnmasked) {
            Button(L10n.text(.diagnoseUnmaskedConfirm), role: .destructive) { unmasked = true }
            Button(L10n.text(.actionCancel), role: .cancel) { unmasked = false }
        } message: {
            Text(L10n.text(.diagnoseUnmaskedMessage))
        }
    }

    private func restart() {
        copiedAppeal = false
        copiedReport = false
        saveError = nil
        model.startDiagnosis(for: serverID)
    }

    // MARK: Verdict card

    private func verdictCard(_ result: ConnectionDiagnosis) -> some View {
        let verdict = result.verdict
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: verdict.symbolName)
                .font(.title2)
                .foregroundStyle(verdict.level.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verdict.sentence)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(verdict.level.textColor)
                Text(verdict.advice)
                    .font(.callout)
                    .foregroundStyle(Palette.text)
                if result.verdictFromLog {
                    Text(L10n.format(.diagnoseLogOverride, result.probeVerdict.rawValue))
                        .font(.caption)
                        .foregroundStyle(Palette.text2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(verdict.level.tint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text(.diagnoseVerdict))
        .accessibilityValue(verdict.sentence + " " + verdict.advice)
        .accessibilityIdentifier("diagnoseVerdict")
    }

    // MARK: Steps

    private func stepList(_ session: AppModel.DiagnosisSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(.diagnoseSteps)).font(.caption.bold()).foregroundStyle(Palette.text2)
            ForEach(DiagnosisStepKind.allCases, id: \.self) { kind in
                stepRow(kind, step: session.steps.first { $0.step == kind }, running: session.current == kind,
                        waiting: session.isRunning)
            }
        }
    }

    private func stepRow(_ kind: DiagnosisStepKind, step: DiagnosisStep?, running: Bool, waiting: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if running {
                    ProgressView().controlSize(.small)
                } else if let step {
                    Text(verbatim: Self.mark(step.status))
                } else {
                    Image(systemName: "circle.dotted").foregroundStyle(Palette.text3)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.callout.weight(.medium))
                    if let step, step.status != .skipped {
                        Text(L10n.format(.diagnoseDuration, String(step.durationMs)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.text2)
                    }
                }
                if let step {
                    Text(verbatim: step.detail.isEmpty ? step.target : "\(step.target) · \(step.detail)")
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
        .accessibilityValue(Self.accessibilityValue(step: step, running: running, waiting: waiting))
        .accessibilityIdentifier("diagnoseStep-\(kind.rawValue)")
    }

    /// ✅ / ❌ / ⏭ (§64.4).
    static func mark(_ status: DiagnosisStepStatus) -> String {
        switch status {
        case .ok: return "✅"
        case .failed: return "❌"
        case .skipped: return "⏭"
        }
    }

    static func accessibilityValue(step: DiagnosisStep?, running: Bool, waiting: Bool) -> String {
        if running { return L10n.text(.diagnoseStatusRunning) }
        guard let step else { return L10n.text(.diagnoseStatusPending) }
        var parts = [step.status.label]
        if step.status != .skipped { parts.append(L10n.format(.diagnoseDuration, String(step.durationMs))) }
        parts.append(step.target)
        if !step.detail.isEmpty { parts.append(step.detail) }
        return parts.joined(separator: ", ")
    }

    // MARK: Engine log

    private func engineLogSection(_ log: EngineLogReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(.diagnoseLogTitle)).font(.caption.bold()).foregroundStyle(Palette.text2)
            switch log.status {
            case .missing:
                Label(L10n.text(.diagnoseLogMissing), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Palette.text2)
            case .unreadable:
                Label(L10n.format(.diagnoseLogUnreadable, log.fileName ?? ""), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Palette.orangeText)
            case .found where log.matches.isEmpty:
                Text(L10n.format(.diagnoseLogNoMatch, log.fileName ?? "")).font(.caption).foregroundStyle(Palette.text2)
            case .found:
                ForEach(Array(log.matches.enumerated()), id: \.offset) { _, match in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(match.pattern.explanation) · \(L10n.format(.diagnoseLogLine, String(match.matchedAt)))")
                            .font(.caption.weight(.medium))
                        Text(verbatim: match.line)
                            .font(.caption.monospaced())
                            .foregroundStyle(Palette.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("diagnoseLog")
    }

    // MARK: Actions

    private func actions(_ result: ConnectionDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let appeal = model.diagnosisAppealText(for: serverID) {
                    Button(L10n.text(copiedAppeal ? .actionCopied : .fixCopyAppeal)) {
                        Pasteboard.copy(appeal)
                        copiedAppeal = true
                    }
                    .accessibilityIdentifier("diagnoseCopyAppeal")
                }
                if let url = model.serverPageURL(for: serverID) {
                    Button(L10n.text(.fixOpenServerPage)) { NSWorkspace.shared.open(url) }
                        .accessibilityIdentifier("diagnoseServerPage")
                }
                Button(L10n.text(.actionRetry)) { restart() }
                    .accessibilityIdentifier("diagnoseRetry")
            }
            HStack(spacing: 8) {
                Button(L10n.text(copiedReport ? .actionCopied : .diagnoseCopy)) {
                    guard let report = model.diagnosisReport(for: serverID, masked: !unmasked) else { return }
                    Pasteboard.copy(report)
                    copiedReport = true
                }
                .accessibilityIdentifier("diagnoseCopy")
                Button(L10n.text(.diagnoseSave)) { save(result) }
                    .accessibilityIdentifier("diagnoseSave")
                Toggle(L10n.text(.diagnoseUnmasked), isOn: Binding(get: { unmasked }, set: { on in
                    if on { confirmUnmasked = true } else { unmasked = false }
                    copiedReport = false
                }))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("diagnoseUnmasked")
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(Palette.redText)
            }
        }
        .controlSize(.small)
    }

    private func save(_ result: ConnectionDiagnosis) {
        guard let report = model.diagnosisReport(for: serverID, masked: !unmasked) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = DiagnosisReport.fileName(host: result.host, date: result.startedAt)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = L10n.format(.diagnoseSaveFailed, error.localizedDescription)
        }
    }
}

import AppKit
import SwiftUI

/// §17.7 Fix sheet: IP ban (confirmed flow), CID ban (appeal), unreachable (recheck).
struct FixSheet: View {
    @Bindable var model: AppModel
    let initialSession: AppModel.FixSession

    @State private var copied = false

    /// Current session (the model changes while the sheet is open).
    private var session: AppModel.FixSession { model.fixSession ?? initialSession }

    private var entry: ServerEntry? { model.servers.first { $0.id == session.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch session.kind {
            case .ipBan: ipBanContent
            case .cidBan: cidBanContent
            case .unreachable: unreachableContent
            }
            if let note = session.note {
                Text(note).font(.callout).foregroundStyle(Palette.text2)
            }
        }
        .padding(20)
        .frame(width: 640)
        .interactiveDismissDisabled(model.isFixRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(TypeScale.headline)
            if let entry {
                Text(verbatim: "\(entry.label) · \(entry.host):\(String(entry.port))")
                    .font(.callout.monospaced())
                    .foregroundStyle(Palette.text2)
            }
        }
    }

    private var title: String {
        switch session.kind {
        case .ipBan: return L10n.text(.fixTitleIPBan)
        case .cidBan: return L10n.text(.fixTitleCIDBan)
        case .unreachable: return L10n.text(.fixTitleUnreachable)
        }
    }

    // MARK: IP ban (§17.2)

    @ViewBuilder
    private var ipBanContent: some View {
        switch session.phase {
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(L10n.text(.fixCurrentIP)) {
                    Text(model.publicIP ?? "—").font(.body.monospaced())
                }
                Text(L10n.text(.fixStepsTitle)).font(.headline)
                numbered([L10nKey.fixIPBanStep1, .fixIPBanStep2, .fixIPBanStep3, .fixIPBanStep4, .fixIPBanStep5]
                    .map(L10n.text))
                Text(L10n.text(.fixOutage)).font(.callout)
                Text(L10n.text(.fixRisk))
                    .font(.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel) { model.fixSession = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.actionStart)) { model.startIPFix() }
                    .keyboardShortcut(.defaultAction)
            }
        case .running(let progress):
            runningView(progress, cancellable: true)
        case .finished(let outcome, let at):
            ipResult(outcome, at: at)
        }
    }

    @ViewBuilder
    private func ipResult(_ outcome: IPFixOutcome, at date: Date) -> some View {
        Text(outcome.message + " · " + TimeText.format(date))
            .foregroundStyle(outcome.isSuccess ? Palette.greenText : Palette.redText)
            .fixedSize(horizontal: false, vertical: true)
        switch outcome {
        case .ipUnchanged(_, let routerURL):
            numbered(IPFixOutcome.unchangedNextSteps)
            HStack {
                if let routerURL {
                    Button(L10n.text(.fixOpenRouter)) { NSWorkspace.shared.open(routerURL) }
                }
                Spacer()
                retryAndClose
            }
        case .rangeBanned:
            Text(L10n.text(.fixSuggestionsTitle)).font(.headline)
            numbered(IPFixOutcome.rangeBannedSuggestions)
            HStack {
                appealButtons
                Spacer()
                retryAndClose
            }
        case .stillBanned:
            Text(IPFixOutcome.outOfRangeText).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text(.fixPossibleCausesTitle)).font(.headline)
            numbered(IPFixOutcome.stillBannedReasons)
            HStack {
                appealButtons
                Spacer()
                retryAndClose
            }
        default:
            HStack {
                serverPageButton
                Spacer()
                retryAndClose
            }
        }
    }

    private var retryAndClose: some View {
        HStack {
            Button(L10n.text(.actionRetry)) {
                model.fixSession?.phase = .ready
                model.fixSession?.note = nil
            }
            Button(L10n.text(.actionClose)) { model.fixSession = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: CID ban (§17.3)

    @ViewBuilder
    private var cidBanContent: some View {
        Text(L10n.text(.fixCIDBanExplanation))
            .fixedSize(horizontal: false, vertical: true)
        if let text = model.appealText(for: session.id) {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
        }
        if case .running(let progress) = session.phase {
            runningView(progress, cancellable: false)
        }
        HStack {
            appealButtons
            Button(L10n.text(.actionRecheck)) { model.recheckServer(session.id) }
                .disabled(model.isFixRunning)
            Spacer()
            Button(L10n.text(.actionClose)) { model.fixSession = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Unreachable (§17.4)

    @ViewBuilder
    private var unreachableContent: some View {
        Text(MessageCode.unreachable.text)
        if case .running(let progress) = session.phase {
            runningView(progress, cancellable: false)
        }
        HStack {
            Button(L10n.text(.actionRecheck)) { model.recheckServer(session.id) }
                .disabled(model.isFixRunning)
            serverPageButton
            Spacer()
            Button(L10n.text(.actionClose)) { model.fixSession = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Shared

    private var appealButtons: some View {
        HStack {
            Button(L10n.text(copied ? .actionCopied : .fixCopyAppeal)) {
                if let text = model.appealText(for: session.id) {
                    Pasteboard.copy(text)
                    copied = true
                }
            }
            serverPageButton
        }
    }

    @ViewBuilder
    private var serverPageButton: some View {
        if let url = model.serverPageURL(for: session.id) {
            Button(L10n.text(.fixOpenServerPage)) { NSWorkspace.shared.open(url) }
                .help(L10n.format(.fixContactAdmin, url.absoluteString))
        }
    }

    private func runningView(_ progress: FixProgress, cancellable: Bool) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progress.text)
            Spacer()
            if cancellable {
                Button(L10n.text(.actionAbort)) { model.cancelFix() }
            }
        }
    }

    private func numbered(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text(verbatim: "\(index + 1). \(item)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

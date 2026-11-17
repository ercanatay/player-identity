import SwiftUI

/// §67.3 launch summary: "<server>: N bans in the last 7 days" with "Details" (server details and trend) and
/// "Hide for Today". Shown at the top of the main window only while `model.launchSummary` is set.
struct LaunchSummaryCard: View {
    let summary: LaunchSummary
    let onDetails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(Palette.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.launchSummaryTitle))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.text2)
                Text(summary.text)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("launchSummaryText")
            }
            Spacer(minLength: Space.s2)
            Button(L10n.text(.launchSummaryDetails), action: onDetails)
                .accessibilityIdentifier("launchSummaryDetails")
            Button(L10n.text(.launchSummaryDismiss), action: onDismiss)
                .accessibilityIdentifier("launchSummaryDismiss")
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.redTint))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(.launchSummaryTitle))
        .accessibilityIdentifier("launchSummary")
    }
}

/// §67.2 "Launch Game with Logging": opens Xash3D with `-condebug` so the engine writes `qconsole.log` for the
/// diagnosis. Disabled (with the reason) while the game runs or when Xash3D is missing; then shows the result.
struct CondebugLaunchRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    model.launchGameWithLogging()
                } label: {
                    Label(L10n.text(.diagnoseCondebugAction), systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .help(L10n.text(.diagnoseCondebugHelp))
                .disabled(model.condebugBlocker != nil || model.condebugState == .waiting)
                .accessibilityHint(L10n.text(.diagnoseCondebugHelp))
                .accessibilityIdentifier("diagnoseCondebug")
                if model.condebugState == .waiting {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(Self.statusLines(blocker: model.condebugBlocker, state: model.condebugState).enumerated()),
                    id: \.offset) { _, line in
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(line.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("diagnoseCondebugStatus")
        }
    }

    /// The result of the last launch, then the reason the button is disabled (once); empty when there is nothing to say.
    static func statusLines(blocker: CondebugLaunchError?, state: CondebugState?) -> [(text: String, color: Color)] {
        var lines: [(text: String, color: Color)] = []
        switch state {
        case .waiting?: return [(L10n.text(.diagnoseCondebugWaiting), Palette.text2)]
        case .active(let file)?: lines.append((L10n.format(.diagnoseCondebugActive, file), Palette.greenText))
        case .noLog(let path)?: lines.append((L10n.format(.diagnoseCondebugNoLog, path), Palette.orangeText))
        case .failed(let error)?:
            lines.append((text(error), Palette.redText))
            if error == blocker { return lines }
        case nil: break
        }
        if let blocker { lines.append((text(blocker), Palette.text2)) }
        return lines
    }

    static func text(_ error: CondebugLaunchError) -> String {
        switch error {
        case .appNotFound: return L10n.text(.diagnoseCondebugAppMissing)
        case .gameRunning: return L10n.text(.diagnoseCondebugGameRunning)
        case .launchFailed(let reason): return L10n.format(.diagnoseCondebugFailed, reason)
        }
    }
}

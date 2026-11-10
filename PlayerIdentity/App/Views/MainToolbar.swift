import SwiftUI

/// Unified toolbar of the main window: title + status group (leading), Refresh and Save (trailing).
/// ⌘R / ⌘S are the app menu commands (`PlayerIdentityApp`); the buttons show them in their tooltips.
struct MainToolbarContent: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ToolbarStatusView(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            RefreshToolbarButton(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            SaveToolbarButton(model: model)
        }
    }
}

/// Refresh → Save (keyboard order), for layouts outside the window toolbar (evidence renders).
struct ToolbarActionButtons: View {
    @Bindable var model: AppModel

    var body: some View {
        RefreshToolbarButton(model: model)
        SaveToolbarButton(model: model)
    }
}

/// Icon-only Refresh; disabled while a refresh runs (⌘R in the menu still restarts it, §6).
struct RefreshToolbarButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button {
            model.refresh()
        } label: {
            Label(L10n.text(.actionRefresh), systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .disabled(model.isRefreshing)
        .help(L10n.text(.helpRefresh))
        .accessibilityIdentifier("toolbarRefresh")
    }
}

/// Icon-only Save (writes `profile.json` only, §5).
struct SaveToolbarButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button {
            model.save()
        } label: {
            Label(L10n.text(.actionSave), systemImage: "square.and.arrow.down")
        }
        .labelStyle(.iconOnly)
        .help(L10n.text(.helpSave))
        .accessibilityIdentifier("toolbarSave")
    }
}

/// Title, status icon + label + detail (truncates) + "·" + last check (never truncates), unsaved badge.
/// With reasons the group opens the "What to do?" popover (§14.2/2).
struct ToolbarStatusView: View {
    @Bindable var model: AppModel
    @State private var showsSuggestions = false

    var body: some View {
        HStack(spacing: Space.s2) {
            Text(L10n.text(.appWindowTitle))
                .font(TypeScale.headline)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, Space.s2)
                .accessibilityAddTraits(.isHeader)
            if hasReasons {
                Button { showsSuggestions = true } label: { status }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.text(.topbarWhatToDo))
                    .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) {
                        SuggestionsPopover(reasons: model.report?.reasons ?? [])
                    }
            } else {
                status
            }
            if model.hasUnsavedChanges {
                TintBadge(text: L10n.text(.topbarUnsaved), foreground: Palette.orangeText, background: Palette.orangeTint)
                    .accessibilityIdentifier("unsavedBadge")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var hasReasons: Bool { !(model.report?.reasons.isEmpty ?? true) }

    private var status: some View {
        let text = ToolbarStatusText(model: model)
        return HStack(spacing: Space.s2) {
            Group {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: text.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(text.symbolColor)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(text.label)
                .font(TypeScale.label)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .fixedSize()
            if !text.detail.isEmpty {
                Text(text.detail)
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Text(verbatim: "·")
                .foregroundStyle(Palette.text3)
                .accessibilityHidden(true)
            Text(text.lastCheck)
                .foregroundStyle(Palette.text2)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .font(TypeScale.body)
        .contentShape(Rectangle())
        .help(text.sentence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.label)
        .accessibilityValue(text.detail.isEmpty ? text.lastCheck : text.detail + ", " + text.lastCheck)
        .accessibilityIdentifier("toolbarStatus")
    }
}

/// Texts of the toolbar status group.
@MainActor
struct ToolbarStatusText {
    let symbol: String
    let symbolColor: Color
    let label: String
    let detail: String
    let lastCheck: String

    init(model: AppModel) {
        let report = model.report
        if model.isRefreshing {
            symbol = "arrow.clockwise"
            symbolColor = Palette.text2
            label = model.servers.isEmpty
                ? L10n.text(.topbarChecking)
                : L10n.format(.toolbarCheckingServers, String(model.servers.count))
        } else if let report {
            symbol = report.overall.symbolName
            symbolColor = report.overall.color
            label = report.overall.label
        } else {
            symbol = "info.circle.fill"
            symbolColor = Palette.text3
            label = L10n.text(.topbarNotChecked)
        }
        let reasons = report?.reasons ?? []
        switch reasons.count {
        case 0: detail = ""
        case 1: detail = reasons[0].message
        default: detail = L10n.format(.toolbarMoreReasons, reasons[0].message, String(reasons.count - 1))
        }
        lastCheck = L10n.format(.topbarLastCheck, TimeText.format(model.lastChecked))
    }

    /// Full sentence for the tooltip.
    var sentence: String {
        [label, detail, lastCheck].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

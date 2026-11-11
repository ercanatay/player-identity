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
        .disabled(model.isRefreshing || model.isRestoring)
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
        ViewThatFits(in: .horizontal) {
            ForEach(ToolbarStatusLayout.allCases, id: \.self) { layout in
                // Ideal width per variant: ViewThatFits then drops parts instead of squeezing the last-check text.
                content(layout).fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func content(_ layout: ToolbarStatusLayout) -> some View {
        HStack(spacing: Space.s2) {
            if layout.showsTitle {
                Text(L10n.text(.appWindowTitle))
                    .font(TypeScale.headline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, idealWidth: ToolbarStatusLayout.titleMaxWidth, maxWidth: ToolbarStatusLayout.titleMaxWidth, alignment: .leading)
                    .layoutPriority(-2)
                    .padding(.trailing, Space.s2)
                    .accessibilityAddTraits(.isHeader)
            }
            if hasReasons {
                Button { showsSuggestions = true } label: { status(layout) }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.text(.topbarWhatToDo))
                    .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) {
                        SuggestionsPopover(reasons: model.report?.reasons ?? [])
                    }
            } else {
                status(layout)
            }
            if layout.showsBadge, model.hasUnsavedChanges {
                TintBadge(text: L10n.text(.topbarUnsaved), foreground: Palette.orangeText, background: Palette.orangeTint)
                    .accessibilityIdentifier("unsavedBadge")
            }
        }
    }

    private var hasReasons: Bool { !(model.report?.reasons.isEmpty ?? true) }

    private func status(_ layout: ToolbarStatusLayout) -> some View {
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
            if layout.showsDetail, !text.detail.isEmpty {
                Text(text.detail)
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, idealWidth: ToolbarStatusLayout.detailIdealWidth, maxWidth: ToolbarStatusLayout.detailMaxWidth, alignment: .leading)
                    .layoutPriority(-1)
            }
            if layout.showsLastCheck {
                Text(verbatim: "·")
                    .foregroundStyle(Palette.text3)
                    .accessibilityHidden(true)
                Text(text.lastCheck)
                    .foregroundStyle(Palette.text2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
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

/// Width fallbacks of the status group, widest first (`ViewThatFits` picks the first that fits).
/// Full: title + icon/label/detail/last check + badge · titled: same without detail · compact: no title/detail (detail in tooltip) ·
/// narrow: icon + label only. The tooltip and accessibility texts always keep the full sentence.
enum ToolbarStatusLayout: CaseIterable, Hashable {
    case full, titled, compact, narrow

    static let titleMaxWidth: CGFloat = 180
    /// Cap of the detail text, so the full layout has a bounded ideal width and truncates instead of being skipped.
    static let detailMaxWidth: CGFloat = 240
    static let detailIdealWidth: CGFloat = 110

    var showsTitle: Bool { self == .full || self == .titled }
    var showsDetail: Bool { self == .full }
    var showsLastCheck: Bool { self != .narrow }
    var showsBadge: Bool { self != .narrow }
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

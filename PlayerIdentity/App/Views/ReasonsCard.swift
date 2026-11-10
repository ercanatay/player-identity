import AppKit
import SwiftUI

/// Reasons & suggestions card (§14.2): severity badge + message + hint per reason, an action where one exists,
/// and the All Actions popover (every server's actions + profile items).
struct ReasonsCard: View {
    @Bindable var model: AppModel
    let presenter: MainWindowPresenter

    @State private var showsActions = false

    var body: some View {
        ThemedCard(spacing: Space.s2) {
            CardHeader(symbol: "lightbulb", title: L10n.text(.reasonsTitle), count: reasons.map { String($0.count) }) {
                Button {
                    showsActions = true
                } label: {
                    Label(L10n.text(.reasonsAllActions), systemImage: "ellipsis.circle")
                }
                .disabled(model.report == nil)
                .accessibilityIdentifier("allActions")
                .popover(isPresented: $showsActions, arrowEdge: .top) {
                    AllActionsPopover(groups: actionGroups) { showsActions = false }
                }
            }
        } content: {
            if let reasons {
                if reasons.isEmpty {
                    messageRow(symbol: "checkmark.circle.fill", color: Palette.green, title: L10n.text(.reasonsEmptyTitle),
                               body: L10n.text(.reasonsEmptyBody))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(reasons.enumerated()), id: \.offset) { index, reason in
                            if index > 0 { ThemedDivider() }
                            ReasonRow(reason: reason, action: action(for: reason))
                        }
                    }
                }
            } else if model.isRefreshing {
                loading
            } else {
                messageRow(symbol: "info.circle.fill", color: Palette.text3, title: L10n.text(.topbarNotChecked),
                           body: L10n.text(.helpRefresh))
            }
        }
        .accessibilityLabel(L10n.text(.reasonsTitle))
    }

    private var reasons: [StatusReason]? { model.report?.reasons }

    private var loading: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s2) {
                ProgressView().controlSize(.small)
                Text(L10n.text(.reasonsLoading)).foregroundStyle(Palette.text2)
                Spacer(minLength: 0)
            }
            .frame(height: Metrics.reasonRow)
            ForEach([0.62, 0.54], id: \.self) { fraction in
                ThemedDivider()
                HStack(spacing: Space.s3) {
                    Circle().fill(Palette.skeleton).frame(width: 18, height: 18)
                    GeometryReader { proxy in
                        VStack(alignment: .leading, spacing: Space.s2) {
                            SkeletonBar(width: proxy.size.width * fraction)
                            SkeletonBar(width: proxy.size.width * (fraction - 0.18), height: 9)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: Metrics.reasonRow)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reasonsLoading")
    }

    private func messageRow(symbol: String, color: Color, title: String, body: String) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.label)
                Text(body).font(TypeScale.callout).foregroundStyle(Palette.text2)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Metrics.reasonRow)
        .accessibilityElement(children: .combine)
    }

    /// Reason → the action that addresses it (ban/unreachable → Fix… of the first matching server).
    private func action(for reason: StatusReason) -> ReasonRow.Action? {
        switch reason.code {
        case .ipBanned, .cidBanned, .unreachable:
            guard let entry = model.servers.first(where: { $0.banCheck?.status.messageCode == reason.code }),
                  model.fixKind(for: entry.id) != nil else { return nil }
            return ReasonRow.Action(title: L10n.text(.actionFix) + "…", help: L10n.format(.fixShowFor, entry.label)) {
                model.beginFix(entry.id)
            }
        case .snapshotMissing, .snapshotCorrupt:
            return ReasonRow.Action(title: L10n.text(.actionSave), help: L10n.text(.helpSave)) { model.save() }
        case .publicIPFailed:
            return ReasonRow.Action(title: L10n.text(.actionRetry), help: L10n.text(.helpRefresh)) { model.refresh() }
        default:
            return nil
        }
    }

    /// Server groups (same items as each row's Fix…) + profile items.
    private var actionGroups: [AllActionsPopover.ActionGroup] {
        var groups = model.servers.compactMap { entry -> AllActionsPopover.ActionGroup? in
            let actions = ServerActionList.actions(for: entry, model: model, details: presenter.details)
            return actions.isEmpty ? nil : AllActionsPopover.ActionGroup(id: entry.id.uuidString, title: entry.label, actions: actions)
        }
        var profile: [ServerAction] = []
        if case .success(let identity)? = model.identity {
            let url = identity.source.url
            profile.append(ServerAction(id: "revealIdentity", symbol: "folder",
                                        title: L10n.text(.profileShowInFinder) + " · " + url.lastPathComponent) {
                Finder.reveal(url)
            })
        }
        if let reasons = model.report?.reasons, !reasons.isEmpty {
            profile.append(ServerAction(id: "copySuggestions", symbol: "doc.on.doc", title: L10n.text(.reasonsCopySuggestions)) {
                Pasteboard.copy(SuggestionText.plainText(for: reasons))
            })
        }
        if !profile.isEmpty {
            groups.append(AllActionsPopover.ActionGroup(id: "profile", title: L10n.text(.profileTitle), actions: profile))
        }
        return groups
    }
}

/// Grid 20 | flex | auto, min height 52: icon 18 + severity badge + message / hint (1 line each, tooltips) + action.
struct ReasonRow: View {
    struct Action {
        let title: String
        let help: String
        let run: () -> Void
    }

    let reason: StatusReason
    let action: Action?

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    TintBadge(text: severity, foreground: textColor, background: tint)
                    Text(reason.message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(reason.message)
                }
                Text(reason.code.suggestion)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason.code.suggestion)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format(.a11yReason, reason.severity.label, reason.message))
            .accessibilityValue(reason.code.suggestion)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
                    .fixedSize()
                    .help(action.help)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: Metrics.reasonRow)
    }

    private var isBan: Bool { reason.code == .ipBanned || reason.code == .cidBanned }

    private var severity: String {
        if isBan { return L10n.text(.severityBan) }
        switch reason.severity {
        case .red: return L10n.text(.severityError)
        case .orange: return L10n.text(.severityRisk)
        case .green: return L10n.text(.severityInfo)
        }
    }

    private var symbol: String {
        reason.severity == .green ? "info.circle.fill" : reason.severity.symbolName
    }

    private var iconColor: Color { reason.severity == .green ? Palette.accent : reason.severity.color }
    private var textColor: Color { reason.severity == .green ? Palette.accentText : reason.severity.textColor }
    private var tint: Color { reason.severity == .green ? Palette.accentTint : reason.severity.tint }
}

/// All Actions popover (296 wide): menu-like list grouped by server / profile.
struct AllActionsPopover: View {
    struct ActionGroup: Identifiable {
        let id: String
        let title: String
        let actions: [ServerAction]
    }

    let groups: [ActionGroup]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text(L10n.text(.reasonsNoActions))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .padding(Space.s2)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { ThemedDivider().padding(.vertical, 2) }
                PopoverGroupTitle(title: group.title)
                ForEach(group.actions) { action in
                    PopoverActionRow(symbol: action.symbol, title: action.title) {
                        dismiss()
                        action.run()
                    }
                }
            }
        }
        .padding(6)
        .frame(width: Metrics.actionsPopover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(.reasonsAllActions))
    }
}

/// "What to do?" popover (§14.2/2): numbered list of suggestions for the reasons + "Copy".
struct SuggestionsPopover: View {
    let reasons: [StatusReason]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(.topbarWhatToDo)).font(TypeScale.headline)
            ForEach(Array(SuggestionText.numberedLines(for: reasons).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if copied {
                    Text(L10n.text(.actionCopied)).font(TypeScale.callout).foregroundStyle(Palette.text2)
                }
                Button(L10n.text(.actionCopy)) {
                    Pasteboard.copy(SuggestionText.plainText(for: reasons))
                    copied = true
                }
            }
        }
        .font(TypeScale.body)
        .padding(Space.s4)
        .frame(width: 440)
    }
}

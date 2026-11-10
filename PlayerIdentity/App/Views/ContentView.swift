import AppKit
import SwiftUI

/// Single-window UI (§8), main window redesign: unified toolbar, optional banners, then a scroll view with
/// [Profile | Network], Servers and Reasons cards on the window background.
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var sheet: SheetMode?

    enum SheetMode: Identifiable {
        case add
        case edit(UUID)
        /// §32 notes and appeal.
        case details(UUID)
        /// §33 share card preview.
        case shareCard(UUID)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let id): return "edit-" + id.uuidString
            case .details(let id): return "details-" + id.uuidString
            case .shareCard(let id): return "share-" + id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MainWindowBanners(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    TopRowLayout {
                        ProfileCard(model: model)
                        NetworkCard(model: model)
                    }
                    ServersCard(model: model, presenter: presenter)
                    ReasonsCard(model: model, presenter: presenter)
                }
                .padding(Space.s4)
            }
            .background(Palette.window)
        }
        .background(Palette.window)
        .foregroundStyle(Palette.text)
        .font(TypeScale.body)
        .frame(minWidth: 720, minHeight: 520)
        .toolbar { MainToolbarContent(model: model) }
        .task {
            guard !AppModel.isRunningTests else { return }
            model.refresh()
            model.checkForUpdates()
            model.updates.startPeriodicChecks()
            model.activateBackgroundTasks()
        }
        .sheet(item: Binding(
            get: { model.updates.pendingInstall?.origin == .banner ? model.updates.pendingInstall : nil },
            set: { if $0 == nil { model.updates.cancelRequest() } })
        ) { request in
            InstallConfirmSheet(updates: model.updates, request: request)
        }
        .sheet(item: $model.applyPreview) { preview in
            ApplyPreviewSheet(preview: preview, onWrite: { model.confirmApply() }, onCancel: model.cancelApply)
        }
        .sheet(item: $sheet) { mode in
            sheetView(mode)
        }
        .sheet(item: $model.fixSession) { session in
            FixSheet(model: model, initialSession: session)
        }
        // §29: the game is running → confirm before replacing it; errors of "Join Game".
        .alert(L10n.text(.gameJoinConfirmTitle), isPresented: Binding(
            get: { model.pendingJoin != nil },
            set: { if !$0 { model.cancelJoin() } }
        )) {
            Button(L10n.text(.actionCancel), role: .cancel) { model.cancelJoin() }
            Button(L10n.text(.gameJoinConfirmAction)) { model.confirmJoin() }
        } message: {
            Text(L10n.format(.gameJoinConfirmMessage, model.pendingJoin?.label ?? ""))
        }
        .alert(L10n.text(.gameErrorTitle), isPresented: Binding(
            get: { model.joinError != nil && model.joinError != .cancelled },
            set: { if !$0 { model.joinError = nil } }
        )) {
            Button(L10n.text(.actionOK), role: .cancel) {}
        } message: {
            Text(model.joinError.map(GameLaunchText.error) ?? "")
        }
        .alert(L10n.text(.alertSaveFailedTitle), isPresented: Binding(
            get: { model.saveErrorMessage != nil },
            set: { if !$0 { model.saveErrorMessage = nil } }
        )) {
            Button(L10n.text(.actionOK), role: .cancel) {}
        } message: {
            Text(model.saveErrorMessage ?? "")
        }
    }

    /// Opens the window-level sheets and windows for the cards.
    private var presenter: MainWindowPresenter {
        MainWindowPresenter(
            addServer: { sheet = .add },
            editServer: { sheet = .edit($0) },
            details: { sheet = .details($0) },
            shareCard: { sheet = .shareCard($0) },
            openBanMatrix: { openWindow(id: "banMatrix") })
    }

    @ViewBuilder
    private func sheetView(_ mode: SheetMode) -> some View {
        switch mode {
        case .add:
            ServerFormSheet(title: L10n.text(.serverAdd), confirmTitle: L10n.text(.actionAdd), groups: model.serverGroups,
                            onConfirm: { draft in
                                model.addServer(draft)
                                sheet = nil
                            },
                            onCancel: { sheet = nil })
        case .edit(let id):
            if let entry = model.servers.first(where: { $0.id == id }) {
                ServerFormSheet(title: L10n.text(.serverEditTitle), confirmTitle: L10n.text(.actionOK), groups: model.serverGroups,
                                draft: ServerDraft(entry: entry),
                                onConfirm: { draft in
                                    model.updateServer(id: id, with: draft)
                                    sheet = nil
                                },
                                onCancel: { sheet = nil })
            }
        case .details(let id):
            ServerDetailSheet(model: model, serverID: id, onClose: { sheet = nil })
        case .shareCard(let id):
            ShareCardSheet(model: model, serverID: id, onClose: { sheet = nil })
        }
    }
}

/// Callbacks the cards use to open window-level sheets (the cards hold no sheet state themselves).
struct MainWindowPresenter {
    var addServer: () -> Void = {}
    var editServer: (UUID) -> Void = { _ in }
    var details: (UUID) -> Void = { _ in }
    var shareCard: (UUID) -> Void = { _ in }
    var openBanMatrix: () -> Void = {}
}

/// Update / restore banners: full-width strips under the toolbar, outside the scroll view (they push content down).
struct MainWindowBanners: View {
    @Bindable var model: AppModel

    var body: some View {
        if let backup = model.updates.restoreOffer {
            RestoreBanner(updates: model.updates, backup: backup)
            ThemedDivider()
        }
        if let update = model.availableUpdate {
            UpdateBanner(updates: model.updates, update: update)
            ThemedDivider()
        }
    }
}

/// [Profile | Network] row: columns 1.38 : 1 with equal heights; stacks below the 820 pt window breakpoint.
struct TopRowLayout: Layout {
    var spacing: CGFloat = Space.s4

    /// Content width (window minus the 2 × 16 pt inset) below which the cards stack.
    static let stackWidth = Metrics.stackedBreakpoint - 2 * Space.s4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.stackWidth
        let frames = layout(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, layout(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// Profile and network column widths (1.38 : 1); `nil` = stacked (content narrower than the breakpoint).
    static func columnWidths(contentWidth width: CGFloat, spacing: CGFloat = Space.s4) -> (CGFloat, CGFloat)? {
        guard width >= stackWidth else { return nil }
        let available = max(width - spacing, 0)
        let leading = (available * Metrics.profileShare / (Metrics.profileShare + 1)).rounded(.down)
        return (leading, available - leading)
    }

    private func layout(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else {
            var y: CGFloat = 0
            return subviews.map { subview in
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                defer { y += height + spacing }
                return CGRect(x: 0, y: y, width: width, height: height)
            }
        }
        guard let (leading, trailing) = Self.columnWidths(contentWidth: width, spacing: spacing) else {
            let first = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let second = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            return [CGRect(x: 0, y: 0, width: width, height: first),
                    CGRect(x: 0, y: first + spacing, width: width, height: second)]
        }
        let height = max(subviews[0].sizeThatFits(ProposedViewSize(width: leading, height: nil)).height,
                         subviews[1].sizeThatFits(ProposedViewSize(width: trailing, height: nil)).height)
        return [CGRect(x: 0, y: 0, width: leading, height: height),
                CGRect(x: leading + spacing, y: 0, width: trailing, height: height)]
    }
}

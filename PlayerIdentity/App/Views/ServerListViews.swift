import AppKit
import SwiftUI

/// Row callbacks; the row itself holds no model (§8, §29–§33).
struct ServerRowActions {
    var copy: (String) -> Void = { _ in }
    var edit: () -> Void = {}
    var delete: () -> Void = {}
    /// §17.1: only on `ipBanned` / `cidBanned` / `unreachable` rows; the inline popover lists `fixActions`.
    var fix: (() -> Void)?
    var fixActions: [ServerAction] = []
    /// §29: `nil` = Xash3D is not installed (the action is hidden).
    var join: (() -> Void)?
    var toggleFavorite: () -> Void = {}
    /// §42 🔔 watch switch.
    var toggleWatch: () -> Void = {}
    /// §31 ▲/▼; `nil` = the row cannot move in that direction.
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    /// §32 notes and appeal; §33 share card.
    var details: () -> Void = {}
    var shareCard: () -> Void = {}
}

/// One entry of a Fix… / All Actions popover.
struct ServerAction: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let run: () -> Void
}

/// The actions of one server for the inline Fix… popover; All Actions lists the same items per server.
@MainActor
enum ServerActionList {
    static func actions(for entry: ServerEntry, model: AppModel, details: @escaping (UUID) -> Void) -> [ServerAction] {
        guard let kind = model.fixKind(for: entry.id) else { return [] }
        let id = entry.id
        var actions: [ServerAction] = []
        let primary: (symbol: String, key: L10nKey) = switch kind {
        case .ipBan: ("wrench.and.screwdriver", .fixTitleIPBan)
        case .cidBan: ("key", .fixTitleCIDBan)
        case .unreachable: ("waveform.path.ecg", .fixTitleUnreachable)
        }
        actions.append(ServerAction(id: "fix", symbol: primary.symbol, title: L10n.text(primary.key) + "…") {
            model.beginFix(id)
        })
        if kind != .unreachable, let text = model.appealText(for: id) {
            actions.append(ServerAction(id: "appeal", symbol: "doc.on.doc", title: L10n.text(.fixCopyAppeal)) {
                Pasteboard.copy(text)
            })
        }
        if let url = model.serverPageURL(for: id) {
            actions.append(ServerAction(id: "page", symbol: "arrow.up.right.square", title: L10n.text(.fixOpenServerPage)) {
                NSWorkspace.shared.open(url)
            })
        }
        if model.banListURL(for: id) != nil {
            actions.append(ServerAction(id: "banList", symbol: "magnifyingglass", title: L10n.text(.banListSearch)) {
                model.openBanList(for: id)
            })
        }
        if model.banCheckEnabled {
            actions.append(ServerAction(id: "recheck", symbol: "arrow.clockwise", title: L10n.text(.actionRecheck)) {
                model.recheckServer(id)
            })
        }
        actions.append(ServerAction(id: "details", symbol: "note.text", title: L10n.text(.serverDetails)) {
            details(id)
        })
        return actions
    }
}

/// View-only list options (not stored): search text, grouping, unresolved hosts.
struct ServerListOptions: Equatable {
    var search = ""
    var groupBySection = true
    var hideUnresolved = false

    var isActive: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty || hideUnresolved }
}

// MARK: - Servers card

/// Servers card: header (count, chips, search, filter options, ban matrix, Add Server), notices, table.
struct ServersCard: View {
    @Bindable var model: AppModel
    let presenter: MainWindowPresenter
    /// Offscreen renders only: draw this focus (an offscreen window has no real keyboard focus).
    var previewFocus: ServerListFocus?

    @State private var options = ServerListOptions()
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsFilters = false
    @State private var collapsed: Set<String> = []
    @State private var copiedKey: String?
    /// Width of the table; below `Metrics.Column.compactTable` the map · players · ping column folds into the tooltip.
    @State private var tableWidth: CGFloat = 900
    /// §55 keyboard: ⌘F focuses the search field; the table takes ↑/↓ (selection), Return (details) and Esc.
    @FocusState private var focus: ServerListFocus?
    @State private var selection: UUID?

    init(model: AppModel, presenter: MainWindowPresenter, previewFocus: ServerListFocus? = nil,
         previewSelection: UUID? = nil) {
        self.model = model
        self.presenter = presenter
        self.previewFocus = previewFocus
        _selection = State(initialValue: previewSelection)
    }

    private var shownFocus: ServerListFocus? { focus ?? previewFocus }

    enum ServerListFocus: Hashable {
        case search
        case table
    }

    var body: some View {
        ThemedCard {
            header
        } content: {
            notices
            if model.servers.isEmpty {
                StateBlock(symbol: "tray", symbolColor: Palette.text3, title: L10n.text(.serversEmptyTitle),
                           message: L10n.text(.serversEmptyBody), minHeight: 240, dashed: true) {
                    addServerButton(prominent: true)
                }
                .accessibilityIdentifier("serversEmpty")
            } else {
                table
            }
        }
        .accessibilityLabel(L10n.text(.serversTitle))
        .background { findShortcut }
        // §60: the menu bar "Copy CID" follows the selected row.
        .onChange(of: selection) { model.selectedServerID = selection }
    }

    /// ⌘F anywhere in the main window (in-window shortcuts are handled before the Edit menu's Find).
    private var findShortcut: some View {
        Button(L10n.text(.a11yFindServers)) { focus = .search }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(model.servers.isEmpty)
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s2) {
                titleGroup
                chips
                Spacer(minLength: Space.s2)
                tools
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    titleGroup
                    Spacer(minLength: Space.s2)
                    tools
                }
                chips
            }
        }
    }

    private var titleGroup: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "server.rack")
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(L10n.text(.serversTitle))
                .font(TypeScale.label)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: String(model.servers.count))
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text3)
                .monospacedDigit()
                .padding(.trailing, Space.s2)
        }
        .fixedSize()
    }

    private var chips: some View {
        HStack(spacing: 6) {
            FilterChip(kind: .banned, count: counts.banned, isOn: $model.serverFilter.onlyBanned)
                .accessibilityIdentifier("filterBanned")
            FilterChip(kind: .favorites, count: counts.favorites, isOn: $model.serverFilter.onlyFavorites)
                .accessibilityIdentifier("filterFavorites")
            FilterChip(kind: .watched, count: counts.watched, isOn: $model.serverFilter.onlyWatched)
                .accessibilityIdentifier("filterWatched")
        }
        .disabled(model.servers.isEmpty)
        .opacity(model.servers.isEmpty ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(.serversFilterOptions))
    }

    private var tools: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                    .accessibilityHidden(true)
                TextField(L10n.text(.serversSearch), text: $options.search)
                    .textFieldStyle(.plain)
                    .font(TypeScale.callout)
                    .focused($focus, equals: .search)
                    .help(L10n.text(.helpSearch))
                    .accessibilityIdentifier("serverSearch")
            }
            .padding(.horizontal, Space.s2)
            .frame(width: Metrics.searchField, height: Metrics.control)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.controlBorder, lineWidth: 1))
            .focusRing(shownFocus == .search, cornerRadius: Radius.control)
            .disabled(model.servers.isEmpty)
            .opacity(model.servers.isEmpty ? 0.45 : 1)

            IconButton(symbol: "line.3.horizontal.decrease.circle", label: L10n.text(.serversFilterOptions),
                       size: CGSize(width: 28, height: Metrics.control), symbolSize: 15,
                       tint: filtersActive || showsFilters ? Palette.accentText : Palette.text2) {
                showsFilters.toggle()
            }
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(filtersActive || showsFilters ? Palette.accentTint : .clear))
            .accessibilityAddTraits(filtersActive ? .isSelected : [])
            .popover(isPresented: $showsFilters, arrowEdge: .bottom) { filtersPopover }
            .disabled(model.servers.isEmpty)

            // §38 ban matrix window
            IconButton(symbol: "tablecells", label: L10n.text(.banMatrixOpen),
                       size: CGSize(width: 28, height: Metrics.control), symbolSize: 13, action: presenter.openBanMatrix)
                .accessibilityIdentifier("openBanMatrix")

            addServerButton(prominent: false)
        }
        .fixedSize()
    }

    /// `+` menu: the plain add form (also the primary click) and the §50 URL / bulk import.
    private func addServerButton(prominent: Bool) -> some View {
        Group {
            if prominent {
                Menu {
                    addServerMenuItems
                } label: {
                    Label(L10n.text(.serverAdd), systemImage: "plus")
                } primaryAction: {
                    presenter.addServer()
                }
                .prominentButton()
            } else {
                Menu {
                    addServerMenuItems
                } label: {
                    Label(L10n.text(.serverAdd), systemImage: "plus")
                } primaryAction: {
                    presenter.addServer()
                }
            }
        }
        .fixedSize()
        .accessibilityIdentifier("addServer")
    }

    @ViewBuilder
    private var addServerMenuItems: some View {
        Button(L10n.text(.serverAdd), action: presenter.addServer)
        Button(L10n.text(.serverImportMenu), action: presenter.importServers)
            .accessibilityIdentifier("importServers")
    }

    // MARK: Filters popover

    private var filtersPopover: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(L10n.text(.serversShowOnly))
                .font(TypeScale.captionStrong)
                .foregroundStyle(Palette.text2)
            filterToggle(.banned, counts.banned, $model.serverFilter.onlyBanned)
            filterToggle(.favorites, counts.favorites, $model.serverFilter.onlyFavorites)
            filterToggle(.watched, counts.watched, $model.serverFilter.onlyWatched)
            ThemedDivider().padding(.vertical, 2)
            HStack(spacing: Space.s2) {
                Text(L10n.text(.serversGroupBy))
                Spacer(minLength: Space.s2)
                Picker(L10n.text(.serversGroupBy), selection: $options.groupBySection) {
                    Text(L10n.text(.serverFormGroup)).tag(true)
                    Text(L10n.text(.serversGroupNone)).tag(false)
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .frame(height: Metrics.control)
            Toggle(L10n.text(.serversHideUnresolved), isOn: $options.hideUnresolved)
                .toggleStyle(.checkbox)
            ThemedDivider().padding(.vertical, 2)
            Button(L10n.text(.serversClearFilters), action: clearFilters)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accentText)
                .disabled(!filtersActive)
        }
        .font(TypeScale.body)
        .padding(Space.s3)
        .frame(width: Metrics.filtersPopover)
    }

    private func filterToggle(_ kind: ServerFilterChipKind, _ count: Int, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: Space.s2) {
            Toggle(kind.title, isOn: isOn)
                .toggleStyle(.checkbox)
                .accessibilityValue(AccessibilityText.filterChip(kind, count: count, isOn: isOn.wrappedValue).value)
            Spacer(minLength: Space.s2)
            Text(verbatim: String(count))
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text3)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .frame(height: Metrics.minTarget)
    }

    private var filtersActive: Bool { model.serverFilter != ServerListFilter() || options.isActive }

    private func clearFilters() {
        model.serverFilter = ServerListFilter()
        options = ServerListOptions(groupBySection: options.groupBySection)
    }

    private var counts: (banned: Int, favorites: Int, watched: Int) {
        let banned = model.servers.filter { ServerListFilter(onlyBanned: true).matches($0) }.count
        return (banned, model.servers.filter(\.favorite).count, model.servers.filter(\.watch).count)
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if !model.banCheckEnabled {
            NoticeBox(symbol: "shield.slash", symbolColor: Palette.text2, text: L10n.text(.serversChecksOff),
                      textColor: Palette.text2, background: Palette.inset, border: Palette.border) {
                SettingsLink { Text(L10n.text(.serversOpenSettings)) }
                    .controlSize(.small)
            }
            .accessibilityIdentifier("banChecksOff")
        } else if model.lastChecked != nil, model.publicIP == nil, !model.isRefreshing, !model.servers.isEmpty {
            NoticeBox(symbol: "exclamationmark.triangle.fill", symbolColor: Palette.orangeText,
                      text: MessageCode.publicIPFailed.text, background: Palette.orangeTint) {
                Button(L10n.text(.actionRetry)) { model.refresh() }
                    .controlSize(.small)
            }
            .accessibilityIdentifier("serversCheckFailed")
        }
        if model.hasWatchedServers, !model.menuBarEnabled {
            // §42: no background checks without the menu bar mode.
            Label(L10n.text(.watchBackgroundNote), systemImage: "info.circle")
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("watchBackgroundNote")
        }
    }

    // MARK: Table

    private var displaySections: [ServerSection] {
        let sections = model.serverSections(filter: model.serverFilter).compactMap { section -> ServerSection? in
            let rows = section.servers.filter(matchesOptions)
            return rows.isEmpty ? nil : ServerSection(group: section.group, servers: rows)
        }
        guard options.groupBySection, !model.serverGroups.isEmpty else {
            let all = sections.flatMap(\.servers)
            return all.isEmpty ? [] : [ServerSection(group: nil, servers: all)]
        }
        return sections
    }

    private var showsGroupHeaders: Bool { options.groupBySection && !model.serverGroups.isEmpty }

    private func matchesOptions(_ entry: ServerEntry) -> Bool {
        let status = model.rowStatus(entry.id)
        if options.hideUnresolved, status?.resolutionFailure != nil { return false }
        let query = options.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let fields = [entry.label, entry.host, status?.resolvedIP, status?.currentCID, entry.banCheck?.info?.name]
        return fields.contains { $0?.lowercased().contains(query) ?? false }
    }

    private var table: some View {
        let sections = displaySections
        let showsInfo = tableWidth >= Metrics.Column.compactTable
        return VStack(spacing: 0) {
            ServerTableHeader(showsInfo: showsInfo)
            if sections.isEmpty {
                VStack(spacing: Space.s2) {
                    Text(L10n.text(.serversFilterEmpty)).foregroundStyle(Palette.text2)
                    Button(L10n.text(.serversClearFilters), action: clearFilters)
                }
                .frame(maxWidth: .infinity, minHeight: 144)
                .accessibilityIdentifier("serversNoMatch")
            }
            ForEach(sections, id: \.group) { section in
                let key = section.group ?? ""
                if showsGroupHeaders {
                    GroupHeaderRow(title: section.group ?? L10n.text(.serversOther), count: section.servers.count,
                                   isExpanded: !collapsed.contains(key)) {
                        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
                    }
                }
                if !showsGroupHeaders || !collapsed.contains(key) {
                    ForEach(section.servers) { entry in
                        ServerRowView(entry: entry,
                                      status: model.rowStatus(entry.id),
                                      ban: BanCellContent.make(check: entry.banCheck, status: model.rowStatus(entry.id),
                                                               host: entry.host, isChecking: model.isRefreshing,
                                                               checksEnabled: model.banCheckEnabled),
                                      copied: copiedKey == entry.id.uuidString,
                                      followUpDue: model.isFollowUpDue(entry),
                                      showsInfo: showsInfo,
                                      isSelected: selection == entry.id,
                                      actions: rowActions(entry))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner)
            .strokeBorder(contrast == .increased ? Palette.borderStrong : Palette.border, lineWidth: 1))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { tableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in tableWidth = width }
            }
        }
        // §55: the table is one Tab stop (like a text field, whatever the Keyboard navigation setting);
        // ↑/↓/Home/End select, Return opens the details, Esc clears.
        .focusable(true, interactions: .edit)
        .focused($focus, equals: .table)
        .focusEffectDisabled()
        .focusRing(shownFocus == .table, cornerRadius: Radius.inner)
        .onKeyPress(keys: [.upArrow, .downArrow, .home, .end, .return, .escape]) { press in
            handleTableKey(press.key)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(.serversTitle))
        .accessibilityHint(L10n.text(.a11yServerTableHint))
    }

    /// Rows in display order without collapsed groups (what ↑/↓ walks through).
    private var visibleRowIDs: [UUID] {
        displaySections.flatMap { section -> [UUID] in
            if showsGroupHeaders, collapsed.contains(section.group ?? "") { return [] }
            return section.servers.map(\.id)
        }
    }

    private func handleTableKey(_ key: KeyEquivalent) -> KeyPress.Result {
        let mapped: MainWindowKey
        switch key {
        case .upArrow: mapped = .upArrow
        case .downArrow: mapped = .downArrow
        case .home: mapped = .home
        case .end: mapped = .end
        case .return: mapped = .returnKey
        case .escape: mapped = .escape
        default: return .ignored
        }
        switch MainWindowKeyboard.handle(mapped, selection: selection, rows: visibleRowIDs) {
        case .focusSearch: focus = .search
        case .select(let id): selection = id
        case .open(let id): presenter.details(id)
        case .clearSelection: selection = nil
        case .ignored: return .ignored
        }
        return .handled
    }

    private func rowActions(_ entry: ServerEntry) -> ServerRowActions {
        let id = entry.id
        return ServerRowActions(
            copy: { copy($0, key: id.uuidString) },
            edit: { presenter.editServer(id) },
            delete: { model.deleteServer(id: id) },
            fix: model.fixKind(for: id) == nil ? nil : { model.beginFix(id) },
            fixActions: ServerActionList.actions(for: entry, model: model, details: presenter.details),
            join: model.isGameAppInstalled ? { model.joinGame(id) } : nil,
            toggleFavorite: { model.setFavorite(!entry.favorite, for: id) },
            toggleWatch: { model.setWatch(!entry.watch, for: id) },
            moveUp: model.canMoveServer(id: id, .up) ? { model.moveServer(id: id, .up) } : nil,
            moveDown: model.canMoveServer(id: id, .down) ? { model.moveServer(id: id, .down) } : nil,
            details: { presenter.details(id) },
            shareCard: { presenter.shareCard(id) })
    }

    private func copy(_ text: String, key: String) {
        Pasteboard.copy(text)
        copiedKey = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKey == key { copiedKey = nil }
        }
    }
}

// MARK: - Table pieces

/// Column header row (28 pt, 11 semibold secondary, sentence case).
private struct ServerTableHeader: View {
    var showsInfo = true

    var body: some View {
        HStack(spacing: Metrics.Column.gap) {
            Color.clear.frame(width: Metrics.Column.marks)
            Text(L10n.text(.banMatrixServer)).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text(.serversColumnCID)).frame(width: Metrics.Column.cid, alignment: .leading)
            if showsInfo {
                Text(L10n.text(.serversColumnInfo))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(L10n.text(.serversColumnInfo))
                    .frame(width: Metrics.Column.info, alignment: .leading)
            }
            Text(L10n.text(.serversColumnBan)).frame(width: Metrics.Column.ban, alignment: .leading)
            Color.clear.frame(width: Metrics.Column.menu)
        }
        .font(TypeScale.captionStrong)
        .foregroundStyle(Palette.text2)
        .lineLimit(1)
        .padding(.horizontal, Space.s2)
        .frame(height: Metrics.groupHeader)
        .overlay(alignment: .bottom) { ThemedDivider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Group header row with a disclosure chevron and the row count.
private struct GroupHeaderRow: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .accessibilityHidden(true)
                Text(title)
                Text(verbatim: String(count))
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.text3)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(TypeScale.captionStrong)
            .foregroundStyle(Palette.text2)
            .padding(.leading, Space.s3)
            .padding(.trailing, Space.s2)
            .frame(height: Metrics.groupHeader)
            .frame(maxWidth: .infinity)
            .background(Palette.group)
            .overlay(alignment: .bottom) { ThemedDivider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(String(count))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

/// Server row (48 pt): ★ + 🔔 | name + host → IP | CID 8…8 | map · players · ping | ban cell + Fix… | row menu.
struct ServerRowView: View {
    let entry: ServerEntry
    let status: ServerRowStatus?
    let ban: BanCellContent
    let copied: Bool
    /// §32: the follow-up date of an open appeal has passed (🔔).
    var followUpDue = false
    /// `false` in narrow windows: map · players · ping move into the server cell tooltip.
    var showsInfo = true
    /// §55 keyboard selection of the table (accent tint + leading bar; VoiceOver "selected").
    var isSelected = false
    let actions: ServerRowActions

    @State private var hovering = false
    @State private var showsFix = false

    var body: some View {
        HStack(spacing: Metrics.Column.gap) {
            marks.frame(width: Metrics.Column.marks, alignment: .leading)
            serverCell.frame(maxWidth: .infinity, alignment: .leading)
            cidCell.frame(width: Metrics.Column.cid, alignment: .leading)
            if showsInfo {
                infoCell.frame(width: Metrics.Column.info, alignment: .leading)
            }
            banCell.frame(width: Metrics.Column.ban, alignment: .leading)
            rowMenu.frame(width: Metrics.Column.menu)
        }
        .padding(.horizontal, Space.s2)
        .frame(height: Metrics.row)
        .background(isSelected ? Palette.accentTint : hovering ? Palette.rowHover : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Palette.accentText).frame(width: 3).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) { ThemedDivider() }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.label)
        .accessibilityValue(AccessibilityText.serverNotifications(entry.notifications) ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Cells

    private var marks: some View {
        HStack(spacing: 2) {
            markButton(.favorite, symbol: entry.favorite ? "star.fill" : "star",
                       color: entry.favorite ? Palette.orange : Palette.text3,
                       isOn: entry.favorite, action: actions.toggleFavorite)
                .accessibilityIdentifier("favorite")
            markButton(.watch, symbol: entry.watch ? "bell.fill" : "bell",
                       color: entry.watch ? Palette.accentText : Palette.text3,
                       isOn: entry.watch, action: actions.toggleWatch)
                .accessibilityIdentifier("watchToggle")
        }
    }

    /// ★ / 🔔 switch: 24 × 24 hit target (§55); VoiceOver says the action and "Favorite: On/Off".
    private func markButton(_ mark: ServerRowMark, symbol: String, color: Color, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        let text = AccessibilityText.mark(mark, isOn: isOn)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: Metrics.markButton, height: Metrics.markButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text.label)
        .accessibilityLabel(text.label)
        .accessibilityValue(text.value)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var serverCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Badges give way first in narrow windows (notes / appeal stay reachable from the row menu).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    nameText
                    badges
                }
                nameText
            }
            addressLine
        }
        .help(showsInfo ? "" : infoText.map + " · " + infoText.meta)
    }

    private var nameText: some View {
        Text(verbatim: entry.label)
            .font(TypeScale.rowTitle)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(entry.banCheck?.info?.name.map { entry.label + "\n" + $0 } ?? entry.label)
    }

    /// `host → IP:port` (host truncates, the address never does); IP literals show `IP:port` only.
    @ViewBuilder
    private var addressLine: some View {
        let port = String(entry.port)
        if status?.message == .invalidHost && status?.resolutionFailure == nil || status?.resolutionFailure == .invalid {
            Text(verbatim: entry.host)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.redText)
                .lineLimit(1)
                .help(MessageCode.invalidHost.text)
        } else if case .hostname? = HostValidator.classify(entry.host) {
            let target = status?.resolvedIP.map { Self.hostPort($0, port) } ?? resolutionText
            HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                Text(verbatim: entry.host)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: "→")
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text3)
                    .accessibilityHidden(true)
                // The address keeps its width (the host truncates first); only below the minimum window width
                // does it truncate in the middle.
                Text(verbatim: target)
                    .font(status?.resolvedIP == nil ? TypeScale.callout : TypeScale.mono)
                    .foregroundStyle(status?.resolvedIP == nil ? Palette.orangeText : Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            .help(entry.host + " → " + target)
        } else {
            Text(verbatim: Self.hostPort(entry.host, port))
                .font(TypeScale.mono)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Self.hostPort(entry.host, port))
        }
    }

    private var resolutionText: String {
        switch status?.resolutionFailure {
        case .notFound?: return L10n.text(.serverResolveNotFound)
        case .network?: return L10n.text(.serverResolveNetwork)
        default: return L10n.text(.serverResolving)
        }
    }

    static func hostPort(_ host: String, _ port: String) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// CID 8…8 (click to copy); orange when it differs from the record, "—" without an address.
    @ViewBuilder
    private var cidCell: some View {
        if let cid = status?.currentCID {
            let changed = status?.message == .serverCIDChanged
            Button {
                actions.copy(cid)
            } label: {
                Text(verbatim: copied ? L10n.text(.actionCopied) : Self.shortCID(cid))
                    .font(TypeScale.mono)
                    .foregroundStyle(changed ? Palette.orangeText : Palette.text)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help([cid, status?.message?.text, L10n.text(.serverCopyHint)].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(L10n.text(.serversColumnCID) + " " + cid)
            .accessibilityHint(L10n.text(.serverCopyHint))
        } else {
            Text(verbatim: "—")
                .font(TypeScale.mono)
                .foregroundStyle(Palette.text3)
                .help(status?.message?.text ?? L10n.text(.serverNotChecked))
        }
    }

    /// `9f3a1c7e…d7b8a4e2` (N1 §10).
    static func shortCID(_ cid: String) -> String {
        cid.count > 20 ? String(cid.prefix(8)) + "…" + String(cid.suffix(8)) : cid
    }

    /// Map and `players · ping`; unknown parts are "—".
    private var infoText: (map: String, meta: String) {
        let info = entry.banCheck?.info
        let players = info?.players.map { players in info?.maxPlayers.map { "\(players)/\($0)" } ?? String(players) }
        let ping = info?.pingMillis.map { L10n.format(.serverInfoPing, String($0)) }
        return (info?.map ?? "—", (players ?? "—") + " · " + (ping ?? "—"))
    }

    private var infoCell: some View {
        let text = infoText
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: text.map)
                .font(TypeScale.mono)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text.map)
            Text(verbatim: text.meta)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serverInfo")
    }

    private var banCell: some View {
        HStack(spacing: Space.s2) {
            Group {
                if ban.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ban.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(ban.iconColor)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(ban.title)
                    .font(TypeScale.label)
                    .foregroundStyle(ban.textColor)
                    .lineLimit(1)
                if !ban.detail.isEmpty {
                    Text(ban.detail)
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(ban.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AccessibilityText.ban(ban).label)
            .accessibilityValue(AccessibilityText.ban(ban).value)
            if actions.fix != nil, !ban.isChecking {
                // Claude Design deviation (agreed): Fix… opens an inline popover with this server's actions only.
                Button {
                    showsFix = true
                } label: {
                    Text(verbatim: L10n.text(.actionFix) + "…")
                }
                .controlSize(.small)
                .fixedSize()
                .help(L10n.format(.fixShowFor, entry.label))
                .accessibilityLabel(L10n.format(.fixShowFor, entry.label))
                .accessibilityIdentifier("fixButton")
                .popover(isPresented: $showsFix, arrowEdge: .bottom) {
                    ServerActionsPopover(title: entry.label, actions: actions.fixActions) { showsFix = false }
                }
            }
        }
    }

    private var rowMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(minWidth: Metrics.minTarget, minHeight: Metrics.minTarget)
        .opacity(hovering || isSelected ? 1 : 0.55)
        .help(L10n.text(.serversRowMenu))
        .accessibilityLabel(L10n.text(.serversRowMenu))
        .accessibilityIdentifier("rowMenu")
    }

    @ViewBuilder
    private var menuItems: some View {
        if let join = actions.join {
            Button(L10n.text(.gameJoin), action: join)
            Divider()
        }
        if actions.fix != nil {
            ForEach(actions.fixActions) { action in
                Button(action.title, action: action.run)
            }
            Divider()
        } else {
            Button(L10n.text(.serverDetails), action: actions.details)
        }
        Button(L10n.text(.shareCardCreate), action: actions.shareCard)
        Divider()
        Button(L10n.text(entry.favorite ? .serverFavoriteRemove : .serverFavoriteAdd), action: actions.toggleFavorite)
        Button(L10n.text(entry.watch ? .watchToggleOff : .watchToggleOn), action: actions.toggleWatch)
        Button(L10n.text(.serverMoveUp)) { actions.moveUp?() }.disabled(actions.moveUp == nil)
        Button(L10n.text(.serverMoveDown)) { actions.moveDown?() }.disabled(actions.moveDown == nil)
        Divider()
        Button(L10n.text(.actionEdit), action: actions.edit)
        Button(L10n.text(.actionDelete), role: .destructive, action: actions.delete)
    }

    /// §32: note, appeal status and follow-up reminder; each opens the details.
    @ViewBuilder
    private var badges: some View {
        if !entry.note.isEmpty {
            Button(action: actions.details) {
                Image(systemName: "note.text").font(.system(size: 11)).foregroundStyle(Palette.text2)
            }
            .buttonStyle(.plain)
            .help(entry.note)
            .accessibilityLabel(L10n.text(.notesHasNote))
        }
        if let appeal = entry.appeal {
            Button(action: actions.details) {
                AppealStatusBadge(status: appeal.status)
            }
            .buttonStyle(.plain)
            .help(L10n.text(.appealTitle) + " · " + appeal.channelLabel)
            if followUpDue, let date = appeal.followUpAt {
                // §32: 🔔 reminder when the follow-up date has passed.
                Button(action: actions.details) {
                    Image(systemName: "bell.badge").font(.system(size: 11)).foregroundStyle(Palette.orange)
                }
                .buttonStyle(.plain)
                .help(L10n.format(.appealFollowUpDue, AppealDates.text(date)))
                .accessibilityLabel(L10n.format(.appealFollowUpDue, AppealDates.text(date)))
                .accessibilityIdentifier("followUpDue")
            }
        }
    }
}

// MARK: - Ban cell

/// §13.3 ban cell: icon + status (13 semibold, status-text colour) + detail (12 secondary). Status is always text.
struct BanCellContent: Equatable {
    var symbol: String
    var isChecking = false
    var iconColor: Color
    var textColor: Color
    var title: String
    var detail: String
    var help: String

    @MainActor
    static func make(check: BanCheck?, status: ServerRowStatus?, host: String, isChecking: Bool,
                     checksEnabled: Bool) -> BanCellContent {
        guard checksEnabled else {
            return BanCellContent(symbol: "shield.slash", iconColor: Palette.text3, textColor: Palette.text2,
                                  title: L10n.text(.banCellChecksOff), detail: L10n.text(.banCellChecksOffDetail),
                                  help: L10n.text(.serversChecksOff))
        }
        if isChecking {
            return BanCellContent(symbol: "", isChecking: true, iconColor: Palette.text2, textColor: Palette.text2,
                                  title: L10n.text(.topbarChecking), detail: check?.status.label ?? "",
                                  help: check.map(tooltip) ?? L10n.text(.topbarChecking))
        }
        guard let check else {
            if let failure = status?.resolutionFailure, failure != .pending {
                let detail = failure == .invalid ? MessageCode.invalidHost.text
                    : L10n.text(failure == .notFound ? .serverResolveNotFound : .serverResolveNetwork)
                return BanCellContent(symbol: "questionmark.circle", iconColor: Palette.text3, textColor: Palette.text2,
                                      title: L10n.text(.banStatusUnknown), detail: detail, help: host + " · " + detail)
            }
            return BanCellContent(symbol: "questionmark.circle", iconColor: Palette.text3, textColor: Palette.text2,
                                  title: L10n.text(.serverNotChecked), detail: "—", help: L10n.text(.serverNotChecked))
        }
        let lastCheck = L10n.format(.topbarLastCheck, TimeText.format(check.checkedAt))
        switch check.status {
        case .ipBanned, .cidBanned:
            return BanCellContent(symbol: "xmark.octagon.fill", iconColor: Palette.red, textColor: Palette.redText,
                                  title: L10n.text(.banMatrixCellBanned), detail: check.status.label, help: tooltip(check))
        case .cidOk, .cidNotApplicable:
            return BanCellContent(symbol: "checkmark.shield.fill", iconColor: Palette.green, textColor: Palette.greenText,
                                  title: check.status.label, detail: lastCheck, help: tooltip(check))
        case .unreachable:
            return BanCellContent(symbol: "exclamationmark.circle", iconColor: Palette.orange, textColor: Palette.text,
                                  title: check.status.label, detail: lastCheck, help: tooltip(check))
        case .unknown, .cidUnknown, .ipOk:
            var detail = lastCheck
            if case .rejectedUnknownType(let raw) = BanClassification.classify(check) {
                // §17.9.2: server rejected, type unknown → the raw reply is shown.
                detail = BanClassification.unverifiedText + ": " + raw
            }
            return BanCellContent(symbol: "questionmark.circle", iconColor: Palette.text3, textColor: Palette.text2,
                                  title: check.status.label, detail: detail, help: tooltip(check))
        }
    }

    /// Last check time, the stored detail and the §13.5 message.
    static func tooltip(_ check: BanCheck) -> String {
        let time = L10n.format(.topbarLastCheck, TimeText.format(check.checkedAt))
        return [time, check.status.messageCode?.text, check.detail.isEmpty ? nil : check.detail]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

// MARK: - Popovers

/// Inline Fix… popover (one server) — menu-like list, 296 wide.
struct ServerActionsPopover: View {
    let title: String
    let actions: [ServerAction]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverGroupTitle(title: title)
            ForEach(actions) { action in
                PopoverActionRow(symbol: action.symbol, title: action.title) {
                    dismiss()
                    action.run()
                }
            }
        }
        .padding(6)
        .frame(width: Metrics.actionsPopover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format(.fixShowFor, title))
    }
}

/// Appeal status capsule (§32).
struct AppealStatusBadge: View {
    let status: AppealStatus

    var body: some View {
        TintBadge(text: status.label, foreground: textColor, background: tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AccessibilityText.appeal(status).label)
            .accessibilityValue(AccessibilityText.appeal(status).value)
    }

    private var textColor: Color {
        switch status {
        case .sent: return Palette.accentText
        case .answered: return Palette.orangeText
        case .rejected: return Palette.redText
        case .accepted: return Palette.greenText
        }
    }

    private var tint: Color {
        switch status {
        case .sent: return Palette.accentTint
        case .answered: return Palette.orangeTint
        case .rejected: return Palette.redTint
        case .accepted: return Palette.greenTint
        }
    }
}

enum AppealDates {
    static func text(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}

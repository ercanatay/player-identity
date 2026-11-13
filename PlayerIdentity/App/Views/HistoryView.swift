import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §22 / §48.1 history window: toolbar (title + count, type and server filters, JSON / Markdown export), a card
/// with one row per entry (kind icon + label, details, server, relative time with the full date as tooltip), newest
/// first; separate empty and no-match states. Rows are prepared once per load/filter change and shown in a lazy
/// stack (only visible rows are built), so 5000 entries scroll smoothly.
struct HistoryView: View {
    @Bindable var model: AppModel
    /// Shown instead of loading from disk (previews/evidence); `nil` = load `history.jsonl`.
    var fixedEntries: [HistoryEntry]?
    /// Offscreen renders have no window toolbar: draw the same toolbar groups in the content (`InlineToolbar`).
    var inlineToolbar = false

    @State private var entries: [HistoryEntry] = []
    @State private var rows: [HistoryRowContent] = []
    @State private var kind: HistoryKind?
    @State private var serverID: UUID?
    @State private var exportError: String?

    init(model: AppModel, fixedEntries: [HistoryEntry]? = nil, initialKind: HistoryKind? = nil,
         initialServerID: UUID? = nil, inlineToolbar: Bool = false) {
        self.model = model
        self.fixedEntries = fixedEntries
        self.inlineToolbar = inlineToolbar
        _kind = State(initialValue: initialKind)
        _serverID = State(initialValue: initialServerID)
    }

    private var filter: HistoryFilter { HistoryFilter(serverID: serverID, kinds: kind.map { [$0] }) }

    var body: some View {
        VStack(spacing: 0) {
            if inlineToolbar {
                InlineToolbar { toolbarLeading } trailing: { toolbarTrailing }
            }
            content
                .padding(Space.s4)
        }
        .background(Palette.window)
        .foregroundStyle(Palette.text)
        .font(TypeScale.body)
        .frame(minWidth: Metrics.History.minWidth, minHeight: Metrics.History.minHeight)
        .toolbar {
            if !inlineToolbar {
                ToolbarItem(placement: .navigation) { toolbarLeading }
                ToolbarItemGroup(placement: .primaryAction) { toolbarTrailing }
            }
        }
        .task(id: model.historyRevision) {
            if let fixedEntries {
                entries = fixedEntries
            } else {
                entries = await model.loadHistory()
            }
            rebuildRows()
        }
        .onChange(of: filter) { rebuildRows() }
        .alert(L10n.format(.historyExportFailed, exportError ?? ""), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(L10n.text(.actionOK), role: .cancel) {}
        }
    }

    // MARK: Toolbar

    private var toolbarLeading: some View {
        ToolbarTitle(title: L10n.text(.historyTitle), count: L10n.format(.historyCount, String(rows.count)))
            .accessibilityIdentifier("historyCount")
    }

    @ViewBuilder
    private var toolbarTrailing: some View {
        ToolbarFilterMenu(title: L10n.text(.historyFilterKind), symbol: "line.3.horizontal.decrease.circle",
                          selection: $kind,
                          options: [(HistoryKind?.none, L10n.text(.historyFilterAll))]
                              + HistoryKind.allCases.map { (Optional($0), HistoryText.kind($0)) })
            .accessibilityIdentifier("historyFilterKind")
        ToolbarFilterMenu(title: L10n.text(.historyFilterServer), symbol: "server.rack", selection: $serverID,
                          options: [(UUID?.none, L10n.text(.historyFilterAll))]
                              + serverOptions.map { (Optional($0.id), $0.name) })
            .accessibilityIdentifier("historyFilterServer")
        exportButton(markdown: false)
        exportButton(markdown: true)
    }

    private func exportButton(markdown: Bool) -> some View {
        let title = L10n.text(markdown ? .historyExportMarkdown : .historyExportJSON)
        return Button { export(markdown: markdown) } label: {
            Label {
                Text(verbatim: HistoryExportFormat.name(markdown: markdown))
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
        }
        .disabled(rows.isEmpty)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(markdown ? "historyExportMarkdown" : "historyExportJSON")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            let unfiltered = entries.isEmpty
            StateBlock(symbol: unfiltered ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle",
                       symbolColor: Palette.text3,
                       title: L10n.text(unfiltered ? .historyEmpty : .historyEmptyFiltered),
                       message: L10n.text(unfiltered ? .historyEmptyBody : .historyEmptyFilteredBody)) {
                if !unfiltered {
                    Button(L10n.text(.serversClearFilters)) {
                        kind = nil
                        serverID = nil
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
            .accessibilityIdentifier(unfiltered ? "historyEmpty" : "historyNoMatch")
        } else {
            VStack(spacing: 0) {
                HistoryColumnHeader()
                ScrollView {
                    // Lazy: only the visible rows are built, so 5000 entries scroll smoothly.
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HistoryRowView(row: row)
                            ThemedDivider()
                        }
                    }
                }
            }
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text(.historyTitle))
        }
    }

    private func rebuildRows() {
        let servers = Dictionary(model.servers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        rows = HistoryRowContent.make(filter.apply(entries), now: model.now) { entry in
            guard let id = entry.serverID else { return nil }
            return servers[id] ?? entry.host
        }
    }

    /// Configured servers plus servers that only appear in the history.
    private var serverOptions: [(id: UUID, name: String)] {
        var options = model.servers.map { (id: $0.id, name: $0.label) }
        var known = Set(options.map(\.id))
        for entry in entries {
            guard let id = entry.serverID, known.insert(id).inserted else { continue }
            options.append((id: id, name: entry.host ?? id.uuidString))
        }
        return options
    }

    private func export(markdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "history.md" : "history.json"
        panel.allowedContentTypes = [markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let filtered = filter.apply(entries)
        let text = markdown ? HistoryExport.markdown(filtered) : HistoryExport.json(filtered)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

enum HistoryExportFormat {
    /// Visible button titles (format names, not translated); the full localized action is the tooltip.
    static func name(markdown: Bool) -> String { markdown ? "Markdown" : "JSON" }
}

/// Toolbar filter: a menu titled "Type: All" with the choices as an inline picker (checkmark on the current one).
struct ToolbarFilterMenu<Value: Hashable>: View {
    let title: String
    let symbol: String
    @Binding var selection: Value
    let options: [(Value, String)]

    private var current: String { options.first { $0.0 == selection }?.1 ?? "" }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].1).tag(options[index].0)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(L10n.format(.historyFilterValue, title, current), systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help(L10n.format(.historyFilterValue, title, current))
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}

// MARK: - Rows

/// Display data of one history row, prepared outside `body` (formatters run once per rebuild, not per frame).
struct HistoryRowContent: Identifiable, Equatable {
    let id: Int
    let symbol: String
    let tone: ChipTone
    let kind: String
    let server: String?
    /// `old → new` (monospaced).
    let change: String?
    let note: String?
    /// "5 minutes ago" / "5 dakika önce".
    let relativeTime: String
    /// Full date and time (tooltip, accessibility).
    let absoluteTime: String

    /// Rows in the given order (pass `HistoryFilter.apply` output: newest first).
    @MainActor
    static func make(_ entries: [HistoryEntry], now: Date,
                     serverName: (HistoryEntry) -> String?) -> [HistoryRowContent] {
        let time = HistoryTimeFormat()
        return entries.enumerated().map { index, entry in
            HistoryRowContent(id: index, symbol: HistoryKindStyle.symbol(entry.kind), tone: HistoryKindStyle.tone(entry),
                              kind: HistoryText.kind(entry.kind), server: serverName(entry),
                              change: HistoryText.change(entry), note: HistoryText.note(entry),
                              relativeTime: time.relative(entry.ts, now: now), absoluteTime: time.absolute(entry.ts))
        }
    }

    /// Spoken as one element: kind, then server, details and the full time.
    var accessibilityValue: String {
        [server, change, note, absoluteTime].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Relative and absolute times in the app language (§35), not the system one.
struct HistoryTimeFormat {
    private let relativeFormatter: RelativeDateTimeFormatter
    private let absoluteFormatter: DateFormatter

    init(language: AppLanguage = L10n.currentLanguage, timeZone: TimeZone = .current) {
        let locale = Locale(identifier: language.rawValue)
        relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .named
        absoluteFormatter = DateFormatter()
        absoluteFormatter.locale = locale
        absoluteFormatter.timeZone = timeZone
        absoluteFormatter.dateStyle = .long
        absoluteFormatter.timeStyle = .medium
    }

    func relative(_ date: Date, now: Date) -> String {
        // Under a minute reads "now" (no "in 3 seconds" for a clock a little behind).
        abs(now.timeIntervalSince(date)) < 60 ? relativeFormatter.localizedString(fromTimeInterval: 0)
            : relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    func absolute(_ date: Date) -> String { absoluteFormatter.string(from: date) }
}

/// Kind → SF Symbol and tone. Ban/watch changes carry their status colour; a status change carries the new level.
enum HistoryKindStyle {
    static func symbol(_ kind: HistoryKind) -> String {
        switch kind {
        case .refresh: return "arrow.clockwise"
        case .ipChanged: return "network"
        case .banAppeared: return "xmark.octagon.fill"
        case .banLifted: return "checkmark.shield.fill"
        case .identityChanged: return "key"
        case .nameChanged: return "pencil"
        case .modelChanged: return "person.crop.circle"
        case .apply: return "square.and.arrow.down"
        case .fixAttempt: return "wrench.and.screwdriver"
        case .appUpdateAvailable: return "arrow.down.circle"
        case .appeal: return "envelope"
        case .note: return "note.text"
        case .watchBanAppeared: return "bell.badge"
        case .watchBanLifted: return "bell"
        case .watchOffline: return "exclamationmark.circle"
        case .watchOnline: return "wifi"
        case .watchMapChanged: return "map"
        case .configOverrideRemoved: return "doc.badge.gearshape"
        case .diagnose: return "stethoscope"
        }
    }

    static func tone(_ entry: HistoryEntry) -> ChipTone {
        switch entry.kind {
        case .refresh:
            return StatusLevel.allCases.first { HistoryTransitions.levelName($0) == entry.new }.map(ChipTone.init) ?? .neutral
        case .banAppeared, .watchBanAppeared: return .red
        case .banLifted, .watchBanLifted, .watchOnline: return .green
        case .identityChanged, .fixAttempt, .watchOffline, .configOverrideRemoved: return .orange
        case .ipChanged, .apply, .appUpdateAvailable, .appeal: return .accent
        case .nameChanged, .modelChanged, .note, .watchMapChanged: return .neutral
        case .diagnose:
            return DiagnosisVerdict(rawValue: entry.new ?? "").map { ChipTone($0.level) } ?? .neutral
        }
    }
}

/// Column header (28 pt, 11 semibold secondary): event | server | time.
private struct HistoryColumnHeader: View {
    var body: some View {
        HStack(spacing: Metrics.Column.gap) {
            Text(L10n.text(.historyColumnEvent))
                .padding(.leading, Metrics.rowIcon + Metrics.Column.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text(.historyFilterServer)).frame(width: Metrics.History.serverColumn, alignment: .leading)
            Text(L10n.text(.historyColumnTime)).frame(width: Metrics.History.timeColumn, alignment: .trailing)
        }
        .font(TypeScale.captionStrong)
        .foregroundStyle(Palette.text2)
        .lineLimit(1)
        .padding(.horizontal, Space.s3 + Space.s2)
        .frame(height: Metrics.groupHeader)
        .background(Palette.group)
        .overlay(alignment: .bottom) { ThemedDivider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// History row (≥ 48 pt): tinted kind icon | kind (13 medium) + change (12 mono) + note (12 secondary) | server | time.
struct HistoryRowView: View {
    let row: HistoryRowContent

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.Column.gap) {
            Image(systemName: row.symbol)
                .font(TypeScale.callout)
                .foregroundStyle(row.tone.iconColor)
                .frame(width: Metrics.rowIcon, height: Metrics.rowIcon)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(row.tone.tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(row.kind)
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                if let change = row.change {
                    Text(verbatim: change)
                        .font(TypeScale.monoSmall)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(change)
                }
                if let note = row.note {
                    Text(verbatim: note)
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .lineLimit(Metrics.History.noteLines)
                        .truncationMode(.tail)
                        .help(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.server ?? "—")
                .font(TypeScale.callout)
                .foregroundStyle(row.server == nil ? Palette.text3 : Palette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.server ?? "")
                .frame(width: Metrics.History.serverColumn, alignment: .leading)
            Text(verbatim: row.relativeTime)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .monospacedDigit()
                .lineLimit(1)
                .help(row.absoluteTime)
                .frame(width: Metrics.History.timeColumn, alignment: .trailing)
        }
        .padding(.horizontal, Space.s3 + Space.s2)
        .padding(.vertical, Space.s2)
        .frame(minHeight: Metrics.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.kind)
        .accessibilityValue(row.accessibilityValue)
    }
}

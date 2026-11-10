import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §38 / §48.2 ban matrix: toolbar (title + count, CSV export, copy), a table card with one row per server
/// (server | IP ban | CID ban | range | last check), state as chips (icon + text + tint), banned first.
/// Narrow windows drop the last-check, then the range column; their values move into the row tooltip.
struct BanMatrixView: View {
    @Bindable var model: AppModel
    /// Shown instead of computing from the model (UI evidence).
    var fixedRows: [BanMatrixRow]?
    /// Offscreen renders have no window toolbar: draw the same toolbar groups in the content (`InlineToolbar`).
    var inlineToolbar = false

    @State private var rows: [BanMatrixRow] = []
    @State private var message: String?
    @State private var isError = false
    @State private var tableWidth: CGFloat = Metrics.BanMatrix.minWidth

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
        .frame(minWidth: Metrics.BanMatrix.minWidth, minHeight: Metrics.BanMatrix.minHeight)
        .toolbar {
            if !inlineToolbar {
                ToolbarItem(placement: .navigation) { toolbarLeading }
                ToolbarItemGroup(placement: .primaryAction) { toolbarTrailing }
            }
        }
        .task(id: model.historyRevision) { await reload() }
        .onChange(of: model.servers) { Task { await reload() } }
    }

    private func reload() async {
        if let fixedRows {
            rows = fixedRows
        } else {
            rows = await model.banMatrixRows()
        }
    }

    // MARK: Toolbar

    private var toolbarLeading: some View {
        HStack(spacing: Space.s3) {
            ToolbarTitle(title: L10n.text(.banMatrixTitle),
                         count: L10n.format(.banMatrixCount, String(rows.count), String(rows.filter(\.isBanned).count)))
                .accessibilityIdentifier("banMatrixCount")
            if let message {
                Text(message)
                    .font(TypeScale.callout)
                    .foregroundStyle(isError ? Palette.redText : Palette.text2)
                    .middleTruncated(message)
                    .accessibilityIdentifier("banMatrixMessage")
            }
        }
    }

    @ViewBuilder
    private var toolbarTrailing: some View {
        Button(action: export) {
            Label {
                Text(verbatim: BanMatrixExport.formatName)
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
        }
        .disabled(rows.isEmpty)
        .help(L10n.text(.banMatrixExportCSV))
        .accessibilityLabel(L10n.text(.banMatrixExportCSV))
        .accessibilityIdentifier("banMatrixExport")
        Button(action: copy) {
            Label(L10n.text(.actionCopy), systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
        }
        .disabled(rows.isEmpty)
        .help(L10n.text(.actionCopy))
        .accessibilityIdentifier("banMatrixCopy")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            StateBlock(symbol: "tray", symbolColor: Palette.text3, title: L10n.text(.banMatrixEmpty),
                       message: L10n.text(.banMatrixEmptyBody)) {
                EmptyView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
            .accessibilityIdentifier("banMatrixEmpty")
        } else {
            let columns = BanMatrixLayout.columns(tableWidth: tableWidth)
            VStack(spacing: 0) {
                BanMatrixHeader(columns: columns)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.serverID) { row in
                            BanMatrixRowView(row: row, columns: columns)
                            ThemedDivider()
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { tableWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in tableWidth = width }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text(.banMatrixTitle))
        }
    }

    private func copy() {
        Pasteboard.copy(CSV.tabSeparated(BanMatrixText.table(rows)))
        message = L10n.text(.actionCopied)
        isError = false
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = BanMatrixExport.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(CSV.encode(BanMatrixText.table(rows)).utf8).write(to: url, options: .atomic)
            message = L10n.format(.exportSaved, url.path)
            isError = false
        } catch {
            message = L10n.format(.exportFailed, error.localizedDescription)
            isError = true
        }
    }
}

enum BanMatrixExport {
    static let fileName = "ban-matrix.csv"
    /// Visible button title (format name, not translated); the localized action is the tooltip.
    static let formatName = "CSV"
}

// MARK: - Layout

enum BanMatrixColumn: CaseIterable, Equatable {
    case server, ipBan, cidBan, range, lastCheck

    var title: String {
        switch self {
        case .server: return L10n.text(.banMatrixServer)
        case .ipBan: return L10n.text(.banMatrixIPBan)
        case .cidBan: return L10n.text(.banMatrixCIDBan)
        case .range: return L10n.text(.banMatrixRange)
        case .lastCheck: return L10n.text(.banMatrixLastCheck)
        }
    }

    /// Fixed width; `nil` = flexible (server).
    var width: CGFloat? {
        switch self {
        case .server: return nil
        case .ipBan, .cidBan: return Metrics.BanMatrix.cell
        case .range: return Metrics.BanMatrix.range
        case .lastCheck: return Metrics.BanMatrix.lastCheck
        }
    }
}

enum BanMatrixLayout {
    /// Columns dropped first when the table is narrow (last check, then range); server, IP and CID always stay.
    static let dropOrder: [BanMatrixColumn] = [.lastCheck, .range]

    /// Visible columns for a table width (card width; rows are inset by 12 pt on each side).
    static func columns(tableWidth: CGFloat) -> [BanMatrixColumn] {
        var columns = BanMatrixColumn.allCases
        for column in dropOrder where requiredWidth(columns) > tableWidth {
            columns.removeAll { $0 == column }
        }
        return columns
    }

    static func requiredWidth(_ columns: [BanMatrixColumn]) -> CGFloat {
        let fixed = columns.compactMap(\.width).reduce(0, +)
        let gaps = CGFloat(max(columns.count - 1, 0)) * Metrics.Column.gap
        return Metrics.BanMatrix.serverMin + fixed + gaps + 2 * Space.s3
    }

    /// Server cell tooltip: name, address and the values of the hidden columns.
    static func tooltip(_ row: BanMatrixRow, columns: [BanMatrixColumn]) -> String {
        var lines = [row.label, BanMatrixChip.address(row)]
        if !columns.contains(.range) {
            lines.append(BanMatrixColumn.range.title + ": " + (row.range ?? "—"))
        }
        if !columns.contains(.lastCheck) {
            lines.append(BanMatrixColumn.lastCheck.title + ": " + BanMatrixText.lastCheck(row.lastCheck))
        }
        return lines.joined(separator: "\n")
    }
}

/// Chip content of a matrix cell: symbol + text + tone; `nil` = no value ("—").
struct BanMatrixChip: Equatable {
    let symbol: String
    let text: String
    let tone: ChipTone

    static func cell(_ cell: BanMatrixCell) -> BanMatrixChip? {
        switch cell {
        case .banned: return BanMatrixChip(symbol: "xmark.octagon.fill", text: BanMatrixText.cell(cell), tone: .red)
        case .clear: return BanMatrixChip(symbol: "checkmark.shield.fill", text: BanMatrixText.cell(cell), tone: .green)
        case .unknown: return BanMatrixChip(symbol: "questionmark.circle", text: BanMatrixText.cell(cell), tone: .neutral)
        case .notApplicable: return BanMatrixChip(symbol: "minus.circle", text: BanMatrixText.cell(cell), tone: .neutral)
        case .none: return nil
        }
    }

    static func range(_ cidr: String?) -> BanMatrixChip? {
        cidr.map { BanMatrixChip(symbol: "rectangle.split.3x1.fill", text: $0, tone: .red) }
    }

    /// "Ban type unverified" marker (shown in the CID cell, like the export).
    static var unverified: BanMatrixChip {
        BanMatrixChip(symbol: "questionmark.diamond.fill", text: BanClassification.unverifiedText, tone: .orange)
    }

    static func address(_ row: BanMatrixRow) -> String {
        "\(row.host.contains(":") ? "[\(row.host)]" : row.host):\(row.port)"
    }
}

// MARK: - Table pieces

/// Column header row (28 pt, 11 semibold secondary, group fill).
private struct BanMatrixHeader: View {
    let columns: [BanMatrixColumn]

    var body: some View {
        HStack(spacing: Metrics.Column.gap) {
            ForEach(columns, id: \.self) { column in
                Text(column.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(column.title)
                    .frame(width: column.width, alignment: .leading)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .font(TypeScale.captionStrong)
        .foregroundStyle(Palette.text2)
        .padding(.horizontal, Space.s3)
        .frame(height: Metrics.groupHeader)
        .background(Palette.group)
        .overlay(alignment: .bottom) { ThemedDivider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One server (≥ 48 pt): name (+ unreachable marker) and address | chips (the CID cell shows "Ban type unverified"
/// when the type could not be verified) | range | last check.
private struct BanMatrixRowView: View {
    let row: BanMatrixRow
    let columns: [BanMatrixColumn]

    var body: some View {
        HStack(spacing: Metrics.Column.gap) {
            ForEach(columns, id: \.self) { column in
                cell(column)
                    .frame(width: column.width, alignment: .leading)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .frame(minHeight: Metrics.row)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cell(_ column: BanMatrixColumn) -> some View {
        switch column {
        case .server: server
        case .ipBan: chip(BanMatrixChip.cell(row.ipBan), column: column)
        case .cidBan:
            // As in the export: "Ban type unverified" replaces the CID cell (orange marker, full text as tooltip).
            if row.unverified {
                chip(BanMatrixChip.unverified, column: column)
                    .accessibilityIdentifier("banMatrixUnverified")
            } else {
                chip(BanMatrixChip.cell(row.cidBan), column: column)
            }
        case .range: chip(BanMatrixChip.range(row.range), column: column, monospaced: true)
        case .lastCheck:
            Text(verbatim: BanMatrixText.lastCheck(row.lastCheck))
                .font(TypeScale.callout)
                .foregroundStyle(row.lastCheck == nil ? Palette.text3 : Palette.text2)
                .monospacedDigit()
                .lineLimit(1)
                .help(BanMatrixText.lastCheck(row.lastCheck))
                .accessibilityLabel(column.title)
                .accessibilityValue(BanMatrixText.lastCheck(row.lastCheck))
        }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: Space.s1 / 2) {
            HStack(spacing: Space.s2) {
                Text(verbatim: row.label)
                    .font(TypeScale.rowTitle)
                    .fontWeight(row.isBanned ? .semibold : .medium)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if row.unreachable {
                    StatusChip(symbol: "exclamationmark.circle", text: BanStatus.unreachable.label, tone: .orange)
                }
            }
            Text(verbatim: BanMatrixChip.address(row))
                .font(TypeScale.monoSmall)
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(BanMatrixLayout.tooltip(row, columns: columns))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func chip(_ chip: BanMatrixChip?, column: BanMatrixColumn, monospaced: Bool = false) -> some View {
        Group {
            if let chip {
                StatusChip(symbol: chip.symbol, text: chip.text, tone: chip.tone, monospaced: monospaced,
                           help: column.title + ": " + chip.text)
            } else {
                Text(verbatim: "—")
                    .foregroundStyle(Palette.text3)
                    .help(column.title + ": —")
            }
        }
        .accessibilityLabel(column.title)
        .accessibilityValue(chip?.text ?? "—")
    }
}

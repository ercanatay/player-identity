import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §38 ban matrix: servers × IP ban / CID ban / range / last check, banned first; CSV export and copy.
struct BanMatrixView: View {
    @Bindable var model: AppModel
    /// Shown instead of computing from the model (UI evidence).
    var fixedRows: [BanMatrixRow]?

    @State private var rows: [BanMatrixRow] = []
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.format(.banMatrixCount, String(rows.count), String(rows.filter(\.isBanned).count)))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("banMatrixCount")
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(L10n.text(.actionCopy), action: copy)
                    .disabled(rows.isEmpty)
                    .accessibilityIdentifier("banMatrixCopy")
                Button(L10n.text(.banMatrixExportCSV), action: export)
                    .disabled(rows.isEmpty)
                    .accessibilityIdentifier("banMatrixExport")
            }
            .padding(12)
            Divider()
            if rows.isEmpty {
                Text(L10n.text(.banMatrixEmpty))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                    GridRow {
                        header(L10n.text(.banMatrixServer))
                        header(L10n.text(.banMatrixIPBan))
                        header(L10n.text(.banMatrixCIDBan))
                        header(L10n.text(.banMatrixRange))
                        header(L10n.text(.banMatrixLastCheck))
                    }
                    .padding(.vertical, 6)
                    Divider()
                    ForEach(rows, id: \.serverID) { row in
                        BanMatrixGridRow(row: row)
                        Divider()
                    }
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 760, minHeight: 280)
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

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(.secondary)
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
}

/// One server: icon + text per cell; "Ban type unverified" rows are marked; unreachable cells are "—".
private struct BanMatrixGridRow: View {
    let row: BanMatrixRow

    var body: some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.label).fontWeight(row.isBanned ? .semibold : .regular)
                Text(verbatim: "\(row.host.contains(":") ? "[\(row.host)]" : row.host):\(row.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if row.unverified {
                    Label(BanClassification.unverifiedText, systemImage: "questionmark.diamond.fill")
                        .font(.caption)
                        .foregroundStyle(.purple)
                        .accessibilityIdentifier("banMatrixUnverified")
                }
                if row.unreachable {
                    Text(BanStatus.unreachable.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            BanMatrixCellView(cell: row.ipBan)
            BanMatrixCellView(cell: row.cidBan)
            if let range = row.range {
                Label(range, systemImage: "rectangle.split.3x1.fill")
                    .foregroundStyle(.red)
                    .font(.callout.monospaced())
            } else {
                Text(verbatim: "—").foregroundStyle(.secondary)
            }
            Text(verbatim: BanMatrixText.lastCheck(row.lastCheck))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct BanMatrixCellView: View {
    let cell: BanMatrixCell

    var body: some View {
        if cell == .none {
            Text(verbatim: "—").foregroundStyle(.secondary)
        } else {
            Label {
                Text(BanMatrixText.cell(cell))
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var symbol: String {
        switch cell {
        case .banned: return StatusLevel.red.symbolName
        case .clear: return StatusLevel.green.symbolName
        case .unknown: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        case .none: return "circle"
        }
    }

    private var color: Color {
        switch cell {
        case .banned: return .red
        case .clear: return .green
        default: return .secondary
        }
    }
}

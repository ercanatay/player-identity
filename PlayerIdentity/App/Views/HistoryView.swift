import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §22 history window: newest first, filter by kind/server, empty state, JSON/Markdown export.
struct HistoryView: View {
    @Bindable var model: AppModel
    /// Shown instead of loading from disk (previews/evidence); `nil` = load `history.jsonl`.
    var fixedEntries: [HistoryEntry]?

    @State private var entries: [HistoryEntry] = []
    @State private var kind: HistoryKind?
    @State private var serverID: UUID?
    @State private var exportError: String?

    init(model: AppModel, fixedEntries: [HistoryEntry]? = nil, initialKind: HistoryKind? = nil, initialServerID: UUID? = nil) {
        self.model = model
        self.fixedEntries = fixedEntries
        _kind = State(initialValue: initialKind)
        _serverID = State(initialValue: initialServerID)
    }

    private var filter: HistoryFilter { HistoryFilter(serverID: serverID, kinds: kind.map { [$0] }) }
    private var filtered: [HistoryEntry] { filter.apply(entries) }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(12)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(L10n.text(entries.isEmpty ? .historyEmpty : .historyEmptyFiltered))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(filtered.enumerated()), id: \.offset) { _, entry in
                    HistoryRow(entry: entry, serverName: serverName(for: entry))
                }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .task(id: model.historyRevision) {
            if let fixedEntries {
                entries = fixedEntries
            } else {
                entries = await model.loadHistory()
            }
        }
        .alert(L10n.format(.historyExportFailed, exportError ?? ""), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(L10n.text(.actionOK), role: .cancel) {}
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker(L10n.text(.historyFilterKind), selection: $kind) {
                Text(L10n.text(.historyFilterAll)).tag(HistoryKind?.none)
                ForEach(HistoryKind.allCases, id: \.self) { kind in
                    Text(HistoryText.kind(kind)).tag(Optional(kind))
                }
            }
            .fixedSize()
            Picker(L10n.text(.historyFilterServer), selection: $serverID) {
                Text(L10n.text(.historyFilterAll)).tag(UUID?.none)
                ForEach(serverOptions, id: \.id) { option in
                    Text(option.name).tag(Optional(option.id))
                }
            }
            .fixedSize()
            Spacer()
            Text(L10n.format(.historyCount, String(filtered.count)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(L10n.text(.historyExportJSON)) { export(markdown: false) }
                .disabled(filtered.isEmpty)
            Button(L10n.text(.historyExportMarkdown)) { export(markdown: true) }
                .disabled(filtered.isEmpty)
        }
    }

    /// Configured servers plus servers that only appear in the history.
    private var serverOptions: [(id: UUID, name: String)] {
        var options = model.servers.map { (id: $0.id, name: $0.label) }
        for entry in entries {
            guard let id = entry.serverID, !options.contains(where: { $0.id == id }) else { continue }
            options.append((id: id, name: entry.host ?? id.uuidString))
        }
        return options
    }

    private func serverName(for entry: HistoryEntry) -> String? {
        guard let id = entry.serverID else { return nil }
        return model.servers.first { $0.id == id }?.label ?? entry.host
    }

    private func export(markdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "history.md" : "history.json"
        panel.allowedContentTypes = [markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = markdown ? HistoryExport.markdown(filtered) : HistoryExport.json(filtered)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let serverName: String?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.formatter.string(from: entry.ts))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(HistoryText.kind(entry.kind))
                .fontWeight(.medium)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let serverName {
                    Text(serverName)
                }
                if let change = HistoryText.change(entry) {
                    Text(change).font(.callout.monospaced())
                }
                if let note = HistoryText.note(entry) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import WidgetKit

// §69.2 widget: small (overall status, short CID, last check) and medium (first three servers: label, ban, ping).
// Reads `widget-snapshot.json` written by the app, read-only; no network, no player IP.

@main
struct PlayerIdentityWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlayerIdentityStatusWidget()
    }
}

struct PlayerIdentityStatusWidget: Widget {
    static let kind = "tr.ercanatay.playeridentity.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            SnapshotWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetText.text(.widgetDisplayName))
        .description(WidgetText.text(.widgetDescription))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Data

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// `nil` = no usable `widget-snapshot.json` yet: "Open the app".
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    /// The real home folder: the extension runs in the sandbox, whose `NSHomeDirectory()` is its container. Reading
    /// the app's data folder is allowed by a read-only home-relative exception (no App Group).
    static var snapshotURL: URL {
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
        return WidgetSnapshotStore.fileURL(home: URL(fileURLWithPath: home, isDirectory: true))
    }

    static func plan(now: Date = Date()) -> WidgetTimeline.Plan {
        WidgetTimeline.plan(WidgetSnapshotStore.load(from: snapshotURL), now: now)
    }

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(updatedAt: Date(), status: .green, cidShort: "9f3a1c7e\u{2026}d7b8",
                                                             servers: []))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let plan = Self.plan()
        completion(SnapshotEntry(date: plan.date, snapshot: plan.snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let plan = Self.plan()
        completion(Timeline(entries: [SnapshotEntry(date: plan.date, snapshot: plan.snapshot)], policy: .after(plan.reloadAt)))
    }
}

/// Texts from the extension's own copy of the app's `Localizable.strings` (system language).
enum WidgetText {
    static func text(_ key: L10nKey) -> String {
        Bundle.main.localizedString(forKey: key.rawValue, value: nil, table: nil)
    }

    static func format(_ key: L10nKey, _ arguments: String...) -> String {
        String(format: text(key), arguments: arguments.map { $0 as NSString })
    }

    static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}

// MARK: - Views

struct SnapshotWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                if family == .systemMedium { MediumView(snapshot: snapshot) } else { SmallView(snapshot: snapshot) }
            } else {
                EmptyStateView()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(WidgetTimeline.deepLink)
    }
}

private func color(_ status: WidgetStatus) -> Color {
    switch status {
    case .green: return .green
    case .orange: return .orange
    case .red: return .red
    case .unknown: return .secondary
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.text.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(WidgetText.text(.widgetOpenApp))
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SmallView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: snapshot.status.symbolName)
                .font(.title)
                .foregroundStyle(color(snapshot.status))
            Text(WidgetText.text(snapshot.status.textKey))
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let cid = snapshot.cidShort {
                Text(verbatim: "CID \(cid)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
            Text(WidgetText.format(.topbarLastCheck, WidgetText.time(snapshot.updatedAt)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MediumView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.status.symbolName)
                    .foregroundStyle(color(snapshot.status))
                Text(WidgetText.text(snapshot.status.textKey))
                    .font(.headline)
                Spacer(minLength: 4)
                Text(WidgetText.time(snapshot.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if snapshot.servers.isEmpty {
                Text(WidgetText.text(.widgetNoServers))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.servers.enumerated()), id: \.offset) { _, server in
                HStack(spacing: 6) {
                    Image(systemName: server.banLevel.symbolName)
                        .foregroundStyle(color(server.banLevel))
                    Text(verbatim: server.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(WidgetText.text(server.banTextKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(verbatim: server.ping.map { WidgetText.format(.serverInfoPing, String($0)) } ?? "\u{2014}")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

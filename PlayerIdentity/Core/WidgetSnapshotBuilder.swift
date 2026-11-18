import Foundation

/// §69.2: the widget snapshot from the app's state after a refresh. No player IP goes in; the CID is shortened.
enum WidgetSnapshotBuilder {
    /// `servers` in display order (favorites/groups first, like the main window).
    static func make(report: StatusReport?, servers: [ServerEntry], updatedAt: Date) -> WidgetSnapshot {
        let status: WidgetStatus
        switch report?.overall {
        case .green?: status = .green
        case .orange?: status = .orange
        case .red?: status = .red
        case nil: status = .unknown
        }
        let cid = servers.lazy.compactMap { report?.server($0.id)?.currentCID }.first { !$0.isEmpty }
        let rows = servers.prefix(WidgetSnapshot.maxServers).map { entry in
            WidgetSnapshot.Server(label: entry.label, host: entry.host, port: entry.port,
                                  ban: entry.banCheck?.status.rawValue, ping: entry.banCheck?.info?.pingMillis)
        }
        return WidgetSnapshot(updatedAt: updatedAt, status: status, cidShort: cid.map(WidgetSnapshot.shortCID),
                              servers: Array(rows))
    }
}

/// Asks the widget to reload after the snapshot was written (WidgetKit in the app, a no-op elsewhere).
protocol WidgetReloading: Sendable {
    func reloadTimelines()
}

struct NoopWidgetReloader: WidgetReloading {
    init() {}
    func reloadTimelines() {}
}

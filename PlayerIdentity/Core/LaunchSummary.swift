import Foundation

// MARK: - §67.3 Launch summary

/// The server the launch summary card names: the one with the most ban verdicts in the last 7 days (at least 2).
/// Derived from the `diagnose` history lines (§65 trend); nothing extra is stored and no network is used.
struct LaunchSummary: Sendable, Equatable {
    static let window = DiagnosisTrendWindow.week
    /// Ban verdicts (`ipBanned` / `cidBanned` / `rangeBanned`) a server needs in the window for the card.
    static let threshold = 2

    let serverID: UUID
    /// Label, or `host:port` without one.
    let name: String
    let bans: Int

    /// `<server>: N bans in the last 7 days`.
    var text: String { L10n.format(.launchSummaryText, name, String(bans)) }

    /// The server with the most ban verdicts in the window; ties keep the order of `servers` (display order).
    /// `nil` when no server reaches the threshold.
    static func make(entries: [HistoryEntry], servers: [ServerEntry], now: Date) -> LaunchSummary? {
        let diagnoses = entries.filter { $0.kind == .diagnose }
        guard !diagnoses.isEmpty else { return nil }
        var best: LaunchSummary?
        for server in servers {
            let trend = DiagnosisTrend.make(entries: diagnoses, serverID: server.id, window: window, now: now)
            let bans = trend.counts.filter(\.verdict.isBan).map(\.count).reduce(0, +)
            guard bans >= threshold, bans > (best?.bans ?? 0) else { continue }
            let name = server.label.isEmpty ? ServerAddressText.hostPort(host: server.host, port: server.port) : server.label
            best = LaunchSummary(serverID: server.id, name: name, bans: bans)
        }
        return best
    }

    /// The card was hidden for the local day of `now` (UserDefaults); the next day it is evaluated again.
    static func isDismissed(defaults: UserDefaults, now: Date, timeZone: TimeZone = .current) -> Bool {
        defaults.string(forKey: DefaultsKey.launchSummaryDismissedDay) == FullBackupNaming.day(now, timeZone: timeZone)
    }

    static func dismiss(defaults: UserDefaults, now: Date, timeZone: TimeZone = .current) {
        defaults.set(FullBackupNaming.day(now, timeZone: timeZone), forKey: DefaultsKey.launchSummaryDismissedDay)
    }
}

/// `host:port`, IPv6 in brackets.
enum ServerAddressText {
    static func hostPort(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

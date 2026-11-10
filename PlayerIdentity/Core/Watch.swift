import Foundation

// MARK: - §42 Watched servers

/// What was last seen of a server; the baseline the next check is compared with.
struct WatchSnapshot: Codable, Sendable, Equatable {
    /// Last determined ban status (`unknown`/`cidUnknown` keep the previous one).
    var status: BanStatus?
    var online: Bool
    var map: String?
    /// When the server stopped answering (set while offline).
    var offlineSince: Date?
    var observedAt: Date
}

/// A change of a watched server.
enum WatchEvent: Sendable, Equatable {
    /// IP or CID ban appeared (`ipBanned` / `cidBanned`).
    case banAppeared(BanStatus, previous: BanStatus?)
    case banLifted(previous: BanStatus, now: BanStatus)
    case offline
    /// Answering again after an outage of at least 10 minutes.
    case online(after: TimeInterval)
    case mapChanged(old: String, new: String)

    var kind: HistoryKind {
        switch self {
        case .banAppeared: return .watchBanAppeared
        case .banLifted: return .watchBanLifted
        case .offline: return .watchOffline
        case .online: return .watchOnline
        case .mapChanged: return .watchMapChanged
        }
    }
}

enum WatchTransitions {
    /// "Yeniden çevrimiçi" is reported only after an outage of at least 10 minutes.
    static let onlineThreshold: TimeInterval = 10 * 60

    static func isBanned(_ status: BanStatus?) -> Bool { status == .ipBanned || status == .cidBanned }

    /// `nil` for undetermined results (they do not move the baseline).
    static func determined(_ status: BanStatus) -> BanStatus? {
        switch status {
        case .ipBanned, .cidBanned, .ipOk, .cidOk, .cidNotApplicable: return status
        case .unknown, .cidUnknown, .unreachable: return nil
        }
    }

    /// Compares a finished check with the baseline. The first observation (no baseline) produces no event.
    static func evaluate(previous: WatchSnapshot?, check: BanCheck) -> (next: WatchSnapshot, events: [WatchEvent]) {
        let online = check.status != .unreachable
        let map = check.info?.map.flatMap { $0.isEmpty ? nil : $0 }
        guard let previous else {
            return (WatchSnapshot(status: determined(check.status), online: online, map: map,
                                  offlineSince: online ? nil : check.checkedAt, observedAt: check.checkedAt), [])
        }
        var events: [WatchEvent] = []
        var next = previous
        next.observedAt = check.checkedAt

        guard online else {
            if previous.online {
                events.append(.offline)
                next.offlineSince = check.checkedAt
            }
            next.online = false
            if next.offlineSince == nil { next.offlineSince = check.checkedAt }
            return (next, events)
        }

        if !previous.online {
            let outage = check.checkedAt.timeIntervalSince(previous.offlineSince ?? previous.observedAt)
            if outage >= onlineThreshold { events.append(.online(after: outage)) }
        }
        next.online = true
        next.offlineSince = nil

        if let status = determined(check.status) {
            if isBanned(status), status != previous.status {
                events.append(.banAppeared(status, previous: previous.status))
            } else if !isBanned(status), let old = previous.status, isBanned(old) {
                events.append(.banLifted(previous: old, now: status))
            }
            next.status = status
        }
        if let map {
            if let old = previous.map, old != map { events.append(.mapChanged(old: old, new: map)) }
            next.map = map
        }
        return (next, events)
    }

    /// History entry of an event (`old`/`new` = ban status or map; `note` = outage minutes for `watchOnline`).
    static func historyEntry(_ event: WatchEvent, server: ServerEntry, at date: Date) -> HistoryEntry {
        switch event {
        case .banAppeared(let status, let previous):
            return HistoryEntry(ts: date, kind: .watchBanAppeared, serverID: server.id, host: server.host,
                                old: previous?.rawValue, new: status.rawValue)
        case .banLifted(let previous, let now):
            return HistoryEntry(ts: date, kind: .watchBanLifted, serverID: server.id, host: server.host,
                                old: previous.rawValue, new: now.rawValue)
        case .offline:
            return HistoryEntry(ts: date, kind: .watchOffline, serverID: server.id, host: server.host)
        case .online(let after):
            return HistoryEntry(ts: date, kind: .watchOnline, serverID: server.id, host: server.host,
                                note: String(Int((after / 60).rounded())))
        case .mapChanged(let old, let new):
            return HistoryEntry(ts: date, kind: .watchMapChanged, serverID: server.id, host: server.host, old: old, new: new)
        }
    }
}

/// `watch-state.json`: the baselines per server (so the first check after a relaunch is not a "first observation").
struct WatchStateStore: Sendable {
    let fileURL: URL

    func load() -> [UUID: WatchSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? HistoryCoding.makeDecoder().decode([String: WatchSnapshot].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    func save(_ state: [UUID: WatchSnapshot]) throws {
        let encoded = Dictionary(uniqueKeysWithValues: state.map { ($0.key.uuidString, $0.value) })
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HistoryCoding.makeEncoder(pretty: true).encode(encoded).write(to: fileURL, options: .atomic)
    }
}

/// §42 notification texts.
enum WatchNotificationText {
    /// §45 gate of each event.
    static func category(of event: WatchEvent) -> NotificationCategory {
        switch event {
        case .banAppeared, .banLifted: return .ban
        case .offline, .online: return .online
        case .mapChanged: return .map
        }
    }

    static func content(for event: WatchEvent, server: ServerEntry) -> NotificationContent {
        let label = server.label
        let key: String
        let title: String
        let body: String
        switch event {
        case .banAppeared(let status, _):
            key = "\(status.rawValue)"
            title = L10n.format(.watchNotifyBanTitle, label)
            body = L10n.format(.watchNotifyBanBody, status.label)
        case .banLifted:
            key = ""
            title = L10n.format(.watchNotifyLiftedTitle, label)
            body = L10n.text(.watchNotifyLiftedBody)
        case .offline:
            key = ""
            title = L10n.format(.watchNotifyOfflineTitle, label)
            body = L10n.text(.watchNotifyOfflineBody)
        case .online(let after):
            key = ""
            title = L10n.format(.watchNotifyOnlineTitle, label)
            body = L10n.format(.watchNotifyOnlineBody, String(Int((after / 60).rounded())))
        case .mapChanged(let old, let new):
            key = new
            title = L10n.format(.watchNotifyMapTitle, label)
            body = L10n.format(.watchNotifyMapBody, old, new)
        }
        return NotificationContent(key: [event.kind.rawValue, server.id.uuidString, key].joined(separator: "|"),
                                   title: title, body: body, category: Self.category(of: event))
    }
}

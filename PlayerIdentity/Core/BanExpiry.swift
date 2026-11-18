import Foundation

// MARK: - §69.1 Ban expiry notifications

/// Which notification a watch record stands for: "lifts in 10 minutes" or "lifted".
enum BanExpiryKind: String, Codable, Sendable, Equatable, CaseIterable {
    case soon
    case ended
}

/// One planned ban expiry notification (`profile.json` → `banExpiryWatch`). A timed ban has one `ended` record and,
/// while the "10 minutes before" setting is on, one `soon` record; each is posted at most once (`notifiedAt`).
struct BanExpiryWatch: Codable, Sendable, Equatable {
    var serverID: UUID
    /// CID of the lookup that found the ban (a new CID means another ban: the record is replaced).
    var cid: String
    var expiresAt: Date
    var notifiedAt: Date?
    var kind: BanExpiryKind

    /// When the notification is due: 10 minutes before the end, or the end itself.
    var fireAt: Date {
        kind == .soon ? expiresAt.addingTimeInterval(-BanExpiryPlanner.leadTime) : expiresAt
    }
}

/// What to do with a due record.
enum BanExpiryDecision: Sendable, Equatable {
    /// Post it now.
    case post
    /// Quiet hours: kept and posted once they are over.
    case postpone
    /// Notifications off (master, ban changes or the server's mode `off`): dropped without a notification.
    case drop
}

/// Pure planning of the ban expiry notifications (no timers, no scheduled local notifications).
enum BanExpiryPlanner {
    /// "10 minutes before".
    static let leadTime: TimeInterval = 10 * 60
    /// The main window lists expiries at most this far ahead.
    static let upcomingWindow: TimeInterval = 24 * 60 * 60
    /// Sent `ended` records are forgotten after this long (the next lookup removes them anyway).
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// The in-app timer checks at least this often (quiet hours ending, settings changes).
    static let maxTimerDelay: TimeInterval = 15 * 60
    /// A due record that could not be posted yet is tried again after this long.
    static let retryDelay: TimeInterval = 60

    /// End of the ban record's active bans: the latest end among the active timed bans; `nil` when nothing is active,
    /// a ban is permanent or an active ban has no known end.
    static func expiry(of result: BanRecordResult) -> Date? {
        let active = result.active
        guard !active.isEmpty else { return nil }
        var latest: Date?
        for entry in active {
            guard !entry.permanent, let expires = entry.expires, expires > result.fetchedAt else { return nil }
            latest = max(latest ?? expires, expires)
        }
        return latest
    }

    /// Records of one server after a successful lookup. A lifted ban (no active timed ban), a disabled switch or an
    /// empty result removes the server's records; the same end and CID keep the existing records (and their
    /// `notifiedAt`); another end or CID replaces them.
    static func reconcile(_ watches: [BanExpiryWatch], serverID: UUID, cid: String, result: BanRecordResult,
                          notify: Bool, soonEnabled: Bool) -> [BanExpiryWatch] {
        let others = watches.filter { $0.serverID != serverID }
        guard notify, let end = expiry(of: result) else { return others }
        let kinds: [BanExpiryKind] = soonEnabled ? [.soon, .ended] : [.ended]
        let mine = kinds.map { kind in
            watches.first { $0.serverID == serverID && $0.kind == kind && $0.cid == cid
                && abs($0.expiresAt.timeIntervalSince(end)) < 1 }
                ?? BanExpiryWatch(serverID: serverID, cid: cid, expiresAt: end, notifiedAt: nil, kind: kind)
        }
        return others + mine
    }

    /// Launch clean-up: records of removed servers, `soon` records while the setting is off and old sent records go.
    static func prune(_ watches: [BanExpiryWatch], serverIDs: Set<UUID>, soonEnabled: Bool, now: Date) -> [BanExpiryWatch] {
        watches.filter { watch in
            guard serverIDs.contains(watch.serverID) else { return false }
            if watch.kind == .soon, !soonEnabled, watch.notifiedAt == nil { return false }
            if let sent = watch.notifiedAt, now.timeIntervalSince(sent) > retention { return false }
            return true
        }
    }

    /// Records due now and not sent yet. A `soon` record whose end has already passed is never due (the `ended`
    /// one covers it: after quiet hours only one notification goes out).
    static func due(_ watches: [BanExpiryWatch], now: Date) -> [BanExpiryWatch] {
        watches.filter { watch in
            guard watch.notifiedAt == nil, now >= watch.fireAt else { return false }
            return watch.kind == .ended || now < watch.expiresAt
        }
    }

    /// `soon` records overtaken by their end without a notification: dropped.
    static func obsolete(_ watches: [BanExpiryWatch], now: Date) -> [BanExpiryWatch] {
        watches.filter { $0.kind == .soon && $0.notifiedAt == nil && now >= $0.expiresAt }
    }

    /// Gate of one due record: master switch + ban changes + the server's mode, then quiet hours (deferred).
    static func decision(policy: NotificationPolicy, server: ServerNotificationSettings?, at date: Date,
                         calendar: Calendar = .current) -> BanExpiryDecision {
        let effective = policy.applying(server)
        guard effective.master, effective.banChanges else { return .drop }
        return effective.quiet.contains(date, calendar: calendar) ? .postpone : .post
    }

    /// Seconds until the in-app timer should look again; `nil` when nothing is pending (the timer stops).
    static func nextDelay(_ watches: [BanExpiryWatch], now: Date) -> TimeInterval? {
        let pending = watches.filter { $0.notifiedAt == nil }
        guard !pending.isEmpty else { return nil }
        let delays = pending.map { $0.fireAt.timeIntervalSince(now) }
        var next = delays.filter { $0 > 0 }.min() ?? maxTimerDelay
        // Due but held back (quiet hours, permission): look again in a minute, never in a tight loop.
        if delays.contains(where: { $0 <= 0 }) { next = min(next, retryDelay) }
        return min(max(next, 1), maxTimerDelay)
    }

    /// Unsent `ended` records ending within a day (soonest first), for the main window row.
    static func upcoming(_ watches: [BanExpiryWatch], now: Date) -> [BanExpiryWatch] {
        watches.filter { $0.kind == .ended && $0.notifiedAt == nil && $0.expiresAt > now
            && $0.expiresAt.timeIntervalSince(now) <= upcomingWindow }
            .sorted { $0.expiresAt < $1.expiresAt }
    }
}

enum BanExpiryText {
    static func content(for watch: BanExpiryWatch, serverLabel: String) -> NotificationContent {
        let key = ["banExpiry", watch.kind.rawValue, watch.serverID.uuidString,
                   String(Int(watch.expiresAt.timeIntervalSince1970))].joined(separator: "|")
        switch watch.kind {
        case .soon:
            return NotificationContent(key: key, title: L10n.text(.banExpirySoonTitle),
                                       body: L10n.format(.banExpirySoonBody, serverLabel, time(watch.expiresAt)),
                                       category: .ban, serverID: watch.serverID)
        case .ended:
            return NotificationContent(key: key, title: L10n.text(.banExpiryEndedTitle),
                                       body: L10n.format(.banExpiryEndedBody, serverLabel),
                                       category: .ban, serverID: watch.serverID)
        }
    }

    /// Short time in the app language.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.currentLanguage.rawValue)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "Scheduled notification: 14:50 · 15:00" (the planned times of a server's records).
    static func scheduled(_ watches: [BanExpiryWatch]) -> String? {
        let times = watches.sorted { $0.fireAt < $1.fireAt }.map { BanRecordText.date($0.fireAt) }
        return times.isEmpty ? nil : L10n.format(.banExpiryScheduled, times.joined(separator: " · "))
    }

    /// "<server>: in 2h 5m (15:00)".
    static func upcomingLine(_ watch: BanExpiryWatch, serverLabel: String, now: Date) -> String {
        L10n.format(.banExpiryUpcomingLine, serverLabel, BanRecordText.remaining(watch.expiresAt.timeIntervalSince(now)),
                    BanRecordText.date(watch.expiresAt))
    }
}

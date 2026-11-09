import Foundation

// MARK: - Note (§32)

enum ServerNote {
    static let maxLength = 2000

    /// At most 2000 characters (grapheme clusters, as the user sees them).
    static func isValid(_ note: String) -> Bool {
        note.count <= maxLength
    }

    /// Input longer than the limit is cut at 2000 characters.
    static func clamped(_ note: String) -> String {
        note.count <= maxLength ? note : String(note.prefix(maxLength))
    }
}

// MARK: - Appeal (§32)

enum AppealStatus: String, Codable, Sendable, CaseIterable {
    case sent
    case answered
    case rejected
    case accepted

    /// Allowed next states. `accepted` is final; a rejected appeal can be sent again.
    var nextStates: [AppealStatus] {
        switch self {
        case .sent: return [.answered, .rejected, .accepted]
        case .answered: return [.sent, .rejected, .accepted]
        case .rejected: return [.sent]
        case .accepted: return []
        }
    }

    func canTransition(to next: AppealStatus) -> Bool {
        next == self || nextStates.contains(next)
    }

    /// Still waiting for a decision (a follow-up reminder applies).
    var isOpen: Bool { self == .sent || self == .answered }

    var label: String {
        switch self {
        case .sent: return L10n.text(.appealStatusSent)
        case .answered: return L10n.text(.appealStatusAnswered)
        case .rejected: return L10n.text(.appealStatusRejected)
        case .accepted: return L10n.text(.appealStatusAccepted)
        }
    }
}

/// Suggested channels; `Appeal.channel` stores the raw value (any other text is kept as is).
enum AppealChannel: String, Sendable, CaseIterable {
    case discord
    case telegram
    case forum
    case email
    case other

    var label: String {
        switch self {
        case .discord: return L10n.text(.appealChannelDiscord)
        case .telegram: return L10n.text(.appealChannelTelegram)
        case .forum: return L10n.text(.appealChannelForum)
        case .email: return L10n.text(.appealChannelEmail)
        case .other: return L10n.text(.appealChannelOther)
        }
    }
}

/// §36 timeline entry: a status and when it was set.
struct AppealEvent: Codable, Sendable, Equatable {
    var status: AppealStatus
    var at: Date
}

struct Appeal: Codable, Sendable, Equatable {
    static let maxSummaryLength = ServerNote.maxLength
    /// §36: at most 20 timeline entries (the oldest are dropped).
    static let maxEvents = 20

    enum Problem: Error, Sendable, Equatable, CaseIterable {
        case channelEmpty
        case summaryTooLong
        case followUpBeforeSent

        var text: String {
            switch self {
            case .channelEmpty: return L10n.text(.appealProblemChannel)
            case .summaryTooLong: return L10n.text(.appealProblemSummary)
            case .followUpBeforeSent: return L10n.text(.appealProblemFollowUp)
            }
        }
    }

    var sentAt: Date
    var channel: String
    var status: AppealStatus
    var followUpAt: Date?
    var summary: String
    /// §36 status timeline, oldest first (absent in v2.0/v2.1 records).
    var events: [AppealEvent]
    /// §36: when the follow-up reminder was posted; set once per follow-up date.
    var notifiedAt: Date?

    init(sentAt: Date, channel: String, status: AppealStatus = .sent, followUpAt: Date? = nil, summary: String = "",
         events: [AppealEvent] = [], notifiedAt: Date? = nil) {
        self.sentAt = sentAt
        self.channel = channel
        self.status = status
        self.followUpAt = followUpAt
        self.summary = summary
        self.events = events
        self.notifiedAt = notifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sentAt, channel, status, followUpAt, summary, events, notifiedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        channel = try container.decode(String.self, forKey: .channel)
        status = try container.decode(AppealStatus.self, forKey: .status)
        followUpAt = try container.decodeIfPresent(Date.self, forKey: .followUpAt)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        events = try container.decodeIfPresent([AppealEvent].self, forKey: .events) ?? []
        notifiedAt = try container.decodeIfPresent(Date.self, forKey: .notifiedAt)
    }

    /// The fields the user edits (timeline and reminder bookkeeping left out).
    func hasSameContent(as other: Appeal) -> Bool {
        sentAt == other.sentAt && channel == other.channel && status == other.status && followUpAt == other.followUpAt
            && summary == other.summary
    }

    /// Timeline shown in the details: the stored events, or the current status at `sentAt` for older records.
    var timeline: [AppealEvent] {
        events.isEmpty ? [AppealEvent(status: status, at: sentAt)] : events
    }

    /// Adds a timeline entry, keeping the newest 20.
    func appendingEvent(_ status: AppealStatus, at date: Date) -> Appeal {
        var copy = self
        copy.events.append(AppealEvent(status: status, at: date))
        if copy.events.count > Self.maxEvents { copy.events.removeFirst(copy.events.count - Self.maxEvents) }
        return copy
    }

    /// "Takip tarihini ertele": +`days` from the follow-up date, or from now if it has passed (or is not set).
    /// The reminder is armed again for the new date.
    func postponed(byDays days: Int, now: Date, calendar: Calendar = .current) -> Appeal {
        var copy = self
        let base = max(followUpAt ?? now, now)
        copy.followUpAt = calendar.date(byAdding: .day, value: days, to: base) ?? base.addingTimeInterval(Double(days) * 86_400)
        copy.notifiedAt = nil
        return copy
    }

    /// §36: the follow-up date has passed, the appeal is open and no reminder was posted for this date yet.
    func needsReminder(now: Date) -> Bool {
        guard isFollowUpDue(now: now), let followUpAt else { return false }
        guard let notifiedAt else { return true }
        return notifiedAt < followUpAt
    }

    init(sentAt: Date, channel: AppealChannel, status: AppealStatus = .sent, followUpAt: Date? = nil,
         summary: String = "") {
        self.init(sentAt: sentAt, channel: channel.rawValue, status: status, followUpAt: followUpAt, summary: summary)
    }

    /// Channel as shown: the localized name of a known channel, the stored text otherwise.
    var channelLabel: String { knownChannel?.label ?? channel }

    /// Known channel, `nil` for free text.
    var knownChannel: AppealChannel? { AppealChannel(rawValue: channel.trimmingCharacters(in: .whitespaces).lowercased()) }

    var problems: [Problem] {
        var list: [Problem] = []
        if channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.append(.channelEmpty) }
        if summary.count > Self.maxSummaryLength { list.append(.summaryTooLong) }
        if let followUpAt, followUpAt < sentAt { list.append(.followUpBeforeSent) }
        return list
    }

    var isValid: Bool { problems.isEmpty }

    /// 🔔 in the row: the follow-up date has passed and the appeal is still open.
    func isFollowUpDue(now: Date) -> Bool {
        guard status.isOpen, let followUpAt else { return false }
        return followUpAt <= now
    }

    /// Status change, refused if the transition is not allowed.
    func moved(to next: AppealStatus) -> Appeal? {
        guard status.canTransition(to: next) else { return nil }
        var copy = self
        copy.status = next
        return copy
    }
}

enum AppealEditError: Error, Sendable, Equatable {
    case serverNotFound
    case invalid([Appeal.Problem])
    case transitionNotAllowed(from: AppealStatus, to: AppealStatus)
    case noteTooLong
}

/// Note and appeal edits on the server list (pure; the caller persists and records history).
enum ServerAnnotations {
    static func setNote(_ note: String, for id: UUID, in servers: [ServerEntry]) -> Result<[ServerEntry], AppealEditError> {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return .failure(.serverNotFound) }
        guard ServerNote.isValid(note) else { return .failure(.noteTooLong) }
        var copy = servers
        copy[index].note = note
        return .success(copy)
    }

    /// Creates, updates (status transitions are checked) or removes (`nil`) the appeal of a server.
    /// §36: the timeline is kept and gets an entry when the status changes (a new appeal starts with one);
    /// a changed follow-up date arms the reminder again.
    static func setAppeal(_ appeal: Appeal?, for id: UUID, in servers: [ServerEntry],
                          now: Date) -> Result<[ServerEntry], AppealEditError> {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return .failure(.serverNotFound) }
        var stored = appeal
        if let appeal {
            guard appeal.isValid else { return .failure(.invalid(appeal.problems)) }
            let old = servers[index].appeal
            if let old, !old.status.canTransition(to: appeal.status) {
                return .failure(.transitionNotAllowed(from: old.status, to: appeal.status))
            }
            stored = merged(appeal, previous: old, now: now)
        }
        var copy = servers
        copy[index].appeal = stored
        return .success(copy)
    }

    /// Carries the timeline and reminder state of the previous version into an edited appeal.
    static func merged(_ appeal: Appeal, previous: Appeal?, now: Date) -> Appeal {
        var result = appeal
        guard let previous else {
            if result.events.isEmpty { result = result.appendingEvent(appeal.status, at: appeal.sentAt) }
            return result
        }
        result.events = previous.events.isEmpty ? [AppealEvent(status: previous.status, at: previous.sentAt)] : previous.events
        result.notifiedAt = previous.followUpAt == appeal.followUpAt ? previous.notifiedAt : nil
        if previous.status != appeal.status { result = result.appendingEvent(appeal.status, at: now) }
        return result
    }

    /// §36 note history: `old`/`new` cut to 500 characters; `nil` if the note did not change.
    static let noteHistoryLimit = 500

    static func noteHistoryEntry(old: String, new: String, server: ServerEntry, now: Date) -> HistoryEntry? {
        guard old != new else { return nil }
        func cut(_ text: String) -> String? {
            guard !text.isEmpty else { return nil }
            return text.count <= noteHistoryLimit ? text : String(text.prefix(noteHistoryLimit - 1)) + "…"
        }
        return HistoryEntry(ts: now, kind: .note, serverID: server.id, host: server.host, old: cut(old), new: cut(new))
    }

    /// History entry of a saved appeal change: `old`/`new` = status, `note` = channel; `nil` if nothing changed.
    /// A removed appeal is recorded with `new == nil`.
    static func historyEntry(old: Appeal?, new: Appeal?, server: ServerEntry, now: Date) -> HistoryEntry? {
        switch (old, new) {
        case (nil, nil): return nil
        case let (old?, new?) where old.hasSameContent(as: new): return nil
        default: break
        }
        return HistoryEntry(ts: now, kind: .appeal, serverID: server.id, host: server.host,
                            old: old?.status.rawValue, new: new?.status.rawValue, note: (new ?? old)?.channel)
    }
}

extension AppealEditError {
    var text: String {
        switch self {
        case .serverNotFound: return L10n.text(.errorInvalidHost)
        case .invalid(let problems): return problems.map(\.text).joined(separator: "\n")
        case .transitionNotAllowed(let from, let to): return L10n.format(.appealProblemTransition, from.label, to.label)
        case .noteTooLong: return L10n.text(.notesTooLong)
        }
    }
}

// MARK: - §36 Follow-up reminders

/// Which appeals need their one-time follow-up notification, and marking them as notified.
/// The notification text is built by the caller (UI layer).
enum AppealReminder {
    struct Due: Sendable, Equatable {
        let serverID: UUID
        let label: String
        let followUpAt: Date
    }

    /// Servers whose reminder is due; empty when notifications are turned off (nothing is marked then either).
    static func due(_ servers: [ServerEntry], now: Date, notificationsEnabled: Bool) -> [Due] {
        guard notificationsEnabled else { return [] }
        return servers.compactMap { entry in
            guard let appeal = entry.appeal, appeal.needsReminder(now: now), let date = appeal.followUpAt else { return nil }
            return Due(serverID: entry.id, label: entry.label, followUpAt: date)
        }
    }

    /// Sets `notifiedAt` on the given servers' appeals.
    static func markNotified(_ ids: Set<UUID>, in servers: [ServerEntry], at date: Date) -> [ServerEntry] {
        servers.map { entry in
            guard ids.contains(entry.id), entry.appeal != nil else { return entry }
            var copy = entry
            copy.appeal?.notifiedAt = date
            return copy
        }
    }
}

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
}

/// Suggested channels; `Appeal.channel` stores the raw value (any other text is kept as is).
enum AppealChannel: String, Sendable, CaseIterable {
    case discord
    case telegram
    case forum
    case email
    case other
}

struct Appeal: Codable, Sendable, Equatable {
    static let maxSummaryLength = ServerNote.maxLength

    enum Problem: Error, Sendable, Equatable, CaseIterable {
        case channelEmpty
        case summaryTooLong
        case followUpBeforeSent
    }

    var sentAt: Date
    var channel: String
    var status: AppealStatus
    var followUpAt: Date?
    var summary: String

    init(sentAt: Date, channel: String, status: AppealStatus = .sent, followUpAt: Date? = nil, summary: String = "") {
        self.sentAt = sentAt
        self.channel = channel
        self.status = status
        self.followUpAt = followUpAt
        self.summary = summary
    }

    init(sentAt: Date, channel: AppealChannel, status: AppealStatus = .sent, followUpAt: Date? = nil,
         summary: String = "") {
        self.init(sentAt: sentAt, channel: channel.rawValue, status: status, followUpAt: followUpAt, summary: summary)
    }

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
    static func setAppeal(_ appeal: Appeal?, for id: UUID,
                          in servers: [ServerEntry]) -> Result<[ServerEntry], AppealEditError> {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return .failure(.serverNotFound) }
        if let appeal {
            guard appeal.isValid else { return .failure(.invalid(appeal.problems)) }
            if let old = servers[index].appeal, !old.status.canTransition(to: appeal.status) {
                return .failure(.transitionNotAllowed(from: old.status, to: appeal.status))
            }
        }
        var copy = servers
        copy[index].appeal = appeal
        return .success(copy)
    }

    /// History entry of a saved appeal change: `old`/`new` = status, `note` = channel; `nil` if nothing changed.
    /// A removed appeal is recorded with `new == nil`.
    static func historyEntry(old: Appeal?, new: Appeal?, server: ServerEntry, now: Date) -> HistoryEntry? {
        guard old != new else { return nil }
        return HistoryEntry(ts: now, kind: .appeal, serverID: server.id, host: server.host,
                            old: old?.status.rawValue, new: new?.status.rawValue, note: (new ?? old)?.channel)
    }
}

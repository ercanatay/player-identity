import Foundation
@preconcurrency import UserNotifications

// MARK: - Notification center (DI, §23)

enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

protocol UserNotifying: Sendable {
    func authorization() async -> NotificationAuthorization
    /// Shows the system permission prompt; returns whether notifications are allowed.
    func requestAuthorization() async -> Bool
    /// Throws when the notification center refused the request (nothing was shown).
    func post(_ content: NotificationContent) async throws
}

struct NotificationContent: Sendable, Equatable {
    /// Dedupe key: kind + server + new value.
    let key: String
    let title: String
    let body: String
    /// §45 which switch gates this notification.
    var category: NotificationCategory = .general
}

/// Does nothing (default in tests and when notifications are unavailable).
struct NoopNotifier: UserNotifying {
    init() {}
    func authorization() async -> NotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func post(_ content: NotificationContent) async throws {}
}

struct SystemNotifier: UserNotifying {
    init() {}

    func authorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ content: NotificationContent) async throws {
        let message = UNMutableNotificationContent()
        message.title = content.title
        message.body = content.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: message, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Planning

enum NotificationPlanner {
    static let notifyingKinds: Set<HistoryKind> = [.banAppeared, .banLifted, .ipChanged, .identityChanged, .fixAttempt]

    /// Notification for a history entry; `nil` for other kinds and for first observations (`old == nil`,
    /// i.e. the first run). `fixMessage` is the localized outcome of a fix attempt.
    static func content(for entry: HistoryEntry, serverLabel: String?, fixMessage: String? = nil) -> NotificationContent? {
        guard notifyingKinds.contains(entry.kind) else { return nil }
        if entry.kind != .fixAttempt, entry.old == nil { return nil }
        let server = serverLabel ?? entry.host ?? ""
        let key = [entry.kind.rawValue, entry.serverID?.uuidString ?? "", entry.new ?? "", entry.note ?? ""]
            .joined(separator: "|")
        let old = entry.old ?? ""
        let new = entry.new ?? ""
        switch entry.kind {
        case .banAppeared:
            let label = entry.new.flatMap(BanStatus.init(rawValue:))?.label ?? new
            return NotificationContent(key: key, title: L10n.text(.notifyBanAppearedTitle),
                                       body: L10n.format(.notifyServerBody, server, label), category: .ban)
        case .banLifted:
            return NotificationContent(key: key, title: L10n.text(.notifyBanLiftedTitle),
                                       body: L10n.format(.notifyServerBody, server, L10n.text(.banStatusNoBlock)),
                                       category: .ban)
        case .ipChanged:
            return NotificationContent(key: key, title: L10n.text(.notifyIPChangedTitle),
                                       body: L10n.format(.notifyChangeBody, old, new))
        case .identityChanged:
            return NotificationContent(key: key, title: L10n.text(.notifyIdentityChangedTitle),
                                       body: L10n.format(.notifyChangeBody, old, new))
        case .fixAttempt:
            return NotificationContent(key: key, title: L10n.text(.notifyFixAttemptTitle),
                                       body: L10n.format(.notifyServerBody, server, fixMessage ?? entry.note ?? ""))
        case .refresh, .nameChanged, .modelChanged, .apply, .appUpdateAvailable, .appeal, .note, .watchBanAppeared,
             .watchBanLifted, .watchOffline, .watchOnline, .watchMapChanged, .configOverrideRemoved:
            return nil
        }
    }
}

/// Posts notifications for history transitions: setting gate, 10-minute dedupe per event, permission asked
/// only right before the first notification.
///
/// The dedupe time of a notification is recorded only once it was actually posted: a refused permission or a
/// failed post leaves it eligible for the next attempt. Notifications being posted are held back from a parallel
/// `handle` call, so the same event is never posted twice at once.
actor NotificationDispatcher {
    static let dedupeInterval: TimeInterval = 10 * 60

    private let notifier: any UserNotifying
    private let now: @Sendable () -> Date
    private var lastSent: [String: Date] = [:]
    private var inFlight: Set<String> = []
    /// Permission seen by the last `handle` call that had something to post (`nil` before that).
    private(set) var lastAuthorization: NotificationAuthorization?

    init(notifier: any UserNotifying, now: @escaping @Sendable () -> Date) {
        self.notifier = notifier
        self.now = now
    }

    /// Returns the notifications actually posted (not the ones held back, refused or failed).
    @discardableResult
    func handle(_ contents: [NotificationContent], enabled: Bool,
                policy: NotificationPolicy? = nil) async -> [NotificationContent] {
        guard enabled else { return [] }
        let time = now()
        let fresh = contents.filter { content in
            if let policy, !policy.allows(content.category, at: time) { return false }
            guard !inFlight.contains(content.key) else { return false }
            guard let last = lastSent[content.key] else { return true }
            return time.timeIntervalSince(last) >= Self.dedupeInterval
        }
        guard !fresh.isEmpty else { return [] }
        let keys = Set(fresh.map(\.key))
        inFlight.formUnion(keys)
        defer { inFlight.subtract(keys) }
        let authorization: NotificationAuthorization
        switch await notifier.authorization() {
        case .denied: authorization = .denied
        case .notDetermined: authorization = await notifier.requestAuthorization() ? .authorized : .denied
        case .authorized: authorization = .authorized
        }
        lastAuthorization = authorization
        guard authorization == .authorized else { return [] }
        var posted: [NotificationContent] = []
        for content in fresh {
            do {
                try await notifier.post(content)
            } catch {
                continue   // not recorded: the next attempt may post it
            }
            lastSent[content.key] = time
            posted.append(content)
        }
        return posted
    }

    /// Current permission (Settings shows a warning when it was refused); also updates `lastAuthorization`.
    func currentAuthorization() async -> NotificationAuthorization {
        let status = await notifier.authorization()
        lastAuthorization = status
        return status
    }
}

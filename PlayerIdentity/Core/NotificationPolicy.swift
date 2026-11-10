import Foundation

/// §45 which switch gates a notification.
enum NotificationCategory: String, Sendable, Equatable {
    case general
    case ban
    case online
    case map
}

/// §45 quiet-hours window in minutes since midnight; may cross midnight (23:00–08:00).
struct QuietHours: Sendable, Equatable {
    static let defaultStart = "23:00"
    static let defaultEnd = "08:00"

    var enabled: Bool
    var start: String
    var end: String

    /// `HH:mm` → minutes since midnight; `nil` if malformed.
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    static func text(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// Start == end means an empty window (never quiet).
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled,
              let s = Self.minutes(start) ?? Self.minutes(Self.defaultStart),
              let e = Self.minutes(end) ?? Self.minutes(Self.defaultEnd) else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if s == e { return false }
        return s < e ? (now >= s && now < e) : (now >= s || now < e)
    }
}

/// §45 notification gates: master switch, per-category switches and quiet hours.
struct NotificationPolicy: Sendable, Equatable {
    var master = true
    var banChanges = true
    var onlineChanges = true
    var mapChanges = true
    var quiet = QuietHours(enabled: false, start: QuietHours.defaultStart, end: QuietHours.defaultEnd)

    func allows(_ category: NotificationCategory, at date: Date, calendar: Calendar = .current) -> Bool {
        guard master, !quiet.contains(date, calendar: calendar) else { return false }
        switch category {
        case .general: return true
        case .ban: return banChanges
        case .online: return onlineChanges
        case .map: return mapChanges
        }
    }
}

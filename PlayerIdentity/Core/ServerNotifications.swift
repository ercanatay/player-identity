import Foundation

// MARK: - §56 Per-server notification thresholds

/// What a server notifies about, on top of the general notification settings (§45).
enum ServerNotificationMode: String, CaseIterable, Codable, Sendable, Equatable {
    /// Follows the general settings (master switch, category switches).
    case inherit
    /// Ban, online and map changes, whatever the category switches say (the master switch still applies).
    case all
    /// Only ban appeared / lifted.
    case bansOnly
    /// Nothing from this server is notified (history is still written).
    case off
}

/// Quiet hours for one server: the general window, or always on / off for this server.
enum QuietHoursOverride: String, CaseIterable, Codable, Sendable, Equatable {
    case inherit
    /// The general quiet-hours window applies even when it is switched off in Settings.
    case on
    /// This server is never held back by quiet hours.
    case off
}

/// `ServerEntry.notifications` (§56). Absent in old records (= every field at its default, i.e. inherit).
struct ServerNotificationSettings: Codable, Sendable, Equatable {
    static let maxPingMs = 5000
    static let maxPlayers = 256

    var mode: ServerNotificationMode
    /// Online / map notifications only while the measured ping is at most this many ms; 0 = off.
    var pingThresholdMs: Int
    /// Online / map notifications only with at least this many players on the server; 0 = off.
    var playersAtLeast: Int
    var quietHoursOverride: QuietHoursOverride

    init(mode: ServerNotificationMode = .inherit, pingThresholdMs: Int = 0, playersAtLeast: Int = 0,
         quietHoursOverride: QuietHoursOverride = .inherit) {
        self.mode = mode
        self.pingThresholdMs = pingThresholdMs
        self.playersAtLeast = playersAtLeast
        self.quietHoursOverride = quietHoursOverride
    }

    /// Every field at its default: stored as `nil` (no override).
    var isDefault: Bool { self == ServerNotificationSettings() }

    /// Whether the thresholds are within their ranges.
    var isValid: Bool {
        (0...Self.maxPingMs).contains(pingThresholdMs) && (0...Self.maxPlayers).contains(playersAtLeast)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, pingThresholdMs, playersAtLeast, quietHoursOverride
    }

    /// Tolerant: an unknown mode / override falls back to `inherit` and an out-of-range threshold to 0 (off), so a
    /// hand-edited or newer record never makes the whole `profile.json` unreadable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decodeIfPresent(String.self, forKey: .mode))
            .flatMap(ServerNotificationMode.init(rawValue:)) ?? .inherit
        quietHoursOverride = (try? container.decodeIfPresent(String.self, forKey: .quietHoursOverride))
            .flatMap(QuietHoursOverride.init(rawValue:)) ?? .inherit
        let ping = (try? container.decodeIfPresent(Int.self, forKey: .pingThresholdMs)) ?? 0
        let players = (try? container.decodeIfPresent(Int.self, forKey: .playersAtLeast)) ?? 0
        pingThresholdMs = (0...Self.maxPingMs).contains(ping) ? ping : 0
        playersAtLeast = (0...Self.maxPlayers).contains(players) ? players : 0
    }
}

/// Why a threshold text was rejected.
enum ServerNotificationThresholdError: Error, Sendable, Equatable {
    /// Not a whole number (letters, sign, decimals).
    case notANumber
    case tooLarge(max: Int)
}

enum ServerNotificationThresholds {
    /// Threshold field text → value: empty = 0 (off); digits only; at most `max`.
    static func parse(_ text: String, max: Int) -> Result<Int, ServerNotificationThresholdError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(0) }
        guard trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return .failure(.notANumber) }
        let digits = trimmed.drop { $0 == "0" }
        guard digits.count <= String(max).count else { return .failure(.tooLarge(max: max)) }
        let value = Int(digits) ?? 0
        return value <= max ? .success(value) : .failure(.tooLarge(max: max))
    }

    static func parsePing(_ text: String) -> Result<Int, ServerNotificationThresholdError> {
        parse(text, max: ServerNotificationSettings.maxPingMs)
    }

    static func parsePlayers(_ text: String) -> Result<Int, ServerNotificationThresholdError> {
        parse(text, max: ServerNotificationSettings.maxPlayers)
    }
}

extension NotificationPolicy {
    /// The general policy with a server's override applied (§56). The master switch is never turned on by a server.
    func applying(_ settings: ServerNotificationSettings?) -> NotificationPolicy {
        guard let settings else { return self }
        var policy = self
        switch settings.mode {
        case .inherit: break
        case .all:
            policy.banChanges = true
            policy.onlineChanges = true
            policy.mapChanges = true
        case .bansOnly:
            policy.banChanges = true
            policy.onlineChanges = false
            policy.mapChanges = false
        case .off:
            policy.master = false
        }
        switch settings.quietHoursOverride {
        case .inherit: break
        case .on: policy.quiet.enabled = true
        case .off: policy.quiet.enabled = false
        }
        return policy
    }
}

/// §56 evaluation: general settings + server override. Events below a threshold are not notified; the history entry
/// is written regardless (the caller records history before asking this).
enum ServerNotificationRules {
    /// Whether the thresholds let the event through. They apply to "back online" and "map changed" (the events that
    /// say the server is worth joining); ban and offline events are never held back by a threshold. A threshold that
    /// cannot be checked (no ping / player count in the reply) holds the event back.
    static func passesThresholds(_ event: WatchEvent, settings: ServerNotificationSettings?, info: ServerInfo?) -> Bool {
        guard let settings else { return true }
        switch event {
        case .banAppeared, .banLifted, .offline: return true
        case .online, .mapChanged: break
        }
        if settings.pingThresholdMs > 0 {
            guard let ping = info?.pingMillis, ping <= settings.pingThresholdMs else { return false }
        }
        if settings.playersAtLeast > 0 {
            guard let players = info?.players, players >= settings.playersAtLeast else { return false }
        }
        return true
    }

    /// Mode and quiet hours (thresholds are checked separately, when the event is detected).
    static func allows(_ category: NotificationCategory, settings: ServerNotificationSettings?, policy: NotificationPolicy,
                       at date: Date, calendar: Calendar = .current) -> Bool {
        policy.applying(settings).allows(category, at: date, calendar: calendar)
    }

    /// Full decision for a watch event: thresholds, mode, category switch, quiet hours and the master switch.
    static func shouldNotify(_ event: WatchEvent, settings: ServerNotificationSettings?, info: ServerInfo?,
                             policy: NotificationPolicy, at date: Date, calendar: Calendar = .current) -> Bool {
        passesThresholds(event, settings: settings, info: info)
            && allows(WatchNotificationText.category(of: event), settings: settings, policy: policy, at: date,
                      calendar: calendar)
    }
}

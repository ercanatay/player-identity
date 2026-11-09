import Foundation
import ServiceManagement

// MARK: - §30 Menu bar item

/// Status item content: SF Symbol, tint and the status line of the menu.
struct MenuBarPresentation: Sendable, Equatable {
    enum Tint: Sendable, Equatable {
        case green
        case orange
        case red
        /// Not checked yet.
        case neutral
    }

    let symbolName: String
    let tint: Tint
    /// First (disabled) menu line, also the item's tooltip.
    let title: String

    static let uncheckedSymbol = "circle.dashed"

    /// `nil` = no refresh has finished yet.
    static func make(overall: StatusLevel?) -> MenuBarPresentation {
        guard let overall else {
            return MenuBarPresentation(symbolName: uncheckedSymbol, tint: .neutral, title: L10n.text(.topbarNotChecked))
        }
        let tint: Tint
        switch overall {
        case .green: tint = .green
        case .orange: tint = .orange
        case .red: tint = .red
        }
        return MenuBarPresentation(symbolName: overall.symbolName, tint: tint, title: overall.label)
    }
}

/// Background refresh every 30 minutes, only while the menu bar mode is on.
enum MenuBarRefreshSchedule {
    static let interval: TimeInterval = 30 * 60

    static func isDue(lastRefresh: Date?, now: Date, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval || lastRefresh > now
    }

    /// Seconds until the next refresh; `nil` while the menu bar mode is off (no timer runs).
    static func delay(lastRefresh: Date?, now: Date, enabled: Bool) -> TimeInterval? {
        guard enabled else { return nil }
        guard let lastRefresh, lastRefresh <= now else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastRefresh))
    }
}

/// §30 switches in Settings > General (both off by default). "Launch at login" itself lives in the system
/// (`SMAppService`); only the menu bar switch is a preference.
struct MenuBarPreferences: Sendable, Equatable {
    var showInMenuBar = false

    init(showInMenuBar: Bool = false) {
        self.showInMenuBar = showInMenuBar
    }

    init(defaults: UserDefaults) {
        showInMenuBar = defaults.bool(forKey: DefaultsKey.showInMenuBar)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(showInMenuBar, forKey: DefaultsKey.showInMenuBar)
    }
}

// MARK: - Launch at login

enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case notRegistered
    /// Registered but waiting for approval in System Settings > General > Login Items.
    case requiresApproval
    case notFound

    var isOn: Bool { self == .enabled || self == .requiresApproval }
}

/// Registration failure shown to the user (§30); `detail` is the system's description.
enum LoginItemError: Error, Sendable, Equatable {
    case registerFailed(detail: String)
    case unregisterFailed(detail: String)
}

protocol LoginItemControlling: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp` (macOS 13+).
struct MainAppLoginItem: LoginItemControlling {
    init() {}

    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

enum LoginItemSwitch {
    /// Turns "launch at login" on or off; returns the resulting status or the error to show.
    static func set(_ enabled: Bool, using controller: any LoginItemControlling) -> Result<LoginItemStatus, LoginItemError> {
        let current = controller.status()
        if enabled == current.isOn { return .success(current) }
        do {
            if enabled { try controller.register() } else { try controller.unregister() }
        } catch {
            let detail = error.localizedDescription
            return .failure(enabled ? .registerFailed(detail: detail) : .unregisterFailed(detail: detail))
        }
        return .success(controller.status())
    }
}

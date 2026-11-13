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

// MARK: - §60 Quick CID

/// What a quick menu item copies.
enum MenuBarCopyKind: Sendable, Equatable {
    case cid(UUID)
    case rawID
}

/// Result of the last copy from the menu: "Copied" for 2 seconds, a failure until the next copy.
enum MenuBarCopyFeedback: Sendable, Equatable {
    case copied(MenuBarCopyKind, at: Date)
    case failed(MenuBarCopyKind, at: Date)

    static let confirmationDuration: TimeInterval = 2

    /// The confirmation shows for `confirmationDuration` seconds; a failure stays until it is replaced.
    func isVisible(now: Date) -> Bool {
        switch self {
        case .copied(_, let at):
            let age = now.timeIntervalSince(at)
            return age >= 0 && age < Self.confirmationDuration
        case .failed:
            return true
        }
    }
}

/// One server of the menu's server submenu.
struct MenuBarServerChoice: Sendable, Equatable, Identifiable {
    let id: UUID
    let label: String
    /// `nil` = no CID yet (no identity or unusable host): "Copy CID" is disabled.
    let cid: String?
    let canRecheck: Bool
    /// §65.2 "Diagnose" is enabled (not while it runs or while a data operation runs).
    var canDiagnose = true
    /// §65.2 menu bar diagnosis of this server: running, or the result line.
    var diagnosis: MenuBarDiagnosisState? = nil

    /// Submenu title: the label, plus `teşhis sürüyor…` while a diagnosis runs.
    var title: String {
        guard diagnosis == .running else { return label }
        return L10n.format(.menuBarStatusLine, label, L10n.text(.menuBarDiagnoseRunning))
    }

    /// The server submenu in order: Copy CID, Check Again, Diagnose, then the diagnosis line (if any).
    var items: [MenuBarServerItem] {
        var items: [MenuBarServerItem] = [
            .copyCID(enabled: cid != nil),
            .recheck(enabled: canRecheck),
            .diagnose(enabled: canDiagnose && diagnosis != .running),
        ]
        if let diagnosis { items.append(.diagnosisLine(MenuBarDiagnosisText.line(diagnosis))) }
        return items
    }
}

/// One item of a server's submenu (§60, §65.2).
enum MenuBarServerItem: Sendable, Equatable {
    case copyCID(enabled: Bool)
    case recheck(enabled: Bool)
    case diagnose(enabled: Bool)
    /// `teşhis sürüyor…` or `CID ban · 1,2 sn`; always disabled (no action).
    case diagnosisLine(String)
}

/// Items of the top of the menu bar menu (the Refresh/Settings/Show/Quit block follows them).
enum MenuBarQuickItem: Sendable, Equatable {
    /// Overall status + last check time; always disabled (gray, no action).
    case status(String)
    /// "Copy CID" for the selected server (or the first one); disabled without a CID.
    case copyCID(serverID: UUID?, label: String?, enabled: Bool)
    case copyRawID(enabled: Bool)
    case copied
    case copyFailed
    case servers([MenuBarServerChoice])
}

enum MenuBarQuickMenu {
    /// The selected server if it still exists, otherwise the first server.
    static func cidServer(selected: UUID?, servers: [UUID]) -> UUID? {
        if let selected, servers.contains(selected) { return selected }
        return servers.first
    }

    static func statusLine(title: String, lastChecked: Date?) -> String {
        L10n.format(.menuBarStatusLine, title, L10n.format(.topbarLastCheck, TimeText.format(lastChecked)))
    }

    /// Nothing while the menu bar mode is off (the status item is not inserted then).
    static func items(enabled: Bool, statusTitle: String, lastChecked: Date?, servers: [MenuBarServerChoice],
                      selected: UUID?, rawID: String?, feedback: MenuBarCopyFeedback?, now: Date) -> [MenuBarQuickItem] {
        guard enabled else { return [] }
        let target = cidServer(selected: selected, servers: servers.map(\.id)).flatMap { id in servers.first { $0.id == id } }
        var items: [MenuBarQuickItem] = [
            .status(statusLine(title: statusTitle, lastChecked: lastChecked)),
            .copyCID(serverID: target?.id, label: target?.label, enabled: target?.cid != nil),
            .copyRawID(enabled: !(rawID ?? "").isEmpty),
        ]
        if let feedback, feedback.isVisible(now: now) {
            if case .copied = feedback { items.append(.copied) } else { items.append(.copyFailed) }
        }
        if !servers.isEmpty { items.append(.servers(servers)) }
        return items
    }
}

/// Writes text to the clipboard (NSPasteboard in the app, a recorder in tests).
protocol PasteboardWriting: Sendable {
    /// `false` = the clipboard did not take the text.
    @MainActor func write(_ text: String) -> Bool
}

/// Default when nothing is injected (tests): every write fails.
struct UnavailablePasteboard: PasteboardWriting {
    init() {}
    @MainActor func write(_ text: String) -> Bool { false }
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

import Foundation

/// Quit confirmation policy (§8). A quit caused by an update relaunch never asks "Quit without saving?":
/// the pre-install snapshot was already taken with the user's consent, so no data is at risk.
@MainActor
enum TerminationPolicy {
    private(set) static var terminatingForUpdate = false

    static func needsConfirmation(hasUnsavedChanges: Bool) -> Bool {
        hasUnsavedChanges && !terminatingForUpdate
    }

    /// Marks the quit as update-driven, then runs `terminate` (NSApp.terminate in the app).
    static func terminateForUpdate(_ terminate: () -> Void) {
        terminatingForUpdate = true
        terminate()
    }

    static func resetForTesting() { terminatingForUpdate = false }

    /// §30: the app quits with its last window, except in menu bar mode.
    static func quitsAfterLastWindowClosed(menuBarEnabled: Bool) -> Bool {
        !menuBarEnabled
    }
}

import AppKit
import OSLog
import SwiftUI

@main
struct PlayerIdentityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(L10n.text(.appWindowTitle), id: "main") {
            ContentView(model: appDelegate.model)
        }
        .defaultSize(width: 900, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // §6: the Refresh button is disabled while refreshing; ⌘R always works and,
            // if pressed during a refresh, cancels the previous one so the latest request wins.
            CommandGroup(before: .toolbar) {
                Button(L10n.text(.actionRefresh)) { appDelegate.model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.text(.actionSave)) { appDelegate.model.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button(L10n.text(.updateCheck)) { appDelegate.model.checkForUpdates(manual: true) }
            }
        }

        // §22 history window; SwiftUI lists it in the Window menu, with ⌘Y.
        Window(L10n.text(.historyTitle), id: "history") {
            HistoryView(model: appDelegate.model)
        }
        .defaultSize(width: 760, height: 480)
        .keyboardShortcut("y", modifiers: .command)

        Settings {
            SettingsView(model: appDelegate.model)
        }

        // §30 status item (only while "Show in menu bar" is on); the Dock icon stays (V1).
        MenuBarExtra(isInserted: Binding(get: { appDelegate.model.menuBarEnabled },
                                         set: { appDelegate.model.menuBarEnabled = $0 })) {
            MenuBarMenu(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Confirmation for unsaved changes on quit (§8).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        let dependencies = AppDependencies.live()
        // §19.3: one-time migration from the legacy bundle, before the snapshot is loaded.
        // Skipped in the test host so tests never touch the user's real data.
        if !AppModel.isRunningTests {
            let outcome = DataMigration.live(paths: dependencies.paths, defaults: dependencies.defaults).run()
            Logger(subsystem: "tr.ercanatay.playeridentity", category: "migration")
                .info("Data migration: \(String(describing: outcome), privacy: .public)")
        }
        model = AppModel(dependencies: dependencies)
        super.init()
    }

    /// §30: in menu bar mode closing the window keeps the app running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        TerminationPolicy.quitsAfterLastWindowClosed(menuBarEnabled: model.menuBarEnabled)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TerminationPolicy.needsConfirmation(hasUnsavedChanges: model.hasUnsavedChanges) else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(.quitTitle)
        alert.informativeText = L10n.text(.quitMessage)
        alert.addButton(withTitle: L10n.text(.quitConfirm))
        alert.addButton(withTitle: L10n.text(.actionCancel))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}


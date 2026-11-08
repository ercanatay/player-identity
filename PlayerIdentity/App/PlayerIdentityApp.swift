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
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(.quitTitle)
        alert.informativeText = L10n.text(.quitMessage)
        alert.addButton(withTitle: L10n.text(.quitConfirm))
        alert.addButton(withTitle: L10n.text(.actionCancel))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

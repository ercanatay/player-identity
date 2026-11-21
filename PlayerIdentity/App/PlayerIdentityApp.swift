import AppIntents
import AppKit
import OSLog
import SwiftUI

@main
struct PlayerIdentityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(L10n.text(.appWindowTitle), id: "main") {
            ContentView(model: appDelegate.model)
                .id(appDelegate.model.appLanguage)
                .appLayoutDirection(appDelegate.model.appLanguage)
        }
        .defaultSize(width: 900, height: 760)
        .windowResizability(.contentMinSize)
        // §53: `playeridentity://` links open (or bring up) the main window, which adds the servers.
        .handlesExternalEvents(matching: [ServerLink.scheme])
        // Unified toolbar; the title is drawn by the toolbar status group (title → status, leading).
        .windowToolbarStyle(.unified(showsTitle: false))
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
                .id(appDelegate.model.appLanguage)
                .appLayoutDirection(appDelegate.model.appLanguage)
        }
        .defaultSize(width: 760, height: 480)
        .keyboardShortcut("y", modifiers: .command)
        // §48: native unified toolbar; the title is drawn by the toolbar title group.
        .windowToolbarStyle(.unified(showsTitle: false))

        // §38 ban matrix (servers × ban types, CSV export, copy).
        Window(L10n.text(.banMatrixTitle), id: "banMatrix") {
            BanMatrixView(model: appDelegate.model)
                .id(appDelegate.model.appLanguage)
                .appLayoutDirection(appDelegate.model.appLanguage)
        }
        .defaultSize(width: 860, height: 420)
        .windowToolbarStyle(.unified(showsTitle: false))

        // §70 "Find Servers" (GoldSrc master list + A2S_INFO), ⌘B.
        Window(L10n.text(.serverBrowserTitle), id: ServerBrowserWindow.id) {
            ServerBrowserWindow(model: appDelegate.model)
                .id(appDelegate.model.appLanguage)
                .appLayoutDirection(appDelegate.model.appLanguage)
        }
        .defaultSize(width: 980, height: 620)
        .keyboardShortcut("b", modifiers: .command)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView(model: appDelegate.model)
                .id(appDelegate.model.appLanguage)
                .appLayoutDirection(appDelegate.model.appLanguage)
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
        let dependencies = AppModel.isUITesting ? AppDependencies.uiTesting() : AppDependencies.live()
        // §19.3: one-time migration from the legacy bundle, before the snapshot is loaded.
        // Skipped in the test host so tests never touch the user's real data.
        if !AppModel.isRunningTests {
            let outcome = DataMigration.live(paths: dependencies.paths, defaults: dependencies.defaults).run()
            Logger(subsystem: "tr.ercanatay.playeridentity", category: "migration")
                .info("Data migration: \(String(describing: outcome), privacy: .public)")
        }
        model = AppModel(dependencies: dependencies)
        super.init()
        // §41 / §66.4: the "Refresh", "Diagnose Server" and "Copy Diagnosis Report" intents use this model.
        let model = self.model
        AppDependencyManager.shared.add(dependency: model)
        // §66.2 notification actions ("Copy Unban Message") and taps (open the server details).
        if !AppModel.isRunningTests {
            notificationResponder.install()
        }
    }

    private lazy var notificationResponder = NotificationResponder(model: model)

    /// §67.4: an opened Spotlight result shows the server details in the main window.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard model.openSpotlightResult(SpotlightActivity.identifier(of: userActivity)) else { return false }
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        return true
    }

    /// §30: in menu bar mode closing the window keeps the app running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        TerminationPolicy.quitsAfterLastWindowClosed(menuBarEnabled: model.menuBarEnabled)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if TerminationPolicy.needsConfirmation(hasUnsavedChanges: model.hasUnsavedChanges) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text(.quitTitle)
            alert.informativeText = L10n.text(.quitMessage)
            alert.addButton(withTitle: L10n.text(.quitConfirm))
            alert.addButton(withTitle: L10n.text(.actionCancel))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        let model = self.model
        // §74: an engine install is never cut off: a download/extraction is cancelled (temporary files removed), a
        // backup/install is waited for until it completes or rolls back.
        if model.isEngineInstallRunning, !AppModel.isRunningTests {
            Task { @MainActor in
                await model.stopEngineInstallForQuit()
                if model.syncFolder != nil { _ = await model.syncBeforeQuit() }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // §71.2: a last folder sync before quitting, at most 2 seconds.
        guard model.syncFolder != nil, !AppModel.isRunningTests else { return .terminateNow }
        Task { @MainActor in
            _ = await model.syncBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}


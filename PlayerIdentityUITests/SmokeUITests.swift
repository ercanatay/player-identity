import XCTest

/// §41 UI smoke test (local only; not part of the `PlayerIdentity` scheme, so CI does not run it).
/// Launches the app in Turkish with `-PIUITesting` (temporary home, separate defaults, no network),
/// checks the main window, opens Settings from the app menu and looks for the "Güncellemeler" tab button.
@MainActor
final class SmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-PIUITesting", "-AppleLanguages", "(tr)", "-AppleLocale", "tr_TR"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "app did not come to the foreground")
        try await Task.sleep(for: .seconds(1))
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testMainWindowAndSettingsUpdatesTab() throws {
        let mainWindow = app.windows.element(boundBy: 0)
        if !mainWindow.waitForExistence(timeout: 30) {
            XCTContext.runActivity(named: "App hierarchy") { _ in
                let attachment = XCTAttachment(string: app.debugDescription)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTFail("main window missing (windows=\(app.windows.count))")
            return
        }
        XCTAssertTrue(app.buttons["Yenile"].firstMatch.waitForExistence(timeout: 10), "Refresh button missing")

        // App menu: by title (TR/EN), fallback to the item after the Apple menu.
        let menuBar = app.menuBars.firstMatch
        let titledMenu = ["Oyuncu Kimlik Kartı", "Player Identity"]
            .map { menuBar.menuBarItems[$0] }
            .first { $0.exists }
        let appMenu = titledMenu ?? menuBar.menuBarItems.element(boundBy: 1)
        XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "app menu missing")
        appMenu.click()
        let settingsTitles = ["Ayarlar…", "Settings…"]
        let settingsItem = settingsTitles
            .map { app.menuItems[$0] }
            .first { $0.waitForExistence(timeout: 5) }
        XCTAssertNotNil(settingsItem, "Ayarlar… / Settings… menu item missing")
        settingsItem?.click()

        let updatesTitles = ["Güncellemeler", "Updates"]
        let updatesTab = updatesTitles
            .map { app.toolbars.buttons[$0].firstMatch }
            .first { $0.waitForExistence(timeout: 15) }
        XCTAssertNotNil(updatesTab, "Güncellemeler / Updates toolbar button missing")
        updatesTab?.click()
        let checkTitles = ["Şimdi denetle", "Check Now"]
        let checkButton = checkTitles
            .map { app.buttons[$0].firstMatch }
            .first { $0.waitForExistence(timeout: 10) }
        XCTAssertNotNil(checkButton, "updates pane did not open")

        // Close the Settings window.
        app.typeKey("w", modifierFlags: .command)
    }
}

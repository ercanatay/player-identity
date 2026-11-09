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
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testMainWindowAndSettingsUpdatesTab() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "app did not come to the foreground")
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20), "main window missing")
        XCTAssertTrue(app.buttons["Yenile"].firstMatch.waitForExistence(timeout: 10), "Refresh button missing")

        // App menu (the first item after the Apple menu) → "Ayarlar…"
        let appMenu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "app menu missing")
        appMenu.click()
        let settingsItem = app.menuItems["Ayarlar…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 10), "Ayarlar… menu item missing")
        settingsItem.click()

        let updatesTab = app.toolbars.buttons["Güncellemeler"].firstMatch
        XCTAssertTrue(updatesTab.waitForExistence(timeout: 15), "Güncellemeler toolbar button missing")
        updatesTab.click()
        XCTAssertTrue(app.buttons["Şimdi denetle"].firstMatch.waitForExistence(timeout: 10), "updates pane did not open")

        // Close the Settings window.
        app.typeKey("w", modifierFlags: .command)
    }
}

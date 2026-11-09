import XCTest
@testable import PlayerIdentity

@MainActor
final class TerminationPolicyTests: XCTestCase {
    override func setUp() async throws { TerminationPolicy.resetForTesting() }
    override func tearDown() async throws { TerminationPolicy.resetForTesting() }

    func testUnsavedChangesAskForConfirmationOnNormalQuit() {
        XCTAssertTrue(TerminationPolicy.needsConfirmation(hasUnsavedChanges: true))
        XCTAssertFalse(TerminationPolicy.needsConfirmation(hasUnsavedChanges: false))
    }

    func testUpdateRelaunchQuitSkipsConfirmation() {
        var terminated = false
        TerminationPolicy.terminateForUpdate {
            // The flag is already set when terminate runs, so applicationShouldTerminate sees it.
            XCTAssertFalse(TerminationPolicy.needsConfirmation(hasUnsavedChanges: true))
            terminated = true
        }
        XCTAssertTrue(terminated)
        XCTAssertFalse(TerminationPolicy.needsConfirmation(hasUnsavedChanges: true))
    }

    func testManualMenuCheckOpensNoAlertAndReportsInStatus() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel(updates: HTTPScript(defaultBody: "[]"), appVersion: "1.0")
        await model.checkForUpdates(manual: true)?.value
        // No modal state exists any more; the result lives in the controller status (Settings status line).
        XCTAssertNotEqual(model.updates.status, .checking)
    }

    func testLocalizationKeyCountsAreEqualAndDownloadKeyRemoved() throws {
        func keys(_ lang: String) throws -> [String] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Localizable", withExtension: "strings",
                                                                subdirectory: nil, localization: lang)
                                    ?? Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                       subdirectory: nil, localization: lang))
            let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            return Array(dict.keys)
        }
        let tr = try keys("tr"), en = try keys("en")
        XCTAssertEqual(tr.count, en.count)
        XCTAssertFalse(tr.contains("update.download"))
        XCTAssertFalse(en.contains("update.download"))
    }
}

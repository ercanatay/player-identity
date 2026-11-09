import XCTest
@testable import PlayerIdentity

/// §25: semver comparison, release evaluation, 24-hour schedule, ignore, silent API errors.
final class UpdateCheckTests: XCTestCase {
    private func release(_ tag: String, prerelease: Bool = false, url: String = "https://github.com/ercanatay/player-identity/releases/tag/x") -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)","prerelease":\#(prerelease),"draft":false}"#.utf8)
    }

    func testSemanticVersionComparison() throws {
        let v = { (text: String) in try XCTUnwrap(SemanticVersion(text)) }
        XCTAssertGreaterThan(try v("1.10"), try v("1.9"))
        XCTAssertGreaterThan(try v("v1.10.0"), try v("1.9.9"))
        XCTAssertEqual(try v("1.2"), try v("1.2.0"))
        XCTAssertGreaterThan(try v("2.0.0"), try v("1.99.99"))
        XCTAssertLessThan(try v("1.2.0-beta.1"), try v("1.2.0"))
        XCTAssertTrue(try v("1.2.0-rc1").isPrerelease)
        XCTAssertEqual(try v("1.2.3+build.5").description, "1.2.3")
        for bad in ["", "v", "1..2", "1.2.3.4", "a.b", "1.-2", "１.２"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testEvaluateRelease() {
        let newer = UpdateChecker.evaluate(release("v1.10.0"), currentVersion: "1.9")
        XCTAssertEqual(newer, .available(AppUpdate(version: "1.10.0",
                                                   url: URL(string: "https://github.com/ercanatay/player-identity/releases/tag/x")!)))
        XCTAssertEqual(UpdateChecker.evaluate(release("1.9.0"), currentVersion: "1.9"), .upToDate)
        XCTAssertEqual(UpdateChecker.evaluate(release("1.8"), currentVersion: "1.9"), .upToDate)
        XCTAssertEqual(UpdateChecker.evaluate(release("2.0.0", prerelease: true), currentVersion: "1.9"), .upToDate)
        XCTAssertEqual(UpdateChecker.evaluate(release("2.0.0-beta.1"), currentVersion: "1.9"), .upToDate)
        XCTAssertEqual(UpdateChecker.evaluate(Data("not json".utf8), currentVersion: "1.9"), .failed)
        XCTAssertEqual(UpdateChecker.evaluate(release("latest"), currentVersion: "1.9"), .failed)
        // Non-HTTPS release links fall back to the releases page.
        XCTAssertEqual(UpdateChecker.evaluate(release("2.0", url: "http://evil.example"), currentVersion: "1.9"),
                       .available(AppUpdate(version: "2.0.0", url: UpdateChecker.releasesPageURL)))
    }

    func testTwentyFourHourSchedule() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: nil, now: now, manual: false))
        XCTAssertFalse(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now, manual: false))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now, manual: false))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-60), now: now, manual: true))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(3600), now: now, manual: false))   // clock moved back
        XCTAssertEqual(UpdateChecker.latestReleaseURL.absoluteString,
                       "https://api.github.com/repos/ercanatay/player-identity/releases/latest")
    }

    func testStateBannerAndIgnore() throws {
        let suite = "PlayerIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let update = AppUpdate(version: "1.2.0", url: UpdateChecker.releasesPageURL)
        UpdateState(lastCheck: Date(timeIntervalSince1970: 1), latest: update).save(to: defaults)
        let loaded = UpdateState(defaults: defaults)
        XCTAssertEqual(loaded.latest, update)
        XCTAssertEqual(loaded.lastCheck, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(loaded.banner(currentVersion: "1.0"), update)
        XCTAssertNil(loaded.banner(currentVersion: "1.2"))
        var ignored = loaded
        ignored.ignoredVersion = "1.2.0"
        XCTAssertNil(ignored.banner(currentVersion: "1.0"))
    }
}

@MainActor
final class AppModelUpdateTests: XCTestCase {
    private let newer = #"{"tag_name":"v1.10.0","html_url":"https://github.com/ercanatay/player-identity/releases/tag/v1.10.0","prerelease":false}"#
    private let same = #"{"tag_name":"v1.0.0","html_url":"https://github.com/ercanatay/player-identity/releases/tag/v1.0.0","prerelease":false}"#

    func testNewReleaseShowsBannerOncePerDayAndIgnoreHidesIt() async throws {
        let env = try TestAppEnvironment()
        let api = HTTPScript(defaultBody: newer)
        let model = env.makeModel(updates: api, appVersion: "1.9")
        XCTAssertNil(model.availableUpdate)
        await model.checkForUpdates()?.value
        XCTAssertEqual(model.availableUpdate?.version, "1.10.0")
        await model.waitForHistory()
        XCTAssertEqual(env.historyStore.load().map(\.kind), [.appUpdateAvailable])

        // Next launch within 24 h: no request, banner from the cache.
        env.clock.advance(3600)
        let relaunched = env.makeModel(updates: api, appVersion: "1.9")
        XCTAssertNil(relaunched.checkForUpdates())
        XCTAssertEqual(relaunched.availableUpdate?.version, "1.10.0")
        let calls = await api.calls
        XCTAssertEqual(calls, 1)

        relaunched.ignoreUpdate()
        XCTAssertNil(relaunched.availableUpdate)
        XCTAssertNil(env.makeModel(updates: api, appVersion: "1.9").availableUpdate)

        // A manual check bypasses the schedule; the same version is recorded in the history only once.
        await relaunched.checkForUpdates(manual: true)?.value
        let callsAfterManual = await api.calls
        XCTAssertEqual(callsAfterManual, 2)
        XCTAssertNil(relaunched.availableUpdate)   // still ignored
        await relaunched.waitForHistory()
        XCTAssertEqual(env.historyStore.load().count, 1)
    }

    func testAPIErrorIsSilentAndRetriedNextLaunch() async throws {
        let env = try TestAppEnvironment()
        let failing = HTTPScript(defaultBody: nil)
        let model = env.makeModel(updates: failing, appVersion: "1.0")
        await model.checkForUpdates()?.value
        XCTAssertNil(model.availableUpdate)
        XCTAssertNil(UpdateState(defaults: env.defaults).lastCheck)
        XCTAssertNotNil(env.makeModel(updates: failing, appVersion: "1.0").checkForUpdates())
    }

    func testManualCheckReportsUpToDate() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel(updates: HTTPScript(defaultBody: same), appVersion: "1.0")
        await model.checkForUpdates()?.value
        await model.checkForUpdates(manual: true)?.value
        XCTAssertEqual(model.updates.status, .upToDate)    // shown in the status line, no modal alert
        XCTAssertNil(model.availableUpdate)
    }

    func testNoUpdateClientMeansNoCheck() throws {
        let env = try TestAppEnvironment()
        XCTAssertNil(env.makeModel().checkForUpdates(manual: true))
    }
}

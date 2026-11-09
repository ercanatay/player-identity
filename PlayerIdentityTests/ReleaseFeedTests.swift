import XCTest
@testable import PlayerIdentity

/// §27.1/§27.2/§28.2: feed parsing, assets, SHA256SUMS, history, schedule, preferences.
final class ReleaseFeedTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, assets: Bool = true) -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let list = assets ? """
        [{"name":"PlayerIdentity-\(version)-macos.zip","size":1736250,"browser_download_url":"https://github.com/ercanatay/player-identity/releases/download/\(tag)/PlayerIdentity-\(version)-macos.zip"},
         {"name":"SHA256SUMS.txt","size":97,"browser_download_url":"https://github.com/ercanatay/player-identity/releases/download/\(tag)/SHA256SUMS.txt"}]
        """ : "[]"
        return """
        {"tag_name":"\(tag)","html_url":"https://github.com/ercanatay/player-identity/releases/tag/\(tag)","body":"notes \(tag)",
         "draft":\(draft),"prerelease":\(prerelease),"published_at":"2026-11-09T07:25:00Z","assets":\(list)}
        """
    }

    private func feed(_ items: [String]) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }

    func testStableReleasesOnlySortedBySemver() throws {
        let data = feed([release("v1.9.0"), release("v1.10.0"), release("v2.0.0", draft: true),
                         release("v2.1.0", prerelease: true), release("v1.11.0-beta.1"), release("v1.0.0"), release("nightly")])
        let releases = try XCTUnwrap(ReleaseFeed.parse(data))
        XCTAssertEqual(releases.map(\.versionString), ["1.10.0", "1.9.0", "1.0.0"])
        let newest = try XCTUnwrap(releases.first)
        XCTAssertEqual(newest.zip?.name, "PlayerIdentity-1.10.0-macos.zip")
        XCTAssertEqual(newest.zip?.size, 1_736_250)
        XCTAssertEqual(newest.sums?.name, "SHA256SUMS.txt")
        XCTAssertEqual(newest.notes, "notes v1.10.0")
        XCTAssertNotNil(newest.publishedAt)
        XCTAssertTrue(newest.isInstallable)
        XCTAssertNil(ReleaseFeed.parse(Data("{}".utf8)))
    }

    func testReleaseWithoutAssetsIsListedButNotInstallable() throws {
        let releases = try XCTUnwrap(ReleaseFeed.parse(feed([release("v1.2.0", assets: false), release("v1.1.0")])))
        XCTAssertFalse(releases[0].isInstallable)
        XCTAssertEqual(ReleaseFeed.latestUpdate(in: releases, currentVersion: "1.0.0")?.versionString, "1.1.0")
        XCTAssertNil(ReleaseFeed.latestUpdate(in: releases, currentVersion: "1.1.0"))
    }

    func testHistoryIsLimitedToTwenty() throws {
        let data = feed((0..<25).map { release("v1.\($0).0") })
        let history = ReleaseFeed.history(try XCTUnwrap(ReleaseFeed.parse(data)))
        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.first?.versionString, "1.24.0")
        XCTAssertEqual(history.last?.versionString, "1.5.0")
    }

    func testFeedClient() async throws {
        let ok = ReleaseFeedClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: "[\(release("v1.2.0"))]")))
        let releases = try await ok.fetch()
        XCTAssertEqual(releases.map(\.versionString), ["1.2.0"])
        let failing = ReleaseFeedClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: nil)))
        do {
            _ = try await failing.fetch()
            XCTFail("expected an error")
        } catch {
            XCTAssertNotNil(error)
        }
        let garbage = ReleaseFeedClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: "nope")))
        do {
            _ = try await garbage.fetch()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .feedUnavailable)
        }
        XCTAssertEqual(ReleaseFeed.url.scheme, "https")
        XCTAssertTrue(ReleaseFeed.url.absoluteString.hasPrefix("https://api.github.com/repos/ercanatay/player-identity/releases"))
    }

    func testSHA256SumsParsing() {
        let hash = String(repeating: "a", count: 64)
        let text = """
        \(hash)  PlayerIdentity-1.1.0-macos.zip
        \(String(repeating: "B", count: 64)) *binary-mode.zip
        not-a-hash  x.zip
        \(String(repeating: "c", count: 63))  short.zip

        """
        XCTAssertEqual(SHA256Sums.parse(text), ["PlayerIdentity-1.1.0-macos.zip": hash,
                                               "binary-mode.zip": String(repeating: "b", count: 64)])
    }

    func testSchedule24hAnd6h() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertTrue(UpdateSchedule.isLaunchCheckDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isLaunchCheckDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(UpdateSchedule.isLaunchCheckDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertFalse(UpdateSchedule.isPeriodicCheckDue(lastCheck: now.addingTimeInterval(-5.9 * 3600), now: now))
        XCTAssertTrue(UpdateSchedule.isPeriodicCheckDue(lastCheck: now.addingTimeInterval(-6 * 3600), now: now))
        XCTAssertTrue(UpdateSchedule.isPeriodicCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))   // clock moved back
        XCTAssertEqual(UpdateSchedule.nextPeriodicCheck(lastCheck: now.addingTimeInterval(-3600), now: now),
                       now.addingTimeInterval(5 * 3600))
        XCTAssertEqual(UpdateSchedule.nextPeriodicCheck(lastCheck: nil, now: now), now)
        XCTAssertEqual(UpdateSchedule.periodicInterval, 6 * 3600)
        XCTAssertEqual(UpdateSchedule.launchInterval, 24 * 3600)
    }

    func testPreferencesDefaultToNoAutomaticDownload() throws {
        let suite = "PlayerIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UpdatePreferences(defaults: defaults), UpdatePreferences(autoCheck: true, autoDownload: false))
        UpdatePreferences(autoCheck: false, autoDownload: true).save(to: defaults)
        XCTAssertEqual(UpdatePreferences(defaults: defaults), UpdatePreferences(autoCheck: false, autoDownload: true))
    }

    func testUpdatePaths() {
        let paths = AppPaths(home: URL(fileURLWithPath: "/h"))
        let base = "/h/Library/Application Support/tr.ercanatay.playeridentity/updates"
        XCTAssertEqual(paths.updateDownloads.path, base + "/downloads")
        XCTAssertEqual(paths.updateAppBackups.path, base + "/backup")
        XCTAssertEqual(paths.dataBackups.path, base + "/backups")
    }
}

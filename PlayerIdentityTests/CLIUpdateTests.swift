import XCTest
@testable import PlayerIdentity

/// §51 `playeridentityctl update --check | --install`: fake feed (HTTP), fake downloader/tools, a fixture app in a
/// temp folder and an injected y/N prompt. No network; the app is never relaunched.
final class CLIUpdateTests: XCTestCase {
    private var temp: TempDirectory!
    private let clock = TestClock()
    private var app: URL!
    private var executable: URL!
    private var release: AppRelease!
    private var files: [URL: Data] = [:]
    private var runner: FakeUpdateRunner!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        app = try temp.makeDirectory("Applications").appendingPathComponent("PlayerIdentity.app", isDirectory: true)
        try UpdateFixture.makeApp(at: app, bundleID: UpdateInstaller.bundleID, version: "2.9.2", marker: "old")
        executable = try temp.write("Applications/PlayerIdentity.app/Contents/Helpers/playeridentityctl", "ctl")
        (release, files) = UpdateFixture.release("2.10.0")
        runner = FakeUpdateRunner()
        runner.appVersion = "2.10.0"
    }

    override func tearDown() async throws { temp = nil }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
    private var paths: AppPaths { AppPaths(home: home) }
    /// The installer works on the symlink-resolved path (`/var` → `/private/var`).
    private var appPath: String { app.resolvingSymlinksInPath().path }
    private var sumsURL: URL { release.sums!.downloadURL }

    // MARK: Fixtures

    /// `/releases` JSON with the given stable releases (and one pre-release that must be ignored).
    private func feed(_ releases: [AppRelease]) throws -> Data {
        var objects: [[String: Any]] = releases.map { release in
            var assets: [[String: Any]] = []
            for asset in [release.zip, release.sums].compactMap({ $0 }) {
                assets.append(["name": asset.name, "size": asset.size, "browser_download_url": asset.downloadURL.absoluteString])
            }
            return ["tag_name": release.tag, "draft": false, "prerelease": false, "body": "notes",
                    "html_url": "https://github.com/ercanatay/player-identity/releases/tag/\(release.tag)", "assets": assets]
        }
        objects.append(["tag_name": "v9.0.0-beta.1", "draft": false, "prerelease": true, "assets": []])
        return try JSONSerialization.data(withJSONObject: objects)
    }

    private func http(_ releases: [AppRelease]? = nil, feedStatus: Int = 200) throws -> FeedHTTPClient {
        var responses: [URL: (Data, Int)] = [ReleaseFeed.url: (try feed(releases ?? [release, installedRelease]), feedStatus)]
        for (url, data) in files { responses[url] = (data, 200) }
        return FeedHTTPClient(responses)
    }

    private var installedRelease: AppRelease { UpdateFixture.release("2.9.2").0 }

    private func context(http: FeedHTTPClient? = nil, executable: URL?? = nil, prompt: CLIPrompt = .none,
                         downloader: FakeUpdateDownloader? = nil) throws -> CLIContext {
        let clock = self.clock
        return CLIContext(version: "1.2.1", build: "13", paths: paths, environment: [:], fileSystem: LocalFileSystem(),
                          resolver: FakeAddressResolver(), udpTransport: FakeServer.healthy(clock: clock), now: { clock.now },
                          updateHTTP: try http ?? self.http(), executableURL: executable ?? self.executable,
                          updateDownloader: downloader ?? FakeUpdateDownloader(files), updateFileManager: LocalUpdateFileManager(),
                          updateRunner: runner, prompt: prompt)
    }

    private func run(_ arguments: [String], _ context: CLIContext) async -> CLIResult {
        await CLIRunner.run(arguments: arguments, context: context)
    }

    private func json(_ result: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        return try XCTUnwrap(object, result.stdout + result.stderr, file: file, line: line)
    }

    private func assertOldAppInPlace(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(UpdateFixture.marker(of: app), "old", file: file, line: line)
    }

    // MARK: Parsing

    func testUpdateArgumentParsing() {
        XCTAssertEqual(CLIParser.parse(["update", "--check"]), .success(.update(CLIUpdateOptions(mode: .check, json: false))))
        XCTAssertEqual(CLIParser.parse(["--json", "update", "--check"]),
                       .success(.update(CLIUpdateOptions(mode: .check, json: true))))
        XCTAssertEqual(CLIParser.parse(["update", "--install"]),
                       .success(.update(CLIUpdateOptions(mode: .install, json: false, yes: false, app: nil))))
        XCTAssertEqual(CLIParser.parse(["update", "--install", "--yes", "--app", "/Applications/PlayerIdentity.app", "--json"]),
                       .success(.update(CLIUpdateOptions(mode: .install, json: true, yes: true,
                                                         app: "/Applications/PlayerIdentity.app"))))
        XCTAssertEqual(CLIParser.parse(["update", "--install", "--app=/tmp/X.app"]),
                       .success(.update(CLIUpdateOptions(mode: .install, json: false, app: "/tmp/X.app"))))

        let usageErrors: [[String]] = [
            ["update"], ["update", "--check", "--install"], ["update", "--check", "--yes"], ["update", "--check", "--app", "/x.app"],
            ["update", "--install", "extra"], ["update", "--install", "--app"], ["update", "--install", "--app="],
            ["update", "--install", "--yes=1"], ["update", "--check", "--timeout", "4"], ["status", "--check"],
            ["ban", "192.0.2.1", "--yes"], ["cid", "192.0.2.1", "--install"], ["update", "--check", "--no-metrics"],
            ["update", "--install", "--app", "/a.app", "--app", "/b.app"],
        ]
        for arguments in usageErrors {
            guard case .failure = CLIParser.parse(arguments) else {
                XCTFail("expected usage error: \(arguments)")
                continue
            }
        }
    }

    func testEnclosingAppFromTheExecutablePath() throws {
        XCTAssertEqual(CLIAppBundle.enclosing(executable: executable)?.path, appPath)
        // Homebrew links the tool into PATH; the link is followed back into the app.
        let link = temp.url.appendingPathComponent("bin/playeridentityctl")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(CLIAppBundle.enclosing(executable: link)?.path, appPath)
        XCTAssertNil(CLIAppBundle.enclosing(executable: URL(fileURLWithPath: "/usr/local/bin/playeridentityctl")))
        XCTAssertNil(CLIAppBundle.enclosing(executable: URL(fileURLWithPath: "/x/PlayerIdentity.app/Contents/MacOS/ctl")))
    }

    // MARK: update --check

    func testCheckReportsAnUpdateAsJSONWithExitCode4() async throws {
        let client = try http()
        let result = await run(["update", "--check", "--json"], try context(http: client))
        XCTAssertEqual(result.exitCode, 4, result.stdout + result.stderr)
        XCTAssertEqual(result.stderr, "")
        let object = try json(result)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "command", "action", "app", "current", "latest", "updateAvailable",
                                          "asset", "sha256", "notesURL"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["command"] as? String, "update")
        XCTAssertEqual(object["action"] as? String, "check")
        XCTAssertEqual(object["current"] as? String, "2.9.2")       // from the app's Info.plist, not the tool (1.2.1)
        XCTAssertEqual(object["app"] as? String, appPath)
        XCTAssertEqual(object["latest"] as? String, "2.10.0")
        XCTAssertEqual(object["updateAvailable"] as? Bool, true)
        let asset = try XCTUnwrap(object["asset"] as? [String: Any])
        XCTAssertEqual(asset["name"] as? String, "PlayerIdentity-2.10.0-macos.zip")
        XCTAssertEqual(asset["size"] as? Int, release.zip?.size)
        XCTAssertEqual(asset["url"] as? String, release.zip?.downloadURL.absoluteString)
        XCTAssertEqual(object["sha256"] as? String, UpdateInstaller.sha256(Data("zip-bytes".utf8)))
        XCTAssertEqual(object["notesURL"] as? String, "https://github.com/ercanatay/player-identity/releases/tag/v2.10.0")
        XCTAssertEqual(client.requested, [ReleaseFeed.url, sumsURL])
        XCTAssertEqual(runner.commands, [])                          // a check never runs the install tools

        let text = await run(["update", "--check"], try context())
        XCTAssertEqual(text.exitCode, 4)
        XCTAssertTrue(text.stdout.contains("current: 2.9.2"), text.stdout)
        XCTAssertTrue(text.stdout.contains("update:  available (PlayerIdentity-2.10.0-macos.zip"), text.stdout)
    }

    func testCheckUpToDateExitsZero() async throws {
        let result = await run(["update", "--check", "--json"], try context(http: try http([installedRelease])))
        XCTAssertEqual(result.exitCode, 0, result.stdout)
        let object = try json(result)
        XCTAssertEqual(object["updateAvailable"] as? Bool, false)
        XCTAssertEqual(object["current"] as? String, "2.9.2")
        XCTAssertEqual(object["latest"] as? String, "2.9.2")         // the pre-release 9.0.0-beta.1 is ignored
        XCTAssertTrue(object["asset"] is NSNull)
        XCTAssertTrue(object["sha256"] is NSNull)

        let text = await run(["update", "--check"], try context(http: try http([installedRelease])))
        XCTAssertEqual(text.exitCode, 0)
        XCTAssertTrue(text.stdout.contains("update:  none (up to date)"), text.stdout)
    }

    func testCheckOutsideAnAppUsesTheToolVersion() async throws {
        let result = await run(["update", "--check", "--json"], try context(executable: .some(nil)))
        XCTAssertEqual(result.exitCode, 4)
        XCTAssertEqual(try json(result)["current"] as? String, "1.2.1")
        XCTAssertTrue(try json(result)["app"] is NSNull)
    }

    func testCheckNetworkErrorsExitTwo() async throws {
        let offline = await run(["update", "--check", "--json"], try context(http: FeedHTTPClient([:])))
        XCTAssertEqual(offline.exitCode, 2)
        XCTAssertEqual(try json(offline)["error"] as? String, "feedUnavailable")

        let serverError = await run(["update", "--check"], try context(http: try http(feedStatus: 503)))
        XCTAssertEqual(serverError.exitCode, 2)
        XCTAssertTrue(serverError.stderr.contains("release feed"), serverError.stderr)
        XCTAssertEqual(serverError.stdout, "")

        // The checksum file is optional for a check: the update is still reported.
        let client = try http()
        client.remove(sumsURL)
        let noSums = await run(["update", "--check", "--json"], try context(http: client))
        XCTAssertEqual(noSums.exitCode, 4)
        XCTAssertTrue(try json(noSums)["sha256"] is NSNull)
    }

    // MARK: update --install

    func testInstallWithYesReplacesTheEnclosingAppWithoutRelaunching() async throws {
        let downloader = FakeUpdateDownloader(files)
        let result = await run(["update", "--install", "--yes", "--json"], try context(downloader: downloader))
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
        let object = try json(result)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "command", "action", "app", "from", "to", "installed",
                                          "relaunchRequired", "backup"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["action"] as? String, "install")
        XCTAssertEqual(object["from"] as? String, "2.9.2")
        XCTAssertEqual(object["to"] as? String, "2.10.0")
        XCTAssertEqual(object["installed"] as? Bool, true)
        XCTAssertEqual(object["relaunchRequired"] as? Bool, true)
        XCTAssertEqual(object["app"] as? String, appPath)

        XCTAssertEqual(UpdateFixture.marker(of: app), "new")
        let backup = paths.updateAppBackups.appendingPathComponent("PlayerIdentity-2.9.2.app", isDirectory: true)
        XCTAssertEqual(object["backup"] as? String, backup.path)
        XCTAssertEqual(UpdateFixture.marker(of: backup), "old")
        XCTAssertEqual(Set(downloader.requestedURLs), [release.zip!.downloadURL, sumsURL])
        // The whole verification chain ran; nothing was opened (the caller relaunches).
        let tools = runner.commands.map { $0.argv[0] }
        XCTAssertEqual(tools, ["/usr/bin/ditto", "/usr/bin/codesign", "/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/xattr"])
        XCTAssertFalse(runner.commands.contains { if case .open = $0 { return true } else { return false } })

        let text = await run(["update", "--install", "--yes"], try context(http: try http([release])))
        XCTAssertEqual(text.exitCode, 3)                              // 2.10.0 is installed now
    }

    func testInstallTextOutput() async throws {
        let result = await run(["update", "--install", "--yes"], try context())
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("installed Cybokron Player Identity 2.10.0 (was 2.9.2): \(appPath)\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("relaunch required"))
    }

    func testInstallConfirmation() async throws {
        // No terminal and no --yes: refused before the feed is even loaded.
        let client = try http()
        let noTTY = await run(["update", "--install", "--json"], try context(http: client, prompt: .none))
        XCTAssertEqual(noTTY.exitCode, 1)
        XCTAssertEqual(try json(noTTY)["error"] as? String, "confirmationRequired")
        XCTAssertEqual(client.requested, [])
        assertOldAppInPlace()

        // Declined at the prompt: nothing downloaded or replaced.
        let declined = PromptLog(answer: false)
        let downloader = FakeUpdateDownloader(files)
        let no = await run(["update", "--install"], try context(prompt: declined.prompt, downloader: downloader))
        XCTAssertEqual(no.exitCode, 1)
        XCTAssertTrue(no.stderr.contains("not confirmed"), no.stderr)
        XCTAssertEqual(declined.questions, ["Install Cybokron Player Identity 2.10.0 over 2.9.2 at \(appPath)? [y/N] "])
        XCTAssertEqual(downloader.requestedURLs, [])
        XCTAssertEqual(runner.commands, [])
        assertOldAppInPlace()

        // Confirmed: installed.
        let accepted = PromptLog(answer: true)
        let yes = await run(["update", "--install", "--json"], try context(prompt: accepted.prompt))
        XCTAssertEqual(yes.exitCode, 0, yes.stdout)
        XCTAssertEqual(accepted.questions.count, 1)
        XCTAssertEqual(UpdateFixture.marker(of: app), "new")
    }

    func testYesSkipsThePrompt() async throws {
        let prompt = PromptLog(answer: false)
        let result = await run(["update", "--install", "--yes"], try context(prompt: prompt.prompt))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(prompt.questions, [])
    }

    func testInstallWithoutUpdateExitsThree() async throws {
        let prompt = PromptLog(answer: true)
        let result = await run(["update", "--install", "--json"], try context(http: try http([installedRelease]),
                                                                              prompt: prompt.prompt))
        XCTAssertEqual(result.exitCode, 3)
        let object = try json(result)
        XCTAssertEqual(object["from"] as? String, "2.9.2")
        XCTAssertTrue(object["to"] is NSNull)
        XCTAssertEqual(object["latest"] as? String, "2.9.2")
        XCTAssertEqual(object["installed"] as? Bool, false)
        XCTAssertEqual(object["relaunchRequired"] as? Bool, false)
        XCTAssertEqual(prompt.questions, [])                          // nothing to confirm
        assertOldAppInPlace()

        let text = await run(["update", "--install", "--yes"], try context(http: try http([installedRelease])))
        XCTAssertEqual(text.exitCode, 3)
        XCTAssertTrue(text.stdout.contains("up to date"), text.stdout)
    }

    func testVerificationFailuresExitTwoAndKeepTheApp() async throws {
        runner.teamID = "OTHERTEAM1"
        let team = await run(["update", "--install", "--yes", "--json"], try context())
        XCTAssertEqual(team.exitCode, 2)
        XCTAssertEqual(try json(team)["error"] as? String, "teamMismatch")
        assertOldAppInPlace()

        runner.teamID = UpdateInstaller.teamID
        runner.gatekeeperResult = CommandOutput(status: 3, output: "/x/PlayerIdentity.app: rejected\nsource=no usable signature")
        let gatekeeper = await run(["update", "--install", "--yes", "--json"], try context())
        XCTAssertEqual(gatekeeper.exitCode, 2)
        XCTAssertEqual(try json(gatekeeper)["error"] as? String, "gatekeeperRejected")
        assertOldAppInPlace()

        runner = FakeUpdateRunner()
        runner.appVersion = "2.10.0"
        (release, files) = UpdateFixture.release("2.10.0", sums: String(repeating: "0", count: 64) + "  PlayerIdentity-2.10.0-macos.zip\n")
        let checksum = await run(["update", "--install", "--yes"], try context())
        XCTAssertEqual(checksum.exitCode, 2)
        XCTAssertTrue(checksum.stderr.contains("SHA-256"), checksum.stderr)
        XCTAssertEqual(runner.commands, [])                           // nothing unpacked after a checksum mismatch
        assertOldAppInPlace()

        (release, files) = UpdateFixture.release("2.10.0", host: "http://github.com")
        let insecure = await run(["update", "--install", "--yes", "--json"], try context())
        XCTAssertEqual(insecure.exitCode, 2)
        XCTAssertEqual(try json(insecure)["error"] as? String, "insecureURL")

        let offline = await run(["update", "--install", "--yes", "--json"], try context(http: FeedHTTPClient([:])))
        XCTAssertEqual(offline.exitCode, 2)
        XCTAssertEqual(try json(offline)["error"] as? String, "feedUnavailable")
        assertOldAppInPlace()
    }

    func testAppOverrideAndTargetErrors() async throws {
        // Not inside an app and no --app: usage error.
        let loose = await run(["update", "--install", "--yes", "--json"], try context(executable: .some(nil)))
        XCTAssertEqual(loose.exitCode, 1)
        XCTAssertEqual(try json(loose)["error"] as? String, "appNotFound")

        // --app replaces that bundle (version read from its Info.plist), not the one containing the tool.
        let other = try temp.makeDirectory("Elsewhere").appendingPathComponent("PlayerIdentity.app", isDirectory: true)
        try UpdateFixture.makeApp(at: other, bundleID: UpdateInstaller.bundleID, version: "2.8.0", marker: "other")
        let result = await run(["update", "--install", "--yes", "--app", other.path, "--json"],
                               try context(executable: .some(nil)))
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
        XCTAssertEqual(try json(result)["from"] as? String, "2.8.0")
        XCTAssertEqual(try json(result)["app"] as? String, other.resolvingSymlinksInPath().path)
        XCTAssertEqual(UpdateFixture.marker(of: other), "new")
        assertOldAppInPlace()

        let foreign = try temp.makeDirectory("Foreign").appendingPathComponent("PlayerIdentity.app", isDirectory: true)
        try UpdateFixture.makeApp(at: foreign, bundleID: "com.example.other", version: "1.0.0", marker: "x")
        let mismatch = await run(["update", "--install", "--yes", "--app", foreign.path, "--json"], try context())
        XCTAssertEqual(mismatch.exitCode, 1)
        XCTAssertEqual(try json(mismatch)["error"] as? String, "appMismatch")
        XCTAssertEqual(UpdateFixture.marker(of: foreign), "x")

        let missing = await run(["update", "--install", "--yes", "--app", temp.url.appendingPathComponent("None.app").path],
                                try context())
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.stderr.contains("no app bundle"), missing.stderr)

        let notApp = try temp.makeDirectory("folder")
        let folder = await run(["update", "--install", "--yes", "--app", notApp.path, "--json"], try context())
        XCTAssertEqual(try json(folder)["error"] as? String, "appNotFound")
    }

    func testErrorDescriptionsAndExitCodes() {
        XCTAssertEqual(CLIRunner.describe(.cancelledByUser).exitCode, 1)
        let others: [UpdateError] = [.feedUnavailable, .insecureURL, .missingAsset, .sameVersion, .downloadFailed,
                                     .sizeMismatch(expected: 2, actual: 1), .checksumMissing, .checksumMismatch, .unzipFailed,
                                     .appMissing, .signatureInvalid, .teamMismatch(found: nil), .bundleMismatch(found: "x"),
                                     .versionMismatch(found: "1"), .gatekeeperRejected, .processTimedOut(tool: "spctl"),
                                     .notWritable, .adminPromptFailed, .installFailed(rolledBack: true, backup: nil),
                                     .installFailed(rolledBack: false, backup: URL(fileURLWithPath: "/b.app")), .cancelled]
        for error in others {
            let described = CLIRunner.describe(error)
            XCTAssertEqual(described.exitCode, 2, "\(error)")
            XCTAssertFalse(described.code.isEmpty)
            XCTAssertFalse(described.message.isEmpty)
        }
        XCTAssertTrue(CLIRunner.describe(.installFailed(rolledBack: false, backup: URL(fileURLWithPath: "/b.app")))
            .message.contains("/b.app"))
    }

    func testHelpListsTheUpdateCommands() async throws {
        let help = await run(["--help"], try context())
        XCTAssertTrue(help.stdout.contains("update --check [--json]"))
        XCTAssertTrue(help.stdout.contains("update --install [--yes] [--app <path>] [--json]"))
        XCTAssertTrue(help.stdout.contains("4 update available (--check)"))
    }
}

/// URL → body and status; unknown URLs fail like an offline network. Records every request.
final class FeedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: (Data, Int)]
    private var log: [URL] = []

    init(_ responses: [URL: (Data, Int)]) { self.responses = responses }

    var requested: [URL] { lock.withLock { log } }

    func remove(_ url: URL) { lock.withLock { _ = responses.removeValue(forKey: url) } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        let response: (Data, Int)? = lock.withLock {
            log.append(url)
            return responses[url]
        }
        guard let response else { throw URLError(.notConnectedToInternet) }
        return response
    }
}

/// Interactive y/N prompt that answers `answer` and records the questions.
final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    let answer: Bool

    init(answer: Bool) { self.answer = answer }

    var questions: [String] { lock.withLock { asked } }

    var prompt: CLIPrompt {
        CLIPrompt(isInteractive: true) { [self] question in
            lock.withLock { asked.append(question) }
            return answer
        }
    }
}

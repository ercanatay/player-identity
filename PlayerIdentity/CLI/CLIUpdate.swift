import Foundation

// §51 `playeridentityctl update --check | --install`. It reads the app's release feed (`ReleaseFeedClient`) and
// installs with the app's installer (`UpdateInstaller`: HTTPS, size, SHA-256, signature/team/bundle/version,
// Gatekeeper). The target is the app that contains this tool (`<name>.app/Contents/Helpers/playeridentityctl`) or
// `--app <path>`. The new version is never started: the caller relaunches it.

extension CLIExit {
    /// `update --install`: there is no newer installable release.
    static let noUpdate: Int32 = 3
    /// `update --check`: a newer installable release exists.
    static let updateAvailable: Int32 = 4
}

struct CLIUpdateOptions: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case check
        case install
    }

    var mode: Mode
    var json: Bool
    /// `--yes`: install without asking.
    var yes = false
    /// `--app <path>`: the app to replace instead of the one containing this tool.
    var app: String?
}

/// The y/N confirmation of `update --install`. Without a terminal (`isInteractive == false`) an install without
/// `--yes` is refused before anything is downloaded.
struct CLIPrompt: Sendable {
    var isInteractive: Bool
    var ask: @Sendable (String) -> Bool

    static let none = CLIPrompt(isInteractive: false, ask: { _ in false })

    /// Standard input must be a terminal; the question goes to standard error, so `--json` output stays clean.
    static let terminal = CLIPrompt(isInteractive: isatty(STDIN_FILENO) == 1) { question in
        FileHandle.standardError.write(Data(question.utf8))
        guard let answer = readLine(strippingNewline: true) else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// The installed app the CLI checks against and replaces.
struct CLIAppBundle: Sendable, Equatable {
    let url: URL
    /// `CFBundleShortVersionString` of the bundle.
    let version: String

    enum Problem: Error, Sendable, Equatable {
        /// No `.app` bundle with a readable `Contents/Info.plist` at the path.
        case notFound
        case notPlayerIdentity(found: String?)
        case noVersion
    }

    /// `<name>.app/Contents/Helpers/playeridentityctl` → `<name>.app` (symlinks such as the Homebrew link resolved).
    static func enclosing(executable: URL) -> URL? {
        let helpers = executable.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    /// `--app <path>`: `~` expanded, relative to the working directory, symlinks resolved.
    static func url(forPath path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    static func read(_ app: URL, fileManager: any UpdateFileManaging) -> Result<CLIAppBundle, Problem> {
        let plist = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard app.pathExtension == "app", fileManager.exists(plist), let data = try? fileManager.data(plist),
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return .failure(.notFound)
        }
        let bundleID = dictionary["CFBundleIdentifier"] as? String
        guard bundleID == UpdateInstaller.bundleID else { return .failure(.notPlayerIdentity(found: bundleID)) }
        guard let version = dictionary["CFBundleShortVersionString"] as? String, SemanticVersion(version) != nil else {
            return .failure(.noVersion)
        }
        return .success(CLIAppBundle(url: app, version: version))
    }
}

/// §51: the CLI replaces the bundle but never starts it (the caller relaunches), so this step always succeeds and
/// the installer never rolls back because of it.
struct CLIKeepClosedRelauncher: AppRelaunching {
    func relaunch(_ app: URL) async throws {}
}

extension CLIRunner {
    /// Largest `SHA256SUMS.txt` read by `update --check`.
    static let checksumFileLimit = 64 * 1024

    static func update(_ options: CLIUpdateOptions, context: CLIContext) async -> CLIResult {
        switch options.mode {
        case .check: return await updateCheck(json: options.json, context: context)
        case .install: return await updateInstall(options, context: context)
        }
    }

    // MARK: update --check

    private static func updateCheck(json: Bool, context: CLIContext) async -> CLIResult {
        // The installed app's version; outside an app bundle (e.g. a loose build) the tool's own version.
        let app = context.executableURL.flatMap(CLIAppBundle.enclosing(executable:))
            .flatMap { try? CLIAppBundle.read($0, fileManager: context.updateFileManager).get() }
        let current = app?.version ?? context.version
        let releases: [AppRelease]
        do {
            releases = try await ReleaseFeedClient(http: context.updateHTTP).fetch()
        } catch {
            return updateFailure(.feedUnavailable, json: json)
        }
        let update = ReleaseFeed.latestUpdate(in: releases, currentVersion: current)
        let latest = update ?? releases.first
        var checksum: String?
        if let update { checksum = await publishedChecksum(of: update, http: context.updateHTTP) }
        let notes = latest.map(notesURL(of:))
        let exitCode = update == nil ? CLIExit.ok : CLIExit.updateAvailable

        if json {
            var object: [String: Any] = [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "update", "action": "check",
                "app": app?.url.path ?? NSNull(), "current": current, "latest": latest?.versionString ?? NSNull(),
                "updateAvailable": update != nil, "asset": NSNull(), "sha256": checksum ?? NSNull(),
                "notesURL": notes?.absoluteString ?? NSNull(),
            ]
            if let zip = update?.zip {
                object["asset"] = ["name": zip.name, "size": zip.size, "url": zip.downloadURL.absoluteString] as [String: Any]
            }
            return CLIResult(exitCode: exitCode, stdout: CLIJSON.string(object), stderr: "")
        }
        var lines = ["current: \(current)", "latest:  \(latest?.versionString ?? "-")"]
        if let update, let zip = update.zip {
            lines.append("update:  available (\(zip.name), \(zip.size) bytes)")
            lines.append("sha256:  \(checksum ?? "-")")
        } else {
            lines.append("update:  none (up to date)")
        }
        if let notes { lines.append("notes:   \(notes.absoluteString)") }
        return CLIResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    /// The zip's SHA-256 from the release's `SHA256SUMS.txt` (`nil` if it cannot be read; the check still answers).
    private static func publishedChecksum(of release: AppRelease, http: any HTTPClient) async -> String? {
        guard let zip = release.zip, let sums = release.sums, UpdateInstaller.isAllowedURL(sums.downloadURL),
              let response = try? await http.get(sums.downloadURL, timeout: ReleaseFeedClient.timeout),
              (200..<300).contains(response.statusCode), response.data.count <= checksumFileLimit else { return nil }
        return SHA256Sums.parse(String(decoding: response.data, as: UTF8.self))[zip.name]
    }

    private static func notesURL(of release: AppRelease) -> URL {
        release.pageURL.flatMap { $0.scheme == "https" ? $0 : nil } ?? UpdateChecker.releasesPageURL
    }

    // MARK: update --install

    private static func updateInstall(_ options: CLIUpdateOptions, context: CLIContext) async -> CLIResult {
        let json = options.json
        guard let url = options.app.map(CLIAppBundle.url(forPath:))
                ?? context.executableURL.flatMap(CLIAppBundle.enclosing(executable:)) else {
            return failure("appNotFound", "this tool is not inside PlayerIdentity.app; pass --app <path>",
                           command: "update", json: json, code: CLIExit.usage)
        }
        let app: CLIAppBundle
        switch CLIAppBundle.read(url, fileManager: context.updateFileManager) {
        case .success(let value):
            app = value
        case .failure(.notFound):
            return failure("appNotFound", "no app bundle at \(url.path)", command: "update", json: json, code: CLIExit.usage)
        case .failure(.notPlayerIdentity(let found)):
            return failure("appMismatch", "\(url.path) is not Cybokron Player Identity (bundle identifier \(found ?? "none"))",
                           command: "update", json: json, code: CLIExit.usage)
        case .failure(.noVersion):
            return failure("appVersionMissing", "\(url.path) has no readable version", command: "update", json: json,
                           code: CLIExit.usage)
        }
        // Without --yes the answer must come from a terminal; scripts are refused before anything is downloaded.
        guard options.yes || context.prompt.isInteractive else {
            return failure("confirmationRequired", "update --install needs a terminal to confirm, or --yes",
                           command: "update", json: json, code: CLIExit.usage)
        }
        let releases: [AppRelease]
        do {
            releases = try await ReleaseFeedClient(http: context.updateHTTP).fetch()
        } catch {
            return updateFailure(.feedUnavailable, json: json)
        }
        guard let release = ReleaseFeed.latestUpdate(in: releases, currentVersion: app.version) else {
            let latest = releases.first?.versionString
            if json {
                let object: [String: Any] = [
                    "schemaVersion": CLIContext.jsonSchemaVersion, "command": "update", "action": "install",
                    "app": app.url.path, "from": app.version, "to": NSNull(), "latest": latest ?? NSNull(),
                    "installed": false, "relaunchRequired": false,
                ]
                return CLIResult(exitCode: CLIExit.noUpdate, stdout: CLIJSON.string(object), stderr: "")
            }
            return CLIResult(exitCode: CLIExit.noUpdate,
                             stdout: "Cybokron Player Identity \(app.version) is up to date (latest \(latest ?? "-")); nothing installed\n",
                             stderr: "")
        }
        if !options.yes {
            let question = "Install Cybokron Player Identity \(release.versionString) over \(app.version) at \(app.url.path)? [y/N] "
            guard context.prompt.ask(question) else {
                return failure("declined", "not confirmed; nothing installed", command: "update", json: json,
                               code: CLIExit.usage)
            }
        }
        // §49.3: a full data backup before every install, as in the app.
        do {
            try FullBackupStore(paths: context.paths, appVersion: app.version).create(.preUpdate, now: context.now())
        } catch {
            return failure("backupFailed", "the data backup before the update failed (\(error)); nothing installed",
                           command: "update", json: json)
        }
        let installer = UpdateInstaller(paths: context.paths, installedApp: app.url, currentVersion: app.version,
                                        downloader: context.updateDownloader, fileManager: context.updateFileManager,
                                        runner: context.updateRunner, relauncher: CLIKeepClosedRelauncher())
        let result: UpdateInstaller.Result
        do {
            result = try await installer.install(release)
        } catch {
            return updateFailure(error as? UpdateError ?? .downloadFailed, json: json)
        }
        if json {
            return success(json: [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "update", "action": "install",
                "app": result.installed.path, "from": app.version, "to": result.version, "installed": true,
                "relaunchRequired": true, "backup": result.backup.path,
            ])
        }
        let lines = [
            "installed Cybokron Player Identity \(result.version) (was \(app.version)): \(result.installed.path)",
            "previous version: \(result.backup.path)",
            "relaunch required: quit and reopen the app to use \(result.version)",
        ]
        return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: Errors

    private static func updateFailure(_ error: UpdateError, json: Bool) -> CLIResult {
        let described = describe(error)
        return failure(described.code, described.message, command: "update", json: json, code: described.exitCode)
    }

    /// Stable error code, message and exit code of an update error: 1 when the user cancelled the administrator
    /// prompt, 2 for every network, download, verification or install error.
    static func describe(_ error: UpdateError) -> (code: String, message: String, exitCode: Int32) {
        let network = CLIExit.network
        switch error {
        case .feedUnavailable: return ("feedUnavailable", "could not load the release feed (network error)", network)
        case .insecureURL: return ("insecureURL", "the release files are not served over HTTPS", network)
        case .missingAsset: return ("missingAsset", "the release has no app zip or SHA256SUMS.txt", network)
        case .sameVersion: return ("sameVersion", "this version is already installed", network)
        case .downloadFailed: return ("downloadFailed", "the download failed", network)
        case .sizeMismatch(let expected, let actual):
            return ("sizeMismatch", "the download has \(actual) bytes, expected \(expected)", network)
        case .checksumMissing: return ("checksumMissing", "SHA256SUMS.txt has no entry for the app zip", network)
        case .checksumMismatch: return ("checksumMismatch", "the SHA-256 checksum of the download does not match", network)
        case .unzipFailed: return ("unzipFailed", "the zip could not be unpacked", network)
        case .appMissing: return ("appMissing", "the zip does not contain the app", network)
        case .signatureInvalid: return ("signatureInvalid", "the code signature of the new app is not valid", network)
        case .teamMismatch(let found):
            return ("teamMismatch", "the new app is signed by team \(found ?? "none"), expected \(UpdateInstaller.teamID)",
                    network)
        case .bundleMismatch(let found):
            return ("bundleMismatch",
                    "the new app has bundle identifier \(found ?? "none"), expected \(UpdateInstaller.bundleID)", network)
        case .versionMismatch(let found):
            return ("versionMismatch", "the new app reports version \(found ?? "none")", network)
        case .gatekeeperRejected: return ("gatekeeperRejected", "Gatekeeper did not accept the new app (not notarized)", network)
        case .processTimedOut(let tool): return ("processTimedOut", "\(tool) did not finish in time", network)
        case .notWritable: return ("notWritable", "the app location is not writable", network)
        case .cancelledByUser: return ("cancelledByUser", "the administrator prompt was cancelled; nothing installed",
                                       CLIExit.usage)
        case .adminPromptFailed: return ("adminPromptFailed", "the administrator prompt could not be shown", network)
        case .installFailed(let rolledBack, let backup):
            let previous = rolledBack ? "the previous version is back in place"
                                      : "the previous version is at \(backup?.path ?? "the update backup folder")"
            return ("installFailed", "replacing the app failed; \(previous)", network)
        case .cancelled: return ("cancelled", "the update was cancelled", network)
        }
    }
}

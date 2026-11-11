import Foundation
@testable import PlayerIdentity

/// Serves scripted bytes per URL; never touches the network.
final class FakeUpdateDownloader: UpdateDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: Data]
    private var requested: [URL] = []
    /// Throws `CancellationError` when this URL is requested (simulates the user cancelling mid-download).
    var cancelOn: URL?

    init(_ files: [URL: Data]) { self.files = files }

    var requestedURLs: [URL] { lock.withLock { requested } }

    func download(_ url: URL, to destination: URL, expectedSize: Int,
                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        let data: Data? = lock.withLock {
            requested.append(url)
            return files[url]
        }
        if url == cancelOn { throw CancellationError() }
        guard let data else { throw URLError(.fileDoesNotExist) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        await progress(1)
    }
}

/// Plays the system tools: "unzips" a fixture app with the given Info.plist and reports scripted signing results.
final class FakeUpdateRunner: UpdateCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [UpdateCommand] = []
    var bundleID = UpdateInstaller.bundleID
    var appVersion = "1.2.0"
    var signatureValid = true
    var teamID: String? = UpdateInstaller.teamID
    var unzipStatus: Int32 = 0
    var openStatus: Int32 = 0
    /// Admin script result: status and output (e.g. "User canceled. (-128)").
    var adminResult = CommandOutput(status: 0, output: "")
    var adminPerformsMoves = true
    /// `osascript` cannot be started (the runner throws).
    var adminLaunchFails = false

    struct LaunchFailure: Error {}

    var commands: [UpdateCommand] { lock.withLock { log } }

    func run(_ command: UpdateCommand) async throws -> CommandOutput {
        precondition(UpdateCommandAllowlist.isAllowed(command.argv), "not allowlisted: \(command.argv)")
        lock.withLock { log.append(command) }
        switch command {
        case .unzip(_, let directory):
            guard unzipStatus == 0 else { return CommandOutput(status: unzipStatus, output: "ditto: error") }
            try UpdateFixture.makeApp(at: URL(fileURLWithPath: directory.value).appendingPathComponent("PlayerIdentity.app"),
                                      bundleID: bundleID, version: appVersion, marker: "new")
            return CommandOutput(status: 0, output: "")
        case .verifySignature:
            return CommandOutput(status: signatureValid ? 0 : 1, output: signatureValid ? "" : "code object is not signed at all")
        case .signingInfo:
            var lines = ["Executable=/x", "Identifier=\(bundleID)", "Format=app bundle with Mach-O universal (x86_64 arm64)"]
            if let teamID { lines.append("TeamIdentifier=\(teamID)") } else { lines.append("TeamIdentifier=not set") }
            return CommandOutput(status: 0, output: lines.joined(separator: "\n"))
        case .assess, .removeQuarantine:
            return CommandOutput(status: 0, output: "")
        case .open:
            return CommandOutput(status: openStatus, output: "")
        case .adminReplace(let current, let backup, let staged):
            if adminLaunchFails { throw LaunchFailure() }
            if adminResult.status == 0, adminPerformsMoves {
                let fileManager = FileManager.default
                try? fileManager.removeItem(atPath: backup.value)
                try fileManager.moveItem(atPath: current.value, toPath: backup.value)
                try fileManager.moveItem(atPath: staged.value, toPath: current.value)
            }
            return adminResult
        }
    }
}

/// Real file operations with injectable failures and permissions.
final class FaultyFileManager: UpdateFileManaging, @unchecked Sendable {
    private let base = LocalUpdateFileManager()
    /// `move(_:to:)` fails when the source lies inside this folder (e.g. the staged app).
    var failMoveFrom: URL?
    /// Every move fails after this many successful moves (rollback failure).
    var failMovesAfter: Int?
    var notWritable: Set<URL> = []
    private var moves = 0

    func exists(_ url: URL) -> Bool { base.exists(url) }
    func size(_ url: URL) -> Int? { base.size(url) }
    func data(_ url: URL) throws -> Data { try base.data(url) }
    func isWritable(_ url: URL) -> Bool { !notWritable.contains(url.standardizedFileURL) && base.isWritable(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }

    func move(_ source: URL, to destination: URL) throws {
        if let limit = failMovesAfter, moves >= limit { throw CocoaError(.fileWriteNoPermission) }
        if let folder = failMoveFrom?.standardizedFileURL.path, source.standardizedFileURL.path.hasPrefix(folder) {
            throw CocoaError(.fileWriteNoPermission)
        }
        moves += 1
        try base.move(source, to: destination)
    }
}

final class FakeRelauncher: AppRelaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []
    var fails = false

    var relaunched: [URL] { lock.withLock { opened } }

    func relaunch(_ app: URL) async throws {
        lock.withLock { opened.append(app) }
        if fails { throw UpdateError.installFailed(rolledBack: false, backup: nil) }
    }
}

enum UpdateFixture {
    static func makeApp(at url: URL, bundleID: String, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("MacOS/PlayerIdentity"))
    }

    static func marker(of app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/PlayerIdentity"))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A release whose zip/sums are served by `FakeUpdateDownloader`.
    static func release(_ version: String, zip: Data = Data("zip-bytes".utf8), sums: String? = nil,
                        zipSize: Int? = nil, host: String = "https://github.com") -> (AppRelease, [URL: Data]) {
        let zipName = AppRelease.zipName(version: version)
        let zipURL = URL(string: "\(host)/ercanatay/player-identity/releases/download/v\(version)/\(zipName)")!
        let sumsURL = URL(string: "\(host)/ercanatay/player-identity/releases/download/v\(version)/SHA256SUMS.txt")!
        let sumsText = sums ?? "\(UpdateInstaller.sha256(zip))  \(zipName)\n"
        let release = AppRelease(version: SemanticVersion(version)!, versionString: version, tag: "v\(version)",
                                 pageURL: nil, notes: "", publishedAt: nil,
                                 zip: ReleaseAsset(name: zipName, size: zipSize ?? zip.count, downloadURL: zipURL),
                                 sums: ReleaseAsset(name: "SHA256SUMS.txt", size: Data(sumsText.utf8).count, downloadURL: sumsURL))
        return (release, [zipURL: zip, sumsURL: Data(sumsText.utf8)])
    }
}

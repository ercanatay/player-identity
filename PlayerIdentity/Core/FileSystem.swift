import Foundation

/// Read-only file system access (§1, §9). There is deliberately no method for writing game files.
protocol FileSystemReading: Sendable {
    func isRegularFile(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func readData(_ url: URL) throws -> Data
    func contentsOfDirectory(_ url: URL) throws -> [URL]
}

struct LocalFileSystem: FileSystemReading {
    init() {}

    func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func readData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

/// Writes inside the app's own data folder (§47.2 erase, §49 restore). Never used for game files; tests inject a
/// fake that fails a chosen step.
protocol DataFileOperating: Sendable {
    func exists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
    /// Every item in a folder, hidden ones included. Throws when the folder cannot be listed.
    func contents(_ url: URL) throws -> [URL]
}

struct LocalDataFileOperations: DataFileOperating {
    init() {}

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) throws { try data.write(to: url) }

    func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// A symbolic link is removed, never its target.
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    func contents(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }
}

/// Default locations (§2, §5).
struct AppPaths: Sendable, Equatable {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private var applicationSupport: URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// `~/Library/Application Support/Xash3D FWGS`
    var defaultDataRoot: URL {
        applicationSupport.appendingPathComponent("Xash3D FWGS", isDirectory: true)
    }

    /// `~/Library/Application Support/tr.ercanatay.playeridentity/profile.json`
    var snapshotFile: URL {
        applicationSupport.appendingPathComponent("tr.ercanatay.playeridentity", isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
    }

    /// §22: `~/Library/Application Support/tr.ercanatay.playeridentity/history.jsonl`
    var historyFile: URL {
        snapshotFile.deletingLastPathComponent().appendingPathComponent("history.jsonl", isDirectory: false)
    }

    /// §39: `~/Library/Application Support/tr.ercanatay.playeridentity/metrics.jsonl`
    var metricsFile: URL {
        snapshotFile.deletingLastPathComponent().appendingPathComponent("metrics.jsonl", isDirectory: false)
    }

    /// §42: `~/Library/Application Support/tr.ercanatay.playeridentity/watch-state.json`
    var watchStateFile: URL {
        snapshotFile.deletingLastPathComponent().appendingPathComponent("watch-state.json", isDirectory: false)
    }

    /// §54: `~/Library/Application Support/tr.ercanatay.playeridentity/errors.json` (persisted error log).
    var errorsFile: URL {
        snapshotFile.deletingLastPathComponent().appendingPathComponent("errors.json", isDirectory: false)
    }

    /// Snapshot of the legacy bundle (§19.3): `~/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json`.
    /// Only ever read by `DataMigration`; never written.
    var legacySnapshotFile: URL {
        applicationSupport.appendingPathComponent(DataMigration.legacyDomain, isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
    }
}

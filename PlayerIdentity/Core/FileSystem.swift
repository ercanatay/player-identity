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

    /// Snapshot of the legacy bundle (§19.3): `~/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json`.
    /// Only ever read by `DataMigration`; never written.
    var legacySnapshotFile: URL {
        applicationSupport.appendingPathComponent(DataMigration.legacyDomain, isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
    }
}

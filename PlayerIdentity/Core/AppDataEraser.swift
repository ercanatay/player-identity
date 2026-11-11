import Foundation

/// Settings > Reset > "Erase All Data…": removes the app's own files in
/// `~/Library/Application Support/tr.ercanatay.playeridentity/` — the record with the server list, identity history,
/// metrics, watch state, record backups (`profile.json.appbak-…`) and the `updates/` folder (data backups, previous
/// app versions, downloads). Game files, the data root and UserDefaults are never touched.
struct AppDataEraser: Sendable {
    let paths: AppPaths

    /// The app's own data folder (parent of `profile.json`).
    var directory: URL { paths.snapshotFile.deletingLastPathComponent() }

    /// What an erase would remove, for the confirmation text.
    struct Inventory: Sendable, Equatable {
        /// Data backups + previous app versions + record backups.
        var backups = 0
        /// Top-level items in the data folder.
        var items = 0
    }

    func inventory() -> Inventory {
        var result = Inventory()
        let recordBackupPrefix = paths.snapshotFile.lastPathComponent + RecordBackup.suffix
        result.items = Self.children(directory).count
        result.backups = Self.children(paths.dataBackups).filter(Self.isDirectory).count
            + Self.children(paths.updateAppBackups).filter { $0.pathExtension == "app" }.count
            + Self.children(directory).filter { $0.lastPathComponent.hasPrefix(recordBackupPrefix) }.count
            + FullBackupStore(paths: paths, appVersion: "").count
        return result
    }

    /// Removes every item inside the data folder (the folder itself stays). Returns the number of removed items.
    /// Refuses to run unless the folder is the app's own bundle folder, so a wrong path can never erase other data.
    @discardableResult
    func erase() throws -> Int {
        guard directory.lastPathComponent == UpdateInstaller.bundleID else { throw CocoaError(.fileWriteNoPermission) }
        var removed = 0
        for item in Self.children(directory) {
            try FileManager.default.removeItem(at: item)   // a symbolic link is removed, never its target
            removed += 1
        }
        return removed
    }

    private static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [])) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

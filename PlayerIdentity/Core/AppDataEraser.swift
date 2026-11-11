import Foundation

/// Settings > Reset > "Erase All Data…": removes the app's own files in
/// `~/Library/Application Support/tr.ercanatay.playeridentity/` — the record with the server list, identity history,
/// metrics, watch state, record backups (`profile.json.appbak-…`) and the `updates/` folder (data backups, previous
/// app versions, downloads). Game files, the data root and UserDefaults are never touched.
struct AppDataEraser: Sendable {
    let paths: AppPaths
    /// Listing and removing (tests inject failures).
    var fileOperations: any DataFileOperating = LocalDataFileOperations()

    /// The app's own data folder (parent of `profile.json`).
    var directory: URL { paths.snapshotFile.deletingLastPathComponent() }

    /// What an erase would remove, for the confirmation text.
    struct Inventory: Sendable, Equatable {
        /// Data backups + previous app versions + record backups.
        var backups = 0
        /// Top-level items in the data folder.
        var items = 0
    }

    /// Some items are still in the data folder after an erase (checked by listing the folder again).
    struct Incomplete: Error, Sendable, Equatable {
        /// Items of the folder that are gone.
        var removed: Int
        /// Names of the items still there, sorted.
        var remaining: [String]
        /// First removal error, if one was reported.
        var reason: String?
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
    /// A missing folder erases nothing (0). A folder that cannot be listed throws before anything is removed. Every
    /// item is attempted; afterwards the folder is listed again and `Incomplete` is thrown if anything is left.
    @discardableResult
    func erase() throws -> Int {
        guard directory.lastPathComponent == UpdateInstaller.bundleID else { throw CocoaError(.fileWriteNoPermission) }
        let files = fileOperations
        guard files.exists(directory) else { return 0 }
        let items = try files.contents(directory)
        var reason: String?
        for item in items {
            do {
                try files.remove(item)   // a symbolic link is removed, never its target
            } catch {
                reason = reason ?? error.localizedDescription
            }
        }
        let left: [URL]
        do {
            left = try files.contents(directory)
        } catch {
            throw Incomplete(removed: 0, remaining: items.map(\.lastPathComponent).sorted(),
                             reason: reason ?? error.localizedDescription)
        }
        let remaining = Set(left.map(\.lastPathComponent))
        let removed = items.filter { !remaining.contains($0.lastPathComponent) }.count
        guard remaining.isEmpty else { throw Incomplete(removed: removed, remaining: remaining.sorted(), reason: reason) }
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

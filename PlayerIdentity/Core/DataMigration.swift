import Foundation

/// UserDefaults keys used by the app.
enum DefaultsKey {
    static let dataRoot = "dataRoot"
    static let banCheckEnabled = "banCheckEnabled"
    static let recentNames = "recentNames"
    static let notificationsEnabled = "notificationsEnabled"
    /// §30 menu bar mode (default off).
    static let showInMenuBar = "showInMenuBar"
    /// §35 UI language: `system` (default) · `tr` · `en`.
    static let appLanguage = "appLanguage"
}

/// One-time migration from the legacy `tr.ercanatay.oyuncukimlik` bundle (§19.3).
///
/// - Snapshot: the legacy `profile.json` is copied to the new location only if the target does not exist yet.
///   The copy is atomic (temporary file in the target folder + move); the legacy file is never modified.
///   A corrupt or unsupported legacy snapshot is skipped.
/// - UserDefaults: `dataRoot`, the ban check toggle and recent names are copied from the legacy domain
///   unless the new domain already has a value.
/// - The `migration.v2.completed` flag is set in the new domain once the migration succeeds. On an I/O error
///   the flag stays unset so the next launch retries; the app keeps running either way.
struct DataMigration {
    static let legacyDomain = "tr.ercanatay.oyuncukimlik"
    static let completedKey = "migration.v2.completed"
    static let migratedKeys = [DefaultsKey.dataRoot, DefaultsKey.banCheckEnabled, DefaultsKey.recentNames]

    enum SnapshotStep: Equatable {
        case copied
        case targetExists
        case noLegacyFile
        /// Legacy file is corrupt or has an unsupported schema; nothing is copied.
        case legacyInvalid
        case failed(String)
    }

    enum Outcome: Equatable {
        /// The flag was already set; nothing was touched.
        case alreadyCompleted
        /// Finished; the flag is now set.
        case completed(snapshot: SnapshotStep, copiedKeys: [String])
        /// An I/O error occurred; the flag is not set, so the next launch retries.
        case failed(snapshot: SnapshotStep, copiedKeys: [String])
    }

    let legacySnapshotFile: URL
    let snapshotFile: URL
    /// New domain (the app's standard defaults).
    let defaults: UserDefaults
    /// Legacy domain; `nil` if it cannot be opened.
    let legacyDefaults: UserDefaults?

    init(legacySnapshotFile: URL, snapshotFile: URL, defaults: UserDefaults, legacyDefaults: UserDefaults?) {
        self.legacySnapshotFile = legacySnapshotFile
        self.snapshotFile = snapshotFile
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
    }

    static func live(paths: AppPaths, defaults: UserDefaults) -> DataMigration {
        DataMigration(legacySnapshotFile: paths.legacySnapshotFile,
                      snapshotFile: paths.snapshotFile,
                      defaults: defaults,
                      legacyDefaults: UserDefaults(suiteName: legacyDomain))
    }

    @discardableResult
    func run() -> Outcome {
        guard !defaults.bool(forKey: Self.completedKey) else { return .alreadyCompleted }
        let snapshot = migrateSnapshot()
        let copiedKeys = migrateDefaults()
        if case .failed = snapshot {
            return .failed(snapshot: snapshot, copiedKeys: copiedKeys)
        }
        defaults.set(true, forKey: Self.completedKey)
        return .completed(snapshot: snapshot, copiedKeys: copiedKeys)
    }

    func migrateSnapshot() -> SnapshotStep {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: snapshotFile.path) { return .targetExists }
        switch SnapshotStore(fileURL: legacySnapshotFile).load() {
        case .missing: return .noLegacyFile
        case .corrupt, .unsupportedSchema: return .legacyInvalid
        case .loaded: break
        }

        let directory = snapshotFile.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(snapshotFile.lastPathComponent).\(UUID().uuidString).migrating",
                                                         isDirectory: false)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: legacySnapshotFile, to: temporary)
            // `moveItem` fails if the target appeared in the meantime, so an existing file is never overwritten.
            try fileManager.moveItem(at: temporary, to: snapshotFile)
            return .copied
        } catch {
            try? fileManager.removeItem(at: temporary)
            return fileManager.fileExists(atPath: snapshotFile.path) ? .targetExists : .failed(error.localizedDescription)
        }
    }

    /// Copies the legacy values whose key is not yet set in the new domain. Returns the copied keys.
    func migrateDefaults() -> [String] {
        guard let legacyDefaults else { return [] }
        var copied: [String] = []
        for key in Self.migratedKeys where defaults.object(forKey: key) == nil {
            guard let value = legacyDefaults.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        return copied
    }
}

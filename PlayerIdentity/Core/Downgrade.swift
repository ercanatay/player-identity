import Foundation

// MARK: - Version choice (§28.2)

enum VersionChange: Sendable, Equatable {
    case upgrade
    case downgrade
}

enum DowngradePlanner {
    /// Stable, installable releases older than the running version (newest first).
    static func candidates(in releases: [AppRelease], currentVersion: String) -> [AppRelease] {
        guard let current = SemanticVersion(currentVersion) else { return [] }
        return ReleaseFeed.history(releases).filter { $0.isInstallable && $0.version < current }
    }

    /// Kind of change to `target`; `nil` for the running version ("dön" is disabled for the same version).
    static func change(to target: AppRelease, currentVersion: String) -> VersionChange? {
        guard let current = SemanticVersion(currentVersion), target.version != current else { return nil }
        return target.version < current ? .downgrade : .upgrade
    }
}

// MARK: - Data backup (§28.2/3, §28.3)

/// `snapshot-info.json` of a data backup.
struct DataBackupInfo: Codable, Sendable, Equatable {
    var fromVersion: String
    var toVersion: String
    var createdAt: Date
    /// `schemaVersion` of the backed-up `profile.json`; `nil` if there was no readable record.
    var schemaVersion: Int?
    var files: [String]
    var bundleID: String
}

struct DataBackup: Sendable, Equatable {
    let directory: URL
    let info: DataBackupInfo
}

/// Backups of the app's data before a version change: `updates/backups/data-<from>-to-<to>-<ts>/` with
/// `profile.json`, `history.jsonl`, `defaults.plist` (UserDefaults export) and `snapshot-info.json`.
/// Backups are kept until the user removes them; at most 10, the oldest is removed first.
struct DataBackupStore: Sendable {
    static let maxBackups = 10
    static let infoFile = "snapshot-info.json"
    static let defaultsFile = "defaults.plist"
    static let profileFile = "profile.json"
    static let historyFile = "history.jsonl"

    let paths: AppPaths
    let defaultsDomain: String

    init(paths: AppPaths, defaultsDomain: String = UpdateInstaller.bundleID) {
        self.paths = paths
        self.defaultsDomain = defaultsDomain
    }

    /// Copies the current data; prunes to the 10 newest backups.
    @discardableResult
    func create(from fromVersion: String, to toVersion: String, now: Date, defaults: UserDefaults) throws -> DataBackup {
        try create(from: fromVersion, to: toVersion, now: now,
                   defaultsPlist: Self.defaultsPlist(defaults, domain: defaultsDomain))
    }

    /// The app's UserDefaults domain as XML property list data. Read where the defaults live (the main actor in the
    /// app: `UserDefaults` is not `Sendable`); the resulting `Data` can be written by `create` on any thread.
    static func defaultsPlist(_ defaults: UserDefaults, domain: String) throws -> Data {
        let values = defaults.persistentDomain(forName: domain) ?? [:]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    /// Same as `create(from:to:now:defaults:)` with the preferences already exported (`defaultsPlist(_:domain:)`):
    /// only file work, safe off the main thread.
    @discardableResult
    func create(from fromVersion: String, to toVersion: String, now: Date, defaultsPlist plist: Data) throws -> DataBackup {
        let fileManager = FileManager.default
        let directory = paths.dataBackups.appendingPathComponent(
            "data-\(Self.component(fromVersion))-to-\(Self.component(toVersion))-\(Self.timestamp(now))", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String] = []
        for (source, name) in [(paths.snapshotFile, Self.profileFile), (paths.historyFile, Self.historyFile)]
        where fileManager.fileExists(atPath: source.path) {
            try fileManager.copyItem(at: source, to: directory.appendingPathComponent(name, isDirectory: false))
            files.append(name)
        }
        try plist.write(to: directory.appendingPathComponent(Self.defaultsFile, isDirectory: false), options: .atomic)
        files.append(Self.defaultsFile)

        let schema = (try? Data(contentsOf: paths.snapshotFile)).flatMap(Self.schemaVersion)
        let info = DataBackupInfo(fromVersion: fromVersion, toVersion: toVersion, createdAt: now, schemaVersion: schema,
                                  files: files, bundleID: defaultsDomain)
        try Self.encoder.encode(info).write(to: directory.appendingPathComponent(Self.infoFile, isDirectory: false),
                                            options: .atomic)
        try prune()
        return DataBackup(directory: directory, info: info)
    }

    /// Backups with a readable `snapshot-info.json`, newest first.
    func list() -> [DataBackup] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: paths.dataBackups, includingPropertiesForKeys: nil)) ?? []
        return urls.map { paths.dataBackups.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
            .filter { $0.lastPathComponent.hasPrefix("data-") }.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.infoFile, isDirectory: false)),
                  let info = try? Self.decoder.decode(DataBackupInfo.self, from: data) else { return nil }
            return DataBackup(directory: url, info: info)
        }
        .sorted { $0.info.createdAt != $1.info.createdAt ? $0.info.createdAt > $1.info.createdAt
                                                         : $0.directory.lastPathComponent > $1.directory.lastPathComponent }
    }

    /// Keeps the 10 newest backups.
    func prune() throws {
        for backup in list().dropFirst(Self.maxBackups) {
            try FileManager.default.removeItem(at: backup.directory)
        }
    }

    /// "Yedekleri temizle": removes every data backup.
    func removeAll() throws {
        for backup in list() { try FileManager.default.removeItem(at: backup.directory) }
    }

    /// Puts the backed-up files back (only after the user confirmed; the caller restarts the app).
    /// The current data is backed up first, so a restore never loses data.
    @discardableResult
    func restore(_ backup: DataBackup, currentVersion: String, now: Date, defaults: UserDefaults) throws -> DataBackup {
        let safety = try create(from: currentVersion, to: "restore", now: now, defaults: defaults)
        let fileManager = FileManager.default
        for (name, target) in [(Self.profileFile, paths.snapshotFile), (Self.historyFile, paths.historyFile)] {
            let source = backup.directory.appendingPathComponent(name, isDirectory: false)
            if backup.info.files.contains(name), fileManager.fileExists(atPath: source.path) {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try Data(contentsOf: source)
                try data.write(to: target, options: .atomic)
            } else if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)   // it did not exist when the backup was made
            }
        }
        let defaultsURL = backup.directory.appendingPathComponent(Self.defaultsFile, isDirectory: false)
        if let data = try? Data(contentsOf: defaultsURL),
           let domain = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            defaults.setPersistentDomain(domain, forName: defaultsDomain)
        }
        return safety
    }

    // MARK: Helpers

    static func schemaVersion(_ data: Data) -> Int? {
        struct Header: Decodable { let schemaVersion: Int }
        return (try? JSONDecoder().decode(Header.self, from: data))?.schemaVersion
    }

    /// `20261109T072345Z`
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Version text safe for a folder name.
    static func component(_ version: String) -> String {
        String(version.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "-": return Character(scalar)
            default: return "_"
            }
        })
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Restore advice (§28.2/5, pure)

enum RestoreAdvisor {
    /// After a version change: if the record cannot be read with this version's schema, the newest backup whose
    /// record has the supported schema is offered for "Yedekten geri yükle". Never restores by itself.
    static func backupToOffer(snapshot: SnapshotLoadResult, backups: [DataBackup],
                              supportedSchema: Int = Snapshot.currentSchemaVersion) -> DataBackup? {
        guard case .unsupportedSchema = snapshot else { return nil }
        return backups.sorted { $0.info.createdAt > $1.info.createdAt }
            .first { $0.info.schemaVersion == supportedSchema && $0.info.files.contains(DataBackupStore.profileFile) }
    }
}

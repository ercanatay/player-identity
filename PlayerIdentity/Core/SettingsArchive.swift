import Foundation

// §46 settings / server export-import. Pure model + parsing + merge planning; the app model applies the result.

/// What an export contains (§46.1).
enum SettingsArchiveScope: String, Codable, Sendable, CaseIterable {
    case settingsOnly
    case settingsAndServers
}

/// Exported preferences. Every field is optional: a missing field is simply not applied on import.
struct ArchivedSettings: Codable, Sendable, Equatable {
    var language: String?
    var notificationsEnabled: Bool?
    var notifyBanChanges: Bool?
    var notifyOnlineChanges: Bool?
    var notifyMapChanges: Bool?
    var quietHoursEnabled: Bool?
    var quietHoursStart: String?
    var quietHoursEnd: String?
    var showInMenuBar: Bool?
    var launchAtLogin: Bool?
    var autoCheckUpdates: Bool?
    var autoDownloadUpdates: Bool?
    var banCheckEnabled: Bool?
    /// §49.3 "Automatic backups" (added in 2.9.2; older files simply do not carry it).
    var autoBackupEnabled: Bool?
    var gamedir: String?
    /// Only present when the user asked for it (§46.1).
    var dataRoot: String?

    /// Number of settings carried (the data root counts only when `includingDataRoot`).
    func count(includingDataRoot: Bool) -> Int {
        let values: [Any?] = [language, notificationsEnabled, notifyBanChanges, notifyOnlineChanges, notifyMapChanges,
                              quietHoursEnabled, quietHoursStart, quietHoursEnd, showInMenuBar, launchAtLogin,
                              autoCheckUpdates, autoDownloadUpdates, banCheckEnabled, autoBackupEnabled, gamedir,
                              includingDataRoot ? dataRoot : nil]
        return values.compactMap { $0 }.count
    }

    /// Factory preferences (Settings > Reset > "Reset Settings…"). `gamedir` and `dataRoot` stay `nil`: the
    /// selected game folder and data root are kept.
    static let defaults = ArchivedSettings(
        language: AppLanguageSetting.system.rawValue, notificationsEnabled: true, notifyBanChanges: true,
        notifyOnlineChanges: true, notifyMapChanges: true, quietHoursEnabled: false,
        quietHoursStart: QuietHours.defaultStart, quietHoursEnd: QuietHours.defaultEnd, showInMenuBar: false,
        launchAtLogin: false, autoCheckUpdates: UpdatePreferences().autoCheck,
        autoDownloadUpdates: UpdatePreferences().autoDownload, banCheckEnabled: true, autoBackupEnabled: true)

    /// How many carried values differ from `current` (import preview: "14 values · 3 differ").
    func differences(from current: ArchivedSettings, includingDataRoot: Bool) -> Int {
        func differs<T: Equatable>(_ value: T?, _ other: T?) -> Int { value.map { $0 != other ? 1 : 0 } ?? 0 }
        return differs(language, current.language) + differs(notificationsEnabled, current.notificationsEnabled)
            + differs(notifyBanChanges, current.notifyBanChanges) + differs(notifyOnlineChanges, current.notifyOnlineChanges)
            + differs(notifyMapChanges, current.notifyMapChanges) + differs(quietHoursEnabled, current.quietHoursEnabled)
            + differs(quietHoursStart, current.quietHoursStart) + differs(quietHoursEnd, current.quietHoursEnd)
            + differs(showInMenuBar, current.showInMenuBar) + differs(launchAtLogin, current.launchAtLogin)
            + differs(autoCheckUpdates, current.autoCheckUpdates)
            + differs(autoDownloadUpdates, current.autoDownloadUpdates)
            + differs(banCheckEnabled, current.banCheckEnabled) + differs(autoBackupEnabled, current.autoBackupEnabled)
            + differs(gamedir, current.gamedir)
            + (includingDataRoot ? (dataRoot.map { Self.samePath($0, current.dataRoot) ? 0 : 1 } ?? 0) : 0)
    }

    /// Drops invalid values (never applied) and returns how many were dropped.
    func sanitized() -> (settings: ArchivedSettings, invalid: Int) {
        var copy = self
        var invalid = 0
        if let language, AppLanguageSetting(rawValue: language) == nil { copy.language = nil; invalid += 1 }
        if let value = quietHoursStart, QuietHours.minutes(value) == nil { copy.quietHoursStart = nil; invalid += 1 }
        if let value = quietHoursEnd, QuietHours.minutes(value) == nil { copy.quietHoursEnd = nil; invalid += 1 }
        if let gamedir {
            let ok = !gamedir.isEmpty && gamedir != "." && gamedir != ".." && !gamedir.contains("/")
            if !ok { copy.gamedir = nil; invalid += 1 }
        }
        if let dataRoot, !Self.isPlausibleDataRoot(dataRoot) { copy.dataRoot = nil; invalid += 1 }
        return (copy, invalid)
    }

    /// `~` / `~/…` expanded to the home folder (other paths unchanged).
    static func expandedPath(_ path: String) -> String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }

    /// Path equality that ignores `~` expansion, symbolic links (`/var` and `/private/var` are the same folder) and
    /// `.`/trailing `/` (§58.3: the same folder written differently is no change).
    static func samePath(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        func url(_ path: String) -> URL { URL(fileURLWithPath: expandedPath(path), isDirectory: true) }
        let x = url(a), y = url(b)
        if x.standardizedFileURL.path == y.standardizedFileURL.path { return true }
        return x.standardizedFileURL.resolvingSymlinksInPath().path == y.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// An existing folder (follows symbolic links).
    static func isExistingFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Shape check of an imported data root (no file system access): an absolute path (after `~` expansion) without
    /// NUL and without a `..` component that is not the file system root. Whether it is an existing folder is checked
    /// by `importableDataRoot`.
    static func isPlausibleDataRoot(_ path: String) -> Bool {
        guard !path.contains("\0") else { return false }
        let path = expandedPath(path)
        guard path.hasPrefix("/") else { return false }
        guard !path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else { return false }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path != "/"
    }

    /// The folder an imported data root is applied as, or `nil` when it cannot be applied (not plausible, missing or
    /// not a folder). The import preview and the import itself both use this check, so they always agree (§58.3).
    static func importableDataRoot(_ path: String, isFolder: (String) -> Bool = isExistingFolder) -> URL? {
        guard isPlausibleDataRoot(path) else { return nil }
        let url = URL(fileURLWithPath: expandedPath(path), isDirectory: true).standardizedFileURL
        return isFolder(url.path) ? url : nil
    }
}

/// Exported server row: no CID, no check state, no ban/metric history (§46.1).
struct ArchivedServer: Codable, Sendable, Equatable {
    var label: String
    var host: String
    var port: Int
    var group: String?
    var favorite: Bool
    var watch: Bool
    var note: String
    var appeal: Appeal?
    var banListURL: String?

    init(label: String, host: String, port: Int, group: String? = nil, favorite: Bool = false, watch: Bool = false,
         note: String = "", appeal: Appeal? = nil, banListURL: String? = nil) {
        self.label = label
        self.host = host
        self.port = port
        self.group = group
        self.favorite = favorite
        self.watch = watch
        self.note = note
        self.appeal = appeal
        self.banListURL = banListURL
    }

    init(entry: ServerEntry) {
        var appeal = entry.appeal
        appeal?.notifiedAt = nil
        self.init(label: entry.label, host: entry.host, port: entry.port, group: entry.group, favorite: entry.favorite,
                  watch: entry.watch, note: entry.note, appeal: appeal, banListURL: entry.banListURL)
    }

    private enum CodingKeys: String, CodingKey {
        case label, host, port, group, favorite, watch, note, appeal, banListURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        watch = try container.decodeIfPresent(Bool.self, forKey: .watch) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        appeal = try container.decodeIfPresent(Appeal.self, forKey: .appeal)
        banListURL = try container.decodeIfPresent(String.self, forKey: .banListURL)
    }

    /// Same validation as the server form (§8, §20, §32, §40); returns the cleaned row or `nil`.
    func validated() -> ArchivedServer? {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.label.isEmpty, HostValidator.classify(copy.host) != nil, HostValidator.isValidPort(port),
              ServerNote.isValid(note) else { return nil }
        if let appeal, !appeal.isValid { return nil }
        if let url = banListURL, !url.isEmpty {
            guard case .success = BanListTemplate.validate(url) else { return nil }
        } else {
            copy.banListURL = nil
        }
        copy.group = ServerOrganization.normalizedGroup(group)
        return copy
    }

    /// `host:port` identity used to match servers (case-insensitive host).
    var key: String { SettingsArchiveKey.make(host: host, port: port) }
}

enum SettingsArchiveKey {
    static func make(host: String, port: Int) -> String { "\(HostValidator.normalized(host)):\(port)" }
}

/// `{ schemaVersion, appVersion, exportedAt, scope, settings, servers? }` (§46.1).
struct SettingsArchive: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let maxFileSize = 4 * 1024 * 1024

    var schemaVersion: Int = SettingsArchive.currentSchemaVersion
    var appVersion: String
    var exportedAt: Date
    var scope: SettingsArchiveScope
    var settings: ArchivedSettings
    var servers: [ArchivedServer]?

    /// File name offered in the save panel, e.g. `playeridentity-settings-20261110-101500.json`.
    static func defaultFileName(now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "playeridentity-settings-\(formatter.string(from: now)).json"
    }

    static func make(scope: SettingsArchiveScope, includeDataRoot: Bool, settings: ArchivedSettings,
                     servers: [ServerEntry], appVersion: String, now: Date) -> SettingsArchive {
        var carried = settings
        if !includeDataRoot { carried.dataRoot = nil }
        let rows = scope == .settingsAndServers
            ? servers.sorted { $0.order < $1.order }.map(ArchivedServer.init(entry:))
            : nil
        return SettingsArchive(appVersion: appVersion, exportedAt: now, scope: scope, settings: carried, servers: rows)
    }

    func encoded() throws -> Data {
        let encoder = SnapshotStore.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum SettingsArchiveError: Error, Sendable, Equatable {
    case unreadable
    case tooLarge
    case symbolicLink
    case notJSON
    case missingVersion
    case unsupportedVersion(Int)
    case invalid

    var text: String {
        switch self {
        case .unreadable: return L10n.text(.importErrorUnreadable)
        case .tooLarge: return L10n.text(.importErrorTooLarge)
        case .symbolicLink: return L10n.text(.importErrorSymlink)
        case .notJSON: return L10n.text(.importErrorNotJSON)
        case .missingVersion: return L10n.text(.importErrorMissingVersion)
        case .unsupportedVersion(let version): return L10n.format(.importErrorUnsupportedVersion, String(version))
        case .invalid: return L10n.text(.importErrorInvalid)
        }
    }
}

/// A validated archive: invalid settings / server rows are already removed and only counted.
struct ParsedSettingsArchive: Sendable, Equatable {
    var archive: SettingsArchive
    var invalidSettings: Int
    var invalidServers: Int

    var invalidCount: Int { invalidSettings + invalidServers }
    var hasDataRoot: Bool { archive.settings.dataRoot != nil }
}

enum SettingsArchiveParser {
    /// Reads a file: JSON only, regular file only (no symbolic link), size-limited.
    static func read(_ url: URL) -> Result<ParsedSettingsArchive, SettingsArchiveError> {
        guard url.pathExtension.lowercased() == "json" else { return .failure(.notJSON) }
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else {
            return .failure(.unreadable)
        }
        if values.isSymbolicLink == true { return .failure(.symbolicLink) }
        guard values.isRegularFile == true else { return .failure(.unreadable) }
        if (values.fileSize ?? 0) > SettingsArchive.maxFileSize { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return parse(data)
    }

    private struct LossyServer: Decodable {
        let value: ArchivedServer?
        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(ArchivedServer.self)
        }
    }

    private struct Raw: Decodable {
        let appVersion: String
        let exportedAt: Date
        let scope: SettingsArchiveScope
        let settings: ArchivedSettings
        let servers: [LossyServer]?
    }

    /// Unknown fields are ignored; a missing/unknown version, broken JSON or a wrong type is refused.
    static func parse(_ data: Data) -> Result<ParsedSettingsArchive, SettingsArchiveError> {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            return .failure(.notJSON)
        }
        guard let versionValue = dict["schemaVersion"] else { return .failure(.missingVersion) }
        guard let number = versionValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return .failure(.invalid) }
        guard number.intValue == SettingsArchive.currentSchemaVersion else {
            return .failure(.unsupportedVersion(number.intValue))
        }
        guard let raw = try? SnapshotStore.makeDecoder().decode(Raw.self, from: data) else { return .failure(.invalid) }
        let cleaned = raw.settings.sanitized()
        var valid: [ArchivedServer] = []
        var invalidServers = 0
        for row in raw.servers ?? [] {
            if let server = row.value?.validated() { valid.append(server) } else { invalidServers += 1 }
        }
        let archive = SettingsArchive(appVersion: raw.appVersion, exportedAt: raw.exportedAt, scope: raw.scope,
                                      settings: cleaned.settings, servers: raw.servers == nil ? nil : valid)
        return .success(ParsedSettingsArchive(archive: archive, invalidSettings: cleaned.invalid,
                                              invalidServers: invalidServers))
    }
}

enum SettingsImportMode: String, Sendable, CaseIterable {
    case merge
    case replace
}

/// Import preview (§46.2): counts only, nothing is changed.
struct SettingsImportPreview: Sendable, Equatable {
    var settingCount: Int
    var serverCount: Int
    var conflictCount: Int
    var invalidCount: Int
    var hasServers: Bool
    /// §49.8/§58.3: the data root to be imported cannot be applied ("not applicable"; also counted in `invalidCount`,
    /// never in `changeCount`).
    var dataRootInvalid = false
    /// §58.3: carried values the import would really change (an unapplicable data root and the same folder written
    /// differently are not counted).
    var changeCount = 0
    /// §58.3: the import would change the data root (`SettingsImportSummary.dataRootChanged` is then set).
    var dataRootWillChange = false
    /// §58.3: fields the import will skip; equal to `SettingsImportSummary.skippedFields` of the same import.
    var skippedFields: [String] = []

    static let dataRootField = "dataRoot"

    static func make(_ parsed: ParsedSettingsArchive, existing: [ServerEntry], includeDataRoot: Bool,
                     current: ArchivedSettings = ArchivedSettings(),
                     isFolder: (String) -> Bool = ArchivedSettings.isExistingFolder) -> SettingsImportPreview {
        let incoming = parsed.archive.servers ?? []
        let local = Set(existing.map { SettingsArchiveKey.make(host: $0.host, port: $0.port) })
        var seen = Set<String>()
        var conflicts = 0
        for row in incoming where seen.insert(row.key).inserted && local.contains(row.key) { conflicts += 1 }
        let settings = parsed.archive.settings
        let carriedRoot = includeDataRoot ? settings.dataRoot : nil
        let applicableRoot = carriedRoot.flatMap { ArchivedSettings.importableDataRoot($0, isFolder: isFolder) }
        let rootInvalid = carriedRoot != nil && applicableRoot == nil
        let rootChanges = applicableRoot.map { !ArchivedSettings.samePath($0.path, current.dataRoot) } ?? false
        return SettingsImportPreview(settingCount: settings.count(includingDataRoot: includeDataRoot),
                                     serverCount: incoming.count, conflictCount: conflicts,
                                     invalidCount: parsed.invalidCount + (rootInvalid ? 1 : 0),
                                     hasServers: parsed.archive.servers != nil, dataRootInvalid: rootInvalid,
                                     changeCount: settings.differences(from: current, includingDataRoot: false)
                                         + (rootChanges ? 1 : 0),
                                     dataRootWillChange: rootChanges,
                                     skippedFields: rootInvalid ? [dataRootField] : [])
    }
}

/// Result summary (§46.2): added / updated / skipped (invalid rows, duplicates and rows without changes).
struct SettingsImportSummary: Sendable, Equatable {
    var added = 0
    var updated = 0
    var skipped = 0
    /// Carried settings that were applied (unchanged values count as applied).
    var settingsApplied = 0
    var backupFile: URL?
    /// Carried settings that could not be applied (launch at login unavailable or refused, data root not a folder).
    var settingsSkipped = 0
    /// Settings dropped as invalid when the file was read (never applied).
    var invalidSettings = 0
    /// New data root path when the import changed it.
    var dataRootChanged: String?
    /// Data root from the file that was not applied (missing folder or not a folder).
    var dataRootRejected: String?
    /// §58.3: carried fields that were not applied (`["dataRoot"]` when the data root could not be applied).
    var skippedFields: [String] = []
    /// `true`/`false` when the import turned launch at login on/off; `nil` when it did not change.
    var launchAtLoginChanged: Bool?
}

/// Merge / replace planning for the server list.
enum ServerImportPlanner {
    struct Plan: Equatable {
        var servers: [ServerEntry]
        var added: Int
        var updated: Int
        var skipped: Int
    }

    static func plan(existing: [ServerEntry], incoming: [ArchivedServer], invalidRows: Int, mode: SettingsImportMode) -> Plan {
        var result = mode == .merge ? existing : []
        var added = 0, updated = 0, skipped = invalidRows
        var seen = Set<String>()
        for row in incoming {
            guard seen.insert(row.key).inserted else { skipped += 1; continue }
            let match = existing.first { SettingsArchiveKey.make(host: $0.host, port: $0.port) == row.key }
            let groups = ServerOrganization.groups(result)
            let group = ServerOrganization.resolveGroup(row.group, existing: groups)
            if let match {
                var entry = match
                entry.label = row.label
                entry.group = group
                entry.favorite = row.favorite
                entry.watch = row.watch
                entry.note = row.note
                entry.banListURL = row.banListURL
                entry.appeal = sameAppeal(match.appeal, row.appeal) ? match.appeal : row.appeal
                if entry == match, mode == .merge {
                    skipped += 1
                } else {
                    updated += 1
                    if let index = result.firstIndex(where: { $0.id == match.id }) {
                        result[index] = entry
                    } else {
                        entry.order = ServerOrganization.nextOrder(result)
                        result.append(entry)
                    }
                }
            } else {
                result.append(ServerEntry(label: row.label, host: row.host, port: row.port, group: group,
                                          favorite: row.favorite, order: ServerOrganization.nextOrder(result),
                                          note: row.note, appeal: row.appeal, banListURL: row.banListURL,
                                          watch: row.watch))
                added += 1
            }
        }
        return Plan(servers: result, added: added, updated: updated, skipped: skipped)
    }

    private static func sameAppeal(_ lhs: Appeal?, _ rhs: Appeal?) -> Bool {
        var a = lhs, b = rhs
        a?.notifiedAt = nil
        b?.notifiedAt = nil
        return a == b
    }
}

/// `profile.json.appbak-<yyyyMMdd-HHmmss>` next to the record (§46.2 Replace).
enum RecordBackup {
    static let suffix = ".appbak-"

    static func backupURL(for file: URL, at date: Date, timeZone: TimeZone = .current) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + suffix + formatter.string(from: date), isDirectory: false)
    }

    /// Copies the record; `nil` when there is no record yet. Throws on failure.
    static func make(of file: URL, at date: Date) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let target = backupURL(for: file, at: date)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }
}

enum SettingsImportError: Error, Sendable, Equatable {
    case backupFailed(String)
    /// A restore, an erase or an update is running (data operation lock).
    case busy

    var text: String {
        switch self {
        case .backupFailed(let detail): return L10n.format(.importErrorBackup, detail)
        case .busy: return L10n.text(.importErrorBusy)
        }
    }
}

import CryptoKit
import Foundation

// MARK: - §49 Full data backup / restore

extension AppPaths {
    /// §49: `~/Library/Application Support/tr.ercanatay.playeridentity/backups/` (full backups as ZIP files).
    var fullBackups: URL {
        snapshotFile.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }
}

/// The app data files a full backup carries, in archive order. Nothing else is ever written into or read from a
/// backup: no game files, no `*.appbak` record copies, no `updates/` downloads or previous app versions, no logs.
enum FullBackupFile: String, CaseIterable, Sendable {
    case profile = "profile.json"
    case history = "history.jsonl"
    case metrics = "metrics.jsonl"
    case watchState = "watch-state.json"

    var isLineBased: Bool { self == .history || self == .metrics }

    func url(in paths: AppPaths) -> URL {
        switch self {
        case .profile: return paths.snapshotFile
        case .history: return paths.historyFile
        case .metrics: return paths.metricsFile
        case .watchState: return paths.watchStateFile
        }
    }
}

/// Why a backup was made (part of the manifest and of the file name in `backups/`).
enum FullBackupKind: String, Codable, Sendable, CaseIterable {
    case manual
    case automatic = "auto"
    case preRestore = "pre-restore"
    case preUpdate = "pre-update"
}

/// `manifest.json` of a full backup.
struct FullBackupManifest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let fileName = "manifest.json"

    struct FileRecord: Codable, Sendable, Equatable {
        var name: String
        var bytes: Int
        /// Line count of the JSONL files; `nil` for JSON documents.
        var lines: Int?
        var sha256: String
    }

    /// What the backup contains (shown in the restore preview).
    struct Counts: Codable, Sendable, Equatable {
        var servers = 0
        var historyEntries = 0
        var metricSamples = 0
        /// Servers marked "watch" in the record.
        var watchedServers = 0
    }

    /// A data file that existed but was left out of the backup (or only partly included).
    struct SkippedFile: Codable, Sendable, Equatable {
        enum Reason: String, Codable, Sendable {
            /// The file could not be read; it is not in the backup.
            case unreadable
            /// The file could not be decoded; it is not in the backup.
            case corrupt
            /// The JSONL file is in the backup, but `lines` damaged lines were left out.
            case corruptLines = "corrupt-lines"
        }

        var file: String
        var reason: Reason
        var lines: Int?

        /// The file is missing from the backup entirely (a restore removes the current version).
        var isMissingFromBackup: Bool { reason != .corruptLines }
    }

    var schemaVersion = FullBackupManifest.currentSchemaVersion
    var appVersion: String
    var createdAt: Date
    var kind: FullBackupKind
    /// `savedAt` of the backed-up record, if there was one.
    var recordSavedAt: Date?
    var counts: Counts
    var files: [FileRecord]
    /// SHA-256 over every file (name, length, bytes) in archive order: equal content ⇔ equal value.
    var contentSHA256: String
    /// Files that existed but could not be backed up; absent when nothing was skipped (schema 1 stays readable by
    /// older versions, which ignore the field).
    var skipped: [SkippedFile]?

    /// What a backup result reports to the user.
    var warnings: [SkippedFile] { skipped ?? [] }

    /// Names of the files the backup leaves out entirely although they existed when it was made.
    var missingFiles: [String] { warnings.filter(\.isMissingFromBackup).map(\.file) }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// The current data read from disk, ready to be archived. Unreadable parts are left out, so every backup can be
/// restored again: a corrupt record or watch state is skipped and only decodable JSONL lines are kept (an append
/// that is running at the same time can never leave a partial line in the backup). A file that does not exist is
/// simply absent; a file that exists but is unreadable, corrupt or loses lines is listed in `skipped`, so the
/// manifest and the backup result say that the backup is incomplete.
struct FullBackupContent: Sendable {
    var files: [(FullBackupFile, Data)]
    var counts: FullBackupManifest.Counts
    var recordSavedAt: Date?
    var skipped: [FullBackupManifest.SkippedFile] = []

    var isEmpty: Bool { files.isEmpty }

    var sha256: String { Self.combinedSHA256(files.map { ($0.0.rawValue, $0.1) }) }

    static func collect(_ paths: AppPaths) -> FullBackupContent {
        var result = FullBackupContent(files: [], counts: .init(), recordSavedAt: nil)
        func skip(_ file: FullBackupFile, _ reason: FullBackupManifest.SkippedFile.Reason, lines: Int? = nil) {
            result.skipped.append(.init(file: file.rawValue, reason: reason, lines: lines))
        }
        for file in FullBackupFile.allCases {
            let url = file.url(in: paths)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }   // no such file: nothing lost
            guard let data = try? Data(contentsOf: url) else {
                skip(file, .unreadable)
                continue
            }
            switch file {
            case .profile:
                switch SnapshotStore.decode(data) {
                case .loaded(let snapshot):
                    result.counts.servers = snapshot.servers.count
                    result.counts.watchedServers = snapshot.servers.filter(\.watch).count
                    result.recordSavedAt = snapshot.savedAt
                case .unsupportedSchema:
                    break   // kept as is; a restore with this version reports the schema
                case .corrupt, .missing:
                    skip(file, .corrupt)
                    continue
                }
                result.files.append((file, data))
            case .history, .metrics:
                let all = FullBackupValidator.lines(data)
                let lines = all.filter { FullBackupValidator.decodes($0, file: file) }
                guard !all.isEmpty else { continue }   // empty file: no data
                guard !lines.isEmpty else {
                    skip(file, .corrupt)
                    continue
                }
                if lines.count < all.count { skip(file, .corruptLines, lines: all.count - lines.count) }
                var joined = Data()
                for line in lines {
                    joined.append(line)
                    joined.append(UInt8(ascii: "\n"))
                }
                if file == .history { result.counts.historyEntries = lines.count } else { result.counts.metricSamples = lines.count }
                result.files.append((file, joined))
            case .watchState:
                guard FullBackupValidator.watchCount(data) != nil else {
                    skip(file, .corrupt)
                    continue
                }
                result.files.append((file, data))
            }
        }
        return result
    }

    static func combinedSHA256(_ files: [(String, Data)]) -> String {
        var hasher = SHA256()
        for (name, data) in files {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            var length = UInt64(data.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// ZIP layout: `manifest.json` followed by the data files (stored, written by `ZipArchive`).
enum FullBackupArchive {
    static func manifest(for content: FullBackupContent, kind: FullBackupKind, appVersion: String,
                         now: Date) -> FullBackupManifest {
        let records = content.files.map { file, data in
            FullBackupManifest.FileRecord(name: file.rawValue, bytes: data.count,
                                          lines: file.isLineBased ? FullBackupValidator.lineCount(data) : nil,
                                          sha256: FullBackupContent.sha256(data))
        }
        return FullBackupManifest(appVersion: appVersion, createdAt: now, kind: kind,
                                  recordSavedAt: content.recordSavedAt, counts: content.counts, files: records,
                                  contentSHA256: content.sha256, skipped: content.skipped.isEmpty ? nil : content.skipped)
    }

    static func make(_ content: FullBackupContent, kind: FullBackupKind, appVersion: String,
                     now: Date) throws -> (data: Data, manifest: FullBackupManifest) {
        let manifest = manifest(for: content, kind: kind, appVersion: appVersion, now: now)
        let entries = [ZipEntry(name: FullBackupManifest.fileName, data: try FullBackupManifest.makeEncoder().encode(manifest))]
            + content.files.map { ZipEntry(name: $0.0.rawValue, data: $0.1) }
        return (ZipArchive.make(entries, modified: now), manifest)
    }
}

/// File names of full backups (local time).
enum FullBackupNaming {
    static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// Save panel suggestion: `playeridentity-backup-20261111-093015.zip`.
    static func manualFileName(now: Date, timeZone: TimeZone = .current) -> String {
        "playeridentity-backup-" + formatter("yyyyMMdd-HHmmss", timeZone: timeZone).string(from: now) + ".zip"
    }

    /// `20261111`: one automatic backup per local day.
    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyyMMdd", timeZone: timeZone).string(from: date)
    }

    /// Name inside `backups/`: `auto-20261111.zip`, `pre-restore-20261111-093015.zip`, `pre-update-…`.
    static func storedFileName(_ kind: FullBackupKind, now: Date, timeZone: TimeZone = .current) -> String {
        switch kind {
        case .automatic: return "auto-" + day(now, timeZone: timeZone) + ".zip"
        case .manual, .preRestore, .preUpdate:
            return kind.rawValue + "-" + formatter("yyyyMMdd-HHmmss", timeZone: timeZone).string(from: now) + ".zip"
        }
    }
}

// MARK: - Validation

enum FullBackupError: Error, Sendable, Equatable {
    case nothingToBackUp
    /// Data files exist, but none of them could be read or decoded (their names): no backup was made.
    case noUsableData([String])
    case unreadableArchive
    case tooLarge
    case unexpectedEntry(String)
    case missingManifest
    case corruptManifest
    case unsupportedSchema(Int)
    case corruptFile(String)
    case unsupportedRecordSchema(Int)
    case updateRunning
    case busy
    case preRestoreBackupFailed(String)
    /// "Save first" before a restore failed (the save error text); nothing was restored.
    case saveFailed(String)
    /// The files could not be put in place, but every previous file was put back.
    case writeFailed(String)
    /// The files could not be put in place and not every previous file could be put back: the copies of the
    /// previous files are still in `staging` (never removed in this case).
    case rollbackFailed(staging: URL, reason: String)

    /// Whether the current data is known to be unchanged after this error.
    var keptCurrentData: Bool {
        if case .rollbackFailed = self { return false }
        return true
    }

    var text: String {
        switch self {
        case .nothingToBackUp: return L10n.text(.backupNothing)
        case .noUsableData(let files): return L10n.format(.backupNoUsableData, String(files.count), files.joined(separator: ", "))
        case .unreadableArchive: return L10n.text(.restoreErrorUnreadable)
        case .tooLarge: return L10n.text(.restoreErrorTooLarge)
        case .unexpectedEntry(let name): return L10n.format(.restoreErrorUnexpected, name)
        case .missingManifest: return L10n.text(.restoreErrorNoManifest)
        case .corruptManifest: return L10n.text(.restoreErrorManifest)
        case .unsupportedSchema(let version): return L10n.format(.restoreErrorSchema, String(version))
        case .corruptFile(let name): return L10n.format(.restoreErrorFile, name)
        case .unsupportedRecordSchema(let version): return L10n.format(.restoreErrorRecordSchema, String(version))
        case .updateRunning: return L10n.text(.restoreErrorUpdate)
        case .busy: return L10n.text(.restoreErrorBusy)
        case .preRestoreBackupFailed(let reason): return L10n.format(.restoreErrorPreBackup, reason)
        case .saveFailed(let reason): return L10n.format(.restoreErrorSave, reason)
        case .writeFailed(let reason): return L10n.format(.restoreErrorWrite, reason)
        case .rollbackFailed(let staging, let reason): return L10n.format(.restoreErrorRollback, reason, staging.path)
        }
    }
}

enum FullBackupValidator {
    static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
            .filter { !$0.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: "\t") } }
    }

    static func lineCount(_ data: Data) -> Int { lines(data).count }

    static func decodes(_ line: Data, file: FullBackupFile) -> Bool {
        let decoder = HistoryCoding.makeDecoder()
        switch file {
        case .history: return (try? decoder.decode(HistoryEntry.self, from: line)) != nil
        case .metrics: return (try? decoder.decode(MetricSample.self, from: line)) != nil
        case .profile, .watchState: return false
        }
    }

    static func decodableLines(_ data: Data, file: FullBackupFile) -> [Data] {
        lines(data).filter { decodes($0, file: file) }
    }

    /// Number of servers in a `watch-state.json`; `nil` if it is not one.
    static func watchCount(_ data: Data) -> Int? {
        (try? HistoryCoding.makeDecoder().decode([String: WatchSnapshot].self, from: data))?.count
    }
}

/// A backup that passed every check, kept in memory until the user confirms the restore.
struct ParsedFullBackup: Sendable, Equatable {
    let manifest: FullBackupManifest
    /// Data files by name (only `FullBackupFile` names).
    let files: [String: Data]
    /// Counted from the files themselves while parsing (the manifest's `counts` must match them).
    let counts: FullBackupManifest.Counts
    /// `savedAt` of the record in the backup (the manifest's `recordSavedAt` must match it).
    let recordSavedAt: Date?

    func data(_ file: FullBackupFile) -> Data? { files[file.rawValue] }
}

enum FullBackupParser {
    /// Backups larger than this are refused before reading (the app's own data stays far below it).
    static let maxArchiveBytes = 256 * 1024 * 1024

    static func read(_ url: URL) -> Result<ParsedFullBackup, FullBackupError> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxArchiveBytes else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadableArchive) }
        return parse(data)
    }

    /// Opens the ZIP and validates the manifest and every file. Nothing is written.
    static func parse(_ data: Data) -> Result<ParsedFullBackup, FullBackupError> {
        guard data.count <= maxArchiveBytes else { return .failure(.tooLarge) }
        guard let entries = ZipArchive.read(data), !entries.isEmpty else { return .failure(.unreadableArchive) }
        let allowed = Set([FullBackupManifest.fileName] + FullBackupFile.allCases.map(\.rawValue))
        var byName: [String: Data] = [:]
        for entry in entries {
            guard allowed.contains(entry.name), byName[entry.name] == nil else { return .failure(.unexpectedEntry(entry.name)) }
            byName[entry.name] = entry.data
        }
        guard let manifestData = byName.removeValue(forKey: FullBackupManifest.fileName) else {
            return .failure(.missingManifest)
        }
        struct Header: Decodable { let schemaVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: manifestData) else { return .failure(.corruptManifest) }
        guard header.schemaVersion == FullBackupManifest.currentSchemaVersion else {
            return .failure(.unsupportedSchema(header.schemaVersion))
        }
        guard let manifest = try? HistoryCoding.makeDecoder().decode(FullBackupManifest.self, from: manifestData),
              Set(manifest.files.map(\.name)) == Set(byName.keys), manifest.files.count == byName.count,
              manifest.warnings.allSatisfy({ skipped in
                  FullBackupFile(rawValue: skipped.file) != nil && (byName[skipped.file] == nil) == skipped.isMissingFromBackup
              }) else {
            return .failure(.corruptManifest)
        }
        var ordered: [(String, Data)] = []
        var counts = FullBackupManifest.Counts()
        var recordSavedAt: Date?
        for file in FullBackupFile.allCases {
            guard let content = byName[file.rawValue] else { continue }
            guard let record = manifest.files.first(where: { $0.name == file.rawValue }),
                  record.bytes == content.count, record.sha256 == FullBackupContent.sha256(content) else {
                return .failure(.corruptFile(file.rawValue))
            }
            switch file {
            case .profile:
                switch SnapshotStore.decode(content) {
                case .loaded(let snapshot):
                    counts.servers = snapshot.servers.count
                    counts.watchedServers = snapshot.servers.filter(\.watch).count
                    recordSavedAt = snapshot.savedAt
                case .unsupportedSchema(let version): return .failure(.unsupportedRecordSchema(version))
                case .corrupt, .missing: return .failure(.corruptFile(file.rawValue))
                }
            case .history, .metrics:
                let lines = FullBackupValidator.lines(content)
                guard lines.allSatisfy({ FullBackupValidator.decodes($0, file: file) }), record.lines == lines.count else {
                    return .failure(.corruptFile(file.rawValue))
                }
                if file == .history { counts.historyEntries = lines.count } else { counts.metricSamples = lines.count }
            case .watchState:
                guard FullBackupValidator.watchCount(content) != nil else { return .failure(.corruptFile(file.rawValue)) }
            }
            ordered.append((file.rawValue, content))
        }
        guard FullBackupContent.combinedSHA256(ordered) == manifest.contentSHA256 else { return .failure(.corruptManifest) }
        // The preview shows what is really in the files; a manifest whose counts or record date say otherwise (a
        // hand-made or edited ZIP) does not match the backup and is refused.
        guard manifest.counts == counts, manifest.recordSavedAt == recordSavedAt else { return .failure(.corruptManifest) }
        return .success(ParsedFullBackup(manifest: manifest, files: byName, counts: counts, recordSavedAt: recordSavedAt))
    }
}

/// Restore preview (§49.2): dates, counts and whether the backup comes from this, an older or a newer version.
struct FullBackupPreview: Sendable, Equatable {
    enum Compatibility: Sendable, Equatable {
        case sameVersion
        case olderVersion
        case newerVersion
    }

    var createdAt: Date
    var appVersion: String
    var recordSavedAt: Date?
    var counts: FullBackupManifest.Counts
    var compatibility: Compatibility
    /// Files that existed but are not in the backup: a restore removes their current versions.
    var missingFiles: [String] = []

    static func make(_ backup: ParsedFullBackup, currentVersion: String) -> FullBackupPreview {
        let manifest = backup.manifest
        let compatibility: Compatibility
        if let from = SemanticVersion(manifest.appVersion), let current = SemanticVersion(currentVersion), from != current {
            compatibility = from < current ? .olderVersion : .newerVersion
        } else {
            compatibility = .sameVersion
        }
        return FullBackupPreview(createdAt: manifest.createdAt, appVersion: manifest.appVersion,
                                 recordSavedAt: backup.recordSavedAt, counts: backup.counts,
                                 compatibility: compatibility, missingFiles: manifest.missingFiles)
    }
}

// MARK: - Store

/// Writes full backups, keeps the automatic ones rotated and puts a validated backup back in place.
struct FullBackupStore: Sendable {
    /// At most this many backups of each kind stay in `backups/` (the oldest is removed first).
    static let maxPerKind = 5

    let paths: AppPaths
    let appVersion: String
    var timeZone: TimeZone = .current
    /// File operations of `restore` (tests inject failures).
    var fileOperations: any DataFileOperating = LocalDataFileOperations()

    var directory: URL { paths.fullBackups }

    enum AutomaticOutcome: Sendable, Equatable {
        case created(URL)
        case alreadyToday
        case unchanged
        case empty
    }

    /// The ZIP of the current data. Throws `nothingToBackUp` when there is no data at all and `noUsableData` when
    /// data files exist but none of them could be read.
    func archive(kind: FullBackupKind, now: Date) throws -> (data: Data, manifest: FullBackupManifest) {
        let content = FullBackupContent.collect(paths)
        try Self.requireUsable(content)
        return try FullBackupArchive.make(content, kind: kind, appVersion: appVersion, now: now)
    }

    private static func requireUsable(_ content: FullBackupContent) throws {
        guard content.isEmpty else { return }
        guard content.skipped.isEmpty else { throw FullBackupError.noUsableData(content.skipped.map(\.file)) }
        throw FullBackupError.nothingToBackUp
    }

    /// Manual backup to a user-chosen file.
    @discardableResult
    func write(to url: URL, now: Date) throws -> FullBackupManifest {
        let (data, manifest) = try archive(kind: .manual, now: now)
        try data.write(to: url, options: .atomic)
        return manifest
    }

    /// Backup into `backups/` (pre-restore, pre-update); `nil` when there is no usable data to back up (a restore
    /// then keeps the unreadable previous files, see `createBackup`). Prunes the kind, never the new file.
    @discardableResult
    func create(_ kind: FullBackupKind, now: Date) throws -> URL? {
        try createBackup(kind, now: now).url
    }

    /// Result of `createBackup`: the file (`nil` when there was nothing to back up) and the files that existed but
    /// could not be backed up.
    struct Created: Sendable, Equatable {
        var url: URL?
        var skipped: [FullBackupManifest.SkippedFile]
    }

    /// `create` that also reports the skipped files (also when nothing at all could be backed up).
    func createBackup(_ kind: FullBackupKind, now: Date) throws -> Created {
        let content = FullBackupContent.collect(paths)
        guard !content.isEmpty else { return Created(url: nil, skipped: content.skipped) }
        let (data, _) = try FullBackupArchive.make(content, kind: kind, appVersion: appVersion, now: now)
        let url = directory.appendingPathComponent(FullBackupNaming.storedFileName(kind, now: now, timeZone: timeZone),
                                                   isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try prune(kind, keeping: url)
        return Created(url: url, skipped: content.skipped)
    }

    /// Launch backup: once per day (`auto-YYYYMMDD.zip`), skipped when the content equals the newest automatic one.
    /// Throws `noUsableData` when data files exist but none could be read (the failure is shown, the day not marked).
    func createAutomatic(now: Date) throws -> AutomaticOutcome {
        let today = directory.appendingPathComponent(FullBackupNaming.storedFileName(.automatic, now: now, timeZone: timeZone),
                                                     isDirectory: false)
        guard !FileManager.default.fileExists(atPath: today.path) else { return .alreadyToday }
        let content = FullBackupContent.collect(paths)
        guard !content.isEmpty else {
            guard content.skipped.isEmpty else { throw FullBackupError.noUsableData(content.skipped.map(\.file)) }
            return .empty
        }
        if let newest = list(.automatic).first, let data = try? Data(contentsOf: newest),
           case .success(let previous) = FullBackupParser.parse(data),
           previous.manifest.contentSHA256 == content.sha256 {
            return .unchanged
        }
        let (data, _) = try FullBackupArchive.make(content, kind: .automatic, appVersion: appVersion, now: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: today, options: .atomic)
        try prune(.automatic, keeping: today)
        return .created(today)
    }

    /// Backups of a kind in `backups/`, newest first by modification date (the name's time stamp only breaks ties),
    /// so a backup written after the clock was set back still counts as the newest one.
    func list(_ kind: FullBackupKind) -> [URL] {
        let prefix = kind.rawValue + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let dated = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".zip") }.map { name -> (URL, Date) in
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, modified ?? .distantPast)
        }
        return dated.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }.map(\.0)
    }

    /// Every ZIP in `backups/` (for the erase inventory).
    var count: Int { FullBackupKind.allCases.reduce(0) { $0 + list($1).count } }

    /// Keeps the `maxPerKind` newest backups of a kind. `keeping` (the file just written) is always kept, whatever
    /// its date says, and counts as the newest one.
    func prune(_ kind: FullBackupKind, keeping newest: URL? = nil) throws {
        var urls = list(kind)
        if let newest {
            let path = newest.standardizedFileURL.path
            urls.removeAll { $0.standardizedFileURL.path == path }
            urls.insert(newest, at: 0)
        }
        for url in urls.dropFirst(Self.maxPerKind) { try FileManager.default.removeItem(at: url) }
    }

    /// Puts the backed-up files in place. The files are staged in a temporary folder next to the data first
    /// (`.restore-<UUID>/new`); the current files are moved aside into `.restore-<UUID>/previous` and only removed
    /// once every new file is in place. Files missing from the backup are removed (the backup is the complete state).
    ///
    /// On an error the previous files are moved back first; only then are the new files taken out again. If every
    /// step of that rollback works the current data is unchanged (`writeFailed`) and the staging folder, which then
    /// holds nothing but copies of the backup, is removed. If any rollback step fails the staging folder is kept,
    /// because it may hold the only copy of a previous file, and `rollbackFailed` reports its location.
    ///
    /// `keepPrevious` (the pre-restore backup could not include every current file): the staging folder with the
    /// previous files is kept after a successful restore and returned, instead of being removed.
    @discardableResult
    func restore(_ backup: ParsedFullBackup, keepPrevious: Bool = false) throws -> URL? {
        let files = fileOperations
        let dataFolder = paths.snapshotFile.deletingLastPathComponent()
        let staging = dataFolder.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        let staged = staging.appendingPathComponent("new", isDirectory: true)
        let previous = staging.appendingPathComponent("previous", isDirectory: true)
        do {
            try files.createDirectory(staged)
            try files.createDirectory(previous)
            for file in FullBackupFile.allCases {
                guard let data = backup.data(file) else { continue }
                try files.write(data, to: staged.appendingPathComponent(file.rawValue, isDirectory: false))
            }
        } catch {
            try? files.remove(staging)   // nothing was moved yet: the folder only holds copies of the backup
            throw FullBackupError.writeFailed(error.localizedDescription)
        }

        var movedAside: [FullBackupFile] = []
        var placed: [FullBackupFile] = []
        do {
            for file in FullBackupFile.allCases {
                let target = file.url(in: paths)
                if files.exists(target) {
                    try files.move(target, to: previous.appendingPathComponent(file.rawValue, isDirectory: false))
                    movedAside.append(file)
                }
                if backup.data(file) != nil {
                    try files.move(staged.appendingPathComponent(file.rawValue, isDirectory: false), to: target)
                    placed.append(file)
                }
            }
        } catch {
            let failed = rollback(movedAside: movedAside, placed: placed, staged: staged, previous: previous)
            guard failed.isEmpty else {
                throw FullBackupError.rollbackFailed(staging: staging, reason: error.localizedDescription)
            }
            try? files.remove(staging)
            throw FullBackupError.writeFailed(error.localizedDescription)
        }
        if keepPrevious {
            try? files.remove(staged)
            return staging
        }
        try? files.remove(staging)
        return nil
    }

    /// Puts every moved-aside file back, then takes the placed new files out again. A new file that sits where a
    /// previous one has to go is moved back into `staged` (never deleted) first. Returns the names whose step failed.
    private func rollback(movedAside: [FullBackupFile], placed: [FullBackupFile], staged: URL, previous: URL) -> [String] {
        let files = fileOperations
        var failed: [String] = []
        for file in movedAside {
            let target = file.url(in: paths)
            if placed.contains(file) {
                do {
                    try files.move(target, to: staged.appendingPathComponent(file.rawValue, isDirectory: false))
                } catch {
                    failed.append(file.rawValue)   // the previous file stays in `previous`
                    continue
                }
            }
            do {
                try files.move(previous.appendingPathComponent(file.rawValue, isDirectory: false), to: target)
            } catch {
                failed.append(file.rawValue)
            }
        }
        for file in placed where !movedAside.contains(file) {
            do { try files.remove(file.url(in: paths)) } catch { failed.append(file.rawValue) }
        }
        return failed
    }
}

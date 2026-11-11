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

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// The current data read from disk, ready to be archived. Unreadable parts are left out, so every backup can be
/// restored again: a corrupt record or watch state is skipped and only decodable JSONL lines are kept (an append
/// that is running at the same time can never leave a partial line in the backup).
struct FullBackupContent: Sendable {
    var files: [(FullBackupFile, Data)]
    var counts: FullBackupManifest.Counts
    var recordSavedAt: Date?

    var isEmpty: Bool { files.isEmpty }

    var sha256: String { Self.combinedSHA256(files.map { ($0.0.rawValue, $0.1) }) }

    static func collect(_ paths: AppPaths) -> FullBackupContent {
        var result = FullBackupContent(files: [], counts: .init(), recordSavedAt: nil)
        for file in FullBackupFile.allCases {
            guard let data = try? Data(contentsOf: file.url(in: paths)) else { continue }
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
                    continue
                }
                result.files.append((file, data))
            case .history, .metrics:
                let lines = FullBackupValidator.decodableLines(data, file: file)
                guard !lines.isEmpty else { continue }
                var joined = Data()
                for line in lines {
                    joined.append(line)
                    joined.append(UInt8(ascii: "\n"))
                }
                if file == .history { result.counts.historyEntries = lines.count } else { result.counts.metricSamples = lines.count }
                result.files.append((file, joined))
            case .watchState:
                guard FullBackupValidator.watchCount(data) != nil else { continue }
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
                                  contentSHA256: content.sha256)
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
    case writeFailed(String)

    var text: String {
        switch self {
        case .nothingToBackUp: return L10n.text(.backupNothing)
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
        case .writeFailed(let reason): return L10n.format(.restoreErrorWrite, reason)
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
              Set(manifest.files.map(\.name)) == Set(byName.keys), manifest.files.count == byName.count else {
            return .failure(.corruptManifest)
        }
        var ordered: [(String, Data)] = []
        for file in FullBackupFile.allCases {
            guard let content = byName[file.rawValue] else { continue }
            guard let record = manifest.files.first(where: { $0.name == file.rawValue }),
                  record.bytes == content.count, record.sha256 == FullBackupContent.sha256(content) else {
                return .failure(.corruptFile(file.rawValue))
            }
            switch file {
            case .profile:
                switch SnapshotStore.decode(content) {
                case .loaded: break
                case .unsupportedSchema(let version): return .failure(.unsupportedRecordSchema(version))
                case .corrupt, .missing: return .failure(.corruptFile(file.rawValue))
                }
            case .history, .metrics:
                let lines = FullBackupValidator.lines(content)
                guard lines.allSatisfy({ FullBackupValidator.decodes($0, file: file) }), record.lines == lines.count else {
                    return .failure(.corruptFile(file.rawValue))
                }
            case .watchState:
                guard FullBackupValidator.watchCount(content) != nil else { return .failure(.corruptFile(file.rawValue)) }
            }
            ordered.append((file.rawValue, content))
        }
        guard FullBackupContent.combinedSHA256(ordered) == manifest.contentSHA256 else { return .failure(.corruptManifest) }
        return .success(ParsedFullBackup(manifest: manifest, files: byName))
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

    static func make(_ backup: ParsedFullBackup, currentVersion: String) -> FullBackupPreview {
        let manifest = backup.manifest
        let compatibility: Compatibility
        if let from = SemanticVersion(manifest.appVersion), let current = SemanticVersion(currentVersion), from != current {
            compatibility = from < current ? .olderVersion : .newerVersion
        } else {
            compatibility = .sameVersion
        }
        return FullBackupPreview(createdAt: manifest.createdAt, appVersion: manifest.appVersion,
                                 recordSavedAt: manifest.recordSavedAt, counts: manifest.counts,
                                 compatibility: compatibility)
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

    var directory: URL { paths.fullBackups }

    enum AutomaticOutcome: Sendable, Equatable {
        case created(URL)
        case alreadyToday
        case unchanged
        case empty
    }

    /// The ZIP of the current data. Throws `nothingToBackUp` when there is no data at all.
    func archive(kind: FullBackupKind, now: Date) throws -> (data: Data, manifest: FullBackupManifest) {
        let content = FullBackupContent.collect(paths)
        guard !content.isEmpty else { throw FullBackupError.nothingToBackUp }
        return try FullBackupArchive.make(content, kind: kind, appVersion: appVersion, now: now)
    }

    /// Manual backup to a user-chosen file.
    @discardableResult
    func write(to url: URL, now: Date) throws -> FullBackupManifest {
        let (data, manifest) = try archive(kind: .manual, now: now)
        try data.write(to: url, options: .atomic)
        return manifest
    }

    /// Backup into `backups/` (pre-restore, pre-update); `nil` when there is no data to back up. Prunes the kind.
    @discardableResult
    func create(_ kind: FullBackupKind, now: Date) throws -> URL? {
        let content = FullBackupContent.collect(paths)
        guard !content.isEmpty else { return nil }
        let (data, _) = try FullBackupArchive.make(content, kind: kind, appVersion: appVersion, now: now)
        let url = directory.appendingPathComponent(FullBackupNaming.storedFileName(kind, now: now, timeZone: timeZone),
                                                   isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try prune(kind)
        return url
    }

    /// Launch backup: once per day (`auto-YYYYMMDD.zip`), skipped when the content equals the newest automatic one.
    func createAutomatic(now: Date) throws -> AutomaticOutcome {
        let today = directory.appendingPathComponent(FullBackupNaming.storedFileName(.automatic, now: now, timeZone: timeZone),
                                                     isDirectory: false)
        guard !FileManager.default.fileExists(atPath: today.path) else { return .alreadyToday }
        let content = FullBackupContent.collect(paths)
        guard !content.isEmpty else { return .empty }
        if let newest = list(.automatic).first, let data = try? Data(contentsOf: newest),
           case .success(let previous) = FullBackupParser.parse(data),
           previous.manifest.contentSHA256 == content.sha256 {
            return .unchanged
        }
        let (data, _) = try FullBackupArchive.make(content, kind: .automatic, appVersion: appVersion, now: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: today, options: .atomic)
        try prune(.automatic)
        return .created(today)
    }

    /// Backups of a kind in `backups/`, newest first (the time stamp in the name sorts chronologically).
    func list(_ kind: FullBackupKind) -> [URL] {
        let prefix = kind.rawValue + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".zip") }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// Every ZIP in `backups/` (for the erase inventory).
    var count: Int { FullBackupKind.allCases.reduce(0) { $0 + list($1).count } }

    func prune(_ kind: FullBackupKind) throws {
        for url in list(kind).dropFirst(Self.maxPerKind) { try FileManager.default.removeItem(at: url) }
    }

    /// Puts the backed-up files in place. The files are staged in a temporary folder next to the data first; the
    /// current files are moved aside and only removed once every new file is in place. On any error the previous
    /// files are put back, so the current data is never lost. Files missing from the backup are removed (the
    /// backup is the complete state).
    func restore(_ backup: ParsedFullBackup) throws {
        let fileManager = FileManager.default
        let dataFolder = paths.snapshotFile.deletingLastPathComponent()
        let staging = dataFolder.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        let staged = staging.appendingPathComponent("new", isDirectory: true)
        let previous = staging.appendingPathComponent("previous", isDirectory: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previous, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for file in FullBackupFile.allCases {
            guard let data = backup.data(file) else { continue }
            try data.write(to: staged.appendingPathComponent(file.rawValue, isDirectory: false))
        }

        var movedAside: [FullBackupFile] = []
        var placed: [FullBackupFile] = []
        do {
            for file in FullBackupFile.allCases {
                let target = file.url(in: paths)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.moveItem(at: target, to: previous.appendingPathComponent(file.rawValue))
                    movedAside.append(file)
                }
                if backup.data(file) != nil {
                    try fileManager.moveItem(at: staged.appendingPathComponent(file.rawValue), to: target)
                    placed.append(file)
                }
            }
        } catch {
            for file in placed { try? fileManager.removeItem(at: file.url(in: paths)) }
            for file in movedAside {
                try? fileManager.moveItem(at: previous.appendingPathComponent(file.rawValue), to: file.url(in: paths))
            }
            throw error
        }
    }
}

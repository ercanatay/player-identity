import Foundation

// MARK: - §71 Folder-based sync

/// One synced record: the value is `nil` once the record is deleted (tombstone, `deletedAt` set). `updatedAt` is the
/// last change of the record (a deletion is a change too); the newer one wins when two copies meet (§71.2).
struct SyncRecord<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    var value: Value?

    var isDeleted: Bool { deletedAt != nil }

    /// Same state regardless of the stamps (both deleted, or both alive with the same value).
    func sameContent(as other: SyncRecord) -> Bool {
        isDeleted == other.isDeleted && (isDeleted || value == other.value)
    }
}

/// §61 profile (the data root path and the game folder; nothing read from the game files).
struct SyncProfile: Codable, Sendable, Equatable {
    var name: String
    var dataRoot: String?
    var gamedir: String
    var createdAt: Date
}

/// Server row without CID, check state, ban list URL, ban record endpoint or any history (§71.1).
struct SyncServer: Codable, Sendable, Equatable {
    var label: String
    var host: String
    var port: Int
    var group: String?
    var favorite: Bool
    var order: Int
    var notifications: ServerNotificationSettings?
}

/// A watched server (§42); the record id is the server id. Unwatching deletes the record.
struct SyncWatched: Codable, Sendable, Equatable {
    var watch = true
}

/// Server note and appeal (§32, §36); the record id is the server id. An empty note without appeal deletes it.
struct SyncNote: Codable, Sendable, Equatable {
    var note: String
    var appeal: Appeal?
}

/// The synced preferences (§71.1: language, notification preferences, quiet hours, appearance = menu bar mode).
struct SyncSettings: Codable, Sendable, Equatable {
    var language: String
    var notificationsEnabled: Bool
    var notifyBanChanges: Bool
    var notifyOnlineChanges: Bool
    var notifyMapChanges: Bool
    var quietHoursEnabled: Bool
    var quietHoursStart: String
    var quietHoursEnd: String
    var showInMenuBar: Bool
}

/// `<sync folder>/playeridentity-sync.json` (`schemaVersion: 1`). Also the local ledger (`sync-state.json`): the
/// records as they were after the last successful sync, which tells local edits and deletions apart.
struct SyncFile: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let fileName = "playeridentity-sync.json"
    /// The single settings record has a fixed id.
    static let settingsID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!

    var schemaVersion = SyncFile.currentSchemaVersion
    var deviceID: String
    var updatedAt: Date
    var profiles: [SyncRecord<SyncProfile>] = []
    var servers: [SyncRecord<SyncServer>] = []
    var watched: [SyncRecord<SyncWatched>] = []
    var settings: SyncRecord<SyncSettings>?
    var notes: [SyncRecord<SyncNote>] = []

    /// The records only (no header): two files with the same records need no write.
    func sameRecords(as other: SyncFile) -> Bool {
        profiles == other.profiles && servers == other.servers && watched == other.watched
            && settings == other.settings && notes == other.notes
    }

    /// Live (not deleted) records as plain values.
    var live: SyncLocalData {
        func values<V>(_ records: [SyncRecord<V>]) -> [UUID: V] {
            Dictionary(records.compactMap { record in record.value.map { (record.id, $0) } }) { first, _ in first }
        }
        return SyncLocalData(profiles: values(profiles), servers: values(servers), watched: values(watched),
                             notes: values(notes), settings: settings?.value)
    }
}

/// The local data in sync form (one value per record id).
struct SyncLocalData: Sendable, Equatable {
    var profiles: [UUID: SyncProfile] = [:]
    var servers: [UUID: SyncServer] = [:]
    var watched: [UUID: SyncWatched] = [:]
    var notes: [UUID: SyncNote] = [:]
    var settings: SyncSettings?

    /// Projects the model; every value goes through the file encoding once, so a value read back from the file is
    /// equal to the local one (dates keep millisecond precision).
    static func make(profiles: [Profile], servers: [ServerEntry], settings: SyncSettings?) -> SyncLocalData {
        var data = SyncLocalData()
        for profile in profiles {
            data.profiles[profile.id] = SyncCoding.normalized(
                SyncProfile(name: profile.name, dataRoot: profile.dataRoot, gamedir: profile.gamedir,
                            createdAt: profile.createdAt))
        }
        for entry in servers {
            let projection = SyncServerProjection(entry)
            data.servers[entry.id] = projection.server
            if let watched = projection.watched { data.watched[entry.id] = watched }
            if let note = projection.note { data.notes[entry.id] = note }
        }
        data.settings = settings.map(SyncCoding.normalized)
        return data
    }
}

/// What sync carries of one server row (server fields, watch switch, note + appeal).
struct SyncServerProjection: Sendable, Equatable {
    var server: SyncServer
    var watched: SyncWatched?
    var note: SyncNote?

    init(server: SyncServer, watched: SyncWatched?, note: SyncNote?) {
        self.server = server
        self.watched = watched
        self.note = note
    }

    init(_ entry: ServerEntry) {
        server = SyncCoding.normalized(SyncServer(label: entry.label, host: entry.host, port: entry.port,
                                                  group: entry.group, favorite: entry.favorite, order: entry.order,
                                                  notifications: entry.notifications))
        watched = entry.watch ? SyncWatched() : nil
        var appeal = entry.appeal
        appeal?.notifiedAt = nil   // reminder bookkeeping of this Mac, not a user edit
        note = entry.note.isEmpty && appeal == nil ? nil : SyncCoding.normalized(SyncNote(note: entry.note, appeal: appeal))
    }

    /// The projection of `id` in `data`, `nil` when the server is not there.
    static func of(_ id: UUID, in data: SyncLocalData) -> SyncServerProjection? {
        data.servers[id].map { SyncServerProjection(server: $0, watched: data.watched[id], note: data.notes[id]) }
    }

    /// Same validation as the server form (§8, §20, §32): a row read from another device is applied only when valid.
    var isValid: Bool {
        !server.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && HostValidator.classify(server.host) != nil && HostValidator.isValidPort(server.port)
            && ServerNote.isValid(note?.note ?? "") && (note?.appeal?.isValid ?? true)
    }

    /// Writes the synced fields into a row; the check state is reset when the address changed.
    func apply(to entry: ServerEntry) -> ServerEntry {
        var copy = entry
        if HostValidator.normalized(entry.host) != HostValidator.normalized(server.host) || entry.port != server.port {
            copy.cid = ""
            copy.lastCheckedAt = nil
            copy.banCheck = nil
        }
        copy.label = server.label
        copy.host = server.host
        copy.port = server.port
        copy.group = ServerOrganization.normalizedGroup(server.group)
        copy.favorite = server.favorite
        copy.order = server.order
        copy.notifications = server.notifications
        copy.watch = watched != nil
        copy.note = note?.note ?? ""
        let incoming = note?.appeal
        var current = entry.appeal
        current?.notifiedAt = nil
        if current != incoming { copy.appeal = incoming }
        return copy
    }

    func newEntry(id: UUID) -> ServerEntry {
        apply(to: ServerEntry(id: id, label: server.label, host: server.host, port: server.port))
    }
}

/// The JSON form of the sync file: ISO 8601 dates with milliseconds, sorted keys.
enum SyncCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
            }
            return date
        }
        return decoder
    }

    /// Milliseconds since 1970 (the precision of the file).
    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func rounded(_ date: Date) -> Date { Date(timeIntervalSince1970: Double(milliseconds(date)) / 1000) }

    /// `2026-11-18T10:15:00.123Z`
    static func string(_ date: Date) -> String {
        let ms = milliseconds(date)
        let seconds = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
        let fraction = ms - seconds * 1000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
        return String(base.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return rounded(date) }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map(rounded)
    }

    /// The value as it reads back from the file.
    static func normalized<V: Codable>(_ value: V) -> V {
        guard let data = try? makeEncoder().encode(value),
              let decoded = try? makeDecoder().decode(V.self, from: data) else { return value }
        return decoded
    }

    static func encode(_ file: SyncFile) throws -> Data { try makeEncoder().encode(file) }

    /// `nil` header → `.corrupt`; another schema → `.unsupported`.
    enum Decoded: Equatable {
        case file(SyncFile)
        case corrupt
        case unsupported(Int)
    }

    static func decode(_ data: Data) -> Decoded {
        struct Header: Decodable { let schemaVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return .corrupt }
        guard header.schemaVersion == SyncFile.currentSchemaVersion else { return .unsupported(header.schemaVersion) }
        guard let file = try? makeDecoder().decode(SyncFile.self, from: data) else { return .corrupt }
        return .file(file)
    }
}

// MARK: Stamping and merging

enum FolderSyncMerge {
    /// Turns the local values into records: an unchanged value keeps the stamp of the ledger, a new or changed value
    /// gets `now` (always later than its previous stamp), and a ledger record missing locally becomes a tombstone.
    /// Without `allowDeletions` (no local record yet) missing records are left to the remote side instead.
    static func stamp(_ local: SyncLocalData, ledger: SyncFile?, now: Date, allowDeletions: Bool) -> SyncFile {
        var file = SyncFile(deviceID: ledger?.deviceID ?? "", updatedAt: now)
        file.profiles = stamp(local.profiles, ledger?.profiles ?? [], now: now, allowDeletions: allowDeletions)
        file.servers = stamp(local.servers, ledger?.servers ?? [], now: now, allowDeletions: allowDeletions)
        file.watched = stamp(local.watched, ledger?.watched ?? [], now: now, allowDeletions: allowDeletions)
        file.notes = stamp(local.notes, ledger?.notes ?? [], now: now, allowDeletions: allowDeletions)
        let settings = local.settings.map { [SyncFile.settingsID: $0] } ?? [:]
        file.settings = stamp(settings, ledger?.settings.map { [$0] } ?? [], now: now, allowDeletions: false).first
        return file
    }

    static func stamp<V>(_ local: [UUID: V], _ ledger: [SyncRecord<V>], now: Date,
                         allowDeletions: Bool) -> [SyncRecord<V>] {
        var records: [UUID: SyncRecord<V>] = [:]
        for record in ledger { records[record.id] = record }
        func next(after previous: Date?) -> Date {
            let now = SyncCoding.rounded(now)
            guard let previous, previous >= now else { return now }
            return SyncCoding.rounded(previous.addingTimeInterval(0.001))
        }
        for (id, value) in local {
            let previous = records[id]
            if let previous, !previous.isDeleted, previous.value == value { continue }
            records[id] = SyncRecord(id: id, updatedAt: next(after: previous?.updatedAt), deletedAt: nil, value: value)
        }
        for record in ledger where !record.isDeleted && local[record.id] == nil {
            if allowDeletions {
                let stamp = next(after: record.updatedAt)
                records[record.id] = SyncRecord(id: record.id, updatedAt: stamp, deletedAt: stamp, value: nil)
            } else {
                records[record.id] = nil
            }
        }
        return sorted(Array(records.values))
    }

    /// Record by record: the newer `updatedAt` wins, a record on one side only is kept (a tombstone deletes on both
    /// sides), the same stamp with different content keeps the local copy and counts a conflict.
    static func merge<V>(local: [SyncRecord<V>], remote: [SyncRecord<V>]) -> (records: [SyncRecord<V>], conflicts: Int) {
        var result: [UUID: SyncRecord<V>] = [:]
        var conflicts = 0
        for record in remote where result[record.id].map({ record.updatedAt > $0.updatedAt }) ?? true {
            result[record.id] = record
        }
        for record in local {
            guard let other = result[record.id] else {
                result[record.id] = record
                continue
            }
            if record.updatedAt > other.updatedAt {
                result[record.id] = record
            } else if record.updatedAt == other.updatedAt {
                if !record.sameContent(as: other) { conflicts += 1 }
                result[record.id] = record
            }
        }
        return (sorted(Array(result.values)), conflicts)
    }

    /// `adoptRemoteSettings`: this Mac never synced its preferences yet (joining), so the shared ones are taken
    /// instead of letting the newly stamped local defaults win.
    static func merge(local: SyncFile, remote: SyncFile?,
                      adoptRemoteSettings: Bool = false) -> (file: SyncFile, conflicts: Int) {
        guard let remote else { return (local, 0) }
        if adoptRemoteSettings, let shared = remote.settings, !shared.isDeleted {
            var joining = local
            joining.settings = shared
            return merge(local: joining, remote: remote)
        }
        var file = local
        let profiles = merge(local: local.profiles, remote: remote.profiles)
        let servers = merge(local: local.servers, remote: remote.servers)
        let watched = merge(local: local.watched, remote: remote.watched)
        let notes = merge(local: local.notes, remote: remote.notes)
        let settings = merge(local: local.settings.map { [$0] } ?? [], remote: remote.settings.map { [$0] } ?? [])
        file.profiles = profiles.records
        file.servers = servers.records
        file.watched = watched.records
        file.notes = notes.records
        file.settings = settings.records.first { $0.id == SyncFile.settingsID }
        return (file, profiles.conflicts + servers.conflicts + watched.conflicts + notes.conflicts + settings.conflicts)
    }

    /// The ledger kept after a sync: tombstones, and the live records the local data really took over (a record that
    /// was not applied — invalid, a duplicate profile, or a row edited meanwhile — is left out, so it is neither
    /// "unchanged" nor deleted by the next sync).
    static func ledger(merged: SyncFile, applied: SyncLocalData) -> SyncFile {
        func keep<V>(_ records: [SyncRecord<V>], _ values: [UUID: V]) -> [SyncRecord<V>] {
            records.filter { $0.isDeleted || values[$0.id] == $0.value }
        }
        var file = merged
        file.profiles = keep(merged.profiles, applied.profiles)
        file.servers = keep(merged.servers, applied.servers)
        file.watched = keep(merged.watched, applied.watched)
        file.notes = keep(merged.notes, applied.notes)
        file.settings = merged.settings.flatMap { $0.value == applied.settings ? $0 : nil }
        return file
    }

    private static func sorted<V>(_ records: [SyncRecord<V>]) -> [SyncRecord<V>] {
        records.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

// MARK: Applying the merged data

enum FolderSyncApply {
    /// Rebases `current` rows onto the merged data: a row whose synced fields still equal `base` (not edited since)
    /// takes the merged values or is removed when merged deleted it; a row edited since `base` or only in `current`
    /// stays; merged rows unknown to both are appended. Rows with invalid merged values are left as they are.
    static func servers(current: [ServerEntry], base: SyncLocalData, merged: SyncLocalData) -> [ServerEntry] {
        var result: [ServerEntry] = []
        var known = Set<UUID>()
        for entry in current {
            known.insert(entry.id)
            guard let original = SyncServerProjection.of(entry.id, in: base),
                  original == SyncServerProjection(entry) else {
                result.append(entry)
                continue
            }
            guard let incoming = SyncServerProjection.of(entry.id, in: merged) else { continue }   // deleted
            result.append(incoming.isValid ? incoming.apply(to: entry) : entry)
        }
        known.formUnion(base.servers.keys)
        let added = merged.servers.keys.filter { !known.contains($0) }
            .compactMap { id in SyncServerProjection.of(id, in: merged).map { (id, $0) } }
            .filter { $0.1.isValid }
            .sorted { ($0.1.server.order, $0.0.uuidString) < ($1.1.server.order, $1.0.uuidString) }
        result.append(contentsOf: added.map { $0.1.newEntry(id: $0.0) })
        return result
    }

    /// The merged profiles in the local order (new ones appended by creation date). A new profile with the same data
    /// root + game folder as one already in the list is not added (two Macs each migrate their own `Default`); it
    /// stays in the sync file only. `nil` when nothing changes or the merged list would be empty (the local list is
    /// kept then).
    /// Like `servers`, a profile changed since `base` keeps its local state.
    static func profiles(current: [Profile], base: SyncLocalData, merged: SyncLocalData,
                         defaultDataRoot: URL) -> [Profile]? {
        var result: [Profile] = []
        for profile in current {
            let local = SyncLocalData.make(profiles: [profile], servers: [], settings: nil).profiles[profile.id]
            guard let original = base.profiles[profile.id], original == local else {
                result.append(profile)
                continue
            }
            guard let value = merged.profiles[profile.id] else { continue }
            result.append(Profile(id: profile.id, name: value.name, dataRoot: value.dataRoot, gamedir: value.gamedir,
                                  createdAt: value.createdAt))
        }
        let known = Set(current.map(\.id)).union(base.profiles.keys)
        let added = merged.profiles.filter { !known.contains($0.key) && !$0.value.name.isEmpty }
            .sorted { ($0.value.createdAt, $0.key.uuidString) < ($1.value.createdAt, $1.key.uuidString) }
        for (id, value) in added {
            let list = ProfileList(profiles: result, activeID: id, defaultDataRoot: defaultDataRoot)
            guard result.isEmpty || !list.hasCombination(dataRoot: value.dataRoot, gamedir: value.gamedir) else { continue }
            result.append(Profile(id: id, name: value.name, dataRoot: value.dataRoot, gamedir: value.gamedir,
                                  createdAt: value.createdAt))
        }
        guard !result.isEmpty else { return nil }
        let normalizedCurrent = current.map { profile -> Profile in
            var copy = profile
            copy.createdAt = SyncCoding.rounded(profile.createdAt)
            return copy
        }
        return result == normalizedCurrent ? nil : result
    }
}

// MARK: Folder access

/// Why a sync stopped (§71.2). Local data is never changed by a failed sync.
enum FolderSyncError: Error, Sendable, Equatable {
    /// The chosen folder is gone (disk not mounted, folder removed).
    case folderMissing
    /// The folder (or the file in it) cannot be read or written.
    case folderNotAccessible(String)
    /// The sync file is damaged; it was moved aside as `<name>` (`nil`: moving it failed too).
    case corrupt(backup: String?)
    /// The file was written by a newer version (another schema); it is left untouched.
    case unsupportedVersion(Int)
    /// The local record cannot be read, so the local state is unknown.
    case localRecordUnreadable

    var text: String {
        switch self {
        case .folderMissing: return L10n.text(.syncErrorFolderMissing)
        case .folderNotAccessible(let detail): return L10n.format(.syncErrorFolderAccess, detail)
        case .corrupt(let backup): return L10n.format(.syncErrorCorrupt, backup ?? "—")
        case .unsupportedVersion(let version): return L10n.format(.syncErrorUnsupported, String(version))
        case .localRecordUnreadable: return L10n.text(.syncErrorLocalRecord)
        }
    }

    /// Technical text for the error log (`sync` area).
    var logMessage: String {
        switch self {
        case .folderMissing: return "folderMissing"
        case .folderNotAccessible(let detail): return "folderNotAccessible: \(detail)"
        case .corrupt(let backup): return "corrupt: backup=\(backup ?? "failed")"
        case .unsupportedVersion(let version): return "unsupportedVersion \(version)"
        case .localRecordUnreadable: return "localRecordUnreadable"
        }
    }
}

enum SyncFolderState: Sendable, Equatable {
    case ready
    case missing
    case notAccessible
}

/// File access of the sync folder (tests inject failures and slow disks).
protocol SyncFolderAccessing: Sendable {
    func state(of folder: URL) -> SyncFolderState
    /// `nil` when the file does not exist.
    func read(_ url: URL) throws -> Data?
    /// Temporary file in the same folder + rename, so a reader never sees half a file.
    func writeAtomically(_ data: Data, to url: URL) throws
    func move(_ source: URL, to destination: URL) throws
}

struct LocalSyncFolderAccess: SyncFolderAccessing {
    init() {}

    func state(of folder: URL) -> SyncFolderState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .missing }
        let manager = FileManager.default
        return manager.isReadableFile(atPath: folder.path) && manager.isWritableFile(atPath: folder.path)
            && manager.isExecutableFile(atPath: folder.path) ? .ready : .notAccessible
    }

    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }

    func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

// MARK: The sync run

struct FolderSyncOutcome: Sendable, Equatable {
    /// The records after the merge (the new ledger) and their live values (applied to the model).
    var merged: SyncFile
    var conflicts: Int
    /// The sync file was (re)written.
    var wroteRemote: Bool
    /// 2 when the file changed under the first pass (another device wrote at the same time).
    var passes: Int
}

/// Reads, merges and writes the sync file (§71.2). Pure apart from `access`; runs off the main thread.
struct FolderSyncEngine: Sendable {
    var access: any SyncFolderAccessing = LocalSyncFolderAccess()

    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent(SyncFile.fileName, isDirectory: false)
    }

    /// `playeridentity-sync.json.corrupt-20261118-101500`
    static func corruptBackupURL(for file: URL, at date: Date, timeZone: TimeZone = .current) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(
            file.lastPathComponent + ".corrupt-" + FullBackupNaming.formatter("yyyyMMdd-HHmmss", timeZone: timeZone)
                .string(from: date), isDirectory: false)
    }

    func run(folder: URL, local: SyncLocalData, ledger: SyncFile?, deviceID: String, now: Date,
             allowDeletions: Bool) -> Result<FolderSyncOutcome, FolderSyncError> {
        switch access.state(of: folder) {
        case .ready: break
        case .missing: return .failure(.folderMissing)
        case .notAccessible: return .failure(.folderNotAccessible(folder.path))
        }
        let url = Self.fileURL(in: folder)
        var stamped = FolderSyncMerge.stamp(local, ledger: ledger, now: now, allowDeletions: allowDeletions)
        stamped.deviceID = deviceID
        for pass in 1...2 {
            let remote: SyncFile?
            switch read(url, now: now) {
            case .success(let file): remote = file
            case .failure(let error): return .failure(error)
            }
            let (merged, conflicts) = FolderSyncMerge.merge(local: stamped, remote: remote,
                                                            adoptRemoteSettings: ledger?.settings == nil)
            var file = merged
            file.deviceID = deviceID
            file.updatedAt = SyncCoding.rounded(max(now, remote?.updatedAt.addingTimeInterval(0.001) ?? now))
            guard remote.map({ !$0.sameRecords(as: merged) }) ?? true else {
                return .success(FolderSyncOutcome(merged: remote ?? file, conflicts: conflicts, wroteRemote: false,
                                                  passes: pass))
            }
            do {
                try access.writeAtomically(try SyncCoding.encode(file), to: url)
            } catch {
                return .failure(.folderNotAccessible(error.localizedDescription))
            }
            // Read back: another device may have renamed its file over ours in between (second pass then).
            if case .success(let check?) = read(url, now: now, backUpCorrupt: false),
               check.deviceID != deviceID || check.updatedAt != file.updatedAt, pass == 1 {
                continue
            }
            return .success(FolderSyncOutcome(merged: file, conflicts: conflicts, wroteRemote: true, passes: pass))
        }
        return .failure(.folderNotAccessible(url.path))   // not reached: the second pass always returns
    }

    /// The current sync file (`nil` when there is none). A damaged file is moved to `.corrupt-<time>`.
    private func read(_ url: URL, now: Date, backUpCorrupt: Bool = true) -> Result<SyncFile?, FolderSyncError> {
        let data: Data?
        do {
            data = try access.read(url)
        } catch {
            return .failure(.folderNotAccessible(error.localizedDescription))
        }
        guard let data else { return .success(nil) }
        switch SyncCoding.decode(data) {
        case .file(let file): return .success(file)
        case .unsupported(let version): return .failure(.unsupportedVersion(version))
        case .corrupt:
            guard backUpCorrupt else { return .failure(.corrupt(backup: nil)) }
            let backup = Self.corruptBackupURL(for: url, at: now)
            do {
                try access.move(url, to: backup)
                return .failure(.corrupt(backup: backup.lastPathComponent))
            } catch {
                return .failure(.corrupt(backup: nil))
            }
        }
    }
}

/// `sync-state.json` in the app's data folder: the ledger of the last successful sync.
struct SyncLedgerStore: Sendable {
    let fileURL: URL

    /// `nil` when missing or unreadable (the next sync then treats every local record as new).
    func load() -> SyncFile? {
        guard let data = try? Data(contentsOf: fileURL), case .file(let file) = SyncCoding.decode(data) else { return nil }
        return file
    }

    func save(_ file: SyncFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyncCoding.encode(file).write(to: fileURL, options: .atomic)
    }

    func remove() { try? FileManager.default.removeItem(at: fileURL) }
}

// MARK: Timing

/// When the next sync is due (§71.2): 5 s after the last record write (each write pushes it back), a short delay
/// after launch, at most 2 s at quit. Pure, so tests drive it with a fake clock.
struct SyncDebounce: Sendable, Equatable {
    static let delay: TimeInterval = 5
    static let launchDelay: TimeInterval = 3
    static let quitBudget: TimeInterval = 2

    private(set) var dueAt: Date?

    init() {}

    mutating func schedule(now: Date, delay: TimeInterval = SyncDebounce.delay) {
        dueAt = now.addingTimeInterval(delay)
    }

    /// Seconds until due (0 when due now, `nil` when nothing is scheduled).
    func remaining(now: Date) -> TimeInterval? {
        dueAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// `true` once (and clears the schedule) when the time has come.
    mutating func fire(now: Date) -> Bool {
        guard let dueAt, now >= dueAt else { return false }
        self.dueAt = nil
        return true
    }

    mutating func cancel() { dueAt = nil }
}

import Foundation

// MARK: - Model (§22)

enum HistoryKind: String, Codable, Sendable, CaseIterable {
    case refresh
    case ipChanged
    case banAppeared
    case banLifted
    case identityChanged
    case nameChanged
    case modelChanged
    case apply
    case fixAttempt
    case appUpdateAvailable
    /// §32: an appeal was saved (`old`/`new` = status, `note` = channel).
    case appeal
    /// §36: the server note changed (`old`/`new` = note, cut to 500 characters).
    case note
}

/// One line of `history.jsonl`: `{ts, kind, serverID?, host?, old?, new?, note?}`.
struct HistoryEntry: Codable, Sendable, Equatable {
    var ts: Date
    var kind: HistoryKind
    var serverID: UUID?
    var host: String?
    var old: String?
    var new: String?
    var note: String?

    init(ts: Date, kind: HistoryKind, serverID: UUID? = nil, host: String? = nil,
         old: String? = nil, new: String? = nil, note: String? = nil) {
        self.ts = ts
        self.kind = kind
        self.serverID = serverID
        self.host = host
        self.old = old
        self.new = new
        self.note = note
    }
}

enum HistoryCoding {
    static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One JSON object per line; unreadable lines are skipped (corrupt-line tolerance).
    static func decodeLines(_ data: Data) -> [HistoryEntry] {
        let decoder = makeDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(HistoryEntry.self, from: Data(line))
        }
    }

    static func encodeLine(_ entry: HistoryEntry) throws -> Data {
        var data = try makeEncoder().encode(entry)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// MARK: - Retention

enum HistoryRetention {
    static let maxEntries = 5000
    static let maxAge: TimeInterval = 90 * 24 * 60 * 60

    /// Drops entries older than 90 days, then keeps the newest 5000 (whichever limit is hit first).
    static func apply(_ entries: [HistoryEntry], now: Date) -> [HistoryEntry] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let recent = entries.filter { $0.ts >= cutoff }
        return recent.count > maxEntries ? Array(recent.suffix(maxEntries)) : recent
    }
}

// MARK: - Store

/// `history.jsonl`: append-only, one line per entry. Appends add whole lines at the end of the file; compaction
/// (retention) rewrites the file atomically.
struct HistoryStore: Sendable {
    let fileURL: URL

    func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return HistoryCoding.decodeLines(data)
    }

    func append(_ entries: [HistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        var payload = Data()
        for entry in entries { payload.append(try HistoryCoding.encodeLine(entry)) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            try payload.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            // A previous write may have been cut short: start on a fresh line so it cannot corrupt this one.
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) {
                payload.insert(UInt8(ascii: "\n"), at: 0)
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: payload)
    }

    /// Applies retention and drops corrupt lines; rewrites atomically only if something changed.
    /// Returns the entries kept.
    @discardableResult
    func compact(now: Date) throws -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let entries = HistoryCoding.decodeLines(data)
        let kept = HistoryRetention.apply(entries, now: now)
        let lineCount = data.split(separator: UInt8(ascii: "\n")).count
        guard kept.count != lineCount else { return kept }
        var payload = Data()
        for entry in kept { payload.append(try HistoryCoding.encodeLine(entry)) }
        try payload.write(to: fileURL, options: .atomic)
        return kept
    }
}

// MARK: - Transitions (dedupe by state change)

/// Last observed values, rebuilt by replaying the history; a value that does not change produces no entry.
struct HistoryState: Sendable, Equatable {
    var overall: String?
    var publicIP: String?
    var identity: String?
    var name: String?
    var model: String?
    /// Banned servers and their ban status (`ipBanned` / `cidBanned`).
    var bans: [UUID: String] = [:]
    /// Last release reported by `appUpdateAvailable`.
    var updateVersion: String?

    init() {}

    init(replaying entries: [HistoryEntry]) {
        for entry in entries { apply(entry) }
    }

    mutating func apply(_ entry: HistoryEntry) {
        switch entry.kind {
        case .refresh: overall = entry.new
        case .ipChanged: publicIP = entry.new
        case .identityChanged: identity = entry.new
        case .nameChanged: name = entry.new
        case .modelChanged: model = entry.new
        case .banAppeared: if let id = entry.serverID { bans[id] = entry.new }
        case .banLifted: if let id = entry.serverID { bans[id] = nil }
        case .appUpdateAvailable: updateVersion = entry.new
        case .apply, .fixAttempt, .appeal, .note: break
        }
    }
}

/// What a full refresh observed. `nil` = unknown this time (e.g. public IP unavailable) → no entry.
struct HistoryObservation: Sendable, Equatable {
    struct Server: Sendable, Equatable {
        let id: UUID
        let host: String
        let ban: BanStatus?
    }

    var ts: Date
    var overall: StatusLevel?
    var publicIP: String?
    var identity: String?
    var name: String?
    var model: String?
    var servers: [Server] = []
}

enum HistoryTransitions {
    /// Entries for the values that changed since `state`. A first observation has `old == nil`.
    static func entries(from state: HistoryState, observing observation: HistoryObservation) -> [HistoryEntry] {
        var result: [HistoryEntry] = []
        let ts = observation.ts
        func change(_ kind: HistoryKind, _ old: String?, _ new: String?) {
            guard let new, new != old else { return }
            result.append(HistoryEntry(ts: ts, kind: kind, old: old, new: new))
        }
        change(.refresh, state.overall, observation.overall.map(levelName))
        change(.ipChanged, state.publicIP, observation.publicIP)
        change(.identityChanged, state.identity, observation.identity)
        change(.nameChanged, state.name, observation.name)
        change(.modelChanged, state.model, observation.model)
        for server in observation.servers {
            let previous = state.bans[server.id]
            switch server.ban {
            case .ipBanned?, .cidBanned?:
                let status = server.ban?.rawValue
                if status != previous {
                    result.append(HistoryEntry(ts: ts, kind: .banAppeared, serverID: server.id, host: server.host,
                                               old: previous, new: status))
                }
            case .ipOk?, .cidOk?, .cidNotApplicable?:
                if let previous {
                    result.append(HistoryEntry(ts: ts, kind: .banLifted, serverID: server.id, host: server.host,
                                               old: previous, new: server.ban?.rawValue))
                }
            case .unreachable?, .unknown?, .cidUnknown?, nil:
                break   // undetermined: neither appeared nor lifted
            }
        }
        return result
    }

    static func levelName(_ level: StatusLevel) -> String {
        switch level {
        case .green: return "green"
        case .orange: return "orange"
        case .red: return "red"
        }
    }
}

// MARK: - Filter and export (pure)

struct HistoryFilter: Sendable, Equatable {
    var serverID: UUID?
    /// `nil` = every kind.
    var kinds: Set<HistoryKind>?

    init(serverID: UUID? = nil, kinds: Set<HistoryKind>? = nil) {
        self.serverID = serverID
        self.kinds = kinds
    }

    /// Matching entries, newest first (stable for equal timestamps: later lines first).
    func apply(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.enumerated()
            .filter { _, entry in
                (serverID == nil || entry.serverID == serverID) && (kinds?.contains(entry.kind) ?? true)
            }
            .sorted { $0.element.ts != $1.element.ts ? $0.element.ts > $1.element.ts : $0.offset > $1.offset }
            .map(\.element)
    }
}

enum HistoryExport {
    /// Pretty-printed JSON array with the `history.jsonl` field names.
    static func json(_ entries: [HistoryEntry]) -> String {
        guard let data = try? HistoryCoding.makeEncoder(pretty: true).encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Markdown table; the columns are the `history.jsonl` field names.
    static func markdown(_ entries: [HistoryEntry]) -> String {
        let columns = ["ts", "kind", "serverID", "host", "old", "new", "note"]
        let formatter = ISO8601DateFormatter()
        var lines = ["| " + columns.joined(separator: " | ") + " |",
                     "|" + String(repeating: "---|", count: columns.count)]
        for entry in entries {
            let cells = [formatter.string(from: entry.ts), entry.kind.rawValue, entry.serverID?.uuidString,
                         entry.host, entry.old, entry.new, entry.note].map { cell($0 ?? "") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Recorder

/// Writes history entries in order. The state is rebuilt from the file on first use; retention runs then and
/// whenever the file grows past the entry limit.
actor HistoryRecorder {
    private let store: HistoryStore
    private let now: @Sendable () -> Date
    private var state: HistoryState?
    private var count = 0

    init(store: HistoryStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    /// Records the transitions of a refresh. Returns the entries written.
    @discardableResult
    func observe(_ observation: HistoryObservation) -> [HistoryEntry] {
        var current = loadState()
        let entries = HistoryTransitions.entries(from: current, observing: observation)
        guard write(entries) else { return [] }
        for entry in entries { current.apply(entry) }
        state = current
        return entries
    }

    /// Records a single event (`apply`, `fixAttempt`, `appUpdateAvailable`, `appeal`).
    @discardableResult
    func record(_ entry: HistoryEntry) -> Bool {
        var current = loadState()
        guard write([entry]) else { return false }
        current.apply(entry)
        state = current
        return true
    }

    /// Records `appUpdateAvailable` once per release version.
    @discardableResult
    func recordUpdate(version: String) -> HistoryEntry? {
        let current = loadState()
        guard current.updateVersion != version else { return nil }
        let entry = HistoryEntry(ts: now(), kind: .appUpdateAvailable, old: current.updateVersion, new: version)
        return record(entry) ? entry : nil
    }

    private func loadState() -> HistoryState {
        if let state { return state }
        let kept = (try? store.compact(now: now())) ?? store.load()
        let loaded = HistoryState(replaying: kept)
        state = loaded
        count = kept.count
        return loaded
    }

    private func write(_ entries: [HistoryEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        do {
            try store.append(entries)
        } catch {
            return false
        }
        count += entries.count
        if count > HistoryRetention.maxEntries, let kept = try? store.compact(now: now()) {
            count = kept.count
        }
        return true
    }
}

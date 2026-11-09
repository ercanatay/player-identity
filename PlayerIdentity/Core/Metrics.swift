import Foundation

// MARK: - §39 Ping / uptime history

/// One line of `metrics.jsonl`: `{ts, serverID, host, online, ping?, players?, maxPlayers?, map?}`.
struct MetricSample: Codable, Sendable, Equatable {
    var ts: Date
    var serverID: UUID
    var host: String
    var online: Bool
    var ping: Int?
    var players: Int?
    var maxPlayers: Int?
    var map: String?

    init(ts: Date, serverID: UUID, host: String, online: Bool, ping: Int? = nil, players: Int? = nil,
         maxPlayers: Int? = nil, map: String? = nil) {
        self.ts = ts
        self.serverID = serverID
        self.host = host
        self.online = online
        self.ping = ping
        self.players = players
        self.maxPlayers = maxPlayers
        self.map = map
    }

    /// Sample of a finished ban check: online unless the server did not answer at all.
    init(check: BanCheck, serverID: UUID, host: String) {
        self.init(ts: check.checkedAt, serverID: serverID, host: host, online: check.status != .unreachable,
                  ping: check.info?.pingMillis, players: check.info?.players, maxPlayers: check.info?.maxPlayers,
                  map: check.info?.map)
    }
}

enum MetricsRetention {
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    static let maxSamplesPerServer = 5000

    /// Drops samples older than 30 days, then keeps the newest 5000 per server (file order kept).
    static func apply(_ samples: [MetricSample], now: Date) -> [MetricSample] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let recent = samples.filter { $0.ts >= cutoff }
        var counts: [UUID: Int] = [:]
        var keep = [Bool](repeating: false, count: recent.count)
        for index in recent.indices.reversed() {
            let id = recent[index].serverID
            let count = counts[id, default: 0]
            if count < maxSamplesPerServer {
                keep[index] = true
                counts[id] = count + 1
            }
        }
        return recent.indices.filter { keep[$0] }.map { recent[$0] }
    }
}

/// `metrics.jsonl`: one JSON object per line, appended; unreadable lines are skipped; compaction rewrites atomically.
struct MetricsStore: Sendable {
    let fileURL: URL

    func load() -> [MetricSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return Self.decodeLines(data)
    }

    static func decodeLines(_ data: Data) -> [MetricSample] {
        let decoder = HistoryCoding.makeDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(MetricSample.self, from: Data($0)) }
    }

    static func encodeLine(_ sample: MetricSample) throws -> Data {
        var data = try HistoryCoding.makeEncoder().encode(sample)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    func append(_ samples: [MetricSample]) throws {
        guard !samples.isEmpty else { return }
        var payload = Data()
        for sample in samples { payload.append(try Self.encodeLine(sample)) }
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
            // A cut-short previous write must not swallow this line.
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) { payload.insert(UInt8(ascii: "\n"), at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: payload)
    }

    /// Applies retention and drops corrupt lines; rewrites only if something changed. Returns the samples kept.
    @discardableResult
    func compact(now: Date) throws -> [MetricSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let samples = Self.decodeLines(data)
        let kept = MetricsRetention.apply(samples, now: now)
        guard kept.count != data.split(separator: UInt8(ascii: "\n")).count else { return kept }
        var payload = Data()
        for sample in kept { payload.append(try Self.encodeLine(sample)) }
        try payload.write(to: fileURL, options: .atomic)
        return kept
    }
}

/// Writes samples in order; compacts on first use and when a server passes its 5000-sample limit.
actor MetricsRecorder {
    private let store: MetricsStore
    private let now: @Sendable () -> Date
    private var counts: [UUID: Int]?

    init(store: MetricsStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    func record(_ samples: [MetricSample]) {
        guard !samples.isEmpty else { return }
        var current = counts ?? Self.counts(of: (try? store.compact(now: now())) ?? store.load())
        guard (try? store.append(samples)) != nil else {
            counts = current
            return
        }
        for sample in samples { current[sample.serverID, default: 0] += 1 }
        if current.values.contains(where: { $0 > MetricsRetention.maxSamplesPerServer }),
           let kept = try? store.compact(now: now()) {
            current = Self.counts(of: kept)
        }
        counts = current
    }

    private static func counts(of samples: [MetricSample]) -> [UUID: Int] {
        samples.reduce(into: [:]) { $0[$1.serverID, default: 0] += 1 }
    }
}

/// One point of a chart series.
struct MetricPoint: Sendable, Equatable {
    let ts: Date
    let online: Bool
    let ping: Int?
    let players: Int?
}

enum MetricsAnalysis {
    static let dayWindow: TimeInterval = 24 * 60 * 60

    /// Samples of one server in `[now - window, now]`, oldest first.
    static func samples(_ samples: [MetricSample], serverID: UUID, now: Date,
                        window: TimeInterval = dayWindow) -> [MetricSample] {
        let start = now.addingTimeInterval(-window)
        return samples.filter { $0.serverID == serverID && $0.ts >= start && $0.ts <= now }.sorted { $0.ts < $1.ts }
    }

    /// Uptime = online / total in the window (0…1); `nil` without samples.
    static func uptime(_ samples: [MetricSample], serverID: UUID, now: Date, window: TimeInterval = dayWindow) -> Double? {
        let inWindow = self.samples(samples, serverID: serverID, now: now, window: window)
        guard !inWindow.isEmpty else { return nil }
        return Double(inWindow.filter(\.online).count) / Double(inWindow.count)
    }

    /// Chart series of the last 24 hours (ping only for online samples).
    static func series(_ samples: [MetricSample], serverID: UUID, now: Date,
                       window: TimeInterval = dayWindow) -> [MetricPoint] {
        self.samples(samples, serverID: serverID, now: now, window: window).map {
            MetricPoint(ts: $0.ts, online: $0.online, ping: $0.online ? $0.ping : nil, players: $0.players)
        }
    }
}

enum MetricsExport {
    static let columns = ["ts", "serverID", "host", "online", "ping", "players", "maxPlayers", "map"]

    /// Pretty-printed JSON array with the `metrics.jsonl` field names.
    static func json(_ samples: [MetricSample]) -> String {
        guard let data = try? HistoryCoding.makeEncoder(pretty: true).encode(samples) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// CSV (RFC 4180); the header row is the field names, empty cells for unknown values.
    static func csv(_ samples: [MetricSample]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = samples.map { sample in
            [formatter.string(from: sample.ts), sample.serverID.uuidString, sample.host, sample.online ? "true" : "false",
             sample.ping.map(String.init) ?? "", sample.players.map(String.init) ?? "",
             sample.maxPlayers.map(String.init) ?? "", sample.map ?? ""]
        }
        return CSV.encode([columns] + rows)
    }
}

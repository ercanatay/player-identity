import CryptoKit
import Foundation

// MARK: - §39 Ping / uptime history

/// One line of `metrics.jsonl`: `{ts, serverID, host, online, ping?, players?, maxPlayers?, map?, profileID?, profileName?}`.
struct MetricSample: Codable, Sendable, Equatable {
    var ts: Date
    var serverID: UUID
    var host: String
    var online: Bool
    var ping: Int?
    var players: Int?
    var maxPlayers: Int?
    var map: String?
    /// §61 profile the sample was taken for (name = snapshot at write time); absent in older lines.
    var profileID: UUID?
    var profileName: String?

    /// §61: the sample stamped with a profile (an existing stamp is kept).
    func tagged(_ tag: ProfileTag?) -> MetricSample {
        guard let tag, profileID == nil else { return self }
        var copy = self
        copy.profileID = tag.id
        copy.profileName = tag.name
        return copy
    }

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

    /// Stable id for a server that is not in the record (CLI checks): MD5 of `host:port` as a UUID.
    static func stableServerID(host: String, port: Int) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data("\(host):\(port)".utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30   // version 3 (name-based, MD5)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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

    /// Dedupe key: one sample per server and second (the app, the fix flow and the CLI may check at once).
    static func dedupeKey(_ sample: MetricSample) -> String {
        "\(sample.serverID.uuidString)|\(Int(sample.ts.timeIntervalSince1970.rounded(.down)))"
    }

    /// Bytes read from the end of the file to find recent duplicates.
    static let dedupeTailBytes = 64 * 1024

    /// Appends the samples, skipping any whose server+second is already in the batch or at the end of the file.
    /// Returns the samples written.
    @discardableResult
    func append(_ samples: [MetricSample]) throws -> [MetricSample] {
        guard !samples.isEmpty else { return [] }
        var seen = Set(recentTail().map(Self.dedupeKey))
        let fresh = samples.filter { seen.insert(Self.dedupeKey($0)).inserted }
        guard !fresh.isEmpty else { return [] }
        try write(fresh)
        return fresh
    }

    /// Samples in the last 64 KB of the file (a partial first line is skipped as corrupt).
    private func recentTail() -> [MetricSample] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(Self.dedupeTailBytes) ? size - UInt64(Self.dedupeTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        return Self.decodeLines(data)
    }

    private func write(_ samples: [MetricSample]) throws {
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

    /// Consecutive failed writes: since when, and how many (`nil` after a successful write).
    struct WriteFailure: Sendable, Equatable {
        var since: Date
        var count: Int
        var reason: String
    }

    private(set) var writeFailure: WriteFailure?

    /// Appends the samples; returns the write failure state afterwards (`nil` when this write worked).
    @discardableResult
    func record(_ samples: [MetricSample]) -> WriteFailure? {
        guard !samples.isEmpty else { return writeFailure }
        var current = counts ?? Self.counts(of: (try? store.compact(now: now())) ?? store.load())
        let written: [MetricSample]
        do {
            written = try store.append(samples)
        } catch {
            counts = current
            var failure = writeFailure ?? WriteFailure(since: now(), count: 0, reason: "")
            failure.count += 1
            failure.reason = error.localizedDescription
            writeFailure = failure
            return failure
        }
        writeFailure = nil
        for sample in written { current[sample.serverID, default: 0] += 1 }
        if current.values.contains(where: { $0 > MetricsRetention.maxSamplesPerServer }),
           let kept = try? store.compact(now: now()) {
            current = Self.counts(of: kept)
        }
        counts = current
        return nil
    }

    /// Forgets the cached counts (after "Erase All Data" or a restore): the next write starts from the file again.
    func reset() {
        counts = nil
        writeFailure = nil
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

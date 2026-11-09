import Foundation

/// Server row (§5).
struct ServerEntry: Codable, Sendable, Equatable, Identifiable {
    static let defaultPort = 27015

    var id: UUID
    var label: String
    var host: String
    var port: Int
    /// Saved CID; empty when a new server is added.
    var cid: String
    var lastCheckedAt: Date?
    /// §13.4: optional; absent in old records (schema 1 backward compatible).
    var banCheck: BanCheck?
    /// §31: group name (`nil` = no group), favorite, user order. Absent in old records.
    var group: String?
    var favorite: Bool
    var order: Int
    /// §32: free-text note (at most 2000 characters) and appeal tracking. Absent in old records.
    var note: String
    var appeal: Appeal?
    /// §40: ban list URL template (`https`, with `{cid}`/`{ip}`/`{host}`/`{port}`); absent in old records.
    var banListURL: String?
    /// §42: notify about changes of this server (absent in old records → `false`).
    var watch: Bool

    init(id: UUID = UUID(), label: String, host: String, port: Int = ServerEntry.defaultPort,
         cid: String = "", lastCheckedAt: Date? = nil, banCheck: BanCheck? = nil,
         group: String? = nil, favorite: Bool = false, order: Int = 0, note: String = "", appeal: Appeal? = nil,
         banListURL: String? = nil, watch: Bool = false) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.cid = cid
        self.lastCheckedAt = lastCheckedAt
        self.banCheck = banCheck
        self.group = group
        self.favorite = favorite
        self.order = order
        self.note = note
        self.appeal = appeal
        self.banListURL = banListURL
        self.watch = watch
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, host, port, cid, lastCheckedAt, banCheck, group, favorite, order, note, appeal, banListURL, watch
    }

    /// Fields added after schema 1 are optional when decoding (old records stay readable).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        cid = try container.decode(String.self, forKey: .cid)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        banCheck = try container.decodeIfPresent(BanCheck.self, forKey: .banCheck)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        appeal = try container.decodeIfPresent(Appeal.self, forKey: .appeal)
        banListURL = try container.decodeIfPresent(String.self, forKey: .banListURL)
        watch = try container.decodeIfPresent(Bool.self, forKey: .watch) ?? false
    }
}

struct NetworkInfo: Codable, Sendable, Equatable {
    var publicIP: String
    var lanIPs: [String]
    var checkedAt: Date?
}

/// `profile.json` schema (§5).
struct Snapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Snapshot.currentSchemaVersion
    var savedAt: Date
    var gamedir: String
    var dataRoot: String
    var displayName: String
    var model: String
    var rawID: String
    var identitySource: String
    var network: NetworkInfo
    var servers: [ServerEntry]
}

enum SnapshotLoadResult: Sendable, Equatable {
    /// No file (first run).
    case missing
    /// File exists but is unreadable / JSON is corrupt.
    case corrupt
    /// `schemaVersion` is not supported.
    case unsupportedSchema(Int)
    case loaded(Snapshot)

    var snapshot: Snapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

/// Snapshot reading / atomic writing (§5). Writes only its own file.
struct SnapshotStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = AppPaths().snapshotFile) {
        self.fileURL = fileURL
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Never throws; a corrupt/missing file is returned as a state.
    func load() -> SnapshotLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .corrupt }
        return Self.decode(data)
    }

    static func decode(_ data: Data) -> SnapshotLoadResult {
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = makeDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { return .corrupt }
        guard header.schemaVersion == Snapshot.currentSchemaVersion else {
            return .unsupportedSchema(header.schemaVersion)
        }
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return .corrupt }
        return .loaded(snapshot)
    }

    /// Atomic write via a temporary file + `replaceItemAt`.
    func save(_ snapshot: Snapshot) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try Self.makeEncoder().encode(snapshot)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
                                                         isDirectory: false)
        try data.write(to: temporary)
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

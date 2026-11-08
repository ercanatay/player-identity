import Foundation

/// Sunucu satırı (§5).
struct ServerEntry: Codable, Sendable, Equatable, Identifiable {
    static let defaultPort = 27015

    var id: UUID
    var label: String
    var host: String
    var port: Int
    /// Kayıtlı CID; yeni sunucu eklenince boş.
    var cid: String
    var lastCheckedAt: Date?
    /// §13.4: opsiyonel; eski kayıtlarda yoktur (şema 1 geriye uyumlu).
    var banCheck: BanCheck?

    init(id: UUID = UUID(), label: String, host: String, port: Int = ServerEntry.defaultPort,
         cid: String = "", lastCheckedAt: Date? = nil, banCheck: BanCheck? = nil) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.cid = cid
        self.lastCheckedAt = lastCheckedAt
        self.banCheck = banCheck
    }
}

struct NetworkInfo: Codable, Sendable, Equatable {
    var publicIP: String
    var lanIPs: [String]
    var checkedAt: Date?
}

/// `profile.json` şeması (§5).
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
    /// Dosya yok (ilk çalıştırma).
    case missing
    /// Dosya var ama okunamıyor / JSON bozuk.
    case corrupt
    /// `schemaVersion` desteklenmiyor.
    case unsupportedSchema(Int)
    case loaded(Snapshot)

    var snapshot: Snapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

/// Snapshot okuma / atomik yazma (§5). Yalnızca kendi dosyasına yazar.
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

    /// Hiçbir koşulda hata fırlatmaz; bozuk/eksik dosya durum olarak döner.
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

    /// Geçici dosya + `replaceItemAt` ile atomik yazma.
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

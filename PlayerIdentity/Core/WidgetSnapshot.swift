import Foundation

// MARK: - §69.2 Widget snapshot (shared by the app and the widget extension)
//
// This file is compiled into the app, the CLI and `PlayerIdentityWidget`; it depends on Foundation and `L10nKey` only.

/// Overall status shown by the small widget.
enum WidgetStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case green
    case orange
    case red
    /// Not checked yet.
    case unknown

    var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .orange: return "exclamationmark.triangle.fill"
        case .red: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var textKey: L10nKey {
        switch self {
        case .green: return .statusGreenTitle
        case .orange: return .statusOrangeTitle
        case .red: return .statusRedTitle
        case .unknown: return .topbarNotChecked
        }
    }
}

/// `widget-snapshot.json`: what the widget shows. Never holds an IP of the player, only a shortened CID.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    /// The medium widget shows the first three servers; the file holds no more.
    static let maxServers = 3

    struct Server: Codable, Sendable, Equatable {
        var label: String
        var host: String
        var port: Int
        /// `BanStatus` raw value of the last check; `nil` = not checked.
        var ban: String?
        /// Ping of the last check in ms.
        var ping: Int?

        /// Same groups as `BanStatus.level`: banned → red, no block → green, unknown/unreachable → orange.
        var banLevel: WidgetStatus {
            switch ban {
            case "ipBanned", "cidBanned": return .red
            case "cidOk", "cidNotApplicable": return .green
            case nil: return .unknown
            default: return .orange
            }
        }

        /// Same texts as `BanStatus.label`.
        var banTextKey: L10nKey {
            switch ban {
            case "ipBanned": return .banStatusIPBanned
            case "cidBanned": return .banStatusCIDBanned
            case "cidOk", "cidNotApplicable": return .banStatusNoBlock
            case "unreachable": return .banStatusUnreachable
            case nil: return .topbarNotChecked
            default: return .banStatusUnknown
            }
        }
    }

    var schemaVersion: Int = WidgetSnapshot.currentSchemaVersion
    var updatedAt: Date
    var status: WidgetStatus
    var cidShort: String?
    var servers: [Server]

    init(updatedAt: Date, status: WidgetStatus, cidShort: String?, servers: [Server]) {
        self.updatedAt = updatedAt
        self.status = status
        self.cidShort = cidShort
        self.servers = Array(servers.prefix(Self.maxServers))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, status, cidShort, servers
    }

    /// An unknown status value reads as `unknown` (a newer app never breaks an older widget).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        status = (try? container.decode(String.self, forKey: .status)).flatMap(WidgetStatus.init(rawValue:)) ?? .unknown
        cidShort = try container.decodeIfPresent(String.self, forKey: .cidShort)
        servers = Array(try container.decode([Server].self, forKey: .servers).prefix(Self.maxServers))
    }

    /// `9f3a1c7e…d7b8` (the first 8 and the last 4 characters); short CIDs stay as they are.
    static func shortCID(_ cid: String) -> String {
        let trimmed = cid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        return String(trimmed.prefix(8)) + "\u{2026}" + String(trimmed.suffix(4))
    }
}

enum WidgetSnapshotLoad: Sendable, Equatable {
    case missing
    case corrupt
    case loaded(WidgetSnapshot)

    var snapshot: WidgetSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

/// Reading and writing `widget-snapshot.json`. The app writes it; the widget only reads it.
enum WidgetSnapshotStore {
    static let folderName = "tr.ercanatay.playeridentity"
    static let fileName = "widget-snapshot.json"

    /// `<home>/Library/Application Support/tr.ercanatay.playeridentity/widget-snapshot.json`.
    static func fileURL(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    /// `nil` for broken JSON or another schema version.
    static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.schemaVersion == WidgetSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    static func load(from url: URL) -> WidgetSnapshotLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let snapshot = decode(data) else { return .corrupt }
        return .loaded(snapshot)
    }

    /// Atomic write (the widget never sees half a file).
    static func save(_ snapshot: WidgetSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(snapshot).write(to: url, options: .atomic)
    }
}

/// The widget's timeline: one entry now, the next reload 15 minutes later (`.after`).
enum WidgetTimeline {
    static let refreshInterval: TimeInterval = 15 * 60
    /// Tapping the widget opens (or brings up) the main window.
    static let deepLink = URL(string: "playeridentity://show")!

    struct Plan: Sendable, Equatable {
        var date: Date
        /// `nil` = no usable data: the widget asks to open the app.
        var snapshot: WidgetSnapshot?
        var reloadAt: Date
    }

    static func plan(_ load: WidgetSnapshotLoad, now: Date) -> Plan {
        Plan(date: now, snapshot: load.snapshot, reloadAt: now.addingTimeInterval(refreshInterval))
    }
}

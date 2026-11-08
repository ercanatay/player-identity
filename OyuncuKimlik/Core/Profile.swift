import Foundation

/// §6 adım 1–2 sonucu: gamedir keşfi + kimlik + config.
struct LocalProfile: Sendable, Equatable {
    var gamedirs: [String]
    var selectedGamedir: String?
    var identity: Result<Identity, IdentityError>
    var config: PlayerConfig
}

/// Veri kökü ve seçili gamedir'i doğrulayıp kimlik ve config'i okur. Salt okunur.
struct ProfileLoader: Sendable {
    let fileSystem: any FileSystemReading
    let homeDirectory: URL

    /// `preferredGamedir` keşfedilen listede yoksa varsayılan seçim (§3.4) kullanılır.
    func load(dataRoot: URL, preferredGamedir: String?) -> LocalProfile {
        let gamedirs = GamedirDiscovery(fileSystem: fileSystem).discover(dataRoot: dataRoot)
        let selected: String?
        if let preferredGamedir, gamedirs.contains(preferredGamedir) {
            selected = preferredGamedir
        } else {
            selected = GamedirDiscovery.defaultSelection(from: gamedirs)
        }
        let gamedirURL = selected.map { dataRoot.appendingPathComponent($0, isDirectory: true) }
        let identity = IdentityReader(fileSystem: fileSystem, homeDirectory: homeDirectory).read(gamedir: gamedirURL)
        let config = gamedirURL.map { ConfigReader(fileSystem: fileSystem).read(gamedir: $0) } ?? PlayerConfig()
        return LocalProfile(gamedirs: gamedirs, selectedGamedir: selected, identity: identity, config: config)
    }
}

/// Kullanıcının düzenleyebildiği alanlar; "Kaydedilmedi" rozeti bunların kayıttan farkına bakar (§5).
struct EditableState: Sendable, Equatable {
    struct Server: Sendable, Equatable {
        let id: UUID
        let label: String
        let host: String
        let port: Int
    }

    let dataRoot: String
    let gamedir: String
    let servers: [Server]

    init(dataRoot: String, gamedir: String?, servers: [ServerEntry]) {
        self.dataRoot = URL(fileURLWithPath: dataRoot, isDirectory: true).standardizedFileURL.path
        self.gamedir = gamedir ?? ""
        self.servers = servers.map { Server(id: $0.id, label: $0.label, host: $0.host, port: $0.port) }
    }

    init(snapshot: Snapshot) {
        self.init(dataRoot: snapshot.dataRoot, gamedir: snapshot.gamedir, servers: snapshot.servers)
    }
}

/// "Kaydet" anındaki verilerden snapshot üretir (§5).
enum SnapshotBuilder {
    /// Sunucu CID'si yalnızca satır bir yenilemede kontrol edildiyse (`lastCheckedAt != nil`) yazılır;
    /// yeni eklenen (henüz kontrol edilmemiş) sunucunun `cid` alanı boş kaydedilir.
    static func make(savedAt: Date,
                     dataRoot: URL,
                     gamedir: String?,
                     config: PlayerConfig,
                     identity: Result<Identity, IdentityError>?,
                     publicIP: String?,
                     lanIPs: [String],
                     checkedAt: Date?,
                     servers: [ServerEntry]) -> Snapshot {
        let identityValue = try? identity?.get()
        let savedServers = servers.map { entry -> ServerEntry in
            var copy = entry
            if entry.lastCheckedAt != nil, let rawID = identityValue?.rawID {
                copy.cid = CIDCalculator.cid(rawID: rawID, host: entry.host) ?? ""
            } else {
                copy.cid = ""
            }
            return copy
        }
        return Snapshot(savedAt: savedAt,
                        gamedir: gamedir ?? "",
                        dataRoot: dataRoot.standardizedFileURL.path,
                        displayName: config.name,
                        model: config.model,
                        rawID: identityValue?.rawIDHex ?? "",
                        identitySource: identityValue?.source.url.path ?? "",
                        network: NetworkInfo(publicIP: publicIP ?? "", lanIPs: lanIPs, checkedAt: checkedAt),
                        servers: savedServers)
    }
}

/// Sunucu ekleme/düzenleme formu doğrulaması (§8).
struct ServerDraft: Sendable, Equatable {
    enum Problem: Sendable, Equatable, CaseIterable {
        case labelEmpty
        case hostEmpty
        case portInvalid

        var text: String {
            switch self {
            case .labelEmpty: return "Etiket boş olamaz."
            case .hostEmpty: return "Host boş olamaz."
            case .portInvalid: return "Port 1–65535 arasında bir sayı olmalı."
            }
        }
    }

    var label: String = ""
    var host: String = ""
    var portText: String = String(ServerEntry.defaultPort)

    init(label: String = "", host: String = "", portText: String = String(ServerEntry.defaultPort)) {
        self.label = label
        self.host = host
        self.portText = portText
    }

    init(entry: ServerEntry) {
        self.init(label: entry.label, host: entry.host, portText: String(entry.port))
    }

    var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    var port: Int? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    var problems: [Problem] {
        var list: [Problem] = []
        if trimmedLabel.isEmpty { list.append(.labelEmpty) }
        if trimmedHost.isEmpty { list.append(.hostEmpty) }
        if port == nil { list.append(.portInvalid) }
        return list
    }

    var isValid: Bool { problems.isEmpty }
}

/// Saat biçimi `HH:mm:ss` (§6, §8).
enum TimeText {
    static func format(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

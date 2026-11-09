import Foundation

/// Result of §6 steps 1–2: gamedir discovery + identity + config.
struct LocalProfile: Sendable, Equatable {
    var gamedirs: [String]
    var selectedGamedir: String?
    var identity: Result<Identity, IdentityError>
    var config: PlayerConfig
    /// §15.2 effective value sources.
    var configSources = ConfigSources()
    /// §15.3 model list; `nil` if the folder is unreadable.
    var models: [String]? = nil
}

/// Validates the data root and selected gamedir, then reads identity and config. Read-only.
struct ProfileLoader: Sendable {
    let fileSystem: any FileSystemReading
    let homeDirectory: URL

    /// If `preferredGamedir` is not in the discovered list, the default selection (§3.4) is used.
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
        let effective = gamedirURL.map { ConfigReader(fileSystem: fileSystem).readEffective(gamedir: $0) }
        let models = gamedirURL.flatMap { ModelCatalog.load(gamedir: $0, fileSystem: fileSystem) }
        return LocalProfile(gamedirs: gamedirs, selectedGamedir: selected, identity: identity,
                            config: effective?.config ?? PlayerConfig(),
                            configSources: effective?.sources ?? ConfigSources(),
                            models: models)
    }
}

/// User-editable fields; the "unsaved" badge compares these against the record (§5).
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

/// Builds a snapshot from the data at the moment of "Save" (§5).
enum SnapshotBuilder {
    /// A server CID is written only if the row was checked during a refresh (`lastCheckedAt != nil`);
    /// a newly added (not yet checked) server is saved with an empty `cid`.
    static func make(savedAt: Date,
                     dataRoot: URL,
                     gamedir: String?,
                     config: PlayerConfig,
                     identity: Result<Identity, IdentityError>?,
                     publicIP: String?,
                     lanIPs: [String],
                     checkedAt: Date?,
                     servers: [ServerEntry],
                     resolutions: [String: HostResolution] = [:]) -> Snapshot {
        let identityValue = try? identity?.get()
        let savedServers = servers.map { entry -> ServerEntry in
            var copy = entry
            if entry.lastCheckedAt != nil, let rawID = identityValue?.rawID {
                copy.cid = HostAddressing.address(for: entry.host, in: resolutions)
                    .map { CIDCalculator.cid(rawID: rawID, address: $0) } ?? ""
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

/// Validation of the add/edit server form (§8).
struct ServerDraft: Sendable, Equatable {
    enum Problem: Sendable, Equatable, CaseIterable {
        case labelEmpty
        case hostEmpty
        /// §20: neither an IP literal nor an RFC 1123 hostname.
        case hostInvalid
        case portInvalid

        var text: String {
            switch self {
            case .labelEmpty: return L10n.text(.serverProblemLabelEmpty)
            case .hostEmpty: return L10n.text(.serverProblemHostEmpty)
            case .hostInvalid: return L10n.text(.errorInvalidHost)
            case .portInvalid: return L10n.text(.serverProblemPortInvalid)
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
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), HostValidator.isValidPort(value) else {
            return nil
        }
        return value
    }

    var problems: [Problem] {
        var list: [Problem] = []
        if trimmedLabel.isEmpty { list.append(.labelEmpty) }
        if trimmedHost.isEmpty {
            list.append(.hostEmpty)
        } else if HostValidator.classify(trimmedHost) == nil {
            list.append(.hostInvalid)
        }
        if port == nil { list.append(.portInvalid) }
        return list
    }

    var isValid: Bool { problems.isEmpty }
}

/// Time format `HH:mm:ss` (§6, §8).
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

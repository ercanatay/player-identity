import Foundation

// MARK: - §67.4 Spotlight indexing of the servers

/// One searchable server: title = label (or `host:port`), description = `host:port · CID` (CID shortened).
struct SpotlightServerItem: Sendable, Equatable {
    /// The server's UUID string (Spotlight `uniqueIdentifier`; the opened activity carries it back).
    let identifier: String
    let title: String
    let summary: String
}

/// The Spotlight index; the app uses CoreSpotlight, tests a fake. Every call throws its failure.
protocol SpotlightIndexing: Sendable {
    func index(_ items: [SpotlightServerItem]) async throws
    func delete(identifiers: [String]) async throws
    func deleteAll() async throws
}

/// Default when nothing is injected (tests): indexes nothing.
struct NoopSpotlightIndexer: SpotlightIndexing {
    init() {}
    func index(_ items: [SpotlightServerItem]) async throws {}
    func delete(identifiers: [String]) async throws {}
    func deleteAll() async throws {}
}

enum SpotlightServers {
    /// `domainIdentifier` of every server item (one fixed domain, removed as a whole by "Erase All Data").
    static let domainIdentifier = "tr.ercanatay.playeridentity.servers"

    static func item(for entry: ServerEntry) -> SpotlightServerItem {
        let address = ServerAddressText.hostPort(host: entry.host, port: entry.port)
        let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = entry.cid.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpotlightServerItem(identifier: entry.id.uuidString, title: label.isEmpty ? address : label,
                                   summary: cid.isEmpty ? address : "\(address) · \(DiagnosisReport.maskCID(cid))")
    }

    /// What changed between the indexed items and the current servers: new or changed items to (re)index and the
    /// identifiers of removed servers. Unchanged servers cause no call.
    static func changes(indexed: [String: SpotlightServerItem],
                        servers: [ServerEntry]) -> (upsert: [SpotlightServerItem], remove: [String]) {
        let current = servers.map(item(for:))
        let ids = Set(current.map(\.identifier))
        let upsert = current.filter { indexed[$0.identifier] != $0 }
        let remove = indexed.keys.filter { !ids.contains($0) }.sorted()
        return (upsert, remove)
    }

    /// The server a Spotlight result opens; `nil` for an unknown or malformed identifier.
    static func serverID(identifier: String?, servers: [ServerEntry]) -> UUID? {
        guard let identifier, let id = UUID(uuidString: identifier), servers.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }
}

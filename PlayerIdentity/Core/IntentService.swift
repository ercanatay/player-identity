import Foundation

// MARK: - §41 App Intents core (check ban, show CID, refresh)

enum IntentFailure: Error, Sendable, Equatable {
    /// No saved record (`profile.json` missing, corrupt or from a newer version).
    case noRecord
    case noServers
    case serverNotFound(String)
    /// More than one server matches; the labels are listed.
    case ambiguous([String])
    /// No identity file: the CID cannot be computed.
    case identityMissing
    case resolution(ResolutionError)
}

/// Finds the server an intent refers to: by id, label (case/diacritic-insensitive), `host[:port]`, or a unique
/// label prefix; with no query the only server is used.
enum IntentServerResolution {
    static func resolve(_ query: String?, in servers: [ServerEntry]) -> Result<ServerEntry, IntentFailure> {
        guard !servers.isEmpty else { return .failure(.noServers) }
        let text = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return servers.count == 1 ? .success(servers[0]) : .failure(.ambiguous(servers.map(\.label)))
        }
        if let id = UUID(uuidString: text), let match = servers.first(where: { $0.id == id }) { return .success(match) }

        func same(_ a: String, _ b: String) -> Bool {
            a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let byLabel = servers.filter { same($0.label, text) }
        if let only = unique(byLabel) { return only }

        if let target = HostPortQuery.parse(text) {
            let byAddress = servers.filter {
                HostValidator.normalized($0.host) == target.host && (target.port == nil || $0.port == target.port)
            }
            if let only = unique(byAddress) { return only }
        }

        let byPrefix = servers.filter {
            $0.label.range(of: text, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }
        if let only = unique(byPrefix) { return only }
        return .failure(.serverNotFound(text))
    }

    private static func unique(_ matches: [ServerEntry]) -> Result<ServerEntry, IntentFailure>? {
        switch matches.count {
        case 0: return nil
        case 1: return .success(matches[0])
        default: return .failure(.ambiguous(matches.map(\.label)))
        }
    }
}

/// `host`, `host:port`, `[ipv6]:port` or a bare IPv6 address; the port is optional.
enum HostPortQuery {
    static func parse(_ text: String) -> (host: String, port: Int?)? {
        var host = text
        var port: Int?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            port = Int(text[text.index(after: colon)...])
            if port == nil { return nil }
        }
        guard HostValidator.classify(host) != nil else { return nil }
        return (HostValidator.normalized(host), port)
    }
}

/// What the intents need, without the app model: the saved record, the identity files, DNS and UDP.
struct IntentService: Sendable {
    let paths: AppPaths
    let fileSystem: any FileSystemReading
    let resolver: any ServerAddressResolver
    let udpTransport: any UDPTransport
    let now: @Sendable () -> Date

    static func live() -> IntentService {
        IntentService(paths: AppPaths(), fileSystem: LocalFileSystem(), resolver: SystemAddressResolver(),
                      udpTransport: BSDUDPTransport(), now: { Date() })
    }

    func snapshot() -> Snapshot? {
        SnapshotStore(fileURL: paths.snapshotFile).load().snapshot
    }

    /// Saved servers in display order (§31).
    func servers() -> Result<[ServerEntry], IntentFailure> {
        guard let snapshot = snapshot() else { return .failure(.noRecord) }
        return .success(ServerOrganization.sections(snapshot.servers).flatMap(\.servers))
    }

    func server(_ query: String?) -> Result<ServerEntry, IntentFailure> {
        servers().flatMap { IntentServerResolution.resolve(query, in: $0) }
    }

    /// Raw identity from the identity files (home locations, then the saved gamedir).
    func rawID() -> UInt64? {
        var gamedir: URL?
        if let snapshot = snapshot(), !snapshot.gamedir.isEmpty, !snapshot.dataRoot.isEmpty {
            gamedir = URL(fileURLWithPath: snapshot.dataRoot, isDirectory: true).appendingPathComponent(snapshot.gamedir)
        }
        return try? IdentityReader(fileSystem: fileSystem, homeDirectory: paths.home).read(gamedir: gamedir).get().rawID
    }

    func address(for host: String) async -> Result<ServerAddress, IntentFailure> {
        switch HostValidator.classify(host) {
        case .address(let address)?: return .success(address)
        case nil: return .failure(.resolution(.invalidHostname))
        case .hostname(let name)?:
            do {
                guard let address = AddressPreference.pick(try await resolver.addresses(for: name)) else {
                    return .failure(.resolution(.notFound))
                }
                return .success(address)
            } catch let error as ResolutionError {
                return .failure(.resolution(error))
            } catch {
                return .failure(.resolution(.network))
            }
        }
    }

    /// "CID'imi göster": the CID for the server's address.
    func cid(for entry: ServerEntry) async -> Result<String, IntentFailure> {
        guard let rawID = rawID() else { return .failure(.identityMissing) }
        return await address(for: entry.host).map { CIDCalculator.cid(rawID: rawID, address: $0) }
    }

    /// "Sunucu banını kontrol et": one live check (same steps and limits as the app; CID step if an identity exists).
    func checkBan(_ entry: ServerEntry) async -> Result<BanCheck, IntentFailure> {
        let address: ServerAddress
        switch await self.address(for: entry.host) {
        case .success(let value): address = value
        case .failure(let error): return .failure(error)
        }
        guard HostValidator.isValidPort(entry.port) else { return .failure(.resolution(.invalidHostname)) }
        let name = snapshot()?.displayName ?? ""
        let request = BanCheckRequest(serverID: entry.id, host: entry.host, port: entry.port,
                                      endpoint: UDPEndpoint(address: address, port: UInt16(entry.port)),
                                      cid: rawID().map { CIDCalculator.cid(rawID: $0, address: address) }, name: name)
        let checker = BanChecker(transport: udpTransport, now: now)
        guard let check = try? await checker.check(request) else { return .failure(.resolution(.network)) }
        return .success(check)
    }
}

import Foundation
import Observation

/// §70 "Find Servers" window state: master list → A2S_INFO replies (live), filter, row refresh; the last finished
/// scan is reused for 5 minutes (memory only). Nothing here is written except the master's address cache.
@MainActor
@Observable
final class ServerBrowserController {
    enum Phase: Equatable {
        case idle
        /// Asking the master; addresses so far.
        case master(addresses: Int)
        /// A2S_INFO: finished / answered / all addresses.
        case servers(asked: Int, answered: Int, total: Int)
        case finished
        case failed(MasterQueryError)
        case cancelled
    }

    private(set) var phase = Phase.idle
    /// Servers that answered (grows while the scan runs; kept after a cancel).
    private(set) var servers: [BrowserServer] = []
    /// The last finished scan (`nil` while running, after a cancel or an error).
    private(set) var scan: BrowserScan?
    var filter = BrowserFilter()
    /// Rows whose "Refresh" is running.
    private(set) var refreshing: Set<BrowserAddress> = []
    /// Result of the last row refresh that dropped a server.
    private(set) var rowMessage: String?

    @ObservationIgnored private var memory = BrowserMemoryCache()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private let scanner: ServerBrowserScanner
    @ObservationIgnored private let now: @Sendable () -> Date

    init(scanner: ServerBrowserScanner) {
        self.scanner = scanner
        now = scanner.now
    }

    convenience init(dependencies deps: AppDependencies) {
        var master = MasterServerQuery(transport: deps.udpTransport, resolver: deps.resolver, now: deps.now)
        master.host = deps.masterServerHost
        master.port = deps.masterServerPort
        self.init(scanner: ServerBrowserScanner(master: master,
                                                collector: BrowserInfoCollector(transport: deps.udpTransport, now: deps.now),
                                                cache: MasterCacheStore(fileURL: deps.paths.masterCacheFile),
                                                now: deps.now))
    }

    var isRunning: Bool {
        switch phase {
        case .master, .servers: return true
        default: return false
        }
    }

    /// The filtered, sorted rows (at most `BrowserFilter.displayLimit`).
    var listing: BrowserListing { filter.apply(servers) }

    /// Starts a scan. Without `force`, a scan finished less than 5 minutes ago is shown again (no network). A running
    /// scan is cancelled first.
    @discardableResult
    func start(force: Bool = false) -> Task<Void, Never>? {
        if !force, !isRunning, let cached = memory.fresh(now: now()) {
            scan = cached
            servers = cached.servers
            phase = .finished
            return nil
        }
        task?.cancel()
        let current = UUID()
        token = current
        phase = .master(addresses: 0)
        servers = []
        scan = nil
        rowMessage = nil
        let scanner = scanner
        let task = Task {
            do {
                let result = try await scanner.scan { progress in
                    await self.apply(progress, token: current)
                }
                guard token == current else { return }
                scan = result
                servers = result.servers
                memory.store(result)
                phase = .finished
            } catch let error as MasterQueryError {
                guard token == current else { return }
                phase = .failed(error)
            } catch {
                guard token == current else { return }
                phase = .cancelled
            }
        }
        self.task = task
        return task
    }

    /// Stops the running scan; the servers that already answered stay listed (not cached).
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        token = UUID()
        phase = .cancelled
    }

    func clearFilter() {
        filter = BrowserFilter(sort: filter.sort)
    }

    /// "Refresh" of one row: a new A2S_INFO; a server that no longer answers is removed.
    @discardableResult
    func refreshRow(_ address: BrowserAddress) -> Task<Void, Never>? {
        guard !refreshing.contains(address) else { return nil }
        refreshing.insert(address)
        let collector = scanner.collector
        let deadline = now().addingTimeInterval(collector.perServer)
        return Task {
            defer { refreshing.remove(address) }
            let reply: BrowserServer?
            do {
                reply = try await collector.query(address, until: deadline)
            } catch {
                return
            }
            if let reply, let index = servers.firstIndex(where: { $0.address == address }) {
                servers[index] = reply
                rowMessage = nil
            } else if reply == nil {
                servers.removeAll { $0.address == address }
                rowMessage = L10n.format(.serverBrowserRowGone, address.id)
            }
            if scan != nil {
                scan?.servers = servers
                memory.update(address, with: reply)
            }
        }
    }

    private func apply(_ progress: BrowserProgress, token current: UUID) {
        guard token == current else { return }
        switch progress {
        case .master(let count):
            phase = .master(addresses: count)
        case .servers(let asked, let answered, let total, let server):
            if let server { servers.append(server) }
            phase = .servers(asked: asked, answered: answered, total: total)
        }
    }

    /// Test / evidence hook: shows a finished scan without the network.
    func show(_ result: BrowserScan) {
        task?.cancel()
        token = UUID()
        scan = result
        servers = result.servers
        phase = .finished
    }
}

// MARK: - Row actions (§70.3)

extension AppModel {
    /// The saved server with the same `host:port` (its host as typed, or the address it resolved to).
    func savedServerID(for target: BrowserAddress) -> UUID? {
        servers.first { entry in
            entry.port == Int(target.port)
                && (HostValidator.normalized(entry.host) == target.host || address(for: entry)?.text == target.host)
        }?.id
    }

    /// "Add": a new unsaved row (label = the server name); an existing `host:port` is never added twice. Returns the
    /// row's id.
    @discardableResult
    func addBrowserServer(_ server: BrowserServer) -> UUID? {
        if let id = savedServerID(for: server.address) { return id }
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        addServers([ServerURLImport.Candidate(host: server.address.host, port: Int(server.address.port))],
                   label: name.isEmpty ? nil : name)
        return savedServerID(for: server.address)
    }

    /// "Diagnose": the existing §64 diagnosis in the server details (the server is added first when it is not in
    /// the list, since the diagnosis belongs to a list row).
    @discardableResult
    func diagnoseBrowserServer(_ server: BrowserServer) -> Task<Void, Never>? {
        guard let id = addBrowserServer(server) else { return nil }
        let task = startDiagnosis(for: id)
        requestedServerDetail = id
        return task
    }
}

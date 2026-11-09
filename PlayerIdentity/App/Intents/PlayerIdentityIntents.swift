import AppIntents
import Foundation

// §41 App Intents / Shortcuts: "Check server ban", "Show my CID", "Refresh".
// Titles are localization keys; the texts are added with the UI part (Localizable.strings).

/// Where the intents read their data (the live record by default; tests replace it).
enum IntentEnvironment {
    nonisolated(unsafe) static var service: IntentService = .live()
}

/// A saved server as a Shortcuts parameter.
struct ServerEntity: AppEntity, Equatable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("intent.server.type"))
    static let defaultQuery = ServerEntityQuery()

    let id: UUID
    let label: String
    let address: String

    init(id: UUID, label: String, address: String) {
        self.id = id
        self.label = label
        self.address = address
    }

    init(entry: ServerEntry) {
        let host = entry.host.contains(":") ? "[\(entry.host)]" : entry.host
        self.init(id: entry.id, label: entry.label, address: "\(host):\(entry.port)")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(address)")
    }
}

struct ServerEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        let servers = (try? IntentEnvironment.service.servers().get()) ?? []
        return identifiers.compactMap { id in servers.first { $0.id == id }.map(ServerEntity.init(entry:)) }
    }

    func entities(matching string: String) async throws -> [ServerEntity] {
        let servers = (try? IntentEnvironment.service.servers().get()) ?? []
        switch IntentServerResolution.resolve(string, in: servers) {
        case .success(let entry): return [ServerEntity(entry: entry)]
        case .failure(.ambiguous(let labels)): return servers.filter { labels.contains($0.label) }.map(ServerEntity.init(entry:))
        case .failure: return []
        }
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        ((try? IntentEnvironment.service.servers().get()) ?? []).map(ServerEntity.init(entry:))
    }
}

/// Intent error; the message is a localization key.
struct IntentError: Error, CustomLocalizedStringResourceConvertible {
    let failure: IntentFailure

    var localizedStringResource: LocalizedStringResource {
        switch failure {
        case .noRecord: return LocalizedStringResource("intent.error.noRecord")
        case .noServers: return LocalizedStringResource("intent.error.noServers")
        case .serverNotFound: return LocalizedStringResource("intent.error.serverNotFound")
        case .ambiguous: return LocalizedStringResource("intent.error.ambiguous")
        case .identityMissing: return LocalizedStringResource("intent.error.identityMissing")
        case .resolution: return LocalizedStringResource("intent.error.resolution")
        }
    }
}

enum IntentRunner {
    /// Resolves the parameter against the current record (the server may have been edited or deleted).
    static func entry(for server: ServerEntity) throws -> ServerEntry {
        switch IntentEnvironment.service.server(server.id.uuidString) {
        case .success(let entry): return entry
        case .failure(let failure): throw IntentError(failure: failure)
        }
    }

    /// Value returned by "Check server ban": the ban status (`ipBanned`, `cidOk`, …).
    static func checkBan(_ server: ServerEntity) async throws -> String {
        let entry = try entry(for: server)
        switch await IntentEnvironment.service.checkBan(entry) {
        case .success(let check): return check.status.rawValue
        case .failure(let failure): throw IntentError(failure: failure)
        }
    }

    /// Value returned by "Show my CID".
    static func cid(_ server: ServerEntity) async throws -> String {
        let entry = try entry(for: server)
        switch await IntentEnvironment.service.cid(for: entry) {
        case .success(let cid): return cid
        case .failure(let failure): throw IntentError(failure: failure)
        }
    }
}

struct CheckServerBanIntent: AppIntent {
    static let title = LocalizedStringResource("intent.checkBan.title")

    @Parameter(title: LocalizedStringResource("intent.parameter.server"))
    var server: ServerEntity

    init() {}

    init(server: ServerEntity) {
        self.server = server
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await IntentRunner.checkBan(server))
    }
}

struct ShowCIDIntent: AppIntent {
    static let title = LocalizedStringResource("intent.showCID.title")

    @Parameter(title: LocalizedStringResource("intent.parameter.server"))
    var server: ServerEntity

    init() {}

    init(server: ServerEntity) {
        self.server = server
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await IntentRunner.cid(server))
    }
}

/// "Refresh": runs a full refresh in the running app (its model is registered at launch).
struct RefreshIntent: AppIntent {
    static let title = LocalizedStringResource("intent.refresh.title")

    @Dependency private var model: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await model.refresh().value
        return .result(value: model.report.map { HistoryTransitions.levelName($0.overall) } ?? "")
    }
}

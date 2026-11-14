import AppIntents
import Foundation

// §41 App Intents / Shortcuts: "Check server ban", "Show my CID", "Refresh"; §66.4 "Diagnose Server",
// "Copy Diagnosis Report".
// Titles are keys of Localizable.strings (system language); spoken/shown results use the app language (L10n).

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
        case .noDiagnosis: return LocalizedStringResource("intent.error.noDiagnosis")
        case .noNetwork: return LocalizedStringResource("intent.error.noNetwork")
        case .clipboard: return LocalizedStringResource("intent.error.clipboard")
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

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let status = try await IntentRunner.checkBan(server)
        let label = BanStatus(rawValue: status)?.label ?? status
        return .result(value: status, dialog: IntentDialog(stringLiteral: L10n.format(.intentDialogBan, server.label, label)))
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

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let cid = try await IntentRunner.cid(server)
        return .result(value: cid, dialog: IntentDialog(stringLiteral: L10n.format(.intentDialogCID, server.label, cid)))
    }
}

/// "Refresh": runs a full refresh in the running app (its model is registered at launch).
struct RefreshIntent: AppIntent {
    static let title = LocalizedStringResource("intent.refresh.title")

    @Dependency private var model: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        await model.refresh().value
        let level = model.report?.overall
        let text = L10n.format(.intentDialogRefresh, level?.label ?? L10n.text(.topbarNotChecked))
        return .result(value: level.map(HistoryTransitions.levelName) ?? "", dialog: IntentDialog(stringLiteral: text))
    }
}

/// §66.4 trend period of the report ("Copy Diagnosis Report").
extension DiagnosisTrendWindow: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("diagnose.trend.window"))
    static let caseDisplayRepresentations: [DiagnosisTrendWindow: DisplayRepresentation] = [
        .week: DisplayRepresentation(title: LocalizedStringResource("diagnose.trend.window.week")),
        .month: DisplayRepresentation(title: LocalizedStringResource("diagnose.trend.window.month")),
        .all: DisplayRepresentation(title: LocalizedStringResource("diagnose.trend.window.all")),
    ]
}

/// §66.4 "Diagnose Server": runs the §64 diagnosis in the running app and answers with the verdict and duration
/// (`CID ban · 1,2 sn`); the history gets the usual `diagnose` line.
struct DiagnoseServerIntent: AppIntent {
    static let title = LocalizedStringResource("intent.diagnose.title")

    @Parameter(title: LocalizedStringResource("intent.parameter.server"))
    var server: ServerEntity

    @Dependency private var model: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let diagnosis: ConnectionDiagnosis
        do {
            diagnosis = try await model.diagnoseForIntent(server.id)
        } catch let failure as IntentFailure {
            throw IntentError(failure: failure)
        }
        return .result(value: DiagnosisIntentText.result(diagnosis),
                       dialog: IntentDialog(stringLiteral: DiagnosisIntentText.dialog(label: server.label, diagnosis)))
    }
}

/// §66.4 "Copy Diagnosis Report": the report of the server's last diagnosis (masked by default) with the history
/// of the chosen period goes to the clipboard.
struct CopyDiagnosisReportIntent: AppIntent {
    static let title = LocalizedStringResource("intent.copyReport.title")

    @Parameter(title: LocalizedStringResource("intent.parameter.server"))
    var server: ServerEntity

    @Parameter(title: LocalizedStringResource("intent.parameter.masked"), default: true)
    var masked: Bool

    @Parameter(title: LocalizedStringResource("diagnose.trend.window"), default: .week)
    var window: DiagnosisTrendWindow

    @Dependency private var model: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await model.copyDiagnosisReportForIntent(server.id, masked: masked, window: window) {
        case .success(let label):
            return .result(dialog: IntentDialog(stringLiteral: L10n.format(.intentDialogCopyReport, label)))
        case .failure(let failure):
            throw IntentError(failure: failure)
        }
    }
}

/// Shortcuts and Siri: 5 shortcuts, 10 phrases. Phrases are keys of `AppShortcuts.strings` (tr/en).
struct PlayerIdentityShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckServerBanIntent(),
                    phrases: ["intent.phrase.checkBan \(.applicationName)", "intent.phrase.checkBanShort \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.short.checkBan"), systemImageName: "shield.lefthalf.filled")
        AppShortcut(intent: ShowCIDIntent(),
                    phrases: ["intent.phrase.showCID \(.applicationName)", "intent.phrase.showIdentity \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.short.showCID"), systemImageName: "person.text.rectangle")
        AppShortcut(intent: RefreshIntent(),
                    phrases: ["intent.phrase.refresh \(.applicationName)", "intent.phrase.refreshBans \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.short.refresh"), systemImageName: "arrow.clockwise")
        AppShortcut(intent: DiagnoseServerIntent(),
                    phrases: ["intent.phrase.diagnose \(.applicationName)", "intent.phrase.diagnoseConnection \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.short.diagnose"), systemImageName: "stethoscope")
        AppShortcut(intent: CopyDiagnosisReportIntent(),
                    phrases: ["intent.phrase.copyReport \(.applicationName)", "intent.phrase.copyDiagnosis \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.short.copyReport"), systemImageName: "doc.on.clipboard")
    }
}

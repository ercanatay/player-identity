import AppKit
import Foundation
import Observation

/// External dependencies; tests pass fakes (§9).
struct AppDependencies {
    var paths: AppPaths
    var fileSystem: any FileSystemReading
    var localIPProvider: any LocalIPProviding
    var publicIPClient: PublicIPClient
    var snapshotStore: SnapshotStore
    var defaults: UserDefaults
    var now: @Sendable () -> Date
    /// §13 ban check UDP transport (fake in tests).
    var udpTransport: any UDPTransport
    /// §15.6 `xash3d` process detection (fake in tests).
    var gameProcessDetector: any GameProcessDetecting
    /// §17 Fix: allowlisted network command runner and sleeper (fake in tests; no real command runs).
    var commandRunner: any CommandRunning
    var sleeper: any Sleeping
    /// §20 hostname resolution (fake in tests; tests never hit DNS).
    var resolver: any ServerAddressResolver
    /// §23 notification center; no-op unless injected.
    var notifier: any UserNotifying = NoopNotifier()
    /// §25 GitHub Releases client; `nil` = update checks disabled (default in tests).
    var updateHTTP: (any HTTPClient)? = nil
    /// `CFBundleShortVersionString` of the running app.
    var appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// §27 installer dependencies (real by default; the relauncher is a no-op that fails unless injected).
    var installedApp: URL = Bundle.main.bundleURL
    var updateDownloader: any UpdateDownloading = URLSessionUpdateDownloader()
    var updateFileManager: any UpdateFileManaging = LocalUpdateFileManager()
    var updateRunner: any UpdateCommandRunning = ProcessUpdateCommandRunner()
    var relauncher: any AppRelaunching = UnavailableRelauncher()
    /// UserDefaults domain exported into data backups (§28.2/3).
    var defaultsDomain: String = UpdateInstaller.bundleID
    /// §29: Xash3D app detection and the `open` runner (the default never runs anything; real one in `live()`).
    var gameAppLocator = GameAppLocator()
    var gameLaunchRunner: any GameLaunchRunning = UnavailableGameLaunchRunner()
    /// §30: launch at login; `nil` = not available (tests inject a fake).
    var loginItem: (any LoginItemControlling)? = nil
    /// §40: opens the ban list page in the browser (the default opens nothing).
    var urlOpener: any URLOpening = UnavailableURLOpener()
    /// §37: interfaces + egress interface (`getifaddrs` + route lookup; read-only, nothing is sent).
    var interfaceReporter = InterfaceReporter()

    /// UI smoke test (§41): live UI, but nothing touches the network, the user's record or preferences.
    static func uiTesting() -> AppDependencies {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerIdentityUITesting", isDirectory: true)
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let suite = UpdateInstaller.bundleID + ".uitesting"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let paths = AppPaths(home: home)
        var deps = AppDependencies(paths: paths,
                                   fileSystem: LocalFileSystem(),
                                   localIPProvider: SystemLocalIPProvider(),
                                   publicIPClient: PublicIPClient(),
                                   snapshotStore: SnapshotStore(fileURL: paths.snapshotFile),
                                   defaults: defaults,
                                   now: { Date() },
                                   udpTransport: BSDUDPTransport(),
                                   gameProcessDetector: SystemGameProcessDetector(),
                                   commandRunner: ProcessCommandRunner(),
                                   sleeper: TaskSleeper(),
                                   resolver: SystemAddressResolver())
        deps.defaultsDomain = suite
        return deps
    }

    static func live() -> AppDependencies {
        let paths = AppPaths()
        return AppDependencies(paths: paths,
                               fileSystem: LocalFileSystem(),
                               localIPProvider: SystemLocalIPProvider(),
                               publicIPClient: PublicIPClient(),
                               snapshotStore: SnapshotStore(fileURL: paths.snapshotFile),
                               defaults: .standard,
                               now: { Date() },
                               udpTransport: BSDUDPTransport(),
                               gameProcessDetector: SystemGameProcessDetector(),
                               commandRunner: ProcessCommandRunner(),
                               sleeper: TaskSleeper(),
                               resolver: SystemAddressResolver(),
                               notifier: SystemNotifier(),
                               updateHTTP: URLSessionHTTPClient(),
                               relauncher: OpenAndTerminateRelauncher(runner: ProcessUpdateCommandRunner(),
                                                                      terminate: { await MainActor.run { TerminationPolicy.terminateForUpdate { NSApp.terminate(nil) } } }),
                               gameLaunchRunner: ProcessGameLaunchRunner(),
                               loginItem: MainAppLoginItem(),
                               urlOpener: WorkspaceURLOpener())
    }
}

/// Refresh orchestration, status and persistence (§5, §6, §8).
@MainActor
@Observable
final class AppModel {
    static let dataRootDefaultsKey = DefaultsKey.dataRoot
    static let banCheckDefaultsKey = DefaultsKey.banCheckEnabled
    static let recentNamesDefaultsKey = DefaultsKey.recentNames

    private(set) var dataRoot: URL
    private(set) var gamedirs: [String] = []
    private(set) var selectedGamedir: String?
    /// `nil` = not read yet.
    private(set) var identity: Result<Identity, IdentityError>?
    private(set) var config = PlayerConfig()
    private(set) var lanAddresses: [LocalAddress] = []
    /// Public IP fetched in the last refresh; `nil` = could not be fetched or not checked yet.
    private(set) var publicIP: String?
    private(set) var servers: [ServerEntry]
    private(set) var snapshotState: SnapshotLoadResult
    /// `nil` until the first full refresh finishes.
    private(set) var report: StatusReport?
    private(set) var isRefreshing = false
    private(set) var lastChecked: Date?
    var saveErrorMessage: String?
    /// Settings > "Ban check" (on by default, stored in UserDefaults). When off, no ban packets are sent.
    var banCheckEnabled: Bool {
        didSet { deps.defaults.set(banCheckEnabled, forKey: Self.banCheckDefaultsKey) }
    }
    /// Settings > "Notifications" (§23, on by default). When off, no notification is posted.
    var notificationsEnabled: Bool {
        didSet { deps.defaults.set(notificationsEnabled, forKey: DefaultsKey.notificationsEnabled) }
    }

    /// Settings > "Language / Dil" (§35). Applied at once: texts resolve in the new language and views rebuild.
    var appLanguage: AppLanguageSetting {
        didSet {
            guard appLanguage != oldValue else { return }
            appLanguage.save(to: deps.defaults)
            L10n.setting = appLanguage
        }
    }

    // MARK: §30 menu bar and launch at login
    /// Settings > "Show in menu bar" (off by default).
    var menuBarEnabled: Bool {
        didSet {
            guard menuBarEnabled != oldValue else { return }
            MenuBarPreferences(showInMenuBar: menuBarEnabled).save(to: deps.defaults)
            if backgroundTasksActive {
                if menuBarEnabled { startMenuBarRefresh() } else { stopMenuBarRefresh() }
            }
        }
    }
    private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    /// Last launch-at-login error, shown under the switch.
    var loginItemError: LoginItemError?
    @ObservationIgnored private var menuBarTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTasksActive = false

    // MARK: §29 join the game
    /// `Xash3D-FWGS.app` was found; "Join Game" is hidden otherwise.
    private(set) var isGameAppInstalled = false
    struct JoinRequest: Identifiable, Equatable {
        let id = UUID()
        let serverID: UUID
        let label: String
        let plan: GameLaunchPlan
    }
    /// The game is running: "a new connection closes the current game" confirmation.
    var pendingJoin: JoinRequest?
    var joinError: GameLaunchError?
    @ObservationIgnored private var joinTask: Task<Void, Never>?

    // MARK: §31 list filter
    var serverFilter = ServerListFilter()

    // MARK: §37 interfaces
    /// Interfaces and VPN state of the last full refresh; `nil` before it.
    private(set) var interfaceReport: InterfaceReport?

    // MARK: §25/§27/§28 updates
    /// Release feed, banner, installer and data backups.
    let updates: UpdateController
    /// Banner content: a newer, not ignored release.
    var availableUpdate: AppUpdate? { updates.availableUpdate }

    // MARK: §24 apply preview
    struct ApplyPreview: Identifiable, Equatable {
        let id = UUID()
        let diffs: [ConfigFileDiff]
    }
    /// Open preview sheet; nothing is written until `confirmApply()`.
    var applyPreview: ApplyPreview?

    // MARK: §22 history window
    /// Incremented after every history write so the history window reloads.
    private(set) var historyRevision = 0

    // MARK: §15 name/model editing
    /// Sources of the effective values (§15.2).
    private(set) var configSources = ConfigSources()
    /// Folder names under `<gamedir>/models/player/`; `nil` if unreadable.
    private(set) var availableModels: [String]?
    /// Draft values; written to disk only via Apply.
    var nameDraft = ""
    var modelDraft = ""
    private(set) var recentNames: [String]
    private(set) var isApplying = false
    private(set) var applyStatus: ApplyStatus?
    /// Whether an `xash3d` process is running (checked on refresh and on Apply).
    private(set) var isGameRunning = false
    /// After Apply the record becomes "unsaved"; reset by Save.
    private var appliedSinceSave = false

    // MARK: §17 Fix
    struct FixSession: Identifiable, Equatable {
        /// Server row identifier.
        let id: UUID
        let kind: FixKind
        var phase: FixPhase = .ready
        /// One-line info such as a lock rejection or a recheck result.
        var note: String?
    }

    enum FixPhase: Equatable {
        case ready
        case running(FixProgress)
        case finished(IPFixOutcome, at: Date)
    }

    /// Open Fix sheet.
    var fixSession: FixSession?
    /// After a fix the record becomes "unsaved".
    private var fixedSinceSave = false
    @ObservationIgnored private let fixLock = BanFixLock()
    @ObservationIgnored private var fixTask: Task<Void, Never>?

    static var fixLockedText: String { L10n.text(.fixLocked) }
    static var banCheckDisabledText: String { L10n.text(.fixBanCheckDisabled) }
    static var recheckThrottledText: String { L10n.text(.fixRecheckThrottled) }

    // MARK: §16 model preview
    /// Model previews of the selected gamedir; models not loaded yet are absent (skeleton view).
    private(set) var modelPreviews: [String: ModelPreview] = [:]
    private(set) var isLoadingPreviews = false
    @ObservationIgnored private let previewCache = ModelPreviewCache()
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    enum ApplyStatus: Equatable {
        case success(String)
        case failure(EditMessage)
    }

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let banScheduler = BanCheckScheduler()
    /// §20: hostname resolutions keyed by normalized hostname (5-minute cache behind it).
    private(set) var hostResolutions: [String: HostResolution] = [:]
    @ObservationIgnored private let hostCache: HostResolutionCache
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    /// §22 history (`history.jsonl`); writes are chained so entries keep their order.
    @ObservationIgnored private let history: HistoryRecorder
    /// §39 ping/uptime samples (`metrics.jsonl`).
    @ObservationIgnored private let metrics: MetricsRecorder
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private let notificationDispatcher: NotificationDispatcher
    /// Whether the user made changes while there is no record.
    private var editedWithoutSnapshot = false

    init(dependencies: AppDependencies) {
        deps = dependencies
        hostCache = HostResolutionCache(resolver: dependencies.resolver, now: dependencies.now)
        history = HistoryRecorder(store: HistoryStore(fileURL: dependencies.paths.historyFile), now: dependencies.now)
        metrics = MetricsRecorder(store: MetricsStore(fileURL: dependencies.paths.metricsFile), now: dependencies.now)
        notificationDispatcher = NotificationDispatcher(notifier: dependencies.notifier, now: dependencies.now)
        let loaded = dependencies.snapshotStore.load()
        snapshotState = loaded
        let snapshot = loaded.snapshot

        if let stored = dependencies.defaults.string(forKey: Self.dataRootDefaultsKey), !stored.isEmpty {
            dataRoot = URL(fileURLWithPath: stored, isDirectory: true)
        } else if let snapshot, !snapshot.dataRoot.isEmpty {
            dataRoot = URL(fileURLWithPath: snapshot.dataRoot, isDirectory: true)
        } else {
            dataRoot = dependencies.paths.defaultDataRoot
        }
        selectedGamedir = (snapshot?.gamedir).flatMap { $0.isEmpty ? nil : $0 }
        servers = snapshot?.servers ?? []
        banCheckEnabled = dependencies.defaults.object(forKey: Self.banCheckDefaultsKey) as? Bool ?? true
        notificationsEnabled = dependencies.defaults.object(forKey: DefaultsKey.notificationsEnabled) as? Bool ?? true
        recentNames = dependencies.defaults.stringArray(forKey: Self.recentNamesDefaultsKey) ?? []
        menuBarEnabled = MenuBarPreferences(defaults: dependencies.defaults).showInMenuBar
        appLanguage = AppLanguageSetting(defaults: dependencies.defaults)
        L10n.setting = AppLanguageSetting(defaults: dependencies.defaults)
        isGameAppInstalled = dependencies.gameAppLocator.locate() != nil
        loginItemStatus = dependencies.loginItem?.status() ?? .notRegistered
        updates = UpdateController(dependencies: dependencies)
        updates.evaluateRestore(snapshot: loaded)
        updates.onUpdateFound = { [weak self] version in
            self?.recordHistory { recorder in
                await recorder.recordUpdate(version: version)
                return []
            }
        }
    }

    // MARK: Derived state

    var hasUnsavedChanges: Bool {
        if appliedSinceSave || fixedSinceSave { return true }
        guard let snapshot = snapshotState.snapshot else { return editedWithoutSnapshot }
        return editableState != EditableState(snapshot: snapshot)
    }

    var editableState: EditableState {
        EditableState(dataRoot: dataRoot.path, gamedir: selectedGamedir, servers: servers)
    }

    func rowStatus(_ id: UUID) -> ServerRowStatus? {
        report?.server(id)
    }

    // MARK: Refresh (§6)

    /// Starts a new generation; the previous refresh is cancelled and its late result ignored.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        startRefresh(includeNetwork: true)
    }

    private func startRefresh(includeNetwork: Bool) -> Task<Void, Never> {
        generation += 1
        let current = generation
        refreshTask?.cancel()
        isRefreshing = true
        let task = Task { await self.runRefresh(generation: current, includeNetwork: includeNetwork) }
        refreshTask = task
        return task
    }

    private func runRefresh(generation current: Int, includeNetwork: Bool) async {
        // 1–2. Identity + config (off the main thread)
        let loader = ProfileLoader(fileSystem: deps.fileSystem, homeDirectory: deps.paths.home)
        let root = dataRoot
        let preferred = selectedGamedir
        let detector = deps.gameProcessDetector
        let (profile, gameRunning) = await Task.detached {
            (loader.load(dataRoot: root, preferredGamedir: preferred), detector.isGameRunning())
        }.value
        guard current == generation else { return }
        gamedirs = profile.gamedirs
        selectedGamedir = profile.selectedGamedir
        isGameAppInstalled = deps.gameAppLocator.locate() != nil
        identity = profile.identity
        // Unedited drafts follow the new effective value; the user's draft is kept.
        if nameDraft == config.name { nameDraft = profile.config.name }
        if modelDraft == config.model { modelDraft = profile.config.model }
        let gamedirChanged = previewGamedir != profile.selectedGamedir
        config = profile.config
        configSources = profile.configSources
        availableModels = profile.models
        isGameRunning = gameRunning
        loadPreviews(resetting: gamedirChanged)

        if includeNetwork {
            // §20: resolve hostnames first (cached); CIDs and ban checks use the resolved address.
            let resolved = await hostCache.resolveAll(servers.map(\.host))
            guard current == generation else { return }
            hostResolutions.merge(resolved) { _, new in new }

            // §13 ban check: in parallel with the other network steps; cancelled together with the refresh.
            let banRequests = banCheckEnabled
                ? BanCheckRunner.requests(servers: servers, rawID: try? profile.identity.get().rawID,
                                          name: profile.config.name, resolutions: hostResolutions)
                : []
            let checker = BanChecker(transport: deps.udpTransport, now: deps.now)
            let scheduler = banScheduler
            async let banResults = BanCheckRunner.run(banRequests, checker: checker, scheduler: scheduler)

            // 3. Local IPs
            let provider = deps.localIPProvider
            let reporter = deps.interfaceReporter
            let (lan, interfaces) = await Task.detached { (provider.localAddresses(), reporter.report()) }.value
            guard current == generation else { return }
            lanAddresses = lan
            interfaceReport = interfaces

            // 4. Public IP (primary → fallback)
            let ip: String?
            do {
                ip = try await deps.publicIPClient.fetch()
            } catch is CancellationError {
                return
            } catch {
                ip = nil
            }
            guard current == generation else { return }
            publicIP = ip

            let bans = await banResults
            guard current == generation else { return }
            var samples: [MetricSample] = []
            for request in banRequests {
                guard let check = bans[request.serverID],
                      let index = servers.firstIndex(where: { $0.id == request.serverID }),
                      servers[index].host == request.host, servers[index].port == request.port else { continue }
                servers[index].banCheck = check
                samples.append(MetricSample(check: check, serverID: request.serverID, host: request.host))
            }
            recordMetrics(samples)

            let now = deps.now()
            lastChecked = now
            for index in servers.indices { servers[index].lastCheckedAt = now }
        }

        // 5–6. CIDs + comparison
        isRefreshing = false
        reevaluate()
        if includeNetwork { recordRefreshHistory() }
        checkAppealReminders()
    }

    /// Recomputes the status from current data without network requests (§8). No evaluation before the first full refresh.
    func reevaluate() {
        guard lastChecked != nil, let identity else { return }
        let current = CurrentState(identity: identity,
                                   displayName: config.name,
                                   model: config.model,
                                   lanIPs: lanAddresses.map(\.display),
                                   publicIP: publicIP,
                                   servers: servers,
                                   resolutions: hostResolutions)
        report = StatusEvaluator.evaluate(current: current, snapshot: snapshotState)
    }

    // MARK: Hostnames (§20)

    /// Effective address of a server host (IP literal or resolved hostname).
    func address(for entry: ServerEntry) -> ServerAddress? {
        HostAddressing.address(for: entry.host, in: hostResolutions)
    }

    /// Resolves a newly entered hostname (cached), then re-evaluates. DNS only; no other network request.
    private func resolveIfNeeded(_ host: String) {
        guard case .hostname(let name)? = HostValidator.classify(host), hostResolutions[name] == nil else { return }
        let cache = hostCache
        let previous = resolveTask
        resolveTask = Task {
            await previous?.value
            let resolution = await cache.resolve(name)
            hostResolutions[name] = resolution
            reevaluate()
        }
    }

    /// For tests: waits until pending hostname resolutions finish.
    func waitForResolutions() async {
        await resolveTask?.value
    }

    // MARK: History (§22)

    /// Runs a history write after the previous ones; the returned notifications (§23) are posted afterwards.
    private func recordHistory(_ operation: @escaping @Sendable (HistoryRecorder) async -> [NotificationContent]) {
        let recorder = history
        let dispatcher = notificationDispatcher
        let enabled = notificationsEnabled
        let previous = historyTask
        historyTask = Task {
            await previous?.value
            let contents = await operation(recorder)
            historyRevision += 1
            await dispatcher.handle(contents, enabled: enabled)
        }
    }

    private func serverLabels() -> [UUID: String] {
        Dictionary(servers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    /// History entries for the history window (read off the main thread).
    func loadHistory() async -> [HistoryEntry] {
        let store = HistoryStore(fileURL: deps.paths.historyFile)
        return await Task.detached { store.load() }.value
    }

    private func recordRefreshHistory() {
        let observation = HistoryObservation(
            ts: deps.now(),
            overall: report?.overall,
            publicIP: publicIP,
            identity: try? identity?.get().rawIDHex,
            name: config.name.isEmpty ? nil : config.name,
            model: config.model.isEmpty ? nil : config.model,
            servers: servers.map { HistoryObservation.Server(id: $0.id, host: $0.host, ban: $0.banCheck?.status) })
        let labels = serverLabels()
        recordHistory { recorder in
            await recorder.observe(observation).compactMap { entry in
                NotificationPlanner.content(for: entry, serverLabel: entry.serverID.flatMap { labels[$0] })
            }
        }
    }

    // MARK: §40 ban list URL

    /// Sets (or clears with an empty text) the row's ban list URL template; saved with the record.
    @discardableResult
    func setBanListURL(_ template: String, for id: UUID) -> BanListTemplateError? {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        var stored: String?
        if !trimmed.isEmpty {
            switch BanListTemplate.validate(trimmed) {
            case .success(let valid): stored = valid
            case .failure(let error): return error
            }
        }
        guard servers[index].banListURL != stored else { return nil }
        servers[index].banListURL = stored
        markEdited()
        return nil
    }

    /// The filled-in ban list URL of a row (CID and IP from the current identity and resolution).
    func banListURL(for id: UUID) -> Result<URL, BanListTemplateError>? {
        guard let entry = servers.first(where: { $0.id == id }), let template = entry.banListURL else { return nil }
        let status = rowStatus(id)
        let values = BanListValues(cid: status?.currentCID, ip: address(for: entry)?.text, host: entry.host, port: entry.port)
        return BanListTemplate.url(template, values: values)
    }

    /// "Ban listesinde ara": opens the page in the default browser (no scraping).
    @discardableResult
    func openBanList(for id: UUID) -> BanListTemplateError? {
        switch banListURL(for: id) {
        case .success(let url)?:
            _ = deps.urlOpener.open(url)
            return nil
        case .failure(let error)?:
            return error
        case nil:
            return .empty
        }
    }

    // MARK: §36 appeal reminders

    /// Appeals whose follow-up date has passed and that were not notified yet (empty with notifications off).
    /// The caller posts the notification, then calls `markAppealsNotified`.
    func dueAppealReminders() -> [AppealReminder.Due] {
        AppealReminder.due(servers, now: deps.now(), notificationsEnabled: notificationsEnabled)
    }

    func markAppealsNotified(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let now = deps.now()
        servers = AppealReminder.markNotified(ids, in: servers, at: now)
        // The reminder must not come back after a relaunch: `notifiedAt` goes straight into the saved record
        // (only for appeals already saved with the same follow-up date). It is not an "unsaved" change.
        guard var saved = snapshotState.snapshot else { return }
        var changed = false
        for index in saved.servers.indices where ids.contains(saved.servers[index].id) {
            guard let stored = saved.servers[index].appeal,
                  stored.followUpAt == servers.first(where: { $0.id == saved.servers[index].id })?.appeal?.followUpAt else { continue }
            saved.servers[index].appeal?.notifiedAt = now
            changed = changed || stored.notifiedAt != now
        }
        guard changed, (try? deps.snapshotStore.save(saved)) != nil else { return }
        snapshotState = .loaded(saved)
    }

    /// §36: posts "İtiraz takibi: <server>" once per follow-up date (launch, refresh, menu bar timer).
    @discardableResult
    func checkAppealReminders() -> Task<Void, Never>? {
        let due = dueAppealReminders()
        guard !due.isEmpty else { return nil }
        let contents = due.compactMap { item in
            servers.first { $0.id == item.serverID }?.appeal.map { AppealReminderText.content(for: item, status: $0.status) }
        }
        markAppealsNotified(Set(due.map(\.serverID)))
        let dispatcher = notificationDispatcher
        let enabled = notificationsEnabled
        return Task { await dispatcher.handle(contents, enabled: enabled) }
    }

    // MARK: §38 ban matrix

    /// Matrix rows (banned first); range bans come from the history of fix attempts.
    func banMatrixRows() async -> [BanMatrixRow] {
        BanMatrix.rows(servers: servers, rangeBans: BanMatrix.rangeBans(from: await loadHistory()))
    }

    // MARK: §41 diagnostics

    /// The diagnostics ZIP (app info, redacted record, history/metrics tails, update state).
    func diagnosticsArchive(appInfo: DiagnosticsAppInfo = .current()) async -> Data {
        await historyTask?.value
        await metricsTask?.value
        return DiagnosticsBundle.archive(DiagnosticsInput(appInfo: appInfo, paths: deps.paths, defaults: deps.defaults,
                                                           now: deps.now()))
    }

    // MARK: §39 metrics

    @ObservationIgnored private var metricsTask: Task<Void, Never>?

    /// Appends one sample per finished check, after the previous writes.
    private func recordMetrics(_ samples: [MetricSample]) {
        guard !samples.isEmpty else { return }
        let recorder = metrics
        let previous = metricsTask
        metricsTask = Task {
            await previous?.value
            await recorder.record(samples)
        }
    }

    /// Samples for the charts (read off the main thread).
    func loadMetrics() async -> [MetricSample] {
        let store = MetricsStore(fileURL: deps.paths.metricsFile)
        await metricsTask?.value
        return await Task.detached { store.load() }.value
    }

    /// For tests: waits until the running refresh finishes.
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// For tests: waits until queued history writes finish.
    func waitForHistory() async {
        await historyTask?.value
    }

    // MARK: User changes

    /// On gamedir change only local files are re-read (no network request). A running full refresh is restarted.
    @discardableResult
    func selectGamedir(_ name: String) -> Task<Void, Never>? {
        guard name != selectedGamedir else { return nil }
        selectedGamedir = name
        markEdited()
        return startRefresh(includeNetwork: isRefreshing)
    }

    /// The data root choice is written to UserDefaults; rediscovery + refresh follow.
    @discardableResult
    func setDataRoot(_ url: URL) -> Task<Void, Never> {
        dataRoot = url.standardizedFileURL
        deps.defaults.set(dataRoot.path, forKey: Self.dataRootDefaultsKey)
        markEdited()
        return refresh()
    }

    func addServer(_ draft: ServerDraft) {
        guard draft.isValid, let port = draft.port else { return }
        servers.append(ServerEntry(label: draft.trimmedLabel, host: draft.trimmedHost, port: port,
                                   group: draft.resolvedGroup(existing: ServerOrganization.groups(servers)),
                                   favorite: draft.favorite, order: ServerOrganization.nextOrder(servers)))
        markEdited()
        reevaluate()
        resolveIfNeeded(draft.trimmedHost)
    }

    func updateServer(id: UUID, with draft: ServerDraft) {
        guard draft.isValid, let port = draft.port,
              let index = servers.firstIndex(where: { $0.id == id }) else { return }
        if servers[index].host != draft.trimmedHost {
            servers[index].lastCheckedAt = nil
        }
        if servers[index].host != draft.trimmedHost || servers[index].port != port {
            servers[index].banCheck = nil
        }
        servers[index].label = draft.trimmedLabel
        servers[index].host = draft.trimmedHost
        servers[index].port = port
        servers[index].group = draft.resolvedGroup(existing: ServerOrganization.groups(servers))
        servers[index].favorite = draft.favorite
        markEdited()
        reevaluate()
        resolveIfNeeded(draft.trimmedHost)
    }

    // MARK: §31 groups, favorites, order

    /// Existing group names (sorted) for the group picker.
    var serverGroups: [String] { ServerOrganization.groups(servers) }

    func serverSections(filter: ServerListFilter = ServerListFilter()) -> [ServerSection] {
        ServerOrganization.sections(servers, filter: filter)
    }

    func setFavorite(_ favorite: Bool, for id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }), servers[index].favorite != favorite else { return }
        servers[index].favorite = favorite
        markEdited()
    }

    func canMoveServer(id: UUID, _ direction: ServerMoveDirection) -> Bool {
        ServerOrganization.canMove(id, direction, in: servers)
    }

    /// ▲/▼ inside the section; `order` is saved with the record.
    func moveServer(id: UUID, _ direction: ServerMoveDirection) {
        guard let moved = ServerOrganization.move(id, direction, in: servers) else { return }
        servers = moved
        markEdited()
    }

    // MARK: §29 join the game

    private var gameLauncher: GameLauncher {
        GameLauncher(locator: deps.gameAppLocator, resolver: deps.resolver, detector: deps.gameProcessDetector,
                     runner: deps.gameLaunchRunner)
    }

    /// "Join Game": builds the command; if the game is running, asks first (`pendingJoin`), otherwise opens it.
    @discardableResult
    func joinGame(_ id: UUID) -> Task<Void, Never>? {
        guard let entry = servers.first(where: { $0.id == id }), joinTask == nil else { return nil }
        let launcher = gameLauncher
        let gamedir = selectedGamedir
        let known = hostResolutions
        let task = Task {
            defer { joinTask = nil }
            do {
                let plan = try await launcher.plan(host: entry.host, port: entry.port, gamedir: gamedir, known: known)
                if plan.gameRunning {
                    pendingJoin = JoinRequest(serverID: id, label: entry.label, plan: plan)
                } else {
                    try await launcher.launch(plan) { true }
                }
            } catch let error as GameLaunchError {
                joinError = error
            } catch {
                joinError = .launchFailed(status: -1)
            }
        }
        joinTask = task
        return task
    }

    /// Confirmed: the running game is replaced by the new connection.
    @discardableResult
    func confirmJoin() -> Task<Void, Never>? {
        guard let request = pendingJoin else { return nil }
        pendingJoin = nil
        let launcher = gameLauncher
        return Task {
            do {
                try await launcher.launch(request.plan) { true }
            } catch let error as GameLaunchError {
                joinError = error
            } catch {
                joinError = .launchFailed(status: -1)
            }
        }
    }

    /// Cancelled: nothing is started.
    func cancelJoin() {
        pendingJoin = nil
    }

    // MARK: §30 menu bar and launch at login

    var menuBarPresentation: MenuBarPresentation { MenuBarPresentation.make(overall: report?.overall) }

    /// Called once by the app (not in tests): starts the 30-minute refresh if the menu bar mode is on.
    func activateBackgroundTasks() {
        backgroundTasksActive = true
        checkAppealReminders()
        if menuBarEnabled { startMenuBarRefresh() }
    }

    private func startMenuBarRefresh() {
        guard menuBarTask == nil else { return }
        let sleeper = deps.sleeper
        menuBarTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.runMenuBarTick() else { return }
                try? await sleeper.sleep(seconds: max(delay, 60))
            }
        }
    }

    private func stopMenuBarRefresh() {
        menuBarTask?.cancel()
        menuBarTask = nil
    }

    /// One tick of the menu bar timer: refreshes if 30 minutes have passed since the last check. Returns the
    /// seconds until the next tick, `nil` when the menu bar mode is off (the timer stops).
    @discardableResult
    func runMenuBarTick() -> TimeInterval? {
        guard let delay = MenuBarRefreshSchedule.delay(lastRefresh: lastChecked, now: deps.now(), enabled: menuBarEnabled) else {
            return nil
        }
        guard delay <= 0 else {
            checkAppealReminders()
            return delay
        }
        if !isRefreshing { refresh() }   // the refresh checks the reminders when it finishes
        return MenuBarRefreshSchedule.interval
    }

    var isLoginItemAvailable: Bool { deps.loginItem != nil }

    func refreshLoginItemStatus() {
        guard let item = deps.loginItem else { return }
        loginItemStatus = item.status()
    }

    /// Settings > "Launch at login" (`SMAppService.mainApp`); a failure is shown under the switch.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard let item = deps.loginItem else { return }
        switch LoginItemSwitch.set(enabled, using: item) {
        case .success(let status):
            loginItemStatus = status
            loginItemError = nil
        case .failure(let error):
            loginItemStatus = item.status()
            loginItemError = error
        }
    }

    // MARK: §33 share card

    /// Card content for a row; labels and date in the user's language.
    func shareCardContent(for id: UUID, icon: CGImage?) -> ShareCardContent? {
        guard let entry = servers.first(where: { $0.id == id }) else { return nil }
        let cid = rowStatus(id)?.currentCID ?? entry.cid
        let host = ServerAddress.parse(entry.host).flatMap { address -> String? in
            if case .ipv6 = address { return "[\(entry.host)]" }
            return nil
        } ?? entry.host
        let name = config.name.isEmpty ? (snapshotState.snapshot?.displayName ?? "") : config.name
        return ShareCardContent(serverName: entry.label, hostPort: "\(host):\(entry.port)", cid: cid, playerName: name,
                                dateText: DateFormatter.localizedString(from: deps.now(), dateStyle: .medium, timeStyle: .short),
                                labels: ShareCardLabels(title: L10n.text(.appWindowTitle), server: L10n.text(.shareCardServer),
                                                        cid: L10n.text(.shareCardCID), player: L10n.text(.shareCardPlayer),
                                                        date: L10n.text(.shareCardDate)),
                                icon: icon)
    }

    // MARK: §32 notes and appeals

    /// 🔔 in the row: an open appeal whose follow-up date has passed.
    func isFollowUpDue(_ entry: ServerEntry) -> Bool {
        entry.appeal?.isFollowUpDue(now: deps.now()) ?? false
    }

    var now: Date { deps.now() }

    /// Sets the note (at most 2000 characters). Saved with the record.
    @discardableResult
    func setNote(_ note: String, for id: UUID) -> AppealEditError? {
        switch ServerAnnotations.setNote(note, for: id, in: servers) {
        case .success(let updated):
            guard updated != servers, let old = servers.first(where: { $0.id == id }) else { return nil }
            servers = updated
            markEdited()
            // §36: note changes go into the history (old → new, cut to 500 characters).
            if let entry = ServerAnnotations.noteHistoryEntry(old: old.note, new: note, server: old, now: deps.now()) {
                recordHistory { recorder in
                    await recorder.record(entry)
                    return []
                }
            }
            return nil
        case .failure(let error):
            return error
        }
    }

    /// §36 "postpone the follow-up date" (+1 / +3 days); the reminder is armed again.
    @discardableResult
    func postponeFollowUp(byDays days: Int, for id: UUID) -> AppealEditError? {
        guard let appeal = servers.first(where: { $0.id == id })?.appeal else { return .serverNotFound }
        return saveAppeal(appeal.postponed(byDays: days, now: deps.now()), for: id)
    }

    /// Adds, edits or removes (`nil`) the appeal; a change is recorded in the history (`appeal`).
    @discardableResult
    func saveAppeal(_ appeal: Appeal?, for id: UUID) -> AppealEditError? {
        guard let old = servers.first(where: { $0.id == id }) else { return .serverNotFound }
        switch ServerAnnotations.setAppeal(appeal, for: id, in: servers, now: deps.now()) {
        case .success(let updated):
            guard let entry = ServerAnnotations.historyEntry(old: old.appeal, new: appeal, server: old, now: deps.now()) else {
                return nil
            }
            servers = updated
            markEdited()
            recordHistory { recorder in
                await recorder.record(entry)
                return []
            }
            return nil
        case .failure(let error):
            return error
        }
    }

    func deleteServer(id: UUID) {
        servers.removeAll { $0.id == id }
        markEdited()
        reevaluate()
    }

    private func markEdited() {
        if snapshotState.snapshot == nil { editedWithoutSnapshot = true }
    }

    // MARK: Model preview (§16)

    @ObservationIgnored private var previewGamedir: String?

    /// Loads previews of the list + current model in the background (async; UI is not blocked).
    /// On gamedir change the old images are cleared immediately.
    @discardableResult
    func loadPreviews(resetting: Bool = false) -> Task<Void, Never>? {
        previewGeneration += 1
        let current = previewGeneration
        previewTask?.cancel()
        previewGamedir = selectedGamedir
        if resetting { modelPreviews = [:] }
        guard let gamedir = selectedGamedir else {
            modelPreviews = [:]
            isLoadingPreviews = false
            return nil
        }
        let gamedirURL = dataRoot.appendingPathComponent(gamedir, isDirectory: true)
        var models = modelOptions.map(\.value)
        if !modelDraft.isEmpty, !models.contains(modelDraft) { models.append(modelDraft) }
        let cache = previewCache
        isLoadingPreviews = true
        let task = Task {
            let previews = await cache.previews(gamedir: gamedirURL, models: models)
            guard current == previewGeneration else { return }
            modelPreviews = previews
            isLoadingPreviews = false
        }
        previewTask = task
        return task
    }

    func preview(for model: String) -> ModelPreview? {
        modelPreviews[model]
    }

    /// For tests: waits until the background preview loading finishes.
    func waitForPreviews() async {
        await previewTask?.value
    }

    // MARK: Name/model editing (§15)

    var modelOptions: [ModelOption] {
        PlayerOptions.modelOptions(available: availableModels ?? [], current: config.model)
    }

    var nameOptions: [String] {
        PlayerOptions.nameOptions(current: config.name, saved: snapshotState.snapshot?.displayName, recent: recentNames)
    }

    /// Without a model list, manual entry is offered (§15.3).
    var allowsManualModelEntry: Bool {
        (availableModels ?? []).isEmpty
    }

    /// Name to write; `nil` if the draft does not differ from the effective value.
    var pendingName: String? {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        return trimmed == config.name ? nil : nameDraft
    }

    var pendingModel: String? {
        modelDraft == config.model ? nil : modelDraft
    }

    /// Only the changed field is validated.
    var nameError: EditMessage? {
        guard let pendingName else { return nil }
        return PlayerValueValidator.normalizedName(pendingName) == nil ? .nameInvalid : nil
    }

    var modelError: EditMessage? {
        guard let pendingModel else { return nil }
        return PlayerValueValidator.isValidModel(pendingModel) ? nil : .modelInvalid
    }

    var canApply: Bool {
        !isApplying && identity != nil && selectedGamedir != nil
            && (pendingName != nil || pendingModel != nil)
            && nameError == nil && modelError == nil
    }

    /// Writes the drafts to the selected gamedir, then re-reads the files (no network request).
    @discardableResult
    func apply() -> Task<Void, Never>? {
        guard canApply, let gamedir = selectedGamedir else { return nil }
        let gamedirURL = dataRoot.appendingPathComponent(gamedir, isDirectory: true)
        let name = pendingName
        let model = pendingModel
        let writer = PlayerConfigWriter(detector: deps.gameProcessDetector)
        isApplying = true
        applyStatus = nil
        return Task {
            let result = await Task.detached { () -> Result<ApplyOutcome, EditMessage> in
                do {
                    return .success(try writer.apply(gamedir: gamedirURL, name: name, model: model))
                } catch let error as EditMessage {
                    return .failure(error)
                } catch {
                    return .failure(.writeFailed)
                }
            }.value
            isApplying = false
            switch result {
            case .success(let outcome):
                var text = L10n.format(.profileApplied, TimeText.format(deps.now()))
                if !outcome.changedFiles.isEmpty { text += " · " + outcome.summary }
                applyStatus = .success(text)
                if !outcome.changedFiles.isEmpty {
                    let entry = HistoryEntry(ts: deps.now(), kind: .apply,
                                             new: [name.map { "name=\($0)" }, model.map { "model=\($0)" }]
                                                .compactMap { $0 }.joined(separator: "; "),
                                             note: outcome.summary)
                    recordHistory { recorder in
                        await recorder.record(entry)
                        return []
                    }
                }
                appliedSinceSave = true
                isGameRunning = false
                if let name, let normalized = PlayerValueValidator.normalizedName(name) {
                    recentNames = PlayerOptions.updatedRecentNames(recentNames, adding: normalized)
                    deps.defaults.set(recentNames, forKey: Self.recentNamesDefaultsKey)
                    nameDraft = normalized
                }
                await startRefresh(includeNetwork: isRefreshing).value
            case .failure(let error):
                applyStatus = .failure(error)
                if error == .gameRunning { isGameRunning = true }
            }
        }
    }

    // MARK: Apply preview (§24)

    /// Uygula: computes the diff without writing. An empty diff opens no sheet; errors show as the apply status.
    @discardableResult
    func requestApply() -> Task<Void, Never>? {
        guard canApply, let gamedir = selectedGamedir else { return nil }
        let gamedirURL = dataRoot.appendingPathComponent(gamedir, isDirectory: true)
        let name = pendingName
        let model = pendingModel
        let writer = PlayerConfigWriter(detector: deps.gameProcessDetector)
        applyStatus = nil
        return Task {
            let result = await Task.detached { () -> Result<[ConfigFileDiff], EditMessage> in
                do {
                    return .success(try writer.preview(gamedir: gamedirURL, name: name, model: model).diffs)
                } catch let error as EditMessage {
                    return .failure(error)
                } catch {
                    return .failure(.writeFailed)
                }
            }.value
            switch result {
            case .success(let diffs):
                applyPreview = diffs.isEmpty ? nil : ApplyPreview(diffs: diffs)
            case .failure(let error):
                applyStatus = .failure(error)
            }
        }
    }

    /// "Yaz": closes the preview and writes.
    @discardableResult
    func confirmApply() -> Task<Void, Never>? {
        guard applyPreview != nil else { return nil }
        applyPreview = nil
        return apply()
    }

    /// Cancel: closes the preview; nothing is written.
    func cancelApply() {
        applyPreview = nil
    }

    // MARK: Update check (§25, §27.2)

    /// Launch check (at most every 24 h) or manual check. Network errors are silent.
    @discardableResult
    func checkForUpdates(manual: Bool = false) -> Task<Void, Never>? {
        updates.checkForUpdates(manual: manual)
    }

    var appVersion: String { deps.appVersion }

    /// "Yoksay": hides the banner for this version.
    func ignoreUpdate() {
        updates.ignoreUpdate()
    }

    // MARK: Fix (§17)

    /// The row's fix kind; the button is visible only for `ipBanned` / `cidBanned` / `unreachable`.
    func fixKind(for id: UUID) -> FixKind? {
        FixKind.forStatus(servers.first { $0.id == id }?.banCheck?.status)
    }

    /// Only opens the sheet; runs no command.
    func beginFix(_ id: UUID) {
        guard let kind = fixKind(for: id) else { return }
        fixSession = FixSession(id: id, kind: kind)
    }

    var isFixRunning: Bool {
        if case .running? = fixSession?.phase { return true }
        return false
    }

    private func banRequest(for id: UUID) -> BanCheckRequest? {
        guard let entry = servers.first(where: { $0.id == id }) else { return nil }
        return BanCheckRunner.requests(servers: [entry], rawID: try? identity?.get().rawID, name: config.name,
                                       resolutions: hostResolutions).first
    }

    /// IP ban flow (§17.2). Called by the Start button on the confirmation sheet.
    @discardableResult
    func startIPFix() -> Task<Void, Never>? {
        guard let session = fixSession, session.kind == .ipBan, !isFixRunning else { return nil }
        let id = session.id
        let request = banRequest(for: id)
        let enabled = banCheckEnabled
        let checker = BanChecker(transport: deps.udpTransport, now: deps.now)
        let scheduler = banScheduler
        let sleeper = deps.sleeper
        let now = deps.now
        let client = deps.publicIPClient
        let lock = fixLock
        let fixer = IPBanFixer(
            runner: deps.commandRunner,
            sleeper: sleeper,
            now: now,
            fetchPublicIP: { try await client.fetch() },
            recheck: {
                guard enabled, let request else { return nil }
                // 10 s throttle: wait until permitted (at most 10 s).
                while !(await scheduler.reserve(request.endpoint.key, now: now())) {
                    do { try await sleeper.sleep(seconds: 1) } catch { return nil }
                }
                return try? await checker.check(request)
            },
            progress: { [weak self] progress in await self?.setFixProgress(progress, for: id) })
        fixSession?.note = nil
        let task = Task {
            guard await lock.acquire(now: now()) else {
                fixSession?.note = Self.fixLockedText
                return
            }
            fixSession?.phase = .running(.renewingIP)
            let oldIP = publicIP
            let result = await fixer.run()
            await lock.release()
            applyFixResult(result, serverID: id, request: request)
            let entry = HistoryEntry(ts: deps.now(), kind: .fixAttempt, serverID: id, host: request?.host,
                                     old: oldIP, new: result.newIP, note: result.outcome.code)
            let content = NotificationPlanner.content(for: entry, serverLabel: serverLabels()[id],
                                                      fixMessage: result.outcome.message)
            recordHistory { recorder in
                await recorder.record(entry) ? [content].compactMap { $0 } : []
            }
        }
        fixTask = task
        return task
    }

    func cancelFix() {
        fixTask?.cancel()
    }

    private func setFixProgress(_ progress: FixProgress, for id: UUID) {
        guard fixSession?.id == id, case .running? = fixSession?.phase else { return }
        fixSession?.phase = .running(progress)
    }

    private func applyFixResult(_ result: IPBanFixer.Result, serverID: UUID, request: BanCheckRequest?) {
        if let newIP = result.newIP {
            publicIP = newIP
            fixedSinceSave = true
        }
        if let check = result.recheck, let request {
            // §39: the fix recheck is a check too.
            recordMetrics([MetricSample(check: check, serverID: serverID, host: request.host)])
        }
        if let check = result.recheck, let request,
           let index = servers.firstIndex(where: { $0.id == serverID }),
           servers[index].host == request.host, servers[index].port == request.port {
            servers[index].banCheck = check
            fixedSinceSave = true
        }
        reevaluate()
        if fixSession?.id == serverID {
            fixSession?.phase = .finished(result.outcome, at: deps.now())
        }
    }

    /// Recheck (§17.3, §17.4): ban check only; no network command.
    @discardableResult
    func recheckServer(_ id: UUID) -> Task<Void, Never>? {
        guard banCheckEnabled else {
            fixSession?.note = Self.banCheckDisabledText
            return nil
        }
        guard let request = banRequest(for: id), !isFixRunning else { return nil }
        let checker = BanChecker(transport: deps.udpTransport, now: deps.now)
        let scheduler = banScheduler
        let now = deps.now
        let task = Task {
            guard await scheduler.reserve(request.endpoint.key, now: now()) else {
                fixSession?.note = Self.recheckThrottledText
                return
            }
            let previous = fixSession?.phase
            fixSession?.phase = .running(.rechecking)
            let check = try? await checker.check(request)
            fixSession?.phase = previous ?? .ready
            if let check { recordMetrics([MetricSample(check: check, serverID: id, host: request.host)]) }
            guard let check, let index = servers.firstIndex(where: { $0.id == id }),
                  servers[index].host == request.host, servers[index].port == request.port else { return }
            servers[index].banCheck = check
            fixedSinceSave = true
            reevaluate()
            fixSession?.note = L10n.format(.fixRecheckResult, check.status.label, TimeText.format(check.checkedAt))
        }
        fixTask = task
        return task
    }

    /// Appeal text (§17.9.1); `nil` if the row has no ban result.
    func appealText(for id: UUID) -> String? {
        guard let entry = servers.first(where: { $0.id == id }), let check = entry.banCheck else { return nil }
        let rawID = try? identity?.get().rawID
        let cid = rawID.flatMap { raw in address(for: entry).map { CIDCalculator.cid(rawID: raw, address: $0) } }
            ?? L10n.text(.appealUnknown)
        var rangeBan: RangeBanInfo?
        if case .finished(.rangeBanned(let old, let new, let cidr), _)? = fixSession?.phase, fixSession?.id == id {
            rangeBan = RangeBanInfo(cidr: cidr, oldIP: old, newIP: new)
        }
        return AppealText.make(AppealInput(serverLabel: entry.label, host: entry.host, port: entry.port,
                                           checkedAt: check.checkedAt, playerName: config.name, cid: cid,
                                           publicIP: publicIP ?? L10n.text(.appealUnknown), gamedir: selectedGamedir ?? "—",
                                           check: check, rangeBan: rangeBan))
    }

    func serverPageURL(for id: UUID) -> URL? {
        guard let entry = servers.first(where: { $0.id == id }) else { return nil }
        return GameTrackerLink.url(host: address(for: entry)?.text ?? entry.host, port: entry.port)
    }

    // MARK: Save (§5)

    /// Only `profile.json` is written.
    func save() {
        let snapshot = SnapshotBuilder.make(savedAt: deps.now(),
                                            dataRoot: dataRoot,
                                            gamedir: selectedGamedir,
                                            config: config,
                                            identity: identity,
                                            publicIP: publicIP,
                                            lanIPs: lanAddresses.map(\.display),
                                            checkedAt: lastChecked,
                                            servers: servers,
                                            resolutions: hostResolutions)
        do {
            try deps.snapshotStore.save(snapshot)
        } catch {
            saveErrorMessage = L10n.format(.saveFailed, error.localizedDescription)
            return
        }
        deps.defaults.set(dataRoot.path, forKey: Self.dataRootDefaultsKey)
        snapshotState = .loaded(snapshot)
        servers = snapshot.servers
        editedWithoutSnapshot = false
        appliedSinceSave = false
        fixedSinceSave = false
        saveErrorMessage = nil
        reevaluate()
    }

    // MARK: Environment

    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil || isUITesting
    }

    /// Launch argument of the UI smoke test: no network, a temporary home and a separate defaults domain.
    nonisolated static let uiTestingArgument = "-PIUITesting"

    nonisolated static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestingArgument)
    }
}

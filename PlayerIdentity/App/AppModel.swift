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
    /// `CFBundleVersion`, shown next to the version in Settings > Updates.
    var appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
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
    /// §47.2/§49: file operations of "Erase All Data" and the restore (tests inject failures).
    var dataFileOperations: any DataFileOperating = LocalDataFileOperations()
    /// §54: in-memory log of the last app errors (diagnostics `errors.json`).
    var errorLog = ErrorLog()

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
    /// §49.3 Settings > General > Data > "Automatic backups" (on by default).
    var autoBackupEnabled: Bool {
        didSet { deps.defaults.set(autoBackupEnabled, forKey: DefaultsKey.autoBackupEnabled) }
    }
    /// A data operation that replaces or removes the data files (§47.2, §49.2).
    enum DataOperation: Sendable, Equatable {
        case restore
        case erase
        /// §46 settings import (applies preferences, the server list and possibly the data root at once).
        case importSettings
    }

    /// §47.2/§49.2: the running data operation. Refreshing, saving, changing the data root, installing, automatic
    /// backups and any other data operation are locked meanwhile.
    private(set) var dataOperation: DataOperation?
    /// §49.2: a restore is replacing the data files.
    var isRestoring: Bool { dataOperation == .restore }
    var isDataOperationRunning: Bool { dataOperation != nil }
    /// Step of a running restore (shown in the restore sheet); `nil` when no restore runs.
    enum RestoreStep: Sendable, Equatable {
        /// The current data goes to `backups/pre-restore-…zip`.
        case backingUp
        /// The backed-up files are put in place.
        case replacing
    }

    private(set) var restoreStep: RestoreStep?
    /// §49.3: newest `backups/auto-*.zip` (modification date) and the number of automatic backups.
    private(set) var latestAutomaticBackup: Date?
    private(set) var automaticBackupCount = 0
    /// §49.3 error of the last automatic backup attempt (cleared by the next successful one).
    private(set) var autoBackupLastError: FullBackupError?
    @ObservationIgnored private var automaticBackupTask: Task<AutomaticBackupResult, Never>?
    /// Settings > "Notifications" (§23, on by default). When off, no notification is posted.
    var notificationsEnabled: Bool {
        didSet { deps.defaults.set(notificationsEnabled, forKey: DefaultsKey.notificationsEnabled) }
    }
    /// §45 per-category switches (on by default).
    var notifyBanChanges: Bool {
        didSet { deps.defaults.set(notifyBanChanges, forKey: DefaultsKey.notifyBanChanges) }
    }
    var notifyOnlineChanges: Bool {
        didSet { deps.defaults.set(notifyOnlineChanges, forKey: DefaultsKey.notifyOnlineChanges) }
    }
    var notifyMapChanges: Bool {
        didSet { deps.defaults.set(notifyMapChanges, forKey: DefaultsKey.notifyMapChanges) }
    }
    /// §45 quiet hours (`HH:mm`, may cross midnight). History is still written; only notifications are held back.
    var quietHoursEnabled: Bool {
        didSet { deps.defaults.set(quietHoursEnabled, forKey: DefaultsKey.quietHoursEnabled) }
    }
    var quietHoursStart: String {
        didSet { deps.defaults.set(quietHoursStart, forKey: DefaultsKey.quietHoursStart) }
    }
    var quietHoursEnd: String {
        didSet { deps.defaults.set(quietHoursEnd, forKey: DefaultsKey.quietHoursEnd) }
    }

    var notificationPolicy: NotificationPolicy {
        NotificationPolicy(master: notificationsEnabled, banChanges: notifyBanChanges,
                           onlineChanges: notifyOnlineChanges, mapChanges: notifyMapChanges,
                           quiet: QuietHours(enabled: quietHoursEnabled, start: quietHoursStart, end: quietHoursEnd))
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

    // MARK: §42 watched servers
    /// Last observed state per server (baseline of the change detection), kept in `watch-state.json`.
    @ObservationIgnored private var watchState: [UUID: WatchSnapshot] = [:]

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
    /// §43.2 sources per model folder name.
    private(set) var modelSources: [String: [ModelSource]] = [:]
    /// §43.1 confirmation dialog for removing the `userconfig.cfg` override line.
    var showsOverrideRemoval = false
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
    /// §36 reminders being posted (not offered again until that attempt finished).
    @ObservationIgnored private var appealRemindersInFlight: Set<UUID> = []
    @ObservationIgnored private var appealReminderTask: Task<Void, Never>?
    /// §23: macOS refused the notification permission (seen when posting or opening Settings); Settings warns.
    private(set) var notificationPermissionDenied = false
    /// §42: `watch-state.json` could not be written (the error text); cleared by the next successful write.
    private(set) var watchStateSaveError: String?
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
        autoBackupEnabled = dependencies.defaults.object(forKey: DefaultsKey.autoBackupEnabled) as? Bool ?? true
        let defaults = dependencies.defaults
        notifyBanChanges = defaults.object(forKey: DefaultsKey.notifyBanChanges) as? Bool ?? true
        notifyOnlineChanges = defaults.object(forKey: DefaultsKey.notifyOnlineChanges) as? Bool ?? true
        notifyMapChanges = defaults.object(forKey: DefaultsKey.notifyMapChanges) as? Bool ?? true
        quietHoursEnabled = defaults.object(forKey: DefaultsKey.quietHoursEnabled) as? Bool ?? false
        quietHoursStart = defaults.string(forKey: DefaultsKey.quietHoursStart) ?? QuietHours.defaultStart
        quietHoursEnd = defaults.string(forKey: DefaultsKey.quietHoursEnd) ?? QuietHours.defaultEnd
        recentNames = dependencies.defaults.stringArray(forKey: Self.recentNamesDefaultsKey) ?? []
        menuBarEnabled = MenuBarPreferences(defaults: dependencies.defaults).showInMenuBar
        watchState = WatchStateStore(fileURL: dependencies.paths.watchStateFile).load()
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
        refreshBackupInfo()
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
        // §49.2: no refresh while a restore or an erase replaces the files (each refreshes itself when done).
        guard !isDataOperationRunning else { return Task {} }
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
        modelSources = profile.modelSources
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
            evaluateWatch(banRequests.compactMap { request in bans[request.serverID].map { (request.serverID, $0) } })

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
        let policy = notificationPolicy
        let previous = historyTask
        historyTask = Task {
            await previous?.value
            let contents = await operation(recorder)
            historyRevision += 1
            await dispatcher.handle(contents, enabled: enabled, policy: policy)
            await updateNotificationPermission(from: dispatcher)
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
        let watched = Set(servers.filter(\.watch).map(\.id))
        recordHistory { recorder in
            await recorder.observe(observation).compactMap { entry in
                // §42: watched servers get the more detailed watch notifications instead.
                if let id = entry.serverID, watched.contains(id), entry.kind == .banAppeared || entry.kind == .banLifted {
                    return nil
                }
                return NotificationPlanner.content(for: entry, serverLabel: entry.serverID.flatMap { labels[$0] })
            }
        }
    }

    // MARK: §42 watched servers

    /// Compares the finished checks with the baselines; watched servers get history entries and notifications.
    /// Every checked server's baseline is updated (turning watching on later starts from a known state).
    private func evaluateWatch(_ checks: [(UUID, BanCheck)]) {
        guard !checks.isEmpty else { return }
        var entries: [HistoryEntry] = []
        var contents: [NotificationContent] = []
        for (id, check) in checks {
            guard let entry = servers.first(where: { $0.id == id }) else { continue }
            let (next, events) = WatchTransitions.evaluate(previous: watchState[id], check: check)
            watchState[id] = next
            guard entry.watch else { continue }
            for event in events {
                entries.append(WatchTransitions.historyEntry(event, server: entry, at: check.checkedAt))
                contents.append(WatchNotificationText.content(for: event, server: entry))
            }
        }
        do {
            try WatchStateStore(fileURL: deps.paths.watchStateFile).save(watchState)
            watchStateSaveError = nil
        } catch {
            watchStateSaveError = error.localizedDescription
            logError(.watch, "watchState: \(error.localizedDescription)")
        }
        guard !entries.isEmpty else { return }
        let written = entries
        let notifications = contents
        recordHistory { recorder in
            for entry in written { await recorder.record(entry) }
            return notifications
        }
    }

    /// 🔔 "Bu sunucuyu izle"; saved with the record.
    func setWatch(_ watch: Bool, for id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }), servers[index].watch != watch else { return }
        servers[index].watch = watch
        markEdited()
    }

    var hasWatchedServers: Bool { servers.contains(where: \.watch) }

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
    /// The caller posts the notification, then calls `markAppealsNotified` with the ones actually posted.
    func dueAppealReminders() -> [AppealReminder.Due] {
        AppealReminder.due(servers, now: deps.now(), notificationsEnabled: notificationsEnabled)
    }

    /// Sets `notifiedAt` on the appeals. Returns `false` when the saved record could not be updated: the mark is
    /// then taken back in memory too, so the reminder stays pending instead of being lost after a relaunch.
    @discardableResult
    func markAppealsNotified(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        let now = deps.now()
        let previous = Dictionary(servers.filter { ids.contains($0.id) }.map { ($0.id, $0.appeal?.notifiedAt) },
                                  uniquingKeysWith: { first, _ in first })
        servers = AppealReminder.markNotified(ids, in: servers, at: now)
        // The reminder must not come back after a relaunch: `notifiedAt` goes straight into the saved record
        // (only for appeals already saved with the same follow-up date). It is not an "unsaved" change.
        guard var saved = snapshotState.snapshot else { return true }
        var changed = false
        for index in saved.servers.indices where ids.contains(saved.servers[index].id) {
            guard let stored = saved.servers[index].appeal,
                  stored.followUpAt == servers.first(where: { $0.id == saved.servers[index].id })?.appeal?.followUpAt else { continue }
            saved.servers[index].appeal?.notifiedAt = now
            changed = changed || stored.notifiedAt != now
        }
        guard changed else { return true }
        do {
            try deps.snapshotStore.save(saved)
        } catch {
            for index in servers.indices where servers[index].appeal?.notifiedAt == now {
                guard let old = previous[servers[index].id] else { continue }
                servers[index].appeal?.notifiedAt = old
            }
            return false
        }
        snapshotState = .loaded(saved)
        return true
    }

    /// §36: posts "İtiraz takibi: <server>" once per follow-up date (launch, refresh, menu bar timer).
    /// Only the reminders that were actually posted are marked notified: with the permission refused, during quiet
    /// hours or when the post fails they stay pending and the next check tries again.
    @discardableResult
    func checkAppealReminders() -> Task<Void, Never>? {
        // §45: during quiet hours the reminder stays pending (not marked notified) and fires later.
        guard !notificationPolicy.quiet.contains(deps.now()) else { return nil }
        let due = dueAppealReminders().filter { !appealRemindersInFlight.contains($0.serverID) }
        guard !due.isEmpty else { return nil }
        var serverByKey: [String: UUID] = [:]
        var followUps: [UUID: Date] = [:]
        let contents = due.compactMap { item -> NotificationContent? in
            guard let appeal = servers.first(where: { $0.id == item.serverID })?.appeal else { return nil }
            let content = AppealReminderText.content(for: item, status: appeal.status)
            serverByKey[content.key] = item.serverID
            followUps[item.serverID] = item.followUpAt
            return content
        }
        let ids = Set(serverByKey.values)
        guard !ids.isEmpty else { return nil }
        appealRemindersInFlight.formUnion(ids)
        let dispatcher = notificationDispatcher
        let enabled = notificationsEnabled
        let policy = notificationPolicy
        let previous = appealReminderTask
        let task = Task {
            await previous?.value
            let posted = await dispatcher.handle(contents, enabled: enabled, policy: policy)
            await updateNotificationPermission(from: dispatcher)
            appealRemindersInFlight.subtract(ids)
            // An appeal whose follow-up date changed meanwhile is armed for the new date: not marked.
            let sent = posted.compactMap { serverByKey[$0.key] }.filter { id in
                servers.first(where: { $0.id == id })?.appeal?.followUpAt == followUps[id]
            }
            markAppealsNotified(Set(sent))
        }
        appealReminderTask = task
        return task
    }

    /// For tests: waits until the running reminder check finishes.
    func waitForAppealReminders() async {
        await appealReminderTask?.value
    }

    /// Re-reads the notification permission (Settings > Notifications warns when it was refused).
    func refreshNotificationPermission() async {
        _ = await notificationDispatcher.currentAuthorization()
        await updateNotificationPermission(from: notificationDispatcher)
    }

    private func updateNotificationPermission(from dispatcher: NotificationDispatcher) async {
        guard let status = await dispatcher.lastAuthorization else { return }
        notificationPermissionDenied = status == .denied
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
                                                           now: deps.now(), errors: deps.errorLog.entries))
    }

    // MARK: §39 metrics

    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    /// Consecutive failed `metrics.jsonl` writes (server details show a line from the second one on).
    private(set) var metricsWriteFailure: MetricsRecorder.WriteFailure?

    /// Appends one sample per finished check, after the previous writes.
    private func recordMetrics(_ samples: [MetricSample]) {
        guard !samples.isEmpty else { return }
        let recorder = metrics
        let previous = metricsTask
        metricsTask = Task {
            await previous?.value
            metricsWriteFailure = await recorder.record(samples)
            if let failure = metricsWriteFailure { logError(.metrics, "metricsWrite: \(failure.reason)") }
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

    /// The data root choice is written to UserDefaults; rediscovery + refresh follow. Refused (nothing changes)
    /// while a restore or an erase runs, because the reload afterwards would mix it with the restored record.
    @discardableResult
    func setDataRoot(_ url: URL) -> Task<Void, Never> {
        guard !isDataOperationRunning else { return Task {} }
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

    /// §50: adds the imported candidates (label = host); entries that already exist (host + port) are skipped.
    /// The rows start unsaved and unchecked; the normal refresh fetches their A2S info. Returns the added count.
    /// §53 links may also set the label (instead of the host), the group and "watch" of every added row.
    @discardableResult
    func addServers(_ candidates: [ServerURLImport.Candidate], label: String? = nil, group: String? = nil,
                    watch: Bool = false) -> Int {
        var known = Set(servers.map { "\(HostValidator.normalized($0.host)):\($0.port)" })
        var added: [ServerEntry] = []
        var order = ServerOrganization.nextOrder(servers)
        let resolvedGroup = ServerOrganization.resolveGroup(group, existing: ServerOrganization.groups(servers))
        for candidate in candidates where known.insert(candidate.id).inserted {
            added.append(ServerEntry(label: label ?? candidate.label, host: candidate.host, port: candidate.port,
                                     group: resolvedGroup, order: order, watch: watch))
            order += 1
        }
        guard !added.isEmpty else { return 0 }
        servers.append(contentsOf: added)
        markEdited()
        reevaluate()
        for entry in added { resolveIfNeeded(entry.host) }
        return added.count
    }

    // MARK: §53 playeridentity:// links

    /// Result of the last handled link (the main window shows it once).
    var serverLinkOutcome: ServerLink.Outcome?

    /// `playeridentity://add?host=…`: the valid, new entries are added unsaved (like the §50 import); existing,
    /// repeated and invalid entries are reported. Refused while a data operation runs.
    @discardableResult
    func handleServerLink(_ url: URL) -> ServerLink.Outcome {
        var outcome = ServerLink.Outcome()
        if isDataOperationRunning {
            outcome.failure = L10n.text(.serverLinkBusy)
        } else {
            switch ServerLink.parse(url, existing: servers) {
            case .failure(let failure):
                outcome.failure = failure.text
            case .success(let request):
                let entries = request.entries
                outcome.added = addServers(entries.fresh, label: request.label, group: request.group, watch: request.watch)
                outcome.existing = entries.existing.count
                outcome.duplicates = entries.duplicates
                outcome.overflow = entries.overflow
                outcome.invalid = entries.invalid
            }
        }
        serverLinkOutcome = outcome
        return outcome
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
            logError(.login, "loginItem: \(error)")
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
        PlayerOptions.modelOptions(available: availableModels ?? [], current: config.model, sources: modelSources)
    }

    // MARK: userconfig.cfg override (§43.1)

    /// Keys (`name`, `model`) whose effective value comes from `userconfig.cfg`.
    var overriddenKeys: [String] {
        [configSources.name == .userconfig ? "name" : nil, configSources.model == .userconfig ? "model" : nil]
            .compactMap { $0 }
    }

    var hasConfigOverride: Bool { !overriddenKeys.isEmpty }

    /// Comments out the override lines (after the user confirmed), then re-reads the files.
    @discardableResult
    func removeOverride() -> Task<Void, Never>? {
        guard hasConfigOverride, !isApplying, let gamedir = selectedGamedir else { return nil }
        let gamedirURL = dataRoot.appendingPathComponent(gamedir, isDirectory: true)
        let keys = overriddenKeys
        let now = deps.now
        let remover = UserconfigOverrideRemover(detector: deps.gameProcessDetector, now: { now() })
        isApplying = true
        applyStatus = nil
        return Task {
            let result = await Task.detached { () -> Result<OverrideRemoval, EditMessage> in
                do {
                    return .success(try remover.remove(gamedir: gamedirURL, keys: keys))
                } catch let error as EditMessage {
                    return .failure(error)
                } catch {
                    return .failure(.writeFailed)
                }
            }.value
            isApplying = false
            switch result {
            case .success(let removal):
                applyStatus = .success(L10n.format(.configOverrideDone, removal.backupURL.lastPathComponent))
                let entry = HistoryEntry(ts: deps.now(), kind: .configOverrideRemoved,
                                         new: removal.keys.joined(separator: ", "),
                                         note: removal.backupURL.lastPathComponent)
                recordHistory { recorder in
                    await recorder.record(entry)
                    return []
                }
                isGameRunning = false
                await startRefresh(includeNetwork: isRefreshing).value
            case .failure(let error):
                applyStatus = .failure(error)
                if error == .gameRunning { isGameRunning = true }
            }
        }
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

    /// Only `profile.json` is written. Refused while a restore or an erase replaces the data files (the record
    /// would be overwritten or recreated half way through); the error is shown like any other save error.
    func save() {
        guard !isDataOperationRunning else {
            saveErrorMessage = L10n.text(.saveBusy)
            return
        }
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

    // MARK: Settings export / import (§46)

    /// Current preferences in archive form (`dataRoot` is filtered out by the builder unless requested).
    func currentArchivedSettings() -> ArchivedSettings {
        ArchivedSettings(language: appLanguage.rawValue,
                         notificationsEnabled: notificationsEnabled,
                         notifyBanChanges: notifyBanChanges,
                         notifyOnlineChanges: notifyOnlineChanges,
                         notifyMapChanges: notifyMapChanges,
                         quietHoursEnabled: quietHoursEnabled,
                         quietHoursStart: quietHoursStart,
                         quietHoursEnd: quietHoursEnd,
                         showInMenuBar: menuBarEnabled,
                         launchAtLogin: isLoginItemAvailable ? loginItemStatus.isOn : nil,
                         autoCheckUpdates: updates.preferences.autoCheck,
                         autoDownloadUpdates: updates.preferences.autoDownload,
                         banCheckEnabled: banCheckEnabled,
                         autoBackupEnabled: autoBackupEnabled,
                         gamedir: selectedGamedir,
                         dataRoot: dataRoot.path)
    }

    func settingsArchive(scope: SettingsArchiveScope, includeDataRoot: Bool) -> SettingsArchive {
        SettingsArchive.make(scope: scope, includeDataRoot: includeDataRoot, settings: currentArchivedSettings(),
                             servers: servers, appVersion: deps.appVersion, now: deps.now())
    }

    func importPreview(_ parsed: ParsedSettingsArchive, includeDataRoot: Bool) -> SettingsImportPreview {
        SettingsImportPreview.make(parsed, existing: servers, includeDataRoot: includeDataRoot)
    }

    /// Applies a validated archive. Replace first copies `profile.json` to `profile.json.appbak-<time>`; if that
    /// fails nothing is changed. The record is left "unsaved" and the files are re-read (refresh is started).
    ///
    /// Takes the data operation lock: refused (`busy`) while a restore, an erase, an install backup or an update
    /// runs, so the record, the data root and the server list never change under them. The summary names what was
    /// applied and skipped, the invalid values of the file and the side effects (data root, launch at login).
    func importSettings(_ parsed: ParsedSettingsArchive, mode: SettingsImportMode,
                        includeDataRoot: Bool) -> Result<SettingsImportSummary, SettingsImportError> {
        guard !updates.status.isUpdating, beginDataOperation(.importSettings) else { return .failure(.busy) }
        var summary = SettingsImportSummary()
        summary.invalidSettings = parsed.invalidSettings
        let settings = parsed.archive.settings
        let plan = parsed.archive.servers.map {
            ServerImportPlanner.plan(existing: servers, incoming: $0, invalidRows: parsed.invalidServers, mode: mode)
        }
        if mode == .replace, plan != nil {
            do {
                summary.backupFile = try RecordBackup.make(of: deps.paths.snapshotFile, at: deps.now())
            } catch {
                endDataOperation()
                return .failure(.backupFailed(error.localizedDescription))
            }
        }
        let report = applySettings(settings, includeDataRoot: includeDataRoot)
        summary.settingsApplied = report.applied
        summary.settingsSkipped = report.skipped
        summary.dataRootChanged = report.dataRootChanged
        summary.dataRootRejected = report.dataRootRejected
        summary.launchAtLoginChanged = report.launchAtLoginChanged
        if let plan {
            servers = plan.servers
            summary.added = plan.added
            summary.updated = plan.updated
            summary.skipped = plan.skipped
            for entry in plan.servers { resolveIfNeeded(entry.host) }
        }
        appliedSinceSave = true
        markEdited()
        reevaluate()
        endDataOperation()
        refresh()
        return .success(summary)
    }

    /// What `applySettings` did: carried values applied / skipped and the side effects worth naming.
    struct SettingsApplyReport: Sendable, Equatable {
        var applied = 0
        var skipped = 0
        var dataRootChanged: String?
        var dataRootRejected: String?
        var launchAtLoginChanged: Bool?
    }

    /// Applies every carried preference; missing values are left unchanged. `applied + skipped` equals
    /// `settings.count(includingDataRoot:)`.
    @discardableResult
    private func applySettings(_ settings: ArchivedSettings, includeDataRoot: Bool) -> SettingsApplyReport {
        var report = SettingsApplyReport()
        func apply<T>(_ value: T?, _ set: (T) -> Void) {
            guard let value else { return }
            set(value)
            report.applied += 1
        }
        if let value = settings.language {
            if let setting = AppLanguageSetting(rawValue: value) {
                appLanguage = setting
                report.applied += 1
            } else {
                report.skipped += 1   // unknown language (the parser already drops it)
            }
        }
        apply(settings.notificationsEnabled) { notificationsEnabled = $0 }
        apply(settings.notifyBanChanges) { notifyBanChanges = $0 }
        apply(settings.notifyOnlineChanges) { notifyOnlineChanges = $0 }
        apply(settings.notifyMapChanges) { notifyMapChanges = $0 }
        apply(settings.quietHoursEnabled) { quietHoursEnabled = $0 }
        apply(settings.quietHoursStart) { quietHoursStart = $0 }
        apply(settings.quietHoursEnd) { quietHoursEnd = $0 }
        apply(settings.showInMenuBar) { menuBarEnabled = $0 }
        if let value = settings.launchAtLogin {
            if !isLoginItemAvailable {
                report.skipped += 1
            } else if value == loginItemStatus.isOn {
                report.applied += 1
            } else {
                setLaunchAtLogin(value)
                if loginItemStatus.isOn == value {
                    report.applied += 1
                    report.launchAtLoginChanged = value
                } else {
                    report.skipped += 1   // refused: `loginItemError` shows why in Settings > General
                }
            }
        }
        apply(settings.autoCheckUpdates) { updates.preferences.autoCheck = $0 }
        apply(settings.autoDownloadUpdates) { updates.preferences.autoDownload = $0 }
        apply(settings.banCheckEnabled) { banCheckEnabled = $0 }
        apply(settings.autoBackupEnabled) { autoBackupEnabled = $0 }
        apply(settings.gamedir) { selectedGamedir = $0 }
        if includeDataRoot, let value = settings.dataRoot {
            if let folder = Self.importableDataRoot(value) {
                report.applied += 1
                if !ArchivedSettings.samePath(folder.path, dataRoot.path) {
                    dataRoot = folder
                    deps.defaults.set(dataRoot.path, forKey: Self.dataRootDefaultsKey)
                    report.dataRootChanged = folder.path
                }
            } else {
                report.skipped += 1
                report.dataRootRejected = value
            }
        }
        return report
    }

    /// An imported data root is applied only as an existing folder (not `/`, no `..` component).
    static func importableDataRoot(_ path: String) -> URL? {
        guard ArchivedSettings.isPlausibleDataRoot(path) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    // MARK: Reset and erase (Settings > Reset)

    /// "Reset Settings…": preferences return to their defaults. Servers, the record, identity history, the data root
    /// and the game folder are kept.
    func resetSettings() {
        applySettings(.defaults, includeDataRoot: false)   // `.defaults` also turns automatic backups back on
    }

    /// Home folder of the paths in use (for `~/…` display).
    var homeDirectory: URL { deps.paths.home }

    /// The app's own data folder (`~/Library/Application Support/tr.ercanatay.playeridentity`).
    var appDataFolder: URL { AppDataEraser(paths: deps.paths).directory }

    /// What "Erase All Data…" would remove (for the confirmation text).
    var eraseInventory: AppDataEraser.Inventory { AppDataEraser(paths: deps.paths).inventory() }

    /// "Erase All Data…": waits for queued writes, removes the app's own data folder contents (record with servers,
    /// identity history, metrics, watch state, backups, downloads) and starts over with an empty list. Game files,
    /// the data root and the preferences are not touched. Returns an error text, `nil` on success.
    ///
    /// Takes the same data operation lock as a restore (no restore, install, save or refresh meanwhile); the update
    /// state is checked again after waiting for the queued writes. If the folder cannot be listed nothing is removed
    /// and the model is unchanged. If only some items could be removed the error names what is left, and the model is
    /// reloaded from what is still on disk, so a later Save never writes back the erased state.
    func eraseAllData() async -> String? {
        guard !updates.status.isBusy else { return L10n.text(.eraseBusy) }
        guard beginDataOperation(.erase) else { return L10n.text(.restoreErrorBusy) }
        refreshTask?.cancel()
        generation += 1
        isRefreshing = false
        await historyTask?.value
        await metricsTask?.value
        guard !updates.status.isBusy else {
            endDataOperation()
            return L10n.text(.eraseBusy)
        }
        var failure: String?
        do {
            try AppDataEraser(paths: deps.paths, fileOperations: deps.dataFileOperations).erase()
        } catch let incomplete as AppDataEraser.Incomplete {
            failure = L10n.format(.eraseIncomplete, String(incomplete.removed), incomplete.remaining.joined(separator: ", "))
        } catch {
            endDataOperation()   // nothing was removed
            return L10n.format(.eraseFailed, error.localizedDescription)
        }
        await history.reset()
        await metrics.reset()
        metricsWriteFailure = nil
        reloadFromDisk(keepGamedirWithoutRecord: true)
        updates.dataFolderErased()
        refreshBackupInfo()
        endDataOperation()
        refresh()
        return failure
    }

    // MARK: §49 full data backup / restore

    var fullBackupStore: FullBackupStore { FullBackupStore(paths: deps.paths, appVersion: deps.appVersion) }

    /// Re-reads the automatic backup list (Settings > Data shows the newest one).
    func refreshBackupInfo() {
        let automatic = fullBackupStore.list(.automatic)
        automaticBackupCount = automatic.count
        latestAutomaticBackup = automatic.first.flatMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    typealias AutomaticBackupResult = Result<FullBackupStore.AutomaticOutcome, FullBackupError>

    /// §49.3 launch backup: with "Automatic backups" on, at most one successful attempt per local day
    /// (`auto-YYYYMMDD.zip`, skipped when the content did not change, the 5 newest kept). Runs off the main thread;
    /// `nil` if not due (or one is already running).
    ///
    /// The day is marked before the attempt (so a second launch path does not start another one) and the mark is
    /// taken back when the attempt fails: the error stays in `autoBackupLastError` (Settings > Data shows it with
    /// "Try Again") and the next launch tries again.
    @discardableResult
    func runAutomaticBackupIfDue() -> Task<AutomaticBackupResult, Never>? {
        guard autoBackupEnabled, !isDataOperationRunning, automaticBackupTask == nil else { return nil }
        let now = deps.now()
        let today = FullBackupNaming.day(now)
        let defaults = deps.defaults
        let previousRun = defaults.string(forKey: DefaultsKey.autoBackupLastRun)
        guard previousRun != today else { return nil }
        defaults.set(today, forKey: DefaultsKey.autoBackupLastRun)
        let store = fullBackupStore
        let task = Task { () -> AutomaticBackupResult in
            let result = await Task.detached { () -> AutomaticBackupResult in
                do {
                    return .success(try store.createAutomatic(now: now))
                } catch let error as FullBackupError {
                    return .failure(error)
                } catch {
                    return .failure(.writeFailed(error.localizedDescription))
                }
            }.value
            switch result {
            case .success:
                autoBackupLastError = nil
            case .failure(let error):
                autoBackupLastError = error
                logError(.backup, "autoBackup: \(error)")
                // Not done for today: the next launch (or "Try Again") makes another attempt.
                if defaults.string(forKey: DefaultsKey.autoBackupLastRun) == today {
                    if let previousRun {
                        defaults.set(previousRun, forKey: DefaultsKey.autoBackupLastRun)
                    } else {
                        defaults.removeObject(forKey: DefaultsKey.autoBackupLastRun)
                    }
                }
            }
            automaticBackupTask = nil
            refreshBackupInfo()
            return result
        }
        automaticBackupTask = task
        return task
    }

    /// "Try Again" next to a failed automatic backup (the failed attempt did not mark the day).
    @discardableResult
    func retryAutomaticBackup() -> Task<AutomaticBackupResult, Never>? {
        runAutomaticBackupIfDue()
    }

    /// "Back Up All Data…": waits for queued writes, then writes the ZIP to the chosen file.
    func writeFullBackup(to url: URL) async -> Result<FullBackupManifest, FullBackupError> {
        await historyTask?.value
        await metricsTask?.value
        let store = fullBackupStore
        let now = deps.now()
        let result = await Task.detached { () -> Result<FullBackupManifest, FullBackupError> in
            do {
                return .success(try store.write(to: url, now: now))
            } catch let error as FullBackupError {
                return .failure(error)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }.value
        if case .failure(let error) = result { logError(.backup, "manualBackup: \(error)") }
        return result
    }

    func fullBackupPreview(_ backup: ParsedFullBackup) -> FullBackupPreview {
        FullBackupPreview.make(backup, currentVersion: deps.appVersion)
    }

    /// Result of a completed restore.
    struct FullRestoreOutcome: Sendable, Equatable {
        /// `backups/pre-restore-…zip` (`nil` when there was no data to back up).
        var safetyBackup: URL?
        /// Folder that keeps the previous files the pre-restore backup could not include (unreadable or corrupt).
        var keptPrevious: URL?
    }

    /// "Restore from Backup…" (confirmed): refused while an update downloads/installs or another data operation
    /// runs. With `saveFirst` the unsaved changes are saved before anything else (so the pre-restore backup has
    /// them); a failed save stops the restore. Refreshing, saving and erasing are locked, queued writes finish, the
    /// current data goes to `backups/pre-restore-…zip`, then the validated files are put in place and everything is
    /// reloaded. If the files cannot be put in place the previous files are put back (`writeFailed`); if even that
    /// fails, `rollbackFailed` names the folder with the copies of the previous files.
    func restoreFullBackup(_ backup: ParsedFullBackup, saveFirst: Bool = false) async -> Result<FullRestoreOutcome, FullBackupError> {
        guard !updates.status.isUpdating else { return .failure(.updateRunning) }
        guard !isDataOperationRunning, !updates.isDataOperationRunning else { return .failure(.busy) }
        if saveFirst, hasUnsavedChanges {
            save()
            if let message = saveErrorMessage {
                saveErrorMessage = nil   // shown in the restore sheet instead of the main window alert
                return .failure(.saveFailed(message))
            }
        }
        guard beginRestoreLock() else { return .failure(.busy) }
        let result = await performRestore(backup)
        endRestoreLock()
        refreshBackupInfo()
        switch result {
        case .success: refresh()
        case .failure(let error): logError(.backup, "restore: \(error)")
        }
        return result
    }

    /// Takes the data operation lock (§47.2/§49.2): locks refreshing, saving, the data root, installing, automatic
    /// backups and every other data operation. `false` if one is already running (restore, erase or install backup).
    func beginDataOperation(_ operation: DataOperation) -> Bool {
        guard dataOperation == nil, !updates.isDataOperationRunning else { return false }
        dataOperation = operation
        updates.isDataOperationRunning = true
        return true
    }

    func endDataOperation() {
        dataOperation = nil
        updates.isDataOperationRunning = false
    }

    /// The restore's data operation lock; `false` if a data operation is already running.
    func beginRestoreLock() -> Bool { beginDataOperation(.restore) }

    func endRestoreLock() { endDataOperation() }

    private func performRestore(_ backup: ParsedFullBackup) async -> Result<FullRestoreOutcome, FullBackupError> {
        refreshTask?.cancel()
        generation += 1
        isRefreshing = false
        await historyTask?.value
        await metricsTask?.value
        guard !updates.status.isUpdating else { return .failure(.updateRunning) }
        var configured = fullBackupStore
        configured.fileOperations = deps.dataFileOperations
        let store = configured
        let now = deps.now()
        defer { restoreStep = nil }
        // Both steps run off the main thread in detached tasks: they are never cancelled halfway (the restore
        // completes or rolls back) and the window stays responsive meanwhile.
        restoreStep = .backingUp
        let created = await Task.detached { () -> Result<FullBackupStore.Created, FullBackupError> in
            do {
                return .success(try store.createBackup(.preRestore, now: now))
            } catch {
                return .failure(.preRestoreBackupFailed(error.localizedDescription))
            }
        }.value
        let safety: FullBackupStore.Created
        switch created {
        case .success(let value): safety = value
        case .failure(let error): return .failure(error)
        }
        restoreStep = .replacing
        // Files the pre-restore backup could not include are kept next to the data instead of being removed.
        let keepPrevious = !safety.skipped.isEmpty
        let restored = await Task.detached { () -> Result<URL?, FullBackupError> in
            do {
                return .success(try store.restore(backup, keepPrevious: keepPrevious))
            } catch let error as FullBackupError {
                return .failure(error)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }.value
        let kept: URL?
        switch restored {
        case .success(let url):
            kept = url
        case .failure(let error):
            await history.reset()
            await metrics.reset()
            metricsWriteFailure = nil
            return .failure(error)
        }
        await history.reset()
        await metrics.reset()
        metricsWriteFailure = nil
        reloadFromDisk(keepGamedirWithoutRecord: false)
        return .success(FullRestoreOutcome(safetyBackup: safety.url, keptPrevious: kept))
    }

    /// After a restore or an erase: record, servers, game folder and watch state come from the files on disk.
    /// `keepGamedirWithoutRecord`: without a record the chosen game folder stays (erase); a restore takes it from the
    /// restored record only.
    private func reloadFromDisk(keepGamedirWithoutRecord: Bool) {
        let loaded = deps.snapshotStore.load()
        snapshotState = loaded
        let snapshot = loaded.snapshot
        servers = snapshot?.servers ?? []
        if snapshot != nil || !keepGamedirWithoutRecord {
            selectedGamedir = (snapshot?.gamedir).flatMap { $0.isEmpty ? nil : $0 }
        }
        if (deps.defaults.string(forKey: Self.dataRootDefaultsKey) ?? "").isEmpty, let snapshot, !snapshot.dataRoot.isEmpty {
            dataRoot = URL(fileURLWithPath: snapshot.dataRoot, isDirectory: true)
        }
        watchState = WatchStateStore(fileURL: deps.paths.watchStateFile).load()
        for entry in servers { resolveIfNeeded(entry.host) }
        editedWithoutSnapshot = false
        appliedSinceSave = false
        fixedSinceSave = false
        saveErrorMessage = nil
        historyRevision += 1
        updates.evaluateRestore(snapshot: loaded)
        reevaluate()
    }

    // MARK: §54 error log

    /// The app's error log (diagnostics `errors.json`).
    var errorLog: ErrorLog { deps.errorLog }

    /// Records an error for the diagnostics package only; nothing is shown to the user.
    func logError(_ area: ErrorLogArea, _ message: String) {
        deps.errorLog.record(area, message, at: deps.now())
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

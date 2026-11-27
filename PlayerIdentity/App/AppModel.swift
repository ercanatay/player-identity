import AppKit
import Foundation
import Observation
import os

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
    /// §60: clipboard of the menu bar copy items (the default write fails; real one in `live()`).
    var pasteboard: any PasteboardWriting = UnavailablePasteboard()
    /// §37: interfaces + egress interface (`getifaddrs` + route lookup; read-only, nothing is sent).
    var interfaceReporter = InterfaceReporter()
    /// §47.2/§49: file operations of "Erase All Data" and the restore (tests inject failures).
    var dataFileOperations: any DataFileOperating = LocalDataFileOperations()
    /// §54: log of the last app errors (diagnostics `errors.json`); the live app persists it to `errors.json`.
    var errorLog = ErrorLog()
    /// §67.2: starts Xash3D with `-condebug` (the default never starts anything; NSWorkspace in `live()`), and the
    /// modification date of the engine log it waits for.
    var appLauncher: any AppLaunching = UnavailableAppLauncher()
    var fileDating: any FileDating = LocalFileDating()
    /// §67.4: the Spotlight index of the servers (the default indexes nothing; CoreSpotlight in `live()`).
    var spotlightIndexer: any SpotlightIndexing = NoopSpotlightIndexer()
    /// §68.2: HTTPS GET of the ban record (the default fails as a network error; `URLSession` in `live()`) and the
    /// store of its bearer tokens (in memory by default; the Keychain in `live()`).
    var banRecordHTTP: any BanRecordHTTP = UnavailableBanRecordHTTP()
    var secretStore: any SecretStoring = InMemorySecretStore()
    /// §72.1: store of the RCON passwords (account `rcon.<serverID>`; in memory by default, the Keychain in `live()`).
    var rconSecretStore: any SecretStoring = InMemorySecretStore()
    /// §69.2: asks WidgetKit to reload the widget after `widget-snapshot.json` was written (no-op unless injected).
    var widgetReloader: any WidgetReloading = NoopWidgetReloader()
    /// §70.1: the GoldSrc master server of "Find Servers" (tests point it at an IP literal behind the fake transport).
    var masterServerHost = MasterServerQuery.defaultHost
    var masterServerPort = MasterServerQuery.defaultPort
    /// §71: file access of the sync folder (tests inject failures and slow disks).
    var syncFolderAccess: any SyncFolderAccessing = LocalSyncFolderAccess()
    /// §73: read-only probe of the engine bundle and the identity files (the default sees nothing; `lstat`/`pread` in
    /// `live()`).
    var fileProbe: any ReadOnlyFileProbing = UnavailableFileProbe()
    /// §74 "Install Compatible Engine": builds the installer of one environment (the default downloads and writes
    /// nothing; the real GitHub/tar/codesign installer in `live()`), the file operations of the engine backup
    /// inventory (only under `engine-backups` of `paths`) and the Mac's architecture (Intel installs stay closed).
    var engineInstallerFactory: EngineInstallerFactory = { _ in UnavailableEngineInstaller() }
    var engineFileOperations: any EngineFileOperating = LocalEngineFileOperations()
    var engineArchitecture: EngineArchitecture = .current()

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
        deps.errorLog = ErrorLog(fileURL: paths.errorsFile)
        deps.pasteboard = SystemPasteboard()
        return deps
    }

    static func live() -> AppDependencies {
        let paths = AppPaths()
        var deps = AppDependencies(paths: paths,
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
        deps.errorLog = ErrorLog(fileURL: paths.errorsFile)
        deps.pasteboard = SystemPasteboard()
        deps.appLauncher = WorkspaceAppLauncher()
        deps.spotlightIndexer = CoreSpotlightIndexer()
        deps.banRecordHTTP = URLSessionBanRecordHTTP()
        deps.secretStore = KeychainSecretStore()
        deps.rconSecretStore = KeychainSecretStore(service: RconKeychain.service)
        deps.widgetReloader = WidgetCenterReloader()
        deps.fileProbe = LocalFileProbe()
        deps.engineInstallerFactory = { EngineInstaller.live(environment: $0) }
        return deps
    }
}

/// Refresh orchestration, status and persistence (§5, §6, §8).
@MainActor
@Observable
final class AppModel {
    static let dataRootDefaultsKey = DefaultsKey.dataRoot
    static let banCheckDefaultsKey = DefaultsKey.banCheckEnabled
    static let recentNamesDefaultsKey = DefaultsKey.recentNames

    /// Data root and game folder of the active profile (§61); every change is mirrored into `profileList`.
    private(set) var dataRoot: URL {
        didSet { if dataRoot != oldValue { profileList.updateActive(dataRoot: dataRoot) } }
    }
    private(set) var gamedirs: [String] = []
    private(set) var selectedGamedir: String? {
        didSet { if selectedGamedir != oldValue { profileList.updateActive(gamedir: .some(selectedGamedir)) } }
    }
    /// §61 profiles (the first one is the default); kept in `profile.json` next to the record.
    private(set) var profileList: ProfileList
    /// §61: why the last profile change was refused (shown once by the window that asked).
    var profileError: ProfileError?
    /// `nil` = not read yet.
    private(set) var identity: Result<Identity, IdentityError>?
    private(set) var config = PlayerConfig()
    private(set) var lanAddresses: [LocalAddress] = []
    /// Public IP fetched in the last refresh; `nil` = could not be fetched or not checked yet.
    private(set) var publicIP: String?
    private(set) var servers: [ServerEntry] {
        didSet { if servers != oldValue { syncSpotlight() } }
    }
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
    /// §60: row selected in the main window's server table (the menu bar "Copy CID" target); not saved.
    var selectedServerID: UUID?
    /// §60: result of the last menu bar copy ("Copied" for 2 seconds, a failure until the next copy).
    private(set) var menuBarCopyFeedback: MenuBarCopyFeedback?
    @ObservationIgnored private var menuBarFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTasksActive = false

    // MARK: §29 join the game
    /// `Xash3D-FWGS.app` was found; "Join Game" is hidden otherwise.
    private(set) var isGameAppInstalled = false
    struct JoinRequest: Identifiable, Equatable {
        let id = UUID()
        let serverID: UUID
        let label: String
        /// §75.4 the address the user is asked about; the confirmation rebuilds the plan for it with the protocol
        /// known at that moment (a protocol learned while the question was open is used).
        var host: String = ""
        var port: Int = ServerEntry.defaultPort
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

    // MARK: §70 server browser

    /// "Find Servers" window (master list + A2S_INFO); see `ServerBrowserController`.
    let serverBrowser: ServerBrowserController

    // MARK: §71 folder sync

    /// The chosen sync folder (`nil` = sync off), kept in UserDefaults.
    private(set) var syncFolder: URL?
    private(set) var isSyncing = false
    /// End of the last successful sync (this launch).
    private(set) var syncLastSuccess: Date?
    /// Why the last sync stopped; cleared by the next successful one.
    private(set) var syncError: FolderSyncError?
    /// Records where both sides had the same stamp but different content (the local copy was kept), this launch.
    private(set) var syncConflictCount = 0
    /// Finished sync runs that reached the folder (tests).
    private(set) var syncRunCount = 0
    @ObservationIgnored private var syncDebounce = SyncDebounce()
    @ObservationIgnored private var syncTimerTask: Task<Void, Never>?
    @ObservationIgnored private var syncRunTask: Task<Void, Never>?
    @ObservationIgnored private var syncRequestedDuringRun = false

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
    /// §75.4 newest decided A2S protocol per server (refresh, recheck, diagnosis); never saved.
    @ObservationIgnored private(set) var protocolMemory = ServerProtocolMemory()
    /// §75.13 last "Join Game" (gs) per server in this session: an older engine log block is stale.
    @ObservationIgnored private(set) var goldSrcJoins: [UUID: Date] = [:]
    /// §75.13 last successful resolution per hostname (a later DNS failure must not hide the engine log evidence).
    @ObservationIgnored private var lastResolvedAddresses: [String: String] = [:]
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

        // §61: the active profile decides the data root and the game folder; a record without profiles migrates its
        // single `dataRoot`/`gamedir` into `Default` (written with the next record write).
        let list = ProfileList.resolve(snapshot: snapshot,
                                       storedDataRoot: dependencies.defaults.string(forKey: Self.dataRootDefaultsKey),
                                       defaultDataRoot: dependencies.paths.defaultDataRoot, now: dependencies.now())
        profileList = list
        dataRoot = list.active.dataRootURL(defaultDataRoot: dependencies.paths.defaultDataRoot)
        selectedGamedir = list.active.preferredGamedir
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
        let soonEnabled = defaults.object(forKey: DefaultsKey.banExpirySoonEnabled) as? Bool ?? true
        banExpirySoonEnabled = soonEnabled
        banExpiryWatches = BanExpiryPlanner.prune(snapshot?.banExpiryWatch ?? [],
                                                  serverIDs: Set((snapshot?.servers ?? []).map(\.id)),
                                                  soonEnabled: soonEnabled, now: dependencies.now())
        recentNames = dependencies.defaults.stringArray(forKey: Self.recentNamesDefaultsKey) ?? []
        menuBarEnabled = MenuBarPreferences(defaults: dependencies.defaults).showInMenuBar
        watchState = WatchStateStore(fileURL: dependencies.paths.watchStateFile).load()
        appLanguage = AppLanguageSetting(defaults: dependencies.defaults)
        L10n.setting = AppLanguageSetting(defaults: dependencies.defaults)
        isGameAppInstalled = dependencies.gameAppLocator.locate() != nil
        loginItemStatus = dependencies.loginItem?.status() ?? .notRegistered
        updates = UpdateController(dependencies: dependencies)
        serverBrowser = ServerBrowserController(dependencies: dependencies)
        updates.evaluateRestore(snapshot: loaded)
        updates.onUpdateFound = { [weak self] version in
            self?.recordHistory { recorder in
                await recorder.recordUpdate(version: version)
                return []
            }
        }
        refreshBackupInfo()
        reindexSpotlight()
        syncFolder = dependencies.defaults.string(forKey: DefaultsKey.syncFolder).flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
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
        // §73: the tri-state, so a process list that cannot be read never shows the engine as closed.
        let (profile, processState) = await Task.detached {
            (loader.load(dataRoot: root, preferredGamedir: preferred), detector.engineProcessState())
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
        syncEngineProcessState(processState)
        loadPreviews(resetting: gamedirChanged)
        // §73: the macOS identity health check runs next to the network steps (read-only, no network).
        refreshMacIdentity()

        if includeNetwork {
            // §20: resolve hostnames first (cached); CIDs and ban checks use the resolved address.
            let resolved = await hostCache.resolveAll(servers.map(\.host))
            guard current == generation else { return }
            hostResolutions.merge(resolved) { _, new in new }
            for (name, resolution) in resolved { if let text = resolution.address?.text { lastResolvedAddresses[name] = text } }

            // §75.4 the saved rows' decided protocols seed this session's memory (they survive a restart).
            for entry in servers {
                protocolMemory.record(StatusEvaluator.protocolOf(entry), for: entry.id, host: entry.host, port: entry.port,
                                      at: entry.banCheck?.checkedAt ?? .distantPast)
            }

            // §13 ban check: in parallel with the other network steps; cancelled together with the refresh.
            let banRequests = banCheckEnabled
                ? BanCheckRunner.requests(servers: servers, rawID: try? profile.identity.get().rawID,
                                          name: profile.config.name, resolutions: hostResolutions,
                                          knownProtocols: knownProtocols())
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

            var bans = await banResults
            guard current == generation else { return }
            let now = deps.now()

            // §75.4 a server known as GoldSrc 48 keeps that protocol when this check decided none (time-out, damaged
            // reply): its result carries it, so the CID stays N/A and Join Game keeps `gs` (also after a restart).
            for request in banRequests {
                guard var fresh = bans[request.serverID], (fresh.info?.serverProtocol ?? .unknown) == .unknown,
                      launchProtocol(for: request.serverID) == .goldsrc48 else { continue }
                var info = fresh.info ?? ServerInfo()
                info.serverProtocol = .goldsrc48
                fresh.info = info
                bans[request.serverID] = fresh
            }

            // §75.13 the engine log is read once and judged per server, independent of the network results: a ban of
            // this server's last GoldSrc block applies even when A2S timed out, the server was just added or no
            // check ran; a proven ban is kept until a newer engine session or a fresh Source 49 result replaces it.
            let fileSystem = deps.fileSystem
            let root = dataRoot
            let read = await Task.detached { GoldSrcEngineLog.read(dataRoot: root, fileSystem: fileSystem) }.value
            guard current == generation else { return }
            if case .unreadable(let reason) = read { logError(.serverProtocol, "engineLog: " + reason) }
            var logChecks: [UUID: BanCheck] = [:]
            for entry in servers {
                let fresh = bans[entry.id]
                // A fresh Source 49 result wins over any older GoldSrc evidence.
                if fresh?.info?.serverProtocol == .source49 { continue }
                let evidence = read.text.flatMap {
                    GoldSrcEngineLog.evidence(
                        in: $0, addresses: goldSrcLogAddresses(entry),
                        now: now, notBefore: goldSrcJoins[entry.id], redactor: Redactor(home: deps.paths.home))
                }
                if let evidence, evidence.outcome == .banned {
                    var info = fresh?.info ?? entry.banCheck?.info ?? ServerInfo()
                    info.serverProtocol = .goldsrc48   // the engine connected with the GoldSrc 48 protocol
                    logChecks[entry.id] = BanCheck(status: .goldSrcBanned, checkedAt: now,
                                                   detail: "ipOk → goldSrcBanned: " + evidence.reason, info: info)
                    continue
                }
                guard let previous = entry.banCheck, previous.status == .goldSrcBanned else { continue }
                let newerSession = evidence.map { $0.sessionStart > previous.checkedAt } ?? false
                if !newerSession { logChecks[entry.id] = previous }
            }
            for (id, check) in logChecks where banRequests.contains(where: { $0.serverID == id }) { bans[id] = check }

            var samples: [MetricSample] = []
            var goldSrcIDs: Set<UUID> = []
            for request in banRequests {
                guard let check = bans[request.serverID],
                      let index = servers.firstIndex(where: { $0.id == request.serverID }),
                      servers[index].host == request.host, servers[index].port == request.port else { continue }
                servers[index].banCheck = check
                noteProtocol(check, for: servers[index])
                if check.info?.serverProtocol == .goldsrc48 { goldSrcIDs.insert(request.serverID) }
                samples.append(MetricSample(check: check, serverID: request.serverID, host: request.host))
            }
            // Servers without a check this time (no request, throttled, checks off): the engine log still decides.
            for (id, check) in logChecks where !banRequests.contains(where: { $0.serverID == id }) {
                guard let index = servers.firstIndex(where: { $0.id == id }) else { continue }
                servers[index].banCheck = check
                noteProtocol(check, for: servers[index])
                goldSrcIDs.insert(id)
            }
            // §75.3/§75.4: the GoldSrc decision (protocol + ban result) and the removal of the legacy CID are written
            // to the saved record together (only on this successful GoldSrc result; a failed refresh removes nothing).
            persistGoldSrcDecisions(goldSrcIDs)
            recordMetrics(samples)
            evaluateWatch(banRequests.compactMap { request in bans[request.serverID].map { (request.serverID, $0) } })

            lastChecked = now
            for index in servers.indices { servers[index].lastCheckedAt = now }
        }

        // 5–6. CIDs + comparison
        isRefreshing = false
        reevaluate()
        if includeNetwork { recordRefreshHistory() }
        checkAppealReminders()
        writeWidgetSnapshot()
        checkBanExpiryNotifications()
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
                                   resolutions: hostResolutions,
                                   knownProtocols: knownProtocols())
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
            if let text = resolution.address?.text { lastResolvedAddresses[name] = text }
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
        let tag = profileTag
        historyTask = Task {
            await previous?.value
            await recorder.setProfile(tag)
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
        let overrides = serverNotificationOverrides()
        recordHistory { recorder in
            await recorder.observe(observation).compactMap { entry in
                // §42: watched servers get the more detailed watch notifications instead.
                if let id = entry.serverID, watched.contains(id), entry.kind == .banAppeared || entry.kind == .banLifted {
                    return nil
                }
                var content = NotificationPlanner.content(for: entry, serverLabel: entry.serverID.flatMap { labels[$0] })
                // §56: ban notifications of a server follow its override (mode, quiet hours).
                if content?.category == .ban, let id = entry.serverID { content?.server = overrides[id] }
                return content
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
                // §56: the history entry is always written; an event below the server's thresholds is not notified.
                entries.append(WatchTransitions.historyEntry(event, server: entry, at: check.checkedAt))
                guard ServerNotificationRules.passesThresholds(event, settings: entry.notifications, info: check.info) else {
                    continue
                }
                var content = WatchNotificationText.content(for: event, server: entry)
                content.server = entry.notifications
                contents.append(content)
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

    // MARK: §56 per-server notification thresholds

    private func serverNotificationOverrides() -> [UUID: ServerNotificationSettings] {
        Dictionary(servers.compactMap { entry in entry.notifications.map { (entry.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Sets the server's notification override ("Bildirimler" in the details); the default settings are stored as
    /// `nil` (inherit). Invalid thresholds are rejected and nothing changes. Saved with the record.
    @discardableResult
    func setServerNotifications(_ settings: ServerNotificationSettings, for id: UUID) -> Bool {
        guard settings.isValid else { return false }
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return false }
        let stored: ServerNotificationSettings? = settings.isDefault ? nil : settings
        guard servers[index].notifications != stored else { return true }
        servers[index].notifications = stored
        markEdited()
        return true
    }

    // MARK: §40 ban list URL

    /// §59 "Apply to all servers": validates once, then sets (or clears) the template on every row.
    @discardableResult
    func applyBanListURLToAll(_ template: String) -> BanListTemplateError? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        var stored: String?
        if !trimmed.isEmpty {
            switch BanListTemplate.validate(trimmed) {
            case .success(let valid): stored = valid
            case .failure(let error): return error
            }
        }
        var changed = false
        for index in servers.indices where servers[index].banListURL != stored {
            servers[index].banListURL = stored
            changed = true
        }
        if changed { markEdited() }
        return nil
    }

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

    /// Matrix rows (banned first); range bans come from the history of fix attempts, §66.1 the "Last 7 days"
    /// column from the `diagnose` lines (§65 trend).
    func banMatrixRows() async -> [BanMatrixRow] {
        let history = await loadHistory()
        let recent = BanMatrixRecent.make(entries: history, serverIDs: servers.map(\.id), now: deps.now())
        return BanMatrix.rows(servers: servers, rangeBans: BanMatrix.rangeBans(from: history), recent: recent)
    }

    // MARK: §41 diagnostics

    /// The diagnostics ZIP (app info, redacted record, history/metrics tails, update state).
    func diagnosticsArchive(appInfo: DiagnosticsAppInfo = .current()) async -> Data {
        await historyTask?.value
        await metricsTask?.value
        return DiagnosticsBundle.archive(DiagnosticsInput(appInfo: appInfo, paths: deps.paths, defaults: deps.defaults,
                                                           now: deps.now(), errors: deps.errorLog.entries,
                                                           errorLogStatus: deps.errorLog.status))
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
        let tagged = samples.map { $0.tagged(profileTag) }
        metricsTask = Task {
            await previous?.value
            metricsWriteFailure = await recorder.record(tagged)
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
        // §61: the active profile keeps the new data root across launches (like the UserDefaults value).
        persistProfiles()
        markEdited()
        return refresh()
    }

    // MARK: §61 profiles

    var profiles: [Profile] { profileList.profiles }
    var activeProfile: Profile { profileList.active }
    var defaultProfileID: UUID { profileList.defaultProfile.id }
    /// Stamp of the history entries and metric samples written now.
    var profileTag: ProfileTag { ProfileTag(profileList.active) }
    /// The default data root (a profile without its own data root uses it).
    var defaultDataRoot: URL { deps.paths.defaultDataRoot }

    /// Writes the profile list into the saved record (the rest of the record is unchanged). Without a readable
    /// record the list is written with the first Save.
    @discardableResult
    private func persistProfiles() -> Bool {
        guard var saved = snapshotState.snapshot else { return true }
        guard saved.profiles != profileList.profiles || saved.activeProfileID != profileList.activeID else { return true }
        saved.profiles = profileList.profiles
        saved.activeProfileID = profileList.activeID
        do {
            try deps.snapshotStore.save(saved)
        } catch {
            saveErrorMessage = L10n.format(.saveFailed, error.localizedDescription)
            return false
        }
        snapshotState = .loaded(saved)
        scheduleSync()
        return true
    }

    /// A profile switch changes which files are read and written; refused while the game runs or data is replaced.
    private func profileSwitchProblem() -> ProfileError? {
        if isDataOperationRunning { return .busy }
        if deps.gameProcessDetector.isGameRunning() {
            isGameRunning = true
            return .gameRunning
        }
        return nil
    }

    /// Runs a profile change; a refused change is kept in `profileError` and returned.
    @discardableResult
    private func changeProfiles(_ change: (inout ProfileList) throws(ProfileError) -> Void) -> ProfileError? {
        var list = profileList
        do {
            try change(&list)
        } catch {
            profileError = error
            return error
        }
        profileList = list
        profileError = nil
        persistProfiles()
        return nil
    }

    /// Activates a profile: identity source, game folder and data root are resolved again and the CIDs recomputed
    /// from local files (no network request). The server list stays (it is shared).
    @discardableResult
    func activateProfile(_ id: UUID) -> ProfileError? {
        guard id != profileList.activeID else { return nil }
        if let problem = profileSwitchProblem() {
            profileError = problem
            return problem
        }
        if let error = changeProfiles({ (list: inout ProfileList) throws(ProfileError) in try list.activate(id) }) {
            return error
        }
        applyActiveProfile()
        return nil
    }

    /// Adds a profile (not activated). The same data root + game folder pair cannot be added twice.
    @discardableResult
    func addProfile(name: String, dataRoot: URL?, gamedir: String) -> ProfileError? {
        if isDataOperationRunning { return reject(.busy) }
        let now = deps.now()
        return changeProfiles { (list: inout ProfileList) throws(ProfileError) in
            try list.add(name: name, dataRoot: dataRoot?.path, gamedir: gamedir, now: now)
        }
    }

    @discardableResult
    func renameProfile(_ id: UUID, to name: String) -> ProfileError? {
        if isDataOperationRunning { return reject(.busy) }
        return changeProfiles { (list: inout ProfileList) throws(ProfileError) in try list.rename(id, to: name) }
    }

    @discardableResult
    func makeDefaultProfile(_ id: UUID) -> ProfileError? {
        if isDataOperationRunning { return reject(.busy) }
        return changeProfiles { (list: inout ProfileList) throws(ProfileError) in try list.makeDefault(id) }
    }

    /// Deletes a profile (cannot be undone). Deleting the active profile activates the default one, so it is refused
    /// while the game runs.
    @discardableResult
    func deleteProfile(_ id: UUID) -> ProfileError? {
        let wasActive = id == profileList.activeID
        if wasActive, let problem = profileSwitchProblem() { return reject(problem) }
        if isDataOperationRunning { return reject(.busy) }
        if let error = changeProfiles({ (list: inout ProfileList) throws(ProfileError) in try list.remove(id) }) {
            return error
        }
        if wasActive { applyActiveProfile() }
        return nil
    }

    private func reject(_ error: ProfileError) -> ProfileError {
        profileError = error
        return error
    }

    /// The active profile's data root and game folder take effect; local files are read again (no network request).
    private func applyActiveProfile() {
        let profile = profileList.active
        dataRoot = profile.dataRootURL(defaultDataRoot: deps.paths.defaultDataRoot)
        selectedGamedir = profile.preferredGamedir
        deps.defaults.set(dataRoot.path, forKey: Self.dataRootDefaultsKey)
        markEdited()
        _ = startRefresh(includeNetwork: isRefreshing)
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

    /// Any `playeridentity:` URL: §69.2 `show` (the widget) only brings up the main window; the rest is a §53 link.
    /// Returns `nil` for `show` (nothing to report).
    @discardableResult
    func handleOpenURL(_ url: URL) -> ServerLink.Outcome? {
        if ServerLink.isShowLink(url) { return nil }
        return handleServerLink(url)
    }

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
        // §75.4: the newest A2S result decides `gs` (GoldSrc 48); `unknown` launches like `source49`.
        let serverProtocol = launchProtocol(for: id)
        let root = dataRoot
        let task = Task {
            defer { joinTask = nil }
            do {
                let plan = try await launcher.plan(host: entry.host, port: entry.port, gamedir: gamedir, known: known,
                                                   serverProtocol: serverProtocol, dataRoot: root)
                if plan.gameRunning {
                    pendingJoin = JoinRequest(serverID: id, label: entry.label, host: entry.host, port: entry.port,
                                              plan: plan)
                } else {
                    try await launcher.launch(plan) { true }
                    noteGoldSrcJoin(plan, for: id)
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
        // §75.4: the server must still be the one asked about; the plan is rebuilt with the protocol known now.
        guard let entry = servers.first(where: { $0.id == request.serverID }), entry.host == request.host,
              entry.port == request.port else {
            joinError = .cancelled
            return nil
        }
        let launcher = gameLauncher
        let gamedir = selectedGamedir
        let known = hostResolutions
        let serverProtocol = launchProtocol(for: entry.id)
        let root = dataRoot
        return Task {
            do {
                let plan = try await launcher.plan(host: entry.host, port: entry.port, gamedir: gamedir, known: known,
                                                   serverProtocol: serverProtocol, dataRoot: root)
                try await launcher.launch(plan) { true }
                noteGoldSrcJoin(plan, for: request.serverID)
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

    // MARK: §60 menu bar quick CID

    /// CID copied for a row: the current one, else the CID saved with the row.
    func menuBarCID(for id: UUID) -> String? {
        guard let entry = servers.first(where: { $0.id == id }), !isCIDNotApplicable(id) else { return nil }
        let cid = rowStatus(id)?.currentCID ?? entry.cid
        return cid.isEmpty ? nil : cid
    }

    var menuBarRawID: String? { try? identity?.get().rawIDHex }

    func canRecheckServer(_ id: UUID) -> Bool {
        banCheckEnabled && !isFixRunning && !isDataOperationRunning && banRequest(for: id) != nil
    }

    /// Top items of the menu bar menu (empty while the menu bar mode is off).
    var menuBarQuickItems: [MenuBarQuickItem] {
        let choices = servers.map { entry in
            MenuBarServerChoice(id: entry.id, label: entry.label, cid: menuBarCID(for: entry.id),
                                canRecheck: canRecheckServer(entry.id), canDiagnose: canDiagnoseFromMenuBar(entry.id),
                                diagnosis: menuBarDiagnoses[entry.id])
        }
        return MenuBarQuickMenu.items(enabled: menuBarEnabled, statusTitle: menuBarPresentation.title,
                                      lastChecked: lastChecked, servers: choices, selected: selectedServerID,
                                      rawID: menuBarRawID, feedback: menuBarCopyFeedback, now: deps.now())
    }

    /// Copies a CID or the raw identity. A clipboard failure is shown in the menu and recorded in the error log.
    @discardableResult
    func menuBarCopy(_ kind: MenuBarCopyKind) -> Bool {
        let text: String?
        switch kind {
        case .cid(let id): text = menuBarCID(for: id)
        case .rawID: text = menuBarRawID
        }
        guard let text else { return false }
        menuBarFeedbackTask?.cancel()
        menuBarFeedbackTask = nil
        let at = deps.now()
        guard deps.pasteboard.write(text) else {
            menuBarCopyFeedback = .failed(kind, at: at)
            let what: String
            switch kind {
            case .cid: what = "cid"
            case .rawID: what = "rawID"
            }
            logError(.clipboard, "menuBarCopy(\(what)): pasteboardWriteFailed")
            return false
        }
        let feedback = MenuBarCopyFeedback.copied(kind, at: at)
        menuBarCopyFeedback = feedback
        let sleeper = deps.sleeper
        menuBarFeedbackTask = Task { [weak self] in
            try? await sleeper.sleep(seconds: MenuBarCopyFeedback.confirmationDuration)
            guard !Task.isCancelled, let self, self.menuBarCopyFeedback == feedback else { return }
            self.menuBarCopyFeedback = nil
        }
        return true
    }

    /// Called once by the app (not in tests): starts the 30-minute refresh if the menu bar mode is on.
    func activateBackgroundTasks() {
        backgroundTasksActive = true
        checkAppealReminders()
        // §69.1: the saved ban expiries are planned again at launch (no scheduled local notifications).
        if checkBanExpiryNotifications() == nil { scheduleBanExpiryTimer() }
        if menuBarEnabled { startMenuBarRefresh() }
        // §71.2: the launch sync waits a little, so it never competes with the first refresh.
        scheduleSync(delay: SyncDebounce.launchDelay)
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

    /// Card content for a row; labels and date in the user's language. §33.1: DURUM and BAN TİPİ come from the row's
    /// last ban check; `historyRange` is the range ban kept in the history (§17.10), the current fix result wins.
    func shareCardContent(for id: UUID, icon: CGImage?, historyRange: String? = nil) -> ShareCardContent? {
        guard let entry = servers.first(where: { $0.id == id }) else { return nil }
        // §75.3 / §33.1.3: a GoldSrc 48 card has no CID row at all (not even "N/A" or an old saved CID).
        let goldSrc = isCIDNotApplicable(id)
        let cid = goldSrc ? "" : rowStatus(id)?.currentCID ?? entry.cid
        // §33.1.3: a Source49 row without a CID draws no CID caption or row (no "—" placeholder).
        let showsCID = !goldSrc && !cid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let host = ServerAddress.parse(entry.host).flatMap { address -> String? in
            if case .ipv6 = address { return "[\(entry.host)]" }
            return nil
        } ?? entry.host
        let hostPort = "\(host):\(entry.port)"
        var range = historyRange
        if case .finished(.rangeBanned(_, _, let cidr), _)? = fixSession?.phase, fixSession?.id == id { range = cidr }
        let check = rowStatus(id)?.ban ?? entry.banCheck
        let summary = ShareCardBanSummary.classify(check?.status, rangeKnown: range != nil, goldSrc: goldSrc)
        // §33.1.4: Source49 keeps the CID QR; GoldSrc 48 carries the status-only payload.
        let qr = goldSrc ? ShareCardQR.goldSrcPayload(serverName: entry.label, hostPort: hostPort,
                                                      status: summary.status, banType: summary.banType) : nil
        let name = config.name.isEmpty ? (snapshotState.snapshot?.displayName ?? "") : config.name
        return ShareCardContent(serverName: entry.label, hostPort: hostPort, cid: cid, playerName: name,
                                dateText: DateFormatter.localizedString(from: deps.now(), dateStyle: .medium, timeStyle: .short),
                                labels: ShareCardLabels(title: L10n.text(.appWindowTitle), server: L10n.text(.shareCardServer),
                                                        cid: L10n.text(.shareCardCID), player: L10n.text(.shareCardPlayer),
                                                        date: L10n.text(.shareCardDate),
                                                        status: L10n.text(.shareCardStatus),
                                                        banType: L10n.text(.shareCardBanType),
                                                        qrNote: L10n.text(.shareCardQRStatusOnly)),
                                icon: icon, statusText: summary.status.text, banTypeText: summary.banType.text,
                                status: summary.status, banType: summary.banType, showsCID: showsCID, qrPayload: qr)
    }

    /// §33.1.2 the same content with the range ban read from the history (off the main thread).
    func shareCardContentWithHistory(for id: UUID, icon: CGImage?) async -> ShareCardContent? {
        let ranges = BanMatrix.rangeBans(from: await loadHistory())
        return shareCardContent(for: id, icon: icon, historyRange: ranges[id])
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
        if servers.first(where: { $0.id == id })?.banRecord != nil { removeBanRecordToken(for: id) }
        if hasRconPassword(for: id) { _ = setRconPassword(nil, for: id) }
        rconConsoles[id] = nil
        servers.removeAll { $0.id == id }
        forgetBanExpiry(for: id)
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
            noteProtocol(check, for: servers[index])
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
            noteProtocol(check, for: servers[index])
            fixedSinceSave = true
            reevaluate()
            fixSession?.note = L10n.format(.fixRecheckResult, check.status.label, TimeText.format(check.checkedAt))
        }
        fixTask = task
        return task
    }

    /// Appeal text (§17.9.1); `nil` if the row has no ban result. `check` replaces the row's stored result (§64:
    /// the diagnosis' own evidence).
    func appealText(for id: UUID, check override: BanCheck? = nil) -> String? {
        guard let entry = servers.first(where: { $0.id == id }), let check = override ?? entry.banCheck else { return nil }
        let rawID = try? identity?.get().rawID
        // §75.3: no CID is computed for a GoldSrc 48 server.
        let cid = isCIDNotApplicable(id) ? L10n.text(.serversGoldsrcCidNotUsed)
            : rawID.flatMap { raw in address(for: entry).map { CIDCalculator.cid(rawID: raw, address: $0) } }
            ?? L10n.text(.appealUnknown)
        var rangeBan: RangeBanInfo?
        if case .finished(.rangeBanned(let old, let new, let cidr), _)? = fixSession?.phase, fixSession?.id == id {
            rangeBan = RangeBanInfo(cidr: cidr, oldIP: old, newIP: new)
        }
        return AppealText.make(AppealInput(serverLabel: entry.label, host: entry.host, port: entry.port,
                                           checkedAt: check.checkedAt, playerName: config.name, cid: cid,
                                           publicIP: publicIP ?? L10n.text(.appealUnknown), gamedir: selectedGamedir ?? "—",
                                           check: check, rangeBan: rangeBan, banRecordLine: banRecordAppealLine(for: id)))
    }

    // MARK: §64 connection diagnosis

    /// Live state of the diagnosis shown in the server details; never saved (only the history line is written).
    struct DiagnosisSession: Equatable {
        let token: UUID
        let serverID: UUID
        var isRunning = true
        /// Step currently running (spinner).
        var current: DiagnosisStepKind?
        var steps: [DiagnosisStep] = []
        var result: ConnectionDiagnosis?
        var cancelled = false
    }

    private(set) var diagnosisSession: DiagnosisSession?
    @ObservationIgnored private var diagnosisTask: Task<Void, Never>?
    /// §66.4 the last finished diagnosis per server in this session (details, menu bar or Shortcuts); never saved.
    @ObservationIgnored private(set) var lastDiagnoses: [UUID: ConnectionDiagnosis] = [:]

    func diagnosis(for id: UUID) -> DiagnosisSession? {
        diagnosisSession?.serverID == id ? diagnosisSession : nil
    }

    /// Everything one diagnosis needs, captured on the main actor when it starts (§64.1, §64.3). Shared by the
    /// server details and the menu bar (§65.2).
    private struct DiagnosisJob: Sendable {
        let entry: ServerEntry
        let fixRange: String?
        let rawID: UInt64?
        let name: String
        let checksEnabled: Bool
        let reporter: InterfaceReporter
        let fileSystem: any FileSystemReading
        let root: URL
        let gamedir: String?
        let redactor: Redactor
        let started: Date
        let publicIP: String?
        let historyStore: HistoryStore
        let diagnoser: ConnectionDiagnoser
        /// §68.1 / §68.2: the details' diagnosis also asks A2S_RULES and the ban record (once per run).
        var queryRules = false
        /// §75.10 AC-75.R1: the GoldSrc legacy probe is sent only for a diagnosis the user started (button, menu bar,
        /// server browser); never for Shortcuts/automation.
        var legacyProbeConfirmed = false
        var banLookup: BanRecordLookup? = nil
        /// §75.13 the last "Join Game" (gs) of the server in this session.
        var goldSrcJoin: Date? = nil
        /// §75.4 the last decided A2S protocol of the server.
        var knownProtocol: ServerProtocol = .unknown
        /// §75.13 IPs known for the server (last resolution, saved A2S address string) for the engine log match.
        var knownAddresses: [String?] = []

        /// Probe + engine log; throws `CancellationError` when cancelled.
        func run(progress: @escaping @Sendable (DiagnosisProgress) async -> Void = { _ in }) async throws -> ConnectionDiagnosis {
            let store = historyStore
            let history = await Task.detached { store.load() }.value
            let knownRange = fixRange ?? BanMatrix.rangeBans(from: history)[entry.id]
            let reporter = reporter
            let vpnActive = await Task.detached { reporter.report().isVPNActive }.value
            let request = ConnectionDiagnosisRequest(host: entry.host, port: entry.port, rawID: rawID, name: name,
                                                     checksEnabled: checksEnabled, vpnActive: vpnActive,
                                                     knownRange: knownRange, queryRules: queryRules,
                                                     legacyProbeConfirmed: legacyProbeConfirmed,
                                                     knownProtocol: knownProtocol)
            let lookup = banLookup
            async let recordOutcome: BanRecordOutcome? = lookup?.run()
            let probe = try await diagnoser.run(request, progress: progress)
            let (root, gamedir, fileSystem, redactor) = (root, gamedir, fileSystem, redactor)
            let log = await Task.detached {
                EngineLogReader.read(dataRoot: root, gamedir: gamedir, fileSystem: fileSystem, redactor: redactor)
            }.value
            // §75.13 GoldSrc 48: the engine log of the last GoldSrc connection to this server.
            var goldSrcLog: GoldSrcLogEvidence?
            var goldSrcLogError: String?
            if probe.serverProtocol != .source49 {
                let read = await Task.detached { GoldSrcEngineLog.read(dataRoot: root, fileSystem: fileSystem) }.value
                if case .unreadable(let reason) = read { goldSrcLogError = reason }
                goldSrcLog = read.text.flatMap {
                    GoldSrcEngineLog.evidence(in: $0, addresses: GoldSrcEngineLog.addresses(
                                                host: entry.host, port: entry.port, resolved: probe.address,
                                                known: knownAddresses + [probe.info?.reportedAddress]),
                                              now: diagnoser.now(), notBefore: goldSrcJoin, redactor: redactor)
                }
            }
            let banRecord = await recordOutcome
            try Task.checkCancellation()
            let durationMs = max(0, Int((diagnoser.now().timeIntervalSince(started) * 1000).rounded()))
            var diagnosis = ConnectionDiagnosis(serverID: entry.id, label: entry.label, host: entry.host, port: entry.port,
                                                startedAt: started, probe: probe, engineLog: log, publicIP: publicIP,
                                                durationMs: durationMs, banRecord: banRecord)
            diagnosis.goldSrcLog = goldSrcLog
            diagnosis.goldSrcLogError = goldSrcLogError
            return diagnosis
        }
    }

    private func diagnosisJob(for id: UUID) -> DiagnosisJob? {
        guard let entry = servers.first(where: { $0.id == id }) else { return nil }
        var fixRange: String?
        if case .finished(.rangeBanned(_, _, let cidr), _)? = fixSession?.phase, fixSession?.id == id { fixRange = cidr }
        return DiagnosisJob(entry: entry, fixRange: fixRange, rawID: try? identity?.get().rawID, name: config.name,
                            checksEnabled: banCheckEnabled, reporter: deps.interfaceReporter, fileSystem: deps.fileSystem,
                            root: dataRoot, gamedir: selectedGamedir, redactor: Redactor(home: deps.paths.home),
                            started: deps.now(), publicIP: publicIP,
                            historyStore: HistoryStore(fileURL: deps.paths.historyFile),
                            diagnoser: ConnectionDiagnoser(transport: deps.udpTransport, resolver: deps.resolver,
                                                           now: deps.now),
                            goldSrcJoin: goldSrcJoins[id], knownProtocol: launchProtocol(for: id),
                            knownAddresses: knownAddresses(entry))
    }

    /// §64.1: DNS → A2S_INFO → getchallenge → connect 49 → verdict, plus the read-only engine log (§64.3). The server
    /// entry is not changed; the result is written to the history only (`diagnose`). A new run cancels the previous one.
    @discardableResult
    func startDiagnosis(for id: UUID) -> Task<Void, Never>? {
        guard var job = diagnosisJob(for: id) else { return nil }
        job.queryRules = true
        job.legacyProbeConfirmed = true
        switch banRecordLookup(for: id) {
        case .success(let lookup)?:
            job.banLookup = lookup
            banRecords[id] = .loading
        case .failure(let error)?:
            finishBanRecord(.failure(error), for: id)
        case nil:
            break
        }
        diagnosisTask?.cancel()
        let token = UUID()
        diagnosisSession = DiagnosisSession(token: token, serverID: id)
        let task = Task {
            do {
                let diagnosis = try await job.run { progress in
                    await self.applyDiagnosisProgress(progress, token: token)
                }
                guard diagnosisSession?.token == token else { return }
                diagnosisSession?.steps = diagnosis.steps
                diagnosisSession?.result = diagnosis
                diagnosisSession?.current = nil
                diagnosisSession?.isRunning = false
                lastDiagnoses[id] = diagnosis
                noteProtocol(diagnosis, for: id)
                if let outcome = diagnosis.banRecord { finishBanRecord(outcome, for: id) }
                let line = diagnosis.historyEntry
                recordHistory { recorder in
                    await recorder.record(line)
                    return []
                }
            } catch {
                if banRecords[id] == .loading { banRecords[id] = nil }
                guard diagnosisSession?.token == token else { return }
                diagnosisSession?.current = nil
                diagnosisSession?.isRunning = false
                diagnosisSession?.cancelled = true
            }
        }
        diagnosisTask = task
        return task
    }

    // MARK: §65 diagnosis trend and menu bar diagnosis

    /// §65.1 trend of a server's diagnoses in `window`, derived from the history (`diagnose` lines); read off the
    /// main thread. Changes nothing.
    func diagnosisTrend(for id: UUID, window: DiagnosisTrendWindow) async -> DiagnosisTrend {
        let entries = await loadHistory()
        return DiagnosisTrend.make(entries: entries, serverID: id, window: window, now: deps.now())
    }

    /// §65.2 menu bar diagnoses per server (running / result line); never saved.
    private(set) var menuBarDiagnoses: [UUID: MenuBarDiagnosisState] = [:]
    @ObservationIgnored private var menuBarDiagnosisTasks: [UUID: Task<Void, Never>] = [:]

    func canDiagnoseFromMenuBar(_ id: UUID) -> Bool {
        !isDataOperationRunning && menuBarDiagnoses[id] != .running && servers.contains { $0.id == id }
    }

    /// §65.2 "Diagnose" in the menu bar server submenu: the same probe as the details (§64), shown as one line.
    /// The history gets the same `diagnose` line; the server entry is not changed. A ban verdict posts one
    /// notification (notification switches, quiet hours and the server's §56 override apply).
    @discardableResult
    func startMenuBarDiagnosis(for id: UUID) -> Task<Void, Never>? {
        guard canDiagnoseFromMenuBar(id), var job = diagnosisJob(for: id) else { return nil }
        job.legacyProbeConfirmed = true
        menuBarDiagnoses[id] = .running
        let task = Task {
            defer { menuBarDiagnosisTasks[id] = nil }
            do {
                let diagnosis = try await job.run()
                menuBarDiagnoses[id] = .finished(diagnosis.verdict, durationMs: diagnosis.durationMs ?? 0)
                lastDiagnoses[id] = diagnosis
                noteProtocol(diagnosis, for: id)
                let line = diagnosis.historyEntry
                // §66.2: a range ban carries the "Copy Unban Message" action.
                let content = MenuBarDiagnosisText.notification(verdict: diagnosis.verdict, server: job.entry,
                                                                at: diagnosis.startedAt,
                                                                appeal: diagnosisAppealText(diagnosis))
                recordHistory { recorder in
                    await recorder.record(line)
                    return content.map { [$0] } ?? []
                }
            } catch {
                menuBarDiagnoses[id] = nil
            }
        }
        menuBarDiagnosisTasks[id] = task
        return task
    }

    func cancelDiagnosis() {
        diagnosisTask?.cancel()
    }

    // MARK: §68.1 server details (A2S_PLAYER / A2S_RULES)

    /// The last "Server details" query of a server in this session (never saved, never refreshed automatically).
    struct ServerDetailsState: Equatable {
        var isLoading = false
        var snapshot: ServerDetailsSnapshot?
    }

    private(set) var serverDetails: [UUID: ServerDetailsState] = [:]
    @ObservationIgnored private var serverDetailsTasks: [UUID: Task<Void, Never>] = [:]

    func serverDetailsState(for id: UUID) -> ServerDetailsState? { serverDetails[id] }

    /// "Refresh" of the details: players, then rules, on one UDP session. Only on request; a running query is not
    /// started twice.
    @discardableResult
    func refreshServerDetails(for id: UUID) -> Task<Void, Never>? {
        guard let entry = servers.first(where: { $0.id == id }), serverDetails[id]?.isLoading != true else { return nil }
        let querier = ServerQuerier(transport: deps.udpTransport, now: deps.now)
        let endpoint = address(for: entry).flatMap { address -> UDPEndpoint? in
            guard address != .localMachine, HostValidator.isValidPort(entry.port) else { return nil }
            return UDPEndpoint(address: address, port: UInt16(entry.port))
        }
        serverDetails[id, default: ServerDetailsState()].isLoading = true
        let now = deps.now
        let task = Task {
            defer { serverDetailsTasks[id] = nil }
            let snapshot: ServerDetailsSnapshot
            if let endpoint {
                do {
                    snapshot = try await querier.details(endpoint)
                } catch {
                    serverDetails[id]?.isLoading = false
                    return
                }
            } else {
                snapshot = ServerDetailsSnapshot(players: .failure(.unreachable), rules: .failure(.unreachable), at: now())
            }
            serverDetails[id] = ServerDetailsState(isLoading: false, snapshot: snapshot)
        }
        serverDetailsTasks[id] = task
        return task
    }

    // MARK: §68.2 ban record (JSON endpoint)

    enum BanRecordState: Equatable {
        case loading
        case finished(BanRecordOutcome)
    }

    /// The last ban record lookup per server in this session (never saved).
    private(set) var banRecords: [UUID: BanRecordState] = [:]

    func banRecordState(for id: UUID) -> BanRecordState? { banRecords[id] }

    func banRecordConfig(for id: UUID) -> BanRecordConfig? {
        servers.first { $0.id == id }?.banRecord
    }

    /// A bearer token is stored for this server (the token itself never leaves the store).
    func hasBanRecordToken(for id: UUID) -> Bool {
        ((try? deps.secretStore.secret(for: id.uuidString)) ?? nil)?.isEmpty == false
    }

    /// Saves the settings; `token` `nil` keeps the stored token, `""` removes it. An empty template removes the
    /// settings and the token. Returns the problem without changing anything.
    @discardableResult
    func setBanRecord(urlTemplate: String, enabled: Bool, token: String?, for id: UUID) -> BanRecordError? {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeBanRecordToken(for: id)
            if servers[index].banRecord != nil {
                servers[index].banRecord = nil
                markEdited()
            }
            banRecords[id] = nil
            forgetBanExpiry(for: id)
            return nil
        }
        let valid: String
        switch BanRecordConfig.validate(trimmed) {
        case .success(let template): valid = template
        case .failure(let error): return .invalidTemplate(error)
        }
        if let token {
            do {
                try deps.secretStore.setSecret(token.trimmingCharacters(in: .whitespacesAndNewlines), for: id.uuidString)
            } catch {
                deps.errorLog.record(.banLookup, "keychainWrite \(error)", at: deps.now())
                return .keychain
            }
        }
        let config = BanRecordConfig(urlTemplate: valid, enabled: enabled)
        if servers[index].banRecord != config {
            servers[index].banRecord = config
            markEdited()
        }
        return nil
    }

    private func removeBanRecordToken(for id: UUID) {
        do {
            try deps.secretStore.setSecret(nil, for: id.uuidString)
        } catch {
            deps.errorLog.record(.banLookup, "keychainDelete \(error)", at: deps.now())
        }
    }

    /// Everything one lookup needs, captured on the main actor; `nil` when the server has no enabled ban record.
    func banRecordLookup(for id: UUID) -> Result<BanRecordLookup, BanRecordError>? {
        guard let entry = servers.first(where: { $0.id == id }), let config = entry.banRecord, config.enabled else {
            return nil
        }
        let values = BanListValues(cid: rowStatus(id)?.currentCID, ip: publicIP, host: entry.host, port: entry.port)
        let template: String
        switch BanRecordConfig.validate(config.urlTemplate) {
        case .success(let valid): template = valid
        case .failure(let error): return .failure(.invalidTemplate(error))
        }
        let url: URL
        switch BanListTemplate.url(template, values: values) {
        case .success(let filled): url = filled
        case .failure(let error): return .failure(.invalidTemplate(error))
        }
        let token: String?
        do {
            token = try deps.secretStore.secret(for: id.uuidString)
        } catch {
            return .failure(.keychain)
        }
        return .success(BanRecordLookup(url: url, bearerToken: token, client: BanRecordClient(http: deps.banRecordHTTP),
                                        now: deps.now))
    }

    /// "Check Ban Record" on the card (outside a diagnosis).
    @discardableResult
    func refreshBanRecord(for id: UUID) -> Task<Void, Never>? {
        guard banRecords[id] != .loading, let lookup = banRecordLookup(for: id) else { return nil }
        switch lookup {
        case .failure(let error):
            finishBanRecord(.failure(error), for: id)
            return nil
        case .success(let lookup):
            banRecords[id] = .loading
            return Task {
                let outcome = await lookup.run()
                finishBanRecord(outcome, for: id)
            }
        }
    }

    /// Stores the outcome; a failure is never swallowed: it stays on the card and goes to the error log (`banLookup`,
    /// kind and status only — no URL, token or body).
    private func finishBanRecord(_ outcome: BanRecordOutcome, for id: UUID) {
        banRecords[id] = .finished(outcome)
        switch outcome {
        case .failure(let error):
            deps.errorLog.record(.banLookup, error.logMessage, at: deps.now())
        case .success(let result):
            planBanExpiry(result, for: id)
        }
    }

    // MARK: §72 read-only RCON console

    enum RconConsoleState: Equatable {
        case running(RconCommand)
        case finished(RconCommand, RconOutcome)
    }

    /// The last console run per server in this session (never saved).
    private(set) var rconConsoles: [UUID: RconConsoleState] = [:]

    func rconState(for id: UUID) -> RconConsoleState? { rconConsoles[id] }

    /// A password is stored for this server (the password itself never leaves the store).
    func hasRconPassword(for id: UUID) -> Bool {
        ((try? deps.rconSecretStore.secret(for: RconKeychain.account(id))) ?? nil)?.isEmpty == false
    }

    /// Stores (`nil`/empty removes) the password in the Keychain only. A failure is logged by kind, never the value.
    @discardableResult
    func setRconPassword(_ password: String?, for id: UUID) -> RconError? {
        do {
            try deps.rconSecretStore.setSecret(password, for: RconKeychain.account(id))
            return nil
        } catch {
            deps.errorLog.record(.rcon, password?.isEmpty == false ? "keychainWrite" : "keychainDelete", at: deps.now())
            return .keychain
        }
    }

    func setRconEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }), servers[index].rconEnabled != enabled else { return }
        servers[index].rconEnabled = enabled
        markEdited()
    }

    /// `false` (nothing changes) for a port outside 1–65535.
    @discardableResult
    func setRconPort(_ port: Int, for id: UUID) -> Bool {
        guard HostValidator.isValidPort(port), let index = servers.firstIndex(where: { $0.id == id }) else { return false }
        if servers[index].rconPort != port {
            servers[index].rconPort = port
            markEdited()
        }
        return true
    }

    /// Everything one run needs, captured on the main actor.
    func rconRun(_ command: RconCommand, for id: UUID) -> Result<RconRun, RconError> {
        guard let entry = servers.first(where: { $0.id == id }) else { return .failure(.unreachable) }
        guard entry.rconEnabled else { return .failure(.disabled) }
        let password: String?
        do {
            password = try deps.rconSecretStore.secret(for: RconKeychain.account(id))
        } catch {
            return .failure(.keychain)
        }
        guard let password, !password.isEmpty else { return .failure(.noPassword) }
        guard let address = address(for: entry), address != .localMachine, HostValidator.isValidPort(entry.rconPort) else {
            return .failure(.unreachable)
        }
        return .success(RconRun(command: command, endpoint: UDPEndpoint(address: address, port: UInt16(entry.rconPort)),
                                password: password, client: RconClient(transport: deps.udpTransport, now: deps.now)))
    }

    /// A console button: one allowlisted command; a running one is not started twice.
    @discardableResult
    func runRcon(_ command: RconCommand, for id: UUID) -> Task<Void, Never>? {
        if case .running? = rconConsoles[id] { return nil }
        switch rconRun(command, for: id) {
        case .failure(let error):
            finishRcon(command, .failure(error), for: id)
            return nil
        case .success(let run):
            rconConsoles[id] = .running(command)
            return Task {
                do {
                    finishRcon(command, try await run.run(), for: id)
                } catch {
                    rconConsoles[id] = nil
                }
            }
        }
    }

    /// Keeps the result; a failure or an unknown command goes to `ErrorLog(rcon)` as kind + command only.
    private func finishRcon(_ command: RconCommand, _ outcome: RconOutcome, for id: UUID) {
        rconConsoles[id] = .finished(command, outcome)
        switch outcome {
        case .failure(let error):
            deps.errorLog.record(.rcon, "\(error.logMessage) \(command.rawValue)", at: deps.now())
        case .success(let output) where output.isUnknownCommand:
            deps.errorLog.record(.rcon, "unknownCommand \(command.rawValue)", at: deps.now())
        case .success:
            break
        }
    }

    private func banRecordAppealLine(for id: UUID) -> String? {
        guard case .finished(.success(let result))? = banRecords[id] else { return nil }
        return BanRecordText.appealLine(result)
    }

    /// Closes the diagnosis (sheet closed): a running probe is cancelled.
    func clearDiagnosis() {
        diagnosisTask?.cancel()
        diagnosisSession = nil
    }

    private func applyDiagnosisProgress(_ progress: DiagnosisProgress, token: UUID) {
        guard diagnosisSession?.token == token else { return }
        switch progress {
        case .started(let kind): diagnosisSession?.current = kind
        case .finished(let step):
            diagnosisSession?.steps.append(step)
            if diagnosisSession?.current == step.step { diagnosisSession?.current = nil }
        }
    }

    /// §64.5 Markdown report of the finished diagnosis (masked unless the user confirmed "unmasked").
    func diagnosisReport(for id: UUID, masked: Bool = true) -> String? {
        guard let diagnosis = diagnosis(for: id)?.result else { return nil }
        return DiagnosisReport.markdown(diagnosis, appVersion: deps.appVersion, masked: masked)
    }

    /// §66.3 the report with the "History (last 10 runs)" table of `window` (after the pending history writes).
    func diagnosisReport(for id: UUID, masked: Bool = true, window: DiagnosisTrendWindow) async -> String? {
        guard let diagnosis = diagnosis(for: id)?.result else { return nil }
        return await report(for: diagnosis, masked: masked, window: window)
    }

    private func report(for diagnosis: ConnectionDiagnosis, masked: Bool, window: DiagnosisTrendWindow) async -> String {
        await historyTask?.value
        let entries = await loadHistory()
        let history = diagnosis.serverID.map {
            DiagnosisReportHistory.make(entries: entries, serverID: $0, window: window, now: deps.now())
        }
        return DiagnosisReport.markdown(diagnosis, appVersion: deps.appVersion, masked: masked, history: history)
    }

    /// Unban message (§17.9.1) built from the diagnosis evidence when its verdict is a ban.
    func diagnosisAppealText(for id: UUID) -> String? {
        guard let diagnosis = diagnosis(for: id)?.result else { return nil }
        return diagnosisAppealText(diagnosis)
    }

    func diagnosisAppealText(_ diagnosis: ConnectionDiagnosis) -> String? {
        guard let id = diagnosis.serverID, diagnosis.verdict.isBan else { return nil }
        let status: BanStatus = diagnosis.verdict == .cidBanned ? .cidBanned : .ipBanned
        let evidence = diagnosis.steps.first { $0.detail.hasPrefix("banned") }?.detail
            ?? diagnosis.engineLog.matches.last { $0.pattern.directVerdict != nil }?.line ?? status.rawValue
        return appealText(for: id, check: BanCheck(status: status, checkedAt: diagnosis.startedAt, detail: evidence))
    }

    // MARK: §66.4 Shortcuts: "Diagnose Server", "Copy Diagnosis Report"

    /// Runs the §64 diagnosis for Shortcuts/Siri: the history gets the same `diagnose` line (the server entry is not
    /// changed); no notification (the result is the answer). Throws `IntentFailure.noNetwork` without a network,
    /// `CancellationError` when cancelled (nothing is written then).
    func diagnoseForIntent(_ id: UUID) async throws -> ConnectionDiagnosis {
        guard let job = diagnosisJob(for: id) else { throw IntentFailure.serverNotFound(id.uuidString) }
        let diagnosis = try await job.run()
        lastDiagnoses[id] = diagnosis
        noteProtocol(diagnosis, for: id)
        let line = diagnosis.historyEntry
        recordHistory { recorder in
            await recorder.record(line)
            return []
        }
        if diagnosis.networkUnavailable { throw IntentFailure.noNetwork }
        return diagnosis
    }

    /// Copies the report of the server's last diagnosis in this session (masked by default) with the history of
    /// `window`; returns the label the dialog names.
    func copyDiagnosisReportForIntent(_ id: UUID, masked: Bool = true,
                                      window: DiagnosisTrendWindow = .default) async -> Result<String, IntentFailure> {
        guard let entry = servers.first(where: { $0.id == id }) else { return .failure(.serverNotFound(id.uuidString)) }
        guard let diagnosis = lastDiagnoses[id] ?? diagnosis(for: id)?.result else { return .failure(.noDiagnosis) }
        let text = await report(for: diagnosis, masked: masked, window: window)
        guard deps.pasteboard.write(text) else {
            logError(.clipboard, "intentCopyDiagnosisReport: pasteboardWriteFailed")
            return .failure(.clipboard)
        }
        return .success(entry.label.isEmpty ? "\(entry.host):\(entry.port)" : entry.label)
    }

    // MARK: §66.2 notification responses

    /// Server whose details the main window should open (a tapped notification); the window clears it.
    var requestedServerDetail: UUID?

    /// "Copy Unban Message" copies (nothing opens); a tap opens the server details (nothing is copied).
    @discardableResult
    func handleNotificationRoute(_ route: NotificationActions.Route) -> Bool {
        switch route {
        case .copy(let text):
            guard deps.pasteboard.write(text) else {
                logError(.clipboard, "notificationCopyAppeal: pasteboardWriteFailed")
                return false
            }
            return true
        case .openServer(let id):
            guard servers.contains(where: { $0.id == id }) else { return false }
            requestedServerDetail = id
            return true
        case .none:
            return false
        }
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
        var snapshot = SnapshotBuilder.make(savedAt: deps.now(),
                                            dataRoot: dataRoot,
                                            gamedir: selectedGamedir,
                                            config: config,
                                            identity: identity,
                                            publicIP: publicIP,
                                            lanIPs: lanAddresses.map(\.display),
                                            checkedAt: lastChecked,
                                            servers: servers,
                                            resolutions: hostResolutions)
        snapshot.profiles = profileList.profiles
        snapshot.activeProfileID = profileList.activeID
        snapshot.banExpiryWatch = banExpiryWatches.isEmpty ? nil : banExpiryWatches
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
        scheduleSync()
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
        SettingsImportPreview.make(parsed, existing: servers, includeDataRoot: includeDataRoot,
                                   current: currentArchivedSettings())
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
        summary.skippedFields = report.skippedFields
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
        var skippedFields: [String] = []
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
                report.skippedFields.append(SettingsImportPreview.dataRootField)
            }
        }
        return report
    }

    /// An imported data root is applied only as an existing folder (not `/`, no `..` component); the same check as
    /// the import preview (§58.3).
    static func importableDataRoot(_ path: String) -> URL? {
        ArchivedSettings.importableDataRoot(path)
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
        deps.errorLog.removeAll()
        metricsWriteFailure = nil
        // §67.4: the whole Spotlight domain goes; whatever is still on disk is indexed again by the reload.
        spotlightIndexed = [:]
        enqueueSpotlight("deleteAll") { try await $0.deleteAll() }
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
        if let snapshot, !(snapshot.profiles ?? []).isEmpty {
            // §61: the restored record brings its profiles; the active one decides the data root and game folder.
            profileList = ProfileList.resolve(snapshot: snapshot, storedDataRoot: nil,
                                              defaultDataRoot: deps.paths.defaultDataRoot, now: deps.now())
            dataRoot = profileList.active.dataRootURL(defaultDataRoot: deps.paths.defaultDataRoot)
            selectedGamedir = profileList.active.preferredGamedir
        } else {
            if snapshot != nil || !keepGamedirWithoutRecord {
                selectedGamedir = (snapshot?.gamedir).flatMap { $0.isEmpty ? nil : $0 }
            }
            if (deps.defaults.string(forKey: Self.dataRootDefaultsKey) ?? "").isEmpty, let snapshot, !snapshot.dataRoot.isEmpty {
                dataRoot = URL(fileURLWithPath: snapshot.dataRoot, isDirectory: true)
            }
            // A record without profiles (or none at all): the current setup becomes the single `Default` profile.
            let migrated = Profile(name: Profile.migratedName,
                                   dataRoot: ProfileList.normalizedRoot(dataRoot.path, defaultDataRoot: deps.paths.defaultDataRoot),
                                   gamedir: selectedGamedir ?? "", createdAt: deps.now())
            profileList = ProfileList(profiles: [migrated], activeID: migrated.id, defaultDataRoot: deps.paths.defaultDataRoot)
        }
        watchState = WatchStateStore(fileURL: deps.paths.watchStateFile).load()
        banExpiryWatches = BanExpiryPlanner.prune(snapshot?.banExpiryWatch ?? [], serverIDs: Set(servers.map(\.id)),
                                                  soonEnabled: banExpirySoonEnabled, now: deps.now())
        scheduleBanExpiryTimer()
        for entry in servers { resolveIfNeeded(entry.host) }
        editedWithoutSnapshot = false
        appliedSinceSave = false
        fixedSinceSave = false
        saveErrorMessage = nil
        historyRevision += 1
        updates.evaluateRestore(snapshot: loaded)
        reevaluate()
    }

    // MARK: §67.2 launch the game with logging (`-condebug`)

    /// Result of the last "Launch Game with Logging" (waiting / log active / no log / failed); not saved.
    private(set) var condebugState: CondebugState?
    @ObservationIgnored private var condebugTask: Task<Void, Never>?

    /// Why "Launch Game with Logging" is disabled: Xash3D is not installed, or the game is already running.
    var condebugBlocker: CondebugLaunchError? {
        if !isGameAppInstalled { return .appNotFound }
        if isGameRunning { return .gameRunning }
        return nil
    }

    /// Opens Xash3D with `-condebug` (NSWorkspace; only a process is started, no file is written) and waits up to
    /// 10 s for `qconsole.log`. A failure is shown and written to the error log (`launch`).
    @discardableResult
    func launchGameWithLogging() -> Task<Void, Never>? {
        guard condebugTask == nil else { return nil }
        let launcher = CondebugLauncher(locator: deps.gameAppLocator, detector: deps.gameProcessDetector,
                                        launcher: deps.appLauncher, files: deps.fileDating, sleeper: deps.sleeper)
        let (root, gamedir) = (dataRoot, selectedGamedir)
        condebugState = .waiting
        let task = Task {
            let result = await launcher.launch(dataRoot: root, gamedir: gamedir) { state in
                await self.setCondebugState(state)
            }
            condebugState = result
            if case .failed(let error) = result {
                switch error {
                case .appNotFound: logError(.launch, "condebug: appNotFound")
                case .gameRunning: logError(.launch, "condebug: gameRunning")
                case .launchFailed(let reason): logError(.launch, "condebug: launchFailed: \(reason)")
                }
            }
            isGameRunning = deps.gameProcessDetector.isGameRunning()
            condebugTask = nil
        }
        condebugTask = task
        return task
    }

    private func setCondebugState(_ state: CondebugState) {
        condebugState = state
    }

    // MARK: §73 macOS hardware identity health

    /// Why "Regenerate Identity" ended (launched, or failed with a reason); cleared by the next identity check.
    enum MacIdentityRegenerateStatus: Sendable, Equatable {
        case launched
        case failed(MacIdentityRegenerateError)
    }

    /// Result of the last check; `nil` before the first one. Holds no raw identity and no full CID. While
    /// `isCheckingMacIdentity` is set the card hides it completely (it belongs to the previous generation).
    private(set) var macIdentity: MacIdentityReport?
    private(set) var isCheckingMacIdentity = false
    /// The engine app the check uses (a valid override, else the default).
    private(set) var engineResolution = EnginePathResolution(app: EnginePaths.defaultApp, isOverride: false,
                                                             rejectedOverride: nil)
    /// The override the user just chose was refused (not stored; the default is used).
    private(set) var engineOverrideRejection: EnginePathError?
    private(set) var macIdentityRegenerateStatus: MacIdentityRegenerateStatus?
    private(set) var isRegeneratingMacIdentity = false
    /// The release page could not be opened, or the link was refused by the allowlist (shown under the button).
    private(set) var engineDownloadFailed = false
    /// §73 tri-state of the engine process, from the same source as the identity report (`nil` before the first
    /// check). `.unavailable` means "unknown": `isGameRunning` is then left as it was and nothing treats it as closed.
    private(set) var engineProcessState: EngineProcessState?
    /// "Open the engine?" confirmation of "Regenerate Identity".
    var showsMacIdentityRegenerateConfirmation = false
    @ObservationIgnored private var macIdentityTask: Task<Void, Never>?
    @ObservationIgnored private(set) var macIdentityGeneration = 0
    @ObservationIgnored private var regenerateTask: Task<Void, Never>?
    @ObservationIgnored private var loggedEngineRejection: EnginePathError?

    /// The stored engine app override (`nil` = the default path).
    var engineAppOverride: String? {
        deps.defaults.string(forKey: DefaultsKey.engineApp).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var engineForbiddenRoots: [URL] {
        EnginePaths.forbiddenRoots(home: deps.paths.home, dataRoot: dataRoot)
    }

    /// §73 `isGameRunning` follows the identity check's process state: running → true, not running → false;
    /// unavailable leaves the flag alone (unknown) and is kept in `engineProcessState`.
    private func syncEngineProcessState(_ state: EngineProcessState) {
        engineProcessState = state
        switch state {
        case .running: isGameRunning = true
        case .notRunning: isGameRunning = false
        case .unavailable: break
        }
    }

    /// §73.5.3: starts a new generation (the card shows only "Checking…" until its result arrives), resolves the
    /// engine path, then checks the engine process, its static evidence and the raw identity state off the main
    /// thread. The previous scan is cancelled (its result is dropped). Read-only; never starts the engine and never
    /// refreshes on its own after an action.
    ///
    /// - Parameter verifyInstall: §74: when an engine install waits for its identity verification and the engine is
    ///   known to be closed, the identity before and after the install is compared (only the refresh right after the
    ///   install passes `false`: the engine has not been opened yet).
    @discardableResult
    func refreshMacIdentity(verifyInstall: Bool = true) -> Task<Void, Never> {
        macIdentityGeneration += 1
        let current = macIdentityGeneration
        macIdentityTask?.cancel()
        isCheckingMacIdentity = true
        macIdentityRegenerateStatus = nil
        engineDownloadFailed = false
        showsMacIdentityRegenerateConfirmation = false
        let override = engineAppOverride
        let roots = engineForbiddenRoots
        let checker = MacIdentityChecker(files: deps.fileProbe, detector: deps.gameProcessDetector,
                                         home: deps.paths.home)
        let gamedir = selectedGamedir.map { dataRoot.appendingPathComponent($0, isDirectory: true) }
        let task = Task {
            // The process state is taken before the override is validated (its bundle and Info.plist are read only
            // when the engine is known to be closed).
            let scan = Task.detached { checker.check(override: override, forbiddenRoots: roots, gamedir: gamedir) }
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard current == macIdentityGeneration, !Task.isCancelled else { return }
            applyEngineResolution(result.resolution)
            macIdentity = result.report
            syncEngineProcessState(result.report.processState)
            if verifyInstall { verifyEngineInstall(result.report) }
            isCheckingMacIdentity = false
            macIdentityTask = nil
        }
        macIdentityTask = task
        return task
    }

    /// The resolution of a finished check; a rejected override is logged once (not on every refresh). An unvalidated
    /// resolution (engine running / state unknown) keeps the previous rejection state.
    private func applyEngineResolution(_ resolution: EnginePathResolution) {
        engineResolution = resolution
        guard resolution.validated else { return }
        if let rejected = resolution.rejectedOverride, rejected != loggedEngineRejection {
            logError(.launch, "macIdentity: overrideRejected=\(rejected.rawValue)")
        }
        loggedEngineRejection = resolution.rejectedOverride
    }

    /// §73.6.2: stores a valid engine app override (`nil` = back to the default) and checks again. An invalid one is
    /// refused: nothing is stored, the default is used, the reason is shown and logged. The process state comes first:
    /// while the engine runs (or its state is unknown) the chosen bundle is not read; the choice is kept and the first
    /// check that sees the engine closed validates it (a refused one then shows and logs its reason).
    @discardableResult
    func setEngineApp(_ url: URL?) -> EnginePathError? {
        if let url {
            let state = deps.gameProcessDetector.engineProcessState()
            syncEngineProcessState(state)
            guard state == .notRunning else {
                deps.defaults.set(url.standardized.path, forKey: DefaultsKey.engineApp)
                engineOverrideRejection = nil
                refreshMacIdentity()
                return nil
            }
            if let error = EnginePaths.validateOverride(url, files: deps.fileProbe, forbiddenRoots: engineForbiddenRoots) {
                deps.defaults.removeObject(forKey: DefaultsKey.engineApp)
                engineOverrideRejection = error
                logError(.launch, "macIdentity: overrideRejected=\(error.rawValue)")
                refreshMacIdentity()
                return error
            }
            deps.defaults.set(url.standardized.path, forKey: DefaultsKey.engineApp)
        } else {
            deps.defaults.removeObject(forKey: DefaultsKey.engineApp)
        }
        engineOverrideRejection = nil
        refreshMacIdentity()
        return nil
    }

    /// "Regenerate Identity" pressed: only for the current (not checking) report that offers it; the engine must be
    /// known to be closed (checked again now, tri-state); then the confirmation opens.
    func requestMacIdentityRegeneration() {
        guard !isCheckingMacIdentity, let report = macIdentity, report.action == .regenerate,
              report.processState == .notRunning else {
            macIdentityRegenerateStatus = .failed(.notOffered)
            return
        }
        let state = deps.gameProcessDetector.engineProcessState()
        syncEngineProcessState(state)
        switch state {
        case .running:
            macIdentityRegenerateStatus = .failed(.engineRunning)
            return
        case .unavailable:
            macIdentityRegenerateStatus = .failed(.processUnavailable)
            logError(.launch, "macIdentity: processUnavailable")
            return
        case .notRunning:
            break
        }
        showsMacIdentityRegenerateConfirmation = true
    }

    /// Confirmed: opens the engine (no arguments) so it repairs the identity itself. The app writes and deletes no
    /// identity file, does not quit the engine and does not refresh afterwards (the user quits it and presses Refresh).
    /// After a successful launch the engine is assumed to be running. The result belongs to the generation that
    /// started it: if a refresh started meanwhile, it is only logged as stale and never touches the new report.
    @discardableResult
    func confirmMacIdentityRegeneration() -> Task<Void, Never>? {
        showsMacIdentityRegenerateConfirmation = false
        guard regenerateTask == nil, !isCheckingMacIdentity, let report = macIdentity else { return nil }
        let generation = macIdentityGeneration
        let regenerator = MacIdentityRegenerator(files: deps.fileProbe, detector: deps.gameProcessDetector,
                                                 launcher: deps.appLauncher)
        isRegeneratingMacIdentity = true
        macIdentityRegenerateStatus = nil
        let task = Task {
            var outcome: MacIdentityRegenerateStatus
            do {
                try await regenerator.regenerate(report: report)
                outcome = .launched
            } catch {
                outcome = .failed(error as? MacIdentityRegenerateError ?? .launchFailed(String(describing: error)))
            }
            isRegeneratingMacIdentity = false
            regenerateTask = nil
            guard generation == macIdentityGeneration else {
                // The status belongs to the old report, but a launched (or running) engine is a fact of the real
                // world: the process state is synced anyway.
                if outcome == .launched || outcome == .failed(.engineRunning) { syncEngineProcessState(.running) }
                logError(.launch, "macIdentity: staleRegenerate=\(generation)->\(macIdentityGeneration),\(outcome)")
                return
            }
            macIdentityRegenerateStatus = outcome
            switch outcome {
            case .launched:
                syncEngineProcessState(.running)
            case .failed(let failure):
                if failure == .engineRunning { syncEngineProcessState(.running) }
                if failure == .processUnavailable { syncEngineProcessState(.unavailable) }
                logError(.launch, "macIdentity: \(failure)")
            }
        }
        regenerateTask = task
        return task
    }

    func cancelMacIdentityRegeneration() {
        showsMacIdentityRegenerateConfirmation = false
    }

    /// "Download Compatible Engine": opens only the fixed official release page (https allowlist). Nothing is
    /// downloaded, installed or changed. A link refused by the allowlist is never silent: the card shows the failure
    /// and the error log records it.
    @discardableResult
    func openCompatibleEngineDownload(_ url: URL = EngineDownloadLink.url) -> Bool {
        guard EngineDownloadLink.isAllowed(url) else {
            engineDownloadFailed = true
            logError(.launch, "macIdentity: downloadPage=notAllowed")
            return false
        }
        let opened = deps.urlOpener.open(url)
        engineDownloadFailed = !opened
        if !opened { logError(.launch, "macIdentity: downloadPage") }
        return opened
    }

    // MARK: §74 "Install Compatible Engine"

    /// Where the install flow is (button → release details → confirmation → progress → result → verification).
    private(set) var engineInstall: EngineInstallFlow = .idle
    /// The install finished (`installed`) and the identity is not verified yet: the card never claims "supported"
    /// meanwhile (AC-E45, AC-E87a).
    private(set) var engineInstallAwaitingVerification = false
    /// Result of "Open Engine" after an install (cleared by the next install).
    private(set) var engineInstallLaunchStatus: EngineInstallLaunchStatus?
    @ObservationIgnored private var engineInstallTask: Task<Void, Never>?
    @ObservationIgnored private var engineInstallLaunchTask: Task<Void, Never>?
    /// Identity labels + masked CID at confirmation time (AC-E2c); runtime only, never persisted.
    @ObservationIgnored private var engineInstallBefore: EngineIdentitySnapshot?
    @ObservationIgnored private(set) var engineInstallEnvironment: EngineInstallEnvironment?

    /// Whether the card shows "Install Compatible Engine" and why it is disabled.
    var engineInstallAvailability: EngineInstallAvailability {
        EngineInstallAvailability.evaluate(report: macIdentity, checking: isCheckingMacIdentity,
                                           engineRunning: isGameRunning, processState: engineProcessState,
                                           architecture: deps.engineArchitecture, flow: engineInstall)
    }

    /// A fetch or an install is in flight (quit and window close handle it; a second install is refused).
    var isEngineInstallRunning: Bool { engineInstallTask != nil }

    private var engineIdentityReader: LocalEngineIdentityReader { LocalEngineIdentityReader(files: deps.fileProbe) }

    /// "Install Compatible Engine" pressed: the engine must be known to be closed (checked again now); then only the
    /// release API is read (no download, no write) and the confirmation opens with its details.
    @discardableResult
    func requestEngineInstall() -> Task<Void, Never>? {
        guard engineInstallTask == nil else {
            engineInstall = engineInstall.isBusy ? engineInstall : .blocked(.busy)
            return nil
        }
        switch engineInstallAvailability {
        case .hidden:
            engineInstall = .blocked(.notOffered)
            return nil
        case .disabled(let block):
            engineInstall = .blocked(block)
            return nil
        case .enabled:
            break
        }
        guard let report = macIdentity else { return nil }
        let state = deps.gameProcessDetector.engineProcessState()
        syncEngineProcessState(state)
        guard state == .notRunning else {
            engineInstall = .blocked(state == .running ? .engineRunning : .processUnavailable)
            if state == .unavailable { logError(.engineInstall, "request: error=processUnavailable") }
            return nil
        }
        let environment = EngineInstallEnvironment.make(targetApp: report.engineApp, dataRoot: dataRoot,
                                                        gamedir: selectedGamedir, paths: deps.paths,
                                                        architecture: deps.engineArchitecture)
        let installer = deps.engineInstallerFactory(environment)
        let cid = report.cidMasked
        engineInstall = .fetchingRelease
        engineInstallLaunchStatus = nil
        let task = Task {
            let result = await installer.fetchRelease()
            engineInstallTask = nil
            guard case .fetchingRelease = engineInstall else { return }   // cancelled meanwhile
            switch result {
            case .success(let release):
                engineInstall = .confirming(EngineInstallOffer(
                    summary: EngineInstallPlanSummary(release: release, environment: environment, cidMasked: cid),
                    environment: environment))
            case .failure(.cancelled):
                engineInstall = .idle
            case .failure(let failure):
                engineInstall = .fetchFailed(failure)
                logError(.engineInstall, "fetch: error=\(failure.code)")
            }
        }
        engineInstallTask = task
        return task
    }

    /// The confirmation was declined (or closed): nothing was downloaded or written.
    func declineEngineInstall() {
        guard engineInstall.offer != nil else { return }
        engineInstall = .idle
    }

    /// Confirmed with the CID warning accepted. The process state is checked once more, the identity labels and the
    /// masked CID are taken (`cidBefore`, read-only) and the install runs off the main actor with live progress.
    /// Without the accepted warning nothing happens (AC-E2a).
    @discardableResult
    func confirmEngineInstall(acceptedCIDWarning: Bool) -> Task<Void, Never>? {
        guard acceptedCIDWarning, let offer = engineInstall.offer, engineInstallTask == nil else { return nil }
        let state = deps.gameProcessDetector.engineProcessState()
        syncEngineProcessState(state)
        guard state == .notRunning else {
            engineInstall = .blocked(state == .running ? .engineRunning : .processUnavailable)
            logError(.engineInstall, "confirm: error=\(state == .running ? "engineRunning" : "processUnavailable")")
            return nil
        }
        let environment = offer.environment
        let before = engineIdentityReader.snapshot(home: deps.paths.home, gamedir: environment.gamedirURL)
        engineInstallBefore = before
        engineInstallEnvironment = environment
        engineInstallAwaitingVerification = false
        engineInstallLaunchStatus = nil
        let confirmation = EngineInstallConfirmation(acceptedCIDWarning: true,
                                                     cidBefore: before.cidMasked ?? offer.summary.cidMasked)
        let installer = deps.engineInstallerFactory(environment)
        let release = offer.summary.release
        engineInstall = .installing(EngineInstallProgress(phase: .downloading, bytes: 0, total: release.asset.size),
                                    cancelling: false)
        let task = Task {
            let result = await installer.install(release, confirmation: confirmation) { progress in
                await self.applyEngineInstallProgress(progress)
            }
            engineInstallTask = nil
            finishEngineInstall(result)
        }
        engineInstallTask = task
        return task
    }

    private func applyEngineInstallProgress(_ progress: EngineInstallProgress) {
        guard case .installing(_, let cancelling) = engineInstall, !progress.phase.isTerminal,
              progress.phase != .awaitingIdentityRepair else { return }
        engineInstall = .installing(progress, cancelling: cancelling && progress.phase.isCancellable)
    }

    private func finishEngineInstall(_ result: EngineInstallResult) {
        engineInstall = .finished(EngineInstallFinish(outcome: result.outcome, report: result.report))
        switch result.outcome {
        case .installed:
            engineInstallAwaitingVerification = true
        case .failed(let failure):
            logError(.engineInstall, "install: stage=failed,error=\(failure.code)")
        case .rolledBack(let failure):
            logError(.engineInstall, "install: stage=rolledBack,error=\(failure.code),backupKept=yes")
        case .rollbackIncomplete(let failure):
            logError(.engineInstall, "install: stage=rollbackIncomplete,error=\(failure.code),critical=yes,"
                     + "backup=\(result.report.backup?.root.path ?? "-")")
        case .cancelled:
            logError(.engineInstall, "install: stage=cancelled")
        }
        if !result.report.leftovers.isEmpty {
            logError(.engineInstall, "install: leftovers=\(result.report.leftovers.count)")
        }
        // The engine may have changed: check again (the engine is not opened; no identity verification yet).
        refreshMacIdentity(verifyInstall: false)
        loadEngineBackups()
    }

    /// Cancel: the release fetch, or the install only while it downloads or extracts (AC-E7). Once the backup has
    /// started nothing is cancelled; the install then completes or rolls back.
    func cancelEngineInstall() {
        switch engineInstall {
        case .fetchingRelease:
            engineInstallTask?.cancel()
            engineInstallTask = nil
            engineInstall = .idle
        case .confirming:
            engineInstall = .idle
        case .installing(let progress, _) where progress.phase.isCancellable:
            engineInstallTask?.cancel()
            engineInstall = .installing(progress, cancelling: true)
        default:
            break
        }
    }

    /// The main window closes: a fetch or a confirmation is dropped and a download/extraction is cancelled (its
    /// temporary files are removed by the core); a running backup/install is left to finish or roll back.
    func engineInstallWindowWillClose() {
        cancelEngineInstall()
    }

    /// The app quits: like a window close, then waits until the install task has ended (cleanup or rollback done).
    func stopEngineInstallForQuit() async {
        cancelEngineInstall()
        await engineInstallTask?.value
    }

    /// Hides the finished / failed / blocked result. While an installed engine waits for its identity verification
    /// the result stays (no "supported" claim before it).
    func dismissEngineInstallResult() {
        switch engineInstall {
        case .finished where engineInstallAwaitingVerification:
            return
        case .finished, .fetchFailed, .blocked:
            engineInstall = .idle
            engineInstallLaunchStatus = nil
        default:
            break
        }
    }

    /// "Open Engine" after an install (user action only; the app never opens it by itself): the engine must be known
    /// to be closed. Afterwards the engine is assumed to run; the user quits it and presses Refresh.
    @discardableResult
    func openEngineAfterInstall() -> Task<Void, Never>? {
        guard engineInstallAwaitingVerification, engineInstallLaunchTask == nil,
              let environment = engineInstallEnvironment else { return nil }
        let state = deps.gameProcessDetector.engineProcessState()
        syncEngineProcessState(state)
        switch state {
        case .running:
            engineInstallLaunchStatus = .engineRunning
            return nil
        case .unavailable:
            engineInstallLaunchStatus = .processUnavailable
            logError(.engineInstall, "open: error=processUnavailable")
            return nil
        case .notRunning:
            break
        }
        let launcher = deps.appLauncher
        let app = environment.targetApp
        let task = Task {
            do {
                try await launcher.open(app: app, arguments: [])
                engineInstallLaunchStatus = .launched
                syncEngineProcessState(.running)
            } catch {
                engineInstallLaunchStatus = .failed(String(describing: error))
                logError(.engineInstall, "open: error=launchFailed")
            }
            engineInstallLaunchTask = nil
        }
        engineInstallLaunchTask = task
        return task
    }

    /// After a refresh with the engine closed: compares the identity labels before and after the install in the core
    /// verifier (global + game folder non-zero and equal). Only `identityRepaired` / `alreadyHealthy` end the wait.
    private func verifyEngineInstall(_ report: MacIdentityReport) {
        guard engineInstallAwaitingVerification, report.processState == .notRunning,
              let before = engineInstallBefore, let environment = engineInstallEnvironment,
              var finish = engineInstall.finish else { return }
        let after = engineIdentityReader.snapshot(home: deps.paths.home, gamedir: environment.gamedirURL)
        let result = EngineIdentityVerifier.evaluate(before: before, after: after)
        finish.verification = result
        engineInstall = .finished(finish)
        if result.mayClaimSupported { engineInstallAwaitingVerification = false }
    }

    // MARK: §74 engine backups (Settings > Data)

    /// Inventory of `engine-backups` (`nil` before the first read).
    private(set) var engineBackups: EngineBackupInventory?
    private(set) var engineBackupsError: EngineInstallFailure?
    /// Result of the last confirmed deletion (a partial failure is shown, never called a success).
    private(set) var engineBackupDeletion: EngineBackupDeletionReport?
    /// `confirmationRequired`: the folder changed since the confirmation; `locked`: an install is running.
    private(set) var engineBackupDeletionError: EngineInstallFailure?
    var showsEngineBackupDeletionConfirmation = false
    @ObservationIgnored private var engineBackupToken: EngineBackupDeletionToken?

    var engineBackupStore: EngineBackupStore {
        EngineBackupStore(root: deps.paths.engineBackupsDirectory, files: deps.engineFileOperations)
    }

    /// Reads the backup folder (read-only; nothing is ever deleted automatically).
    func loadEngineBackups() {
        do {
            engineBackups = try engineBackupStore.inventory()
            engineBackupsError = nil
        } catch {
            let failure = error as? EngineInstallFailure ?? .backupFailed
            engineBackups = nil
            engineBackupsError = failure
            logError(.engineInstall, "backups: error=\(failure.code)")
        }
    }

    /// "Delete Older Backups…": a token is issued for the prune candidates of the current inventory only; the
    /// confirmation opens. Nothing is deleted here.
    func requestEngineBackupDeletion() {
        engineBackupDeletion = nil
        engineBackupDeletionError = nil
        guard engineInstallTask == nil else {
            engineBackupDeletionError = .locked
            return
        }
        loadEngineBackups()
        guard let inventory = engineBackups, !inventory.pruneCandidates.isEmpty else { return }
        switch engineBackupStore.confirmDeletion(of: inventory.pruneCandidates.map(\.stamp), in: inventory) {
        case .success(let token):
            engineBackupToken = token
            showsEngineBackupDeletionConfirmation = true
        case .failure(let failure):
            engineBackupDeletionError = failure
        }
    }

    /// Confirmed: deletes exactly the confirmed groups (a changed folder deletes nothing). Partial failures are shown
    /// and logged; the records of a group that could not be removed are kept by the core.
    func confirmEngineBackupDeletion() {
        showsEngineBackupDeletionConfirmation = false
        guard let token = engineBackupToken else { return }
        engineBackupToken = nil
        guard engineInstallTask == nil else {
            engineBackupDeletionError = .locked
            return
        }
        switch engineBackupStore.deleteBackups(token) {
        case .success(let report):
            engineBackupDeletion = report
            if report.status == .partialFailure {
                logError(.engineInstall, "backups: delete=partialFailure,failed=\(report.failed.count)")
            }
        case .failure(let failure):
            engineBackupDeletionError = failure
            logError(.engineInstall, "backups: delete,error=\(failure.code)")
        }
        loadEngineBackups()
    }

    func cancelEngineBackupDeletion() {
        showsEngineBackupDeletionConfirmation = false
        engineBackupToken = nil
    }

    // MARK: §67.3 launch summary

    /// The card at the top of the main window: a server with at least 2 ban verdicts in the last 7 days; `nil` when
    /// there is none or the card was hidden today.
    private(set) var launchSummary: LaunchSummary?

    /// Scans the last 7 days of `diagnose` history lines (no network; read off the main thread).
    func evaluateLaunchSummary() async {
        guard !LaunchSummary.isDismissed(defaults: deps.defaults, now: deps.now()) else {
            launchSummary = nil
            return
        }
        let entries = await loadHistory()
        launchSummary = LaunchSummary.make(entries: entries, servers: ServerOrganization.sections(servers).flatMap(\.servers),
                                           now: deps.now())
    }

    /// Hides the card for the rest of the local day (UserDefaults); the next day it is evaluated again.
    func dismissLaunchSummary() {
        LaunchSummary.dismiss(defaults: deps.defaults, now: deps.now())
        launchSummary = nil
    }

    /// "Details": opens the server details (diagnosis trend included). Returns the server opened.
    @discardableResult
    func openLaunchSummaryDetails() -> UUID? {
        guard let id = launchSummary?.serverID, servers.contains(where: { $0.id == id }) else { return nil }
        requestedServerDetail = id
        return id
    }

    // MARK: §67.4 Spotlight

    /// Items as last sent to the index (identifier → item); a change of the server list sends only the difference.
    @ObservationIgnored private var spotlightIndexed: [String: SpotlightServerItem] = [:]
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?

    /// Launch: the domain is replaced by the current servers (drops items of servers removed elsewhere).
    private func reindexSpotlight() {
        let items = servers.map(SpotlightServers.item(for:))
        spotlightIndexed = Dictionary(items.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
        enqueueSpotlight("reindex") { indexer in
            try await indexer.deleteAll()
            try await indexer.index(items)
        }
    }

    /// Adding, renaming, editing or deleting a server (and restores / imports) updates the changed items only.
    private func syncSpotlight() {
        let changes = SpotlightServers.changes(indexed: spotlightIndexed, servers: servers)
        guard !changes.upsert.isEmpty || !changes.remove.isEmpty else { return }
        for item in changes.upsert { spotlightIndexed[item.identifier] = item }
        for identifier in changes.remove { spotlightIndexed[identifier] = nil }
        enqueueSpotlight("update") { indexer in
            if !changes.remove.isEmpty { try await indexer.delete(identifiers: changes.remove) }
            if !changes.upsert.isEmpty { try await indexer.index(changes.upsert) }
        }
    }

    /// Index calls run one after another; a failure is written to the error log (`spotlight`), never swallowed.
    private func enqueueSpotlight(_ label: String,
                                  _ operation: @escaping @Sendable (any SpotlightIndexing) async throws -> Void) {
        let previous = spotlightTask
        let indexer = deps.spotlightIndexer
        spotlightTask = Task {
            await previous?.value
            do {
                try await operation(indexer)
            } catch {
                logError(.spotlight, "\(label): \(error)")
            }
        }
    }

    /// Waits for the queued index updates (tests).
    func waitForSpotlight() async {
        while let task = spotlightTask {
            await task.value
            if spotlightTask == task { break }
        }
    }

    /// A Spotlight result was opened: the server details are shown. `false` for an unknown server.
    @discardableResult
    func openSpotlightResult(_ identifier: String?) -> Bool {
        guard let id = SpotlightServers.serverID(identifier: identifier, servers: servers) else { return false }
        requestedServerDetail = id
        return true
    }

    // MARK: §54 error log

    /// The app's error log (diagnostics `errors.json`).
    var errorLog: ErrorLog { deps.errorLog }

    /// Records an error for the diagnostics package only; nothing is shown to the user.
    // MARK: §75 GoldSrc 48

    /// §75.3 the row is a GoldSrc 48 server: no CID is computed, shown or copied.
    func isCIDNotApplicable(_ id: UUID) -> Bool {
        // §75.3: the protocol memory first (a known GoldSrc server never shows a saved CID, whatever its address).
        if launchProtocol(for: id) == .goldsrc48 { return true }
        if let status = rowStatus(id) { return status.cidNotApplicable }
        return servers.first { $0.id == id }?.banCheck?.info?.serverProtocol == .goldsrc48
    }

    /// §75.13 IPs the app knows for a row besides the current resolution: the last successful resolution of its
    /// hostname and the address string of its saved A2S reply (both IP literals only).
    private func knownAddresses(_ entry: ServerEntry) -> [String?] {
        // Only while the row has no current address (DNS loss): a resolved row is matched by its current address.
        guard address(for: entry) == nil else { return [] }
        let name = HostValidator.classify(entry.host).flatMap { kind -> String? in
            if case .hostname(let name) = kind { return name }
            return nil
        }
        return [name.flatMap { lastResolvedAddresses[$0] }, entry.banCheck?.info?.reportedAddress]
    }

    /// §75.13 every `host:port` form the engine log may name for this row.
    private func goldSrcLogAddresses(_ entry: ServerEntry) -> Set<String> {
        GoldSrcEngineLog.addresses(host: entry.host, port: entry.port, resolved: address(for: entry)?.text,
                                   known: knownAddresses(entry))
    }

    /// §75.4 decided protocols of all rows (for the status evaluation and the ban check requests).
    func knownProtocols() -> [UUID: ServerProtocol] {
        Dictionary(servers.compactMap { entry in
            let decided = protocolMemory.launchProtocol(for: entry)
            return decided == .unknown ? nil : (entry.id, decided)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// §75.4 protocol "Join Game" uses for the row.
    func launchProtocol(for id: UUID) -> ServerProtocol {
        guard let entry = servers.first(where: { $0.id == id }) else { return .unknown }
        return protocolMemory.launchProtocol(for: entry)
    }

    /// §75.13 remembers a GoldSrc launch (the engine log blocks before it are stale for this server).
    private func noteGoldSrcJoin(_ plan: GameLaunchPlan, for id: UUID) {
        guard plan.command.serverProtocol == .goldsrc48 else { return }
        goldSrcJoins[id] = deps.now()
    }

    private func noteProtocol(_ check: BanCheck, for entry: ServerEntry) {
        guard let serverProtocol = check.info?.serverProtocol else { return }
        protocolMemory.record(serverProtocol, for: entry.id, host: entry.host, port: entry.port, at: check.checkedAt)
    }

    private func noteProtocol(_ diagnosis: ConnectionDiagnosis, for id: UUID) {
        if let error = diagnosis.goldSrcLogError { logError(.serverProtocol, "engineLog: " + error) }
        guard let entry = servers.first(where: { $0.id == id }), entry.host == diagnosis.host,
              entry.port == diagnosis.port else { return }
        protocolMemory.record(diagnosis.serverProtocol, for: id, host: entry.host, port: entry.port,
                              at: diagnosis.startedAt)
    }

    /// §75.3/§75.4: rows decided as GoldSrc 48 by this refresh (A2S reply or engine log) lose their legacy CID, and
    /// their GoldSrc result (protocol + ban status) is written into the saved record in the same atomic write
    /// (bookkeeping, not an unsaved change; the rest of the record is unchanged). A write error is logged.
    private func persistGoldSrcDecisions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in servers.indices where ids.contains(servers[index].id) && !servers[index].cid.isEmpty {
            servers[index].cid = ""
        }
        guard var saved = snapshotState.snapshot else { return }
        var changed = false
        for index in saved.servers.indices where ids.contains(saved.servers[index].id) {
            guard let current = servers.first(where: { $0.id == saved.servers[index].id }),
                  current.host == saved.servers[index].host, current.port == saved.servers[index].port else { continue }
            if !saved.servers[index].cid.isEmpty {
                saved.servers[index].cid = ""
                changed = true
            }
            if saved.servers[index].banCheck != current.banCheck {
                saved.servers[index].banCheck = current.banCheck
                changed = true
            }
        }
        guard changed else { return }
        do {
            try deps.snapshotStore.save(saved)
        } catch {
            logError(.serverProtocol, "goldSrcRecord: \(error.localizedDescription)")
            return
        }
        snapshotState = .loaded(saved)
    }

    func logError(_ area: ErrorLogArea, _ message: String) {
        deps.errorLog.record(area, message, at: deps.now())
    }

    // MARK: §69.1 ban expiry notifications

    /// Planned ban expiry notifications (`profile.json` → `banExpiryWatch`); written straight into the saved record
    /// (bookkeeping, not an unsaved change).
    private(set) var banExpiryWatches: [BanExpiryWatch] = []
    /// Settings > Notifications: "Also notify 10 minutes before a ban ends" (on by default).
    var banExpirySoonEnabled: Bool {
        didSet {
            guard banExpirySoonEnabled != oldValue else { return }
            deps.defaults.set(banExpirySoonEnabled, forKey: DefaultsKey.banExpirySoonEnabled)
            replanBanExpiries()
        }
    }
    @ObservationIgnored private var banExpiryTimer: Task<Void, Never>?
    @ObservationIgnored private var banExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var banExpiryInFlight: Set<String> = []

    private var mutedBanExpiryServers: Set<String> {
        Set(deps.defaults.stringArray(forKey: DefaultsKey.banExpiryMutedServers) ?? [])
    }

    /// The card's "Notify When It Ends" switch (on unless the user turned it off for this server).
    func isBanExpiryNotifyOn(for id: UUID) -> Bool {
        !mutedBanExpiryServers.contains(id.uuidString)
    }

    /// Turning it off removes the server's planned notifications; turning it on plans them from the last lookup.
    func setBanExpiryNotify(_ on: Bool, for id: UUID) {
        var muted = mutedBanExpiryServers
        if on { muted.remove(id.uuidString) } else { muted.insert(id.uuidString) }
        deps.defaults.set(muted.sorted(), forKey: DefaultsKey.banExpiryMutedServers)
        if on, case .finished(.success(let result))? = banRecords[id] {
            planBanExpiry(result, for: id)
        } else if !on {
            forgetBanExpiry(for: id)
        }
    }

    /// Unsent notifications planned for a server (the card's "Scheduled notification" line).
    func plannedBanExpiries(for id: UUID) -> [BanExpiryWatch] {
        banExpiryWatches.filter { $0.serverID == id && $0.notifiedAt == nil }
    }

    /// Main window row: timed bans ending within a day, with the server label.
    var upcomingBanExpiries: [(watch: BanExpiryWatch, label: String)] {
        BanExpiryPlanner.upcoming(banExpiryWatches, now: deps.now()).compactMap { watch in
            servers.first { $0.id == watch.serverID }.map { (watch, $0.label) }
        }
    }

    /// The row's lines: "<server>: in 2h 5m (date)".
    var upcomingBanExpiryLines: [String] {
        let now = deps.now()
        return upcomingBanExpiries.map { BanExpiryText.upcomingLine($0.watch, serverLabel: $0.label, now: now) }
    }

    /// A successful lookup plans (or clears) the server's notifications.
    private func planBanExpiry(_ result: BanRecordResult, for id: UUID) {
        let updated = BanExpiryPlanner.reconcile(banExpiryWatches, serverID: id, cid: rowStatus(id)?.currentCID ?? "",
                                                 result: result, notify: isBanExpiryNotifyOn(for: id),
                                                 soonEnabled: banExpirySoonEnabled)
        setBanExpiryWatches(updated)
        if checkBanExpiryNotifications() == nil { scheduleBanExpiryTimer() }
    }

    /// The ban record went away (server deleted, endpoint removed, switch off): nothing is notified for it.
    private func forgetBanExpiry(for id: UUID) {
        setBanExpiryWatches(banExpiryWatches.filter { $0.serverID != id })
        scheduleBanExpiryTimer()
    }

    /// The "10 minutes before" setting changed: `soon` records are added to or removed from the unsent bans.
    private func replanBanExpiries() {
        var watches = banExpiryWatches.filter { $0.kind != .soon || $0.notifiedAt != nil || banExpirySoonEnabled }
        if banExpirySoonEnabled {
            for ended in watches where ended.kind == .ended && ended.notifiedAt == nil
                && !watches.contains(where: { $0.serverID == ended.serverID && $0.kind == .soon }) {
                watches.append(BanExpiryWatch(serverID: ended.serverID, cid: ended.cid, expiresAt: ended.expiresAt,
                                              notifiedAt: nil, kind: .soon))
            }
        }
        setBanExpiryWatches(watches)
        scheduleBanExpiryTimer()
    }

    private func setBanExpiryWatches(_ watches: [BanExpiryWatch]) {
        guard watches != banExpiryWatches else { return }
        banExpiryWatches = watches
        persistBanExpiryWatches()
    }

    /// Writes the list into the saved record (the rest unchanged). Without a record it is written with the first Save.
    private func persistBanExpiryWatches() {
        guard var saved = snapshotState.snapshot else { return }
        let value = banExpiryWatches.isEmpty ? nil : banExpiryWatches
        guard saved.banExpiryWatch != value else { return }
        saved.banExpiryWatch = value
        do {
            try deps.snapshotStore.save(saved)
        } catch {
            logError(.banLookup, "banExpiryWatch: \(error.localizedDescription)")
            return
        }
        snapshotState = .loaded(saved)
    }

    /// Posts the due notifications: once per record, held back during quiet hours (posted once they end), dropped
    /// when notifications, ban changes or the server's notifications (`off`) are switched off. Returns the posting
    /// task, `nil` when nothing was posted.
    @discardableResult
    func checkBanExpiryNotifications() -> Task<Void, Never>? {
        let now = deps.now()
        let ids = Set(servers.map(\.id))
        let obsolete = BanExpiryPlanner.obsolete(banExpiryWatches, now: now)
        var watches = banExpiryWatches.filter { ids.contains($0.serverID) && !obsolete.contains($0) }
        var contents: [NotificationContent] = []
        var posting: [String: BanExpiryWatch] = [:]
        for watch in BanExpiryPlanner.due(watches, now: now) {
            guard let entry = servers.first(where: { $0.id == watch.serverID }) else { continue }
            let content = BanExpiryText.content(for: watch, serverLabel: entry.label)
            guard !banExpiryInFlight.contains(content.key) else { continue }
            switch BanExpiryPlanner.decision(policy: notificationPolicy, server: entry.notifications, at: now) {
            case .drop: watches.removeAll { $0 == watch }
            case .postpone: continue
            case .post:
                contents.append(content)
                posting[content.key] = watch
            }
        }
        setBanExpiryWatches(watches)
        guard !contents.isEmpty else { return nil }
        let keys = Set(posting.keys)
        banExpiryInFlight.formUnion(keys)
        let dispatcher = notificationDispatcher
        let enabled = notificationsEnabled
        let previous = banExpiryTask
        let task = Task {
            await previous?.value
            let posted = await dispatcher.handle(contents, enabled: enabled)
            await updateNotificationPermission(from: dispatcher)
            banExpiryInFlight.subtract(keys)
            let sent = posted.compactMap { posting[$0.key] }
            if !sent.isEmpty {
                let at = deps.now()
                setBanExpiryWatches(banExpiryWatches.map { watch in
                    guard sent.contains(watch) else { return watch }
                    var marked = watch
                    marked.notifiedAt = at
                    return marked
                })
            }
            scheduleBanExpiryTimer()
        }
        banExpiryTask = task
        return task
    }

    /// In-app timer (only while the app runs): wakes at the next planned time, at least every 15 minutes while
    /// something is pending; stops when nothing is.
    private func scheduleBanExpiryTimer() {
        guard backgroundTasksActive else { return }
        banExpiryTimer?.cancel()
        banExpiryTimer = nil
        guard let delay = BanExpiryPlanner.nextDelay(banExpiryWatches, now: deps.now()) else { return }
        let sleeper = deps.sleeper
        banExpiryTimer = Task { [weak self] in
            do {
                try await sleeper.sleep(seconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            if self.checkBanExpiryNotifications() == nil { self.scheduleBanExpiryTimer() }
        }
    }

    /// For tests: waits until the running ban expiry posting finishes.
    func waitForBanExpiry() async {
        await banExpiryTask?.value
    }

    // MARK: §69.2 widget

    /// Writes `widget-snapshot.json` (status, short CID, first three servers; no player IP) and reloads the widget.
    func writeWidgetSnapshot() {
        let ordered = ServerOrganization.sections(servers).flatMap(\.servers)
        let snapshot = WidgetSnapshotBuilder.make(report: report, servers: ordered, updatedAt: lastChecked ?? deps.now())
        do {
            try WidgetSnapshotStore.save(snapshot, to: deps.paths.widgetSnapshotFile)
        } catch {
            logError(.widget, "widgetSnapshot: \(error.localizedDescription)")
            return
        }
        deps.widgetReloader.reloadTimelines()
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

    // MARK: §71 folder sync

    /// "Choose Folder…": sync starts at once.
    @discardableResult
    func setSyncFolder(_ url: URL) -> Task<Void, Never> {
        let folder = url.standardizedFileURL
        syncFolder = folder
        deps.defaults.set(folder.path, forKey: DefaultsKey.syncFolder)
        syncError = nil
        syncLastSuccess = nil
        return syncNow()
    }

    /// "Remove": sync stops; the local data and the file in the folder stay as they are (§71.3).
    func removeSyncFolder() {
        syncFolder = nil
        deps.defaults.removeObject(forKey: DefaultsKey.syncFolder)
        syncDebounce.cancel()
        syncTimerTask?.cancel()
        syncTimerTask = nil
        syncError = nil
        syncLastSuccess = nil
    }

    /// Plans a sync `delay` seconds from now; another request before then pushes it back (5 s debounce after each
    /// record write, §71.2). No-op without a sync folder.
    func scheduleSync(delay: TimeInterval = SyncDebounce.delay) {
        guard syncFolder != nil else { return }
        syncDebounce.schedule(now: deps.now(), delay: delay)
        guard syncTimerTask == nil else { return }
        let sleeper = deps.sleeper
        syncTimerTask = Task { [weak self] in
            while let wait = self?.syncDebounce.remaining(now: self?.deps.now() ?? Date()) {
                if wait > 0 { try? await sleeper.sleep(seconds: wait) }
                guard !Task.isCancelled, let self else { return }
                if self.syncDebounce.fire(now: self.deps.now()) { await self.syncNow().value }
            }
            self?.syncTimerTask = nil
        }
    }

    /// The running debounce timer (tests await it).
    var pendingSyncTimer: Task<Void, Never>? { syncTimerTask }

    /// "Sync Now" (and every planned sync). A request while one runs is queued once and runs right after it.
    @discardableResult
    func syncNow() -> Task<Void, Never> {
        if let running = syncRunTask {
            syncRequestedDuringRun = true
            return running
        }
        let task = Task { [weak self] in
            await self?.performSync()
            guard let self else { return }
            self.syncRunTask = nil
            if self.syncRequestedDuringRun {
                self.syncRequestedDuringRun = false
                await self.syncNow().value
            }
        }
        syncRunTask = task
        return task
    }

    /// §71.2 quit: one last sync, at most `SyncDebounce.quitBudget` seconds. Returns whether it finished in time.
    func syncBeforeQuit() async -> Bool {
        guard syncFolder != nil else { return true }
        syncDebounce.cancel()
        syncTimerTask?.cancel()
        syncTimerTask = nil
        let run = syncNow()
        let sleeper = deps.sleeper
        // A race without a task group: a group would wait for the stuck sync too (a disk that does not answer).
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: @Sendable (Bool) -> Void = { value in
                if resumed.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: value) }
            }
            let timer = Task {
                try? await sleeper.sleep(seconds: SyncDebounce.quitBudget)
                finish(false)
            }
            Task {
                await run.value
                timer.cancel()
                finish(true)
            }
        }
    }

    /// The synced preferences (language, notifications, quiet hours, menu bar mode).
    func currentSyncSettings() -> SyncSettings {
        SyncSettings(language: appLanguage.rawValue, notificationsEnabled: notificationsEnabled,
                     notifyBanChanges: notifyBanChanges, notifyOnlineChanges: notifyOnlineChanges,
                     notifyMapChanges: notifyMapChanges, quietHoursEnabled: quietHoursEnabled,
                     quietHoursStart: quietHoursStart, quietHoursEnd: quietHoursEnd, showInMenuBar: menuBarEnabled)
    }

    private var syncDeviceID: String {
        if let id = deps.defaults.string(forKey: DefaultsKey.syncDeviceID), !id.isEmpty { return id }
        let id = UUID().uuidString
        deps.defaults.set(id, forKey: DefaultsKey.syncDeviceID)
        return id
    }

    /// Reads, merges and writes the sync file off the main thread, then applies the merged records to the saved
    /// record, the open list, the profiles and the preferences. A failed sync changes nothing locally.
    private func performSync() async {
        guard let folder = syncFolder else { return }
        if isDataOperationRunning {
            scheduleSync()   // a restore/erase/import is replacing the data: try again afterwards
            return
        }
        // The local source is the saved record; without one (first run) the open list, and nothing is deleted.
        let saved: Snapshot?
        switch snapshotState {
        case .loaded(let snapshot): saved = snapshot
        case .missing: saved = nil
        case .corrupt, .unsupportedSchema:
            failSync(.localRecordUnreadable)
            return
        }
        let base = SyncLocalData.make(profiles: profileList.profiles, servers: saved?.servers ?? servers,
                                      settings: currentSyncSettings())
        let ledgerStore = SyncLedgerStore(fileURL: deps.paths.syncStateFile)
        let ledger = ledgerStore.load()
        let engine = FolderSyncEngine(access: deps.syncFolderAccess)
        let now = deps.now()
        let deviceID = syncDeviceID
        let allowDeletions = saved != nil
        isSyncing = true
        let result = await Task.detached {
            engine.run(folder: folder, local: base, ledger: ledger, deviceID: deviceID, now: now,
                       allowDeletions: allowDeletions)
        }.value
        isSyncing = false
        guard syncFolder == folder else { return }   // removed or changed meanwhile
        syncRunCount += 1
        switch result {
        case .failure(let error):
            failSync(error)
        case .success(let outcome):
            guard applySync(outcome.merged.live, base: base) else { return }
            do {
                try ledgerStore.save(FolderSyncMerge.ledger(merged: outcome.merged, applied: currentSyncLocalData()))
            } catch {
                logError(.sync, "ledgerWrite: \(error.localizedDescription)")
            }
            syncConflictCount += outcome.conflicts
            syncError = nil
            syncLastSuccess = deps.now()
        }
    }

    private func failSync(_ error: FolderSyncError) {
        syncError = error
        logError(.sync, error.logMessage)
    }

    /// What the local data is now (the saved record when there is one).
    private func currentSyncLocalData() -> SyncLocalData {
        SyncLocalData.make(profiles: profileList.profiles, servers: snapshotState.snapshot?.servers ?? servers,
                           settings: currentSyncSettings())
    }

    /// Applies merged values everywhere they were not changed since `base` (an edit made during the sync wins and
    /// is synced next time). Returns `false` when the record could not be written (the ledger is then kept, so the
    /// next sync applies the same changes again).
    private func applySync(_ merged: SyncLocalData, base: SyncLocalData) -> Bool {
        if var saved = snapshotState.snapshot {
            let rebased = FolderSyncApply.servers(current: saved.servers, base: base, merged: merged)
            let profiles = FolderSyncApply.profiles(current: profileList.profiles, base: base, merged: merged,
                                                    defaultDataRoot: profileList.defaultDataRoot)
            if rebased != saved.servers || profiles != nil {
                saved.servers = rebased
                if let profiles { saved.profiles = profiles }
                do {
                    try deps.snapshotStore.save(saved)
                } catch {
                    saveErrorMessage = L10n.format(.saveFailed, error.localizedDescription)
                    logError(.sync, "recordWrite: \(error.localizedDescription)")
                    return false
                }
                snapshotState = .loaded(saved)
            }
            applySyncedProfiles(profiles)
            servers = FolderSyncApply.servers(current: servers, base: base, merged: merged)
        } else {
            applySyncedProfiles(FolderSyncApply.profiles(current: profileList.profiles, base: base, merged: merged,
                                                         defaultDataRoot: profileList.defaultDataRoot))
            // First run (no record yet): the synced list becomes the record, unless the user already edited.
            let rebased = FolderSyncApply.servers(current: servers, base: base, merged: merged)
            if rebased != servers {
                let edited = editedWithoutSnapshot
                servers = rebased
                if edited { markEdited() } else { save() }
            }
        }
        for entry in servers { resolveIfNeeded(entry.host) }
        if let settings = merged.settings, settings != currentSyncSettings(), base.settings == currentSyncSettings() {
            applySyncedSettings(settings)
        }
        reevaluate()
        return true
    }

    private func applySyncedProfiles(_ profiles: [Profile]?) {
        guard let profiles else { return }
        let previous = profileList.active
        profileList = ProfileList(profiles: profiles, activeID: profileList.activeID,
                                  defaultDataRoot: profileList.defaultDataRoot)
        let active = profileList.active
        if active.id != previous.id || active.dataRoot != previous.dataRoot || active.gamedir != previous.gamedir {
            applyActiveProfile()
        }
    }

    private func applySyncedSettings(_ settings: SyncSettings) {
        if let language = AppLanguageSetting(rawValue: settings.language) { appLanguage = language }
        notificationsEnabled = settings.notificationsEnabled
        notifyBanChanges = settings.notifyBanChanges
        notifyOnlineChanges = settings.notifyOnlineChanges
        notifyMapChanges = settings.notifyMapChanges
        quietHoursEnabled = settings.quietHoursEnabled
        if QuietHours.minutes(settings.quietHoursStart) != nil { quietHoursStart = settings.quietHoursStart }
        if QuietHours.minutes(settings.quietHoursEnd) != nil { quietHoursEnd = settings.quietHoursEnd }
        menuBarEnabled = settings.showInMenuBar
    }
}

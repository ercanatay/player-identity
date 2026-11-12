import Foundation
import Observation

/// §25/§27/§28 update state: release feed, banner, preferences, install/downgrade flow, data backups and the
/// "restore from backup" offer. Every external effect comes from `AppDependencies`.
@MainActor
@Observable
final class UpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        /// §49.3: the data backups before an install are being written (off the main thread).
        case backingUp
        case downloading(Double)
        case verifying
        /// Downloaded and verified in the background (automatic download); waiting for "Install".
        case ready(String)
        case installing
        case relaunching
        case cancelled
        case failed(UpdateError)
        case backupFailed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .backingUp, .downloading, .verifying, .installing, .relaunching: return true
            default: return false
            }
        }

        /// §49.2: an update is backing up the data, downloading, being verified or installed (a feed check does not
        /// count).
        var isUpdating: Bool { isBusy && self != .checking }

        /// Download/verification can still be cancelled; replacing cannot.
        var isCancellable: Bool {
            switch self {
            case .downloading, .verifying: return true
            default: return false
            }
        }
    }

    /// Confirmation sheet content (§27.3, §28.2/2).
    struct InstallRequest: Identifiable, Equatable {
        enum Origin: Equatable {
            case banner
            case settings
        }

        let id = UUID()
        let release: AppRelease
        let change: VersionChange
        /// Window that shows the confirmation sheet.
        var origin: Origin = .settings
        /// "Back up data first" (on by default; used for downgrades).
        var backupData = true
    }

    // MARK: State

    let appVersion: String
    let appBuild: String
    /// Stable releases from the feed, newest first (empty until the first check).
    private(set) var releases: [AppRelease] = []
    /// Banner: newer stable release that is not ignored.
    private(set) var availableUpdate: AppUpdate?
    private(set) var status: Status = .idle
    private(set) var lastCheck: Date?
    var preferences: UpdatePreferences {
        didSet { preferences.save(to: deps.defaults) }
    }
    var pendingInstall: InstallRequest?
    /// §28.2/5: backup offered when the record cannot be read by this version.
    private(set) var restoreOffer: DataBackup?
    var pendingRestore = false
    private(set) var restoreError: String?
    /// The backup is back in place but the app has not relaunched yet (the banner offers "Relaunch").
    private(set) var restoredAwaitingRelaunch = false
    private(set) var isRelaunchingAfterRestore = false
    private(set) var dataBackupCount = 0
    /// Release being downloaded/installed (or prepared in the background); shown in the Updates status card.
    private(set) var activeRelease: AppRelease?
    /// §49: a restore is replacing the data files; installing waits until it is done.
    var isDataOperationRunning = false

    /// Called once per newly found release version (history `appUpdateAvailable`).
    @ObservationIgnored var onUpdateFound: (String) -> Void = { _ in }

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var prepared: UpdateInstaller.Prepared?

    init(dependencies: AppDependencies) {
        deps = dependencies
        appVersion = dependencies.appVersion
        appBuild = dependencies.appBuild
        preferences = UpdatePreferences(defaults: dependencies.defaults)
        let state = UpdateState(defaults: dependencies.defaults)
        lastCheck = state.lastCheck
        availableUpdate = state.banner(currentVersion: dependencies.appVersion)
        dataBackupCount = backupStore.list().count
    }

    private var backupStore: DataBackupStore { DataBackupStore(paths: deps.paths, defaultsDomain: deps.defaultsDomain) }

    private var installer: UpdateInstaller {
        UpdateInstaller(paths: deps.paths, installedApp: deps.installedApp, currentVersion: appVersion,
                        downloader: deps.updateDownloader, fileManager: deps.updateFileManager,
                        runner: deps.updateRunner, relauncher: deps.relauncher)
    }

    /// Feed entry of the banner's release (`nil` until the feed is loaded).
    var availableRelease: AppRelease? {
        guard let version = availableUpdate?.version else { return nil }
        return releases.first { $0.version.description == version }
    }

    /// Version history: the last 20 stable releases (§28.2/1).
    var history: [AppRelease] { ReleaseFeed.history(releases) }

    func change(to release: AppRelease) -> VersionChange? {
        DowngradePlanner.change(to: release, currentVersion: appVersion)
    }

    // MARK: Checking (§25, §27.2)

    /// Launch check (at most every 24 h, only with automatic checks on) or manual check. Network errors are silent.
    /// Menu and Settings share this path: the result shows in the Settings status line and the banner (no modal alert).
    @discardableResult
    func checkForUpdates(manual: Bool = false) -> Task<Void, Never>? {
        guard let http = deps.updateHTTP, checkTask == nil, !status.isBusy || status == .checking else { return nil }
        let now = deps.now()
        if !manual {
            guard preferences.autoCheck, UpdateSchedule.isLaunchCheckDue(lastCheck: lastCheck, now: now) else { return nil }
        }
        if manual { status = .checking }
        let client = ReleaseFeedClient(http: http)
        let task = Task {
            defer { checkTask = nil }
            guard let fetched = try? await client.fetch() else {
                // Automatic checks stay silent (§25); a manual check shows the error in Settings > Updates (§27.3).
                if status == .checking { status = manual ? .failed(.feedUnavailable) : .idle }
                return
            }
            apply(feed: fetched, checkedAt: now, manual: manual)
        }
        checkTask = task
        return task
    }

    private func apply(feed: [AppRelease], checkedAt now: Date, manual: Bool) {
        releases = feed
        lastCheck = now
        var state = UpdateState(defaults: deps.defaults)
        state.lastCheck = now
        let current = SemanticVersion(appVersion)
        let newest = feed.filter { release in current.map { release.version > $0 } ?? false }.max { $0.version < $1.version }
        if let newest {
            let url = newest.pageURL.flatMap { $0.scheme == "https" ? $0 : nil } ?? UpdateChecker.releasesPageURL
            state.latest = AppUpdate(version: newest.version.description, url: url)
            onUpdateFound(newest.version.description)
        } else {
            state.latest = nil
        }
        state.save(to: deps.defaults)
        availableUpdate = state.banner(currentVersion: appVersion)
        if status == .checking || status == .upToDate || status == .failed(.feedUnavailable) {
            status = newest == nil ? .upToDate : .idle
        }
        if let newest, newest.isInstallable, preferences.autoDownload, availableUpdate != nil {
            startDownloadInBackground(newest)
        }
    }

    /// While the app stays open: another check every 6 hours (§27.2).
    func startPeriodicChecks() {
        guard periodicTask == nil else { return }
        let sleeper = deps.sleeper
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.runPeriodicCheckIfDue() else { return }
                try? await sleeper.sleep(seconds: max(delay, 60))
            }
        }
    }

    /// One periodic tick: checks if the 6-hour counter has run out (and automatic checks are on). Returns the
    /// seconds until the next tick.
    @discardableResult
    func runPeriodicCheckIfDue() -> TimeInterval {
        let now = deps.now()
        guard UpdateSchedule.isPeriodicCheckDue(lastCheck: lastCheck, now: now) else {
            return UpdateSchedule.nextPeriodicCheck(lastCheck: lastCheck, now: now).timeIntervalSince(now)
        }
        if preferences.autoCheck, let http = deps.updateHTTP, checkTask == nil, !status.isBusy {
            let client = ReleaseFeedClient(http: http)
            checkTask = Task {
                defer { checkTask = nil }
                if let fetched = try? await client.fetch() { apply(feed: fetched, checkedAt: now, manual: false) }
            }
        }
        return UpdateSchedule.periodicInterval
    }

    func stopPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// "Yoksay": hides the banner for this version.
    func ignoreUpdate() {
        guard let update = availableUpdate else { return }
        var state = UpdateState(defaults: deps.defaults)
        state.ignoredVersion = update.version
        state.save(to: deps.defaults)
        availableUpdate = nil
    }

    // MARK: Install / downgrade (§27.1, §28.2)

    /// "Yükle" in the banner: opens the confirmation for the newest release (fetching the feed if needed).
    @discardableResult
    func requestInstallOfAvailableUpdate() -> Task<Void, Never>? {
        guard let version = availableUpdate?.version else { return nil }
        if let release = releases.first(where: { $0.version.description == version }) {
            request(release, origin: .banner)
            return nil
        }
        guard let http = deps.updateHTTP else { return nil }
        let client = ReleaseFeedClient(http: http)
        return Task {
            guard let fetched = try? await client.fetch() else {
                status = .failed(.feedUnavailable)
                return
            }
            releases = fetched
            if let release = fetched.first(where: { $0.version.description == version }) { request(release, origin: .banner) }
        }
    }

    /// Opens the confirmation sheet for any other installable stable version ("Bu sürüme dön", §28.2).
    func request(_ release: AppRelease, origin: InstallRequest.Origin = .settings) {
        guard let change = change(to: release) else { return }   // same version: disabled
        guard release.isInstallable else {
            status = .failed(.missingAsset)
            return
        }
        pendingInstall = InstallRequest(release: release, change: change, origin: origin)
    }

    func cancelRequest() {
        pendingInstall = nil
    }

    /// Why "Install" / "Revert" in the confirmation sheet cannot run now (`nil` = it can). The sheet shows it and
    /// disables the button, so a refused confirmation never looks like a frozen sheet.
    var installBlockedReason: String? {
        if isDataOperationRunning { return L10n.text(.updateConfirmBlockedData) }
        if status.isBusy { return L10n.text(.updateConfirmBlockedBusy) }
        return nil
    }

    /// Confirmed: back up the data (downgrade, if chosen), then download, verify, replace and relaunch.
    ///
    /// While a data operation or another update task runs nothing starts: the request (and the sheet) stays open and
    /// `installBlockedReason` says why, so the user can wait and press the button again or cancel.
    @discardableResult
    func confirmInstall() -> Task<Void, Never>? {
        guard let request = pendingInstall, installBlockedReason == nil else { return nil }
        pendingInstall = nil
        // `backingUp` counts as updating: restores, erases and a second install are refused until it is done.
        status = .backingUp
        activeRelease = request.release
        let installer = self.installer
        let ready = prepared?.release == request.release ? prepared : nil
        // A download prepared for another release is not used: its files are removed before anything else.
        let stale = prepared?.release == request.release ? nil : prepared
        prepared = nil
        let fullBackups = FullBackupStore(paths: deps.paths, appVersion: appVersion)
        let dataBackups = request.change == .downgrade && request.backupData ? backupStore : nil
        // UserDefaults is read here (main actor); the files are written off the main thread.
        let dataDefaults = dataBackups.map { store in
            Result { try DataBackupStore.defaultsPlist(deps.defaults, domain: store.defaultsDomain) }
        }
        let from = appVersion
        let to = request.release.versionString
        let now = deps.now()
        let task = Task {
            // §49.3: full data backup (`backups/pre-update-…zip`) before every install, then (downgrade, if chosen)
            // the small data backup with the preferences export, both off the main thread. A failure stops the install.
            let failure = await Task.detached { () -> (any Error)? in
                if let stale { installer.discard(stale) }
                do {
                    try fullBackups.create(.preUpdate, now: now)
                    if let dataBackups, let dataDefaults {
                        try dataBackups.create(from: from, to: to, now: now, defaultsPlist: dataDefaults.get())
                    }
                    return nil
                } catch {
                    return error
                }
            }.value
            if dataBackups != nil { dataBackupCount = backupStore.list().count }
            if let failure {
                if prepared == nil { prepared = ready }   // a prepared download stays ready for the next attempt
                status = .backupFailed(Self.errorText(failure))
                installTask = nil
                return
            }
            do {
                let progress: @Sendable (InstallPhase) async -> Void = { phase in
                    await self.setPhase(phase)
                }
                if let ready {
                    _ = try await installer.finish(ready, progress: progress)
                } else {
                    _ = try await installer.install(request.release, progress: progress)
                }
            } catch let error as UpdateError {
                status = error == .cancelled ? .cancelled : .failed(error)
            } catch {
                status = .failed(.downloadFailed)
            }
            installTask = nil
        }
        installTask = task
        return task
    }

    /// Cancels the download/verification (§27.3). Replacing is never interrupted.
    func cancelInstall() {
        guard status.isCancellable else { return }
        installTask?.cancel()
    }

    private func setPhase(_ phase: InstallPhase) {
        switch phase {
        case .downloading(let fraction): status = .downloading(fraction)
        case .verifying: status = .verifying
        case .installing: status = .installing
        case .relaunching: status = .relaunching
        }
    }

    /// Automatic download (off by default): downloads and verifies, never installs (§27.2).
    private func startDownloadInBackground(_ release: AppRelease) {
        guard installTask == nil, prepared?.release != release else { return }
        activeRelease = release
        let installer = self.installer
        // A download prepared for an older release is removed first (the files may share names, e.g. SHA256SUMS.txt).
        let stale = prepared
        prepared = nil
        installTask = Task {
            if let stale { await Task.detached { installer.discard(stale) }.value }
            do {
                let ready = try await installer.prepare(release) { phase in await self.setPhase(phase) }
                prepared = ready
                status = .ready(release.versionString)
            } catch let error as UpdateError {
                status = error == .cancelled ? .cancelled : .failed(error)
            } catch {
                status = .failed(.downloadFailed)
            }
            installTask = nil
        }
    }

    /// For tests: waits for the running check/install.
    func waitForTasks() async {
        await checkTask?.value
        await installTask?.value
    }

    // MARK: Data backups and restore (§28.2/5, §28.3)

    /// Offers the newest compatible backup when the record has an unsupported schema.
    func evaluateRestore(snapshot: SnapshotLoadResult) {
        guard !restoredAwaitingRelaunch else { return }   // the banner keeps offering the relaunch
        restoreOffer = RestoreAdvisor.backupToOffer(snapshot: snapshot, backups: backupStore.list())
    }

    /// Confirmed restore: current data is backed up, the backup is put back, the app relaunches.
    ///
    /// The offer (and with it the banner) stays until the relaunch worked: if the files are back but the app could
    /// not relaunch, the banner shows the error and offers "Relaunch" (the data is not restored a second time).
    @discardableResult
    func confirmRestore() -> Task<Void, Never>? {
        guard let backup = restoreOffer else { return nil }
        pendingRestore = false
        restoreError = nil
        guard !restoredAwaitingRelaunch else { return relaunchAfterRestore() }
        do {
            try backupStore.restore(backup, currentVersion: appVersion, now: deps.now(), defaults: deps.defaults)
        } catch {
            restoreError = Self.errorText(error)
            return nil
        }
        restoredAwaitingRelaunch = true
        dataBackupCount = backupStore.list().count
        return relaunchAfterRestore()
    }

    /// "Relaunch" after a restore whose relaunch failed (also the last step of `confirmRestore`).
    @discardableResult
    func relaunchAfterRestore() -> Task<Void, Never>? {
        guard restoredAwaitingRelaunch, restoreOffer != nil, !isRelaunchingAfterRestore else { return nil }
        restoreError = nil
        isRelaunchingAfterRestore = true
        let relauncher = deps.relauncher
        let app = deps.installedApp
        return Task {
            do {
                try await relauncher.relaunch(app)
                restoreOffer = nil
                restoredAwaitingRelaunch = false
            } catch {
                restoreError = Self.errorText(error)
            }
            isRelaunchingAfterRestore = false
        }
    }

    /// Localized text of a restore/relaunch error.
    static func errorText(_ error: any Error) -> String {
        switch error {
        case let update as UpdateError: return UpdateStatusText.error(update)
        case let backup as FullBackupError: return backup.text
        default: return error.localizedDescription
        }
    }

    /// After "Erase All Data": the backups and any prepared download are gone.
    func dataFolderErased() {
        prepared = nil
        restoreOffer = nil
        restoredAwaitingRelaunch = false
        restoreError = nil
        if case .ready = status { status = .idle }
        dataBackupCount = backupStore.list().count
    }

    /// "Yedekleri temizle" (§28.3).
    func removeDataBackups() {
        try? backupStore.removeAll()
        dataBackupCount = backupStore.list().count
    }
}

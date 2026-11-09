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
            case .checking, .downloading, .verifying, .installing, .relaunching: return true
            default: return false
            }
        }

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
    /// Stable releases from the feed, newest first (empty until the first check).
    private(set) var releases: [AppRelease] = []
    /// Banner: newer stable release that is not ignored.
    private(set) var availableUpdate: AppUpdate?
    /// After a manual check found nothing newer.
    var manualCheckUpToDate = false
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
    private(set) var dataBackupCount = 0

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

    /// Version history: the last 20 stable releases (§28.2/1).
    var history: [AppRelease] { ReleaseFeed.history(releases) }

    func change(to release: AppRelease) -> VersionChange? {
        DowngradePlanner.change(to: release, currentVersion: appVersion)
    }

    // MARK: Checking (§25, §27.2)

    /// Launch check (at most every 24 h, only with automatic checks on) or manual check. Network errors are silent.
    /// `announce`: a manual check that finds nothing shows the "up to date" alert (menu); the Settings tab shows
    /// it in its status line instead.
    @discardableResult
    func checkForUpdates(manual: Bool = false, announce: Bool = true) -> Task<Void, Never>? {
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
                if status == .checking { status = .idle }
                return
            }
            apply(feed: fetched, checkedAt: now, manual: manual, announce: announce)
        }
        checkTask = task
        return task
    }

    private func apply(feed: [AppRelease], checkedAt now: Date, manual: Bool, announce: Bool = true) {
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
        if status == .checking || status == .upToDate { status = newest == nil ? .upToDate : .idle }
        manualCheckUpToDate = manual && announce && newest == nil
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

    /// Confirmed: back up the data (downgrade, if chosen), then download, verify, replace and relaunch.
    @discardableResult
    func confirmInstall() -> Task<Void, Never>? {
        guard let request = pendingInstall, !status.isBusy else { return nil }
        pendingInstall = nil
        status = .idle
        if request.change == .downgrade, request.backupData {
            do {
                try backupStore.create(from: appVersion, to: request.release.versionString, now: deps.now(),
                                       defaults: deps.defaults)
                dataBackupCount = backupStore.list().count
            } catch {
                status = .backupFailed(error.localizedDescription)
                return nil
            }
        }
        let installer = self.installer
        let ready = prepared?.release == request.release ? prepared : nil
        prepared = nil
        let task = Task {
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
        let installer = self.installer
        installTask = Task {
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
        restoreOffer = RestoreAdvisor.backupToOffer(snapshot: snapshot, backups: backupStore.list())
    }

    /// Confirmed restore: current data is backed up, the backup is put back, the app relaunches.
    @discardableResult
    func confirmRestore() -> Task<Void, Never>? {
        guard let backup = restoreOffer else { return nil }
        pendingRestore = false
        do {
            try backupStore.restore(backup, currentVersion: appVersion, now: deps.now(), defaults: deps.defaults)
        } catch {
            restoreError = error.localizedDescription
            return nil
        }
        restoreOffer = nil
        dataBackupCount = backupStore.list().count
        let relauncher = deps.relauncher
        let app = deps.installedApp
        return Task {
            do {
                try await relauncher.relaunch(app)
            } catch {
                restoreError = String(describing: error)
            }
        }
    }

    /// "Yedekleri temizle" (§28.3).
    func removeDataBackups() {
        try? backupStore.removeAll()
        dataBackupCount = backupStore.list().count
    }
}

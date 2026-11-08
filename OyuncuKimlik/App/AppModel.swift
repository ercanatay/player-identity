import Foundation
import Observation

/// Dış bağımlılıklar; testlerde sahteleri verilir (§9).
struct AppDependencies {
    var paths: AppPaths
    var fileSystem: any FileSystemReading
    var localIPProvider: any LocalIPProviding
    var publicIPClient: PublicIPClient
    var snapshotStore: SnapshotStore
    var defaults: UserDefaults
    var now: @Sendable () -> Date
    /// §13 ban kontrolü UDP taşıyıcısı (testlerde sahte).
    var udpTransport: any UDPTransport
    /// §15.6 `xash3d` süreci tespiti (testlerde sahte).
    var gameProcessDetector: any GameProcessDetecting
    /// §17 Düzelt: allowlist'li ağ komutu yürütücüsü ve bekleme (testlerde sahte; gerçek komut çalışmaz).
    var commandRunner: any CommandRunning
    var sleeper: any Sleeping

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
                               sleeper: TaskSleeper())
    }
}

/// Yenileme orkestrasyonu, durum ve kalıcılık (§5, §6, §8).
@MainActor
@Observable
final class AppModel {
    static let dataRootDefaultsKey = "dataRoot"
    static let banCheckDefaultsKey = "banCheckEnabled"
    static let recentNamesDefaultsKey = "recentNames"

    private(set) var dataRoot: URL
    private(set) var gamedirs: [String] = []
    private(set) var selectedGamedir: String?
    /// `nil` = henüz okunmadı.
    private(set) var identity: Result<Identity, IdentityError>?
    private(set) var config = PlayerConfig()
    private(set) var lanAddresses: [LocalAddress] = []
    /// Son yenilemede alınan genel IP; `nil` = alınamadı veya henüz kontrol edilmedi.
    private(set) var publicIP: String?
    private(set) var servers: [ServerEntry]
    private(set) var snapshotState: SnapshotLoadResult
    /// İlk tam yenileme bitene kadar `nil`.
    private(set) var report: StatusReport?
    private(set) var isRefreshing = false
    private(set) var lastChecked: Date?
    var saveErrorMessage: String?
    /// Ayarlar > "Ban kontrolü" (varsayılan açık, UserDefaults'ta saklanır). Kapalıyken ban paketi gönderilmez.
    var banCheckEnabled: Bool {
        didSet { deps.defaults.set(banCheckEnabled, forKey: Self.banCheckDefaultsKey) }
    }

    // MARK: §15 ad/model düzenleme
    /// Etkin değerlerin kaynakları (§15.2).
    private(set) var configSources = ConfigSources()
    /// `<gamedir>/models/player/` klasör adları; okunamazsa `nil`.
    private(set) var availableModels: [String]?
    /// Taslak değerler; diske yalnız Uygula ile yazılır.
    var nameDraft = ""
    var modelDraft = ""
    private(set) var recentNames: [String]
    private(set) var isApplying = false
    private(set) var applyStatus: ApplyStatus?
    /// `xash3d` süreci açık mı (yenilemede ve Uygula'da kontrol edilir).
    private(set) var isGameRunning = false
    /// Uygula sonrası kayıt "Kaydedilmedi" olur; Kaydet ile sıfırlanır.
    private var appliedSinceSave = false

    // MARK: §17 Düzelt
    struct FixSession: Identifiable, Equatable {
        /// Sunucu satırı kimliği.
        let id: UUID
        let kind: FixKind
        var phase: FixPhase = .ready
        /// Kilit reddi, yeniden kontrol sonucu gibi tek satırlık bilgi.
        var note: String?
    }

    enum FixPhase: Equatable {
        case ready
        case running(FixProgress)
        case finished(IPFixOutcome, at: Date)
    }

    /// Açık Düzelt sayfası (sheet).
    var fixSession: FixSession?
    /// Düzelt sonrası kayıt "Kaydedilmedi" olur.
    private var fixedSinceSave = false
    @ObservationIgnored private let fixLock = BanFixLock()
    @ObservationIgnored private var fixTask: Task<Void, Never>?

    static let fixLockedText = "Başka bir düzeltme sürüyor veya son 60 sn içinde yapıldı; biraz sonra tekrar deneyin."
    static let banCheckDisabledText = "Ban kontrolü Ayarlar'da kapalı; yeniden kontrol yapılmadı."
    static let recheckThrottledText = "Bu sunucu son 10 sn içinde kontrol edildi; biraz sonra tekrar deneyin."

    // MARK: §16 model önizleme
    /// Seçili gamedir'in model önizlemeleri; yüklenmemiş model sözlükte yoktur (iskelet görünüm).
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
    /// Kayıt yokken kullanıcı değişikliği yaptı mı.
    private var editedWithoutSnapshot = false

    init(dependencies: AppDependencies) {
        deps = dependencies
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
        recentNames = dependencies.defaults.stringArray(forKey: Self.recentNamesDefaultsKey) ?? []
    }

    // MARK: Türetilmiş durum

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

    // MARK: Yenileme (§6)

    /// Yeni nesil başlatır; önceki yenileme iptal edilir ve geç dönen sonucu yok sayılır.
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
        // 1–2. Kimlik + config (ana iş parçacığı dışında)
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
        identity = profile.identity
        // Düzenlenmemiş taslaklar yeni etkin değeri izler; kullanıcının taslağı korunur.
        if nameDraft == config.name { nameDraft = profile.config.name }
        if modelDraft == config.model { modelDraft = profile.config.model }
        let gamedirChanged = previewGamedir != profile.selectedGamedir
        config = profile.config
        configSources = profile.configSources
        availableModels = profile.models
        isGameRunning = gameRunning
        loadPreviews(resetting: gamedirChanged)

        if includeNetwork {
            // §13 ban kontrolü: diğer ağ adımlarıyla paralel; yenileme iptaliyle birlikte iptal edilir.
            let banRequests = banCheckEnabled
                ? BanCheckRunner.requests(servers: servers, rawID: try? profile.identity.get().rawID,
                                          name: profile.config.name)
                : []
            let checker = BanChecker(transport: deps.udpTransport, now: deps.now)
            let scheduler = banScheduler
            async let banResults = BanCheckRunner.run(banRequests, checker: checker, scheduler: scheduler)

            // 3. Yerel IP
            let provider = deps.localIPProvider
            let lan = await Task.detached { provider.localAddresses() }.value
            guard current == generation else { return }
            lanAddresses = lan

            // 4. Genel IP (birincil → yedek)
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
            for request in banRequests {
                guard let check = bans[request.serverID],
                      let index = servers.firstIndex(where: { $0.id == request.serverID }),
                      servers[index].host == request.host, servers[index].port == request.port else { continue }
                servers[index].banCheck = check
            }

            let now = deps.now()
            lastChecked = now
            for index in servers.indices { servers[index].lastCheckedAt = now }
        }

        // 5–6. CID'ler + karşılaştırma
        isRefreshing = false
        reevaluate()
    }

    /// Ağ isteği olmadan mevcut verilerle durumu yeniden hesaplar (§8). İlk tam yenilemeden önce hesap yapılmaz.
    func reevaluate() {
        guard lastChecked != nil, let identity else { return }
        let current = CurrentState(identity: identity,
                                   displayName: config.name,
                                   model: config.model,
                                   lanIPs: lanAddresses.map(\.display),
                                   publicIP: publicIP,
                                   servers: servers)
        report = StatusEvaluator.evaluate(current: current, snapshot: snapshotState)
    }

    // MARK: Kullanıcı değişiklikleri

    /// Gamedir değişince yalnız yerel dosyalar yeniden okunur (ağ isteği yok). Tam yenileme sürüyorsa yeniden başlatılır.
    @discardableResult
    func selectGamedir(_ name: String) -> Task<Void, Never>? {
        guard name != selectedGamedir else { return nil }
        selectedGamedir = name
        markEdited()
        return startRefresh(includeNetwork: isRefreshing)
    }

    /// Veri kökü seçimi UserDefaults'a yazılır; yeniden keşif + yenileme yapılır.
    @discardableResult
    func setDataRoot(_ url: URL) -> Task<Void, Never> {
        dataRoot = url.standardizedFileURL
        deps.defaults.set(dataRoot.path, forKey: Self.dataRootDefaultsKey)
        markEdited()
        return refresh()
    }

    func addServer(_ draft: ServerDraft) {
        guard draft.isValid, let port = draft.port else { return }
        servers.append(ServerEntry(label: draft.trimmedLabel, host: draft.trimmedHost, port: port))
        markEdited()
        reevaluate()
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
        markEdited()
        reevaluate()
    }

    func deleteServer(id: UUID) {
        servers.removeAll { $0.id == id }
        markEdited()
        reevaluate()
    }

    private func markEdited() {
        if snapshotState.snapshot == nil { editedWithoutSnapshot = true }
    }

    // MARK: Model önizleme (§16)

    @ObservationIgnored private var previewGamedir: String?

    /// Liste + mevcut modelin önizlemelerini arka planda yükler (async; UI bloklanmaz).
    /// Gamedir değişince eski görseller hemen temizlenir.
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

    /// Testler için: arka plandaki önizleme yüklemesinin bitmesini bekler.
    func waitForPreviews() async {
        await previewTask?.value
    }

    // MARK: Ad/model düzenleme (§15)

    var modelOptions: [ModelOption] {
        PlayerOptions.modelOptions(available: availableModels ?? [], current: config.model)
    }

    var nameOptions: [String] {
        PlayerOptions.nameOptions(current: config.name, saved: snapshotState.snapshot?.displayName, recent: recentNames)
    }

    /// Model listesi yoksa "Elle gir…" sunulur (§15.3).
    var allowsManualModelEntry: Bool {
        (availableModels ?? []).isEmpty
    }

    /// Yazılacak ad; taslak etkin değerden farklı değilse `nil`.
    var pendingName: String? {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        return trimmed == config.name ? nil : nameDraft
    }

    var pendingModel: String? {
        modelDraft == config.model ? nil : modelDraft
    }

    /// Yalnız değişen alan doğrulanır.
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

    /// Taslakları seçili gamedir'e yazar, ardından dosyaları yeniden okur (ağ isteği yok).
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
                var text = "Uygulandı · \(TimeText.format(deps.now()))"
                if !outcome.changedFiles.isEmpty { text += " · " + outcome.summary }
                applyStatus = .success(text)
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

    // MARK: Düzelt (§17)

    /// Satırın Düzelt türü; düğme yalnız `ipBanned` / `cidBanned` / `unreachable` için görünür.
    func fixKind(for id: UUID) -> FixKind? {
        FixKind.forStatus(servers.first { $0.id == id }?.banCheck?.status)
    }

    /// Yalnız sayfayı açar; hiçbir komut çalıştırmaz.
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
        return BanCheckRunner.requests(servers: [entry], rawID: try? identity?.get().rawID, name: config.name).first
    }

    /// IP ban akışı (§17.2). Onay sayfasındaki "Başlat" ile çağrılır.
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
                // 10 sn kısıtı: izin gelene kadar beklenir (en çok 10 sn).
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
            let result = await fixer.run()
            await lock.release()
            applyFixResult(result, serverID: id, request: request)
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

    /// "Yeniden kontrol et" (§17.3, §17.4): yalnız ban kontrolü; ağ komutu yok.
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
            guard let check, let index = servers.firstIndex(where: { $0.id == id }),
                  servers[index].host == request.host, servers[index].port == request.port else { return }
            servers[index].banCheck = check
            fixedSinceSave = true
            reevaluate()
            fixSession?.note = "Yeniden kontrol: \(check.status.label) · \(TimeText.format(check.checkedAt))"
        }
        fixTask = task
        return task
    }

    /// İtiraz metni (§17.9.1); satırda ban sonucu yoksa `nil`.
    func appealText(for id: UUID) -> String? {
        guard let entry = servers.first(where: { $0.id == id }), let check = entry.banCheck else { return nil }
        let cid = (try? identity?.get().rawID).flatMap { CIDCalculator.cid(rawID: $0, host: entry.host) } ?? "bilinmiyor"
        var rangeBan: RangeBanInfo?
        if case .finished(.rangeBanned(let old, let new, let cidr), _)? = fixSession?.phase, fixSession?.id == id {
            rangeBan = RangeBanInfo(cidr: cidr, oldIP: old, newIP: new)
        }
        return AppealText.make(AppealInput(serverLabel: entry.label, host: entry.host, port: entry.port,
                                           checkedAt: check.checkedAt, playerName: config.name, cid: cid,
                                           publicIP: publicIP ?? "bilinmiyor", gamedir: selectedGamedir ?? "—",
                                           check: check, rangeBan: rangeBan))
    }

    func serverPageURL(for id: UUID) -> URL? {
        guard let entry = servers.first(where: { $0.id == id }) else { return nil }
        return GameTrackerLink.url(host: entry.host, port: entry.port)
    }

    // MARK: Kaydet (§5)

    /// Yalnızca `profile.json` yazılır.
    func save() {
        let snapshot = SnapshotBuilder.make(savedAt: deps.now(),
                                            dataRoot: dataRoot,
                                            gamedir: selectedGamedir,
                                            config: config,
                                            identity: identity,
                                            publicIP: publicIP,
                                            lanIPs: lanAddresses.map(\.display),
                                            checkedAt: lastChecked,
                                            servers: servers)
        do {
            try deps.snapshotStore.save(snapshot)
        } catch {
            saveErrorMessage = "Kayıt yazılamadı: \(error.localizedDescription)"
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

    // MARK: Ortam

    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

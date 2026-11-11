import XCTest
@testable import PlayerIdentity

/// Notification center that records calls instead of showing anything.
final class FakeNotifier: UserNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var status: NotificationAuthorization
    private var grant: Bool
    private var requests = 0
    private var posted: [NotificationContent] = []
    private var failing = false
    private var attempts = 0

    struct PostFailure: Error {}

    init(status: NotificationAuthorization = .notDetermined, grant: Bool = true) {
        self.status = status
        self.grant = grant
    }

    var requestCount: Int { lock.withLock { requests } }
    var posts: [NotificationContent] { lock.withLock { posted } }
    /// Every `post` call, including the failed ones.
    var postAttempts: Int { lock.withLock { attempts } }
    /// While on, `post` throws and nothing is recorded as posted.
    var failsPosts: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func setStatus(_ value: NotificationAuthorization) { lock.withLock { status = value } }

    func authorization() async -> NotificationAuthorization { lock.withLock { status } }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            requests += 1
            status = grant ? .authorized : .denied
            return grant
        }
    }

    func post(_ content: NotificationContent) async throws {
        let fails = lock.withLock { () -> Bool in
            attempts += 1
            if !failing { posted.append(content) }
            return failing
        }
        if fails { throw PostFailure() }
    }
}

/// Builds an `AppModel` on a temporary home with fake network, notifications and update API.
@MainActor
final class TestAppEnvironment {
    let temp: TempDirectory
    let defaults: UserDefaults
    let suiteName: String
    let clock = TestClock()

    init() throws {
        temp = try TempDirectory()
        suiteName = "PlayerIdentityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        try temp.write("home/Library/Application Support/Xash3D FWGS/valve/config.cfg", "name \"N\"\nmodel \"gordon\"\n")
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
    var valveDir: URL { home.appendingPathComponent("Library/Application Support/Xash3D FWGS/valve", isDirectory: true) }
    var historyStore: HistoryStore { HistoryStore(fileURL: AppPaths(home: home).historyFile) }

    func makeModel(publicIPs: HTTPScript = HTTPScript(defaultBody: #"{"ip":"203.0.113.7"}"#),
                   udp: FakeUDPTransport? = nil,
                   resolver: FakeAddressResolver = FakeAddressResolver(),
                   notifier: any UserNotifying = NoopNotifier(),
                   updates: HTTPScript? = nil,
                   appVersion: String = "1.0",
                   game: FakeGameDetector = FakeGameDetector(),
                   configure: (inout AppDependencies) -> Void = { _ in }) -> AppModel {
        let clock = self.clock
        var deps = AppDependencies(
            paths: AppPaths(home: home),
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: [LocalAddress(interface: "en0", family: .ipv4, address: "192.0.2.10")]),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: publicIPs)),
            snapshotStore: SnapshotStore(fileURL: AppPaths(home: home).snapshotFile),
            defaults: defaults,
            now: { clock.now },
            udpTransport: udp ?? FakeServer.healthy(clock: clock),
            gameProcessDetector: game,
            commandRunner: FakeCommandRunner(),
            sleeper: FakeSleeper(clock: clock),
            resolver: resolver)
        deps.notifier = notifier
        deps.updateHTTP = updates.map { ScriptedHTTPClient(script: $0) }
        deps.appVersion = appVersion
        // No Xash3D app unless a test installs one (the host's /Applications is never consulted).
        deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: []), homeDirectory: home)
        // No host interfaces in tests (§37); tests that need them inject a fake list.
        deps.interfaceReporter = InterfaceReporter(lister: FakeInterfaceLister([]), egress: FakeEgressRoute(nil))
        configure(&deps)
        return AppModel(dependencies: deps)
    }
}

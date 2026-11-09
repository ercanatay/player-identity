import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// Renders the v1.8 screens offscreen with fake data (no network) and writes PNG files.
/// Runs only when `PI_UI_EVIDENCE_DIR` is set (`TEST_RUNNER_PI_UI_EVIDENCE_DIR=… xcodebuild test`).
@MainActor
final class UIEvidenceTests: XCTestCase {
    private var directory: URL!
    private var language: String { Bundle.main.preferredLocalizations.first ?? "x" }

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// §33 share card with the real app icon (labels as part 2 would pass them).
    func testRenderShareCard() throws {
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        let icon = NSApplication.shared.applicationIconImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        let content = ShareCardContent(serverName: "POLIGON RPG | Turkiye'nin en uzun sunucu adi denemesi 2026",
                                       hostPort: "play.example.com:27015", cid: "d9de0eb4419608a8423241430581e91c",
                                       playerName: "TestPlayer", dateText: "09.11.2026 13:45",
                                       labels: ShareCardLabels(title: "Player Identity", server: "Server", cid: "CID",
                                                               player: "Player", date: "Date"),
                                       icon: icon)
        let png = try XCTUnwrap(ShareCardRenderer.png(content))
        try png.write(to: directory.appendingPathComponent("share-card.png"))
    }

    func testRenderScreens() async throws {
        let env = try TestAppEnvironment()
        let clock = env.clock
        let udp = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.042)))
        let resolver = FakeAddressResolver(["play.example.test": .success([TestAddresses.v4("51.68.190.91")]),
                                            "down.example.test": .failure(.network)])
        let api = HTTPScript(defaultBody: #"{"tag_name":"v1.1.0","html_url":"https://github.com/ercanatay/player-identity/releases/tag/v1.1.0"}"#)
        let model = env.makeModel(udp: udp, resolver: resolver, updates: api, appVersion: "1.0")
        model.addServer(ServerDraft(label: "POLIGON RPG", host: "play.example.test"))
        model.addServer(ServerDraft(label: "Missing", host: "nx.example.test"))
        model.addServer(ServerDraft(label: "Offline DNS", host: "down.example.test"))
        await model.waitForResolutions()
        await model.refresh().value
        await model.checkForUpdates()?.value
        XCTAssertNotNil(model.availableUpdate)
        XCTAssertNotNil(model.servers.first?.banCheck?.info)

        try render(ContentView(model: model), size: CGSize(width: 900, height: 1100), name: "main")

        let ids = model.servers.map(\.id)
        let t0 = clock.now
        let entries = [
            HistoryEntry(ts: t0, kind: .refresh, new: "orange"),
            HistoryEntry(ts: t0.addingTimeInterval(60), kind: .banAppeared, serverID: ids[0], host: "play.example.test",
                         old: nil, new: "ipBanned"),
            HistoryEntry(ts: t0.addingTimeInterval(120), kind: .ipChanged, old: "203.0.113.7", new: "198.51.100.1"),
            HistoryEntry(ts: t0.addingTimeInterval(180), kind: .fixAttempt, serverID: ids[0], host: "play.example.test",
                         old: "203.0.113.7", new: "198.51.100.1", note: "resolved"),
            HistoryEntry(ts: t0.addingTimeInterval(240), kind: .banLifted, serverID: ids[0], host: "play.example.test",
                         old: "ipBanned", new: "cidOk"),
            HistoryEntry(ts: t0.addingTimeInterval(300), kind: .apply, new: "model=gina", note: "config.cfg"),
            HistoryEntry(ts: t0.addingTimeInterval(360), kind: .appUpdateAvailable, new: "1.1.0"),
        ]
        try render(HistoryView(model: model, fixedEntries: entries), size: CGSize(width: 900, height: 420), name: "history")
        try render(HistoryView(model: model, fixedEntries: entries, initialServerID: ids[0]),
                   size: CGSize(width: 900, height: 420), name: "history-filter-server")
        try render(HistoryView(model: model, fixedEntries: entries, initialKind: .identityChanged),
                   size: CGSize(width: 900, height: 420), name: "history-filter-empty")
        try render(HistoryView(model: model, fixedEntries: []), size: CGSize(width: 900, height: 420), name: "history-empty")

        let preview = AppModel.ApplyPreview(diffs: [
            ConfigFileDiff(file: .config, lines: [ConfigDiffLine(kind: .removed, number: 42, text: "model \"gordon\""),
                                                  ConfigDiffLine(kind: .added, number: 42, text: "model \"gina\""),
                                                  ConfigDiffLine(kind: .added, number: 87, text: "name \"Yeni Ad\"")]),
            ConfigFileDiff(file: .userconfig, lines: [ConfigDiffLine(kind: .removed, number: 3, text: "name \"Eski\""),
                                                      ConfigDiffLine(kind: .added, number: 3, text: "name \"Yeni Ad\"")]),
        ])
        try render(ApplyPreviewSheet(preview: preview, onWrite: {}, onCancel: {}), size: CGSize(width: 560, height: 420),
                   name: "diff")
        try render(SettingsView(model: model), size: CGSize(width: 320, height: 120), name: "settings")
    }

    func testRenderUpdateScreens() async throws {
        let env = try TestAppEnvironment()
        let paths = AppPaths(home: env.home)
        // A data backup with the supported schema, then a record this version cannot read → restore banner.
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", #"{"schemaVersion":1}"#)
        try DataBackupStore(paths: paths, defaultsDomain: env.suiteName)
            .create(from: "1.1.0", to: "2.0.0", now: env.clock.now, defaults: env.defaults)
        try env.temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", #"{"schemaVersion":2}"#)

        let (json, files) = UpdateControllerTests.feed(["1.2.0", "1.1.0", "1.0.0"])
        let installed = try env.temp.makeDirectory("Applications").appendingPathComponent("PlayerIdentity.app")
        try UpdateFixture.makeApp(at: installed, bundleID: UpdateInstaller.bundleID, version: "1.1.0", marker: "old")
        let clock = env.clock
        var deps = AppDependencies(
            paths: paths, fileSystem: LocalFileSystem(), localIPProvider: FixedLocalIPProvider(addresses: []),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: nil))),
            snapshotStore: SnapshotStore(fileURL: paths.snapshotFile), defaults: env.defaults, now: { clock.now },
            udpTransport: FakeServer.healthy(clock: clock), gameProcessDetector: FakeGameDetector(),
            commandRunner: FakeCommandRunner(), sleeper: FakeSleeper(clock: clock), resolver: FakeAddressResolver())
        deps.updateHTTP = ScriptedHTTPClient(script: HTTPScript(defaultBody: json))
        deps.appVersion = "1.1.0"
        deps.installedApp = installed
        deps.updateDownloader = GatedDownloader(files: files)
        deps.relauncher = FakeRelauncher()
        deps.defaultsDomain = env.suiteName
        let model = AppModel(dependencies: deps)
        await model.checkForUpdates()?.value
        XCTAssertNotNil(model.updates.restoreOffer)
        XCTAssertEqual(model.availableUpdate?.version, "1.2.0")

        try render(ContentView(model: model), size: CGSize(width: 900, height: 1000), name: "update-banner")

        let newer = try XCTUnwrap(model.updates.history.first)
        let older = try XCTUnwrap(model.updates.history.last)
        try render(InstallConfirmSheet(updates: model.updates,
                                       request: UpdateController.InstallRequest(release: newer, change: .upgrade)),
                   size: CGSize(width: 520, height: 400), name: "update-confirm")
        model.updates.request(older)
        let downgrade = try XCTUnwrap(model.updates.pendingInstall)
        try render(InstallConfirmSheet(updates: model.updates, request: downgrade),
                   size: CGSize(width: 520, height: 480), name: "downgrade-confirm")
        model.updates.cancelRequest()

        try render(UpdateSettingsView(updates: model.updates), size: CGSize(width: 600, height: 600), name: "settings-updates")

        // Install of 1.2.0 held at 42 % of the download → progress + cancel in Settings and in the banner.
        model.updates.request(newer, origin: .banner)
        let install = model.updates.confirmInstall()
        for _ in 0..<50 where model.updates.status != .downloading(0.42) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.updates.status, .downloading(0.42))
        try render(UpdateSettingsView(updates: model.updates), size: CGSize(width: 600, height: 600),
                   name: "settings-updates-progress")
        try render(UpdateBanner(updates: model.updates, update: try XCTUnwrap(model.availableUpdate)),
                   size: CGSize(width: 1000, height: 50), name: "update-banner-progress")
        model.updates.cancelInstall()
        await install?.value
        XCTAssertEqual(model.updates.status, .cancelled)
        XCTAssertEqual(UpdateFixture.marker(of: installed), "old")
    }

    /// v2.0 screens (§29–§33): groups + favorites + filter, notes/appeal, share card, menu bar, Settings > General.
    func testRenderV2Screens() async throws {
        let env = try TestAppEnvironment()
        let clock = env.clock
        let udp = FakeUDPTransport(clock: clock) { endpoint, packet in
            if endpoint.address == TestAddresses.v4("192.0.2.30") {
                return FakeServer.scripted(challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8))))(endpoint, packet)
            }
            return FakeServer.scripted(info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.031))(endpoint, packet)
        }
        let item = FakeLoginItem()
        item.registersAs = .requiresApproval
        let model = env.makeModel(udp: udp) { deps in
            deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: ["/Applications/Xash3D-FWGS.app"]),
                                                 homeDirectory: URL(fileURLWithPath: "/Users/test"))
            deps.gameLaunchRunner = FakeGameLaunchRunner()
            deps.loginItem = item
        }
        model.addServer(ServerDraft(label: "POLIGON RPG", host: "192.0.2.10", group: "Europe", favorite: true))
        model.addServer(ServerDraft(label: "Deathmatch EU", host: "192.0.2.20", group: "Europe"))
        model.addServer(ServerDraft(label: "Zombie TR", host: "192.0.2.30", group: "Turkey"))
        model.addServer(ServerDraft(label: "LAN", host: "192.0.2.40"))
        model.addServer(ServerDraft(label: "Surf EU", host: "192.0.2.50", group: "Europe"))
        await model.refresh().value
        let ids = model.servers.map(\.id)
        model.setNote("Admin: discord.gg/example · ban 2026-11-01", for: ids[1])
        model.saveAppeal(Appeal(sentAt: clock.now.addingTimeInterval(-5 * 86_400), channel: .discord, status: .sent,
                                followUpAt: clock.now.addingTimeInterval(-86_400),
                                summary: "IP ban; new IP after router restart, CID unchanged."), for: ids[2])
        model.menuBarEnabled = true
        model.setLaunchAtLogin(true)

        try render(ContentView(model: model), size: CGSize(width: 1000, height: 1250), name: "v2-main")
        model.serverFilter.onlyBanned = true
        try render(ContentView(model: model), size: CGSize(width: 1000, height: 1000), name: "v2-filter-banned")
        model.serverFilter = ServerListFilter(onlyFavorites: true)
        try render(ContentView(model: model), size: CGSize(width: 1000, height: 1000), name: "v2-filter-favorites")
        model.serverFilter = ServerListFilter()

        var draft = ServerDraft(entry: model.servers[3])
        draft.group = "Asia"
        try render(ServerFormSheet(title: L10n.text(.serverEditTitle), confirmTitle: L10n.text(.actionOK),
                                   groups: model.serverGroups, draft: draft, onConfirm: { _ in }, onCancel: {}),
                   size: CGSize(width: 400, height: 330), name: "v2-server-form")
        try render(ServerDetailSheet(model: model, serverID: ids[2], onClose: {}),
                   size: CGSize(width: 560, height: 520), name: "v2-details")
        try render(ServerDetailSheet(model: model, serverID: ids[2], onClose: {},
                                     editingAppeal: AppealDraft(try XCTUnwrap(model.servers[2].appeal), now: clock.now)),
                   size: CGSize(width: 560, height: 680), name: "v2-appeal-form")
        try render(ShareCardSheet(model: model, serverID: ids[0], onClose: {}),
                   size: CGSize(width: 640, height: 470), name: "v2-share-card")
        try render(MenuBarEvidenceView(model: model), size: CGSize(width: 420, height: 260), name: "v2-menubar")
        try render(GeneralSettingsView(model: model), size: CGSize(width: 600, height: 300), name: "v2-settings-general")
        item.fails = true
        model.setLaunchAtLogin(false)
        try render(GeneralSettingsView(model: model), size: CGSize(width: 600, height: 300), name: "v2-settings-general-error")

        let t0 = clock.now
        let entries = [
            HistoryEntry(ts: t0, kind: .appeal, serverID: ids[2], host: "192.0.2.30", old: nil, new: "sent", note: "discord"),
            HistoryEntry(ts: t0.addingTimeInterval(60), kind: .appeal, serverID: ids[2], host: "192.0.2.30",
                         old: "sent", new: "answered", note: "discord"),
            HistoryEntry(ts: t0.addingTimeInterval(120), kind: .appeal, serverID: ids[2], host: "192.0.2.30",
                         old: "answered", new: "accepted", note: "email"),
        ]
        try render(HistoryView(model: model, fixedEntries: entries, initialKind: .appeal),
                   size: CGSize(width: 900, height: 420), name: "v2-history-appeal")
    }

    /// v2.2 screens (§36–§41): interfaces/VPN, ban matrix + CSV, appeal timeline + postpone, ban list field,
    /// ping/player charts, diagnostics in Settings.
    func testRenderV22Screens() async throws {
        let env = try TestAppEnvironment()
        let clock = env.clock
        let udp = FakeUDPTransport(clock: clock) { endpoint, packet in
            switch endpoint.address {
            case TestAddresses.v4("192.0.2.30"):
                return FakeServer.scripted(challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8))))(endpoint, packet)
            case TestAddresses.v4("192.0.2.40"):
                return FakeServer.scripted(connect: FakeReply(bytes: FakeServer.oobText("errormsg\nKicked by plugin\n")))(endpoint, packet)
            default:
                return FakeServer.scripted(info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.031))(endpoint, packet)
            }
        }
        let records: [InterfaceRecord] = [
            InterfaceFixture.link("en0"), InterfaceFixture.v4("en0", "192.0.2.11"), InterfaceFixture.v6("en0", "2001:db8::10"),
            InterfaceFixture.link("en1", up: false), InterfaceFixture.v4("en1", "192.0.2.10", up: false),
            InterfaceFixture.link("utun4"), InterfaceFixture.v4("utun4", "10.8.0.2"),
            InterfaceFixture.link("bridge100"), InterfaceFixture.v4("bridge100", "192.0.2.64"),
        ]
        let model = env.makeModel(udp: udp) { deps in
            deps.interfaceReporter = InterfaceReporter(lister: FakeInterfaceLister(records), egress: FakeEgressRoute("utun4"))
        }
        model.addServer(ServerDraft(label: "POLIGON RPG", host: "192.0.2.10"))
        model.addServer(ServerDraft(label: "Zombie TR", host: "192.0.2.30"))
        model.addServer(ServerDraft(label: "Plugin EU", host: "192.0.2.40"))
        model.addServer(ServerDraft(label: "Surf, Classic", host: "192.0.2.50"))
        await model.refresh().value
        let ids = model.servers.map(\.id)
        XCTAssertEqual(model.interfaceReport?.isVPNActive, true)

        // Appeal with a timeline and a passed follow-up date; a ban list template.
        let sent = clock.now.addingTimeInterval(-6 * 86_400)
        model.saveAppeal(Appeal(sentAt: sent, channel: .discord, followUpAt: clock.now.addingTimeInterval(-86_400),
                                summary: "IP ban; CID unchanged."), for: ids[1])
        clock.advance(60)
        model.saveAppeal(try XCTUnwrap(model.servers[1].appeal?.moved(to: .answered)), for: ids[1])
        model.setBanListURL("https://panel.example.com/bans?q={cid}&ip={ip}", for: ids[1])

        try render(ContentView(model: model), size: CGSize(width: 1000, height: 1400), name: "v22-main")

        let history = [HistoryEntry(ts: clock.now, kind: .fixAttempt, serverID: ids[1], host: "192.0.2.30",
                                    old: "198.51.100.7", new: "198.51.23.9", note: "rangeBanned")]
        let rows = BanMatrix.rows(servers: model.servers, rangeBans: BanMatrix.rangeBans(from: history))
        try render(BanMatrixView(model: model, fixedRows: rows), size: CGSize(width: 900, height: 330), name: "v22-ban-matrix")
        try render(BanMatrixView(model: model, fixedRows: []), size: CGSize(width: 900, height: 200), name: "v22-ban-matrix-empty")
        try Data(CSV.encode(BanMatrixText.table(rows)).utf8)
            .write(to: directory.appendingPathComponent("v22-ban-matrix-\(language).csv"))

        // 24 h of samples every 30 minutes: ping wave, players, two offline checks.
        let samples: [MetricSample] = (0..<48).map { index in
            let ts = clock.now.addingTimeInterval(-Double(47 - index) * 1800)
            let offline = index == 20 || index == 21
            return MetricSample(ts: ts, serverID: ids[1], host: "192.0.2.30", online: !offline,
                                ping: offline ? nil : 35 + (index * 7) % 40, players: offline ? nil : 4 + (index * 5) % 22,
                                maxPlayers: 32, map: "zm_dust")
        }
        try render(ServerDetailSheet(model: model, serverID: ids[1], onClose: {}, metrics: samples, maxContentHeight: 1400),
                   size: CGSize(width: 620, height: 1250), name: "v22-details")
        try render(MetricsSection(samples: [], serverID: ids[0], now: clock.now).padding(20),
                   size: CGSize(width: 620, height: 130), name: "v22-metrics-empty")
        model.setBanListURL("", for: ids[2])
        try render(ServerDetailSheet(model: model, serverID: ids[2], onClose: {}, metrics: [], maxContentHeight: 1400),
                   size: CGSize(width: 620, height: 760), name: "v22-details-empty")
        try render(ServerDetailSheet(model: model, serverID: ids[2], onClose: {}, metrics: [], maxContentHeight: 1400,
                                     banListDraft: "http://panel.example.com/bans?q={steamid}"),
                   size: CGSize(width: 620, height: 760), name: "v22-banlist-invalid")
        try render(GeneralSettingsView(model: model), size: CGSize(width: 600, height: 480), name: "v22-settings-general")

        let zip = await model.diagnosticsArchive(appInfo: DiagnosticsAppInfo(version: "2.2.0", build: "22", osVersion: "Version 26.1",
                                                                            architecture: "arm64", language: language))
        try zip.write(to: directory.appendingPathComponent("v22-diagnostics-\(language).zip"))
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(language).png"))
    }
}

/// Serves the checksum file immediately and holds the zip download at 42 % until cancelled.
private struct GatedDownloader: UpdateDownloading {
    let files: [URL: Data]

    func download(_ url: URL, to destination: URL, expectedSize: Int,
                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        if url.lastPathComponent.hasSuffix(".zip") {
            await progress(0.42)
            try await Task.sleep(for: .seconds(60))
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (files[url] ?? Data()).write(to: destination)
    }
}

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

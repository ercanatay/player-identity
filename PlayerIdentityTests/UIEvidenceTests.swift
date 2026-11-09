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

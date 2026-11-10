import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §48 evidence: History, Ban Matrix and the Metrics card in light/dark × TR/EN, with their empty / no-match /
/// narrow states and a 5000-row history, all with fake data (no network). Runs only when `PI_UI_EVIDENCE_DIR` is set
/// (`TEST_RUNNER_PI_UI_EVIDENCE_DIR=… xcodebuild test`); PNGs go to `<dir>/windows/`.
///
/// Offscreen hosting views have no window toolbar, so the views draw their toolbar groups inline
/// (`inlineToolbar: true`); the system traffic lights are not drawn, only their space is kept.
@MainActor
final class SecondaryWindowsEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("windows", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderHistory() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let (model, env) = try await makeModel(language)
            let entries = historyEntries(model, now: env.clock.now)
            for dark in [false, true] {
                let suffix = "\(dark ? "dark" : "light")-\(language.rawValue)"
                try render(HistoryView(model: model, fixedEntries: entries, inlineToolbar: true),
                           size: CGSize(width: 900, height: 620), dark: dark, name: "history-\(suffix)")
                try render(HistoryView(model: model, fixedEntries: entries, initialKind: .identityChanged,
                                       initialServerID: model.servers[0].id, inlineToolbar: true),
                           size: CGSize(width: 900, height: 420), dark: dark, name: "history-nomatch-\(suffix)")
                try render(HistoryView(model: model, fixedEntries: [], inlineToolbar: true),
                           size: CGSize(width: 900, height: 420), dark: dark, name: "history-empty-\(suffix)")
            }
            // Minimum width (600 pt) and a server filter.
            try render(HistoryView(model: model, fixedEntries: entries, initialServerID: model.servers[1].id,
                                   inlineToolbar: true),
                       size: CGSize(width: 600, height: 420), dark: false, name: "history-narrow-light-\(language.rawValue)")
        }
    }

    /// 5000 entries: the list renders (lazily) and the first rows show.
    func testRenderHistoryFiveThousandRows() async throws {
        L10n.setting = .en
        let (model, env) = try await makeModel(.en)
        let ids = model.servers.map(\.id)
        let kinds = HistoryKind.allCases
        let entries = (0..<5_000).map { index in
            HistoryEntry(ts: env.clock.now.addingTimeInterval(-Double(index) * 61), kind: kinds[index % kinds.count],
                         serverID: index % 2 == 0 ? ids[index % ids.count] : nil, host: "192.0.2.\(index % 250)",
                         old: "203.0.113.\(index % 200)", new: "198.51.100.\(index % 200)")
        }
        let start = Date()
        try render(HistoryView(model: model, fixedEntries: entries, inlineToolbar: true),
                   size: CGSize(width: 900, height: 620), dark: true, name: "history-5000-dark-en")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testRenderBanMatrix() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let (model, env) = try await makeModel(language)
            let history = [HistoryEntry(ts: env.clock.now, kind: .fixAttempt, serverID: model.servers[1].id,
                                        host: "192.0.2.30", old: "198.51.100.7", new: "198.51.23.9", note: "rangeBanned")]
            let rows = BanMatrix.rows(servers: model.servers, rangeBans: BanMatrix.rangeBans(from: history))
            XCTAssertTrue(rows.first?.isBanned ?? false)
            for dark in [false, true] {
                let suffix = "\(dark ? "dark" : "light")-\(language.rawValue)"
                try render(BanMatrixView(model: model, fixedRows: rows, inlineToolbar: true),
                           size: CGSize(width: 860, height: 420), dark: dark, name: "banmatrix-\(suffix)")
                try render(BanMatrixView(model: model, fixedRows: rows, inlineToolbar: true),
                           size: CGSize(width: 560, height: 420), dark: dark, name: "banmatrix-narrow-\(suffix)")
                try render(BanMatrixView(model: model, fixedRows: [], inlineToolbar: true),
                           size: CGSize(width: 860, height: 340), dark: dark, name: "banmatrix-empty-\(suffix)")
            }
            try render(BanMatrixView(model: model, fixedRows: rows, inlineToolbar: true),
                       size: CGSize(width: 720, height: 420), dark: false, name: "banmatrix-720-light-\(language.rawValue)")
        }
    }

    func testRenderMetrics() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let (model, env) = try await makeModel(language)
            let id = model.servers[1].id
            let now = env.clock.now
            // 24 h every 30 minutes: ping wave, players, a one-hour outage and a single failed check.
            let samples: [MetricSample] = (0..<48).map { index in
                let offline = index == 20 || index == 21 || index == 38
                return MetricSample(ts: now.addingTimeInterval(-Double(47 - index) * 1800), serverID: id, host: "192.0.2.30",
                                    online: !offline, ping: offline ? nil : 35 + (index * 7) % 40,
                                    players: offline ? nil : 4 + (index * 5) % 22, maxPlayers: 32, map: "zm_dust")
            }
            for dark in [false, true] {
                let suffix = "\(dark ? "dark" : "light")-\(language.rawValue)"
                try render(MetricsSection(samples: samples, serverID: id, now: now).padding(Space.s4),
                           size: CGSize(width: 620, height: 420), dark: dark, name: "metrics-\(suffix)")
                try render(MetricsSection(samples: [], serverID: id, now: now).padding(Space.s4),
                           size: CGSize(width: 620, height: 160), dark: dark, name: "metrics-empty-\(suffix)")
                try render(ServerDetailSheet(model: model, serverID: id, onClose: {}, metrics: samples,
                                             maxContentHeight: 1400),
                           size: CGSize(width: 620, height: 1300), dark: dark, name: "details-metrics-\(suffix)")
            }
        }
    }

    // MARK: Fixtures

    private func makeModel(_ language: AppLanguageSetting) async throws -> (AppModel, TestAppEnvironment) {
        let env = try TestAppEnvironment()
        let udp = FakeUDPTransport(clock: env.clock) { endpoint, packet in
            switch endpoint.address {
            case TestAddresses.v4("192.0.2.30"):
                return FakeServer.scripted(challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8))))(endpoint, packet)
            case TestAddresses.v4("192.0.2.40"):
                return FakeServer.scripted(connect: FakeReply(bytes: FakeServer.oobText("errormsg\nKicked by plugin\n")))(endpoint, packet)
            default:
                return FakeServer.scripted(info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.038))(endpoint, packet)
            }
        }
        let model = env.makeModel(udp: udp)
        model.appLanguage = language
        model.addServer(ServerDraft(label: "Dust2 Only · Istanbul", host: "192.0.2.20", group: "Türkiye"))
        model.addServer(ServerDraft(label: "Zombie TR", host: "192.0.2.30", group: "Türkiye"))
        model.addServer(ServerDraft(label: "Plugin EU", host: "192.0.2.40", group: "Europe"))
        model.addServer(ServerDraft(label: "Frankfurt Mix Arena — 24/7 Dust2, Inferno, Nuke", host: "192.0.2.50"))
        model.addServer(ServerDraft(label: "HLDM Boot Camp", host: "192.0.2.60"))
        await model.refresh().value
        return (model, env)
    }

    private func historyEntries(_ model: AppModel, now: Date) -> [HistoryEntry] {
        let ids = model.servers.map(\.id)
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            HistoryEntry(ts: at(2_900), kind: .appUpdateAvailable, new: "2.8.0"),
            HistoryEntry(ts: at(2_000), kind: .ipChanged, old: "203.0.113.7", new: "198.51.100.7"),
            HistoryEntry(ts: at(1_500), kind: .banAppeared, serverID: ids[1], host: "192.0.2.30", new: "ipBanned"),
            HistoryEntry(ts: at(1_440), kind: .appeal, serverID: ids[1], host: "192.0.2.30", new: "sent", note: "discord"),
            HistoryEntry(ts: at(400), kind: .fixAttempt, serverID: ids[1], host: "192.0.2.30", old: "198.51.100.7",
                         new: "198.51.23.9", note: "rangeBanned"),
            HistoryEntry(ts: at(180), kind: .watchOffline, serverID: ids[2], host: "192.0.2.40"),
            HistoryEntry(ts: at(150), kind: .watchOnline, serverID: ids[2], host: "192.0.2.40", note: "30"),
            HistoryEntry(ts: at(95), kind: .modelChanged, old: "gordon", new: "keyturk1"),
            HistoryEntry(ts: at(60), kind: .note, serverID: ids[0], host: "192.0.2.20", old: "",
                         new: "Admin: discord.gg/example — appeals are answered on weekends, mention the CID and the time."),
            HistoryEntry(ts: at(30), kind: .banLifted, serverID: ids[0], host: "192.0.2.20", old: "cidBanned", new: "cidOk"),
            HistoryEntry(ts: at(5), kind: .refresh, old: HistoryTransitions.levelName(.green),
                         new: HistoryTransitions.levelName(.red)),
            HistoryEntry(ts: at(0.2), kind: .watchMapChanged, serverID: ids[3], host: "192.0.2.50", old: "de_dust2",
                         new: "de_inferno"),
        ]
    }

    // MARK: Rendering

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Palette.window)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = SecondaryEvidenceWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width,
                                                                 height: size.height),
                                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        window.orderBack(nil)
        window.makeKey()
        defer { window.orderOut(nil) }
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

/// Offscreen window that can be key, so controls draw in their active state.
private final class SecondaryEvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

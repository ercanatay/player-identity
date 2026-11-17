import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §67 evidence: the main window with the launch summary card (§67.3) and the server details with the "Launch Game
/// with Logging" button (§67.2: ready, log active, game running), light/dark × EN/TR, fake carriers only (no
/// network, nothing launched). Runs only when `PI_UI_EVIDENCE_DIR` is set; files go to `<dir>/sprint1/`.
@MainActor
final class SprintOneEvidenceTests: XCTestCase {
    private var directory: URL!
    private let app = "/Applications/Xash3D-FWGS.app"

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("sprint1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderLaunchSummaryAndCondebug() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language
            let env = try TestAppEnvironment()
            let apps = FakeAppLauncher()
            let model = env.makeModel(udp: FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(
                info: FakeReply(bytes: A2SFixture.goldSrc(name: Array("Zombie TR".utf8), map: "zm_dust", players: 9, max: 26)),
                connect: FakeReply(bytes: FakeServer.oobText("errormsg\nYou are banned (CID)\n"))))) { deps in
                deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [self.app]), homeDirectory: env.home)
                deps.appLauncher = apps
                deps.fileDating = FakeFileDating(after: env.clock.now, appearsAfter: 3)
            }
            model.appLanguage = language
            model.addServer(ServerDraft(label: "Zombie TR", host: "198.51.100.20", group: "Türkiye"))
            model.addServer(ServerDraft(label: "Public EU", host: "198.51.100.21"))
            await model.refresh().value
            model.save()
            let zombie = try XCTUnwrap(model.servers.first { $0.label == "Zombie TR" }?.id)
            let now = env.clock.now
            try env.historyStore.append([3, 30, 70].map { hours in
                HistoryEntry(ts: now.addingTimeInterval(-Double(hours) * 3600), kind: .diagnose, serverID: zombie,
                             host: "198.51.100.20:27015", new: hours == 30 ? "ipBanned" : "cidBanned", note: "dns=ok",
                             durationMs: 700)
            })
            await model.evaluateLaunchSummary()
            XCTAssertEqual(model.launchSummary?.bans, 3)

            // (1) Main window with the launch summary card on top.
            for dark in [false, true] {
                try render(ContentView(model: model), size: CGSize(width: 900, height: 760), dark: dark,
                           name: "launch-summary-\(dark ? "dark" : "light")-\(lang)")
            }

            // (2) Server details: the diagnosis section with "Launch Game with Logging" (ready, then log active).
            await model.startDiagnosis(for: zombie)?.value
            try render(ServerDetailSheet(model: model, serverID: zombie, onClose: {}, metrics: [], maxContentHeight: 1800),
                       size: CGSize(width: 620, height: 1200), dark: false, name: "condebug-ready-light-\(lang)")
            await model.launchGameWithLogging()?.value
            XCTAssertEqual(model.condebugState, .active("qconsole.log"))
            XCTAssertEqual(apps.calls.last?.arguments, ["-condebug"])
            for dark in [false, true] {
                try render(ServerDetailSheet(model: model, serverID: zombie, onClose: {}, metrics: [], maxContentHeight: 1800),
                           size: CGSize(width: 620, height: 1200), dark: dark,
                           name: "condebug-active-\(dark ? "dark" : "light")-\(lang)")
            }

            // (3) The game is running: the button is disabled with the reason.
            let busy = env.makeModel(game: FakeGameDetector(running: true)) { deps in
                deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [self.app]), homeDirectory: env.home)
            }
            busy.appLanguage = language
            await busy.refresh().value
            XCTAssertEqual(busy.condebugBlocker, .gameRunning)
            let busyID = try XCTUnwrap(busy.servers.first { $0.label == "Zombie TR" }?.id)
            try render(ServerDetailSheet(model: busy, serverID: busyID, onClose: {}, metrics: [], maxContentHeight: 1800),
                       size: CGSize(width: 620, height: 1200), dark: false, name: "condebug-game-running-light-\(lang)")
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Palette.window)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
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
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

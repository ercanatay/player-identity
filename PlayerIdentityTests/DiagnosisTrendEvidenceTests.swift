import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §65 evidence: the trend in the server details (filled + empty) and the menu bar with a running and a finished
/// diagnosis, light/dark × TR/EN, fake carriers only (no network).
/// Runs only when `PI_UI_EVIDENCE_DIR` is set; PNGs go to `<dir>/diagnose-trend/`.
@MainActor
final class DiagnosisTrendEvidenceTests: XCTestCase {
    private var directory: URL!
    private let server = "198.51.100.20"

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("diagnose-trend", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderTrendAndMenu() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language
            let env = try TestAppEnvironment()
            let udp = FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(
                info: FakeReply(bytes: A2SFixture.goldSrc(name: Array("Zombie TR".utf8), map: "zm_dust", players: 9, max: 26), delay: 0.4),
                challenge: FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes), delay: 0.4),
                connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned from this server (CID)"), delay: 0.4)))
            let model = env.makeModel(udp: udp)
            model.appLanguage = language
            model.addServer(ServerDraft(label: "Zombie TR", host: server, group: "Türkiye"))
            model.addServer(ServerDraft(label: "Public EU", host: "198.51.100.21"))
            await model.refresh().value
            let id = try XCTUnwrap(model.servers.first?.id)
            let emptyID = try XCTUnwrap(model.servers.last?.id)

            // Earlier runs of this server over the last days (history lines, as §64 writes them).
            let verdicts: [DiagnosisVerdict] = [.noBan, .noBan, .timeout, .noBan, .cidUnverified, .noBan, .ipBanned,
                                                .noBan, .cidBanned, .cidBanned, .cidBanned]
            let now = env.clock.now
            try env.historyStore.append(verdicts.enumerated().map { index, verdict in
                HistoryEntry(ts: now.addingTimeInterval(TimeInterval(-36_000 * (verdicts.count - index))), kind: .diagnose,
                             serverID: id, host: "\(server):27015", new: verdict.rawValue, note: "dns=ok")
            })
            model.menuBarEnabled = true
            await model.startMenuBarDiagnosis(for: id)?.value
            await model.waitForHistory()
            await model.startDiagnosis(for: id)?.value
            await model.waitForHistory()
            for dark in [false, true] {
                try await render(ServerDetailSheet(model: model, serverID: id, onClose: {}, metrics: [], maxContentHeight: 1600),
                           size: CGSize(width: 620, height: 1080), dark: dark,
                           name: "trend-filled-\(dark ? "dark" : "light")-\(lang)")
            }
            try await render(ServerDetailSheet(model: model, serverID: emptyID, onClose: {}, metrics: [], maxContentHeight: 1600),
                       size: CGSize(width: 620, height: 640), dark: false, name: "trend-empty-light-\(lang)")
            try await render(MenuBarEvidenceView(model: model), size: CGSize(width: 320, height: 360), dark: false,
                       name: "menu-diagnose-result-light-\(lang)")

            // Running from the menu bar: the A2S step waits (real time) while the menu renders.
            let runEnv = try TestAppEnvironment()
            let runModel = runEnv.makeModel(udp: FakeUDPTransport(waitsOnSilence: true,
                                                                  responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil)))
            runModel.appLanguage = language
            runModel.addServer(ServerDraft(label: "Zombie TR", host: server))
            runModel.menuBarEnabled = true
            let runID = try XCTUnwrap(runModel.servers.first?.id)
            let task = runModel.startMenuBarDiagnosis(for: runID)
            XCTAssertEqual(runModel.menuBarDiagnoses[runID], .running)
            try await render(MenuBarEvidenceView(model: runModel), size: CGSize(width: 320, height: 320), dark: true,
                       name: "menu-diagnose-running-dark-\(lang)")
            task?.cancel()
            await task?.value
        }
    }

    /// Like the §64 evidence renderer, but awaits between layout passes so `.task` (the trend's history read) finishes.
    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) async throws {
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
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

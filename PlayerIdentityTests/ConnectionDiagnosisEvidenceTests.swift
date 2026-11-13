import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §64 evidence: the server details with a running diagnosis (live step marks) and finished ones (verdict card, step
/// list, engine log matches, actions), light/dark × TR/EN, fake carriers only (no network).
/// Runs only when `PI_UI_EVIDENCE_DIR` is set (`TEST_RUNNER_PI_UI_EVIDENCE_DIR=… xcodebuild test`); PNGs go to
/// `<dir>/diagnose/`.
@MainActor
final class ConnectionDiagnosisEvidenceTests: XCTestCase {
    private var directory: URL!
    private let server = "198.51.100.20"

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("diagnose", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    private func makeModel(_ language: AppLanguageSetting, udp: (TestClock) -> FakeUDPTransport,
                           log: String? = nil) async throws -> (AppModel, UUID, TestAppEnvironment) {
        L10n.setting = language
        let env = try TestAppEnvironment()
        if let log { try env.temp.write("home/Library/Application Support/Xash3D FWGS/valve/qconsole.log", log) }
        let model = env.makeModel(udp: udp(env.clock))
        model.appLanguage = language
        model.addServer(ServerDraft(label: "Zombie TR", host: server, group: "Türkiye"))
        await model.refresh().value
        return (model, try XCTUnwrap(model.servers.first?.id), env)
    }

    func testRenderDiagnosis() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            // CID ban found by the probe, engine log with evidence lines.
            let (cidModel, cidID, cidEnv) = try await makeModel(language, udp: { clock in
                FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
                    info: FakeReply(bytes: A2SFixture.goldSrc(name: Array("Zombie TR".utf8), map: "zm_dust", players: 9, max: 26), delay: 0.042),
                    challenge: FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes), delay: 0.038),
                    connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned from this server (CID)"), delay: 0.04)))
            }, log: "Connecting to \(server):27015...\nBad challenge.\nYou have been banned\n")
            await cidModel.startDiagnosis(for: cidID)?.value
            XCTAssertEqual(cidModel.diagnosis(for: cidID)?.result?.verdict, .cidBanned)
            for dark in [false, true] {
                try render(ServerDetailSheet(model: cidModel, serverID: cidID, onClose: {}, metrics: [], maxContentHeight: 1600),
                           size: CGSize(width: 620, height: 980), dark: dark,
                           name: "diagnose-cidBanned-\(dark ? "dark" : "light")-\(lang)")
            }
            _ = cidEnv

            // Offline by probe, IP ban by the engine log (log priority).
            let (logModel, logID, logEnv) = try await makeModel(language, udp: { clock in
                FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
            }, log: "Couldn't connect to server.\nYour IP is banned\n")
            await logModel.startDiagnosis(for: logID)?.value
            XCTAssertEqual(logModel.diagnosis(for: logID)?.result?.verdict, .ipBanned)
            try render(ServerDetailSheet(model: logModel, serverID: logID, onClose: {}, metrics: [], maxContentHeight: 1600),
                       size: CGSize(width: 620, height: 980), dark: false, name: "diagnose-logOverride-light-\(lang)")
            _ = logEnv

            // Healthy server, no engine log.
            let (okModel, okID, okEnv) = try await makeModel(language, udp: { clock in FakeServer.healthy(clock: clock) })
            await okModel.startDiagnosis(for: okID)?.value
            XCTAssertEqual(okModel.diagnosis(for: okID)?.result?.verdict, .noBan)
            try render(ServerDetailSheet(model: okModel, serverID: okID, onClose: {}, metrics: [], maxContentHeight: 1600),
                       size: CGSize(width: 620, height: 900), dark: true, name: "diagnose-noBan-dark-\(lang)")
            _ = okEnv

            // Running: the A2S step waits (real time) while the view renders the live marks.
            let (runModel, runID, runEnv) = try await makeModel(language, udp: { _ in
                FakeUDPTransport(waitsOnSilence: true, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
            })
            let task = runModel.startDiagnosis(for: runID)
            for _ in 0..<40 where runModel.diagnosis(for: runID)?.current != .a2sInfo {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(runModel.diagnosis(for: runID)?.current, .a2sInfo)
            try render(ServerDetailSheet(model: runModel, serverID: runID, onClose: {}, metrics: [], maxContentHeight: 1600),
                       size: CGSize(width: 620, height: 760), dark: false, name: "diagnose-running-light-\(lang)")
            runModel.cancelDiagnosis()
            await task?.value
            _ = runEnv
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
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

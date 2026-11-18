import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §72 evidence: the "Server Console (read-only)" section switched off, with a parsed `status` output, and with an
/// auth error. Light/dark × EN/TR, fake UDP and an in-memory password store only. Runs only when
/// `PI_UI_EVIDENCE_DIR` is set; files go to `<dir>/rcon/`.
@MainActor
final class RconEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("rcon", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderRconConsole() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language
            let env = try TestAppEnvironment()
            let udp = FakeUDPTransport(clock: env.clock,
                                       responder: FakeRcon.responder(outputs: [.status: [FakeRcon.goldSrcStatus]]))
            let model = env.makeModel(udp: udp) { $0.rconSecretStore = InMemorySecretStore() }
            model.appLanguage = language
            model.addServer(ServerDraft(label: "Test Server", host: "192.0.2.50"))
            let id = try XCTUnwrap(model.servers.first?.id)
            for dark in [false, true] {
                try render(RconConsoleSection(model: model, serverID: id), dark: dark, height: 260,
                           name: "rcon-off-\(dark ? "dark" : "light")-\(lang)")
            }

            model.setRconEnabled(true, for: id)
            model.setRconPassword(RconTests.password, for: id)
            await model.runRcon(.status, for: id)?.value
            for dark in [false, true] {
                try render(RconConsoleSection(model: model, serverID: id), dark: dark, height: 440,
                           name: "rcon-status-\(dark ? "dark" : "light")-\(lang)")
            }

            model.setRconPassword("wrong", for: id)
            await model.runRcon(.banlist, for: id)?.value
            XCTAssertEqual(model.rconState(for: id), .finished(.banlist, .failure(.authFailed)))
            for dark in [false, true] {
                try render(RconConsoleSection(model: model, serverID: id), dark: dark, height: 320,
                           name: "rcon-error-\(dark ? "dark" : "light")-\(lang)")
            }
        }
    }

    private func render<V: View>(_ view: V, dark: Bool, height: CGFloat, name: String) throws {
        let size = CGSize(width: 620, height: height)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .padding(16)
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

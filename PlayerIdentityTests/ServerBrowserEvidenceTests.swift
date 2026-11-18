import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §70 evidence: the "Find Servers" window with a full list (one row already added), a filtered list, the "no servers
/// found" and the master error states; light/dark × EN/TR, fake carriers only. Runs only when `PI_UI_EVIDENCE_DIR` is
/// set; files go to `<dir>/server-browser/`.
@MainActor
final class ServerBrowserEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("server-browser", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    private static let servers: [BrowserServer] = [
        MasterFixture.server(11, name: "Cybokron Zombie Escape", map: "ze_dust_escape", players: 24, max: 32, ping: 38),
        MasterFixture.server(12, name: "Half-Life DM Classic", map: "crossfire", players: 9, max: 16, ping: 52),
        MasterFixture.server(13, name: "TR Clan War #2", map: "de_dust2", players: 10, max: 10, ping: 61, passworded: true),
        MasterFixture.server(14, name: "Bounce Arena", map: "bounce", players: 6, max: 18, ping: 74),
        MasterFixture.server(15, name: "Stalkyard 24/7", map: "stalkyard", players: 4, max: 12, ping: 88, passworded: nil),
        MasterFixture.server(16, name: "Xash3D Test Lab", map: "datacore", players: 0, max: 8, ping: 23),
        MasterFixture.server(17, name: "Snark Pit EU", map: "snark_pit", players: 2, max: 16, ping: 117),
        MasterFixture.server(18, name: "Old School Gaming", map: "dust_classic", players: 0, max: 20, ping: 142),
    ]

    func testRenderServerBrowserStates() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language
            let env = try TestAppEnvironment()
            let resolver = FakeAddressResolver(["hl1master.example.test": .failure(.notFound)])
            let model = env.makeModel(resolver: resolver) { deps in deps.masterServerHost = "hl1master.example.test" }
            model.appLanguage = language
            model.addServer(ServerDraft(label: "Zombie", host: "10.0.0.11"))
            let browser = model.serverBrowser
            browser.show(BrowserScan(addresses: Self.servers.map(\.address), servers: Self.servers, source: .master,
                                     masterEnd: .complete, timedOut: false, finishedAt: env.clock.now))
            for dark in [false, true] {
                try render(ServerBrowserView(model: model, inlineToolbar: true), dark: dark,
                           name: "browser-list-\(dark ? "dark" : "light")-\(lang)")
            }
            browser.filter = BrowserFilter(notEmpty: true, noPassword: true, maxPing: 90, sort: .ping)
            try render(ServerBrowserView(model: model, inlineToolbar: true), dark: false, name: "browser-filter-light-\(lang)")
            browser.filter = BrowserFilter(name: "nothing here")
            try render(ServerBrowserView(model: model, inlineToolbar: true), dark: false, name: "browser-nomatch-light-\(lang)")
            browser.filter = BrowserFilter()

            // The master's name does not resolve: error state with "Try Again".
            await browser.start(force: true)?.value
            XCTAssertEqual(browser.phase, .failed(.dns))
            try render(ServerBrowserView(model: model, inlineToolbar: true), dark: false, name: "browser-error-light-\(lang)")

            // The master answers with an empty list: "No servers found".
            let emptyEnv = try TestAppEnvironment()
            let empty = MasterFixture.transport(clock: emptyEnv.clock) { _ in [FakeReply(bytes: MasterFixture.reply([]))] }
            let emptyModel = emptyEnv.makeModel(udp: empty) { deps in deps.masterServerHost = MasterFixture.masterIP }
            emptyModel.appLanguage = language
            await emptyModel.serverBrowser.start()?.value
            XCTAssertEqual(emptyModel.serverBrowser.phase, .finished)
            try render(ServerBrowserView(model: emptyModel, inlineToolbar: true), dark: false, name: "browser-empty-light-\(lang)")
            try render(ServerBrowserView(model: emptyModel, inlineToolbar: true), dark: true, name: "browser-empty-dark-\(lang)")
            _ = env
        }
    }

    private func render<V: View>(_ view: V, dark: Bool, name: String) throws {
        let size = CGSize(width: 980, height: 620)
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

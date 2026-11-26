import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// Renders the main window (light, 900×1240) in every supported language into `<PI_UI_EVIDENCE_DIR>/languages/main-<code>.png`.
/// Runs only when `PI_UI_EVIDENCE_DIR` is set; uses fake data (no network).
@MainActor
final class LanguageScreenshotEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("languages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderMainWindowInAllLanguages() async throws {
        let languages = AppLanguageSetting.allCases.filter { $0 != .system }
        XCTAssertEqual(languages.count, 26)
        for language in languages {
            L10n.setting = language
            let (model, _) = try await makeDefaultModel(language)
            try render(window(model), size: CGSize(width: 900, height: 1240), dark: false, name: "main-\(language.rawValue)")
        }
    }

    // MARK: Fixtures

    private let resolver = FakeAddressResolver(["play.example.test": .success([TestAddresses.v4("192.0.2.10")]),
                                                "lego.example.test": .failure(.notFound)])

    private func interfaces(_ deps: inout AppDependencies) {
        let records: [InterfaceRecord] = [
            InterfaceFixture.link("en0"), InterfaceFixture.v4("en0", "192.0.2.24"),
            InterfaceFixture.link("utun4"), InterfaceFixture.v4("utun4", "10.8.0.6"),
            InterfaceFixture.link("en7", up: false), InterfaceFixture.v4("en7", "192.0.2.10", up: false),
        ]
        deps.interfaceReporter = InterfaceReporter(lister: FakeInterfaceLister(records), egress: FakeEgressRoute("utun4"))
    }

    private func healthyUDP(_ env: TestAppEnvironment) -> FakeUDPTransport {
        FakeUDPTransport(clock: env.clock) { endpoint, packet in
            switch endpoint.address {
            case TestAddresses.v4("192.0.2.30"):
                return FakeServer.scripted(challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8))))(endpoint, packet)
            case TestAddresses.v4("192.0.2.40"):
                return FakeServer.scripted(connect: FakeReply(bytes: FakeServer.oobText("errormsg\nKicked by plugin\n")))(endpoint, packet)
            default:
                return FakeServer.scripted(info: FakeReply(bytes: A2SFixture.xash(), delay: 0.038))(endpoint, packet)
            }
        }
    }

    private func addServers(_ model: AppModel) {
        model.addServer(ServerDraft(label: "Dust2 Only · Istanbul", host: "play.example.test", group: "Türkiye",
                                    favorite: true))
        model.addServer(ServerDraft(label: "Zombie TR", host: "192.0.2.30", group: "Türkiye", favorite: true))
        model.addServer(ServerDraft(label: "Plugin EU", host: "192.0.2.40", group: "Europe"))
        model.addServer(ServerDraft(label: "Frankfurt Mix Arena", host: "192.0.2.50", group: "Europe"))
        model.addServer(ServerDraft(label: "AWP Lego Zone", host: "lego.example.test", group: "Europe"))
        model.addServer(ServerDraft(label: "HLDM Boot Camp", host: "192.0.2.60"))
    }

    private func makeDefaultModel(_ language: AppLanguageSetting) async throws -> (AppModel, TestAppEnvironment) {
        let env = try TestAppEnvironment()
        let api = HTTPScript(defaultBody: #"{"tag_name":"v2.11.0","html_url":"https://github.com/ercanatay/player-identity/releases/tag/v2.11.0"}"#)
        let model = env.makeModel(udp: healthyUDP(env), resolver: resolver, updates: api, appVersion: "2.5.0",
                                  configure: interfaces)
        model.appLanguage = language   // the model applies the stored language at init
        addServers(model)
        await model.waitForResolutions()
        await model.refresh().value
        model.save()
        await model.checkForUpdates()?.value
        let ids = model.servers.map(\.id)
        model.setWatch(true, for: ids[0])
        model.setWatch(true, for: ids[3])
        model.setNote("Admin: discord.gg/example", for: ids[1])
        model.saveAppeal(Appeal(sentAt: env.clock.now.addingTimeInterval(-3 * 86_400), channel: .discord, status: .sent,
                                summary: "CID ban"), for: ids[1])
        model.nameDraft = "n1ght0wl"
        return (model, env)
    }

    private func window(_ model: AppModel) -> some View {
        VStack(spacing: 0) {
            LangEvidenceToolbar(model: model)
            ContentView(model: model)
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Palette.window)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = LangKeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        window.orderBack(nil)
        window.makeKey()   // active-window rendering (prominent buttons in the accent fill)
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
private final class LangKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Stand-in for the window toolbar in offscreen renders: the real toolbar views on the toolbar token, 52 pt.
private struct LangEvidenceToolbar: View {
    @Bindable var model: AppModel

    var body: some View {
        // Overlay: like a real toolbar, its contents never widen the window.
        Palette.toolbar
            .frame(height: Metrics.toolbar)
            .overlay(alignment: .leading) {
                HStack(spacing: Space.s3) {
                    Color.clear.frame(width: 64)   // system traffic lights live here (not drawn)
                    ToolbarStatusView(model: model)
                    Spacer(minLength: Space.s2)
                    HStack(spacing: Space.s1) {
                        ToolbarActionButtons(model: model)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.text2)
                }
                .padding(.horizontal, Space.s3)
            }
            .clipped()
            .overlay(alignment: .bottom) { ThemedDivider() }
    }
}

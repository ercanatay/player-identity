import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// Main window redesign evidence: light/dark × TR/EN, the M7–M10 states and the overlays, all with fake data
/// (no network). Runs only when `PI_UI_EVIDENCE_DIR` is set (`TEST_RUNNER_PI_UI_EVIDENCE_DIR=… xcodebuild test`).
///
/// An offscreen `NSHostingView` has no window toolbar, so the frames add `EvidenceToolbar` — the same toolbar views
/// on the toolbar token background; the system traffic lights are not drawn (only their space is kept).
@MainActor
final class MainWindowEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("redesign", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    // MARK: M1–M6 default: light/dark × EN/TR

    func testRenderMainWindowDefault() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let (model, env) = try await makeDefaultModel(language)
            for dark in [false, true] {
                let name = "main-\(dark ? "dark" : "light")-\(language.rawValue)"
                try render(window(model), size: CGSize(width: 900, height: 1240), dark: dark, name: name)
                try render(window(model), size: CGSize(width: 900, height: 760), dark: dark, name: name + "-760")
            }
            // Minimum window width (720 pt, below the 820 pt breakpoint): the top row stacks.
            for dark in [false, true] {
                try render(window(model), size: CGSize(width: 720, height: 1500), dark: dark,
                           name: "main-narrow-\(dark ? "dark" : "light")-\(language.rawValue)")
            }
            _ = env
        }
    }

    // MARK: M7–M10 states

    /// M7 loading: first refresh held at the public IP lookup → toolbar spinner, network skeleton, "Checking…" cells.
    func testRenderLoadingState() async throws {
        L10n.setting = .en
        let env = try TestAppEnvironment()
        let script = HTTPScript(defaultBody: #"{"ip":"203.0.113.7"}"#, gatedCall: 1)
        let model = env.makeModel(publicIPs: script, udp: healthyUDP(env), resolver: resolver,
                                  configure: interfaces)
        model.appLanguage = .en
        addServers(model)
        let refresh = model.refresh()
        await script.waitUntilGatedCallStarted()
        XCTAssertTrue(model.isRefreshing)
        try render(window(model), size: CGSize(width: 900, height: 1100), dark: false, name: "state-loading-light-en")
        try render(window(model), size: CGSize(width: 900, height: 1100), dark: true, name: "state-loading-dark-en")
        await script.releaseGate()
        await refresh.value
    }

    /// M8 empty: no identity file, no servers, offline (no public IP, no LAN address, no interface).
    func testRenderEmptyState() async throws {
        L10n.setting = .en
        let env = try TestAppEnvironment()
        try FileManager.default.removeItem(at: env.home.appendingPathComponent(".config/.xash_id"))
        let model = env.makeModel(publicIPs: HTTPScript(defaultBody: nil)) { deps in
            deps.localIPProvider = FixedLocalIPProvider(addresses: [])
            deps.interfaceReporter = InterfaceReporter(lister: FakeInterfaceLister([]), egress: FakeEgressRoute(nil))
        }
        model.appLanguage = .en
        await model.refresh().value
        XCTAssertEqual(model.identity, .failure(.missing))
        try render(window(model), size: CGSize(width: 900, height: 900), dark: true, name: "state-empty-dark-en")
        try render(window(model), size: CGSize(width: 900, height: 900), dark: false, name: "state-empty-light-en")
    }

    /// M9 error: invalid identity file and failed public IP lookup (Retry), ban cells keep working.
    func testRenderErrorState() async throws {
        let env = try TestAppEnvironment()
        try env.temp.write("home/.config/.xash_id", "not-a-hex-value")
        let model = env.makeModel(publicIPs: HTTPScript(defaultBody: nil), udp: healthyUDP(env), resolver: resolver,
                                  configure: interfaces)
        model.appLanguage = .tr
        addServers(model)
        await model.waitForResolutions()
        await model.refresh().value
        XCTAssertEqual(model.identity, .failure(.invalid))
        XCTAssertNil(model.publicIP)
        try render(window(model), size: CGSize(width: 900, height: 1150), dark: false, name: "state-error-light-tr")
        try render(window(model), size: CGSize(width: 900, height: 1150), dark: true, name: "state-error-dark-tr")
    }

    /// M10 disabled: Xash3D running (read-only profile) and ban checks off (note + "Checks off" cells).
    func testRenderDisabledState() async throws {
        L10n.setting = .tr
        let env = try TestAppEnvironment()
        let model = env.makeModel(udp: healthyUDP(env), resolver: resolver, game: FakeGameDetector(running: true),
                                  configure: interfaces)
        model.appLanguage = .tr
        model.banCheckEnabled = false
        addServers(model)
        await model.waitForResolutions()
        await model.refresh().value
        XCTAssertTrue(model.isGameRunning)
        try render(window(model), size: CGSize(width: 900, height: 1150), dark: true, name: "state-disabled-dark-tr")
        try render(window(model), size: CGSize(width: 900, height: 1150), dark: false, name: "state-disabled-light-tr")
    }

    // MARK: M11–M14 overlays

    func testRenderOverlays() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let (model, _) = try await makeDefaultModel(language)
            let lang = language.rawValue
            let preview = AppModel.ApplyPreview(diffs: [
                ConfigFileDiff(file: .config, lines: [ConfigDiffLine(kind: .removed, number: 35, text: "name \"nightowl\""),
                                                      ConfigDiffLine(kind: .added, number: 35, text: "name \"n1ght0wl\""),
                                                      ConfigDiffLine(kind: .removed, number: 41, text: "model \"gign\""),
                                                      ConfigDiffLine(kind: .added, number: 41, text: "model \"sas\"")]),
            ])
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                try render(ApplyPreviewSheet(preview: preview, onWrite: {}, onCancel: {}),
                           size: CGSize(width: 560, height: 300), dark: dark, name: "overlay-diff-\(theme)-\(lang)")
                let banned = try XCTUnwrap(model.servers.first { model.fixKind(for: $0.id) != nil })
                try render(ServerActionsPopover(title: banned.label,
                                                actions: ServerActionList.actions(for: banned, model: model, details: { _ in }),
                                                dismiss: {}).background(Palette.raised),
                           size: CGSize(width: 296, height: 190), dark: dark, name: "overlay-fix-\(theme)-\(lang)")
                let groups = model.servers.compactMap { entry -> AllActionsPopover.ActionGroup? in
                    let actions = ServerActionList.actions(for: entry, model: model, details: { _ in })
                    return actions.isEmpty ? nil : AllActionsPopover.ActionGroup(id: entry.id.uuidString, title: entry.label,
                                                                                 actions: actions)
                }
                try render(AllActionsPopover(groups: groups, dismiss: {}).background(Palette.raised),
                           size: CGSize(width: 296, height: 380), dark: dark, name: "overlay-allactions-\(theme)-\(lang)")
                try render(SuggestionsPopover(reasons: model.report?.reasons ?? []).background(Palette.raised),
                           size: CGSize(width: 440, height: 300), dark: dark, name: "overlay-suggestions-\(theme)-\(lang)")
            }
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
                return FakeServer.scripted(info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.038))(endpoint, packet)
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
        let api = HTTPScript(defaultBody: #"{"tag_name":"v2.6.0","html_url":"https://github.com/ercanatay/player-identity/releases/tag/v2.6.0"}"#)
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

    // MARK: Rendering

    private func window(_ model: AppModel) -> some View {
        VStack(spacing: 0) {
            EvidenceToolbar(model: model)
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
        let window = KeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
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
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Stand-in for the window toolbar in offscreen renders: the real toolbar views on the toolbar token, 52 pt.
private struct EvidenceToolbar: View {
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

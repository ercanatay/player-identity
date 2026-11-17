import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §68 evidence: "Server details" with players and rules (§68.1), the "Ban record" card with a result and with an
/// error (§68.2), the VPN reality card for a CID ban and an IP ban behind a VPN (§68.3); light/dark × EN/TR, fake
/// carriers only (no network, no Keychain). Runs only when `PI_UI_EVIDENCE_DIR` is set; files go to `<dir>/sprint2/`.
@MainActor
final class SprintTwoEvidenceTests: XCTestCase {
    private var directory: URL!
    private let server = "198.51.100.20"
    private let template = "https://bans.example.com/api/bans?cid={cid}"

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("sprint2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    private var vpnReporter: InterfaceReporter {
        InterfaceReporter(lister: FakeInterfaceLister([InterfaceFixture.link("utun4"), InterfaceFixture.v4("utun4", "10.8.0.2")]),
                          egress: FakeEgressRoute("utun4"))
    }

    private func model(_ env: TestAppEnvironment, language: AppLanguageSetting, connect: FakeReply?,
                       challenge: FakeReply? = FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes)),
                       http: FakeBanRecordHTTP) async throws -> (AppModel, UUID) {
        let players = A2SQueryFixture.players([("Gordon", 42, 3725), ("Alyx", 31, 1810), ("Barney", 7, 95)])
        let rules = A2SQueryFixture.rules([("sv_password", "1"), ("mp_timelimit", "30"), ("sv_cheats", "0"),
                                           ("mp_friendlyfire", "1"), ("sv_region", "3"), ("maxplayers", "26")]
                                          + (0..<70).map { ("amx_cvar_\($0)", "\($0)") })
        let base = A2SQueryFixture.server(players: players, rules: rules, connect: connect)
        let udp = FakeUDPTransport(clock: env.clock) { endpoint, packet in
            if FakeServer.isGetChallenge(packet) { return challenge.map { [$0] } ?? [] }
            return base(endpoint, packet)
        }
        let model = env.makeModel(udp: udp) { deps in
            deps.banRecordHTTP = http
            deps.secretStore = FakeSecretStore()
            deps.interfaceReporter = self.vpnReporter
        }
        model.appLanguage = language
        model.addServer(ServerDraft(label: "Zombie TR", host: server, group: "Türkiye"))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        _ = model.setBanListURL("https://bans.example.com/index.php?p=banlist&searchText={cid}", for: id)
        XCTAssertNil(model.setBanRecord(urlTemplate: template, enabled: true, token: "evidence-token", for: id))
        return (model, id)
    }

    func testRenderServerDetailsBanRecordAndVPN() async throws {
        let json = """
        {"bans":[{"reason":"Wallhack","admin":"Kerem","created":"2026-11-15T10:00:00Z","expires":"2026-12-15T10:00:00Z"},
                 {"reason":"Spam","admin":"Bot","created":"2026-01-02T10:00:00Z","expires":"2026-01-03T10:00:00Z"}]}
        """
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language

            // (1) CID ban behind a VPN, ban record found, server details loaded.
            let env = try TestAppEnvironment()
            env.clock.advance(Date(timeIntervalSince1970: 1_795_000_000).timeIntervalSince(env.clock.now))
            let (cidModel, cidID) = try await model(env, language: language,
                                                    connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned (CID)")),
                                                    http: FakeBanRecordHTTP(.body(json, status: 200)))
            await cidModel.startDiagnosis(for: cidID)?.value
            XCTAssertEqual(cidModel.diagnosis(for: cidID)?.result?.verdict, .cidBanned)
            XCTAssertEqual(VPNGuidance(try XCTUnwrap(cidModel.diagnosis(for: cidID)?.result))?.kind, .identityBan)
            await cidModel.refreshServerDetails(for: cidID)?.value
            for dark in [false, true] {
                try render(section(ConnectionDiagnosisSection(model: cidModel, serverID: cidID)), size: CGSize(width: 620, height: 1150),
                           dark: dark, name: "diagnose-vpn-cid-banrecord-\(dark ? "dark" : "light")-\(lang)")
                try render(section(ServerDetailsSection(model: cidModel, serverID: cidID)), size: CGSize(width: 620, height: 1250),
                           dark: dark, name: "server-details-\(dark ? "dark" : "light")-\(lang)")
            }
            try render(section(ServerDetailsSection(model: cidModel, serverID: cidID, search: "sv_")), size: CGSize(width: 620, height: 560),
                       dark: false, name: "server-details-search-light-\(lang)")

            // (2) IP ban behind a VPN, ban record lookup fails (401) with the ban list fallback.
            let ipEnv = try TestAppEnvironment()
            let (ipModel, ipID) = try await model(ipEnv, language: language, connect: nil,
                                                  challenge: FakeReply(bytes: FakeServer.oobText("9You are banned")),
                                                  http: FakeBanRecordHTTP(.body("denied", status: 401)))
            await ipModel.startDiagnosis(for: ipID)?.value
            XCTAssertEqual(ipModel.diagnosis(for: ipID)?.result?.verdict, .ipBanned)
            try render(section(ConnectionDiagnosisSection(model: ipModel, serverID: ipID)), size: CGSize(width: 620, height: 900),
                       dark: false, name: "diagnose-vpn-ip-banrecord-error-light-\(lang)")

            // (3) Password-protected server (no ban): the verdict from A2S_RULES and the ban record settings.
            let pwEnv = try TestAppEnvironment()
            let (pwModel, pwID) = try await model(pwEnv, language: language, connect: FakeReply(bytes: FakeServer.oob(0x42)),
                                                  http: FakeBanRecordHTTP(.body(#"{"data":[]}"#, status: 200)))
            await pwModel.startDiagnosis(for: pwID)?.value
            XCTAssertEqual(pwModel.diagnosis(for: pwID)?.result?.verdict, .passwordProtected)
            try render(ServerDetailSheet(model: pwModel, serverID: pwID, onClose: {}, metrics: [], maxContentHeight: 2600),
                       size: CGSize(width: 620, height: 2700), dark: false, name: "details-password-full-light-\(lang)")
            _ = (env, ipEnv, pwEnv)
        }
    }

    private func section<V: View>(_ view: V) -> some View {
        VStack(alignment: .leading) { view }
            .padding(20)
            .frame(width: 620)
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

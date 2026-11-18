import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §69.1 evidence: the ban record card with the "Notify When It Ends" switch and the planned times, and the main
/// window's "Upcoming ban expiries" row; light/dark × EN/TR, fake carriers only. Runs only when `PI_UI_EVIDENCE_DIR`
/// is set; files go to `<dir>/sprint3/`.
@MainActor
final class SprintThreeEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("sprint3", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderBanExpiryCardAndUpcomingRow() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language
            let env = try TestAppEnvironment()
            env.clock.advance(Date(timeIntervalSince1970: 1_795_000_000).timeIntervalSince(env.clock.now))
            let end = env.clock.now.addingTimeInterval(3 * 3600 + 25 * 60)
            let json = #"{"bans":[{"reason":"Wallhack","admin":"Kerem","created":"2026-11-15T10:00:00Z","expires":"\#(ISO8601DateFormatter().string(from: end))"}]}"#
            let model = env.makeModel { deps in
                deps.banRecordHTTP = SwitchableBanRecordHTTP(json)
                deps.secretStore = FakeSecretStore()
            }
            model.appLanguage = language
            model.addServer(ServerDraft(label: "Zombie TR", host: "198.51.100.20", group: "Türkiye"))
            await model.refresh().value
            model.save()
            let id = try XCTUnwrap(model.servers.first?.id)
            XCTAssertNil(model.setBanRecord(urlTemplate: "https://bans.example.com/api/bans?cid={cid}", enabled: true,
                                            token: nil, for: id))
            await model.refreshBanRecord(for: id)?.value
            XCTAssertEqual(model.plannedBanExpiries(for: id).count, 2)
            XCTAssertEqual(model.upcomingBanExpiryLines.count, 1)
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                try render(card(BanRecordCard(model: model, serverID: id)), size: CGSize(width: 620, height: 260), dark: dark,
                           name: "ban-expiry-card-\(mode)-\(lang)")
                try render(card(UpcomingBanExpiriesRow(model: model)), size: CGSize(width: 620, height: 110), dark: dark,
                           name: "upcoming-ban-expiries-\(mode)-\(lang)")
            }
            try render(ContentView(model: model), size: CGSize(width: 900, height: 760), dark: false,
                       name: "main-window-upcoming-light-\(lang)")
            // The switch off: no planned line.
            model.setBanExpiryNotify(false, for: id)
            try render(card(BanRecordCard(model: model, serverID: id)), size: CGSize(width: 620, height: 220), dark: false,
                       name: "ban-expiry-card-off-light-\(lang)")
            _ = env
        }
    }

    private func card<V: View>(_ view: V) -> some View {
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

import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §55/§56 evidence: server details "Notifications" section (valid / rejected thresholds) and the focus ring +
/// keyboard selection of the server table, light/dark × TR/EN, fake data only (no network).
/// Runs only when `PI_UI_EVIDENCE_DIR` is set (`TEST_RUNNER_PI_UI_EVIDENCE_DIR=… xcodebuild test`).
@MainActor
final class AccessibilityEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("accessibility", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderNotificationSectionAndFocusRing() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let env = try TestAppEnvironment()
            let model = env.makeModel()
            model.appLanguage = language
            model.addServer(ServerDraft(label: "Dust2 Only · Istanbul", host: "192.0.2.10", group: "Türkiye", favorite: true))
            model.addServer(ServerDraft(label: "Zombie TR", host: "192.0.2.30", group: "Türkiye"))
            model.addServer(ServerDraft(label: "Frankfurt Mix Arena", host: "192.0.2.50", group: "Europe"))
            await model.waitForResolutions()
            await model.refresh().value
            let ids = model.servers.map(\.id)
            model.setWatch(true, for: ids[0])
            model.setServerNotifications(ServerNotificationSettings(mode: .bansOnly, pingThresholdMs: 80, playersAtLeast: 4,
                                                                    quietHoursOverride: .off), for: ids[0])
            let lang = language.rawValue
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                try render(ServerDetailSheet(model: model, serverID: ids[0], onClose: {}, metrics: [], maxContentHeight: 1400),
                           size: CGSize(width: 620, height: 1300), dark: dark, name: "detail-notifications-\(theme)-\(lang)")
                try render(ThemedCardHost(model: model, focus: .table, selection: ids[1]),
                           size: CGSize(width: 900, height: 330), dark: dark, name: "focus-table-\(theme)-\(lang)")
                try render(ThemedCardHost(model: model, focus: .search, selection: nil),
                           size: CGSize(width: 900, height: 330), dark: dark, name: "focus-search-\(theme)-\(lang)")
            }
            let invalid = ServerNotificationDraft(mode: .all, pingText: "abc", playersText: "999", quietHours: .on)
            try render(ServerDetailSheet(model: model, serverID: ids[1], onClose: {}, metrics: [], maxContentHeight: 1400,
                                         notificationDraft: invalid),
                       size: CGSize(width: 620, height: 1300), dark: false, name: "detail-notifications-invalid-light-\(lang)")
        }
    }

    private struct ThemedCardHost: View {
        let model: AppModel
        let focus: ServersCard.ServerListFocus
        let selection: UUID?

        var body: some View {
            ServersCard(model: model, presenter: MainWindowPresenter(), previewFocus: focus, previewSelection: selection)
                .padding(Space.s4)
        }
    }

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
        let window = EvidenceKeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
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

private final class EvidenceKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

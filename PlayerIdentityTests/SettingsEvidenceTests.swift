import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// Settings window evidence (Claude Design S1–S15): General and Updates in light/dark × TR/EN, the update states
/// (available, downloading, up to date, error), the export/import sheets and the destructive confirmations, all with
/// fake data (no network). Runs only when `PI_UI_EVIDENCE_DIR` is set.
///
/// An offscreen `NSHostingView` has no window toolbar, so the frames add `SettingsEvidenceToolbar` — window title and
/// the two tab items on the toolbar token; the system traffic lights are not drawn (only their space is kept).
@MainActor
final class SettingsEvidenceTests: XCTestCase {
    private var directory: URL!
    private static let size = CGSize(width: 600, height: 600)   // 80 pt tab toolbar + 520 pt content

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    // MARK: S1–S6 General

    func testRenderGeneral() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let (model, _) = try await makeModel(language, feed: Self.feedJSON(["2.5.0", "2.4.1", "2.4.0", "2.3.2"]))
            for dark in [false, true] {
                let name = "general-\(dark ? "dark" : "light")-\(language.rawValue)"
                try render(settings(.general) { GeneralSettingsView(model: model) }, size: Self.size, dark: dark, name: name)
                try render(settings(.general) { GeneralSettingsView(model: model) },
                           size: CGSize(width: 600, height: 1320), dark: dark, name: name + "-full")
            }
            // Notifications master switch off: sub-options dimmed and disabled.
            model.notificationsEnabled = false
            try render(settings(.general) { GeneralSettingsView(model: model) }, size: CGSize(width: 600, height: 1320),
                       dark: false, name: "general-notifications-off-light-\(language.rawValue)")
        }
    }

    // MARK: S7–S11 Updates

    func testRenderUpdatesStates() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let lang = language.rawValue
            // Available (2.4.1 installed, 2.5.0 in the feed).
            let (available, _) = try await makeModel(language, feed: Self.feedJSON(["2.5.0", "2.4.1", "2.4.0", "2.3.2"]))
            await available.checkForUpdates(manual: true)?.value
            XCTAssertEqual(available.availableUpdate?.version, "2.5.0")
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                try render(updatesTab(available), size: Self.size, dark: dark, name: "updates-\(theme)-\(lang)")
                try render(updatesTab(available), size: CGSize(width: 600, height: 860), dark: dark,
                           name: "updates-available-\(theme)-\(lang)-full")
            }

            // Downloading: the zip download is held at 62 %.
            let downloader = GatedUpdateDownloader(fraction: 0.62)
            let (downloading, _) = try await makeModel(language, feed: Self.feedJSON(["2.5.0", "2.4.1", "2.4.0", "2.3.2"]),
                                                       downloader: downloader)
            await downloading.checkForUpdates(manual: true)?.value
            await downloading.updates.requestInstallOfAvailableUpdate()?.value
            XCTAssertNotNil(downloading.updates.pendingInstall)
            let install = downloading.updates.confirmInstall()
            for _ in 0..<250 where downloading.updates.status != .downloading(0.62) {   // ≤ 5 s, never hangs
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(downloading.updates.status, .downloading(0.62))
            for dark in [false, true] {
                try render(updatesTab(downloading), size: Self.size, dark: dark,
                           name: "updates-downloading-\(dark ? "dark" : "light")-\(lang)")
            }
            downloader.release()
            await install?.value

            // Up to date (2.5.0 installed).
            let (current, _) = try await makeModel(language, feed: Self.feedJSON(["2.5.0", "2.4.1", "2.4.0", "2.3.2"]),
                                                   appVersion: "2.5.0", build: "250")
            await current.checkForUpdates(manual: true)?.value
            XCTAssertEqual(current.updates.status, .upToDate)
            // Error: the feed cannot be loaded.
            let (failing, _) = try await makeModel(language, feed: nil)
            await failing.checkForUpdates(manual: true)?.value
            XCTAssertEqual(failing.updates.status, .failed(.feedUnavailable))
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                try render(updatesTab(current), size: Self.size, dark: dark, name: "updates-uptodate-\(theme)-\(lang)")
                try render(updatesTab(failing), size: Self.size, dark: dark, name: "updates-error-\(theme)-\(lang)")
            }

            // Install confirmation sheet (downgrade to 2.4.0).
            // Built directly (not via `pendingInstall`) so the tab does not try to present it offscreen.
            let older = try XCTUnwrap(available.updates.history.first { $0.versionString == "2.4.0" })
            let request = UpdateController.InstallRequest(release: older, change: .downgrade)
            for dark in [false, true] {
                try render(overlay(updatesTab(available)) {
                    InstallConfirmSheet(updates: available.updates, request: request)
                }, size: CGSize(width: 600, height: 640), dark: dark,
                           name: "sheet-downgrade-\(dark ? "dark" : "light")-\(lang)")
            }
        }
    }

    // MARK: S12–S15 sheets and alerts

    func testRenderSheetsAndConfirmations() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let lang = language.rawValue
            let (model, env) = try await makeModel(language, feed: Self.feedJSON(["2.5.0", "2.4.1"]))
            let candidate = try importCandidate(model, env)
            let inventory = model.eraseInventory
            let eraseMessage = L10n.format(.eraseConfirmBody, String(model.servers.count), String(inventory.backups),
                                           SettingsFormat.abbreviated(model.appDataFolder.path, home: model.homeDirectory))
            let summary = SettingsImportSummary(added: 2, updated: 1, skipped: 0, settingsApplied: 14,
                                                backupFile: URL(fileURLWithPath: "/tmp/profile.json.appbak-20261110-101500"))
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                let general = settings(.general) { GeneralSettingsView(model: model) }
                try render(overlay(general) { SettingsExportSheet(model: model) {} },
                           size: Self.size, dark: dark, name: "sheet-export-\(theme)-\(lang)")
                try render(overlay(general) {
                    SettingsExportSheet(model: model,
                                        initialResult: .saved(URL(fileURLWithPath: "/Users/me/Desktop/playeridentity-settings.json"))) {}
                }, size: Self.size, dark: dark, name: "sheet-export-done-\(theme)-\(lang)")
                try render(overlay(general) { SettingsImportSheet(model: model, candidate: candidate) {} },
                           size: CGSize(width: 600, height: 640), dark: dark, name: "sheet-import-\(theme)-\(lang)")
                try render(overlay(general) {
                    SettingsImportSheet(model: model, candidate: candidate, initialSummary: summary) {}
                }, size: Self.size, dark: dark, name: "sheet-import-done-\(theme)-\(lang)")
                try render(overlay(general, top: 104) {
                    DestructiveConfirmSheet(title: L10n.text(.eraseConfirmTitle), message: eraseMessage,
                                            confirmTitle: L10n.text(.eraseConfirmAction),
                                            checkboxTitle: L10n.text(.eraseExportFirst), checkbox: .constant(true),
                                            onCancel: {}, onConfirm: {})
                }, size: Self.size, dark: dark, name: "alert-erase-\(theme)-\(lang)")
                try render(overlay(general, top: 104) {
                    DestructiveConfirmSheet(title: L10n.text(.resetConfirmTitle), message: L10n.text(.resetConfirmBody),
                                            confirmTitle: L10n.text(.resetConfirmAction), checkbox: .constant(false),
                                            onCancel: {}, onConfirm: {})
                }, size: Self.size, dark: dark, name: "alert-reset-\(theme)-\(lang)")
            }
        }
    }

    // MARK: Fixtures

    /// `/releases` feed with release notes, dates and assets (2.5.0 newest).
    static func feedJSON(_ versions: [String]) -> String {
        let notes = ["2.5.0": "- Faster ban checks\\n- Xash3D FWGS 0.21 support\\n- 14 fixes",
                     "2.4.1": "- Fixes CID parsing for Xash3D 0.20",
                     "2.4.0": "- Range-ban detection, egress line",
                     "2.3.2": "- Turkish localisation"]
        let dates = ["2.5.0": "2026-11-03", "2.4.1": "2026-10-12", "2.4.0": "2026-09-28", "2.3.2": "2026-09-02"]
        let items = versions.map { version -> String in
            let (release, _) = UpdateFixture.release(version, zipSize: 14_050_000)
            let zip = release.zip!, sums = release.sums!
            return """
            {"tag_name":"v\(version)","html_url":"https://github.com/ercanatay/player-identity/releases/tag/v\(version)",
             "body":"\(notes[version] ?? "")","draft":false,"prerelease":false,"published_at":"\(dates[version] ?? "2026-08-01")T09:00:00Z",
             "assets":[{"name":"\(zip.name)","size":\(zip.size),"browser_download_url":"\(zip.downloadURL.absoluteString)"},
                       {"name":"\(sums.name)","size":\(sums.size),"browser_download_url":"\(sums.downloadURL.absoluteString)"}]}
            """
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func makeModel(_ language: AppLanguageSetting, feed: String?, downloader: (any UpdateDownloading)? = nil,
                           appVersion: String = "2.4.1", build: String = "241") async throws -> (AppModel, TestAppEnvironment) {
        let env = try TestAppEnvironment()
        // Two data backups from earlier downgrades (created before the model, which counts them at launch).
        let store = DataBackupStore(paths: AppPaths(home: env.home), defaultsDomain: env.suiteName)
        try store.create(from: "2.4.1", to: "2.4.0", now: env.clock.now.addingTimeInterval(-86_400), defaults: env.defaults)
        try store.create(from: "2.4.0", to: "2.3.2", now: env.clock.now.addingTimeInterval(-3_600), defaults: env.defaults)
        let login = FakeLoginItem(.notRegistered)
        let model = env.makeModel(updates: HTTPScript(defaultBody: feed), appVersion: appVersion) { deps in
            deps.appBuild = build
            deps.loginItem = login
            if let downloader { deps.updateDownloader = downloader }
        }
        model.appLanguage = language
        model.menuBarEnabled = true
        model.quietHoursEnabled = true
        model.notifyMapChanges = false
        model.addServer(ServerDraft(label: "Dust2 Only · Istanbul", host: "192.0.2.20", group: "Türkiye", favorite: true))
        model.addServer(ServerDraft(label: "Zombie TR", host: "192.0.2.30", group: "Türkiye", favorite: true))
        model.addServer(ServerDraft(label: "Plugin EU", host: "192.0.2.40", group: "Europe"))
        model.addServer(ServerDraft(label: "Frankfurt Mix Arena", host: "192.0.2.50", group: "Europe"))
        model.addServer(ServerDraft(label: "HLDM Boot Camp", host: "192.0.2.60"))
        model.setWatch(true, for: model.servers[0].id)
        model.save()
        return (model, env)
    }

    /// An archive exported from 2.4.0 with 3 differing preferences, 2 new and 3 matching servers and a data root.
    private func importCandidate(_ model: AppModel, _ env: TestAppEnvironment) throws -> DataSettingsRow.ImportCandidate {
        var settings = model.currentArchivedSettings()
        settings.quietHoursEnabled = false
        settings.showInMenuBar = false
        settings.notifyMapChanges = true
        settings.dataRoot = "/Users/me/Library/Application Support/Xash3D FWGS"
        var servers = model.servers.prefix(3).map(ArchivedServer.init(entry:))
        servers.append(ArchivedServer(label: "Public CS 1.6", host: "198.51.100.40", port: 27015, group: "Europe"))
        servers.append(ArchivedServer(label: "Surf Only", host: "198.51.100.41", port: 27016))
        let archive = SettingsArchive(appVersion: "2.4.0", exportedAt: env.clock.now.addingTimeInterval(-7 * 86_400),
                                      scope: .settingsAndServers, settings: settings, servers: servers)
        let url = env.temp.url.appendingPathComponent("playeridentity-settings-20261103-101500.json")
        try archive.encoded().write(to: url)
        guard case .chosen(let candidate) = SettingsImportPicker.load(url) else {
            XCTFail("import file not parsed")
            throw CancellationError()
        }
        return candidate
    }

    // MARK: Rendering

    private func updatesTab(_ model: AppModel) -> some View {
        settings(.updates) { UpdateSettingsView(updates: model.updates) }
    }

    private func settings<Content: View>(_ tab: SettingsTab, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            SettingsEvidenceToolbar(selected: tab)
            content()
        }
    }

    /// Sheet over the window: scrim below the toolbar, the sheet centred near the top (as in S12–S15).
    private func overlay<Base: View, Sheet: View>(_ base: Base, top: CGFloat = 88,
                                                  @ViewBuilder sheet: () -> Sheet) -> some View {
        base
            .overlay {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 80)
                    Palette.scrim
                }
            }
            .overlay(alignment: .top) {
                sheet()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .padding(.top, top)
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

/// Offscreen window that can be key, so controls draw in their active state.
private final class EvidenceKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Stand-in for the Settings tab toolbar in offscreen renders: title row (28 pt) + tab items (46 pt) on the toolbar token.
private struct SettingsEvidenceToolbar: View {
    let selected: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            Text(selected.title)
                .font(TypeScale.label)
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            HStack(spacing: Space.s1) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    let on = tab == selected
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(on ? Palette.accentText : Palette.text2)
                        Text(tab.title)
                            .font(.system(size: 11))
                            .foregroundStyle(on ? Palette.text : Palette.text2)
                    }
                    .frame(minWidth: 76, minHeight: 46)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Palette.toolbarHover : .clear))
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(Palette.toolbar)
        .overlay(alignment: .bottom) { ThemedDivider() }
    }
}

/// Holds the zip download at a fixed fraction until released (Downloading state), then cancels.
final class GatedUpdateDownloader: UpdateDownloading, @unchecked Sendable {
    private let fraction: Double
    private let lock = NSLock()
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?

    init(fraction: Double) { self.fraction = fraction }

    func download(_ url: URL, to destination: URL, expectedSize: Int,
                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard url.pathExtension == "zip" else {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: expectedSize).write(to: destination)   // passes the size check
            return
        }
        await progress(fraction)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        throw CancellationError()
    }

    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let gate = self.gate
            self.gate = nil
            return gate
        }
        gate?.resume()
    }
}

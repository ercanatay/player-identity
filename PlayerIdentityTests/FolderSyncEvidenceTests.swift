import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §71 evidence: Settings > Data > "Sync Folder" with no folder, after a sync (with a conflict) and with a damaged
/// file error; the "not encrypted" warning is always visible. Light/dark × EN/TR, temporary folders only. Runs only
/// when `PI_UI_EVIDENCE_DIR` is set; files go to `<dir>/sync/`.
@MainActor
final class FolderSyncEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderSyncFolderSection() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language
            let env = try TestAppEnvironment()
            let model = env.makeModel()
            model.appLanguage = language
            for dark in [false, true] {
                try render(section(model), dark: dark, name: "sync-none-\(dark ? "dark" : "light")-\(lang)")
            }

            let folder = env.temp.url.appendingPathComponent("iCloud Sync", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.addServer(ServerDraft(label: "Zombie", host: "10.0.0.11"))
            model.save()
            await model.setSyncFolder(folder).value
            // Another Mac wrote the same record with the same stamp: one conflict, the local copy stays.
            let url = folder.appendingPathComponent(SyncFile.fileName)
            guard case .file(var file) = SyncCoding.decode(try Data(contentsOf: url)) else { return XCTFail() }
            file.servers[0].value?.label = "Zombie (other Mac)"
            try SyncCoding.encode(file).write(to: url)
            await model.syncNow().value
            XCTAssertEqual(model.syncConflictCount, 1)
            for dark in [false, true] {
                try render(section(model), dark: dark, name: "sync-synced-\(dark ? "dark" : "light")-\(lang)")
            }

            try Data("{ broken".utf8).write(to: url)
            await model.syncNow().value
            XCTAssertNotNil(model.syncError)
            for dark in [false, true] {
                try render(section(model), dark: dark, name: "sync-error-\(dark ? "dark" : "light")-\(lang)")
            }
        }
    }

    private func section(_ model: AppModel) -> some View {
        SettingsPage {
            SettingsSection(title: L10n.text(.dataSectionTitle)) {
                SyncFolderSettingsRows(model: model)
            }
        }
    }

    private func render<V: View>(_ view: V, dark: Bool, name: String) throws {
        let size = CGSize(width: 600, height: 340)
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

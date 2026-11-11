import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §49 evidence: Settings > General > Data with the full backup rows and the automatic backup switch, the backup
/// result, and the restore sheet (preview, newer version, confirmation, result, error) in light/dark × TR/EN with fake
/// data (no network). Runs only when `PI_UI_EVIDENCE_DIR` is set.
@MainActor
final class FullBackupEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderDataSectionAndRestoreSheet() async throws {
        for language in [AppLanguageSetting.tr, .en] {
            L10n.setting = language
            let lang = language.rawValue
            let env = try TestAppEnvironment()
            let model = env.makeModel(appVersion: "2.7.0")
            model.appLanguage = language
            for (label, host) in [("Dust2 Only · Istanbul", "192.0.2.20"), ("Zombie TR", "192.0.2.30"),
                                  ("Plugin EU", "192.0.2.40"), ("HLDM Boot Camp", "192.0.2.60")] {
                model.addServer(ServerDraft(label: label, host: host))
            }
            model.setWatch(true, for: model.servers[0].id)
            await model.refresh().value
            model.save()
            await model.waitForHistory()
            _ = await model.runAutomaticBackupIfDue()?.value
            XCTAssertNotNil(model.latestAutomaticBackup)

            let url = env.temp.url.appendingPathComponent(FullBackupNaming.manualFileName(now: model.now))
            let written = await model.writeFullBackup(to: url)
            let (savedText, _) = FullBackupText.result(written, url: URL(fileURLWithPath: "/Users/me/Desktop/" + url.lastPathComponent))
            guard case .chosen(let candidate) = FullBackupPicker.load(url) else { return XCTFail("backup not readable") }
            let newer = try newerCandidate(candidate, env)

            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                try render(dataSection(model), size: CGSize(width: 600, height: 560), dark: dark,
                           name: "data-section-\(theme)-\(lang)")
                try render(dataSection(model, message: savedText), size: CGSize(width: 600, height: 600), dark: dark,
                           name: "data-backup-saved-\(theme)-\(lang)")
                try render(dataSection(model, message: FullBackupError.corruptFile("history.jsonl").text, isError: true),
                           size: CGSize(width: 600, height: 580), dark: dark, name: "data-restore-invalid-\(theme)-\(lang)")
                try render(sheet(FullRestoreSheet(model: model, candidate: candidate) {}), size: CGSize(width: 600, height: 640),
                           dark: dark, name: "restore-preview-\(theme)-\(lang)")
                try render(sheet(FullRestoreSheet(model: model, candidate: newer) {}), size: CGSize(width: 600, height: 680),
                           dark: dark, name: "restore-preview-newer-\(theme)-\(lang)")
                try render(sheet(FullRestoreSheet(model: model, candidate: candidate, initialPhase: .confirm) {}),
                           size: CGSize(width: 600, height: 420), dark: dark, name: "restore-confirm-\(theme)-\(lang)")
                let safety = URL(fileURLWithPath: "/tmp/backups/pre-restore-20261111-093015.zip")
                try render(sheet(FullRestoreSheet(model: model, candidate: candidate, initialPhase: .done(safety)) {}),
                           size: CGSize(width: 600, height: 420), dark: dark, name: "restore-done-\(theme)-\(lang)")
                try render(sheet(FullRestoreSheet(model: model, candidate: candidate,
                                                  initialPhase: .failed(FullBackupError.updateRunning.text)) {}),
                           size: CGSize(width: 600, height: 420), dark: dark, name: "restore-failed-\(theme)-\(lang)")
            }
        }
    }

    // MARK: Fixtures

    /// The same backup as if it had been written by 2.9.0 (shows the newer-version note).
    private func newerCandidate(_ candidate: FullRestoreCandidate, _ env: TestAppEnvironment) throws -> FullRestoreCandidate {
        var manifest = candidate.backup.manifest
        manifest.appVersion = "2.9.0"
        let entries = [ZipEntry(name: FullBackupManifest.fileName, data: try FullBackupManifest.makeEncoder().encode(manifest))]
            + FullBackupFile.allCases.compactMap { file in candidate.backup.data(file).map { ZipEntry(name: file.rawValue, data: $0) } }
        let url = env.temp.url.appendingPathComponent("playeridentity-backup-20261120-181500.zip")
        try ZipArchive.make(entries, modified: manifest.createdAt).write(to: url)
        guard case .chosen(let newer) = FullBackupPicker.load(url) else {
            XCTFail("newer backup not readable")
            throw CancellationError()
        }
        return newer
    }

    // MARK: Rendering

    private func dataSection(_ model: AppModel, message: String? = nil, isError: Bool = false) -> some View {
        SettingsPage {
            SettingsSection(title: L10n.text(.dataSectionTitle)) {
                DataRootRow(model: model)
                SettingsDivider()
                DataSettingsRow(model: model)
                SettingsDivider()
                FullBackupSettingsRows(model: model, initialMessage: message, initialIsError: isError)
                SettingsDivider()
                DiagnosticsSettingsRow(model: model)
            }
        }
    }

    /// Sheet over a scrim, centred near the top (as the Settings sheet renders).
    private func sheet<Sheet: View>(_ content: Sheet) -> some View {
        Palette.scrim
            .overlay(alignment: .top) {
                content
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .padding(.top, 40)
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
        let window = BackupEvidenceWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
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
private final class BackupEvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

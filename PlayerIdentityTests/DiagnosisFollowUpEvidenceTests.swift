import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §66 evidence: the ban matrix "Last 7 days" column (wide window: shown, default width: hidden), the range-ban verdict
/// card with the "Change network" hint, and the report with its history table (PNG + `.md`), light/dark × TR/EN,
/// fake carriers only (no network). Runs only when `PI_UI_EVIDENCE_DIR` is set; files go to `<dir>/diagnose-followup/`.
@MainActor
final class DiagnosisFollowUpEvidenceTests: XCTestCase {
    private var directory: URL!
    private let server = "198.51.100.20"

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("diagnose-followup", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.setting = .system
    }

    func testRenderFollowUp() async throws {
        for language in [AppLanguageSetting.en, .tr] {
            let lang = language.rawValue
            L10n.setting = language
            let env = try TestAppEnvironment()
            let udp = FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(
                info: FakeReply(bytes: A2SFixture.goldSrc(name: Array("Zombie TR".utf8), map: "zm_dust", players: 9, max: 26), delay: 0.04),
                challenge: FakeReply(bytes: FakeServer.oobText("9You are banned from this server"), delay: 0.03)))
            let model = env.makeModel(udp: udp)
            model.appLanguage = language
            model.addServer(ServerDraft(label: "Zombie TR", host: server, group: "Türkiye"))
            model.addServer(ServerDraft(label: "Public EU", host: "198.51.100.21"))
            model.addServer(ServerDraft(label: "Deathmatch", host: "198.51.100.22"))
            await model.refresh().value
            await model.waitForHistory()
            let ids = model.servers.map(\.id)
            let zombie = try XCTUnwrap(model.servers.first { $0.label == "Zombie TR" }?.id)
            let eu = try XCTUnwrap(model.servers.first { $0.label == "Public EU" }?.id)

            // Earlier runs (last days) + the fix attempt that found the range ban.
            let now = env.clock.now
            func line(_ id: UUID, _ verdict: DiagnosisVerdict, _ hoursAgo: Double, _ ms: Int) -> HistoryEntry {
                HistoryEntry(ts: now.addingTimeInterval(-hoursAgo * 3600), kind: .diagnose, serverID: id,
                             host: "\(server):27015", new: verdict.rawValue, note: "dns=ok", durationMs: ms)
            }
            try env.historyStore.append([
                line(zombie, .noBan, 150, 812), line(zombie, .timeout, 120, 5020), line(zombie, .ipBanned, 72, 640),
                line(zombie, .rangeBanned, 30, 702), line(zombie, .rangeBanned, 5, 688),
                line(eu, .noBan, 48, 455), line(eu, .noBan, 20, 471), line(eu, .cidUnverified, 2, 1210),
                HistoryEntry(ts: now.addingTimeInterval(-3 * 3600), kind: .fixAttempt, serverID: zombie, host: server,
                             old: "198.51.100.7", new: "198.51.2.9", note: "rangeBanned"),
            ])
            await model.startDiagnosis(for: zombie)?.value
            await model.waitForHistory()
            XCTAssertEqual(model.diagnosis(for: zombie)?.result?.verdict, .rangeBanned)

            // (1) Ban matrix: wide (column shown) and default width (hidden; value in the tooltip).
            let rows = await model.banMatrixRows()
            XCTAssertEqual(rows.count, ids.count)
            XCTAssertEqual(rows.first { $0.serverID == zombie }?.recent?.runs, 6)
            try await render(BanMatrixView(model: model, fixedRows: rows, inlineToolbar: true),
                             size: CGSize(width: 1080, height: 360), dark: false, name: "banmatrix-recent-wide-light-\(lang)")
            try await render(BanMatrixView(model: model, fixedRows: rows, inlineToolbar: true),
                             size: CGSize(width: 1080, height: 360), dark: true, name: "banmatrix-recent-wide-dark-\(lang)")
            try await render(BanMatrixView(model: model, fixedRows: rows, inlineToolbar: true),
                             size: CGSize(width: 860, height: 360), dark: false, name: "banmatrix-recent-narrow-light-\(lang)")
            try Data(CSV.encode(BanMatrixText.tableWithRecent(rows)).utf8)
                .write(to: directory.appendingPathComponent("banmatrix-\(lang).csv"))

            // (2) Range-ban verdict card with the "Change network" hint.
            for dark in [false, true] {
                try await render(ServerDetailSheet(model: model, serverID: zombie, onClose: {}, metrics: [], maxContentHeight: 1800),
                                 size: CGSize(width: 620, height: 1180), dark: dark,
                                 name: "rangeban-card-\(dark ? "dark" : "light")-\(lang)")
            }

            // (3) Report with the "History (last 10 runs)" table (masked), as Markdown and as a rendered page.
            let reportText = await model.diagnosisReport(for: zombie, window: .week)
            let report = try XCTUnwrap(reportText)
            XCTAssertTrue(report.contains(L10n.text(.diagnoseReportHistory)))
            try Data(report.utf8).write(to: directory.appendingPathComponent("report-week-\(lang).md"))
            try await render(ReportPage(text: report), size: CGSize(width: 760, height: 1100), dark: false,
                             name: "report-history-light-\(lang)")
        }
    }

    /// Like the §65 evidence renderer: awaits between layout passes so `.task` reads finish.
    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) async throws {
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
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

/// The Markdown report as plain monospaced text (evidence only).
private struct ReportPage: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
    }
}

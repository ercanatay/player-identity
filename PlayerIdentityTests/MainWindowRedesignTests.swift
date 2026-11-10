import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// Main window redesign (Claude Design handoff): tokens, layout breakpoints, ban cell texts, toolbar status, row actions.
@MainActor
final class MainWindowRedesignTests: XCTestCase {
    // MARK: Tokens

    func testPaletteResolvesLightAndDarkTokensFromTokensCSS() throws {
        XCTAssertEqual(try rgb(Palette.text, .aqua), 0x1B2432)
        XCTAssertEqual(try rgb(Palette.text, .darkAqua), 0xE9EEF4)
        XCTAssertEqual(try rgb(Palette.window, .aqua), 0xF2F4F7)
        XCTAssertEqual(try rgb(Palette.window, .darkAqua), 0x111821)
        XCTAssertEqual(try rgb(Palette.card, .darkAqua), 0x1B2432)
        XCTAssertEqual(try rgb(Palette.accentFill, .aqua), 0x187A71)
        XCTAssertEqual(try rgb(Palette.accentFill, .darkAqua), 0x2FB6A8)
        XCTAssertEqual(try rgb(Palette.redText, .aqua), 0xC0201A)
        XCTAssertEqual(try rgb(Palette.greenText, .darkAqua), 0x5BD97A)
        XCTAssertEqual(try alpha(Palette.border, .aqua), 0.08, accuracy: 0.001)
        XCTAssertEqual(try alpha(Palette.orangeTint, .darkAqua), 0.18, accuracy: 0.001)
        XCTAssertEqual(StatusLevel.red.textColor, Palette.redText)
        XCTAssertEqual(Metrics.row, 48)
        XCTAssertEqual(Metrics.toolbar, 52)
        XCTAssertEqual([Space.s1, Space.s2, Space.s3, Space.s4, Space.s6, Space.s8], [4, 8, 12, 16, 24, 32])
        XCTAssertEqual([Radius.control, Radius.inner, Radius.window, Radius.card], [6, 8, 10, 12])
        XCTAssertEqual(ModelPreviewStyle.previewSize, CGSize(width: 72, height: 96))
    }

    // MARK: Layout

    func testTopRowSplitsProfileAndNetworkAndStacksBelowBreakpoint() throws {
        let (profile, network) = try XCTUnwrap(TopRowLayout.columnWidths(contentWidth: 868))
        XCTAssertEqual(profile + network, 852)
        XCTAssertEqual(profile / network, 1.38, accuracy: 0.01)
        XCTAssertNotNil(TopRowLayout.columnWidths(contentWidth: 788))
        XCTAssertNil(TopRowLayout.columnWidths(contentWidth: 787))
        XCTAssertNil(TopRowLayout.columnWidths(contentWidth: 688))
    }

    // MARK: Ban cell

    func testBanCellShowsEveryStateAsText() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func cell(_ status: BanStatus?, checking: Bool = false, enabled: Bool = true) -> BanCellContent {
            BanCellContent.make(check: status.map { BanCheck(status: $0, checkedAt: date, detail: "") }, status: nil,
                                host: "192.0.2.1", isChecking: checking, checksEnabled: enabled)
        }
        inEnglish {
            for status in BanStatus.allCases {
                let content = cell(status)
                XCTAssertFalse(content.title.isEmpty, status.rawValue)
                XCTAssertFalse(content.detail.isEmpty, status.rawValue)
                XCTAssertFalse(content.symbol.isEmpty, status.rawValue)
            }
            XCTAssertEqual(cell(.ipBanned).title, "Banned")
            XCTAssertEqual(cell(.ipBanned).detail, "IP ban")
            XCTAssertEqual(cell(.cidBanned).symbol, "xmark.octagon.fill")
            XCTAssertEqual(cell(.cidOk).title, "No block")
            XCTAssertEqual(cell(.cidOk).symbol, "checkmark.shield.fill")
            XCTAssertEqual(cell(.unreachable).symbol, "exclamationmark.circle")
            XCTAssertEqual(cell(.unknown).symbol, "questionmark.circle")
            XCTAssertEqual(cell(.ipBanned, checking: true).title, "Checking…")
            XCTAssertTrue(cell(.ipBanned, checking: true).isChecking)
            XCTAssertEqual(cell(.ipBanned, enabled: false).title, "Checks off")
            XCTAssertEqual(cell(.ipBanned, enabled: false).symbol, "shield.slash")
            XCTAssertEqual(cell(nil).title, "Not checked")
        }
        inTurkish {
            XCTAssertEqual(cell(.cidBanned).title, "Ban var")
            XCTAssertEqual(cell(.cidBanned, enabled: false).title, "Kontrol kapalı")
        }
    }

    func testBanCellExplainsUnresolvedHost() {
        let status = ServerRowStatus(id: UUID(), level: .red, currentCID: nil, message: .invalidHost,
                                     resolutionFailure: .notFound)
        inEnglish {
            let content = BanCellContent.make(check: nil, status: status, host: "nx.example.test", isChecking: false,
                                              checksEnabled: true)
            XCTAssertEqual(content.title, "Unknown")
            XCTAssertEqual(content.detail, "name not found")
        }
    }

    func testShortCIDAndHostPort() {
        XCTAssertEqual(ServerRowView.shortCID("9f3a1c7e0b5d4a2896e1f0c3d7b8a4e2"), "9f3a1c7e…d7b8a4e2")
        XCTAssertEqual(ServerRowView.shortCID("abc"), "abc")
        XCTAssertEqual(ServerRowView.hostPort("192.0.2.1", "27015"), "192.0.2.1:27015")
        XCTAssertEqual(ServerRowView.hostPort("2001:db8::1", "27015"), "[2001:db8::1]:27015")
        XCTAssertEqual(InterfacesSection.egressLine(publicIP: "203.0.113.7", interface: "utun4"), "utun4 → 203.0.113.7")
        XCTAssertEqual(InterfacesSection.egressLine(publicIP: nil, interface: nil), "— → —")
    }

    // MARK: Toolbar status

    func testToolbarStatusTextFollowsTheReport() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        inEnglish {
            let idle = ToolbarStatusText(model: model)
            XCTAssertEqual(idle.label, "Not checked yet")
            XCTAssertEqual(idle.detail, "")
            XCTAssertEqual(idle.lastCheck, "Last check: —")
        }
        model.addServer(ServerDraft(label: "POLIGON RPG", host: "192.0.2.10"))
        await model.refresh().value
        let report = try XCTUnwrap(model.report)
        XCTAssertGreaterThan(report.reasons.count, 1)
        inEnglish {
            let text = ToolbarStatusText(model: model)
            XCTAssertEqual(text.label, report.overall.label)
            XCTAssertEqual(text.symbol, report.overall.symbolName)
            XCTAssertEqual(text.detail, report.reasons[0].message + " · +\(report.reasons.count - 1) more")
            XCTAssertTrue(text.sentence.hasPrefix(report.overall.label + " — "))
        }
    }

    // MARK: Row actions

    func testFixPopoverListsOnlyThatServersActions() async throws {
        let env = try TestAppEnvironment()
        let udp = FakeUDPTransport(clock: env.clock) { endpoint, packet in
            if endpoint.address == TestAddresses.v4("192.0.2.30") {
                return FakeServer.scripted(challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8))))(endpoint, packet)
            }
            return FakeServer.scripted(info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.031))(endpoint, packet)
        }
        let model = env.makeModel(udp: udp)
        model.addServer(ServerDraft(label: "Healthy", host: "192.0.2.10"))
        model.addServer(ServerDraft(label: "Banned", host: "192.0.2.30"))
        await model.refresh().value
        let healthy = model.servers[0], banned = model.servers[1]
        XCTAssertNotNil(model.fixKind(for: banned.id))

        var opened: [UUID] = []
        XCTAssertTrue(ServerActionList.actions(for: healthy, model: model, details: { opened.append($0) }).isEmpty)
        let actions = ServerActionList.actions(for: banned, model: model, details: { opened.append($0) })
        XCTAssertEqual(actions.first?.id, "fix")
        XCTAssertTrue(actions.map(\.id).contains("appeal"))
        XCTAssertTrue(actions.map(\.id).contains("recheck"))
        XCTAssertEqual(actions.last?.id, "details")

        actions.first?.run()
        XCTAssertEqual(model.fixSession?.id, banned.id)
        model.fixSession = nil
        actions.last?.run()
        XCTAssertEqual(opened, [banned.id])

        model.banCheckEnabled = false
        XCTAssertFalse(ServerActionList.actions(for: banned, model: model, details: { _ in }).map(\.id).contains("recheck"))
    }

    // MARK: Helpers

    private func resolved(_ color: Color, _ name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(result)
    }

    private func rgb(_ color: Color, _ name: NSAppearance.Name) throws -> UInt32 {
        let c = try resolved(color, name)
        let r = UInt32((c.redComponent * 255).rounded()), g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent * 255).rounded())
        return r << 16 | g << 8 | b
    }

    private func alpha(_ color: Color, _ name: NSAppearance.Name) throws -> CGFloat {
        try resolved(color, name).alphaComponent
    }

    private func inEnglish(_ body: () -> Void) { inLanguage("en", body) }
    private func inTurkish(_ body: () -> Void) { inLanguage("tr", body) }

    private func inLanguage(_ language: String, _ body: () -> Void) {
        guard let bundle = L10n.languageBundle(language) else { return XCTFail("missing \(language).lproj") }
        L10n.$bundle.withValue(bundle) { body() }
    }
}

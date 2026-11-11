import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §50 server import: parser, result model, model integration, evidence screenshots.
@MainActor
final class ServerURLImportTests: XCTestCase {
    private func one(_ text: String, existing: [ServerEntry] = []) -> ServerURLImport.Candidate? {
        ServerURLImport.parse(text, existing: existing).fresh.first
    }

    private func cand(_ host: String, _ port: Int = 27015) -> ServerURLImport.Candidate {
        ServerURLImport.Candidate(host: host, port: port)
    }

    // MARK: Formats

    func testHostPortFormats() {
        XCTAssertEqual(one("192.0.2.10:27016"), cand("192.0.2.10", 27016))
        XCTAssertEqual(one("play.example.com:27020"), cand("play.example.com", 27020))
        XCTAssertEqual(one("play.example.com"), cand("play.example.com", 27015))
        XCTAssertEqual(one("192.0.2.10"), cand("192.0.2.10", 27015))
    }

    func testGameTrackerAndSteamAndHTTP() {
        XCTAssertEqual(one("https://www.gametracker.com/server_info/192.0.2.10:27016/"), cand("192.0.2.10", 27016))
        XCTAssertEqual(one("http://gametracker.com/server_info/play.example.com:27018"), cand("play.example.com", 27018))
        XCTAssertEqual(one("https://www.gametracker.com/server_info/192.0.2.10:27016/?tab=x#top"), cand("192.0.2.10", 27016))
        XCTAssertEqual(one("steam://connect/192.0.2.10:27017"), cand("192.0.2.10", 27017))
        XCTAssertEqual(one("steam://connect/192.0.2.10:27017/secret"), cand("192.0.2.10", 27017))
        XCTAssertEqual(one("https://play.example.com:27019/"), cand("play.example.com", 27019))
        XCTAssertEqual(one("HTTP://192.0.2.10:27019"), cand("192.0.2.10", 27019))
    }

    func testTolerances() {
        XCTAssertEqual(one("   192.0.2.10:27016/   "), cand("192.0.2.10", 27016))
        XCTAssertEqual(one("192.0.2.10:27016?x=1"), cand("192.0.2.10", 27016))
        XCTAssertEqual(one("192.0.2.10:27016#frag"), cand("192.0.2.10", 27016))
        XCTAssertEqual(one("PLAY.Example.COM:27015"), cand("play.example.com", 27015))
        XCTAssertEqual(one("play.example.com.:27015"), cand("play.example.com", 27015))
        let mixed = ServerURLImport.parse("192.0.2.1:1, 192.0.2.2:2\n192.0.2.3:3\r\n192.0.2.4")
        XCTAssertEqual(mixed.fresh.map(\.id), ["192.0.2.1:1", "192.0.2.2:2", "192.0.2.3:3", "192.0.2.4:27015"])
    }

    func testLabelDefaultsToHost() {
        XCTAssertEqual(cand("play.example.com", 1).label, "play.example.com")
    }

    // MARK: Ports

    func testPortRange() {
        XCTAssertEqual(one("192.0.2.10:1"), cand("192.0.2.10", 1))
        XCTAssertEqual(one("192.0.2.10:65535"), cand("192.0.2.10", 65_535))
        for bad in ["192.0.2.10:0", "192.0.2.10:65536", "192.0.2.10:-1", "192.0.2.10:abc", "192.0.2.10:", "192.0.2.10:123456"] {
            let result = ServerURLImport.parse(bad)
            XCTAssertEqual(result.invalid.map(\.reason), [.portInvalid], bad)
            XCTAssertTrue(result.fresh.isEmpty, bad)
        }
    }

    // MARK: IPv6

    func testIPv6OnlyBracketed() {
        XCTAssertEqual(one("[2001:db8::1]:27016"), cand("2001:db8::1", 27016))
        XCTAssertEqual(one("[2001:DB8::1]"), cand("2001:db8::1", 27015))
        XCTAssertEqual(ServerURLImport.parse("2001:db8::1").invalid.map(\.reason), [.ipv6NeedsBrackets])
        XCTAssertEqual(ServerURLImport.parse("2001:db8::1:27015").invalid.map(\.reason), [.ipv6NeedsBrackets])
        XCTAssertEqual(ServerURLImport.parse("[2001:db8::zz]:27015").invalid.map(\.reason), [.hostInvalid])
        XCTAssertEqual(ServerURLImport.parse("[192.0.2.1]:27015").invalid.map(\.reason), [.hostInvalid])
        XCTAssertEqual(ServerURLImport.parse("[2001:db8::1:27015").invalid.map(\.reason), [.hostInvalid])
        XCTAssertEqual(ServerURLImport.parse("[2001:db8::1]:0").invalid.map(\.reason), [.portInvalid])
    }

    // MARK: Invalid

    func testInvalidHostsAndUnsupported() {
        XCTAssertEqual(ServerURLImport.parse("not a host").invalid.map(\.reason), [.hostInvalid])
        XCTAssertEqual(ServerURLImport.parse("-bad-.example.com").invalid.map(\.reason), [.hostInvalid])
        XCTAssertEqual(ServerURLImport.parse("999.1.1.1:27015").invalid.map(\.reason), [.hostInvalid])
        XCTAssertEqual(ServerURLImport.parse("ftp://192.0.2.1:27015").invalid.map(\.reason), [.unsupportedURL])
        XCTAssertEqual(ServerURLImport.parse("https://www.gametracker.com/").invalid.map(\.reason), [.unsupportedURL])
        XCTAssertEqual(ServerURLImport.parse("https://www.gametracker.com/server_info//").invalid.map(\.reason), [.unsupportedURL])
        XCTAssertEqual(ServerURLImport.parse("steam://connect/").invalid.map(\.reason), [.hostInvalid])
    }

    func testInvalidLinesAreReportedWithIndexAndNotAdded() {
        let result = ServerURLImport.parse("192.0.2.1:27015\nbad host\n\n192.0.2.2:99999\nplay.example.com")
        XCTAssertEqual(result.fresh.map(\.id), ["192.0.2.1:27015", "play.example.com:27015"])
        XCTAssertEqual(result.invalid.map(\.index), [2, 3])
        XCTAssertEqual(result.invalid.map(\.raw), ["bad host", "192.0.2.2:99999"])
        XCTAssertTrue(result.invalid.allSatisfy { !$0.reason.text.isEmpty })
    }

    // MARK: Empty, duplicates, limit

    func testEmptyInput() {
        for text in ["", "   ", "\n\n", " , ,\n,"] {
            XCTAssertTrue(ServerURLImport.parse(text).isEmpty, text)
        }
    }

    func testDuplicatesWithinInputMerged() {
        let result = ServerURLImport.parse("192.0.2.1:27015, 192.0.2.1\nsteam://connect/192.0.2.1:27015\nPLAY.example.com\nplay.example.com:27015")
        XCTAssertEqual(result.fresh.map(\.id), ["192.0.2.1:27015", "play.example.com:27015"])
        XCTAssertEqual(result.duplicates, 3)
    }

    func testHundredEntryLimit() {
        let lines = (1...130).map { "10.0.\($0 / 250).\($0 % 250 + 1):27015" }.joined(separator: "\n")
        let result = ServerURLImport.parse(lines)
        XCTAssertEqual(result.fresh.count, 100)
        XCTAssertEqual(result.overflow, 30)
        let exact = ServerURLImport.parse((1...100).map { "10.0.0.\($0):1" }.joined(separator: ","))
        XCTAssertEqual(exact.fresh.count, 100)
        XCTAssertEqual(exact.overflow, 0)
    }

    // MARK: Conflicts and selection

    func testConflictWithExistingServers() {
        let existing = [ServerEntry(label: "A", host: "192.0.2.1", port: 27015),
                        ServerEntry(label: "B", host: "Play.Example.com", port: 27016)]
        let result = ServerURLImport.parse("192.0.2.1\n192.0.2.1:27016\nplay.example.com:27016\n192.0.2.9", existing: existing)
        XCTAssertEqual(result.existing.map(\.id), ["192.0.2.1:27015", "play.example.com:27016"])
        XCTAssertEqual(result.fresh.map(\.id), ["192.0.2.1:27016", "192.0.2.9:27015"])
        XCTAssertEqual(result.defaultSelection, ["192.0.2.1:27016", "192.0.2.9:27015"])
    }

    // MARK: Model

    func testAddServersMarksUnsavedAndSkipsExisting() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        await model.refresh().value
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        let result = ServerURLImport.parse("192.0.2.1:27015\nplay.example.com:27016\n192.0.2.1:27015")
        XCTAssertEqual(model.addServers(result.fresh), 2)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.servers.map(\.label), ["192.0.2.1", "play.example.com"])
        XCTAssertEqual(model.servers.map(\.port), [27015, 27016])
        XCTAssertEqual(model.servers.map(\.order), [0, 1].map { model.servers[0].order + $0 })
        XCTAssertTrue(model.servers.allSatisfy { $0.cid.isEmpty && $0.banCheck == nil && $0.lastCheckedAt == nil })
        // Second import of the same entries adds nothing.
        XCTAssertEqual(model.addServers(result.fresh), 0)
        XCTAssertEqual(model.servers.count, 2)
        // The label stays editable afterwards.
        let id = model.servers[0].id
        model.updateServer(id: id, with: ServerDraft(label: "Benim", host: "192.0.2.1"))
        XCTAssertEqual(model.servers[0].label, "Benim")
        // A refresh fetches A2S info for the added rows.
        await model.refresh().value
        XCTAssertNotNil(model.servers[0].banCheck)
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    // MARK: l10n

    func testImportKeysExistInBothLanguages() {
        let keys = L10nKey.allCases.filter { $0.rawValue.hasPrefix("server.import.") }
        XCTAssertEqual(keys.count, 16)
        for language in [AppLanguageSetting.tr, .en] {
            L10n.setting = language
            for key in keys { XCTAssertNotEqual(L10n.text(key), key.rawValue) }
        }
        L10n.setting = .system
    }

    // MARK: Evidence

    func testRenderImportSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["PI_UI_EVIDENCE_DIR"], !path.isEmpty else {
            throw XCTSkip("UI evidence is generated only on request")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { L10n.setting = .system }
        let existing = [ServerEntry(label: "Zombie TR", host: "192.0.2.30", port: 27015)]
        let sample = """
        192.0.2.10:27016
        https://www.gametracker.com/server_info/play.example.com:27018/
        steam://connect/192.0.2.30:27015
        [2001:db8::1]:27015
        """
        let bad = sample + "\n2001:db8::1:27015\nhost:99999\nftp://x.example.com"
        for language in [AppLanguageSetting.tr, .en] {
            L10n.setting = language
            try render(ServerImportSheet(existing: existing, initialText: sample, parseOnAppear: true,
                                         onAdd: { _ in }, onCancel: {}), height: 460, name: "preview-\(language.rawValue)", dir: dir)
            try render(ServerImportSheet(existing: existing, initialText: bad, parseOnAppear: true,
                                         onAdd: { _ in }, onCancel: {}), height: 600, name: "invalid-\(language.rawValue)", dir: dir)
            try render(ServerImportSheet(existing: existing, initialText: "192.0.2.30\n192.0.2.30:27015", parseOnAppear: true,
                                         onAdd: { _ in }, onCancel: {}), height: 420, name: "conflict-\(language.rawValue)", dir: dir)
            try render(ServerImportSheet(existing: existing, onAdd: { _ in }, onCancel: {}),
                       height: 300, name: "empty-\(language.rawValue)", dir: dir)
        }
    }

    private func render<V: View>(_ view: V, height: CGFloat, name: String, dir: URL) throws {
        let size = CGSize(width: 520, height: height)
        let appearance = NSAppearance(named: .aqua)
        let root = view.frame(width: size.width, height: size.height, alignment: .top)
            .background(Palette.window)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = ImportEvidenceWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        window.orderBack(nil)
        window.makeKey()
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }
}

private final class ImportEvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

import AppKit
import CoreImage
import SwiftUI
import ImageIO
import XCTest
@testable import PlayerIdentity

/// §33.1 share card DURUM / BAN TİPİ: mapping, CID rule, QR payload, layout and pixels (T-33-1 … T-33-13).
final class ShareCardBanTests: XCTestCase {
    static let cid = "668afa7c2daff879e69f6aae714ef3b4"
    static let rawIDHex = "10331C2DCE4C91DB"

    private func inTurkish<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr")), operation: body)
    }

    private func inEnglish<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en")), operation: body)
    }

    // MARK: Mapping (§33.1.1, §33.1.2)

    func testClassification() {
        typealias S = ShareCardBanSummary
        XCTAssertTrue(S.classify(.ipBanned, rangeKnown: false, goldSrc: false) == (.banned, .ip))
        XCTAssertTrue(S.classify(.ipBanned, rangeKnown: true, goldSrc: false) == (.banned, .ipRange))
        XCTAssertTrue(S.classify(.cidBanned, rangeKnown: false, goldSrc: false) == (.banned, .cid))
        XCTAssertTrue(S.classify(.cidBanned, rangeKnown: true, goldSrc: false) == (.banned, .cid))
        XCTAssertTrue(S.classify(.goldSrcBanned, rangeKnown: false, goldSrc: true) == (.banned, .goldSrc))
        XCTAssertTrue(S.classify(.cidOk, rangeKnown: false, goldSrc: false) == (.clear, .none))
        for status in [BanStatus.goldSrcUnverified, .cidUnknown, .unknown] {
            XCTAssertTrue(S.classify(status, rangeKnown: false, goldSrc: false) == (.unverified, .unknown), "\(status)")
        }
        XCTAssertTrue(S.classify(.unreachable, rangeKnown: true, goldSrc: false) == (.unverified, .none))
        XCTAssertTrue(S.classify(nil, rangeKnown: true, goldSrc: true) == (.notChecked, .none))
        // GoldSrc 48: only the GoldSrc ban proof is a ban; an older Source result (cidBanned, ipBanned …) is not.
        XCTAssertTrue(S.classify(.cidBanned, rangeKnown: false, goldSrc: true) == (.unverified, .unknown))
        XCTAssertTrue(S.classify(.ipBanned, rangeKnown: true, goldSrc: true) == (.unverified, .unknown))
        XCTAssertTrue(S.classify(.unreachable, rangeKnown: false, goldSrc: true) == (.unverified, .none))
        for status in BanStatus.allCases where status != .goldSrcBanned {
            let summary = S.classify(status, rangeKnown: true, goldSrc: true)
            XCTAssertNotEqual(summary.status, .banned, "\(status)")
            XCTAssertFalse([.cid, .ip, .ipRange].contains(summary.banType), "\(status)")
        }
        // §75.10 P6: "Ban yok" is never produced for a GoldSrc 48 server.
        for status in BanStatus.allCases {
            XCTAssertNotEqual(S.classify(status, rangeKnown: false, goldSrc: true).status, .clear, "\(status)")
        }
    }

    func testTurkishAndEnglishTexts() throws {
        try inTurkish {
            XCTAssertEqual(ShareCardStatus.banned.text, "Ban var")
            XCTAssertEqual(ShareCardStatus.clear.text, "Ban yok")
            XCTAssertEqual(ShareCardStatus.unverified.text, "Doğrulanamadı")
            XCTAssertEqual(ShareCardStatus.notChecked.text, "Kontrol edilmedi")
            XCTAssertEqual(ShareCardBanType.ip.text, "IP banı")
            XCTAssertEqual(ShareCardBanType.ipRange.text, "IP aralık banı")
            XCTAssertEqual(ShareCardBanType.cid.text, "CID banı")
            XCTAssertEqual(ShareCardBanType.goldSrc.text, "Sunucu bağlantı banı (tür belirsiz)")
            XCTAssertEqual(ShareCardBanType.unknown.text, "Belirlenemedi")
            XCTAssertEqual(ShareCardBanType.none.text, "—")
            XCTAssertEqual(L10n.text(.shareCardStatus), "DURUM")
            XCTAssertEqual(L10n.text(.shareCardBanType), "BAN TİPİ")
        }
        try inEnglish {
            XCTAssertEqual(ShareCardStatus.banned.text, "Banned")
            XCTAssertEqual(ShareCardBanType.goldSrc.text, "Server connection ban (type unknown)")
            XCTAssertEqual(L10n.text(.shareCardBanType), "Ban type")
        }
    }

    /// T-33-13: the new keys exist in all 26 languages; TR/EN are filled and differ from the key.
    func testNewKeysInEveryLanguage() throws {
        let keys = L10nKey.allCases.filter {
            $0.rawValue.hasPrefix("shareCard.status") || $0.rawValue.hasPrefix("shareCard.banType")
                || $0.rawValue.hasPrefix("shareCard.qr.")
        }
        XCTAssertEqual(keys.count, 12)
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(L10n.languageBundle(language.rawValue), language.rawValue)
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"), language.rawValue)
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language.rawValue)
            for key in keys {
                let value = try XCTUnwrap(table[key.rawValue], "\(language.rawValue): \(key.rawValue)")
                XCTAssertFalse(value.isEmpty, "\(language.rawValue): \(key.rawValue)")
            }
        }
    }

    // MARK: QR (§33.1.4)

    func testGoldSrcPayload() {
        let payload = ShareCardQR.goldSrcPayload(serverName: "Example\nServer", hostPort: "192.0.2.10:27015",
                                                 status: .banned, banType: .goldSrc)
        XCTAssertEqual(payload, "sunucu=Example Server\nadres=192.0.2.10:27015\ndurum=banned\nban=goldSrc\nsurum=goldsrc48")
        let keys = payload.split(separator: "\n").map { String($0.split(separator: "=").first ?? "") }
        XCTAssertEqual(keys, ["sunucu", "adres", "durum", "ban", "surum"])
    }

    // MARK: Layout and pixels (§33.1.5)

    static func goldSrcContent(name: String = "Example Server", type: ShareCardBanType = .goldSrc,
                               status: ShareCardStatus = .banned) -> ShareCardContent {
        ShareCardContent(serverName: name, hostPort: "192.0.2.10:27015", cid: "", playerName: "TestOyuncu",
                         dateText: "27 Kas 2026 13:45",
                         labels: ShareCardLabels(title: "Cybokron Oyuncu Kimlik Kartı", server: "Sunucu", cid: "CID",
                                                 player: "Oyuncu", date: "Tarih", status: "DURUM", banType: "BAN TİPİ",
                                                 qrNote: "QR: durum özeti, CID içermez"),
                         statusText: status == .banned ? "Ban var" : "Doğrulanamadı",
                         banTypeText: type == .goldSrc ? "Sunucu bağlantı banı (tür belirsiz)" : "Belirlenemedi",
                         status: status, banType: type, showsCID: false,
                         qrPayload: ShareCardQR.goldSrcPayload(serverName: name, hostPort: "192.0.2.10:27015",
                                                               status: status, banType: type))
    }

    static func source49Content(name: String = "Example Server", typeText: String = "CID banı") -> ShareCardContent {
        ShareCardContent(serverName: name, hostPort: "192.0.2.10:27015", cid: cid, playerName: "TestOyuncu",
                         dateText: "27 Kas 2026 13:45",
                         labels: ShareCardLabels(title: "Cybokron Oyuncu Kimlik Kartı", server: "Sunucu", cid: "CID",
                                                 player: "Oyuncu", date: "Tarih", status: "DURUM", banType: "BAN TİPİ"),
                         statusText: "Ban var", banTypeText: typeText, status: .banned, banType: .cid)
    }

    /// T-33-10: every box stays inside the card and its column, the middle block does not reach the player/date row,
    /// no two boxes overlap, player and date keep their size and text.
    func testLayoutFitsForLongTexts() throws {
        let longName = "Demo RPG | An intentionally very long demo server name 2026 extra"
        let longType = String(repeating: "Çok uzun ban tipi açıklaması ", count: 4)
        var variants: [(String, ShareCardContent)] = [
            ("goldsrc", Self.goldSrcContent()),
            ("goldsrc-long", Self.goldSrcContent(name: longName)),
            ("source49", Self.source49Content()),
            ("source49-long", Self.source49Content(name: longName, typeText: longType)),
            ("legacy", ShareCardContent(serverName: longName, hostPort: "h:1", cid: Self.cid, playerName: "P",
                                        dateText: "d", labels: ShareCardLabels(title: "T", server: "S", cid: "C",
                                                                               player: "P", date: "D"))),
        ]
        var longest = Self.source49Content(name: longName, typeText: longType)
        longest.statusText = String(repeating: "Doğrulanamadı ", count: 6)
        longest.playerName = String(repeating: "W", count: 80)
        longest.dateText = String(repeating: "Wednesday ", count: 10)
        variants.append(("longest", longest))

        for (name, content) in variants {
            let layout = ShareCardRenderer.layout(content)
            XCTAssertEqual(ShareCardEvidence.layoutProblems(layout), [], name)
        }
        // Normal texts are not cut; the long GoldSrc name wraps to two lines instead.
        XCTAssertFalse(ShareCardRenderer.layout(Self.goldSrcContent()).boxes.contains(where: \.truncated))
        let wrapped = try XCTUnwrap(ShareCardRenderer.layout(Self.goldSrcContent(name: longName)).box(.serverName))
        XCTAssertEqual(wrapped.lineCount, 2)
        XCTAssertFalse(wrapped.truncated)
        XCTAssertEqual(ShareCardRenderer.layout(Self.goldSrcContent()).box(.banType)?.text,
                       "Sunucu bağlantı banı (tür belirsiz)")
        // Wrapping keeps the whole name (no character cut before the line break).
        XCTAssertEqual(wrapped.text.replacingOccurrences(of: "\n", with: " "), longName)
        // Captions are upper-cased in the card language (Turkish dotted İ).
        try inTurkish {
            XCTAssertEqual(ShareCardRenderer.layout(Self.goldSrcContent()).box(.dateCaption)?.text, "TARİH")
        }
    }

    /// §33.1.5: the wrapped fields go to CoreText whole — a 108+ character name that fits two lines is shown in full
    /// (no cut at 96 or any other character count).
    func testLongWrappedTextIsMeasuredWhole() throws {
        let narrow = String(repeating: "il li ", count: 20).trimmingCharacters(in: .whitespaces)   // 119 characters
        XCTAssertGreaterThanOrEqual(narrow.count, 108)
        var content = Self.goldSrcContent(name: narrow)
        content.banTypeText = narrow
        content.statusText = narrow
        let layout = ShareCardRenderer.layout(content)
        for role in [ShareCardLayout.Role.serverName, .status, .banType] {
            let box = try XCTUnwrap(layout.box(role), role.rawValue)
            XCTAssertFalse(box.truncated, role.rawValue)
            XCTAssertEqual(box.text.replacingOccurrences(of: "\n", with: " "), narrow, role.rawValue)
        }
        XCTAssertEqual(ShareCardEvidence.layoutProblems(layout), [])
    }

    /// §33.1.5: text that does not fit two lines even at the floor is drawn at `minimumScale` and cut with "…" — the
    /// cut comes from the measurement, not from a character cap.
    func testOverlongTextUsesTheFloorThenEllipsis() throws {
        let words = (1...40).map { "Sunucu\($0)" }.joined(separator: " ")   // ~330 characters
        XCTAssertGreaterThan(words.count, 300)
        let layout = ShareCardRenderer.layout(Self.goldSrcContent(name: words))
        XCTAssertEqual(layout.scale, ShareCardRenderer.minimumScale)
        let name = try XCTUnwrap(layout.box(.serverName))
        XCTAssertTrue(name.truncated)
        XCTAssertEqual(name.lineCount, 2)
        XCTAssertTrue(name.text.hasSuffix("…"))
        XCTAssertTrue(words.hasPrefix(String(name.text.replacingOccurrences(of: "\n", with: " ").dropLast())
                                        .trimmingCharacters(in: .whitespaces)))
        XCTAssertEqual(ShareCardEvidence.layoutProblems(layout), [])
        // A text that fits at some scale above the floor is never cut.
        let fits = ShareCardRenderer.layout(Self.source49Content(name: "Demo Source49 Server"))
        XCTAssertFalse(fits.boxes.contains(where: \.truncated))
        XCTAssertGreaterThan(fits.scale, ShareCardRenderer.minimumScale)
        // No character cap at all: 5000 characters reach CoreText whole (in every wrapped field, player and date
        // included) and only the measured last line ends with "…".
        let hugeText = (1...1_100).map { "w\($0)" }.joined(separator: " ")
        XCTAssertGreaterThanOrEqual(hugeText.count, 5_000)
        XCTAssertEqual(ShareCardText.displayed(hugeText), hugeText)
        var hugeContent = Self.goldSrcContent(name: hugeText)
        hugeContent.statusText = hugeText
        hugeContent.banTypeText = hugeText
        hugeContent.playerName = hugeText
        hugeContent.dateText = hugeText
        let huge = ShareCardRenderer.layout(hugeContent)
        XCTAssertEqual(huge.scale, ShareCardRenderer.minimumScale)
        for role in [ShareCardLayout.Role.serverName, .status, .banType, .player, .date] {
            let box = try XCTUnwrap(huge.box(role), role.rawValue)
            XCTAssertTrue(box.truncated, role.rawValue)
            XCTAssertTrue(box.text.hasSuffix("…"), role.rawValue)
            // What is shown is the start of the full text (no "…" in the middle from an earlier cut).
            let shown = String(box.text.replacingOccurrences(of: "\n", with: " ").dropLast())
                .trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(hugeText.hasPrefix(shown), role.rawValue)
            XCTAssertEqual(box.text.filter { $0 == "…" }.count, 1, role.rawValue)
        }
        XCTAssertEqual(huge.box(.player)?.fontSize, 36)
        XCTAssertEqual(huge.box(.date)?.fontSize, 26)
        XCTAssertEqual(ShareCardEvidence.layoutProblems(huge), [])
        // The player name is not cut before the layout either: it wraps in its own column (same size), and only a
        // name longer than two lines ends with "…".
        var longPlayer = Self.goldSrcContent()
        longPlayer.playerName = "TestPlayer With A Long Display Name"
        let wrappedPlayer = try XCTUnwrap(ShareCardRenderer.layout(longPlayer).box(.player))
        XCTAssertEqual(wrappedPlayer.lineCount, 2)
        XCTAssertFalse(wrappedPlayer.truncated)
        XCTAssertEqual(wrappedPlayer.fontSize, 36)
        XCTAssertEqual(wrappedPlayer.text.replacingOccurrences(of: "\n", with: " "), longPlayer.playerName)
        longPlayer.playerName = String(repeating: "P", count: 60)
        let cutPlayer = try XCTUnwrap(ShareCardRenderer.layout(longPlayer).box(.player))
        XCTAssertTrue(cutPlayer.truncated)
        XCTAssertEqual(ShareCardEvidence.layoutProblems(ShareCardRenderer.layout(longPlayer)), [])
    }

    /// AC-33.1.J / AC-33.1.K in every app language: layout inside the card, no overlap, GoldSrc texts and a CID-free
    /// QR (the evidence test writes the same cards as PNG files with a manifest).
    func testEveryLanguageCardFits() throws {
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(L10n.languageBundle(language.rawValue), language.rawValue)
            try L10n.$bundle.withValue(bundle) {
                for item in ShareCardEvidence.cases {
                    let content = ShareCardEvidence.content(item, icon: nil)
                    let result = try ShareCardEvidence.verify(content, case: item, language: language.rawValue,
                                                              decodeQR: item.goldSrc)
                    XCTAssertEqual(result.result.problems, [], "\(language.rawValue)-\(item.name)")
                }
            }
        }
    }

    /// T-33-1 / T-33-9: GoldSrc card has DURUM + BAN TİPİ, no CID row; its QR holds no CID.
    func testGoldSrcCardHasNoCIDRow() throws {
        let content = Self.goldSrcContent()
        let layout = ShareCardRenderer.layout(content)
        XCTAssertNil(layout.box(.cid))
        XCTAssertNil(layout.box(.cidCaption))
        XCTAssertEqual(layout.box(.status)?.text, "Ban var")
        XCTAssertEqual(layout.box(.statusCaption)?.text, "DURUM")
        XCTAssertEqual(layout.box(.banTypeCaption)?.text, "BAN TİPİ")
        XCTAssertFalse(layout.boxes.contains { $0.text.contains(Self.cid) })
        let image = try Self.decode(try XCTUnwrap(ShareCardRenderer.png(content)))
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 630)
        let messages = Self.qrMessages(image)
        XCTAssertEqual(messages, [content.qrPayload])
        XCTAssertFalse(messages.joined().contains(Self.cid))
    }

    /// T-33-2: Source49 keeps the CID row and its CID QR, with DURUM + BAN TİPİ added.
    func testSource49KeepsCIDAndQR() throws {
        let content = Self.source49Content()
        XCTAssertNil(content.qrPayload)
        XCTAssertEqual(content.resolvedQRPayload, Self.cid)
        let layout = ShareCardRenderer.layout(content)
        XCTAssertEqual(layout.box(.cid)?.text, Self.cid)
        XCTAssertEqual(layout.box(.status)?.text, "Ban var")
        XCTAssertEqual(layout.box(.banType)?.text, "CID banı")
        XCTAssertNil(layout.box(.qrNote))
        let image = try Self.decode(try XCTUnwrap(ShareCardRenderer.png(content)))
        XCTAssertEqual(Self.qrMessages(image), [Self.cid])
    }

    /// T-33-11 / T-33-12: the DURUM value is drawn red with its symbol; the BAN TİPİ orange with its symbol.
    func testColourComesWithTextAndSymbol() throws {
        let content = Self.goldSrcContent()
        let layout = ShareCardRenderer.layout(content)
        let image = try Self.decode(try XCTUnwrap(ShareCardRenderer.png(content)))
        let status = try XCTUnwrap(layout.box(.status))
        let type = try XCTUnwrap(layout.box(.banType))
        XCTAssertEqual(status.symbol, .octagon)
        XCTAssertEqual(type.symbol, .triangle)
        let side = status.fontSize * 0.9
        // Symbol part and text part both carry the colour.
        XCTAssertGreaterThan(Self.count(of: ShareCardRenderer.banRed, in: image,
                                        rect: CGRect(x: status.frame.minX, y: status.frame.minY,
                                                     width: side, height: status.frame.height)), 50)
        XCTAssertGreaterThan(Self.count(of: ShareCardRenderer.banRed, in: image,
                                        rect: CGRect(x: status.frame.minX + side + 12, y: status.frame.minY,
                                                     width: status.frame.width - side - 12,
                                                     height: status.frame.height)), 50)
        XCTAssertGreaterThan(Self.count(of: ShareCardRenderer.warningOrange, in: image, rect: type.frame), 50)
        // Nothing red outside the status/type boxes' column (the card has no other red).
        XCTAssertEqual(Self.count(of: ShareCardRenderer.banRed, in: image,
                                  rect: CGRect(x: 0, y: 10, width: 60, height: 620)), 0)
        XCTAssertNil(ShareCardRenderer.symbol(of: ShareCardBanType.none))
        XCTAssertEqual(ShareCardRenderer.symbol(of: ShareCardBanType.ip), .octagon)
    }

    // MARK: Helpers

    static func decode(_ png: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func qrMessages(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    /// Pixels close to `color` inside `rect` (card coordinates, origin bottom left).
    static func count(of color: CGColor, in image: CGImage, rect: CGRect) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              let target = color.components, target.count >= 3 else { return 0 }
        let step = image.bitsPerPixel / 8
        let bounds = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !bounds.isNull else { return 0 }
        var hits = 0
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            let row = image.height - 1 - y
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                let offset = row * image.bytesPerRow + x * step
                let r = CGFloat(bytes[offset]) / 255, g = CGFloat(bytes[offset + 1]) / 255, b = CGFloat(bytes[offset + 2]) / 255
                if abs(r - target[0]) < 0.06, abs(g - target[1]) < 0.06, abs(b - target[2]) < 0.06 { hits += 1 }
            }
        }
        return hits
    }
}

/// §33.1 card content from the app model (T-33-1 … T-33-9).
@MainActor
final class ShareCardBanModelTests: XCTestCase {
    private static let cid = ShareCardBanTests.cid

    private func model(_ env: TestAppEnvironment, _ entries: [ServerEntry]) throws -> AppModel {
        let record = Snapshot(savedAt: env.clock.now, gamedir: "valve",
                              dataRoot: env.home.appendingPathComponent("Library/Application Support/Xash3D FWGS").path,
                              displayName: "N", model: "gordon", rawID: ShareCardBanTests.rawIDHex, identitySource: "",
                              network: NetworkInfo(publicIP: "203.0.113.7", lanIPs: []), servers: entries)
        try SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).save(record)
        return env.makeModel()
    }

    private func entry(_ status: BanStatus?, goldSrc: Bool = false, label: String = "Example Server") -> ServerEntry {
        var entry = ServerEntry(label: label, host: "192.0.2.10", cid: Self.cid)
        if let status {
            entry.banCheck = BanCheck(status: status, checkedAt: Date(timeIntervalSince1970: 1_800_000_000), detail: "",
                                      info: goldSrc ? ServerInfo(name: label, serverProtocol: .goldsrc48) : nil)
        }
        return entry
    }

    private func content(_ status: BanStatus?, goldSrc: Bool = false) throws -> ShareCardContent {
        let env = try TestAppEnvironment()
        let entry = entry(status, goldSrc: goldSrc)
        let model = try model(env, [entry])
        return try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            try XCTUnwrap(model.shareCardContent(for: entry.id, icon: nil))
        }
    }

    func testGoldSrcBanned() throws {
        let card = try content(.goldSrcBanned, goldSrc: true)
        XCTAssertEqual(card.statusText, "Ban var")
        XCTAssertEqual(card.banTypeText, "Sunucu bağlantı banı (tür belirsiz)")
        XCTAssertEqual(card.labels.status, "DURUM")
        XCTAssertEqual(card.labels.banType, "BAN TİPİ")
        XCTAssertFalse(card.showsCID)
        XCTAssertEqual(card.cid, "")
        let payload = try XCTUnwrap(card.qrPayload)
        XCTAssertEqual(payload, "sunucu=Example Server\nadres=192.0.2.10:27015\ndurum=banned\nban=goldSrc\nsurum=goldsrc48")
        for secret in [Self.cid, ShareCardBanTests.rawIDHex, ShareCardBanTests.rawIDHex.lowercased(), "/Users", "ticket",
                       "password"] {
            XCTAssertFalse(payload.contains(secret), secret)
        }
        // The rendered card has no CID text anywhere and its QR is the status payload.
        let layout = ShareCardRenderer.layout(card)
        XCTAssertNil(layout.box(.cid))
        XCTAssertFalse(layout.boxes.contains { $0.text.contains(Self.cid) || $0.text.contains("N/A") })
        let image = try ShareCardBanTests.decode(try XCTUnwrap(ShareCardRenderer.png(card)))
        XCTAssertEqual(ShareCardBanTests.qrMessages(image), [payload])
    }

    func testSource49CIDBanned() throws {
        let card = try content(.cidBanned)
        XCTAssertEqual(card.statusText, "Ban var")
        XCTAssertEqual(card.banTypeText, "CID banı")
        XCTAssertTrue(card.showsCID)
        XCTAssertEqual(card.cid, Self.cid)
        XCTAssertNil(card.qrPayload)
        XCTAssertEqual(card.resolvedQRPayload, Self.cid)
    }

    func testIPBanAndRangePriority() async throws {
        let ip = try content(.ipBanned)
        XCTAssertEqual(ip.statusText, "Ban var")
        XCTAssertEqual(ip.banTypeText, "IP banı")

        let env = try TestAppEnvironment()
        let entry = entry(.ipBanned)
        let model = try model(env, [entry])
        try env.historyStore.append([HistoryEntry(ts: env.clock.now.addingTimeInterval(-600), kind: .fixAttempt,
                                                  serverID: entry.id, host: entry.host, old: "198.51.100.7",
                                                  new: "198.51.2.9", note: "rangeBanned")])
        let bundle = try XCTUnwrap(L10n.languageBundle("tr"))
        let loaded = await L10n.$bundle.withValue(bundle) {
            await model.shareCardContentWithHistory(for: entry.id, icon: nil)
        }
        let withHistory = try XCTUnwrap(loaded)
        XCTAssertEqual(withHistory.statusText, "Ban var")
        XCTAssertEqual(withHistory.banTypeText, "IP aralık banı")
        XCTAssertEqual(withHistory.banType, .ipRange)
        let explicit = try L10n.$bundle.withValue(bundle) {
            try XCTUnwrap(model.shareCardContent(for: entry.id, icon: nil, historyRange: "198.51.0.0/16"))
        }
        XCTAssertEqual(explicit.banTypeText, "IP aralık banı")
        // A resolved range is no longer used.
        try env.historyStore.append([HistoryEntry(ts: env.clock.now, kind: .fixAttempt, serverID: entry.id,
                                                  host: entry.host, old: nil, new: nil, note: "resolved")])
        let resolved = await model.shareCardContentWithHistory(for: entry.id, icon: nil)
        XCTAssertEqual(resolved?.banType, .ip)
    }

    /// A GoldSrc 48 row whose saved result is an older Source `cidBanned`: no CID ban claim, no "Ban var".
    func testGoldSrcWithLegacyCIDBanIsUnverified() throws {
        let card = try content(.cidBanned, goldSrc: true)
        XCTAssertEqual(card.status, .unverified)
        XCTAssertEqual(card.banType, .unknown)
        XCTAssertEqual(card.statusText, "Doğrulanamadı")
        XCTAssertEqual(card.banTypeText, "Belirlenemedi")
        XCTAssertNotEqual(card.banType, .cid)
        XCTAssertFalse(card.showsCID)
        XCTAssertEqual(card.qrPayload?.contains("durum=unverified\nban=unknown"), true)
    }

    func testUnverifiedUnknownUnreachable() throws {
        for (status, goldSrc) in [(BanStatus.goldSrcUnverified, true), (.cidUnknown, false), (.unknown, false)] {
            let card = try content(status, goldSrc: goldSrc)
            XCTAssertEqual(card.statusText, "Doğrulanamadı", "\(status)")
            XCTAssertEqual(card.banTypeText, "Belirlenemedi", "\(status)")
        }
        let unreachable = try content(.unreachable)
        XCTAssertEqual(unreachable.statusText, "Doğrulanamadı")
        XCTAssertEqual(unreachable.banTypeText, "—")
        let goldSrc = try content(.goldSrcUnverified, goldSrc: true)
        XCTAssertFalse(goldSrc.showsCID)
        XCTAssertEqual(goldSrc.qrPayload?.contains("durum=unverified\nban=unknown"), true)
    }

    /// §33.1.3: a Source49 row without a CID draws no CID caption or row (and has no QR).
    func testSource49WithoutCIDHasNoCIDRow() throws {
        let env = try TestAppEnvironment()
        var entry = entry(.cidBanned)
        entry.cid = ""
        let model = try model(env, [entry])
        let card = try XCTUnwrap(model.shareCardContent(for: entry.id, icon: nil))
        XCTAssertFalse(card.showsCID)
        XCTAssertEqual(card.resolvedQRPayload, "")
        let layout = ShareCardRenderer.layout(card)
        XCTAssertNil(layout.box(.cid))
        XCTAssertNil(layout.box(.cidCaption))
        XCTAssertNil(layout.qrTile)
        XCTAssertNotNil(layout.box(.status))
    }

    /// §33.1.2: the sheet renders one final PNG after the history's range ban is read; until then the preview is
    /// loading and Copy/Save are disabled.
    func testExportIsDisabledUntilTheHistoryIsRead() async throws {
        let env = try TestAppEnvironment()
        let entry = entry(.ipBanned)
        let model = try model(env, [entry])
        try env.historyStore.append([HistoryEntry(ts: env.clock.now.addingTimeInterval(-600), kind: .fixAttempt,
                                                  serverID: entry.id, host: entry.host, old: "198.51.100.7",
                                                  new: "198.51.2.9", note: "rangeBanned")])
        let preview = ShareCardPreview()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let loading = Task {
            await preview.load {
                for await _ in gate { break }
                return await model.shareCardContentWithHistory(for: entry.id, icon: nil)
            }
        }
        await Task.yield()
        XCTAssertEqual(preview.phase, .loading)
        XCTAssertFalse(preview.canExport)
        XCTAssertNil(preview.png)

        let sheet = ShareCardSheet(model: model, serverID: entry.id, onClose: {}, preview: preview)
        let hosting = NSHostingView(rootView: sheet.frame(width: 640, height: 470))
        hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 470)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 640, height: 470),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func settle(_ view: NSView? = nil) {
            for _ in 0..<10 {
                (view ?? hosting).layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        settle()
        // The XCTest host exposes no SwiftUI accessibility tree, so the hosted sheet is checked by its views and
        // pixels: while loading it shows the progress indicator, and its Copy/Save row is drawn exactly like the
        // failed sheet's (both disabled by `!preview.canExport`).
        XCTAssertTrue(Self.contains(NSProgressIndicator.self, in: hosting))
        let failed = ShareCardPreview()
        await failed.load { nil }
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertFalse(failed.canExport)
        let loadingStrip = try Self.buttonStrip(hosting)
        let failedHost = NSHostingView(rootView: ShareCardSheet(model: model, serverID: entry.id, onClose: {},
                                                                preview: failed).frame(width: 640, height: 470))
        failedHost.frame = hosting.frame
        window.contentView = failedHost
        settle(failedHost)
        XCTAssertEqual(try Self.buttonStrip(failedHost), loadingStrip)
        window.contentView = hosting
        XCTAssertEqual(preview.phase, .loading)

        open.yield()
        open.finish()
        await loading.value
        let png = try XCTUnwrap(preview.png)
        XCTAssertTrue(preview.canExport)
        // The one PNG already carries the history's range ban.
        let refined = await model.shareCardContentWithHistory(for: entry.id, icon: nil)
        let expected = try XCTUnwrap(refined)
        XCTAssertEqual(expected.banType, .ipRange)
        XCTAssertEqual(png, ShareCardRenderer.png(expected))
        settle()
        XCTAssertFalse(Self.contains(NSProgressIndicator.self, in: hosting))
        // The view's task running again does not render a second PNG.
        await preview.load {
            XCTFail("loaded twice")
            return nil
        }
        XCTAssertEqual(preview.png, png)
    }

    private static func contains(_ type: NSView.Type, in view: NSView) -> Bool {
        view.isKind(of: type) || view.subviews.contains { contains(type, in: $0) }
    }

    /// PNG of the sheet's lower part (the Copy / Save / Close row).
    private static func buttonStrip(_ view: NSView) throws -> Data {
        let strip = CGRect(x: 0, y: view.isFlipped ? view.bounds.height - 120 : 0, width: view.bounds.width, height: 120)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: strip))
        view.cacheDisplay(in: strip, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testNotCheckedAndCIDOk() throws {
        let none = try content(nil)
        XCTAssertEqual(none.statusText, "Kontrol edilmedi")
        XCTAssertEqual(none.banTypeText, "—")
        XCTAssertEqual(none.status, .notChecked)
        let ok = try content(.cidOk)
        XCTAssertEqual(ok.statusText, "Ban yok")
        XCTAssertEqual(ok.banTypeText, "—")
        XCTAssertEqual(ok.cid, Self.cid)
    }
}

/// §33.1 evidence: the cards of every case in the current language and their checks (shared by the always-run test
/// and the PNG evidence test).
enum ShareCardEvidence {
    struct Case {
        let name: String
        let status: BanStatus?
        let goldSrc: Bool
        let range: Bool
        let label: String
        /// Uses the longest status and ban type texts of the language instead of the case's own.
        var longest = false
    }

    static let cid = ShareCardBanTests.cid
    static let rawIDHex = ShareCardBanTests.rawIDHex
    static let hostPort = "198.51.100.20:27015"
    static let longName = "Demo RPG | An intentionally very long demo server name 2026 with extra words for wrapping tests"

    static let cases: [Case] = [
        Case(name: "goldsrc-banned", status: .goldSrcBanned, goldSrc: true, range: false, label: "Example Server"),
        Case(name: "goldsrc-banned-long", status: .goldSrcBanned, goldSrc: true, range: false, label: longName),
        Case(name: "goldsrc-unverified", status: .goldSrcUnverified, goldSrc: true, range: false, label: "Example Server"),
        Case(name: "goldsrc-longest", status: .goldSrcBanned, goldSrc: true, range: false, label: longName, longest: true),
        Case(name: "source49-cid-banned", status: .cidBanned, goldSrc: false, range: false, label: "Demo Source49"),
        Case(name: "source49-cid-banned-long", status: .cidBanned, goldSrc: false, range: false, label: longName),
        Case(name: "source49-ip-banned", status: .ipBanned, goldSrc: false, range: false, label: "Demo Source49"),
        Case(name: "source49-ip-range-banned", status: .ipBanned, goldSrc: false, range: true, label: "Demo Source49"),
        Case(name: "source49-unknown", status: .unknown, goldSrc: false, range: false, label: "Demo Source49"),
        Case(name: "source49-unreachable", status: .unreachable, goldSrc: false, range: false, label: "Demo Source49"),
        Case(name: "source49-cid-ok", status: .cidOk, goldSrc: false, range: false, label: "Demo Source49"),
        Case(name: "source49-longest", status: .ipBanned, goldSrc: false, range: false, label: longName, longest: true),
        Case(name: "not-checked", status: nil, goldSrc: false, range: false, label: "Demo Source49"),
    ]

    /// Card content as the app builds it, in the current language.
    static func content(_ item: Case, icon: CGImage?) -> ShareCardContent {
        let summary = item.longest ? longestSummary(goldSrc: item.goldSrc)
            : ShareCardBanSummary.classify(item.status, rangeKnown: item.range, goldSrc: item.goldSrc)
        return ShareCardContent(
            serverName: item.label, hostPort: hostPort, cid: item.goldSrc ? "" : cid,
            playerName: item.longest ? "TestPlayer With A Long Display Name" : "TestPlayer",
            dateText: "27.11.2026 13:45",
            labels: ShareCardLabels(title: L10n.text(.appWindowTitle), server: L10n.text(.shareCardServer),
                                    cid: L10n.text(.shareCardCID), player: L10n.text(.shareCardPlayer),
                                    date: L10n.text(.shareCardDate), status: L10n.text(.shareCardStatus),
                                    banType: L10n.text(.shareCardBanType), qrNote: L10n.text(.shareCardQRStatusOnly)),
            icon: icon, statusText: summary.status.text, banTypeText: summary.banType.text,
            status: summary.status, banType: summary.banType, showsCID: !item.goldSrc,
            qrPayload: item.goldSrc ? ShareCardQR.goldSrcPayload(serverName: item.label, hostPort: hostPort,
                                                                 status: summary.status, banType: summary.banType) : nil)
    }

    /// The real (status, type) outcome with the longest texts in the current language for this server kind — text
    /// and enum always come from the same summary.
    static func longestSummary(goldSrc: Bool) -> (status: ShareCardStatus, banType: ShareCardBanType) {
        let outcomes = ([nil] + BanStatus.allCases.map(Optional.some)).flatMap { status in
            [false, true].map { ShareCardBanSummary.classify(status, rangeKnown: $0, goldSrc: goldSrc) }
        }
        return outcomes.max { a, b in
            (a.status.text.count + a.banType.text.count) < (b.status.text.count + b.banType.text.count)
        } ?? (.notChecked, .none)
    }

    struct Result: Encodable {
        let language: String
        let caseName: String
        var file: String?
        let width: Int
        let height: Int
        let scale: Double
        let status: String
        let banType: String
        let statusText: String
        let banTypeText: String
        let truncatedRoles: [String]
        let qrPayload: String
        let qrDecoded: [String]?
        let problems: [String]
    }

    /// Renders the card and checks it; `problems` is empty when everything holds.
    static func verify(_ content: ShareCardContent, case item: Case, language: String,
                       decodeQR: Bool) throws -> (png: Data, result: Result) {
        let layout = ShareCardRenderer.layout(content)
        var problems = layoutProblems(layout)
        let png = try XCTUnwrap(ShareCardRenderer.png(content))
        let image = try ShareCardBanTests.decode(png)
        if image.width != 1200 || image.height != 630 { problems.append("size \(image.width)x\(image.height)") }
        let status = layout.box(.status)?.text.replacingOccurrences(of: "\n", with: " ") ?? ""
        let type = layout.box(.banType)?.text.replacingOccurrences(of: "\n", with: " ") ?? ""
        if status != content.statusText { problems.append("status drawn as \(status)") }
        if type != content.banTypeText { problems.append("ban type drawn as \(type)") }
        if item.goldSrc {
            if item.status == .goldSrcBanned, !item.longest {
                if content.statusText != ShareCardStatus.banned.text { problems.append("GoldSrc status is not banned") }
                if content.banTypeText != ShareCardBanType.goldSrc.text {
                    problems.append("GoldSrc type is not the server connection ban")
                }
            }
            if layout.box(.cid) != nil || layout.box(.cidCaption) != nil { problems.append("GoldSrc card has a CID row") }
        } else if layout.box(.cid)?.text != cid {
            problems.append("Source49 card lost its CID")
        }
        // §33.1.5: "…" only as the last resort (middle block at the floor scale).
        let middleRoles: Set<ShareCardLayout.Role> = [.serverName, .status, .banType]
        if layout.boxes.contains(where: { middleRoles.contains($0.role) && $0.truncated }),
           layout.scale > ShareCardRenderer.minimumScale {
            problems.append("ellipsis above the floor scale \(layout.scale)")
        }
        let payload = content.resolvedQRPayload
        var decoded: [String]?
        if decodeQR {
            let messages = ShareCardBanTests.qrMessages(image)
            decoded = messages
            if messages != [payload] { problems.append("QR decodes as \(messages)") }
        }
        if item.goldSrc {
            for secret in [cid, rawIDHex, rawIDHex.lowercased()] {
                if payload.contains(secret) || (decoded ?? []).joined().contains(secret)
                    || layout.boxes.contains(where: { $0.text.contains(secret) }) {
                    problems.append("GoldSrc card or QR contains \(secret)")
                }
            }
            if !payload.hasSuffix("surum=goldsrc48") { problems.append("payload without surum=goldsrc48") }
        }
        // The texts and the enums (colour, symbol, QR keys) come from one summary: no "could not be verified" in a
        // red octagon.
        if let value = content.status {
            if content.statusText != value.text { problems.append("status text does not match .\(value)") }
            if let box = layout.box(.status) {
                if box.symbol != ShareCardRenderer.symbol(of: value) { problems.append("status symbol does not match") }
                if box.color != ShareCardRenderer.color(of: value) { problems.append("status colour does not match") }
            }
        } else {
            problems.append("status without enum")
        }
        if let value = content.banType {
            if content.banTypeText != value.text { problems.append("ban type text does not match .\(value)") }
            if let box = layout.box(.banType) {
                if box.symbol != ShareCardRenderer.symbol(of: value) { problems.append("ban type symbol does not match") }
                if box.color != ShareCardRenderer.color(of: value) { problems.append("ban type colour does not match") }
            }
        } else {
            problems.append("ban type without enum")
        }
        if item.goldSrc, let status = content.status, let type = content.banType,
           payload != ShareCardQR.goldSrcPayload(serverName: content.serverName, hostPort: content.hostPort,
                                                 status: status, banType: type) {
            problems.append("QR payload does not match the summary")
        }
        let result = Result(language: language, caseName: item.name, file: nil, width: image.width, height: image.height,
                            scale: Double(layout.scale), status: content.status?.rawValue ?? "",
                            banType: content.banType?.rawValue ?? "", statusText: content.statusText,
                            banTypeText: content.banTypeText,
                            truncatedRoles: layout.boxes.filter(\.truncated).map(\.role.rawValue),
                            qrPayload: payload, qrDecoded: decoded, problems: problems)
        return (png, result)
    }

    /// Bounds, columns, overlaps, the middle block above the player/date row, and the fixed player/date row.
    static func layoutProblems(_ layout: ShareCardLayout) -> [String] {
        var problems: [String] = []
        if layout.scale < ShareCardRenderer.minimumScale { problems.append("scale \(layout.scale) below the floor") }
        let card = CGRect(x: 0, y: 10, width: ShareCardRenderer.width, height: ShareCardRenderer.height - 10)
        for box in layout.boxes {
            if !card.contains(box.frame) { problems.append("\(box.role) outside the card \(box.frame)") }
            if box.frame.width > box.maxWidth + 0.5 { problems.append("\(box.role) wider than \(box.maxWidth)") }
            if box.role != .qrNote, let tile = layout.qrTile, box.frame.maxX >= tile.minX {
                problems.append("\(box.role) runs into the QR")
            }
        }
        for (index, a) in layout.boxes.enumerated() {
            for b in layout.boxes[(index + 1)...]
            where a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame.insetBy(dx: 0.5, dy: 0.5)) {
                problems.append("\(a.role) overlaps \(b.role)")
            }
        }
        let middle: Set<ShareCardLayout.Role> = [.serverCaption, .serverName, .hostPort, .cidCaption, .cid,
                                                 .statusCaption, .status, .banTypeCaption, .banType]
        for box in layout.boxes where middle.contains(box.role) && box.frame.minY < layout.stackBottom - 0.5 {
            problems.append("\(box.role) reaches the player/date row")
        }
        if layout.box(.player)?.fontSize != 36 || layout.box(.player)?.text.isEmpty != false {
            problems.append("player missing or shrunk")
        }
        if layout.box(.date)?.fontSize != 26 || layout.box(.date)?.text.isEmpty != false {
            problems.append("date missing or shrunk")
        }
        if layout.box(.playerCaption) == nil || layout.box(.dateCaption) == nil { problems.append("caption missing") }
        return problems
    }
}

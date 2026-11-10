import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §48 History, Ban Matrix and Metrics redesign: row/chip/chart formatting, narrow-width column priority,
/// 5000-row preparation and the token-only source scan of the three view files.
@MainActor
final class SecondaryWindowsRedesignTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() async throws {
        L10n.setting = .system
    }

    // MARK: §48.1 History

    func testHistoryRowsShowKindServerChangeAndRelativeTimeNewestFirst() {
        let server = UUID()
        let entries = [
            HistoryEntry(ts: now.addingTimeInterval(-3_600), kind: .banAppeared, serverID: server, host: "192.0.2.30",
                         new: "ipBanned"),
            HistoryEntry(ts: now.addingTimeInterval(-300), kind: .banLifted, serverID: server, host: "192.0.2.30",
                         old: "ipBanned", new: "cidOk"),
            HistoryEntry(ts: now.addingTimeInterval(-10), kind: .refresh, new: HistoryTransitions.levelName(.red)),
            HistoryEntry(ts: now.addingTimeInterval(-7_200), kind: .ipChanged, serverID: UUID(), host: "old.example.test",
                         old: "203.0.113.7", new: "198.51.100.1"),
        ]
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            let rows = HistoryRowContent.make(HistoryFilter().apply(entries), now: now) { entry in
                entry.serverID == server ? "Zombie TR" : entry.host
            }
            XCTAssertEqual(rows.map(\.kind), [HistoryText.kind(.refresh), HistoryText.kind(.banLifted),
                                              HistoryText.kind(.banAppeared), HistoryText.kind(.ipChanged)])
            XCTAssertEqual(rows.map(\.tone), [.red, .green, .red, .accent])
            XCTAssertEqual(rows.map(\.symbol), ["arrow.clockwise", "checkmark.shield.fill", "xmark.octagon.fill", "network"])
            XCTAssertEqual(rows.map(\.server), [nil, "Zombie TR", "Zombie TR", "old.example.test"])
            XCTAssertEqual(rows[1].change, BanStatus.ipBanned.label + " → " + HistoryText.value("cidOk", kind: .banLifted)!)
            XCTAssertEqual(rows[3].change, "203.0.113.7 → 198.51.100.1")
            XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
            for row in rows {
                XCTAssertFalse(row.absoluteTime.isEmpty)
                XCTAssertNotEqual(row.absoluteTime, row.relativeTime)
                XCTAssertTrue(row.accessibilityValue.contains(row.absoluteTime))
            }
            if language == .en {
                XCTAssertEqual(rows[0].relativeTime, "now")
                XCTAssertEqual(rows[1].relativeTime, "5 minutes ago")
                XCTAssertEqual(rows[2].relativeTime, "1 hour ago")
                XCTAssertEqual(L10n.format(.historyFilterValue, L10n.text(.historyFilterKind), L10n.text(.historyFilterAll)),
                               "Type: All")
            } else {
                XCTAssertEqual(rows[0].relativeTime, "şimdi")
                XCTAssertEqual(rows[1].relativeTime, "5 dakika önce")
                XCTAssertEqual(rows[2].relativeTime, "1 saat önce")
                XCTAssertEqual(L10n.format(.historyFilterValue, L10n.text(.historyFilterKind), L10n.text(.historyFilterAll)),
                               "Tür: Tümü")
            }
        }
    }

    func testHistoryTimeFollowsTheAppLanguageNotTheSystem() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC
        XCTAssertTrue(HistoryTimeFormat(language: .en, timeZone: utc).absolute(date).contains("January 15, 2027"))
        XCTAssertTrue(HistoryTimeFormat(language: .tr, timeZone: utc).absolute(date).contains("15 Ocak 2027"))
        // A clock slightly behind never reads "in 3 seconds".
        XCTAssertEqual(HistoryTimeFormat(language: .en).relative(date.addingTimeInterval(3), now: date), "now")
    }

    func testEveryHistoryKindHasAnExistingSymbolAndATone() {
        for kind in HistoryKind.allCases {
            let symbol = HistoryKindStyle.symbol(kind)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(kind): \(symbol)")
            _ = HistoryKindStyle.tone(HistoryEntry(ts: now, kind: kind))
        }
        XCTAssertEqual(HistoryKindStyle.tone(HistoryEntry(ts: now, kind: .refresh, new: HistoryTransitions.levelName(.green))),
                       .green)
        XCTAssertEqual(HistoryKindStyle.tone(HistoryEntry(ts: now, kind: .refresh, new: "garbage")), .neutral)
        XCTAssertEqual(HistoryKindStyle.tone(HistoryEntry(ts: now, kind: .watchBanAppeared)), .red)
        XCTAssertEqual(HistoryKindStyle.tone(HistoryEntry(ts: now, kind: .fixAttempt)), .orange)
    }

    /// §48.1 "5000 satırda akıcı": rows are prepared once (not per frame) and that preparation stays cheap.
    func testFiveThousandEntriesArePreparedQuickly() {
        L10n.setting = .en
        let servers = (0..<20).map { _ in UUID() }
        let kinds = HistoryKind.allCases
        let entries = (0..<5_000).map { index in
            HistoryEntry(ts: now.addingTimeInterval(-Double(index) * 37), kind: kinds[index % kinds.count],
                         serverID: index % 3 == 0 ? nil : servers[index % servers.count], host: "192.0.2.\(index % 250)",
                         old: "203.0.113.\(index % 200)", new: "198.51.100.\(index % 200)", note: index % 5 == 0 ? "resolved" : nil)
        }
        let names = Dictionary(uniqueKeysWithValues: servers.enumerated().map { ($1, "Server \($0)") })
        let start = Date()
        let rows = HistoryRowContent.make(HistoryFilter().apply(entries), now: now) { $0.serverID.flatMap { names[$0] } }
        let filtered = HistoryRowContent.make(HistoryFilter(serverID: servers[1]).apply(entries), now: now) { _ in "x" }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(rows.count, 5_000)
        XCTAssertEqual(Set(rows.map(\.id)).count, 5_000)
        XCTAssertEqual(rows.first?.relativeTime, "now")
        XCTAssertFalse(filtered.isEmpty)
        XCTAssertLessThan(elapsed, 2.0, "5000 history rows took \(elapsed) s to prepare")
    }

    // MARK: §48.2 Ban matrix

    func testBanMatrixChipsCarryIconTextAndTint() {
        for language in [AppLanguageSetting.en, .tr] {
            L10n.setting = language
            XCTAssertEqual(BanMatrixChip.cell(.banned), BanMatrixChip(symbol: "xmark.octagon.fill",
                                                                      text: L10n.text(.banMatrixCellBanned), tone: .red))
            XCTAssertEqual(BanMatrixChip.cell(.clear)?.tone, .green)
            XCTAssertEqual(BanMatrixChip.cell(.clear)?.text, L10n.text(.banMatrixCellClear))
            XCTAssertEqual(BanMatrixChip.cell(.unknown)?.tone, .neutral)
            XCTAssertEqual(BanMatrixChip.cell(.notApplicable)?.text, L10n.text(.banMatrixCellNotApplicable))
            XCTAssertNil(BanMatrixChip.cell(.none))
            XCTAssertEqual(BanMatrixChip.range("198.51.0.0/16")?.tone, .red)
            XCTAssertNil(BanMatrixChip.range(nil))
            XCTAssertEqual(BanMatrixChip.unverified.text, BanClassification.unverifiedText)
            for cell in BanMatrixCell.allCases {
                guard let chip = BanMatrixChip.cell(cell) else { continue }
                XCTAssertFalse(chip.text.isEmpty)
                XCTAssertNotNil(NSImage(systemSymbolName: chip.symbol, accessibilityDescription: nil), chip.symbol)
            }
        }
        L10n.setting = .en
        XCTAssertEqual(L10n.text(.banMatrixEmpty), "No servers yet.")
        L10n.setting = .tr
        XCTAssertEqual(L10n.text(.banMatrixEmpty), "Henüz sunucu yok.")
    }

    func testBanMatrixDropsLastCheckThenRangeOnNarrowTables() {
        let all = BanMatrixColumn.allCases
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: 828), all)                    // 860 pt window
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: BanMatrixLayout.requiredWidth(all)), all)
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: 688), [.server, .ipBan, .cidBan, .range])   // 720 pt
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: 488), [.server, .ipBan, .cidBan])           // 520 pt minimum
        XCTAssertEqual(BanMatrixLayout.columns(tableWidth: 100), [.server, .ipBan, .cidBan])
        XCTAssertLessThanOrEqual(BanMatrixLayout.requiredWidth([.server, .ipBan, .cidBan]),
                                 Metrics.BanMatrix.minWidth - 2 * Space.s4)
    }

    func testBanMatrixTooltipCarriesTheHiddenColumns() {
        L10n.setting = .en
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        let row = BanMatrixRow(serverID: UUID(), label: "Zombie TR", host: "2001:db8::1", port: 27015, ipBan: .banned,
                               cidBan: .unknown, range: "198.51.0.0/16", lastCheck: checked, unverified: false,
                               unreachable: false)
        XCTAssertEqual(BanMatrixChip.address(row), "[2001:db8::1]:27015")
        XCTAssertEqual(BanMatrixLayout.tooltip(row, columns: BanMatrixColumn.allCases), "Zombie TR\n[2001:db8::1]:27015")
        let narrow = BanMatrixLayout.tooltip(row, columns: [.server, .ipBan, .cidBan])
        XCTAssertTrue(narrow.contains("Range: 198.51.0.0/16"), narrow)
        XCTAssertTrue(narrow.contains("Last check: " + BanMatrixText.lastCheck(checked)), narrow)
    }

    // MARK: §48.3 Metrics

    func testOfflineRangesSpanFromTheFirstOfflineToTheNextOnlineSample() {
        func point(_ minutes: Double, _ online: Bool) -> MetricPoint {
            MetricPoint(ts: now.addingTimeInterval(minutes * 60), online: online, ping: online ? 40 : nil, players: 3)
        }
        let series = [point(-120, true), point(-90, false), point(-60, false), point(-30, true), point(-20, false)]
        XCTAssertEqual(MetricsChart.offlineRanges(series, now: now), [
            MetricsChart.OfflineRange(start: now.addingTimeInterval(-90 * 60), end: now.addingTimeInterval(-30 * 60)),
            MetricsChart.OfflineRange(start: now.addingTimeInterval(-20 * 60), end: now),
        ])
        XCTAssertEqual(MetricsChart.points(series, \.ping).map(\.segment), [0, 2])   // the line breaks at the outage
        // Every stored value stays in the series (offline samples with a player count included).
        XCTAssertEqual(MetricsChart.points(series, \.players).map(\.segment), [0, 1, 2, 2, 3])
        XCTAssertEqual(MetricsChart.offlineRanges([point(-10, true)], now: now), [])
        XCTAssertEqual(MetricsChart.offlineRanges([], now: now), [])
    }

    func testUptimeChipAndChartSummaryTexts() {
        L10n.setting = .en
        XCTAssertEqual(MetricsChart.uptimeChip(1).tone, .green)
        XCTAssertEqual(MetricsChart.uptimeChip(0.95).tone, .green)
        XCTAssertEqual(MetricsChart.uptimeChip(0.6).tone, .orange)
        XCTAssertEqual(MetricsChart.uptimeChip(0.2).tone, .red)
        XCTAssertEqual(MetricsChart.uptimeChip(0.5).text, "Uptime, last 24 hours: 50%")
        XCTAssertEqual(MetricsChart.summary([40, 12, 77]), "3 points, lowest 12, highest 77")
        XCTAssertEqual(MetricsChart.summary([]), "No data in the last 24 hours.")
        XCTAssertEqual(L10n.text(.metricsOffline), "Offline")
        L10n.setting = .tr
        XCTAssertEqual(MetricsChart.summary([5]), "1 nokta, en düşük 5, en yüksek 5")
        XCTAssertEqual(L10n.text(.metricsNoData), "Son 24 saatte veri yok.")
        XCTAssertEqual(L10n.text(.metricsOffline), "Çevrimdışı")
    }

    // MARK: Tokens

    func testChipTonesUseStatusTokens() {
        XCTAssertEqual(ChipTone.red.textColor, Palette.redText)
        XCTAssertEqual(ChipTone.red.tint, Palette.redTint)
        XCTAssertEqual(ChipTone.green.iconColor, Palette.green)
        XCTAssertEqual(ChipTone.orange.tint, Palette.orangeTint)
        XCTAssertEqual(ChipTone.accent.textColor, Palette.accentText)
        XCTAssertEqual(ChipTone.neutral.tint, Palette.group)
        XCTAssertEqual(ChipTone(StatusLevel.orange), .orange)
        XCTAssertEqual(MetricsChart.pingColor, Palette.accent)
    }

    /// §48.4: the three redesigned view files use `Theme` only — no system colours, no raw sizes or system fonts.
    func testRedesignedViewFilesContainNoHardcodedColorsOrSizes() throws {
        let resources = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let views = resources.appendingPathComponent("App/Views", isDirectory: true)
        var violations: [String] = []
        for name in ["HistoryView.swift", "BanMatrixView.swift", "MetricsViews.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(name), encoding: .utf8)
            violations += ThemeScanner.violations(in: source).map { "\(name):\($0)" }
        }
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testThemeScannerDetectsHardcodedValues() {
        let sample = """
        Text("a").foregroundStyle(.secondary)
        Color.red
        Color(red: 0.1, green: 0.2, blue: 0.3)
        .padding(12)
        .padding(.horizontal, 8)
        .frame(width: 150, alignment: .leading)
        VStack(spacing: 6) {}
        .font(.caption)
        .font(.system(size: 12))
        .strokeBorder(Palette.border, lineWidth: 1)
        .opacity(0.35)
        // .padding(20) in a comment is fine
        VStack(spacing: 0) {}
        .padding(Space.s4)
        .frame(width: Metrics.History.timeColumn)
        .foregroundStyle(Palette.text2)
        """
        XCTAssertEqual(ThemeScanner.violations(in: sample).count, 12, ThemeScanner.violations(in: sample).joined(separator: "\n"))
    }
}

/// Finds hardcoded colours, fonts and sizes in view source (§48.4). `0` is allowed (no spacing / no inset).
enum ThemeScanner {
    private static let patterns: [(String, NSRegularExpression)] = [
        ("system colour", #"\bColor\.(red|green|blue|orange|purple|yellow|pink|gray|grey|secondary|primary|black|white|accentColor)\b"#),
        ("shorthand colour", #"(foregroundStyle|foregroundColor|fill|background|tint|stroke|strokeBorder)\(\s*\.(red|green|blue|orange|purple|yellow|pink|gray|secondary|tertiary|primary|black|white)\b"#),
        ("colour literal", #"Color\(\s*(red|white|hue|\.sRGB|#)|#colorLiteral|NSColor\.(system|label|secondary)"#),
        ("system font", #"\.font\(\s*\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|caption|caption2|footnote|system)\b"#),
        ("raw size", #"\b(spacing|width|height|minWidth|minHeight|maxWidth|maxHeight|idealWidth|idealHeight|size|lineWidth|cornerRadius|radius)\s*:\s*[1-9]"#),
        ("raw padding", #"\.padding\(\s*(\.[a-zA-Z]+\s*,\s*)?[1-9]"#),
        ("raw opacity", #"\.opacity\(\s*0?\.\d"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    static func violations(in source: String) -> [String] {
        source.components(separatedBy: "\n").enumerated().flatMap { index, line -> [String] in
            let code = line.components(separatedBy: "//").first ?? line
            return patterns.compactMap { name, regex in
                regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) == nil
                    ? nil : "\(index + 1) \(name): \(line.trimmingCharacters(in: .whitespaces))"
            }
        }
    }
}

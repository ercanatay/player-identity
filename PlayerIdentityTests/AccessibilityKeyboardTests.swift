import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// §55 accessibility and keyboard: key map (pure model), VoiceOver label coverage of every chip / switch / status,
/// contrast of the tokens in every appearance (including high contrast), minimum hit targets.
@MainActor
final class AccessibilityKeyboardTests: XCTestCase {
    override func tearDown() async throws {
        L10n.setting = .system
    }

    private func inLanguages(_ body: (String) throws -> Void) throws {
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) { try body(language) }
        }
    }

    // MARK: Keyboard map

    func testEveryKeyHasAnActionAndEveryActionAKey() {
        for key in MainWindowKey.allCases {
            XCTAssertNotNil(MainWindowKeyboard.action(for: key), "\(key)")
        }
        XCTAssertEqual(Set(MainWindowKeyboard.bindings.values.map { "\($0)" }),
                       Set(MainWindowKeyAction.allCases.map { "\($0)" }))
        XCTAssertEqual(MainWindowKeyboard.action(for: .find), .focusSearch)
        XCTAssertEqual(MainWindowKeyboard.action(for: .upArrow), .selectPrevious)
        XCTAssertEqual(MainWindowKeyboard.action(for: .downArrow), .selectNext)
        XCTAssertEqual(MainWindowKeyboard.action(for: .home), .selectFirst)
        XCTAssertEqual(MainWindowKeyboard.action(for: .end), .selectLast)
        XCTAssertEqual(MainWindowKeyboard.action(for: .returnKey), .openSelected)
        XCTAssertEqual(MainWindowKeyboard.action(for: .escape), .clearSelection)
    }

    func testArrowSelectionMovesAndClamps() {
        let a = UUID(), b = UUID(), c = UUID()
        let rows = [a, b, c]
        func press(_ key: MainWindowKey, _ selection: UUID?) -> ServerTableKeyOutcome {
            MainWindowKeyboard.handle(key, selection: selection, rows: rows)
        }
        XCTAssertEqual(press(.downArrow, nil), .select(a))      // nothing selected: ↓ starts at the top
        XCTAssertEqual(press(.downArrow, a), .select(b))
        XCTAssertEqual(press(.downArrow, c), .select(c))        // clamps at the end
        XCTAssertEqual(press(.upArrow, nil), .select(c))        // ↑ starts at the bottom
        XCTAssertEqual(press(.upArrow, b), .select(a))
        XCTAssertEqual(press(.upArrow, a), .select(a))          // clamps at the top
        XCTAssertEqual(press(.home, c), .select(a))
        XCTAssertEqual(press(.end, a), .select(c))
        XCTAssertEqual(press(.returnKey, b), .open(b))
        XCTAssertEqual(press(.returnKey, nil), .ignored)
        XCTAssertEqual(press(.escape, b), .clearSelection)
        XCTAssertEqual(press(.escape, nil), .ignored)           // Esc goes on (e.g. closes a sheet)
        XCTAssertEqual(press(.find, b), .focusSearch)

        // A selection that is filtered out / in a collapsed group counts as none.
        let hidden = UUID()
        XCTAssertEqual(press(.downArrow, hidden), .select(a))
        XCTAssertEqual(press(.returnKey, hidden), .ignored)
        XCTAssertEqual(press(.escape, hidden), .ignored)

        // Empty table: only ⌘F does something.
        for key in MainWindowKey.allCases {
            let outcome = MainWindowKeyboard.handle(key, selection: nil, rows: [])
            XCTAssertEqual(outcome, key == .find ? .focusSearch : .ignored, "\(key)")
        }
    }

    // MARK: VoiceOver labels

    func testFilterChipsAndRowSwitchesHaveLabelAndStateValue() throws {
        try inLanguages { language in
            let on = AccessibilityText.onOff(true), off = AccessibilityText.onOff(false)
            XCTAssertNotEqual(on, off)
            var labels = Set<String>()
            for kind in ServerFilterChipKind.allCases {
                let chipOn = AccessibilityText.filterChip(kind, count: 3, isOn: true)
                let chipOff = AccessibilityText.filterChip(kind, count: 3, isOn: false)
                XCTAssertFalse(chipOn.label.isEmpty, "\(language) \(kind)")
                XCTAssertEqual(chipOn.label, chipOff.label)
                XCTAssertTrue(chipOn.value.contains("3") && chipOn.value.contains(on), chipOn.value)
                XCTAssertTrue(chipOff.value.contains(off), chipOff.value)
                labels.insert(chipOn.label)
            }
            XCTAssertEqual(labels.count, ServerFilterChipKind.allCases.count, "\(language): chip labels are distinct")
            for mark in ServerRowMark.allCases {
                let markOn = AccessibilityText.mark(mark, isOn: true)
                let markOff = AccessibilityText.mark(mark, isOn: false)
                XCTAssertFalse(markOn.label.isEmpty)
                XCTAssertNotEqual(markOn.label, markOff.label, "\(language) \(mark): the label names the action")
                XCTAssertTrue(markOn.value.hasSuffix(on), markOn.value)
                XCTAssertTrue(markOff.value.hasSuffix(off), markOff.value)
            }
        }
        L10n.setting = .tr
        XCTAssertEqual(AccessibilityText.filterChip(.banned, count: 2, isOn: true).value, "2 sunucu, Açık")
        XCTAssertEqual(AccessibilityText.mark(.watch, isOn: false).value, "İzleniyor: Kapalı")
        L10n.setting = .en
        XCTAssertEqual(AccessibilityText.filterChip(.watched, count: 1, isOn: false),
                       AccessibilityElementText(label: "Watched", value: "1 servers, Off"))
    }

    func testEveryBanStatusAndCellStateIsSpokenAsText() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try inLanguages { language in
            var cells = BanStatus.allCases.map { status in
                BanCellContent.make(check: BanCheck(status: status, checkedAt: checkedAt, detail: ""), status: nil,
                                    host: "192.0.2.10", isChecking: false, checksEnabled: true)
            }
            cells.append(BanCellContent.make(check: nil, status: nil, host: "h", isChecking: false, checksEnabled: true))
            cells.append(BanCellContent.make(check: nil, status: nil, host: "h", isChecking: true, checksEnabled: true))
            cells.append(BanCellContent.make(check: nil, status: nil, host: "h", isChecking: false, checksEnabled: false))
            for cell in cells {
                let text = AccessibilityText.ban(cell)
                XCTAssertFalse(cell.title.isEmpty, "\(language) \(cell)")
                XCTAssertTrue(text.label.contains(cell.title), "\(language): \(text.label)")
            }
            for level in StatusLevel.allCases {
                let text = AccessibilityText.status(level)
                XCTAssertFalse(text.label.isEmpty)
                XCTAssertEqual(text.value, level.label)
            }
            XCTAssertEqual(Set(StatusLevel.allCases.map(\.label)).count, StatusLevel.allCases.count)
            for status in AppealStatus.allCases {
                XCTAssertFalse(AccessibilityText.appeal(status).value.isEmpty, "\(language) \(status)")
            }
            XCTAssertEqual(Set(AppealStatus.allCases.map { AccessibilityText.appeal($0).value }).count,
                           AppealStatus.allCases.count)
        }
    }

    func testNotificationPickerEntriesAndRowValue() throws {
        try inLanguages { language in
            let modes = ServerNotificationMode.allCases.map(AccessibilityText.notificationMode)
            XCTAssertEqual(Set(modes).count, modes.count, "\(language): \(modes)")
            XCTAssertFalse(modes.contains(where: \.isEmpty))
            let quiet = QuietHoursOverride.allCases.map(AccessibilityText.quietOverride)
            XCTAssertEqual(Set(quiet).count, quiet.count, "\(language): \(quiet)")
            XCTAssertNil(AccessibilityText.serverNotifications(nil))
            XCTAssertNil(AccessibilityText.serverNotifications(ServerNotificationSettings()))
            let value = try XCTUnwrap(AccessibilityText.serverNotifications(ServerNotificationSettings(mode: .off)))
            XCTAssertTrue(value.contains(AccessibilityText.notificationMode(.off)), value)
        }
    }

    // MARK: Contrast

    func testContrastRatioMath() {
        let black = Palette.RGBA.hex(0x000000), white = Palette.RGBA.hex(0xFFFFFF)
        XCTAssertEqual(ContrastRatio.ratio(black, on: white), 21, accuracy: 0.001)
        XCTAssertEqual(ContrastRatio.ratio(white, on: black), 21, accuracy: 0.001)
        XCTAssertEqual(ContrastRatio.ratio(white, on: white), 1, accuracy: 0.001)
        XCTAssertEqual(ContrastRatio.ratio(.hex(0x777777), on: white), 4.48, accuracy: 0.01)   // the classic AA miss
        XCTAssertEqual(ContrastRatio.ratio(.hex(0x767676), on: white), 4.54, accuracy: 0.01)   // the classic AA pass
        XCTAssertEqual(ContrastRatio.luminance(white), 1, accuracy: 0.0001)
        // A translucent foreground is composited on the background first.
        XCTAssertEqual(ContrastRatio.ratio(.rgba(0x000000, 0), on: white), 1, accuracy: 0.001)
        XCTAssertEqual(ContrastRatio.composite(.rgba(0x000000, 0.5), over: white).red, 0.5, accuracy: 0.001)
    }

    private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                          .accessibilityHighContrastDarkAqua]
    private static let textTokens: [(String, Color)] = [
        ("text", Palette.text), ("text2", Palette.text2), ("text3", Palette.text3), ("accentText", Palette.accentText),
        ("greenText", Palette.greenText), ("orangeText", Palette.orangeText), ("redText", Palette.redText),
    ]
    private static let surfaces: [(String, Color)] = [
        ("window", Palette.window), ("card", Palette.card), ("field", Palette.field), ("inset", Palette.inset),
        ("group", Palette.group), ("toolbar", Palette.toolbar), ("raised", Palette.raised),
    ]

    func testTextTokensMeetAAOnEverySurfaceInEveryAppearance() throws {
        for name in Self.appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name), "\(name)")
            for (surfaceName, surface) in Self.surfaces {
                let background = try XCTUnwrap(Palette.resolved(surface, in: appearance))
                for (textName, token) in Self.textTokens {
                    let foreground = try XCTUnwrap(Palette.resolved(token, in: appearance))
                    let ratio = ContrastRatio.ratio(foreground, on: background)
                    XCTAssertGreaterThanOrEqual(ratio, ContrastRatio.textMinimum,
                                                "\(name.rawValue): \(textName) on \(surfaceName) = \(ratio)")
                }
                // The focus ring and the selected-row bar are visible (WCAG non-text 3 : 1).
                let ring = try XCTUnwrap(Palette.resolved(FocusRing.color, in: appearance))
                XCTAssertGreaterThanOrEqual(ContrastRatio.ratio(ring, on: background), ContrastRatio.nonTextMinimum,
                                            "\(name.rawValue): focus ring on \(surfaceName)")
            }
            let onAccent = try XCTUnwrap(Palette.resolved(Palette.onAccent, in: appearance))
            let accentFill = try XCTUnwrap(Palette.resolved(Palette.accentFill, in: appearance))
            XCTAssertGreaterThanOrEqual(ContrastRatio.ratio(onAccent, on: accentFill), ContrastRatio.textMinimum,
                                        "\(name.rawValue): prominent button text")
        }
    }

    func testHighContrastAppearancesKeepTheTokens() throws {
        let pairs: [(NSAppearance.Name, NSAppearance.Name)] = [(.accessibilityHighContrastAqua, .aqua),
                                                               (.accessibilityHighContrastDarkAqua, .darkAqua)]
        for (highContrast, base) in pairs {
            let high = try XCTUnwrap(NSAppearance(named: highContrast))
            let normal = try XCTUnwrap(NSAppearance(named: base))
            XCTAssertEqual(Palette.isDark(high), Palette.isDark(normal), "\(highContrast.rawValue)")
            for (tokenName, token) in Self.textTokens + Self.surfaces + [("border", Palette.border), ("focus", Palette.focus)] {
                let a = try XCTUnwrap(Palette.resolved(token, in: high))
                let b = try XCTUnwrap(Palette.resolved(token, in: normal))
                XCTAssertEqual([a.red, a.green, a.blue, a.alpha], [b.red, b.green, b.blue, b.alpha],
                               "\(highContrast.rawValue): \(tokenName)")
            }
        }
        // Light and dark really differ (the resolution follows the appearance).
        let light = try XCTUnwrap(Palette.resolved(Palette.text, in: XCTUnwrap(NSAppearance(named: .aqua))))
        let dark = try XCTUnwrap(Palette.resolved(Palette.text, in: XCTUnwrap(NSAppearance(named: .darkAqua))))
        XCTAssertNotEqual(light.red, dark.red)
    }

    // MARK: Targets

    func testMinimumHitTargets() {
        XCTAssertEqual(Metrics.minTarget, 24)
        let targets: [(String, CGFloat)] = [
            ("control", Metrics.control), ("markButton", Metrics.markButton), ("rowMenu", Metrics.Column.menu),
            ("toolbarButton", Metrics.toolbarButton.height), ("groupHeader", Metrics.groupHeader),
            ("row", Metrics.row), ("iconButton.width", IconButton(symbol: "x", label: "x", action: {}).size.width),
            ("iconButton.height", IconButton(symbol: "x", label: "x", action: {}).size.height),
        ]
        for (name, value) in targets {
            XCTAssertGreaterThanOrEqual(value, Metrics.minTarget, name)
        }
        XCTAssertGreaterThanOrEqual(Metrics.Column.marks, 2 * Metrics.markButton, "★ and 🔔 fit side by side")
        XCTAssertGreaterThanOrEqual(FocusRing.lineWidth, 2)
    }

    // MARK: ⌘F in a real window

    func testCommandFFocusesTheSearchField() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "S", host: "192.0.2.10"))
        let size = CGSize(width: 900, height: 700)
        let hosting = NSHostingView(rootView: ServersCard(model: model, presenter: MainWindowPresenter())
            .frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = FocusTestWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        window.makeKey()
        defer { window.orderOut(nil) }
        pump(hosting)
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder is NSText)

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "f",
                                                   charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "⌘F is handled by the window")
        pump(hosting)
        // The field editor of the search field is the first responder.
        XCTAssertTrue(window.firstResponder is NSText, "first responder: \(String(describing: window.firstResponder))")
    }

    private func pump(_ view: NSView) {
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }
}

private final class FocusTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

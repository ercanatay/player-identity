import AppKit
import SwiftUI
import XCTest
@testable import PlayerIdentity

/// Layout guards for localization: RTL mirroring for `ar`/`fa` and the width of button / short-label texts in all
/// 26 languages (a label wider than the limit would truncate in a toolbar button, menu or diagnosis chip).
@MainActor
final class LocalizationLayoutTests: XCTestCase {
    override func tearDown() async throws {
        L10n.setting = .system
    }

    // MARK: RTL

    func testIsRightToLeftForAll26Languages() {
        XCTAssertEqual(AppLanguage.allCases.count, 26)
        for language in AppLanguage.allCases {
            XCTAssertEqual(language.isRightToLeft, language == .ar || language == .fa, language.rawValue)
        }
    }

    private struct DirectionProbe: View {
        let onRead: (LayoutDirection) -> Void
        @Environment(\.layoutDirection) private var direction
        var body: some View {
            Color.clear.onAppear { onRead(direction) }
        }
    }

    private func rootDirection(_ setting: AppLanguageSetting) -> LayoutDirection? {
        var result: LayoutDirection?
        let view = DirectionProbe { result = $0 }
            .appLayoutDirection(setting, preferredLanguages: ["en-US"])
            .frame(width: 10, height: 10)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return result
    }

    func testRootLayoutDirectionFollowsAppLanguage() {
        XCTAssertEqual(rootDirection(.ar), .rightToLeft)
        XCTAssertEqual(rootDirection(.fa), .rightToLeft)
        XCTAssertEqual(rootDirection(.en), .leftToRight)
        XCTAssertEqual(rootDirection(.de), .leftToRight)
    }

    // MARK: Label widths

    /// Widest accepted button / short label at 13 pt system font.
    static let maxLabelWidth: CGFloat = 190

    private static func isShortLabelKey(_ key: String) -> Bool {
        // `menuBar.copyFailed` is a disabled, sentence-length status line in an auto-sizing menu, not a button label.
        (key.hasPrefix("action.") || key.hasPrefix("menuBar.") || key == "diagnose.action"
            || key.hasPrefix("diagnose.short.")) && key != "menuBar.copyFailed"
    }

    func testButtonAndShortLabelsStayWithinWidthLimit() throws {
        let font = NSFont.systemFont(ofSize: 13)
        var measured: [(language: String, key: String, width: CGFloat)] = []
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(L10n.languageBundle(language.rawValue), language.rawValue)
            for key in L10nKey.allCases.map(\.rawValue) where Self.isShortLabelKey(key) {
                let text = bundle.localizedString(forKey: key, value: nil, table: nil)
                // Longest line: multi-line values wrap at the line break.
                let width = text.split(separator: "\n").map {
                    ceil(($0 as NSString as String as NSString).size(withAttributes: [.font: font]).width)
                }.max() ?? 0
                measured.append((language.rawValue, key, width))
            }
        }
        XCTAssertGreaterThan(measured.count, 26 * 10)
        let top = measured.sorted { $0.width > $1.width }.prefix(5)
        print("LABEL-WIDTH top5: " + top.map { "\($0.language) \($0.key) \(Int($0.width))pt" }.joined(separator: " | "))
        let tooWide = measured.filter { $0.width > Self.maxLabelWidth }
        XCTAssertTrue(tooWide.isEmpty, "Labels wider than \(Self.maxLabelWidth) pt: "
            + tooWide.map { "\($0.language) \($0.key) \(Int($0.width))pt" }.joined(separator: ", "))
    }
}

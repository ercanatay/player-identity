import XCTest
@testable import PlayerIdentity

/// Width fallbacks of the toolbar status group: widest first, each step drops the least important parts.
final class ToolbarStatusLayoutTests: XCTestCase {
    func testOrderIsWidestFirst() {
        XCTAssertEqual(ToolbarStatusLayout.allCases, [.full, .titled, .compact, .narrow])
    }

    func testFullShowsEverything() {
        let l = ToolbarStatusLayout.full
        XCTAssertTrue(l.showsTitle && l.showsDetail && l.showsLastCheck && l.showsBadge)
    }

    func testTitledDropsOnlyDetail() {
        let l = ToolbarStatusLayout.titled
        XCTAssertTrue(l.showsTitle && l.showsLastCheck && l.showsBadge)
        XCTAssertFalse(l.showsDetail)
    }

    func testCompactDropsTitleAndDetailButKeepsLastCheck() {
        let l = ToolbarStatusLayout.compact
        XCTAssertFalse(l.showsTitle)
        XCTAssertFalse(l.showsDetail)
        XCTAssertTrue(l.showsLastCheck)
    }

    func testNarrowKeepsOnlyIconAndLabel() {
        let l = ToolbarStatusLayout.narrow
        XCTAssertFalse(l.showsTitle || l.showsDetail || l.showsLastCheck || l.showsBadge)
    }

    func testTitleWidthIsCapped() {
        XCTAssertEqual(ToolbarStatusLayout.titleMaxWidth, 180)
    }
}

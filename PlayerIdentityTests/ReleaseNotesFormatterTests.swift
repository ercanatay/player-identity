import XCTest
@testable import PlayerIdentity

final class ReleaseNotesFormatterTests: XCTestCase {
    private func plain(_ s: String) -> String { String(ReleaseNotesFormatter.attributed(s).characters) }

    func testHeadingHasIntentAndNoHashes() throws {
        let out = ReleaseNotesFormatter.attributed("## PlayerIdentity 2.2.1\ntext")
        XCTAssertEqual(String(out.characters), "PlayerIdentity 2.2.1\ntext")
        let run = try XCTUnwrap(out.runs.first)
        XCTAssertNotNil(run.presentationIntent)
        XCTAssertTrue(plain("### SHA-256").hasPrefix("SHA-256"))
    }

    func testBold() throws {
        let out = ReleaseNotesFormatter.attributed("**Signing:** ok")
        XCTAssertEqual(String(out.characters), "Signing: ok")
        XCTAssertEqual(out.runs.first?.inlinePresentationIntent, .stronglyEmphasized)
    }

    func testInlineCode() throws {
        let out = ReleaseNotesFormatter.attributed("run `make` now")
        XCTAssertEqual(String(out.characters), "run make now")
        XCTAssertTrue(out.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testFencedBlock() throws {
        let out = ReleaseNotesFormatter.attributed("before\n```\nshasum -a 256 x\n```\nafter")
        XCTAssertEqual(String(out.characters), "before\nshasum -a 256 x\nafter")
        XCTAssertTrue(out.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testBulletsAndBlankCollapse() {
        XCTAssertEqual(plain("- one\n- two\n\n\n\nend\n\n"), "• one\n• two\n\nend")
    }

    func testLink() throws {
        let out = ReleaseNotesFormatter.attributed("see [notes](https://example.com/a)")
        XCTAssertEqual(String(out.characters), "see notes")
        XCTAssertEqual(out.runs.compactMap(\.link).first, URL(string: "https://example.com/a"))
    }

    func testEmptyBody() {
        XCTAssertEqual(plain(""), "")
        XCTAssertEqual(plain("\n \n"), "")
    }

    func testTruncationAtLineBoundary() {
        let body = (0..<2000).map { "line \($0)" }.joined(separator: "\n")
        let out = ReleaseNotesFormatter.truncated(body)
        XCTAssertLessThanOrEqual(out.count, 4000)
        XCTAssertTrue(out.hasSuffix("\n…"))
        let lastLine = out.components(separatedBy: "\n").dropLast().last ?? ""
        XCTAssertTrue(body.components(separatedBy: "\n").contains(lastLine))
        XCTAssertEqual(ReleaseNotesFormatter.truncated(String(repeating: "x", count: 5000)).count, 4000)
    }

    func testMalformedMarkdownDoesNotCrash() {
        let text = plain("**unclosed `code [link](\n```\nopen fence")
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("open fence"))
    }
}

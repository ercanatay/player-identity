import XCTest
@testable import PlayerIdentity

/// §24: diff before Apply — LF/CRLF, multiple occurrences, appended key, no change, cancel, confirm.
final class ConfigDiffTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testLFChangedLine() {
        let old = bytes("bind \"a\"\nname \"Eski\"\nmodel \"gordon\"\n")
        let new = ConfigEditor.set("name", to: "Yeni", in: old)
        XCTAssertEqual(ConfigDiff.lines(old: old, new: new),
                       [ConfigDiffLine(kind: .removed, number: 2, text: "name \"Eski\""),
                        ConfigDiffLine(kind: .added, number: 2, text: "name \"Yeni\"")])
    }

    func testCRLFLinesHaveNoCarriageReturn() {
        let old = bytes("name \"A\"\r\nmodel \"gordon\"\r\n")
        let new = ConfigEditor.set("model", to: "gina", in: old)
        XCTAssertEqual(ConfigDiff.lines(old: old, new: new),
                       [ConfigDiffLine(kind: .removed, number: 2, text: "model \"gordon\""),
                        ConfigDiffLine(kind: .added, number: 2, text: "model \"gina\"")])
    }

    func testMultipleOccurrences() {
        let old = bytes("name \"A\"\nx\nname \"B\"\n")
        let new = ConfigEditor.set("name", to: "C", in: old)
        XCTAssertEqual(ConfigDiff.lines(old: old, new: new).map(\.number), [1, 1, 3, 3])
        XCTAssertEqual(ConfigDiff.lines(old: old, new: new).filter { $0.kind == .added }.map(\.text),
                       ["name \"C\"", "name \"C\""])
    }

    func testAppendedKeyWithoutFinalNewline() {
        let old = bytes("bind \"a\"\nmodel \"gordon\"")
        let new = ConfigEditor.append("name", value: "Yeni", to: old)
        // The missing final newline added before the append is a line-ending change only: not shown.
        XCTAssertEqual(ConfigDiff.lines(old: old, new: new), [ConfigDiffLine(kind: .added, number: 3, text: "name \"Yeni\"")])
    }

    func testNoChangeHasNoLines() {
        let old = bytes("name \"A\"\n")
        XCTAssertEqual(ConfigDiff.lines(old: old, new: old), [])
    }

    func testWriterPreviewWritesNothingAndListsFilesInOrder() throws {
        let temp = try TempDirectory()
        let dir = try temp.makeDirectory("valve")
        try temp.write("valve/config.cfg", "name \"A\"\nmodel \"gordon\"\n")
        try temp.write("valve/userconfig.cfg", "name \"A\"\n")
        let configBefore = try Data(contentsOf: dir.appendingPathComponent("config.cfg"))
        let writer = PlayerConfigWriter(detector: FakeGameDetector())
        let plan = try writer.preview(gamedir: dir, name: "B", model: nil)
        XCTAssertEqual(plan.diffs.map(\.file), [.config, .userconfig])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("config.cfg")), configBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.cfg.appbak").path))
        XCTAssertEqual(try writer.preview(gamedir: dir, name: "A", model: "gordon").diffs, [])
        XCTAssertThrowsError(try writer.preview(gamedir: dir, name: "bad\"", model: nil)) { error in
            XCTAssertEqual(error as? EditMessage, .nameInvalid)
        }
    }
}

@MainActor
final class AppModelApplyPreviewTests: XCTestCase {
    func testPreviewCancelAndConfirm() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        await model.refresh().value
        let configURL = env.valveDir.appendingPathComponent("config.cfg")
        let before = try Data(contentsOf: configURL)

        XCTAssertFalse(model.canApply)
        XCTAssertNil(model.requestApply())   // no change → Apply disabled, no sheet
        XCTAssertNil(model.applyPreview)

        model.modelDraft = "gina"
        await model.requestApply()?.value
        let preview = try XCTUnwrap(model.applyPreview)
        XCTAssertEqual(preview.diffs.map(\.file), [.config])
        XCTAssertEqual(preview.diffs.first?.lines.map(\.text), ["model \"gordon\"", "model \"gina\""])
        XCTAssertEqual(try Data(contentsOf: configURL), before)   // nothing written yet

        model.cancelApply()
        XCTAssertNil(model.applyPreview)
        XCTAssertEqual(try Data(contentsOf: configURL), before)
        XCTAssertNil(model.applyStatus)
        XCTAssertNil(model.confirmApply())                          // no open preview → no write

        await model.requestApply()?.value
        await model.confirmApply()?.value
        XCTAssertNil(model.applyPreview)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "name \"N\"\nmodel \"gina\"\n")
        guard case .success? = model.applyStatus else { return XCTFail("\(String(describing: model.applyStatus))") }
    }

    func testPreviewValidationErrorOpensNoSheet() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        await model.refresh().value
        try FileManager.default.removeItem(at: env.valveDir.appendingPathComponent("config.cfg"))
        model.modelDraft = "gina"
        await model.requestApply()?.value
        XCTAssertNil(model.applyPreview)
        XCTAssertEqual(model.applyStatus, .failure(.configMissing))
    }
}

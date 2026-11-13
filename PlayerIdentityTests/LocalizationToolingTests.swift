import XCTest
@testable import PlayerIdentity

/// §63: the 24-language l10n tool chain (`tools/l10n_keys.py` + `tools/l10n/<lang>.json`), run on a temporary copy
/// of the tools taken from the test bundle (never the repository itself).
final class LocalizationToolingTests: XCTestCase {
    private static let codes = ["tr", "en", "de", "fr", "es", "it", "pt", "nl", "sv", "pl", "cs", "ro", "hu", "el", "bg",
                                "uk", "ru", "ar", "fa", "hi", "zh-Hans", "ja", "ko", "id"]
    private static let jsonCodes = Array(codes.dropFirst(2))
    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#)

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundled = try XCTUnwrap(Bundle(for: LocalizationToolingTests.self).resourceURL)
            .appendingPathComponent("tools")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-tooling-\(UUID().uuidString)", isDirectory: true)
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundled.appendingPathComponent("l10n_keys.py"),
                                         to: tools.appendingPathComponent("l10n_keys.py"))
        try FileManager.default.copyItem(at: bundled.appendingPathComponent("l10n"), to: tools.appendingPathComponent("l10n"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    @discardableResult
    private func tool(_ arguments: [String] = []) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("tools/l10n_keys.py").path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func stringsURL(_ language: String) -> URL {
        root.appendingPathComponent("PlayerIdentity/Resources/\(language).lproj/Localizable.strings")
    }

    private func generated(_ language: String) throws -> [String: String] {
        try XCTUnwrap(NSDictionary(contentsOf: stringsURL(language)) as? [String: String], language)
    }

    private func shipped(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                                                localization: language), language)
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
    }

    private func jsonURL(_ language: String) -> URL {
        root.appendingPathComponent("tools/l10n/\(language).json")
    }

    private func editJSON(_ language: String, _ change: (inout [String: String]) -> Void) throws {
        let data = try Data(contentsOf: jsonURL(language))
        var table = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        change(&table)
        try JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys])
            .write(to: jsonURL(language))
    }

    private func specifiers(_ text: String) -> [String] {
        Self.specifier.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .filter { $0 != "%" }
            .sorted()
    }

    // MARK: (a) Migration

    func testGenerationKeepsEveryShippedValueInAllLanguages() throws {
        let result = try tool()
        XCTAssertEqual(result.status, 0, result.output)
        for language in Self.codes {
            let values = try generated(language)
            XCTAssertEqual(values.count, L10nKey.allCases.count, language)
            XCTAssertEqual(values, try shipped(language), "\(language): generated values differ from the shipped table")
        }
    }

    // MARK: (b) Determinism

    func testTwoGenerationsAreByteIdentical() throws {
        let files = Self.codes.map(stringsURL) + [root.appendingPathComponent("PlayerIdentity/Core/L10nKey.swift")]
        XCTAssertEqual(try tool().status, 0)
        let first = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(try tool().status, 0)
        let second = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(first, second)
        let header = try String(contentsOf: stringsURL("de"), encoding: .utf8)
        XCTAssertTrue(header.hasPrefix("/* Generated by tools/l10n_keys.py — do not edit by hand. */\n\n\"app.windowTitle\" = "))
        XCTAssertTrue(header.hasSuffix("\";\n"))
    }

    // MARK: (c) --check

    func testCheckPassesWhenCleanAndFailsOnMissingKey() throws {
        XCTAssertEqual(try tool().status, 0)
        let clean = try tool(["--check"])
        XCTAssertEqual(clean.status, 0, clean.output)
        XCTAssertEqual(clean.output.trimmingCharacters(in: .whitespacesAndNewlines), "OK")

        let before = try Data(contentsOf: stringsURL("de"))
        try editJSON("de") { $0.removeValue(forKey: "action.save") }
        try editJSON("ja") { $0["action.refresh"] = "  " }
        let broken = try tool(["--check"])
        XCTAssertEqual(broken.status, 1, broken.output)
        XCTAssertTrue(broken.output.contains("de: action.save"), broken.output)
        XCTAssertTrue(broken.output.contains("ja: action.refresh"), broken.output)
        XCTAssertEqual(try Data(contentsOf: stringsURL("de")), before, "--check must not write")
    }

    func testCheckReportsStaleOutputs() throws {
        XCTAssertEqual(try tool().status, 0)
        try "/* stale */\n".write(to: stringsURL("ko"), atomically: true, encoding: .utf8)
        let result = try tool(["--check"])
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("ko.lproj/Localizable.strings"), result.output)
    }

    // MARK: (d) --add

    func testAddWritesTheKeyEverywhereWithEnglishPlaceholders() throws {
        let result = try tool(["--add", "tooling.sample.title", "--en", "Sample title", "--tr", "Örnek başlık"])
        XCTAssertEqual(result.status, 0, result.output)
        for language in Self.jsonCodes {
            XCTAssertTrue(result.output.contains("translation needed: \(language)\n"), language)
            XCTAssertEqual(try generated(language)["tooling.sample.title"], "Sample title", language)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL(language))) as? [String: String])
            XCTAssertEqual(json["tooling.sample.title"], "Sample title", language)
        }
        XCTAssertEqual(try generated("tr")["tooling.sample.title"], "Örnek başlık")
        XCTAssertEqual(try generated("en")["tooling.sample.title"], "Sample title")
        let swift = try String(contentsOf: root.appendingPathComponent("PlayerIdentity/Core/L10nKey.swift"), encoding: .utf8)
        XCTAssertTrue(swift.contains(#"    case toolingSampleTitle = "tooling.sample.title""#))
        let source = try String(contentsOf: root.appendingPathComponent("tools/l10n_keys.py"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"("toolingSampleTitle", "tooling.sample.title", "Örnek başlık", "Sample title"),"#))

        // The source survives a fresh run: still clean, and the same key can't be added twice.
        XCTAssertEqual(try tool(["--check"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        let duplicate = try tool(["--add", "tooling.sample.title", "--en", "Again", "--tr", "Yine"])
        XCTAssertNotEqual(duplicate.status, 0)
        XCTAssertTrue(duplicate.output.contains("already exists"), duplicate.output)
    }

    // MARK: (e) Format specifiers

    func testFormatSpecifiersArePreserved() throws {
        let english = "%1$@ has %2$d of %3$@ (100%%)"
        let result = try tool(["--add", "tooling.sample.count", "--en", english, "--tr", "%1$@: %3$@ içinde %2$d (%%100)"])
        XCTAssertEqual(result.status, 0, result.output)
        let reference = try generated("en")
        for language in Self.codes {
            let values = try generated(language)
            for (key, value) in values {
                XCTAssertEqual(specifiers(value), specifiers(try XCTUnwrap(reference[key])), "\(language): \(key)")
            }
        }
        XCTAssertEqual(try generated("fr")["tooling.sample.count"], english)
        XCTAssertEqual(try generated("de")["topbar.lastCheck"], try shipped("de")["topbar.lastCheck"])

        try editJSON("ru") { $0["topbar.lastCheck"] = "Последняя проверка" }
        let broken = try tool(["--check"])
        XCTAssertEqual(broken.status, 1, broken.output)
        XCTAssertTrue(broken.output.contains("ru: topbar.lastCheck"), broken.output)
        XCTAssertNotEqual(try tool().status, 0, "generation refuses a table with a broken specifier")
    }
}

import XCTest
@testable import PlayerIdentity

final class ConfigTests: XCTestCase {
    func testBasicNameAndModel() {
        let config = ConfigParser.parse("""
        bind "w" "+forward"
        name "Player"
        model "gordon"
        """)
        XCTAssertEqual(config, PlayerConfig(name: "Player", model: "gordon"))
    }

    func testDuplicateKeyLastWins() {
        let config = ConfigParser.parse("""
        name "First"
        model "barney"
        name "Second"
        model "gina"
        """)
        XCTAssertEqual(config.name, "Second")
        XCTAssertEqual(config.model, "gina")
    }

    func testSpacesInsideQuotesPreserved() {
        let config = ConfigParser.parse("name \"  Test   Oyuncu \"\r\nmodel \"gordon\"\r\n")
        XCTAssertEqual(config.name, "  Test   Oyuncu ")
        XCTAssertEqual(config.model, "gordon")
    }

    func testMissingKeysAreEmpty() {
        XCTAssertEqual(ConfigParser.parse("bind \"a\" \"+moveleft\"\n"), PlayerConfig(name: "", model: ""))
        XCTAssertEqual(ConfigParser.parse(""), PlayerConfig())
    }

    func testEmptyQuotedValue() {
        XCTAssertEqual(ConfigParser.parse("name \"\"").name, "")
    }

    func testTabsAndLeadingWhitespace() {
        XCTAssertEqual(ConfigParser.parse("\t name\t\"Tab User\"  ").name, "Tab User")
    }

    func testKeyMustMatchExactly() {
        let config = ConfigParser.parse("""
        namex "nope"
        cl_name "nope"
        topcolor "30"
        """)
        XCTAssertEqual(config, PlayerConfig())
    }

    func testReaderMissingFileYieldsEmpty() throws {
        let temp = try TempDirectory()
        let gamedir = try temp.makeDirectory("valve")
        XCTAssertEqual(ConfigReader().read(gamedir: gamedir), PlayerConfig())
    }

    func testReaderReadsFile() throws {
        let temp = try TempDirectory()
        try temp.write("valve/config.cfg", "name \"Ünlü Oyuncu\"\nmodel \"helmet\"\n")
        let config = ConfigReader().read(gamedir: temp.url.appendingPathComponent("valve"))
        XCTAssertEqual(config, PlayerConfig(name: "Ünlü Oyuncu", model: "helmet"))
    }

    // MARK: Gamedir discovery (§3.4)

    func testGamedirDiscoveryListsOnlyQualifyingFirstLevelDirectories() throws {
        let temp = try TempDirectory()
        try temp.write("valve/config.cfg", "name \"a\"")
        try temp.write("gearbox/.xash_id", "0000000000000000")
        _ = try temp.makeDirectory("empty")
        try temp.write("nested/deep/config.cfg", "")
        try temp.write("config.cfg", "")   // a file at the root is not a folder

        let found = GamedirDiscovery().discover(dataRoot: temp.url)
        XCTAssertEqual(found, ["gearbox", "valve"])
        XCTAssertEqual(GamedirDiscovery.defaultSelection(from: found), "valve")
    }

    func testGamedirDefaultFallsBackToFirst() {
        XCTAssertEqual(GamedirDiscovery.defaultSelection(from: ["bshift", "gearbox"]), "bshift")
        XCTAssertNil(GamedirDiscovery.defaultSelection(from: []))
    }

    func testGamedirDiscoveryMissingRoot() throws {
        let temp = try TempDirectory()
        XCTAssertEqual(GamedirDiscovery().discover(dataRoot: temp.url.appendingPathComponent("yok")), [])
    }
}

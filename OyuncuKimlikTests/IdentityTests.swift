import XCTest
@testable import OyuncuKimlik

final class IdentityTests: XCTestCase {
    private var temp: TempDirectory!
    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
    private var gamedir: URL { home.appendingPathComponent("Library/Application Support/Xash3D FWGS/valve", isDirectory: true) }
    private let gamedirPath = "home/Library/Application Support/Xash3D FWGS/valve"

    override func setUpWithError() throws {
        temp = try TempDirectory()
        _ = try temp.makeDirectory("home")
    }

    override func tearDown() {
        temp = nil
    }

    private var reader: IdentityReader { IdentityReader(homeDirectory: home) }

    // MARK: Hex

    func testHexParseToleratesWhitespaceAndCase() {
        XCTAssertEqual(HexID.parse("  0123456789abcdef\n"), 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(HexID.parse("0123456789ABCDEF\r\n"), 0x0123_4567_89AB_CDEF)
    }

    func testHexParseRejectsInvalid() {
        XCTAssertNil(HexID.parse(""))
        XCTAssertNil(HexID.parse("0123456789abcde"))      // 15
        XCTAssertNil(HexID.parse("0123456789abcdef0"))    // 17
        XCTAssertNil(HexID.parse("0123456789abcdeg"))     // hex değil
        XCTAssertNil(HexID.parse("+123456789abcdef"))     // işaret
        XCTAssertNil(HexID.parse("01234567 89abcdef"))    // iç boşluk
    }

    func testHexFormatIs16UpperPadded() {
        XCTAssertEqual(HexID.format(0), "0000000000000000")
        XCTAssertEqual(HexID.format(0xAB), "00000000000000AB")
    }

    // MARK: Maskeler

    func testHomeMaskYieldsZero() throws {
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB\n")
        let identity = try reader.read(gamedir: gamedir).get()
        XCTAssertEqual(identity.source.location, .homeConfig)
        XCTAssertEqual(identity.rawID, 0)
        XCTAssertEqual(identity.rawIDHex, "0000000000000000")
        XCTAssertTrue(identity.isRawIDZero)
    }

    func testGamedirMaskYieldsZero() throws {
        try temp.write("\(gamedirPath)/.xash_id", "7ffc48fbac1711f1")
        let identity = try reader.read(gamedir: gamedir).get()
        XCTAssertEqual(identity.source.location, .gamedir)
        XCTAssertEqual(identity.rawID, 0)
    }

    func testMasksDifferBySource() throws {
        try temp.write("\(gamedirPath)/.xash_id", "10331C2DCE4C91DB")
        let identity = try reader.read(gamedir: gamedir).get()
        XCTAssertEqual(identity.rawID, 0x6FCF_54D6_625B_802A)
        XCTAssertEqual(identity.rawIDHex, "6FCF54D6625B802A")
    }

    // MARK: Öncelik

    func testPriorityOrder() throws {
        try temp.write("home/.config/.xash_id", "1111111111111111")
        try temp.write("home/.local/.xash_id", "2222222222222222")
        try temp.write("home/.xash_id", "3333333333333333")
        try temp.write("\(gamedirPath)/.xash_id", "4444444444444444")

        XCTAssertEqual(try reader.read(gamedir: gamedir).get().source.location, .homeConfig)
        XCTAssertEqual(try reader.read(gamedir: gamedir).get().fileValue, 0x1111_1111_1111_1111)

        try temp.remove("home/.config/.xash_id")
        XCTAssertEqual(try reader.read(gamedir: gamedir).get().source.location, .homeLocal)

        try temp.remove("home/.local/.xash_id")
        XCTAssertEqual(try reader.read(gamedir: gamedir).get().source.location, .home)

        try temp.remove("home/.xash_id")
        let last = try reader.read(gamedir: gamedir).get()
        XCTAssertEqual(last.source.location, .gamedir)
        XCTAssertEqual(last.source.url.standardizedFileURL, gamedir.appendingPathComponent(".xash_id").standardizedFileURL)
    }

    func testInvalidHigherPriorityFileIsSkipped() throws {
        try temp.write("home/.config/.xash_id", "not-hex")
        try temp.write("home/.local/.xash_id", "2222222222222222")
        let identity = try reader.read(gamedir: gamedir).get()
        XCTAssertEqual(identity.source.location, .homeLocal)
    }

    func testDirectoryInPlaceOfFileIsSkipped() throws {
        _ = try temp.makeDirectory("home/.config/.xash_id")
        try temp.write("home/.xash_id", "3333333333333333")
        XCTAssertEqual(try reader.read(gamedir: gamedir).get().source.location, .home)
    }

    // MARK: Hatalar

    func testMissingWhenNoFiles() {
        XCTAssertEqual(reader.read(gamedir: gamedir), .failure(.missing))
        XCTAssertEqual(reader.read(gamedir: nil), .failure(.missing))
    }

    func testInvalidWhenOnlyInvalidFiles() throws {
        try temp.write("home/.config/.xash_id", "123")
        try temp.write("\(gamedirPath)/.xash_id", "0123456789abcdefXX")
        XCTAssertEqual(reader.read(gamedir: gamedir), .failure(.invalid))
    }

    func testNonUTF8FileIsInvalid() throws {
        try temp.write("home/.xash_id", Data([0xFF, 0xFE, 0x00, 0x41]))
        XCTAssertEqual(reader.read(gamedir: gamedir), .failure(.invalid))
    }

    func testGamedirFileIgnoredWhenNoGamedir() throws {
        try temp.write("\(gamedirPath)/.xash_id", "7ffc48fbac1711f1")
        XCTAssertEqual(reader.read(gamedir: nil), .failure(.missing))
    }
}

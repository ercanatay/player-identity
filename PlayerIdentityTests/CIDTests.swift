import XCTest
@testable import PlayerIdentity

/// §4.1 verification vectors (raw identity = 0).
final class CIDTests: XCTestCase {
    private func cid(_ host: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let address = try XCTUnwrap(ServerAddress.parse(host), file: file, line: line)
        return CIDCalculator.cid(rawID: 0, address: address)
    }

    func testVector1_95_173_174_175() throws {
        XCTAssertEqual(try cid("95.173.174.175"), "68f8c1fb2a23cb02409b8a3231487970")
    }

    func testVector2_51_68_190_91() throws {
        XCTAssertEqual(try cid("51.68.190.91"), "d9de0eb4419608a8423241430581e91c")
    }

    func testVector3_5_161_189_195() throws {
        XCTAssertEqual(try cid("5.161.189.195"), "5282a6daf7a33fe08469e453086de93c")
    }

    func testVector4_127_0_0_1() throws {
        XCTAssertEqual(try cid("127.0.0.1"), "e3f650e2c5f1293838ba8e934ba3b796")
    }

    func testVector5_localMachine() {
        XCTAssertEqual(CIDCalculator.cid(rawID: 0, address: .localMachine), "7dea362b3fac8e00956a4952a3d4f474")
    }

    func testInputLengths() throws {
        XCTAssertEqual(CIDCalculator.input(rawID: 0, address: .localMachine).count, 8)
        XCTAssertEqual(CIDCalculator.input(rawID: 0, address: try XCTUnwrap(ServerAddress.parse("1.2.3.4"))).count, 12)
        XCTAssertEqual(CIDCalculator.input(rawID: 0, address: try XCTUnwrap(ServerAddress.parse("::1"))).count, 24)
    }

    func testRawIDIsLittleEndian() throws {
        let input = CIDCalculator.input(rawID: 0x0123_4567_89AB_CDEF, address: .localMachine)
        XCTAssertEqual(input, [0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01])
        // Value verified by an independent computation (Python hashlib).
        XCTAssertEqual(CIDCalculator.cid(rawID: 0x0123_4567_89AB_CDEF, host: "127.0.0.1"),
                       "e8aa4bfc0b65a0f661a9aac775f9a288")
    }

    func testIPv6CIDFormatIs32LowerHexAndDeterministic() throws {
        let first = try XCTUnwrap(CIDCalculator.cid(rawID: 0, host: "2001:db8::1"))
        let second = try XCTUnwrap(CIDCalculator.cid(rawID: 0, host: "2001:db8::1"))
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "8fe63f59b45241e169e93faa103dd510")
        XCTAssertNotEqual(first, CIDCalculator.cid(rawID: 0, address: .localMachine))
    }

    func testInvalidHostHasNoCID() {
        XCTAssertNil(ServerAddress.parse(""))
        XCTAssertNil(ServerAddress.parse("example.com"))
        XCTAssertNil(ServerAddress.parse("256.1.1.1"))
        XCTAssertNil(ServerAddress.parse("1.2.3"))
        XCTAssertNil(CIDCalculator.cid(rawID: 0, host: "not-an-ip"))
    }
}

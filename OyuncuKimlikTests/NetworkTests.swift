import XCTest
@testable import OyuncuKimlik

/// Ağa çıkmayan sahte HTTP istemcisi.
private struct FakeHTTPClient: HTTPClient {
    struct Failure: Error {}
    let responses: [URL: Result<(data: Data, statusCode: Int), Failure>]

    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        guard timeout == 8 else { throw Failure() }
        guard let response = responses[url] else { throw Failure() }
        return try response.get()
    }
}

final class PublicIPClientTests: XCTestCase {
    private func ok(_ text: String) -> Result<(data: Data, statusCode: Int), FakeHTTPClient.Failure> {
        .success((Data(text.utf8), 200))
    }

    func testPrimaryUsedWhenAvailable() async throws {
        let client = PublicIPClient(http: FakeHTTPClient(responses: [
            PublicIPClient.primaryURL: ok(#"{"ip":"203.0.113.7"}"#),
            PublicIPClient.fallbackURL: ok("198.51.100.1\n"),
        ]))
        let ip = try await client.fetch()
        XCTAssertEqual(ip, "203.0.113.7")
    }

    func testFallbackWhenPrimaryFails() async throws {
        let client = PublicIPClient(http: FakeHTTPClient(responses: [
            PublicIPClient.primaryURL: .failure(.init()),
            PublicIPClient.fallbackURL: ok("198.51.100.1\n"),
        ]))
        let ip = try await client.fetch()
        XCTAssertEqual(ip, "198.51.100.1")
    }

    func testFallbackWhenPrimaryReturnsErrorStatusOrGarbage() async throws {
        let client = PublicIPClient(http: FakeHTTPClient(responses: [
            PublicIPClient.primaryURL: .success((Data("<html>".utf8), 503)),
            PublicIPClient.fallbackURL: ok("2001:db8::7"),
        ]))
        let ip = try await client.fetch()
        XCTAssertEqual(ip, "2001:db8::7")
    }

    func testBothFail() async {
        let client = PublicIPClient(http: FakeHTTPClient(responses: [
            PublicIPClient.primaryURL: ok("not json"),
            PublicIPClient.fallbackURL: ok("<html>hata</html>"),
        ]))
        do {
            _ = try await client.fetch()
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? PublicIPError, .unavailable)
        }
    }

    func testEndpointsAndTimeout() {
        XCTAssertEqual(PublicIPClient.primaryURL.absoluteString, "https://api.ipify.org?format=json")
        XCTAssertEqual(PublicIPClient.fallbackURL.absoluteString, "https://ifconfig.me/ip")
        XCTAssertEqual(PublicIPClient.timeout, 8)
    }
}

final class LocalIPFilterTests: XCTestCase {
    func testFiltersLoopbackAndLinkLocalAndOrdersIPv4First() {
        let entries = [
            InterfaceAddress(interface: "lo0", family: .ipv4, bytes: [127, 0, 0, 1], isLoopback: true),
            InterfaceAddress(interface: "lo0", family: .ipv6, bytes: [UInt8](repeating: 0, count: 15) + [1], isLoopback: true),
            InterfaceAddress(interface: "en0", family: .ipv6,
                             bytes: [0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [1], isLoopback: false),
            InterfaceAddress(interface: "en0", family: .ipv6,
                             bytes: [0xFE, 0xBF] + [UInt8](repeating: 0, count: 13) + [1], isLoopback: false),
            InterfaceAddress(interface: "en0", family: .ipv6,
                             bytes: [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [5], isLoopback: false),
            InterfaceAddress(interface: "en0", family: .ipv4, bytes: [192, 168, 2, 156], isLoopback: false),
            InterfaceAddress(interface: "en1", family: .ipv4, bytes: [10, 0, 0, 2], isLoopback: false),
        ]
        let result = LocalIPFilter.filter(entries).map(\.display)
        XCTAssertEqual(result, ["en0 · 192.0.2.10", "en1 · 10.0.0.2", "en0 · 2001:db8::5"])
    }

    func testSystemProviderNeverReturnsExcludedAddresses() {
        for address in SystemLocalIPProvider().localAddresses() {
            XCTAssertNotEqual(address.interface, "lo0")
            XCTAssertFalse(address.address.lowercased().hasPrefix("fe80"))
        }
    }
}

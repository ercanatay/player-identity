import XCTest
@testable import PlayerIdentity

/// §40 ban list URL template: validation, placeholder filling + percent-encoding, opening through a protocol.
final class BanListTests: XCTestCase {
    private let values = BanListValues(cid: "d9de0eb4419608a8423241430581e91c", ip: "2001:db8::1", host: "play.example.com",
                                       port: 27015)

    func testValidation() {
        XCTAssertEqual(BanListTemplate.validate(" https://panel.example.com/bans?q={cid} "),
                       .success("https://panel.example.com/bans?q={cid}"))
        XCTAssertEqual(BanListTemplate.validate("https://{host}/bans/{port}"), .success("https://{host}/bans/{port}"))
        XCTAssertEqual(BanListTemplate.validate(""), .failure(.empty))
        XCTAssertEqual(BanListTemplate.validate("http://panel.example.com/?q={cid}"), .failure(.notHTTPS))
        XCTAssertEqual(BanListTemplate.validate("ftp://panel.example.com/{cid}"), .failure(.notHTTPS))
        XCTAssertEqual(BanListTemplate.validate("https://panel.example.com/bans"), .failure(.noPlaceholder))
        XCTAssertEqual(BanListTemplate.validate("https://panel.example.com/?q={steamid}"), .failure(.unknownPlaceholder("steamid")))
        XCTAssertEqual(BanListTemplate.validate("https:///?q={cid}"), .failure(.invalidURL))
        XCTAssertEqual(BanListTemplate.validate("panel.example.com/?q={cid}"), .failure(.notHTTPS))
        XCTAssertEqual(BanListTemplate.placeholders(in: "https://x/{ip}/{port}?a={ip}"), ["ip", "port"])
    }

    func testFillingAndEncoding() throws {
        let url = try BanListTemplate.url("https://panel.example.com/bans?q={cid}&ip={ip}&h={host}:{port}", values: values).get()
        XCTAssertEqual(url.absoluteString,
                       "https://panel.example.com/bans?q=d9de0eb4419608a8423241430581e91c&ip=2001%3Adb8%3A%3A1&h=play.example.com:27015")
        let tricky = BanListValues(cid: nil, ip: "192.0.2.1", host: "a b&c=d/e?#", port: 1)
        XCTAssertEqual(try BanListTemplate.url("https://x.example/{host}", values: tricky).get().absoluteString,
                       "https://x.example/a%20b%26c%3Dd%2Fe%3F%23")
    }

    func testMissingValue() {
        let noCID = BanListValues(cid: nil, ip: nil, host: "h", port: 27015)
        XCTAssertEqual(BanListTemplate.url("https://x.example/?q={cid}", values: noCID), .failure(.missingValue(.cid)))
        XCTAssertEqual(BanListTemplate.url("https://x.example/?q={ip}", values: noCID), .failure(.missingValue(.ip)))
        XCTAssertEqual(BanListTemplate.url("http://x.example/?q={ip}", values: values), .failure(.notHTTPS))
    }

    @MainActor
    func testAppModelStoresAndOpensTheURL() async throws {
        let env = try TestAppEnvironment()
        let opener = RecordingURLOpener()
        let model = env.makeModel { $0.urlOpener = opener }
        model.addServer(ServerDraft(label: "A", host: "51.68.190.91"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertEqual(model.openBanList(for: id), .empty)                       // no template yet
        XCTAssertEqual(model.setBanListURL("http://x.example/{cid}", for: id), .notHTTPS)
        XCTAssertNil(model.servers[0].banListURL)
        XCTAssertNil(model.setBanListURL("https://panel.example.com/bans?q={cid}&ip={ip}", for: id))
        XCTAssertEqual(model.servers[0].banListURL, "https://panel.example.com/bans?q={cid}&ip={ip}")

        XCTAssertEqual(model.openBanList(for: id), .missingValue(.cid))          // no refresh → no CID yet
        await model.refresh().value
        XCTAssertNil(model.openBanList(for: id))
        XCTAssertEqual(opener.opened.map(\.absoluteString),
                       ["https://panel.example.com/bans?q=d9de0eb4419608a8423241430581e91c&ip=51.68.190.91"])

        model.save()
        let saved = try XCTUnwrap(SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot)
        XCTAssertEqual(saved.servers[0].banListURL, "https://panel.example.com/bans?q={cid}&ip={ip}")
        XCTAssertNil(model.setBanListURL("  ", for: id))                          // cleared
        XCTAssertNil(model.servers[0].banListURL)
        XCTAssertTrue(model.hasUnsavedChanges)
    }
}

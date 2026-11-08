import XCTest
@testable import OyuncuKimlik

final class ProfileLoaderTests: XCTestCase {
    func testLoadsPreferredGamedirIdentityAndConfig() throws {
        let temp = try TempDirectory()
        try temp.write("root/valve/config.cfg", "name \"V\"\nmodel \"gordon\"")
        try temp.write("root/gearbox/config.cfg", "name \"G\"\nmodel \"helmet\"")
        try temp.write("root/gearbox/.xash_id", "7FFC48FBAC1711F1")
        _ = try temp.makeDirectory("home")
        let loader = ProfileLoader(fileSystem: LocalFileSystem(), homeDirectory: temp.url.appendingPathComponent("home"))
        let root = temp.url.appendingPathComponent("root")

        let gearbox = loader.load(dataRoot: root, preferredGamedir: "gearbox")
        XCTAssertEqual(gearbox.gamedirs, ["gearbox", "valve"])
        XCTAssertEqual(gearbox.selectedGamedir, "gearbox")
        XCTAssertEqual(gearbox.config, PlayerConfig(name: "G", model: "helmet"))
        XCTAssertEqual(try gearbox.identity.get().source.location, .gamedir)
        XCTAssertEqual(try gearbox.identity.get().rawID, 0)

        let fallback = loader.load(dataRoot: root, preferredGamedir: "yok")
        XCTAssertEqual(fallback.selectedGamedir, "valve")
        XCTAssertEqual(fallback.config.name, "V")
        XCTAssertEqual(fallback.identity, .failure(.missing))
    }

    func testMissingDataRootStillReadsHomeIdentity() throws {
        let temp = try TempDirectory()
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
        let loader = ProfileLoader(fileSystem: LocalFileSystem(), homeDirectory: temp.url.appendingPathComponent("home"))
        let profile = loader.load(dataRoot: temp.url.appendingPathComponent("yok"), preferredGamedir: "valve")
        XCTAssertEqual(profile.gamedirs, [])
        XCTAssertNil(profile.selectedGamedir)
        XCTAssertEqual(profile.config, PlayerConfig())
        XCTAssertEqual(try profile.identity.get().source.location, .homeConfig)
    }
}

final class SnapshotBuilderTests: XCTestCase {
    private func identity(_ raw: UInt64) -> Result<Identity, IdentityError> {
        .success(Identity(source: IdentitySource(location: .homeConfig, url: URL(fileURLWithPath: "/h/.config/.xash_id")),
                          fileValue: raw ^ IdentityLocation.homeMask, rawID: raw))
    }

    func testCIDWrittenOnlyForCheckedRows() {
        let checked = ServerEntry(label: "A", host: "95.173.174.175", lastCheckedAt: Date(timeIntervalSince1970: 10))
        let fresh = ServerEntry(label: "B", host: "51.68.190.91")
        let snapshot = SnapshotBuilder.make(savedAt: Date(timeIntervalSince1970: 20),
                                            dataRoot: URL(fileURLWithPath: "/data/root/"),
                                            gamedir: "valve",
                                            config: PlayerConfig(name: "N", model: "M"),
                                            identity: identity(0),
                                            publicIP: "203.0.113.7",
                                            lanIPs: ["en0 · 10.0.0.2"],
                                            checkedAt: Date(timeIntervalSince1970: 10),
                                            servers: [checked, fresh])
        XCTAssertEqual(snapshot.servers[0].cid, "68f8c1fb2a23cb02409b8a3231487970")
        XCTAssertEqual(snapshot.servers[1].cid, "")
        XCTAssertEqual(snapshot.rawID, "0000000000000000")
        XCTAssertEqual(snapshot.identitySource, "/h/.config/.xash_id")
        XCTAssertEqual(snapshot.dataRoot, "/data/root")
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.network.publicIP, "203.0.113.7")
    }

    func testMissingIdentityAndIPWriteEmptyFields() {
        let row = ServerEntry(label: "A", host: "1.2.3.4", lastCheckedAt: Date())
        let snapshot = SnapshotBuilder.make(savedAt: Date(), dataRoot: URL(fileURLWithPath: "/r"), gamedir: nil,
                                            config: PlayerConfig(), identity: .failure(.missing), publicIP: nil,
                                            lanIPs: [], checkedAt: nil, servers: [row])
        XCTAssertEqual(snapshot.rawID, "")
        XCTAssertEqual(snapshot.identitySource, "")
        XCTAssertEqual(snapshot.gamedir, "")
        XCTAssertEqual(snapshot.network.publicIP, "")
        XCTAssertEqual(snapshot.servers[0].cid, "")
    }
}

final class EditableStateTests: XCTestCase {
    func testIgnoresCIDAndCheckTimeButTracksEdits() {
        let id = UUID()
        let a = EditableState(dataRoot: "/r/", gamedir: "valve",
                              servers: [ServerEntry(id: id, label: "A", host: "1.2.3.4", cid: "x", lastCheckedAt: Date())])
        let b = EditableState(dataRoot: "/r", gamedir: "valve",
                              servers: [ServerEntry(id: id, label: "A", host: "1.2.3.4")])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, EditableState(dataRoot: "/r", gamedir: "gearbox", servers: [ServerEntry(id: id, label: "A", host: "1.2.3.4")]))
        XCTAssertNotEqual(a, EditableState(dataRoot: "/r", gamedir: "valve", servers: [ServerEntry(id: id, label: "A", host: "1.2.3.4", port: 27016)]))
        XCTAssertNotEqual(a, EditableState(dataRoot: "/other", gamedir: "valve", servers: [ServerEntry(id: id, label: "A", host: "1.2.3.4")]))
    }
}

final class ServerDraftTests: XCTestCase {
    func testDefaultPortIs27015() {
        XCTAssertEqual(ServerDraft().portText, "27015")
        XCTAssertEqual(ServerDraft().port, 27015)
    }

    func testValidation() {
        XCTAssertEqual(ServerDraft().problems, [.labelEmpty, .hostEmpty])
        XCTAssertTrue(ServerDraft(label: " Test ", host: " example.com ").isValid)
        XCTAssertEqual(ServerDraft(label: " Test ", host: " 1.2.3.4 ").trimmedHost, "1.2.3.4")
        XCTAssertEqual(ServerDraft(label: "a", host: "b", portText: "0").problems, [.portInvalid])
        XCTAssertEqual(ServerDraft(label: "a", host: "b", portText: "65536").problems, [.portInvalid])
        XCTAssertEqual(ServerDraft(label: "a", host: "b", portText: "abc").problems, [.portInvalid])
        XCTAssertEqual(ServerDraft(label: "a", host: "b", portText: "65535").port, 65535)
    }
}

final class TimeTextTests: XCTestCase {
    func testFormatIsHHmmss() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TimeText.format(Date(timeIntervalSince1970: 13 * 3600 + 5 * 60 + 9), timeZone: utc), "13:05:09")
        XCTAssertEqual(TimeText.format(nil), "—")
    }
}

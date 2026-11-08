import XCTest
@testable import OyuncuKimlik

final class SnapshotTests: XCTestCase {
    static func sample() -> Snapshot {
        Snapshot(
            savedAt: Date(timeIntervalSince1970: 1_793_000_000),
            gamedir: "valve",
            dataRoot: "/tmp/Xash3D FWGS",
            displayName: "Oyuncu Bir",
            model: "gordon",
            rawID: "0000000000000000",
            identitySource: "/tmp/home/.config/.xash_id",
            network: NetworkInfo(publicIP: "203.0.113.7",
                                 lanIPs: ["en0 · 192.0.2.10"],
                                 checkedAt: Date(timeIntervalSince1970: 1_793_000_010)),
            servers: [
                ServerEntry(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                            label: "Test", host: "95.173.174.175", port: 27015,
                            cid: "68f8c1fb2a23cb02409b8a3231487970",
                            lastCheckedAt: Date(timeIntervalSince1970: 1_793_000_020)),
                ServerEntry(label: "Yeni", host: "51.68.190.91"),
            ])
    }

    func testRoundtrip() throws {
        let temp = try TempDirectory()
        let store = SnapshotStore(fileURL: temp.url.appendingPathComponent("sub/profile.json"))
        XCTAssertEqual(store.load(), .missing)

        let snapshot = Self.sample()
        try store.save(snapshot)
        XCTAssertEqual(store.load(), .loaded(snapshot))

        // Üzerine yazma (replaceItemAt yolu)
        var changed = snapshot
        changed.displayName = "Oyuncu İki"
        try store.save(changed)
        XCTAssertEqual(store.load(), .loaded(changed))

        // Geçici dosya kalmamalı
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["profile.json"])
    }

    func testEncodedJSONShape() throws {
        let data = try SnapshotStore.makeEncoder().encode(Self.sample())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["rawID"] as? String, "0000000000000000")
        XCTAssertNotNil(object["savedAt"] as? String)
        let network = try XCTUnwrap(object["network"] as? [String: Any])
        XCTAssertEqual(network["lanIPs"] as? [String], ["en0 · 192.0.2.10"])
        let servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0]["port"] as? Int, 27015)
        XCTAssertEqual(servers[1]["cid"] as? String, "")
    }

    func testDecodesSpecExample() {
        let json = """
        {
          "schemaVersion": 1,
          "savedAt": "2026-11-08T11:21:00Z",
          "gamedir": "valve",
          "dataRoot": "/Users/u/Library/Application Support/Xash3D FWGS",
          "displayName": "x",
          "model": "y",
          "rawID": "0000000000000000",
          "identitySource": "/Users/u/.config/.xash_id",
          "network": { "publicIP": "1.2.3.4", "lanIPs": ["en0 · 192.0.2.10"], "checkedAt": "2026-11-08T11:21:00Z" },
          "servers": [
            { "id": "11111111-2222-3333-4444-555555555555", "label": "a", "host": "1.2.3.4", "port": 27015, "cid": "", "lastCheckedAt": "2026-11-08T11:21:00Z" }
          ]
        }
        """
        let result = SnapshotStore.decode(Data(json.utf8))
        XCTAssertEqual(result.snapshot?.servers.first?.port, 27015)
        XCTAssertEqual(result.snapshot?.network.publicIP, "1.2.3.4")
    }

    func testCorruptJSON() throws {
        let temp = try TempDirectory()
        let file = try temp.write("profile.json", "{ bozuk json")
        XCTAssertEqual(SnapshotStore(fileURL: file).load(), .corrupt)
    }

    func testMissingFieldIsCorrupt() {
        XCTAssertEqual(SnapshotStore.decode(Data(#"{"schemaVersion":1,"gamedir":"valve"}"#.utf8)), .corrupt)
    }

    func testUnknownSchemaVersion() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: SnapshotStore.makeEncoder().encode(Self.sample())) as? [String: Any])
        object["schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(SnapshotStore.decode(data), .unsupportedSchema(2))
    }

    func testUnreadablePathIsCorrupt() throws {
        let temp = try TempDirectory()
        let dir = try temp.makeDirectory("profile.json")   // dosya yerine klasör
        XCTAssertEqual(SnapshotStore(fileURL: dir).load(), .corrupt)
    }
}

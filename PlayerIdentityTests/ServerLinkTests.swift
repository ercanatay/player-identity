import XCTest
@testable import PlayerIdentity

/// §53 `playeridentity://add?…` links: parsing (single, repeated hosts, port, label/group/watch), invalid entries,
/// errors, the Info.plist URL type and the unsaved rows added by the model.
@MainActor
final class ServerLinkTests: XCTestCase {
    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text), text) }

    private func request(_ text: String, existing: [ServerEntry] = []) throws -> ServerLink.Request {
        try ServerLink.parse(url(text), existing: existing).get()
    }

    func testSingleHostWithPortLabelGroupAndWatch() throws {
        let parsed = try request("playeridentity://add?host=Example.com&port=27016&label=Demo&group=EU&watch=1")
        XCTAssertEqual(parsed.entries.fresh, [ServerURLImport.Candidate(host: "example.com", port: 27016)])
        XCTAssertEqual(parsed.label, "Demo")
        XCTAssertEqual(parsed.group, "EU")
        XCTAssertTrue(parsed.watch)
        XCTAssertEqual(parsed.entries.invalid, [])

        let plain = try request("playeridentity://add?host=192.0.2.1")
        XCTAssertEqual(plain.entries.fresh, [ServerURLImport.Candidate(host: "192.0.2.1", port: 27015)])   // default port
        XCTAssertNil(plain.label)
        XCTAssertNil(plain.group)
        XCTAssertFalse(plain.watch)
        // Other spellings: `playeridentity:add`, upper-case scheme/action, watch=true / watch=0, empty label.
        XCTAssertEqual(try request("playeridentity:add?host=192.0.2.1").entries.fresh.count, 1)
        XCTAssertEqual(try request("PlayerIdentity://ADD?host=192.0.2.1&watch=true&label=").watch, true)
        XCTAssertNil(try request("playeridentity://add?host=192.0.2.1&label=%20%20").label)
        XCTAssertFalse(try request("playeridentity://add?host=192.0.2.1&watch=0").watch)
        XCTAssertEqual(try request("playeridentity://add?host=192.0.2.1&label=Demo%20Server").label, "Demo Server")
    }

    func testRepeatedHostsOwnPortsAndDuplicates() throws {
        let parsed = try request("playeridentity://add?host=192.0.2.1&host=192.0.2.2:27020&host=%5B2001:db8::1%5D"
                                 + "&host=192.0.2.1&port=27030")
        XCTAssertEqual(parsed.entries.fresh, [
            ServerURLImport.Candidate(host: "192.0.2.1", port: 27030),        // `port` applies to hosts without one
            ServerURLImport.Candidate(host: "192.0.2.2", port: 27020),        // its own port is kept
            ServerURLImport.Candidate(host: "2001:db8::1", port: 27030),
        ])
        XCTAssertEqual(parsed.entries.duplicates, 1)
        // GameTracker / steam links keep their own port.
        let links = try request("playeridentity://add?host=steam://connect/192.0.2.5:27019"
                                + "&host=https://www.gametracker.com/server_info/192.0.2.6:27018/&port=1")
        XCTAssertEqual(links.entries.fresh.map(\.id), ["192.0.2.5:27019", "192.0.2.6:27018"])
    }

    func testInvalidEntriesAreReportedAndExistingOnesSkipped() throws {
        let existing = [ServerEntry(label: "Old", host: "192.0.2.9", port: 27015)]
        let parsed = try request("playeridentity://add?host=not_a_host&host=2001:db8::1&host=192.0.2.9&host=192.0.2.3:99999"
                                 + "&host=ftp://x&host=192.0.2.4", existing: existing)
        XCTAssertEqual(parsed.entries.fresh.map(\.id), ["192.0.2.4:27015"])
        XCTAssertEqual(parsed.entries.existing.map(\.id), ["192.0.2.9:27015"])
        XCTAssertEqual(parsed.entries.invalid.map(\.reason), [.hostInvalid, .ipv6NeedsBrackets, .portInvalid, .unsupportedURL])
        XCTAssertEqual(parsed.entries.invalid.map(\.raw), ["not_a_host", "2001:db8::1", "192.0.2.3:99999", "ftp://x"])
        // An invalid `port` makes the hosts without their own port invalid.
        let badPort = try request("playeridentity://add?host=192.0.2.1&port=abc").entries.invalid
        XCTAssertEqual(badPort.map(\.reason), [.portInvalid])
        XCTAssertEqual(badPort.map(\.raw), ["192.0.2.1"])   // reported as written in the link
        // A comma-separated value counts as several hosts; the entry numbers follow them.
        let split = try request("playeridentity://add?host=192.0.2.1,%20bad_host&host=192.0.2.2&port=27020")
        XCTAssertEqual(split.entries.fresh.map(\.id), ["192.0.2.1:27020", "192.0.2.2:27020"])
        XCTAssertEqual(split.entries.invalid, [ServerURLImport.Invalid(index: 2, raw: "bad_host", reason: .hostInvalid)])
    }

    func testLinkErrors() throws {
        XCTAssertEqual(ServerLink.parse(try url("https://example.com/add?host=192.0.2.1")),
                       .failure(.unsupportedScheme("https://example.com/add?host=192.0.2.1")))
        XCTAssertEqual(ServerLink.parse(try url("playeridentity://remove?host=192.0.2.1")), .failure(.unsupportedAction("remove")))
        XCTAssertEqual(ServerLink.parse(try url("playeridentity://add")), .failure(.noHost))
        XCTAssertEqual(ServerLink.parse(try url("playeridentity://add?host=&host=%20&port=1")), .failure(.noHost))
        XCTAssertEqual(ServerLink.parse(try url("playeridentity://add?label=x")), .failure(.noHost))
    }

    func testAppDeclaresTheURLScheme() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [ServerLink.scheme])
    }

    // MARK: Model

    func testModelAddsUnsavedRowsAndReportsTheRest() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "Old", host: "192.0.2.9", group: "Europe"))
        await model.refresh().value
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)

        let outcome = model.handleServerLink(try url("playeridentity://add?host=192.0.2.1&host=192.0.2.2&host=192.0.2.9"
                                                     + "&host=bad_host&label=Demo&group=europe&watch=1"))
        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.existing, 1)
        XCTAssertEqual(outcome.invalid.map(\.raw), ["bad_host"])
        XCTAssertNil(outcome.failure)
        XCTAssertNotNil(model.serverLinkOutcome)
        XCTAssertTrue(model.hasUnsavedChanges)   // "Kaydedilmedi"
        let added = model.servers.filter { $0.host == "192.0.2.1" || $0.host == "192.0.2.2" }
        XCTAssertEqual(added.map(\.label), ["Demo", "Demo"])
        XCTAssertEqual(added.map(\.group), ["Europe", "Europe"])   // the existing group's spelling
        XCTAssertEqual(added.map(\.watch), [true, true])
        XCTAssertEqual(model.servers.count, 3)

        // The same link again adds nothing.
        let again = model.handleServerLink(try url("playeridentity://add?host=192.0.2.1"))
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.existing, 1)
        XCTAssertEqual(model.servers.count, 3)

        let wrong = model.handleServerLink(try url("playeridentity://open?host=192.0.2.7"))
        XCTAssertEqual(wrong.added, 0)
        XCTAssertNotNil(wrong.failure)

        XCTAssertTrue(model.beginDataOperation(.erase))
        let busy = model.handleServerLink(try url("playeridentity://add?host=192.0.2.7"))
        model.endDataOperation()
        XCTAssertEqual(busy.added, 0)
        XCTAssertNotNil(busy.failure)
        XCTAssertEqual(model.servers.count, 3)
    }

    func testOutcomeTextsInBothLanguages() throws {
        var outcome = ServerLink.Outcome()
        outcome.added = 2
        outcome.existing = 1
        outcome.invalid = [ServerURLImport.Invalid(index: 3, raw: "bad_host", reason: .hostInvalid)]
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr"))) {
            XCTAssertEqual(outcome.lines.first, "2 sunucu eklendi (Kaydedilmedi).")
            XCTAssertEqual(outcome.lines[1], "1 sunucu zaten listede.")
            XCTAssertEqual(outcome.lines.count, 4)
            XCTAssertEqual(ServerLink.Failure.noHost.text, "Bağlantıda sunucu adresi (host) yok.")
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(outcome.lines.first, "2 servers added (unsaved).")
            XCTAssertTrue(outcome.lines[3].hasPrefix("Entry 3: bad_host"), outcome.lines[3])
            XCTAssertEqual(ServerLink.Outcome().lines, ["No valid entries found."])
        }
    }
}

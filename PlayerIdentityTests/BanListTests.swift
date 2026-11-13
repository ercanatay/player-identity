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

    // MARK: §59 template library

    func testPresetLibrary() throws {
        XCTAssertEqual(BanListPreset.all.map(\.id), ["sourcebans", "amxbans", "hlstatsx", "generic-cid", "generic-ip"])
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                XCTAssertEqual(BanListPreset.all.prefix(3).map(\.name), ["SourceBans++", "AMXBans", "HLstatsX"])
                for preset in BanListPreset.all {
                    XCTAssertFalse(preset.summary.isEmpty, "\(language) \(preset.id)")
                    XCTAssertNotEqual(preset.summary, preset.descriptionKey.rawValue, "\(language) \(preset.id)")
                }
            }
        }
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("en"))) {
            XCTAssertEqual(BanListPreset.all.suffix(2).map(\.name), ["Generic (CID)", "Generic (IP)"])
        }
        for preset in BanListPreset.all {
            XCTAssertEqual(BanListTemplate.validate(preset.template), .success(preset.template), preset.id)
            XCTAssertTrue(preset.template.hasPrefix("https://"), preset.id)
            XCTAssertFalse(preset.placeholders.isEmpty, preset.id)
            XCTAssertEqual(BanListPreset.matching(" \(preset.template) "), preset)
            XCTAssertEqual(BanListPreset.preset(id: preset.id), preset)
        }
        XCTAssertEqual(BanListPreset.preset(id: "generic-ip")?.placeholders, [.ip, .host, .port])
        XCTAssertNil(BanListPreset.matching("https://panel.example.com/bans?q={cid}"))   // custom
        XCTAssertNil(BanListPreset.matching(""))
        XCTAssertNil(BanListPreset.preset(id: ""))
    }

    func testValidationLimits() throws {
        XCTAssertEqual(BanListTemplate.validate("https://panel.example.com/bans?q={cid} x"), .failure(.containsWhitespace))
        XCTAssertEqual(BanListTemplate.validate("https://panel.example.com/a\tb?q={cid}"), .failure(.containsWhitespace))
        XCTAssertEqual(BanListTemplate.validate("https://panel.example.com/a\nb?q={cid}"), .failure(.containsWhitespace))
        let prefix = "https://panel.example.com/?q={cid}&p="
        let exact = prefix + String(repeating: "a", count: BanListTemplate.maxLength - prefix.count)
        XCTAssertEqual(exact.count, 2048)
        XCTAssertEqual(BanListTemplate.validate(exact), .success(exact))
        XCTAssertEqual(BanListTemplate.validate(exact + "a"), .failure(.tooLong))
        for language in ["tr", "en"] {
            try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language))) {
                XCTAssertTrue(BanListText.error(.tooLong).contains("2048"), language)
                XCTAssertFalse(BanListText.error(.containsWhitespace).isEmpty, language)
            }
        }
    }

    func testPresetFillingEncodesOnlyWhatNeedsIt() throws {
        let generic = try XCTUnwrap(BanListPreset.preset(id: "generic-cid"))
        let row = BanListValues(cid: "d9de0eb4419608a8423241430581e91c", ip: "51.68.190.91", host: "oyun sunucusu.example",
                                port: 27015)
        XCTAssertEqual(try BanListTemplate.url(generic.template, values: row).get().absoluteString,
                       "https://bans.example.com/search?cid=d9de0eb4419608a8423241430581e91c&server=oyun%20sunucusu.example:27015")
        let byIP = try XCTUnwrap(BanListPreset.preset(id: "generic-ip"))
        XCTAssertEqual(try BanListTemplate.url(byIP.template, values: row).get().absoluteString,
                       "https://bans.example.com/search?ip=51.68.190.91&server=oyun%20sunucusu.example:27015")
    }

    @MainActor
    func testTemplateIsPerServerAndCanBeAppliedToAll() throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "51.68.190.91"))
        model.addServer(ServerDraft(label: "B", host: "51.68.190.92"))
        model.addServer(ServerDraft(label: "C", host: "51.68.190.93"))
        let ids = model.servers.map(\.id)
        let sourceBans = try XCTUnwrap(BanListPreset.preset(id: "sourcebans")).template
        let hlstats = try XCTUnwrap(BanListPreset.preset(id: "hlstatsx")).template

        XCTAssertNil(model.setBanListURL(sourceBans, for: ids[0]))
        XCTAssertNil(model.setBanListURL(hlstats, for: ids[1]))
        XCTAssertEqual(model.servers.map(\.banListURL), [sourceBans, hlstats, nil])   // per server

        // Invalid template: nothing changes anywhere.
        XCTAssertEqual(model.applyBanListURLToAll("http://bans.example.com/{cid}"), .notHTTPS)
        XCTAssertEqual(model.applyBanListURLToAll("https://bans.example.com/{cid} x"), .containsWhitespace)
        XCTAssertEqual(model.setBanListURL("https://bans.example.com/" + String(repeating: "a", count: 2048) + "{cid}",
                                           for: ids[2]), .tooLong)
        XCTAssertEqual(model.servers.map(\.banListURL), [sourceBans, hlstats, nil])

        XCTAssertNil(model.applyBanListURLToAll(" \(hlstats) "))
        XCTAssertEqual(model.servers.map(\.banListURL), [hlstats, hlstats, hlstats])
        XCTAssertTrue(model.hasUnsavedChanges)

        model.save()
        let saved = try XCTUnwrap(SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot)
        XCTAssertEqual(saved.servers.map(\.banListURL), [hlstats, hlstats, hlstats])
    }

    /// Templates saved before the library existed stay as they are (same field, no migration) and show as "Custom".
    @MainActor
    func testExistingTemplateIsKept() throws {
        let env = try TestAppEnvironment()
        let custom = "https://panel.example.com/bans?q={cid}&ip={ip}"
        let first = env.makeModel()
        first.addServer(ServerDraft(label: "A", host: "51.68.190.91"))
        let id = try XCTUnwrap(first.servers.first?.id)
        XCTAssertNil(first.setBanListURL(custom, for: id))
        first.save()

        let reloaded = env.makeModel()
        XCTAssertEqual(reloaded.servers.first?.banListURL, custom)
        XCTAssertNil(BanListPreset.matching(custom))
        XCTAssertFalse(reloaded.hasUnsavedChanges)
        XCTAssertEqual(ServerDetailSheet.validationText(custom), nil)
    }
}

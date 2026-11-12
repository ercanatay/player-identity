import XCTest
@testable import PlayerIdentity

/// §52 `playeridentityctl backup | restore | servers | diagnostics`: parsing, JSON (`schemaVersion: 1`), exit codes,
/// confirmations and the files written. In-process via `CLIRunner.run` on a temporary home; no network.
final class CLIDataTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var temp: TempDirectory!
    private let clock = TestClock()

    override func setUpWithError() throws {
        temp = try TempDirectory()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
    private var paths: AppPaths { AppPaths(home: home) }

    private func context(prompt: CLIPrompt = .none, suite: String = "CLIDataTests-unused") -> CLIContext {
        let clock = self.clock
        var context = CLIContext(version: "3.0.0", build: "40", paths: paths, environment: [:], fileSystem: LocalFileSystem(),
                                 resolver: FakeAddressResolver(), udpTransport: FakeServer.healthy(clock: clock),
                                 now: { clock.now })
        context.prompt = prompt
        context.defaultsSuite = suite
        return context
    }

    private func run(_ arguments: [String], _ context: CLIContext? = nil) async -> CLIResult {
        await CLIRunner.run(arguments: arguments, context: context ?? self.context())
    }

    private func json(_ result: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        let value = try XCTUnwrap(object, result.stdout + result.stderr, file: file, line: line)
        XCTAssertEqual(value["schemaVersion"] as? Int, 1, file: file, line: line)
        return value
    }

    private func writeRecord(_ servers: [ServerEntry]) throws {
        let snapshot = Snapshot(savedAt: Self.t0, gamedir: "valve", dataRoot: "/x", displayName: "Player", model: "gordon",
                                rawID: "0000000000000000", identitySource: "/x/.xash_id",
                                network: NetworkInfo(publicIP: "198.51.100.7", lanIPs: [], checkedAt: Self.t0),
                                servers: servers)
        try SnapshotStore(fileURL: paths.snapshotFile).save(snapshot)
    }

    private var savedServers: [ServerEntry] { SnapshotStore(fileURL: paths.snapshotFile).load().snapshot?.servers ?? [] }

    private func sampleServers() -> [ServerEntry] {
        [ServerEntry(label: "EU", host: "192.0.2.20", group: "Europe", order: 0),
         ServerEntry(label: "Six", host: "2001:db8::1", port: 27016, order: 1, watch: true)]
    }

    // MARK: Parsing

    func testParsing() {
        XCTAssertEqual(CLIParser.parse(["backup"]), .success(.backup(out: nil, json: false)))
        XCTAssertEqual(CLIParser.parse(["backup", "--out", "/tmp/b.zip", "--json"]), .success(.backup(out: "/tmp/b.zip", json: true)))
        XCTAssertEqual(CLIParser.parse(["restore", "b.zip", "--yes"]), .success(.restore(path: "b.zip", yes: true, json: false)))
        XCTAssertEqual(CLIParser.parse(["servers", "list", "--json"]), .success(.serversList(json: true)))
        XCTAssertEqual(CLIParser.parse(["servers", "add", "192.0.2.1:27016", "--label", " Demo ", "--group=EU", "--watch"]),
                       .success(.serversAdd(entry: "192.0.2.1:27016", label: "Demo", group: "EU", watch: true, json: false)))
        XCTAssertEqual(CLIParser.parse(["servers", "add", "192.0.2.1", "--label", " "]),
                       .success(.serversAdd(entry: "192.0.2.1", label: nil, group: nil, watch: false, json: false)))
        XCTAssertEqual(CLIParser.parse(["servers", "remove", "2", "--yes", "--json"]),
                       .success(.serversRemove(target: "2", yes: true, json: true)))
        XCTAssertEqual(CLIParser.parse(["diagnostics", "--out=/tmp"]), .success(.diagnostics(out: "/tmp", json: false)))

        let usageErrors: [[String]] = [
            ["backup", "extra"], ["backup", "--out"], ["backup", "--out", " "], ["backup", "--yes"], ["backup", "--label", "x"],
            ["restore"], ["restore", "a.zip", "b.zip"], ["restore", "a.zip", "--out", "x"], ["restore", "a.zip", "--watch"],
            ["servers"], ["servers", "frob"], ["servers", "list", "extra"], ["servers", "list", "--yes"],
            ["servers", "list", "--label", "x"], ["servers", "add"], ["servers", "add", "a", "b"], ["servers", "add", "a", "--yes"],
            ["servers", "add", "a", "--out", "x"], ["servers", "remove"], ["servers", "remove", "1", "--watch"],
            ["servers", "remove", "1", "--label", "x"], ["diagnostics", "x"], ["diagnostics", "--yes"], ["status", "--yes"],
            ["status", "--watch"], ["status", "--out", "x"], ["ban", "192.0.2.1", "--label", "x"],
            ["servers", "add", "a", "--label", "x", "--label", "y"],
        ]
        for arguments in usageErrors {
            guard case .failure = CLIParser.parse(arguments) else {
                XCTFail("expected usage error: \(arguments)")
                continue
            }
        }
    }

    func testHelpListsTheNewCommands() async {
        let help = await run(["--help"])
        for command in ["backup [--out <path>]", "restore <zip> [--yes]", "servers list", "servers add <host:port>",
                        "servers remove <host:port|index>", "diagnostics [--out <path>]"] {
            XCTAssertTrue(help.stdout.contains(command), command)
        }
    }

    // MARK: backup

    func testBackupDefaultPathJSONAndRefusals() async throws {
        let empty = await run(["backup", "--json"])
        XCTAssertEqual(empty.exitCode, 3)
        XCTAssertEqual(try json(empty)["error"] as? String, "nothingToBackUp")

        try writeRecord(sampleServers())
        try HistoryStore(fileURL: paths.historyFile).append([HistoryEntry(ts: Self.t0, kind: .ipChanged, old: "a", new: "b")])
        let result = await run(["backup", "--json"])
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
        let object = try json(result)
        let path = try XCTUnwrap(object["path"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL,
                       home.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, FullBackupNaming.manualFileName(now: clock.now))
        XCTAssertEqual(object["files"] as? [String], ["profile.json", "history.jsonl"])
        XCTAssertEqual((object["counts"] as? [String: Any])?["servers"] as? Int, 2)
        XCTAssertEqual(object["complete"] as? Bool, true)
        let parsed = try FullBackupParser.read(URL(fileURLWithPath: path)).get()
        XCTAssertEqual(parsed.counts.historyEntries, 1)
        XCTAssertEqual(parsed.manifest.appVersion, "3.0.0")

        // The same name again is refused (never overwritten); a folder gets the default name inside it.
        let again = await run(["backup"])
        XCTAssertEqual(again.exitCode, 1)
        XCTAssertTrue(again.stderr.contains("already exists"), again.stderr)
        let folder = try temp.makeDirectory("out")
        clock.advance(1)
        let inFolder = await run(["backup", "--out", folder.path])
        XCTAssertEqual(inFolder.exitCode, 0, inFolder.stderr)
        XCTAssertTrue(inFolder.stdout.hasPrefix("backup: " + folder.appendingPathComponent(FullBackupNaming.manualFileName(now: clock.now)).path),
                      inFolder.stdout)
        XCTAssertTrue(inFolder.stdout.contains("servers: 2, history entries: 1, metric samples: 0"), inFolder.stdout)
        let missingFolder = await run(["backup", "--out", temp.url.appendingPathComponent("nope/b.zip").path, "--json"])
        XCTAssertEqual(missingFolder.exitCode, 2)
        XCTAssertEqual(try json(missingFolder)["error"] as? String, "folderMissing")
    }

    // MARK: restore

    private func makeBackup(_ servers: [ServerEntry]) throws -> URL {
        let source = try TempDirectory()
        let sourcePaths = AppPaths(home: source.url)
        let snapshot = Snapshot(savedAt: Self.t0, gamedir: "valve", dataRoot: "/x", displayName: "Backup", model: "gordon",
                                rawID: "0000000000000000", identitySource: "/x/.xash_id",
                                network: NetworkInfo(publicIP: "", lanIPs: [], checkedAt: nil), servers: servers)
        try SnapshotStore(fileURL: sourcePaths.snapshotFile).save(snapshot)
        let file = temp.url.appendingPathComponent("backup-\(UUID().uuidString).zip")
        try FullBackupStore(paths: sourcePaths, appVersion: "2.9.0").write(to: file, now: Self.t0)
        return file
    }

    func testRestoreValidationConfirmationAndPreRestoreBackup() async throws {
        try writeRecord(sampleServers())
        let zip = try makeBackup([ServerEntry(label: "Restored", host: "198.51.100.1")])

        let missing = await run(["restore", temp.url.appendingPathComponent("none.zip").path, "--yes", "--json"])
        XCTAssertEqual(missing.exitCode, 3)
        XCTAssertEqual(try json(missing)["error"] as? String, "notFound")
        let corrupt = try temp.write("corrupt.zip", "not a zip")
        let invalid = await run(["restore", corrupt.path, "--yes", "--json"])
        XCTAssertEqual(invalid.exitCode, 2)
        XCTAssertEqual(try json(invalid)["error"] as? String, "unreadableArchive")
        XCTAssertEqual(savedServers.map(\.label), ["EU", "Six"])

        // No terminal and no --yes: refused before anything is written.
        let noTTY = await run(["restore", zip.path, "--json"])
        XCTAssertEqual(noTTY.exitCode, 1)
        XCTAssertEqual(try json(noTTY)["error"] as? String, "confirmationRequired")
        let declined = PromptLog(answer: false)
        let no = await run(["restore", zip.path], context(prompt: declined.prompt))
        XCTAssertEqual(no.exitCode, 1)
        XCTAssertEqual(declined.questions.count, 1)
        XCTAssertTrue(declined.questions[0].contains("1 servers"), declined.questions[0])
        XCTAssertTrue(declined.questions[0].hasSuffix("[y/N] "))
        XCTAssertEqual(savedServers.map(\.label), ["EU", "Six"])
        XCTAssertEqual(FullBackupStore(paths: paths, appVersion: "3.0.0").list(.preRestore), [])

        let accepted = PromptLog(answer: true)
        let yes = await run(["restore", zip.path, "--json"], context(prompt: accepted.prompt))
        XCTAssertEqual(yes.exitCode, 0, yes.stdout)
        let object = try json(yes)
        XCTAssertEqual(object["restored"] as? Bool, true)
        XCTAssertEqual((object["backup"] as? [String: Any])?["compatibility"] as? String, "olderVersion")
        let safety = try XCTUnwrap(object["preRestoreBackup"] as? String)
        XCTAssertTrue(URL(fileURLWithPath: safety).lastPathComponent.hasPrefix("pre-restore-"))
        XCTAssertEqual(savedServers.map(\.label), ["Restored"])
        // The pre-restore backup holds the previous data.
        let previous = try FullBackupParser.read(URL(fileURLWithPath: safety)).get()
        XCTAssertEqual(previous.counts.servers, 2)
        XCTAssertTrue(object["keptPrevious"] is NSNull)
    }

    func testRestoreWithYesDoesNotAsk() async throws {
        let zip = try makeBackup([ServerEntry(label: "R", host: "198.51.100.2")])
        let prompt = PromptLog(answer: false)
        let result = await run(["restore", zip.path, "--yes"], context(prompt: prompt.prompt))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(prompt.questions, [])
        XCTAssertTrue(result.stdout.contains("previous data: none"), result.stdout)   // there was no data yet
        XCTAssertEqual(savedServers.map(\.label), ["R"])
    }

    // MARK: servers

    func testServersListJSONAndText() async throws {
        let none = await run(["servers", "list", "--json"])
        XCTAssertEqual(none.exitCode, 3)
        XCTAssertEqual(try json(none)["error"] as? String, "snapshotMissing")
        try temp.write("home/Library/Application Support/tr.ercanatay.playeridentity/profile.json", "{")
        let corrupt = await run(["servers", "list"])
        XCTAssertEqual(corrupt.exitCode, 2)

        try writeRecord(sampleServers())
        let list = await run(["servers", "list", "--json"])
        XCTAssertEqual(list.exitCode, 0)
        let servers = try XCTUnwrap(try json(list)["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.compactMap { $0["index"] as? Int }, [1, 2])
        XCTAssertEqual(servers.compactMap { $0["host"] as? String }, ["192.0.2.20", "2001:db8::1"])
        XCTAssertEqual(servers[0]["group"] as? String, "Europe")
        XCTAssertEqual(servers[1]["watch"] as? Bool, true)
        let text = await run(["servers", "list"])
        XCTAssertEqual(text.stdout, "1  EU  192.0.2.20:27015  group: Europe  ban: not checked\n"
                                    + "2  Six  [2001:db8::1]:27016  watch  ban: not checked\n")
    }

    func testServersAddUsesTheImportRulesAndBacksUpTheRecord() async throws {
        let noRecord = await run(["servers", "add", "192.0.2.1"])
        XCTAssertEqual(noRecord.exitCode, 3)
        try writeRecord(sampleServers())

        let added = await run(["servers", "add", "https://www.gametracker.com/server_info/Play.Example.com:27017/",
                               "--label", "Demo", "--group", "europe", "--watch", "--json"])
        XCTAssertEqual(added.exitCode, 0, added.stdout)
        let object = try json(added)
        let server = try XCTUnwrap(object["server"] as? [String: Any])
        XCTAssertEqual(server["host"] as? String, "play.example.com")
        XCTAssertEqual(server["port"] as? Int, 27017)
        XCTAssertEqual(server["index"] as? Int, 3)
        XCTAssertNotNil(object["recordBackup"] as? String)
        XCTAssertEqual(savedServers.count, 3)
        let entry = try XCTUnwrap(savedServers.last)
        XCTAssertEqual(entry.label, "Demo")
        XCTAssertEqual(entry.group, "Europe")   // the existing group's spelling
        XCTAssertTrue(entry.watch)
        XCTAssertEqual(entry.order, 2)
        XCTAssertEqual(SnapshotStore(fileURL: paths.snapshotFile).load().snapshot?.savedAt, clock.now)
        XCTAssertEqual(SnapshotStore(fileURL: paths.snapshotFile).load().snapshot?.displayName, "Player")   // rest kept

        let plain = await run(["servers", "add", "steam://connect/192.0.2.30"])
        XCTAssertEqual(plain.exitCode, 0, plain.stderr)
        XCTAssertEqual(savedServers.last?.label, "192.0.2.30")      // label defaults to the host
        XCTAssertEqual(savedServers.last?.port, 27015)

        let duplicate = await run(["servers", "add", "PLAY.example.com:27017", "--json"])
        XCTAssertEqual(duplicate.exitCode, 3)
        XCTAssertEqual(try json(duplicate)["error"] as? String, "alreadyExists")
        for (input, code) in [("2001:db8::5", "ipv6NeedsBrackets"), ("192.0.2.1:70000", "portInvalid"),
                              ("not_a_host", "hostInvalid"), ("ftp://192.0.2.1", "unsupportedURL")] {
            let invalid = await run(["servers", "add", input, "--json"])
            XCTAssertEqual(invalid.exitCode, 2, input)
            XCTAssertEqual(try json(invalid)["error"] as? String, code, input)
        }
        XCTAssertEqual(savedServers.count, 4)
    }

    func testServersRemoveByIndexOrAddressWithConfirmation() async throws {
        try writeRecord(sampleServers() + [ServerEntry(label: "Third", host: "192.0.2.40", order: 2)])

        let noTTY = await run(["servers", "remove", "1", "--json"])
        XCTAssertEqual(noTTY.exitCode, 1)
        XCTAssertEqual(try json(noTTY)["error"] as? String, "confirmationRequired")
        let declined = PromptLog(answer: false)
        let no = await run(["servers", "remove", "[2001:db8::1]:27016"], context(prompt: declined.prompt))
        XCTAssertEqual(no.exitCode, 1)
        XCTAssertEqual(declined.questions, ["Remove server 2 Six ([2001:db8::1]:27016) from the saved record? [y/N] "])
        XCTAssertEqual(savedServers.count, 3)

        for target in ["0", "4", "192.0.2.99", "192.0.2.20:1"] {
            let missing = await run(["servers", "remove", target, "--yes"])
            XCTAssertEqual(missing.exitCode, 3, target)
        }
        let invalid = await run(["servers", "remove", "not a host", "--yes"])
        XCTAssertEqual(invalid.exitCode, 1)

        let accepted = PromptLog(answer: true)
        let byAddress = await run(["servers", "remove", "[2001:db8::1]:27016", "--json"], context(prompt: accepted.prompt))
        XCTAssertEqual(byAddress.exitCode, 0, byAddress.stdout)
        XCTAssertEqual((try json(byAddress)["removed"] as? [String: Any])?["label"] as? String, "Six")
        XCTAssertEqual(savedServers.map(\.label), ["EU", "Third"])

        let byIndex = await run(["servers", "remove", "2", "--yes"])
        XCTAssertEqual(byIndex.exitCode, 0, byIndex.stderr)
        XCTAssertTrue(byIndex.stdout.hasPrefix("removed 2  Third  192.0.2.40:27015\n"), byIndex.stdout)
        XCTAssertEqual(savedServers.map(\.label), ["EU"])
        // Every previous record is kept next to it (two edits in the same second: the second copy gets `-2`).
        let folder = paths.snapshotFile.deletingLastPathComponent()
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(RecordBackup.suffix) }
        let first = RecordBackup.backupURL(for: paths.snapshotFile, at: clock.now).lastPathComponent
        XCTAssertEqual(copies.sorted(), [first, first + "-2"])
        XCTAssertEqual(SnapshotStore.decode(try Data(contentsOf: folder.appendingPathComponent(first))).snapshot?.servers.count, 3)
        XCTAssertEqual(SnapshotStore.decode(try Data(contentsOf: folder.appendingPathComponent(first + "-2"))).snapshot?.servers.count, 2)
    }

    func testServersRemoveRefusesAmbiguousAddresses() async throws {
        try writeRecord([ServerEntry(label: "A", host: "192.0.2.1"), ServerEntry(label: "B", host: "192.0.2.1")])
        let result = await run(["servers", "remove", "192.0.2.1", "--yes", "--json"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(try json(result)["error"] as? String, "ambiguous")
        XCTAssertEqual(savedServers.count, 2)
    }

    // MARK: diagnostics

    func testDiagnosticsWritesTheRedactedPackage() async throws {
        try writeRecord(sampleServers())
        let suite = "CLIDataTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UpdateState(lastCheck: Self.t0, latest: nil, ignoredVersion: "2.0.0").save(to: defaults)

        let result = await run(["diagnostics", "--json"], context(suite: suite))
        XCTAssertEqual(result.exitCode, 0, result.stdout)
        let object = try json(result)
        let path = try XCTUnwrap(object["path"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, DiagnosticsBundle.defaultFileName(now: clock.now))
        XCTAssertEqual(object["files"] as? [String], DiagnosticsBundle.fileNames)
        let files = try XCTUnwrap(ZipArchive.read(try Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(files.map(\.name), DiagnosticsBundle.fileNames)
        let snapshot = String(decoding: try XCTUnwrap(files.first { $0.name == "snapshot.redacted.json" }).data, as: UTF8.self)
        XCTAssertFalse(snapshot.contains("198.51.100.7"))
        XCTAssertTrue(snapshot.contains("198.51.x.x"))
        let update = String(decoding: try XCTUnwrap(files.first { $0.name == "update-state.json" }).data, as: UTF8.self)
        XCTAssertTrue(update.contains("2.0.0"), update)
        let appInfo = String(decoding: try XCTUnwrap(files.first { $0.name == "app-info.json" }).data, as: UTF8.self)
        XCTAssertTrue(appInfo.contains("3.0.0"))
        XCTAssertNotNil(files.first { $0.name == "errors.json" })

        let again = await run(["diagnostics", "--out", path])
        XCTAssertEqual(again.exitCode, 1)   // never overwritten
    }
}

import XCTest
@testable import PlayerIdentity

/// §67.1 `playeridentityctl diagnose | trend | report`: parsing, text and JSON output (`schemaVersion: 1`), exit codes
/// (0 / 4 / 1 / 2 / 3), the history line, the engine log, index targets and the Markdown report. In-process with a
/// fake UDP transport and resolver (no network) and a temporary home.
final class CLIDiagnoseTests: XCTestCase {
    private static let fixtureCID = "d9de0eb4419608a8423241430581e91c"   // raw ID 0 + 51.68.190.91 (§4)
    private static let savedID = UUID(uuidString: "1E390D91-9114-454E-A9B3-4AB1833ACD48")!   // "Example EU" of the fixture
    private var temp: TempDirectory!
    private let clock = TestClock()
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
    private var historyFile: URL { AppPaths(home: home).historyFile }

    private func context(udp: FakeUDPTransport? = nil, resolver: FakeAddressResolver = FakeAddressResolver(),
                         snapshot: URL? = nil) -> CLIContext {
        let clock = self.clock
        var context = CLIContext(version: "2.17.1", build: "45", paths: AppPaths(home: home),
                                 environment: snapshot.map { [CLIContext.snapshotEnvironmentKey: $0.path] } ?? [:],
                                 fileSystem: LocalFileSystem(), resolver: resolver,
                                 udpTransport: udp ?? FakeServer.healthy(clock: clock), now: { clock.now })
        context.vpnActive = { false }
        return context
    }

    private func run(_ arguments: [String], _ context: CLIContext? = nil) async -> CLIResult {
        await CLIRunner.run(arguments: arguments, context: context ?? self.context())
    }

    private func json(_ result: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        return try XCTUnwrap(object, result.stdout + result.stderr, file: file, line: line)
    }

    private func writeIdentity() throws {
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")   // raw ID 0
    }

    /// Healthy server with a full A2S answer → `noBan`.
    private func cleanServer() -> FakeUDPTransport {
        FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: A2SFixture.xash())))
    }

    private func cidBannedServer() -> FakeUDPTransport {
        FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: A2SFixture.xash()),
            connect: FakeReply(bytes: FakeServer.oobText("errormsg\nYou are banned (CID)\n"))))
    }

    /// The `cli-status-profile` record (Example EU at 192.0.2.20:27015, index 1) with its data root in the temp folder.
    private func savedRecord() throws -> URL {
        let source = try XCTUnwrap(Bundle(for: CLIDiagnoseTests.self).url(forResource: "cli-status-profile", withExtension: "json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        object["dataRoot"] = temp.url.appendingPathComponent("data", isDirectory: true).path
        let url = temp.url.appendingPathComponent("record/profile.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func diagnoseLine(_ id: UUID, _ verdict: DiagnosisVerdict, daysAgo: Double, old: DiagnosisVerdict? = nil,
                              ms: Int? = 900) -> HistoryEntry {
        HistoryEntry(ts: clock.now.addingTimeInterval(-daysAgo * day), kind: .diagnose, serverID: id,
                     host: "51.68.190.91:27015", old: old?.rawValue, new: verdict.rawValue,
                     note: "dns=ok a2sInfo=ok getChallenge=ok connect49=failed", durationMs: ms)
    }

    // MARK: Parsing

    func testParsing() {
        XCTAssertEqual(CLIParser.parse(["diagnose", "192.0.2.1:27016"]),
                       .success(.diagnose(target: "192.0.2.1:27016", timeout: 5, json: false, failOnBan: false)))
        XCTAssertEqual(CLIParser.parse(["diagnose", "2", "--timeout", "2", "--json", "--fail-on-ban"]),
                       .success(.diagnose(target: "2", timeout: 2, json: true, failOnBan: true)))
        XCTAssertEqual(CLIParser.parse(["trend", "192.0.2.1"]), .success(.trend(target: "192.0.2.1", window: .week, json: false)))
        XCTAssertEqual(CLIParser.parse(["trend", "192.0.2.1", "--days", "30", "--json"]),
                       .success(.trend(target: "192.0.2.1", window: .month, json: true)))
        XCTAssertEqual(CLIParser.parse(["report", "1", "--days=all", "--unmasked", "--out", "-"]),
                       .success(.report(target: "1", window: .all, unmasked: true, out: "-")))
        XCTAssertEqual(CLIParser.parse(["report", "[2001:db8::1]:27016"]),
                       .success(.report(target: "[2001:db8::1]:27016", window: .week, unmasked: false, out: nil)))

        let usageErrors: [[String]] = [
            ["diagnose"], ["diagnose", "a", "b"], ["diagnose", "not a host"], ["diagnose", "192.0.2.1:0"],
            ["diagnose", "192.0.2.1", "--timeout", "0"], ["diagnose", "192.0.2.1", "--timeout", "31"],
            ["diagnose", "192.0.2.1", "--days", "7"], ["diagnose", "192.0.2.1", "--unmasked"],
            ["trend", "192.0.2.1", "--days", "14"], ["trend", "192.0.2.1", "--fail-on-ban"], ["trend", "192.0.2.1", "--out", "x"],
            ["trend", "192.0.2.1", "--timeout", "3"], ["report", "192.0.2.1", "--json"], ["report", "192.0.2.1", "--out", " "],
            ["ban", "192.0.2.1", "--fail-on-ban"], ["status", "--days", "7"], ["report", "192.0.2.1", "--yes"],
        ]
        for arguments in usageErrors {
            guard case .failure = CLIParser.parse(arguments) else {
                XCTFail("expected usage error: \(arguments)")
                continue
            }
        }
    }

    func testHelpListsTheNewCommandsAndExitCodes() async {
        let help = await run(["--help"])
        for text in ["diagnose <host:port|index>", "--fail-on-ban", "trend <host:port|index> [--days 7|30|all]",
                     "report <host:port|index>", "--unmasked", "4 ban verdict with diagnose --fail-on-ban"] {
            XCTAssertTrue(help.stdout.contains(text), text)
        }
        let usage = await run(["diagnose"])
        XCTAssertEqual(usage.exitCode, 1)
        XCTAssertTrue(usage.stderr.contains("diagnose needs exactly one <host:port|index>"))
    }

    // MARK: diagnose

    func testDiagnoseTextJSONAndHistoryLine() async throws {
        try writeIdentity()
        let text = await run(["diagnose", "51.68.190.91:27015"], context(udp: cleanServer()))
        XCTAssertEqual(text.exitCode, 0, text.stderr)
        XCTAssertTrue(text.stdout.hasPrefix("server:   51.68.190.91:27015\nverdict:  noBan"), text.stdout)
        for step in ["dns", "a2sInfo", "getChallenge", "connect49"] {
            XCTAssertTrue(text.stdout.contains("  \(step)"), step)
        }
        XCTAssertTrue(text.stdout.contains("engine log: none (start Xash3D with -condebug"), text.stdout)
        XCTAssertNil(text.stdout.rangeOfCharacter(from: CharacterSet(charactersIn: "çğıİöşü")), "English texts")

        let lines = HistoryStore(fileURL: historyFile).load()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.kind, .diagnose)
        XCTAssertEqual(lines.first?.new, "noBan")
        XCTAssertEqual(lines.first?.serverID, MetricSample.stableServerID(host: "51.68.190.91", port: 27015))
        XCTAssertEqual(lines.first?.note, "dns=ok a2sInfo=ok getChallenge=ok connect49=ok")

        clock.advance(60)
        let result = await run(["diagnose", "51.68.190.91", "--json"], context(udp: cleanServer()))
        let object = try json(result)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["command"] as? String, "diagnose")
        XCTAssertEqual(object["verdict"] as? String, "noBan")
        XCTAssertEqual(object["banned"] as? Bool, false)
        XCTAssertEqual(object["cid"] as? String, Self.fixtureCID)
        let server = try XCTUnwrap(object["server"] as? [String: Any])
        XCTAssertEqual(server["host"] as? String, "51.68.190.91")
        XCTAssertEqual(server["port"] as? Int, 27015)
        XCTAssertTrue(server["index"] is NSNull)
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["step"] as? String }, ["dns", "a2sInfo", "getChallenge", "connect49"])
        XCTAssertEqual(Set(steps.map { $0.keys.sorted() }), [["detail", "durationMs", "status", "step", "target"]])
        XCTAssertEqual((object["engineLog"] as? [String: Any])?["status"] as? String, "missing")
        XCTAssertEqual(HistoryStore(fileURL: historyFile).load().count, 2)
    }

    func testDiagnoseExitCodes() async throws {
        try writeIdentity()
        // A ban verdict is a successful diagnosis: 0, or 4 with --fail-on-ban.
        let ban = await run(["diagnose", "51.68.190.91", "--json"], context(udp: cidBannedServer()))
        XCTAssertEqual(ban.exitCode, 0)
        XCTAssertEqual(try json(ban)["verdict"] as? String, "cidBanned")
        XCTAssertEqual(try json(ban)["banned"] as? Bool, true)
        let failing = await run(["diagnose", "51.68.190.91", "--fail-on-ban"], context(udp: cidBannedServer()))
        XCTAssertEqual(failing.exitCode, 4)
        XCTAssertTrue(failing.stdout.contains("verdict:  cidBanned"))

        let ipBanned = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8)))))
        let ip = await run(["diagnose", "192.0.2.1", "--fail-on-ban", "--json"], context(udp: ipBanned))
        XCTAssertEqual(ip.exitCode, 4)
        XCTAssertEqual(try json(ip)["verdict"] as? String, "ipBanned")

        let clean = await run(["diagnose", "51.68.190.91", "--fail-on-ban"], context(udp: cleanServer()))
        XCTAssertEqual(clean.exitCode, 0, "no ban → 0 even with --fail-on-ban")

        // An unknown host is a verdict (dnsFailure), not an error; no network at all is 2.
        let dns = await run(["diagnose", "missing.example.com:27015", "--json"])
        XCTAssertEqual(dns.exitCode, 0)
        XCTAssertEqual(try json(dns)["verdict"] as? String, "dnsFailure")
        let offline = await run(["diagnose", "offline.example.com", "--json"],
                                context(resolver: FakeAddressResolver(["offline.example.com": .failure(.network)])))
        XCTAssertEqual(offline.exitCode, 2)
        XCTAssertEqual(try json(offline)["networkUnavailable"] as? Bool, true)

        // --timeout is the step timeout (silent server: total ≤ 4 × 1 s).
        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let start = clock.now
        let slow = await run(["diagnose", "192.0.2.9", "--timeout", "1", "--json"], context(udp: silent))
        XCTAssertEqual(try json(slow)["verdict"] as? String, "serverOffline")
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(start), 4.01)

        // Index without a record / out of range → 3; a bad target reaching the runner → 1.
        let noRecord = await run(["diagnose", "1", "--json"])
        XCTAssertEqual(noRecord.exitCode, 3)
        XCTAssertEqual(try json(noRecord)["error"] as? String, "snapshotMissing")
        let record = try savedRecord()
        let missing = await run(["diagnose", "9"], context(snapshot: record))
        XCTAssertEqual(missing.exitCode, 3)
        XCTAssertTrue(missing.stderr.contains("no server with index 9 (the list has 2)"))
        let invalid = await CLIRunner.diagnose(target: "not a host", timeout: 1, json: false, failOnBan: false,
                                               context: context())
        XCTAssertEqual(invalid.exitCode, 1)
    }

    func testDiagnoseByIndexUsesTheSavedServerAndTheEngineLog() async throws {
        let record = try savedRecord()
        try temp.write("data/valve/qconsole.log", "Connecting to 192.0.2.20:27015...\nYour IP is banned from this server\n")
        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let result = await run(["diagnose", "1", "--json"], context(udp: silent, snapshot: record))
        let object = try json(result)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(object["verdict"] as? String, "ipBanned", "the engine log decides over serverOffline (§64.3)")
        XCTAssertEqual(object["probeVerdict"] as? String, "serverOffline")
        XCTAssertEqual(object["verdictFromLog"] as? Bool, true)
        let server = try XCTUnwrap(object["server"] as? [String: Any])
        XCTAssertEqual(server["label"] as? String, "Example EU")
        XCTAssertEqual(server["index"] as? Int, 1)
        XCTAssertEqual(server["id"] as? String, Self.savedID.uuidString)
        let log = try XCTUnwrap(object["engineLog"] as? [String: Any])
        XCTAssertEqual(log["status"] as? String, "found")
        XCTAssertEqual(log["fileName"] as? String, "qconsole.log")
        XCTAssertEqual((log["matches"] as? [[String: Any]])?.first?["pattern"] as? String, "ipBanned")

        // The line goes next to the record, under the saved server's id; the record itself is unchanged.
        let next = record.deletingLastPathComponent().appendingPathComponent("history.jsonl")
        XCTAssertEqual(HistoryStore(fileURL: next).load().map(\.serverID), [Self.savedID])
        XCTAssertEqual(HistoryStore(fileURL: next).load().first?.old, "serverOffline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile.path))

        // `host:port` of a saved server is the same target as its index.
        let text = await run(["diagnose", "192.0.2.20:27015"], context(udp: silent, snapshot: record))
        XCTAssertTrue(text.stdout.hasPrefix("server:   Example EU (192.0.2.20:27015)"), text.stdout)
        XCTAssertTrue(text.stdout.contains("decided by the engine log; the probe found serverOffline"))
        XCTAssertTrue(text.stdout.contains("Your IP is banned"))
    }

    // MARK: trend

    func testTrendWithoutDataIsAnEmptySuccess() async throws {
        let result = await run(["trend", "51.68.190.91", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let object = try json(result)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["command"] as? String, "trend")
        XCTAssertEqual(object["runs"] as? Int, 0)
        XCTAssertEqual(object["days"] as? String, "7")
        XCTAssertEqual((object["counts"] as? [String: Any])?.count, 0)
        XCTAssertEqual((object["strip"] as? [String])?.count, 0)
        XCTAssertTrue(object["lastRun"] is NSNull)
        let text = await run(["trend", "51.68.190.91"])
        XCTAssertEqual(text.exitCode, 0)
        XCTAssertTrue(text.stdout.contains("no diagnosis for this server yet"), text.stdout)

        let unknownIndex = await run(["trend", "3"], context(snapshot: try savedRecord()))
        XCTAssertEqual(unknownIndex.exitCode, 3)
    }

    func testTrendCountsWindowsAndStrip() async throws {
        let id = MetricSample.stableServerID(host: "51.68.190.91", port: 27015)
        try HistoryStore(fileURL: historyFile).append([
            diagnoseLine(id, .noBan, daysAgo: 20),
            diagnoseLine(id, .cidBanned, daysAgo: 3),
            diagnoseLine(id, .timeout, daysAgo: 2),
            diagnoseLine(id, .cidBanned, daysAgo: 1),
            diagnoseLine(UUID(), .ipBanned, daysAgo: 1),   // another server
            HistoryEntry(ts: clock.now, kind: .refresh, serverID: id),
        ])
        let week = try json(await run(["trend", "51.68.190.91:27015", "--json"]))
        XCTAssertEqual(week["runs"] as? Int, 3)
        XCTAssertEqual(week["totalRuns"] as? Int, 4)
        XCTAssertEqual(week["counts"] as? [String: Int], ["cidBanned": 2, "timeout": 1])
        XCTAssertEqual(week["strip"] as? [String], ["cidBanned", "timeout", "cidBanned"])
        let all = try json(await run(["trend", "51.68.190.91", "--days", "all", "--json"]))
        XCTAssertEqual(all["runs"] as? Int, 4)
        XCTAssertEqual(all["days"] as? String, "all")
        XCTAssertEqual((all["strip"] as? [String])?.first, "noBan", "oldest first")

        let text = await run(["trend", "51.68.190.91", "--days", "30"])
        XCTAssertEqual(text.exitCode, 0)
        XCTAssertTrue(text.stdout.contains("period:   last 30 days"))
        XCTAssertTrue(text.stdout.contains("runs:     4"))
        XCTAssertTrue(text.stdout.contains("verdicts: cidBanned 2, timeout 1, noBan 1"), text.stdout)

        // A diagnosis made by the CLI shows up in its trend.
        try writeIdentity()
        _ = await run(["diagnose", "51.68.190.91"], context(udp: cidBannedServer()))
        let after = try json(await run(["trend", "51.68.190.91", "--json"]))
        XCTAssertEqual(after["runs"] as? Int, 4)
        XCTAssertEqual((after["strip"] as? [String])?.last, "cidBanned")
    }

    // MARK: report

    func testReportNeedsADiagnosis() async throws {
        let result = await run(["report", "51.68.190.91", "--out", "-"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("no diagnosis of 51.68.190.91:27015"), result.stderr)
    }

    func testReportMarkdownMaskingAndOutput() async throws {
        try writeIdentity()
        let id = MetricSample.stableServerID(host: "51.68.190.91", port: 27015)
        try HistoryStore(fileURL: historyFile).append([diagnoseLine(id, .noBan, daysAgo: 2, ms: 700)])
        _ = await run(["diagnose", "51.68.190.91"], context(udp: cidBannedServer()))

        let masked = await run(["report", "51.68.190.91", "--out", "-"])
        XCTAssertEqual(masked.exitCode, 0, masked.stderr)
        let report = masked.stdout
        XCTAssertTrue(report.hasPrefix("# Connection diagnosis — 51.68.190.91:27015\n"), report)
        XCTAssertTrue(report.contains(": Cybokron Player Identity 2.17.1"), "English app texts")
        XCTAssertTrue(report.contains("`cidBanned`"))
        XCTAssertTrue(report.contains("CID and IP are masked."))
        XCTAssertTrue(report.contains("`d9de0eb4…e91c`"), report)
        XCTAssertFalse(report.contains(Self.fixtureCID))
        XCTAssertTrue(report.contains("| `connect49` | failed | — |"), "durations are not kept in the history line")
        XCTAssertTrue(report.contains("## History (last 10 runs)"))
        XCTAssertTrue(report.contains("`noBan`"), "the earlier run is in the history table")
        XCTAssertTrue(report.contains("No engine log found."))

        let unmasked = await run(["report", "51.68.190.91", "--unmasked", "--out", "-"])
        XCTAssertTrue(unmasked.stdout.contains(Self.fixtureCID))
        XCTAssertFalse(unmasked.stdout.contains("CID and IP are masked."))

        // Default target: ~/Documents/playeridentity-diagnose-<host>-<time>.md; never overwritten.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let saved = await run(["report", "51.68.190.91"])
        XCTAssertEqual(saved.exitCode, 0, saved.stderr)
        let path = try XCTUnwrap(saved.stdout.split(separator: "\n").first?.replacingOccurrences(of: "report: ", with: ""))
        XCTAssertTrue(path.hasPrefix(home.appendingPathComponent("Documents").path + "/playeridentity-diagnose-51.68.190.91-"), path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), report)
        let again = await run(["report", "51.68.190.91"])
        XCTAssertEqual(again.exitCode, 1, "an existing file is never overwritten")

        let folder = temp.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inFolder = await run(["report", "51.68.190.91", "--days", "all", "--out", folder.path])
        XCTAssertEqual(inFolder.exitCode, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        let noFolder = await run(["report", "51.68.190.91", "--out", temp.url.appendingPathComponent("nope/r.md").path])
        XCTAssertEqual(noFolder.exitCode, 2)
    }

    func testRecordedDiagnosisKeepsTheWrittenVerdict() throws {
        let target = CLIServerTarget(host: "198.51.100.20", port: 27015, serverID: UUID(), label: "Zombie TR", index: 1,
                                     savedCID: "")
        let entry = HistoryEntry(ts: clock.now, kind: .diagnose, serverID: target.serverID, host: "198.51.100.20:27015",
                                 old: "serverOffline", new: "ipBanned", note: "dns=ok a2sInfo=failed bogus getChallenge=failed",
                                 durationMs: 1200)
        // The log read now has no ban line: the written verdict (from the log at the time) still stands.
        let diagnosis = try XCTUnwrap(ConnectionDiagnosis(recorded: entry, target: target,
                                                          engineLog: EngineLogReport(status: .missing), cid: nil,
                                                          publicIP: "203.0.113.7"))
        XCTAssertEqual(diagnosis.verdict, .ipBanned)
        XCTAssertEqual(diagnosis.probeVerdict, .serverOffline)
        XCTAssertTrue(diagnosis.verdictFromLog)
        XCTAssertEqual(diagnosis.steps.map(\.step), [.dns, .a2sInfo, .getChallenge])
        XCTAssertEqual(diagnosis.steps.map(\.durationMs), Array(repeating: DiagnosisStep.unknownDuration, count: 3))
        XCTAssertEqual(diagnosis.durationMs, 1200)
        XCTAssertNil(ConnectionDiagnosis(recorded: HistoryEntry(ts: clock.now, kind: .refresh), target: target,
                                         engineLog: .missing, cid: nil, publicIP: nil))
    }
}

import AppKit
import XCTest
@testable import PlayerIdentity

/// §64 connection diagnosis: every step and verdict with fake carriers (no network), timing and order, the engine
/// log (patterns, missing/unreadable, priority, read-only), the masked report, cancellation and "no network".
final class ConnectionDiagnosticsTests: XCTestCase {
    private let server = "198.51.100.20"
    private let rawID: UInt64 = 0x1033_1C2D_CE4C_91DB

    override func tearDown() {
        L10n.setting = .system
        super.tearDown()
    }

    private func request(host: String? = nil, rawID: UInt64?? = nil, checks: Bool = true, vpn: Bool = false,
                         range: String? = nil) -> ConnectionDiagnosisRequest {
        ConnectionDiagnosisRequest(host: host ?? server, port: 27015, rawID: rawID ?? self.rawID, name: "Tester",
                                   checksEnabled: checks, vpnActive: vpn, knownRange: range)
    }

    private func diagnoser(_ transport: any UDPTransport, clock: TestClock = TestClock(),
                           resolver: FakeAddressResolver = FakeAddressResolver(),
                           total: TimeInterval = ConnectionDiagnoser.totalTimeout) -> ConnectionDiagnoser {
        ConnectionDiagnoser(transport: transport, resolver: resolver, now: { clock.now }, qport: { 27005 },
                            totalTimeout: total)
    }

    private func run(info: FakeReply? = FakeReply(bytes: FakeServer.oob(0x49, [0x30])),
                     challenge: FakeReply? = FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes)),
                     connect: FakeReply? = FakeReply(bytes: FakeServer.oob(0x42)),
                     request: ConnectionDiagnosisRequest? = nil) async throws -> (ConnectionProbeResult, FakeUDPTransport) {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: info, challenge: challenge,
                                                                                       connect: connect))
        let result = try await diagnoser(transport, clock: clock).run(request ?? self.request())
        return (result, transport)
    }

    private func statuses(_ result: ConnectionProbeResult) -> [DiagnosisStepStatus] { result.steps.map(\.status) }

    // MARK: (a) steps and verdicts

    func testHealthyServerIsNoBanWithEveryStepOK() async throws {
        let (result, transport) = try await run()
        XCTAssertEqual(result.verdict, .noBan)
        XCTAssertEqual(result.steps.map(\.step), DiagnosisStepKind.allCases)
        XCTAssertEqual(statuses(result), [.ok, .ok, .ok, .ok])
        XCTAssertEqual(result.address, server)
        XCTAssertEqual(result.cid, CIDCalculator.cid(rawID: rawID, host: server))
        XCTAssertEqual(result.steps[1].target, "\(server):27015")
        XCTAssertEqual(transport.sessionCount, 1)
        XCTAssertEqual(transport.sentCount, 3)
        XCTAssertTrue(transport.sentPackets[2].starts(with: BanPackets.header + Array("connect 49 ".utf8)))
    }

    func testDNSFailureSkipsEveryLaterStepAndSendsNothing() async throws {
        let transport = FakeServer.healthy()
        let resolver = FakeAddressResolver(["nowhere.example": .failure(.notFound)])
        let result = try await diagnoser(transport, resolver: resolver).run(request(host: "nowhere.example"))
        XCTAssertEqual(result.verdict, .dnsFailure)
        XCTAssertEqual(statuses(result), [.failed, .skipped, .skipped, .skipped])
        XCTAssertEqual(result.steps[0].detail, "notFound")
        XCTAssertEqual(transport.sentCount, 0)
    }

    func testHostnameResolvesIPv4FirstAndInvalidHostFails() async throws {
        let resolver = FakeAddressResolver(["cs.example": .success([TestAddresses.v6("2001:db8::1"), TestAddresses.v4(server)])])
        let ok = try await diagnoser(FakeServer.healthy(), resolver: resolver).run(request(host: "cs.example"))
        XCTAssertEqual(ok.address, server)
        XCTAssertEqual(ok.steps[0].detail, "IPv4 \(server)")
        let invalid = try await diagnoser(FakeServer.healthy()).run(request(host: "bad host!"))
        XCTAssertEqual(invalid.verdict, .dnsFailure)
        XCTAssertEqual(invalid.steps[0].detail, "invalidHost")
    }

    func testNoReplyAtAllIsServerOffline() async throws {
        let (result, _) = try await run(info: nil, challenge: nil, connect: nil)
        XCTAssertEqual(result.verdict, .serverOffline)
        XCTAssertEqual(statuses(result), [.ok, .failed, .failed, .skipped])
    }

    func testInfoButNoChallengeIsTimeoutOrVPNConflict() async throws {
        let (plain, _) = try await run(challenge: nil, connect: nil)
        XCTAssertEqual(plain.verdict, .timeout)
        let (vpn, _) = try await run(challenge: nil, connect: nil, request: request(vpn: true))
        XCTAssertEqual(vpn.verdict, .vpnConflict)
    }

    func testGetChallengeBannedIsIPBannedOrRangeBanned() async throws {
        let banned = FakeReply(bytes: FakeServer.oobText("9You are banned from this server"))
        let (ip, transport) = try await run(challenge: banned)
        XCTAssertEqual(ip.verdict, .ipBanned)
        XCTAssertEqual(statuses(ip), [.ok, .ok, .failed, .skipped])
        XCTAssertTrue(ip.steps[2].detail.hasPrefix("banned: "))
        XCTAssertEqual(transport.sentCount, 2, "no connect after an IP ban")
        let (range, _) = try await run(challenge: banned, request: request(range: "198.51.0.0/16"))
        XCTAssertEqual(range.verdict, .rangeBanned)
    }

    func testConnectRepliesMapToCIDVerdicts() async throws {
        let (cid, _) = try await run(connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned (CID)")))
        XCTAssertEqual(cid.verdict, .cidBanned)
        XCTAssertEqual(statuses(cid), [.ok, .ok, .ok, .failed])
        let (proto, _) = try await run(connect: FakeReply(bytes: FakeServer.oobText("errormsg Unsupported protocol 48")))
        XCTAssertEqual(proto.verdict, .protocolMismatch)
        let (odd, _) = try await run(connect: FakeReply(bytes: FakeServer.oobText("print hello")))
        XCTAssertEqual(odd.verdict, .cidUnverified)
        let (silent, _) = try await run(connect: nil)
        XCTAssertEqual(silent.verdict, .cidUnverified)
        let (silentVPN, _) = try await run(connect: nil, request: request(vpn: true))
        XCTAssertEqual(silentVPN.verdict, .vpnConflict)
    }

    func testUnrecognizedChallengeAndMissingCIDAreUnverified() async throws {
        let (odd, _) = try await run(challenge: FakeReply(bytes: FakeServer.oobText("print what")))
        XCTAssertEqual(odd.verdict, .cidUnverified)
        let (noCID, transport) = try await run(request: request(rawID: .some(nil)))
        XCTAssertEqual(noCID.verdict, .cidUnverified)
        XCTAssertEqual(statuses(noCID), [.ok, .ok, .ok, .skipped])
        XCTAssertNil(noCID.cid)
        XCTAssertEqual(transport.sentCount, 2)
    }

    func testChecksDisabledSendsNoPacket() async throws {
        let (result, transport) = try await run(request: request(checks: false))
        XCTAssertEqual(result.verdict, .checksDisabled)
        XCTAssertEqual(statuses(result), [.ok, .skipped, .skipped, .skipped])
        XCTAssertEqual(transport.sessionCount, 0)
        XCTAssertEqual(transport.sentCount, 0)
    }

    /// "Ban yok" only when steps 2–4 are all `ok`.
    func testNoBanOnlyWhenStepsTwoToFourAreOK() {
        var facts = DiagnosisFacts(dns: .resolved, info: .replied, challenge: .challenge, connect: .ok)
        XCTAssertEqual(DiagnosisClassifier.verdict(facts), .noBan)
        facts.info = .noReply
        XCTAssertNotEqual(DiagnosisClassifier.verdict(facts), .noBan)
        XCTAssertEqual(Set(DiagnosisVerdict.allCases.map(\.rawValue)),
                       ["serverOffline", "dnsFailure", "timeout", "protocolMismatch", "ipBanned", "cidBanned", "rangeBanned",
                        "cidUnverified", "vpnConflict", "checksDisabled", "noBan"])
        for verdict in DiagnosisVerdict.allCases {
            XCTAssertFalse(verdict.sentence.isEmpty)
            XCTAssertFalse(verdict.advice.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: verdict.symbolName, accessibilityDescription: nil), verdict.rawValue)
        }
    }

    // MARK: (b) timing and order

    func testDurationsAndProgressOrder() async throws {
        let clock = TestClock()
        let transport = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: FakeServer.oob(0x49, [0x30]), delay: 0.04),
            challenge: FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes), delay: 0.12),
            connect: nil))
        let events = EventLog()
        let result = try await diagnoser(transport, clock: clock).run(request()) { await events.add($0) }
        XCTAssertEqual(result.steps.map(\.durationMs), [0, 40, 120, 5000])   // the silent connect waits its 5 s
        XCTAssertEqual(result.info?.pingMillis, 40)
        let recorded = await events.items
        XCTAssertEqual(recorded, [.started(.dns), .finished(result.steps[0]), .started(.a2sInfo), .finished(result.steps[1]),
                                  .started(.getChallenge), .finished(result.steps[2]), .started(.connect49),
                                  .finished(result.steps[3])])
    }

    func testStepTimeoutIsFiveSecondsAndTotalBudgetSkipsTheRest() async throws {
        XCTAssertEqual(ConnectionDiagnoser.stepTimeout, 5)
        XCTAssertEqual(ConnectionDiagnoser.totalTimeout, 20)
        let clock = TestClock()
        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let offline = try await diagnoser(silent, clock: clock).run(request())
        XCTAssertEqual(offline.steps.map(\.durationMs), [0, 5000, 5000, 0])

        let budgetClock = TestClock()
        let budget = FakeUDPTransport(clock: budgetClock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let result = try await diagnoser(budget, clock: budgetClock, total: 5).run(request())
        XCTAssertEqual(statuses(result), [.ok, .failed, .skipped, .skipped])
        XCTAssertEqual(result.steps[2].detail, "totalTimeout")
        XCTAssertTrue(result.facts.totalTimedOut)
        XCTAssertEqual(result.verdict, .timeout)
    }

    // MARK: (c) engine log

    private func logReport(_ contents: String?, file: String = "qconsole.log", gamedir: String? = "valve",
                           home: URL? = nil) throws -> (EngineLogReport, TempDirectory) {
        let temp = try TempDirectory()
        if let contents { try temp.write("root/valve/\(file)", contents) }
        let report = EngineLogReader.read(dataRoot: temp.url.appendingPathComponent("root"), gamedir: gamedir,
                                          fileSystem: LocalFileSystem(), redactor: Redactor(home: home))
        return (report, temp)
    }

    func testEveryPatternMatchesWithLineNumberAndExplanation() throws {
        let lines = EngineLogPattern.allCases.map { "]  \($0.needle.uppercased()) — sample" }
        let (report, _) = try logReport((["Loading map", ""] + lines).joined(separator: "\n") + "\n")
        XCTAssertEqual(report.status, .found)
        XCTAssertEqual(report.fileName, "qconsole.log")
        XCTAssertEqual(Set(report.matches.map(\.pattern)), Set(EngineLogPattern.allCases))
        XCTAssertEqual(report.matches.first?.matchedAt, 3)
        for pattern in EngineLogPattern.allCases { XCTAssertFalse(pattern.explanation.isEmpty) }
    }

    func testRawLineIsRedactedAndCombinedLinesKeepTheDirectStatement() throws {
        let (report, _) = try logReport("Couldn't connect to 203.0.113.7:27015: Your IP is banned\n")
        XCTAssertEqual(report.matches.count, 1)
        XCTAssertEqual(report.matches[0].pattern, .ipBanned)
        XCTAssertFalse(report.matches[0].line.contains("203.0.113.7"))
        XCTAssertTrue(report.matches[0].line.contains("203.0.x.x"))
    }

    func testConsoleLogFallbackMissingAndUnreadable() throws {
        let (fallback, _) = try logReport("Server is not responding\n", file: "console.log")
        XCTAssertEqual(fallback.fileName, "console.log")
        XCTAssertEqual(fallback.matches.map(\.pattern), [.serverNotResponding])
        let (missing, _) = try logReport(nil)
        XCTAssertEqual(missing, .missing)
        let (noGamedir, _) = try logReport("Bad challenge", gamedir: nil)
        XCTAssertEqual(noGamedir.status, .missing)
        let unreadable = EngineLogReader.read(dataRoot: URL(fileURLWithPath: "/r"), gamedir: "valve",
                                              fileSystem: UnreadableLog(), redactor: Redactor())
        XCTAssertEqual(unreadable.status, .unreadable)
        XCTAssertEqual(unreadable.fileName, "qconsole.log")
        L10n.setting = .en
        XCTAssertEqual(DiagnosisReport.logLines(.missing), ["No engine log found. Run Xash3D with -condebug."])
    }

    func testOnlyTheLast512KBAndTheLast200LinesAreScanned() throws {
        let filler = String(repeating: "x", count: 99) + "\n"
        let big = "Your IP is banned\n" + String(repeating: filler, count: 6_000) + "Bad challenge\n"
        XCTAssertGreaterThan(big.utf8.count, EngineLogReader.maxBytes)
        let (report, _) = try logReport(big)
        XCTAssertEqual(report.matches.map(\.pattern), [.badChallenge])
        XCTAssertEqual(report.scannedLines, 200)

        let lines = ["Connection reset"] + Array(repeating: "ok", count: 250) + ["host_error: x"]
        let (tail, _) = try logReport(lines.joined(separator: "\n"))
        XCTAssertEqual(tail.matches.map(\.pattern), [.hostError])
        XCTAssertEqual(tail.matches.first?.matchedAt, 200)
    }

    func testTheLogIsNeverWritten() throws {
        let (_, temp) = try logReport("Couldn't connect\n")
        let file = temp.url.appendingPathComponent("root/valve/qconsole.log")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        _ = EngineLogReader.read(dataRoot: temp.url.appendingPathComponent("root"), gamedir: "valve",
                                 fileSystem: LocalFileSystem(), redactor: Redactor())
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["qconsole.log"])
        // A missing log is not created.
        _ = EngineLogReader.read(dataRoot: temp.url.appendingPathComponent("other"), gamedir: "valve",
                                 fileSystem: LocalFileSystem(), redactor: Redactor())
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("other").path))
    }

    // MARK: (d) engine log priority

    func testDirectEngineStatementsOverrideTheProbeVerdict() {
        func log(_ patterns: [EngineLogPattern]) -> EngineLogReport {
            EngineLogReport(status: .found, fileName: "qconsole.log",
                            matches: patterns.enumerated().map { EngineLogMatch(pattern: $1, matchedAt: $0 + 1, line: "") })
        }
        XCTAssertEqual(DiagnosisClassifier.final(probe: .serverOffline, log: log([.ipBanned])), .ipBanned)
        XCTAssertEqual(DiagnosisClassifier.final(probe: .timeout, log: log([.banned])), .cidBanned)
        XCTAssertEqual(DiagnosisClassifier.final(probe: .timeout, log: log([.ipBanned, .banned])), .cidBanned, "newest wins")
        XCTAssertEqual(DiagnosisClassifier.final(probe: .serverOffline, log: log([.couldntConnect, .badChallenge])),
                       .serverOffline, "other patterns are evidence only")
        XCTAssertEqual(DiagnosisClassifier.final(probe: .noBan, log: log([.ipBanned])), .noBan, "steps 2–4 proved no ban")
        XCTAssertEqual(DiagnosisClassifier.final(probe: .rangeBanned, log: log([.banned])), .rangeBanned)
        XCTAssertEqual(DiagnosisClassifier.final(probe: .serverOffline, log: .missing), .serverOffline)
    }

    // MARK: (e) report masking

    private func sampleDiagnosis() async throws -> ConnectionDiagnosis {
        let banned = FakeReply(bytes: FakeServer.oobText("9Disconnect: banned 203.0.113.7"))
        let (probe, _) = try await run(connect: banned)
        let log = EngineLogReport(status: .found, fileName: "qconsole.log",
                                  matches: [EngineLogMatch(pattern: .banned, matchedAt: 4, line: "You have been banned")])
        return ConnectionDiagnosis(serverID: UUID(), label: "Test | Server", host: server, port: 27015,
                                   startedAt: Date(timeIntervalSince1970: 1_793_000_000), probe: probe, engineLog: log,
                                   publicIP: "203.0.113.7")
    }

    func testReportIsMaskedByDefault() async throws {
        L10n.setting = .en
        let diagnosis = try await sampleDiagnosis()
        let cid = try XCTUnwrap(diagnosis.probe.cid)
        XCTAssertEqual(DiagnosisReport.maskCID(cid), String(cid.prefix(8)) + "…" + String(cid.suffix(4)))
        XCTAssertEqual(DiagnosisReport.maskIP("203.0.113.7"), "203.0.113.0/24")
        let masked = DiagnosisReport.markdown(diagnosis, appVersion: "9.9.9", timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertFalse(masked.contains(cid))
        XCTAssertFalse(masked.contains("203.0.113.7"), "the public IP is masked everywhere, server text included")
        XCTAssertTrue(masked.contains(DiagnosisReport.maskCID(cid)))
        XCTAssertTrue(masked.contains("203.0.113.0/24"))
        XCTAssertTrue(masked.contains("# Connection diagnosis — \(server):27015"))
        XCTAssertTrue(masked.contains("Cybokron Player Identity 9.9.9"))
        XCTAssertTrue(masked.contains("2026-10-26T07:33:20Z"))
        XCTAssertTrue(masked.contains("## Verdict: `cidBanned`"))
        XCTAssertTrue(masked.contains("| `connect49` | failed |"))
        XCTAssertTrue(masked.contains("Test \\| Server"))
        XCTAssertTrue(masked.contains("`You have been banned`"))
        XCTAssertTrue(masked.contains("CID and IP are masked."))

        let full = DiagnosisReport.markdown(diagnosis, appVersion: "9.9.9", masked: false)
        XCTAssertTrue(full.contains(cid))
        XCTAssertTrue(full.contains("203.0.113.7"))
    }

    func testReportFileName() {
        let name = DiagnosisReport.fileName(host: "cs.example.com", date: Date(timeIntervalSince1970: 1_793_000_000),
                                            timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "playeridentity-diagnose-cs.example.com-20261026-073320.md")
        XCTAssertEqual(DiagnosisReport.fileName(host: "2001:db8::1", date: Date(timeIntervalSince1970: 0),
                                                timeZone: TimeZone(identifier: "UTC")!),
                       "playeridentity-diagnose-2001_db8__1-19700101-000000.md")
    }

    func testHistoryEntryOfADiagnosis() async throws {
        let diagnosis = try await sampleDiagnosis()
        let entry = diagnosis.historyEntry
        XCTAssertEqual(entry.kind, .diagnose)
        XCTAssertEqual(entry.new, "cidBanned")
        XCTAssertNil(entry.old)
        XCTAssertEqual(entry.host, "\(server):27015")
        XCTAssertEqual(entry.note, "dns=ok a2sInfo=ok getChallenge=ok connect49=failed")
    }

    // MARK: (f) cancellation, (g) no network

    func testCancellationStopsTheProbe() async throws {
        let transport = FakeUDPTransport(waitsOnSilence: true, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let diagnoser = ConnectionDiagnoser(transport: transport, resolver: FakeAddressResolver(), now: { Date() })
        let request = request()
        let task = Task { try await diagnoser.run(request) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let start = Date()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testNoNetworkMeansDNSFailureOrTimeout() async throws {
        let resolver = FakeAddressResolver(["cs.example": .failure(.network)])
        let dns = try await diagnoser(FakeServer.healthy(), resolver: resolver).run(request(host: "cs.example"))
        XCTAssertEqual(dns.verdict, .dnsFailure)
        XCTAssertEqual(dns.steps[0].detail, "network")
        let socket = try await diagnoser(NoNetworkTransport()).run(request())
        XCTAssertEqual(socket.verdict, .timeout)
        XCTAssertEqual(statuses(socket), [.ok, .failed, .skipped, .skipped])
        XCTAssertTrue(socket.steps[1].detail.hasPrefix("socket: "))
    }

    // MARK: App model

    @MainActor
    func testModelDiagnosisWritesHistoryOnlyAndUsesTheEngineLog() async throws {
        let env = try TestAppEnvironment()
        try env.temp.write("home/Library/Application Support/Xash3D FWGS/valve/qconsole.log",
                           "Connecting to \(server)\nYour IP is banned\n")
        let model = env.makeModel(udp: FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil)))
        model.addServer(ServerDraft(label: "Test", host: server))
        await model.refresh().value
        let id = try XCTUnwrap(model.servers.first?.id)
        let entryBefore = model.servers[0]
        await model.startDiagnosis(for: id)?.value
        await model.waitForHistory()
        let session = try XCTUnwrap(model.diagnosis(for: id))
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.steps.count, 4)
        let result = try XCTUnwrap(session.result)
        XCTAssertEqual(result.probeVerdict, .serverOffline)
        XCTAssertEqual(result.verdict, .ipBanned)
        XCTAssertTrue(result.verdictFromLog)
        XCTAssertEqual(model.servers[0], entryBefore, "the server entry is not changed")
        XCTAssertNotNil(model.diagnosisAppealText(for: id))
        XCTAssertNotNil(model.diagnosisReport(for: id))
        let line = try XCTUnwrap(env.historyStore.load().last { $0.kind == .diagnose })
        XCTAssertEqual(line.new, "ipBanned")
        XCTAssertEqual(line.old, "serverOffline")
        XCTAssertEqual(line.serverID, id)
        model.clearDiagnosis()
        XCTAssertNil(model.diagnosis(for: id))
    }

    @MainActor
    func testModelCancelledDiagnosisWritesNoHistory() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel(udp: FakeUDPTransport(waitsOnSilence: true, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil)))
        model.addServer(ServerDraft(label: "Test", host: server))
        let id = try XCTUnwrap(model.servers.first?.id)
        model.banCheckEnabled = true
        let task = model.startDiagnosis(for: id)
        try await Task.sleep(for: .milliseconds(150))
        model.cancelDiagnosis()
        await task?.value
        await model.waitForHistory()
        XCTAssertEqual(model.diagnosis(for: id)?.cancelled, true)
        XCTAssertNil(model.diagnosis(for: id)?.result)
        XCTAssertFalse(env.historyStore.load().contains { $0.kind == .diagnose })
    }

    @MainActor
    func testModelChecksDisabled() async throws {
        let env = try TestAppEnvironment()
        let udp = FakeServer.healthy(clock: env.clock)
        let model = env.makeModel(udp: udp)
        model.addServer(ServerDraft(label: "Test", host: server))
        model.banCheckEnabled = false
        let id = try XCTUnwrap(model.servers.first?.id)
        let sentBefore = udp.sentCount
        await model.startDiagnosis(for: id)?.value
        XCTAssertEqual(model.diagnosis(for: id)?.result?.verdict, .checksDisabled)
        XCTAssertEqual(udp.sentCount, sentBefore)
    }
}

// MARK: - Helpers

private actor EventLog {
    private(set) var items: [DiagnosisProgress] = []
    func add(_ event: DiagnosisProgress) { items.append(event) }
}

/// A file system whose log exists but cannot be read.
private struct UnreadableLog: FileSystemReading {
    struct Denied: Error {}
    func isRegularFile(_ url: URL) -> Bool { url.lastPathComponent == "qconsole.log" }
    func isDirectory(_ url: URL) -> Bool { false }
    func readData(_ url: URL) throws -> Data { throw Denied() }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { [] }
}

/// No network: every socket fails to open (like `ENETUNREACH`).
private struct NoNetworkTransport: UDPTransport {
    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession {
        throw UDPSocketError.system(51)
    }
}

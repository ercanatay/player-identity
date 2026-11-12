import XCTest
@testable import PlayerIdentity

/// §34 `playeridentityctl`: parsing, JSON schema, exit codes, IPv6, no stdin. In-process via `CLIRunner.run`
/// (fake UDP + resolver, temp home) and one smoke test of the bundled binary.
final class CLITests: XCTestCase {
    private static let fixtureCID = "d9de0eb4419608a8423241430581e91c"   // raw ID 0 + 51.68.190.91 (§4)
    private var temp: TempDirectory!
    private let clock = TestClock()

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }

    private func context(udp: FakeUDPTransport? = nil, resolver: FakeAddressResolver = FakeAddressResolver(),
                         snapshot: URL? = nil) -> CLIContext {
        let clock = self.clock
        return CLIContext(version: "1.2.1", build: "13", paths: AppPaths(home: home),
                          environment: snapshot.map { [CLIContext.snapshotEnvironmentKey: $0.path] } ?? [:],
                          fileSystem: LocalFileSystem(), resolver: resolver,
                          udpTransport: udp ?? FakeServer.healthy(clock: clock), now: { clock.now })
    }

    private func run(_ arguments: [String], _ context: CLIContext? = nil) async -> CLIResult {
        await CLIRunner.run(arguments: arguments, context: context ?? self.context())
    }

    private func json(_ result: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        return try XCTUnwrap(object, result.stdout + result.stderr, file: file, line: line)
    }

    private func fixture(_ name: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: CLITests.self).url(forResource: name, withExtension: "json"))
        let copy = temp.url.appendingPathComponent(name + ".json")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func writeIdentity() throws {
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")   // raw ID 0
    }

    // MARK: Parsing

    func testArgumentParsing() {
        XCTAssertEqual(CLIParser.parse(["cid", "51.68.190.91"]), .success(.cid(host: "51.68.190.91", rawID: nil, json: false)))
        XCTAssertEqual(CLIParser.parse(["--json", "cid", "--raw-id", "0x1F", "51.68.190.91"]),
                       .success(.cid(host: "51.68.190.91", rawID: 0x1F, json: true)))
        XCTAssertEqual(CLIParser.parse(["cid", "Play.Example.com", "--raw-id=0000000000000000"]),
                       .success(.cid(host: "play.example.com", rawID: 0, json: false)))
        XCTAssertEqual(CLIParser.parse(["ban", "192.0.2.1:27016", "--timeout", "2.5", "--json"]),
                       .success(.ban(host: "192.0.2.1", port: 27016, cid: nil, json: true, timeout: 2.5, recordMetrics: true)))
        XCTAssertEqual(CLIParser.parse(["ban", "192.0.2.1", "--cid", Self.fixtureCID.uppercased()]),
                       .success(.ban(host: "192.0.2.1", port: 27015, cid: Self.fixtureCID, json: false, timeout: 4)))
        XCTAssertEqual(CLIParser.parse(["ban", "192.0.2.1", "--no-metrics"]),
                       .success(.ban(host: "192.0.2.1", port: 27015, cid: nil, json: false, timeout: 4, recordMetrics: false)))
        XCTAssertEqual(CLIParser.parse(["status", "--json"]), .success(.status(json: true)))
        XCTAssertEqual(CLIParser.parse(["--version"]), .success(.version(json: false)))
        XCTAssertEqual(CLIParser.parse(["--version", "--json"]), .success(.version(json: true)))
        XCTAssertEqual(CLIParser.parse(["-h"]), .success(.help))
        XCTAssertEqual(CLIParser.parse(["help"]), .success(.help))

        let usageErrors: [[String]] = [
            [], ["frobnicate"], ["status", "--no-metrics"], ["cid", "192.0.2.1", "--no-metrics"],
            ["--no-metrics=1", "ban", "192.0.2.1"], ["cid"], ["cid", "a", "b"], ["cid", "not an ip"], ["cid", "192.0.2.1", "--raw-id", "xyz"],
            ["cid", "192.0.2.1", "--raw-id", "00000000000000000"], ["cid", "192.0.2.1", "--raw-id"],
            ["cid", "192.0.2.1", "--cid", Self.fixtureCID], ["ban"], ["ban", "192.0.2.1:0"], ["ban", "192.0.2.1:abc"],
            ["ban", "192.0.2.1", "--cid", "1234"], ["ban", "192.0.2.1", "--timeout", "0"],
            ["ban", "192.0.2.1", "--timeout", "-1"], ["ban", "192.0.2.1", "--timeout", "31"], ["ban", "192.0.2.1", "--raw-id", "0"],
            ["status", "extra"], ["status", "--timeout", "4"], ["status", "--verbose"], ["cid", "--version"],
            ["ban", "192.0.2.1", "--timeout", "1", "--timeout", "2"], ["--json=1", "status"],
        ]
        for arguments in usageErrors {
            guard case .failure = CLIParser.parse(arguments) else {
                XCTFail("expected usage error: \(arguments)")
                continue
            }
        }
    }

    func testHostPortParsingIncludingIPv6() {
        func parse(_ text: String) -> String? { CLIHostPort.parse(text).map { "\($0.host)|\($0.port)" } }
        XCTAssertEqual(parse("192.0.2.1:27016"), "192.0.2.1|27016")
        XCTAssertEqual(parse("192.0.2.1"), "192.0.2.1|27015")
        XCTAssertEqual(parse("Play.Example.com:27017"), "play.example.com|27017")
        XCTAssertEqual(parse("[2001:db8::1]:27016"), "2001:db8::1|27016")
        XCTAssertEqual(parse("[2001:db8::1]"), "2001:db8::1|27015")
        XCTAssertEqual(parse("2001:db8::1"), "2001:db8::1|27015")
        XCTAssertNil(parse("[2001:db8::1]27016"))
        XCTAssertNil(parse("[192.0.2.1]:27015"))
        XCTAssertNil(parse("192.0.2.1:"))
        XCTAssertNil(parse("192.0.2.1:65536"))
        XCTAssertNil(parse("bad host:1"))
    }

    // MARK: cid

    func testCidJSONSchemaAndIdentityFile() async throws {
        try writeIdentity()
        let result = await run(["cid", "51.68.190.91", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        let object = try json(result)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "command", "host", "address", "rawID", "rawIDSource", "cid"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["command"] as? String, "cid")
        XCTAssertEqual(object["cid"] as? String, Self.fixtureCID)
        XCTAssertEqual(object["rawID"] as? String, "0000000000000000")
        XCTAssertEqual(object["rawIDSource"] as? String, "identityFile")
        XCTAssertEqual(result.stdout.last, "\n")

        let plain = await run(["cid", "51.68.190.91"])
        XCTAssertEqual(plain.stdout, Self.fixtureCID + "\n")
    }

    func testCidRawIDArgumentIPv6AndHostname() async throws {
        let override = await run(["cid", "51.68.190.91", "--raw-id", "0", "--json"])   // no identity file needed
        XCTAssertEqual(try json(override)["rawIDSource"] as? String, "argument")
        XCTAssertEqual(try json(override)["cid"] as? String, Self.fixtureCID)

        let v6 = await run(["cid", "2001:DB8::1", "--raw-id", "0", "--json"])
        XCTAssertEqual(v6.exitCode, 0)
        XCTAssertEqual(try json(v6)["address"] as? String, "2001:db8::1")
        XCTAssertEqual(try json(v6)["cid"] as? String, CIDCalculator.cid(rawID: 0, host: "2001:db8::1"))

        let resolver = FakeAddressResolver(["play.example.com": .success([TestAddresses.v4("51.68.190.91")])])
        let named = await run(["cid", "play.example.com", "--raw-id", "0", "--json"], context(resolver: resolver))
        XCTAssertEqual(try json(named)["address"] as? String, "51.68.190.91")
        XCTAssertEqual(try json(named)["cid"] as? String, Self.fixtureCID)
    }

    func testCidErrorsAndExitCodes() async throws {
        let noIdentity = await run(["cid", "51.68.190.91"])
        XCTAssertEqual(noIdentity.exitCode, 2)
        XCTAssertTrue(noIdentity.stderr.contains("--raw-id"))
        XCTAssertEqual(noIdentity.stdout, "")

        let notFound = await run(["cid", "missing.example.com", "--raw-id", "0", "--json"])
        XCTAssertEqual(notFound.exitCode, 2)
        XCTAssertEqual(try json(notFound)["error"] as? String, "notFound")

        let resolver = FakeAddressResolver(["down.example.com": .failure(.network)])
        let network = await run(["cid", "down.example.com", "--raw-id", "0"], context(resolver: resolver))
        XCTAssertEqual(network.exitCode, 2)

        let usage = await run(["cid"])
        XCTAssertEqual(usage.exitCode, 1)
        XCTAssertTrue(usage.stderr.contains("usage: playeridentityctl"))
    }

    // MARK: ban

    func testBanHealthyServerJSON() async throws {
        try writeIdentity()
        let result = await run(["ban", "51.68.190.91:27015", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let object = try json(result)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "command", "host", "port", "address", "cid", "status", "banned",
                                          "detail", "checkedAt", "server"])
        XCTAssertEqual(object["status"] as? String, "cidOk")
        XCTAssertEqual(object["banned"] as? Bool, false)
        XCTAssertEqual(object["cid"] as? String, Self.fixtureCID)   // from the identity file
        XCTAssertEqual(object["port"] as? Int, 27015)
        XCTAssertEqual(object["detail"] as? String, "ipOk → cidOk")
    }

    func testBanExitCodes() async throws {
        let ipBanned = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8)))))
        let banned = await run(["ban", "192.0.2.1:27015"], context(udp: ipBanned))
        XCTAssertEqual(banned.exitCode, 3)
        XCTAssertTrue(banned.stdout.hasPrefix("192.0.2.1:27015 ipBanned"))
        XCTAssertTrue(banned.stdout.contains("cid: none"))

        let cidBanned = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            connect: FakeReply(bytes: FakeServer.oobText("errormsg\nYou are banned (CID)\n"))))
        let byCID = await run(["ban", "192.0.2.1", "--cid", Self.fixtureCID, "--json"], context(udp: cidBanned))
        XCTAssertEqual(byCID.exitCode, 3)
        XCTAssertEqual(try json(byCID)["status"] as? String, "cidBanned")
        XCTAssertEqual(try json(byCID)["banned"] as? Bool, true)
        XCTAssertTrue(String(decoding: cidBanned.sentPackets.last ?? [], as: UTF8.self).contains(Self.fixtureCID))

        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let start = clock.now
        let unreachable = await run(["ban", "192.0.2.1", "--timeout", "1", "--json"], context(udp: silent))
        XCTAssertEqual(unreachable.exitCode, 2)
        XCTAssertEqual(try json(unreachable)["status"] as? String, "unreachable")
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(start), 1.01)   // --timeout is the step timeout

        let unknown = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(challenge: nil))
        let noChallenge = await run(["ban", "192.0.2.1"], context(udp: unknown))
        XCTAssertEqual(noChallenge.exitCode, 0)   // undetermined, not a ban or a network error
        XCTAssertTrue(noChallenge.stdout.contains(" unknown"))

        let unresolved = await run(["ban", "missing.example.com:27015", "--json"])
        XCTAssertEqual(unresolved.exitCode, 2)
    }

    // MARK: §39 metrics sample

    private var metricsFile: URL { AppPaths(home: home).metricsFile }

    private func a2sTransport() -> FakeUDPTransport {
        FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: A2SFixture.goldSrc())))
    }

    func testBanWritesAMetricsSampleOnceAndNoMetricsTurnsItOff() async throws {
        let first = await run(["ban", "51.68.190.91:27015"], context(udp: a2sTransport()))
        XCTAssertEqual(first.exitCode, 0)
        var samples = MetricsStore(fileURL: metricsFile).load()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.serverID, MetricSample.stableServerID(host: "51.68.190.91", port: 27015))
        XCTAssertEqual(samples.first?.map, "rpg_city")
        XCTAssertEqual(samples.first?.online, true)

        _ = await run(["ban", "51.68.190.91:27015"], context(udp: a2sTransport()))   // same second → deduped
        XCTAssertEqual(MetricsStore(fileURL: metricsFile).load().count, 1)

        clock.advance(5)
        _ = await run(["ban", "51.68.190.91:27015", "--no-metrics"], context(udp: a2sTransport()))
        XCTAssertEqual(MetricsStore(fileURL: metricsFile).load().count, 1)

        clock.advance(5)
        _ = await run(["ban", "51.68.190.91:27015", "--json"], context(udp: a2sTransport()))
        samples = MetricsStore(fileURL: metricsFile).load()
        XCTAssertEqual(samples.count, 2)
    }

    func testBanSampleUsesTheSavedServerAndSkipsSilentServers() async throws {
        let snapshot = try fixture("cli-status-profile")    // contains "Example EU" at 192.0.2.20:27015
        _ = await run(["ban", "192.0.2.20:27015"], context(udp: a2sTransport(), snapshot: snapshot))
        let next = snapshot.deletingLastPathComponent().appendingPathComponent("metrics.jsonl")
        XCTAssertEqual(MetricsStore(fileURL: next).load().map(\.serverID),
                       [UUID(uuidString: "1E390D91-9114-454E-A9B3-4AB1833ACD48")!])

        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let unreachable = await run(["ban", "192.0.2.99"], context(udp: silent))
        XCTAssertEqual(unreachable.exitCode, 2)
        XCTAssertEqual(MetricsStore(fileURL: metricsFile).load(), [])           // no A2S answer → no sample
    }

    func testBanIPv6Endpoint() async throws {
        let endpoints = EndpointLog()
        let transport = FakeUDPTransport(clock: clock) { endpoint, packet in
            endpoints.append(endpoint)
            return FakeServer.scripted()(endpoint, packet)
        }
        let result = await run(["ban", "[2001:db8::1]:27016"], context(udp: transport))   // no identity → IP check only
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("[2001:db8::1]:27016 ipOk"), result.stdout)
        XCTAssertEqual(endpoints.first, UDPEndpoint(address: TestAddresses.v6("2001:db8::1"), port: 27016))
    }

    // MARK: status

    func testStatusJSONFromFixture() async throws {
        let result = await run(["status", "--json"], context(snapshot: try fixture("cli-status-profile")))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let object = try json(result)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "command", "version", "snapshot", "rawID", "displayName", "model",
                                          "gamedir", "publicIP", "lanIPs", "bannedCount", "servers"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["version"] as? String, "1.2.1")
        XCTAssertEqual(object["rawID"] as? String, "0000000000000000")
        XCTAssertEqual(object["bannedCount"] as? Int, 0)
        let servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(Set(servers[0].keys), ["id", "label", "host", "port", "cid", "group", "favorite", "order",
                                              "lastCheckedAt", "ban", "appeal"])
        XCTAssertEqual((servers[0]["ban"] as? [String: Any])?["status"] as? String, "cidOk")
        XCTAssertEqual(servers[0]["group"] as? String, "Europe")
        XCTAssertTrue(servers[1]["ban"] is NSNull)       // old row without the new fields
        XCTAssertTrue(servers[1]["group"] is NSNull)
        XCTAssertEqual(servers[1]["favorite"] as? Bool, false)

        let text = await run(["status"], context(snapshot: try fixture("cli-status-profile")))
        XCTAssertTrue(text.stdout.contains("[2001:db8::1]:27016"))
        XCTAssertTrue(text.stdout.contains("ban: cidOk"))
    }

    func testStatusExitCodes() async throws {
        let banned = await run(["status", "--json"], context(snapshot: try fixture("cli-status-banned")))
        XCTAssertEqual(banned.exitCode, 3)
        XCTAssertEqual(try json(banned)["bannedCount"] as? Int, 1)

        let missing = await run(["status", "--json"], context(snapshot: temp.url.appendingPathComponent("none.json")))
        XCTAssertEqual(missing.exitCode, 2)
        XCTAssertEqual(try json(missing)["error"] as? String, "snapshotMissing")

        let corrupt = try temp.write("corrupt.json", "{not json")
        let unreadable = await run(["status"], context(snapshot: corrupt))
        XCTAssertEqual(unreadable.exitCode, 2)
        XCTAssertTrue(unreadable.stderr.contains("cannot be read"))

        let future = try temp.write("future.json", #"{"schemaVersion":2}"#)
        let unsupported = await run(["status", "--json"], context(snapshot: future))
        XCTAssertEqual(try json(unsupported)["error"] as? String, "snapshotUnsupported")

        // Default location: <home>/Library/Application Support/tr.ercanatay.playeridentity/profile.json
        try FileManager.default.createDirectory(at: AppPaths(home: home).snapshotFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try fixture("cli-status-profile"), to: AppPaths(home: home).snapshotFile)
        let defaultPath = await run(["status"])
        XCTAssertEqual(defaultPath.exitCode, 0, defaultPath.stderr)
    }

    // MARK: version / help

    func testVersionAndHelp() async throws {
        let version = await run(["--version"])
        XCTAssertEqual(version.stdout, "playeridentityctl 1.2.1 (13)\n")
        XCTAssertEqual(version.exitCode, 0)
        let object = try json(await run(["--version", "--json"]))
        XCTAssertEqual(object["version"] as? String, "1.2.1")
        XCTAssertEqual(object["build"] as? String, "13")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)

        let help = await run(["--help"])
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(help.stdout.contains("exit codes: 0 ok, 1 usage error, 2 network or resolution error, 3 banned"))
        let none = await run([])
        XCTAssertEqual(none.exitCode, 1)
        XCTAssertEqual(none.stdout, "")
    }

    // MARK: Bundled binary (shell smoke)

    /// Runs `Contents/Helpers/playeridentityctl` with a standard input that is never closed: the tool must not wait
    /// for it. Only offline commands (`--version`, `cid --raw-id`, `status` with the fixture).
    func testBundledBinarySmoke() throws {
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/playeridentityctl")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), binary.path)
        let snapshot = try fixture("cli-status-profile")

        let version = try execute(binary, ["--version"])
        XCTAssertEqual(version.status, 0)
        XCTAssertEqual(version.stdout, "playeridentityctl \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))\n")

        let cid = try execute(binary, ["cid", "51.68.190.91", "--raw-id", "0", "--json"])
        XCTAssertEqual(cid.status, 0)
        XCTAssertTrue(cid.stdout.contains(#""cid" : "\#(Self.fixtureCID)""#), cid.stdout)

        let status = try execute(binary, ["status", "--json"], environment: [CLIContext.snapshotEnvironmentKey: snapshot.path])
        XCTAssertEqual(status.status, 0, status.stderr)
        XCTAssertTrue(status.stdout.contains(#""schemaVersion" : 1"#))

        let banned = try execute(binary, ["status"], environment: [CLIContext.snapshotEnvironmentKey: try fixture("cli-status-banned").path])
        XCTAssertEqual(banned.status, 3)
        XCTAssertEqual(try execute(binary, ["nope"]).status, 1)

        // §51: standard input is a pipe, not a terminal: `update --install` without --yes is refused offline.
        let install = try execute(binary, ["update", "--install"])
        XCTAssertEqual(install.status, 1)
        XCTAssertTrue(install.stderr.contains("--yes"), install.stderr)
        XCTAssertEqual(try execute(binary, ["update"]).status, 1)
    }

    private func execute(_ binary: URL, _ arguments: [String],
                         environment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path].merging(environment) { $1 }
        let input = Pipe()          // kept open and never written
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let done = expectation(description: "exit \(arguments)")
        process.terminationHandler = { _ in done.fulfill() }
        try process.run()
        wait(for: [done], timeout: 20)
        if process.isRunning { process.terminate() }
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try input.fileHandleForWriting.close()
        return (process.terminationStatus, stdout, stderr)
    }
}

final class EndpointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [UDPEndpoint] = []
    var first: UDPEndpoint? { lock.withLock { endpoints.first } }
    func append(_ endpoint: UDPEndpoint) { lock.withLock { endpoints.append(endpoint) } }
}

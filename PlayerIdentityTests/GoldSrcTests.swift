import XCTest
@testable import PlayerIdentity

/// §75 captured packets. The A2S replies come from the public server 51.68.190.91:27015 (POLIGON RPG, 2026-11-26):
/// it answers one `TSource Engine Query` with a legacy `0x6D` reply (protocol byte 47) and a Source `0x49` reply
/// (protocol byte 48). The connect packet head comes from the engine's own `connect 127.0.0.1:27999 gs` with
/// `cl_ticket_generator null` against a local listener; its userinfo (engine cvars) is not kept here.
enum GoldSrcFixture {
    static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    /// Legacy `0x6D` reply, 86 bytes.
    static let poligonLegacy = bytes(
        "ffffffff6d35312e36382e3139302e39313a323730313500504f4c49474f4e20525047205b742e6d652f706f6c69676f6e5f7270675d00"
        + "58666972650076616c76650048616c662d4c69666500091a2f646c00000100")
    /// Source-layout `0x49` reply of the same server, 85 bytes (protocol byte 48).
    static let poligonSourceLayout = bytes(
        "ffffffff4930504f4c49474f4e20525047205b742e6d652f706f6c69676f6e5f7270675d0058666972650076616c76650048616c662d"
        + "4c696665004600091a00646c0001312e312e322e372f537464696f00808769")
    /// The server's `getchallenge` reply.
    static let poligonChallenge: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF] + Array("A00000000 1270654979 2\n".utf8) + [0]
    /// Engine connect packet up to the opening quote of the userinfo (challenge 1234567890 from the local listener).
    static let capturedConnectHead = bytes(
        "ffffffff636f6e6e656374203438203132333435363738393020225c70726f745c335c756e697175655c2d315c7261775c737465616d5c"
        + "63646b65795c3463653130663137366664393539353966383636633131313432303232663233222022")
    static let capturedCDKey = "4ce10f176fd95959f866c11142022f23"
    /// The engine's challenge request before a GoldSrc connect.
    static let capturedGetChallenge = bytes("ffffffff6765746368616c6c656e676520737465616d0a")

    /// The server's real answer to a modern connect 49 (captured 2026-11-26 with a zero CID).
    static let poligonOlderProtocol: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF] + Array(("9This server is using an older protocol ( 48 ) "
        + "than your client ( 49 ).  If you believe this server is outdated, you can contact the server administrator at "
        + "(no email address specified).\n").utf8) + [0]

    /// A Source/Xash `0x49` reply with protocol byte 49.
    static func source49(name: String = "Xash Server", map: String = "crossfire") -> [UInt8] {
        A2SFixture.header + [0x49, 49] + A2SFixture.cString(name) + A2SFixture.cString(map) + A2SFixture.cString("valve")
            + A2SFixture.cString("Half-Life") + [0x46, 0x00, 5, 32, 0, 0x64, 0x6C, 0x00, 0x00]
    }

    /// A complete legacy reply with optional password, mod fields and bots.
    static func legacy(protocolByte: UInt8 = 48, password: UInt8 = 0, mod: Bool = false, bots: UInt8 = 0,
                       trailing: [UInt8] = []) -> [UInt8] {
        var bytes = A2SFixture.header + [0x6D] + A2SFixture.cString("192.0.2.30:27015") + A2SFixture.cString("Legacy")
            + A2SFixture.cString("de_dust") + A2SFixture.cString("cstrike") + A2SFixture.cString("Counter-Strike")
            + [4, 16, protocolByte, 0x64, 0x6C, password, mod ? 1 : 0]
        if mod {
            bytes += A2SFixture.cString("http://mod.example") + A2SFixture.cString("http://dl.example") + [0]
                + [1, 0, 0, 0] + [0, 0x10, 0, 0] + [0, 1]
        }
        return bytes + [1, bots] + trailing
    }

    /// Fake GoldSrc server: legacy A2S reply, text challenge, scripted connect reply.
    static func server(clock: TestClock, info: [UInt8] = poligonLegacy, challenge: FakeReply? = FakeReply(bytes: poligonChallenge),
                       connect: FakeReply?) -> FakeUDPTransport {
        FakeUDPTransport(clock: clock) { _, packet in
            if FakeServer.isInfo(packet) { return [FakeReply(bytes: info)] }
            if FakeServer.isGetChallenge(packet) { return challenge.map { [$0] } ?? [] }
            if FakeServer.isConnect(packet) { return connect.map { [$0] } ?? [] }
            return []
        }
    }

    static func isConnect48(_ packet: [UInt8]) -> Bool { packet.starts(with: A2SFixture.header + Array("connect 48 ".utf8)) }
    static func isConnect49(_ packet: [UInt8]) -> Bool { packet.starts(with: A2SFixture.header + Array("connect 49 ".utf8)) }
}

// MARK: - §75.1 / §75.2 parser (T-75-1 … T-75-4)

final class GoldSrcParserTests: XCTestCase {
    /// AC-75.G1 (T-75-1): the captured legacy reply is `goldsrc48`; name, map, gamedir and protocol are right and the
    /// address string is kept (never used to connect).
    func testCapturedLegacyReplyIsGoldSrc48() throws {
        let inspection = ServerInfoParser.inspect(GoldSrcFixture.poligonLegacy)
        let info = try XCTUnwrap(inspection.info)
        XCTAssertFalse(inspection.malformed)
        XCTAssertEqual(inspection.trailingBytes, 0)
        XCTAssertEqual(info.serverProtocol, .goldsrc48)
        XCTAssertEqual(info.protocolVersion, 47)   // HLDS reports 47 in the legacy reply
        XCTAssertEqual(info.name, "POLIGON RPG [t.me/poligon_rpg]")
        XCTAssertEqual(info.map, "Xfire")
        XCTAssertEqual(info.folder, "valve")
        XCTAssertEqual(info.game, "Half-Life")
        XCTAssertEqual(info.players, 9)
        XCTAssertEqual(info.maxPlayers, 26)
        XCTAssertEqual(info.reportedAddress, "51.68.190.91:27015")
        // Protocol byte 48 is GoldSrc 48 as well.
        XCTAssertEqual(ServerInfoParser.parse(GoldSrcFixture.legacy(protocolByte: 48))?.serverProtocol, .goldsrc48)
    }

    /// The same server's Source-layout reply has protocol byte 48: GoldSrc 48 too (v5.4.3), never `source49`.
    func testSourceLayoutWithProtocol48IsGoldSrc() throws {
        let info = try XCTUnwrap(ServerInfoParser.parse(GoldSrcFixture.poligonSourceLayout))
        XCTAssertEqual(info.serverProtocol, .goldsrc48)
        XCTAssertEqual(info.protocolVersion, 48)
        XCTAssertEqual(info.name, "POLIGON RPG [t.me/poligon_rpg]")
        XCTAssertEqual(info.map, "Xfire")
        XCTAssertEqual(info.players, 9)
        XCTAssertEqual(info.maxPlayers, 26)
    }

    /// AC-75.G2 (T-75-2): Source 49 keeps its layout (map and folder are not swapped).
    func testSource49RegressionLayout() throws {
        let info = try XCTUnwrap(ServerInfoParser.parse(GoldSrcFixture.source49()))
        XCTAssertEqual(info, ServerInfo(name: "Xash Server", map: "crossfire", players: 5, maxPlayers: 32,
                                        serverProtocol: .source49, protocolVersion: 49, folder: "valve", game: "Half-Life"))
        // The older Source fixture (protocol 17) keeps its fields.
        let old = try XCTUnwrap(ServerInfoParser.parse(A2SFixture.source()))
        XCTAssertEqual([old.name, old.map, old.folder], ["Source Server", "de_dust2", "cstrike"])
        XCTAssertEqual(old.players, 12)
        XCTAssertEqual(old.maxPlayers, 32)
    }

    /// AC-75.G3 (T-75-3): password, mod fields (skipped) and bots; trailing bytes keep `goldsrc48` with a warning.
    func testPasswordModAndBots() throws {
        let modded = ServerInfoParser.inspect(GoldSrcFixture.legacy(password: 1, mod: true, bots: 3))
        XCTAssertEqual(modded.info?.serverProtocol, .goldsrc48)
        XCTAssertFalse(modded.malformed)
        XCTAssertEqual(modded.info?.map, "de_dust")
        XCTAssertEqual(modded.info?.folder, "cstrike")
        XCTAssertEqual(modded.info?.players, 4)
        XCTAssertEqual(BrowserInfoParser.visibility(GoldSrcFixture.legacy(password: 1)), true)
        let trailing = ServerInfoParser.inspect(GoldSrcFixture.legacy(trailing: [9, 9, 9]))
        XCTAssertEqual(trailing.info?.serverProtocol, .goldsrc48)
        XCTAssertEqual(trailing.trailingBytes, 3)
        XCTAssertTrue(ConnectionDiagnoser.infoDetail(trailing.info, trailingBytes: 3).contains("trailingBytes=3"))
        // Mod flag 1 without the mod fields → malformed.
        var cut = GoldSrcFixture.legacy()
        cut[cut.count - 3] = 1   // mod flag
        XCTAssertEqual(ServerInfoParser.parse(cut)?.serverProtocol, .unknown)
    }

    /// AC-75.C1 (T-75-4): truncated, unterminated, duplicated field, wrong protocol byte, other type → never a false
    /// `goldsrc48` and never a crash.
    func testMalformedRepliesAreUnknown() {
        let full = GoldSrcFixture.poligonLegacy
        for length in 0..<full.count {
            let inspection = ServerInfoParser.inspect(Array(full.prefix(length)))
            XCTAssertNotEqual(inspection.info?.serverProtocol, .goldsrc48, "prefix \(length)")
            if length >= 5 { XCTAssertTrue(inspection.malformed, "prefix \(length)") }
        }
        let unterminated = A2SFixture.header + [0x6D] + Array("51.68.190.91:27015".utf8)
        XCTAssertEqual(ServerInfoParser.parse(unterminated)?.serverProtocol, .unknown)
        // The name twice: every later field shifts, the protocol byte is not GoldSrc's.
        let duplicated = A2SFixture.header + [0x6D] + A2SFixture.cString("192.0.2.30:27015") + A2SFixture.cString("Legacy")
            + A2SFixture.cString("Legacy") + A2SFixture.cString("de_dust") + A2SFixture.cString("cstrike")
            + A2SFixture.cString("Counter-Strike") + [4, 16, 48, 0x64, 0x6C, 0, 0, 1, 0]
        XCTAssertEqual(ServerInfoParser.inspect(duplicated).info?.serverProtocol, .unknown)
        XCTAssertTrue(ServerInfoParser.inspect(duplicated).malformed)
        XCTAssertEqual(ServerInfoParser.parse(GoldSrcFixture.legacy(protocolByte: 46))?.serverProtocol, .unknown)
        XCTAssertEqual(ServerInfoParser.parse(GoldSrcFixture.legacy(protocolByte: 49))?.serverProtocol, .unknown)
        XCTAssertNil(ServerInfoParser.parse(A2SFixture.header + [0x44, 0]))
        XCTAssertNil(ServerInfoParser.parse(A2SFixture.header + [0x41, 1, 2, 3, 4]))
        XCTAssertNil(ServerInfoParser.parse([]))
        // Source layout truncated before max players → unknown.
        let source = GoldSrcFixture.source49()
        XCTAssertEqual(ServerInfoParser.parse(Array(source.prefix(source.count - 8)))?.serverProtocol, .unknown)
    }

    /// §75.1 records: no protocol field → `unknown` (the record stays readable); new fields round-trip; an unknown
    /// value reads as `unknown`; a record without a protocol is written without the field.
    func testCodableAndOlderRecords() throws {
        let old = Data(#"{"status":"ipOk","checkedAt":"2026-11-08T12:12:04Z","detail":"","info":{"name":"S","max":2}}"#.utf8)
        let check = try SnapshotStore.makeDecoder().decode(BanCheck.self, from: old)
        XCTAssertEqual(check.info?.serverProtocol, .unknown)
        XCTAssertEqual(check.info?.maxPlayers, 2)
        let info = try XCTUnwrap(ServerInfoParser.parse(GoldSrcFixture.poligonLegacy))
        let data = try SnapshotStore.makeEncoder().encode(info)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""protocol" : "goldsrc48""#))
        XCTAssertEqual(try SnapshotStore.makeDecoder().decode(ServerInfo.self, from: data), info)
        let future = Data(#"{"protocol":"source50"}"#.utf8)
        XCTAssertEqual(try SnapshotStore.makeDecoder().decode(ServerInfo.self, from: future).serverProtocol, .unknown)
        let plain = try SnapshotStore.makeEncoder().encode(ServerInfo(name: "S"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("protocol"))
    }
}

// MARK: - §75.3 CID (T-75-5 … T-75-7)

final class GoldSrcCIDTests: XCTestCase {
    private let host = "51.68.190.91"
    private static let rawID: UInt64 = 0
    private static let sourceCID = "d9de0eb4419608a8423241430581e91c"   // raw ID 0 + 51.68.190.91 (§4)

    private func entry(_ serverProtocol: ServerProtocol?, cid: String = "") -> ServerEntry {
        let info = serverProtocol.map { ServerInfo(name: "S", serverProtocol: $0) }
        return ServerEntry(label: "S", host: host, cid: cid, lastCheckedAt: Date(timeIntervalSince1970: 1_793_000_000),
                           banCheck: BanCheck(status: .cidNotApplicable, checkedAt: Date(timeIntervalSince1970: 1_793_000_000),
                                              detail: "", info: info))
    }

    private func snapshot(_ servers: [ServerEntry]) -> Snapshot {
        Snapshot(savedAt: Date(timeIntervalSince1970: 1_793_000_000), gamedir: "valve", dataRoot: "/tmp", displayName: "N",
                 model: "gordon", rawID: "0000000000000000", identitySource: "", network: NetworkInfo(publicIP: "", lanIPs: []),
                 servers: servers)
    }

    /// AC-75.C2 (T-75-5): GoldSrc 48 → no CID, `notApplicable`; an old saved legacy CID is not compared or shown.
    func testGoldSrcRowHasNoCID() {
        let row = entry(.goldsrc48, cid: Self.sourceCID)
        let status = StatusEvaluator.serverRow(row, rawID: Self.rawID, saved: snapshot([row]))
        XCTAssertNil(status.currentCID)
        XCTAssertTrue(status.cidNotApplicable)
        XCTAssertEqual(status.serverProtocol, .goldsrc48)
        XCTAssertEqual(status.level, .green)
        XCTAssertNil(status.message)
        XCTAssertEqual(ServerProtocol.goldsrc48.cidApplicable, false)
        // The row with a different saved CID is still not "CID changed".
        let other = entry(.goldsrc48, cid: "ffffffffffffffffffffffffffffffff")
        XCTAssertNil(StatusEvaluator.serverRow(other, rawID: Self.rawID, saved: snapshot([other])).message)
        // Save drops the legacy CID of a GoldSrc row.
        let saved = SnapshotBuilder.make(savedAt: Date(), dataRoot: URL(fileURLWithPath: "/tmp"), gamedir: "valve",
                                         config: PlayerConfig(),
                                         identity: .success(Identity(source: IdentitySource(location: .homeConfig, url: URL(fileURLWithPath: "/x")),
                                                                     fileValue: 0x10331C2DCE4C91DB, rawID: 0)),
                                         publicIP: nil, lanIPs: [], checkedAt: Date(), servers: [row])
        XCTAssertEqual(saved.servers.first?.cid, "")
    }

    /// AC-75.C3 (T-75-6): Source 49 and `unknown` keep the existing CID.
    func testSourceRowKeepsTheCID() {
        for serverProtocol in [ServerProtocol.source49, .unknown] {
            let row = entry(serverProtocol, cid: Self.sourceCID)
            let status = StatusEvaluator.serverRow(row, rawID: Self.rawID, saved: snapshot([row]))
            XCTAssertEqual(status.currentCID, Self.sourceCID)
            XCTAssertEqual(status.currentCID, CIDCalculator.cid(rawID: Self.rawID, address: TestAddresses.v4(host)))
            XCTAssertEqual(status.level, .green)
            XCTAssertFalse(status.cidNotApplicable)
        }
        let noInfo = entry(nil)
        XCTAssertEqual(StatusEvaluator.serverRow(noInfo, rawID: Self.rawID, saved: nil).currentCID, Self.sourceCID)
        XCTAssertEqual(StatusEvaluator.serverRow(noInfo, rawID: Self.rawID, saved: nil).message, .serverCIDChanged)
        XCTAssertEqual(ServerProtocol.source49.cidApplicable, true)
        XCTAssertNil(ServerProtocol.unknown.cidApplicable)
    }

    /// The automatic ban check never sends connect 49 (nor the legacy probe) to a GoldSrc 48 server and computes no CID.
    func testBanCheckSendsNoConnectToGoldSrc() async throws {
        let clock = TestClock()
        let transport = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oob(0x42)))
        let request = BanCheckRequest(serverID: UUID(), host: host, port: 27015,
                                      endpoint: UDPEndpoint(address: TestAddresses.v4(host), port: 27015),
                                      cid: Self.sourceCID, name: "N")
        let check = try await BanChecker(transport: transport, now: { clock.now }).check(request)
        // §75.13: never a green "no block" — the null-ticket check cannot verify a GoldSrc ban.
        XCTAssertEqual(check.status, .goldSrcUnverified)
        XCTAssertEqual(check.status.level, .orange)
        XCTAssertNotEqual(check.status.label, L10n.text(.banStatusNoBlock))
        XCTAssertEqual(check.status.messageCode, .goldSrcBanUnverified)
        XCTAssertEqual(check.info?.serverProtocol, .goldsrc48)
        XCTAssertFalse(transport.sentPackets.contains(where: FakeServer.isConnect))
        XCTAssertFalse(transport.sentPackets.contains { String(decoding: $0, as: UTF8.self).contains(Self.sourceCID) })
        // A server last seen as GoldSrc 48 gets no CID in its request.
        let requests = BanCheckRunner.requests(servers: [entry(.goldsrc48), entry(.source49)], rawID: Self.rawID, name: "N")
        XCTAssertEqual(requests.map(\.cid), [nil, nil])   // never precomputed: only a check that proves Source 49 derives it
        XCTAssertEqual(requests.map(\.knownProtocol), [.goldsrc48, .source49])
        let remembered = BanCheckRunner.requests(servers: [entry(nil)], rawID: Self.rawID, name: "N",
                                                 knownProtocols: [requests[0].serverID: .goldsrc48])
        XCTAssertNotNil(remembered.first)
    }
}

// MARK: - §75.3 legacy CID cleanup in the app (T-75-7)

@MainActor
final class GoldSrcAppModelTests: XCTestCase {
    private static let legacyCID = "d9de0eb4419608a8423241430581e91c"
    private static let app = "/Applications/Xash3D-FWGS.app"

    private func writeLegacyRecord(_ env: TestAppEnvironment, host: String = "51.68.190.91") throws -> UUID {
        let id = UUID()
        let record = Snapshot(savedAt: Date(timeIntervalSince1970: 1_793_000_000), gamedir: "valve",
                              dataRoot: env.home.appendingPathComponent("Library/Application Support/Xash3D FWGS").path,
                              displayName: "N", model: "gordon", rawID: "0000000000000000", identitySource: "",
                              network: NetworkInfo(publicIP: "203.0.113.7", lanIPs: ["en0 192.0.2.10"]),
                              servers: [ServerEntry(id: id, label: "POLIGON", host: host, cid: Self.legacyCID)])
        try SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).save(record)
        return id
    }

    private func savedCID(_ env: TestAppEnvironment) -> String? {
        SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot?.servers.first?.cid
    }

    /// AC-75.C4 (T-75-7): the old record opens; a failed refresh keeps the legacy CID; a successful refresh with a
    /// GoldSrc 48 reply removes it (memory and record) and the row shows N/A.
    func testLegacyCIDIsClearedOnlyBySuccessfulGoldSrcRefresh() async throws {
        let env = try TestAppEnvironment()
        let id = try writeLegacyRecord(env)
        let offline = FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let first = env.makeModel(udp: offline)
        XCTAssertEqual(first.servers.first?.cid, Self.legacyCID)
        await first.refresh().value
        XCTAssertEqual(first.servers.first?.cid, Self.legacyCID)
        XCTAssertEqual(savedCID(env), Self.legacyCID)

        env.clock.advance(60)
        let transport = GoldSrcFixture.server(clock: env.clock, connect: nil)
        let model = env.makeModel(udp: transport)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.info?.serverProtocol, .goldsrc48)
        XCTAssertEqual(model.servers.first?.cid, "")
        XCTAssertEqual(savedCID(env), "")
        XCTAssertTrue(model.rowStatus(id)?.cidNotApplicable ?? false)
        XCTAssertNil(model.rowStatus(id)?.currentCID)
        XCTAssertNil(model.menuBarCID(for: id))
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(transport.sentPackets.contains(where: FakeServer.isConnect))
        // A later failed refresh does not bring anything back or remove anything else.
        env.clock.advance(60)
        let again = env.makeModel(udp: offline)
        await again.refresh().value
        XCTAssertEqual(savedCID(env), "")
    }

    /// AC-75.L2 (T-75-9): "Join Game" uses the newest A2S result: `gs` after a GoldSrc 48 refresh, kept after a newer
    /// failed refresh, `source49` (no `gs`) once a newer result says Source 49.
    func testJoinGameUsesTheLatestA2SResult() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        final class Script: @unchecked Sendable {
            let lock = NSLock()
            var reply = GoldSrcFixture.poligonLegacy
            var silent = false
        }
        let script = Script()
        let transport = FakeUDPTransport(clock: env.clock) { _, packet in
            script.lock.lock(); defer { script.lock.unlock() }
            if FakeServer.isInfo(packet) { return script.silent ? [] : [FakeReply(bytes: script.reply)] }
            if FakeServer.isGetChallenge(packet) { return [FakeReply(bytes: GoldSrcFixture.poligonChallenge)] }
            return []
        }
        let model = env.makeModel(udp: transport) {
            $0.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]),
                                               homeDirectory: URL(fileURLWithPath: "/Users/test"))
            $0.gameLaunchRunner = runner
        }
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        let id = try XCTUnwrap(model.servers.first?.id)
        // Nothing known yet → source49 default.
        await model.joinGame(id)?.value
        await model.refresh().value
        await model.joinGame(id)?.value
        env.clock.advance(30)
        script.lock.withLock { script.silent = true }
        await model.refresh().value
        await model.joinGame(id)?.value
        env.clock.advance(30)
        script.lock.withLock { script.silent = false; script.reply = GoldSrcFixture.source49() }
        await model.refresh().value
        await model.joinGame(id)?.value
        let base = ["/usr/bin/open", "-a", Self.app, "--args", "-game", "valve", "+connect", "51.68.190.91:27015"]
        let goldSrc = ["/usr/bin/open", "--env", "XASH3D_BASEDIR=" + model.dataRoot.standardizedFileURL.path, "-a", Self.app,
                       "--args", "-game", "valve", "-dev", "1", "-log", "+connect", "51.68.190.91:27015", "gs"]
        XCTAssertEqual(runner.commands, [base, goldSrc, goldSrc, base])
        XCTAssertNotNil(model.goldSrcJoins[id])
        XCTAssertTrue(runner.commands.allSatisfy(GameLaunchAllowlist.isAllowed))
    }
}

// MARK: - §75.4 launch (T-75-8, T-75-9)

final class GoldSrcLaunchTests: XCTestCase {
    private static let app = "/Applications/Xash3D-FWGS.app"

    private func launcher(runner: FakeGameLaunchRunner = FakeGameLaunchRunner()) -> GameLauncher {
        GameLauncher(locator: GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]),
                                             homeDirectory: URL(fileURLWithPath: "/Users/test")),
                     resolver: FakeAddressResolver(), detector: FakeGameDetector(), runner: runner)
    }

    /// AC-75.L1 (T-75-8): exact arguments per protocol; the key is `gs`, never `legacy`.
    func testLaunchArgumentsPerProtocol() async throws {
        let base = ["/usr/bin/open", "-a", Self.app, "--args", "-game", "valve", "+connect", "51.68.190.91:27015"]
        let source = try await launcher().plan(host: "51.68.190.91", port: 27015, gamedir: "valve", serverProtocol: .source49)
        XCTAssertEqual(source.command.argv, base)
        let root = URL(fileURLWithPath: "/Users/test/Library/Application Support/Xash3D FWGS", isDirectory: true)
        let goldSrc = try await launcher().plan(host: "51.68.190.91", port: 27015, gamedir: "valve", serverProtocol: .goldsrc48,
                                                dataRoot: root)
        // §75.13: `XASH3D_BASEDIR` reaches the engine (open --env), so engine.log lands in the data root.
        let goldSrcArgv = ["/usr/bin/open", "--env", "XASH3D_BASEDIR=/Users/test/Library/Application Support/Xash3D FWGS",
                           "-a", Self.app, "--args", "-game", "valve", "-dev", "1", "-log",
                           "+connect", "51.68.190.91:27015", "gs"]
        XCTAssertEqual(goldSrc.command.argv, goldSrcArgv)
        XCTAssertEqual(goldSrc.command.engineLogURL?.path, "/Users/test/Library/Application Support/Xash3D FWGS/engine.log")
        do {
            _ = try await launcher().plan(host: "51.68.190.91", port: 27015, gamedir: "valve", serverProtocol: .goldsrc48)
            XCTFail("a GoldSrc launch without a data root must not be built")
        } catch let error as GameLaunchError {
            XCTAssertEqual(error, .noDataRoot)
        }
        let unknown = try await launcher().plan(host: "51.68.190.91", port: 27015, gamedir: "valve", serverProtocol: .unknown)
        XCTAssertEqual(unknown.command.argv, base)
        let ipv6 = try await launcher().plan(host: "2001:db8::1", port: 27016, gamedir: nil, serverProtocol: .goldsrc48,
                                             dataRoot: root)
        XCTAssertEqual(Array(ipv6.command.argv.suffix(3)), ["+connect", "[2001:db8::1]:27016", "gs"])
        for plan in [source, goldSrc, unknown, ipv6] { XCTAssertTrue(GameLaunchAllowlist.isAllowed(plan.command.argv)) }
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(base + ["gs"]))
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(Array(goldSrcArgv.dropLast()) + ["legacy"]))
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(goldSrcArgv + ["x"]))
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(base + ["+exec"]))
        var tampered = goldSrcArgv
        tampered[9] = "2"
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(tampered))
        for env in ["XASH3D_BASEDIR=relative/path", "XASH3D_BASEDIR=/a/../b", "XASH3D_BASEDIR=/", "HOME=/tmp",
                    "XASH3D_BASEDIR=/a\nb", "DYLD_INSERT_LIBRARIES=/x.dylib"] {
            var bad = goldSrcArgv
            bad[2] = env
            XCTAssertFalse(GameLaunchAllowlist.isAllowed(bad), env)
        }
        // A path with spaces and quotes is one argument (no shell).
        XCTAssertTrue(GameLaunchAllowlist.isBaseDir("XASH3D_BASEDIR=/Users/a b/\"x\"; rm -rf ~"))
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(Array(goldSrcArgv.prefix(2)) + Array(goldSrcArgv.dropFirst(3))))
        let runner = FakeGameLaunchRunner()
        try await launcher(runner: runner).launch(goldSrc) { true }
        XCTAssertEqual(runner.commands, [goldSrcArgv])
    }

    /// AC-75.L2 (T-75-9): the memory keeps the newest decided protocol; `unknown` never overrides; another host/port
    /// starts over; the row's saved result counts by date.
    func testProtocolMemory() {
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        var entry = ServerEntry(id: id, label: "S", host: "51.68.190.91")
        var memory = ServerProtocolMemory()
        XCTAssertEqual(memory.launchProtocol(for: entry), .unknown)
        memory.record(.goldsrc48, for: id, host: entry.host, port: entry.port, at: t0)
        XCTAssertEqual(memory.launchProtocol(for: entry), .goldsrc48)
        memory.record(.unknown, for: id, host: entry.host, port: entry.port, at: t0.addingTimeInterval(10))
        XCTAssertEqual(memory.launchProtocol(for: entry), .goldsrc48)
        memory.record(.source49, for: id, host: entry.host, port: entry.port, at: t0.addingTimeInterval(-10))
        XCTAssertEqual(memory.launchProtocol(for: entry), .goldsrc48)   // older result ignored
        memory.record(.source49, for: id, host: entry.host, port: entry.port, at: t0.addingTimeInterval(20))
        XCTAssertEqual(memory.launchProtocol(for: entry), .source49)
        // A newer saved result of the row wins over the memory.
        entry.banCheck = BanCheck(status: .cidNotApplicable, checkedAt: t0.addingTimeInterval(30), detail: "",
                                  info: ServerInfo(serverProtocol: .goldsrc48))
        XCTAssertEqual(memory.launchProtocol(for: entry), .goldsrc48)
        // Another port: the memory does not apply.
        var moved = ServerEntry(id: id, label: "S", host: "51.68.190.91", port: 27016)
        moved.banCheck = nil
        XCTAssertEqual(memory.launchProtocol(for: moved), .unknown)
    }
}

// MARK: - §75.6 legacy probe packets and replies (T-75-10 … T-75-15)

final class GoldSrcProbeTests: XCTestCase {
    private let host = "51.68.190.91"

    /// AC-75.P1 (T-75-10): the exact byte vector; it matches the engine's captured packet (head, `"\n` + 512 zeros).
    func testConnectPacketByteVector() throws {
        let packet = try XCTUnwrap(GoldSrcPackets.connect(challenge: "1234567890", cdKey: GoldSrcFixture.capturedCDKey,
                                                          name: "PIProbe"))
        let expected = [0xFF, 0xFF, 0xFF, 0xFF] + Array(("connect 48 1234567890 "
            + #""\prot\3\unique\-1\raw\steam\cdkey\4ce10f176fd95959f866c11142022f23" "\name\PIProbe""# + "\n").utf8)
            + [UInt8](repeating: 0, count: 512)
        XCTAssertEqual(packet, expected)
        XCTAssertEqual(packet.count, 4 + 107 + 512)
        XCTAssertTrue(packet.starts(with: GoldSrcFixture.capturedConnectHead))
        XCTAssertEqual(Array(packet.suffix(514)), Array("\"\n".utf8) + [UInt8](repeating: 0, count: 512))
        // No message name on the wire (the engine's buffer label is not sent).
        XCTAssertFalse(String(decoding: packet, as: UTF8.self).contains("GoldSrcConnect"))
        XCTAssertEqual(GoldSrcPackets.getChallenge(), GoldSrcFixture.capturedGetChallenge)
        // Field order of protinfo and userinfo.
        XCTAssertEqual(GoldSrcPackets.protinfo(cdKey: GoldSrcFixture.capturedCDKey),
                       #"\prot\3\unique\-1\raw\steam\cdkey\4ce10f176fd95959f866c11142022f23"#)
        XCTAssertEqual(GoldSrcPackets.userinfo(name: "PIProbe"), #"\name\PIProbe"#)
        // Invalid inputs are never sent.
        XCTAssertNil(GoldSrcPackets.connect(challenge: "12a", cdKey: GoldSrcFixture.capturedCDKey, name: "x"))
        XCTAssertNil(GoldSrcPackets.connect(challenge: "1", cdKey: "XYZ", name: "x"))
        XCTAssertTrue(GoldSrcPackets.isCDKey(GoldSrcPackets.randomCDKey()))
        XCTAssertNotEqual(GoldSrcPackets.randomCDKey(), GoldSrcPackets.randomCDKey())
    }

    func testNameIsSanitized() {
        XCTAssertEqual(GoldSrcPackets.sanitizedName(#"A\name\B"C;D"#), "AnameBCD")
        XCTAssertEqual(GoldSrcPackets.sanitizedName("  \n "), "player")
        XCTAssertEqual(GoldSrcPackets.sanitizedName(String(repeating: "ş", count: 40)).utf8.count, 30)
        XCTAssertLessThanOrEqual(GoldSrcPackets.sanitizedName(String(repeating: "x", count: 99)).utf8.count, 31)
    }

    /// Challenge from the captured server reply; ban text at the challenge; garbage.
    func testChallengeReplies() {
        XCTAssertEqual(GoldSrcReplies.challenge(GoldSrcFixture.poligonChallenge), .challenge("1270654979"))
        XCTAssertEqual(GoldSrcReplies.challenge(FakeServer.oobText("A00000000 1270654979 3 1 1\n")), .challenge("1270654979"))
        XCTAssertEqual(GoldSrcReplies.challenge(FakeServer.oobText("lYou have been banned from this server.\n")),
                       .banned("You have been banned from this server."))
        if case .unrecognized = GoldSrcReplies.challenge(FakeServer.oobText("A00000000 x 2\n")) {} else { XCTFail() }
        if case .unrecognized = GoldSrcReplies.challenge([1, 2]) {} else { XCTFail() }
    }

    /// AC-75.P3 – P6 reply classes; the message is cleaned and at most 200 characters.
    func testConnectReplies() {
        let banned = GoldSrcReplies.connect(FakeServer.oobText("9You have been banned from this server.\n") + [0])
        XCTAssertEqual(banned, GoldSrcProbeResult(.banned, message: "You have been banned from this server."))
        let rejected = GoldSrcReplies.connect(FakeServer.oobText("9Sorry, no-steam p48 clients are not allowed on this server\n"))
        XCTAssertEqual(rejected, GoldSrcProbeResult(.rejected, message: "Sorry, no-steam p48 clients are not allowed on this server"))
        XCTAssertEqual(GoldSrcReplies.connect(FakeServer.oobText("lServer is full.\n")).outcome, .rejected)
        XCTAssertEqual(GoldSrcReplies.connect(FakeServer.oobText("disconnect You are banned")).outcome, .banned)
        XCTAssertEqual(GoldSrcReplies.connect(FakeServer.oob(0x42, Array(" 1 \"192.0.2.10:27005\" 0".utf8))).outcome, .accepted)
        XCTAssertEqual(GoldSrcReplies.connect(FakeServer.oobText("Zsomething")).outcome, .incomplete)
        XCTAssertEqual(GoldSrcReplies.connect([0x01]).outcome, .incomplete)
        let long = GoldSrcReplies.connect(FakeServer.oobText("9" + String(repeating: "x", count: 500) + "\u{07}"))
        XCTAssertEqual(long.message.count, 200)
        let control = GoldSrcReplies.connect(FakeServer.oobText("9bad\u{01}\u{1B}[31mtext\n"))
        XCTAssertFalse(control.message.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }
}

// MARK: - §75.5 diagnosis paths (T-75-11 … T-75-15)

final class GoldSrcDiagnosisTests: XCTestCase {
    private let host = "51.68.190.91"
    private let clock = TestClock()

    private func inLanguage<T>(_ language: String, _ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language)), operation: body)
    }
    private func inEnglish<T>(_ body: () throws -> T) throws -> T { try inLanguage("en", body) }
    private func inTurkish<T>(_ body: () throws -> T) throws -> T { try inLanguage("tr", body) }

    private func request(confirmed: Bool = true, rawID: UInt64? = 0) -> ConnectionDiagnosisRequest {
        var request = ConnectionDiagnosisRequest(host: host, port: 27015, rawID: rawID, name: "PIProbe", checksEnabled: true,
                                                 vpnActive: false, knownRange: nil)
        request.legacyProbeConfirmed = confirmed
        return request
    }

    private func run(_ transport: FakeUDPTransport, _ request: ConnectionDiagnosisRequest) async throws -> ConnectionProbeResult {
        let clock = self.clock
        return try await ConnectionDiagnoser(transport: transport, resolver: FakeAddressResolver(), now: { clock.now },
                                      qport: { 4242 }, cdKey: { GoldSrcFixture.capturedCDKey }).run(request)
    }

    /// AC-75.P2 (T-75-11): GoldSrc → only connect 48 (never connect 49, never a CID); Source 49 / unknown → only
    /// connect 49 (never the legacy probe).
    func testEachPathSendsOnlyItsConnect() async throws {
        let goldSrc = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oob(0x42)))
        let result = try await run(goldSrc, request())
        XCTAssertEqual(result.serverProtocol, .goldsrc48)
        XCTAssertEqual(result.verdict, .legacyVerificationUnavailable)
        XCTAssertNil(result.cid)
        XCTAssertEqual(goldSrc.sentPackets.filter(GoldSrcFixture.isConnect48).count, 1)
        XCTAssertFalse(goldSrc.sentPackets.contains(where: GoldSrcFixture.isConnect49))
        XCTAssertTrue(goldSrc.sentPackets.contains(GoldSrcFixture.capturedGetChallenge))
        XCTAssertEqual(result.steps.map(\.step), [.dns, .a2sInfo, .getChallenge, .connect48])
        let connect = try XCTUnwrap(goldSrc.sentPackets.first(where: GoldSrcFixture.isConnect48))
        XCTAssertTrue(connect.starts(with: A2SFixture.header + Array("connect 48 1270654979 ".utf8)))

        let source = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: GoldSrcFixture.source49())))
        let sourceResult = try await run(source, request())
        XCTAssertFalse(sourceResult.verdict.isGoldSrc)
        XCTAssertEqual(source.sentPackets.filter(GoldSrcFixture.isConnect49).count, 2)   // capability probe + real CID
        XCTAssertFalse(source.sentPackets.contains(where: GoldSrcFixture.isConnect48))
        XCTAssertFalse(source.sentPackets.contains(GoldSrcFixture.capturedGetChallenge))
        XCTAssertNotNil(sourceResult.cid)
        XCTAssertNil(sourceResult.goldSrc)

        // §75.4: an unknown protocol (protocol 17, a truncated or silent reply) gets neither connect 49 nor a CID.
        for info in [A2SFixture.source(), A2SFixture.goldSrc(), FakeServer.oob(0x49, [0x30])] {
            let unknown = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: info)))
            let unknownResult = try await run(unknown, request())
            XCTAssertEqual(unknownResult.serverProtocol, .unknown)
            XCTAssertFalse(unknown.sentPackets.contains(where: FakeServer.isConnect))
            XCTAssertNil(unknownResult.cid)
            XCTAssertEqual(unknownResult.verdict, .cidUnverified)
            XCTAssertNotEqual(unknownResult.verdict, .noBan)
        }
    }

    /// §75.2: both replies of one query (`0x6D` legacy + `0x49`/48) in either order → the legacy reply is kept;
    /// either way GoldSrc 48, no connect 49, no CID.
    func testLegacyReplyIsPreferredInEitherOrder() async throws {
        for order in [[GoldSrcFixture.poligonLegacy, GoldSrcFixture.poligonSourceLayout],
                      [GoldSrcFixture.poligonSourceLayout, GoldSrcFixture.poligonLegacy]] {
            let transport = FakeUDPTransport(clock: clock) { _, packet in
                if FakeServer.isInfo(packet) { return order.map { FakeReply(bytes: $0) } }
                if FakeServer.isGetChallenge(packet) { return [FakeReply(bytes: GoldSrcFixture.poligonChallenge)] }
                return []
            }
            let result = try await run(transport, request(confirmed: false))
            XCTAssertEqual(result.serverProtocol, .goldsrc48)
            XCTAssertEqual(result.info?.protocolVersion, 47)   // the legacy reply
            XCTAssertEqual(result.info?.reportedAddress, "51.68.190.91:27015")
            XCTAssertFalse(transport.sentPackets.contains(where: FakeServer.isConnect))
            XCTAssertNil(result.cid)
            let clock = self.clock
            let check = try await BanChecker(transport: transport, now: { clock.now })
                .check(BanCheckRequest(serverID: UUID(), host: host, port: 27015,
                                       endpoint: UDPEndpoint(address: TestAddresses.v4(host), port: 27015), cid: nil,
                                       name: "N", rawID: 0))
            XCTAssertEqual(check.status, .goldSrcUnverified)
            XCTAssertEqual(check.info?.protocolVersion, 47)
        }
        // Only the Source-layout reply: still GoldSrc 48 (the short window passes without a legacy reply).
        let only49 = FakeUDPTransport(clock: clock) { _, packet in
            if FakeServer.isInfo(packet) { return [FakeReply(bytes: GoldSrcFixture.poligonSourceLayout)] }
            if FakeServer.isGetChallenge(packet) { return [FakeReply(bytes: GoldSrcFixture.poligonChallenge)] }
            return []
        }
        let result = try await run(only49, request(confirmed: false))
        XCTAssertEqual(result.serverProtocol, .goldsrc48)
        XCTAssertEqual(result.info?.protocolVersion, 48)
        XCTAssertFalse(only49.sentPackets.contains(where: FakeServer.isConnect))
    }

    /// §75.4: an A2S time-out does not undo a known GoldSrc result — connect 49 is still never sent.
    func testKnownGoldSrcProtocolSurvivesAnA2STimeout() async throws {
        let transport = FakeUDPTransport(clock: clock) { _, packet in
            if FakeServer.isGetChallenge(packet) { return [FakeReply(bytes: GoldSrcFixture.poligonChallenge)] }
            if FakeServer.isConnect(packet) { return [FakeReply(bytes: FakeServer.oobText("A00000000 1 3 1 1\n"))] }
            return []
        }
        var known = request()
        known.knownProtocol = .goldsrc48
        let result = try await run(transport, known)
        XCTAssertEqual(result.serverProtocol, .goldsrc48)
        XCTAssertEqual(result.verdict, .legacyVerificationUnavailable)
        XCTAssertFalse(transport.sentPackets.contains(where: GoldSrcFixture.isConnect49))
        XCTAssertEqual(transport.sentPackets.filter(GoldSrcFixture.isConnect48).count, 1)
        // Without the known protocol the unknown server follows the Source 49 default.
        let unknown = FakeUDPTransport(clock: clock) { _, packet in
            FakeServer.isGetChallenge(packet) ? [FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes))] : []
        }
        _ = try await run(unknown, request())
        XCTAssertFalse(unknown.sentPackets.contains(where: GoldSrcFixture.isConnect49))   // unknown never gets connect 49
        var knownSource = request()
        knownSource.knownProtocol = .source49
        let remembered = FakeUDPTransport(clock: clock) { _, packet in
            FakeServer.isGetChallenge(packet) ? [FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes))] : []
        }
        _ = try await run(remembered, knownSource)
        XCTAssertTrue(remembered.sentPackets.contains(where: GoldSrcFixture.isConnect49))
    }

    /// Without the user's confirmation the legacy probe is not sent at all.
    func testLegacyProbeNeedsConfirmation() async throws {
        let transport = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oob(0x42)))
        let result = try await run(transport, request(confirmed: false))
        XCTAssertEqual(result.goldSrc, GoldSrcProbeResult(.notConfirmed))
        // No legacy UDP packet at all: neither `getchallenge steam` nor connect 48 (nor connect 49).
        let legacy = transport.sentPackets.filter { $0 == GoldSrcPackets.getChallenge() || GoldSrcFixture.isConnect48($0) }
        XCTAssertEqual(legacy.count, 0)
        XCTAssertFalse(transport.sentPackets.contains(where: FakeServer.isConnect))
        XCTAssertFalse(transport.sentPackets.contains(where: FakeServer.isGetChallenge))
        XCTAssertEqual(transport.sentPackets.count, 1)   // the A2S_INFO query only
        XCTAssertEqual(result.steps.map(\.step), [.dns, .a2sInfo, .getChallenge, .connect48])
        XCTAssertEqual(result.steps.suffix(2).map(\.status), [.skipped, .skipped])
        // Confirmed: exactly one `getchallenge steam` and one connect 48.
        let confirmed = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oob(0x42)))
        _ = try await run(confirmed, request(confirmed: true))
        XCTAssertEqual(confirmed.sentPackets.filter { $0 == GoldSrcPackets.getChallenge() }.count, 1)
        XCTAssertEqual(confirmed.sentPackets.filter(GoldSrcFixture.isConnect48).count, 1)
    }

    /// AC-75.P3 (T-75-12): ban text → "the server banned this connection" (no account/SteamID claim), not an IP/CID
    /// ban verdict; the engine log does not turn it into one.
    func testBanTextIsAServerBanWithoutKind() async throws {
        let transport = GoldSrcFixture.server(clock: clock,
                                              connect: FakeReply(bytes: FakeServer.oobText("9You have been banned from this server.\n")))
        let result = try await run(transport, request())
        XCTAssertEqual(result.verdict, .goldSrcBanned)
        XCTAssertEqual(result.verdict.rawValue, "banned")
        XCTAssertEqual(result.goldSrc?.outcome, .banned)
        try inEnglish {
            XCTAssertEqual(result.goldSrc?.sentence, "The server banned this connection.")
            XCTAssertFalse(result.goldSrc?.sentence.contains("SteamID") ?? true)
            XCTAssertFalse(result.goldSrc?.sentence.lowercased().contains("account") ?? true)
        }
        let log = EngineLogReport(status: .found, fileName: "qconsole.log",
                                  matches: [EngineLogMatch(pattern: .banned, matchedAt: 1, line: "You have been banned")],
                                  scannedLines: 1)
        XCTAssertEqual(DiagnosisClassifier.final(probe: .legacyVerificationUnavailable, log: log), .legacyVerificationUnavailable)
        XCTAssertEqual(DiagnosisClassifier.final(probe: .goldSrcBanned, log: log), .goldSrcBanned)
        let diagnosis = ConnectionDiagnosis(serverID: UUID(), label: "POLIGON", host: host, port: 27015,
                                            startedAt: clock.now, probe: result, engineLog: log)
        XCTAssertEqual(diagnosis.bannedValue, true)
        XCTAssertTrue(diagnosis.verdict.isBan)
        XCTAssertEqual(diagnosis.serverMessage, "You have been banned from this server.")
        // A ban already at the challenge.
        let early = GoldSrcFixture.server(clock: clock, challenge: FakeReply(bytes: FakeServer.oobText("lYou have been banned\n")),
                                          connect: nil)
        let earlyResult = try await run(early, request())
        XCTAssertEqual(earlyResult.goldSrc?.outcome, .banned)
        XCTAssertFalse(early.sentPackets.contains(where: FakeServer.isConnect))
    }

    /// AC-75.P4 (T-75-13): a refusal without a ban text names the server's reason (the real POLIGON reply).
    func testRejectionNamesTheReason() async throws {
        let transport = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oobText(
            "9Sorry, no-steam p48 clients are not allowed on this server\n")))
        let result = try await run(transport, request())
        XCTAssertEqual(result.goldSrc?.outcome, .rejected)
        try inEnglish {
            XCTAssertEqual(result.goldSrc?.sentence,
                           "The GoldSrc connection was rejected; reason: Sorry, no-steam p48 clients are not allowed on this server")
        }
        try inTurkish {
            XCTAssertEqual(result.goldSrc?.sentence,
                           "GoldSrc bağlantısı reddedildi; neden: Sorry, no-steam p48 clients are not allowed on this server")
        }
    }

    /// AC-75.P5 (T-75-14): no reply → "no reply", no ban; challenge without a completed connection → "did not complete".
    func testTimeoutsMakeNoBanClaim() async throws {
        let silent = GoldSrcFixture.server(clock: clock, connect: nil)
        let result = try await run(silent, request())
        XCTAssertEqual(result.goldSrc?.outcome, .noReply)
        XCTAssertEqual(result.verdict, .legacyVerificationUnavailable)
        let silentDiagnosis = ConnectionDiagnosis(serverID: nil, label: "", host: host, port: 27015, startedAt: clock.now,
                                                  probe: result, engineLog: .missing)
        XCTAssertNil(silentDiagnosis.bannedValue)
        // The live POLIGON answer to the null-ticket probe can be a bare `A…` packet (ping/challenge): unverified.
        let ping = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oobText("A00000000 1270654979 3 1 1\n")))
        let pingResult = try await run(ping, request())
        XCTAssertEqual(pingResult.goldSrc?.outcome, .incomplete)
        XCTAssertEqual(pingResult.verdict, .legacyVerificationUnavailable)
        let noChallenge = GoldSrcFixture.server(clock: clock, challenge: nil, connect: nil)
        let noChallengeResult = try await run(noChallenge, request())
        XCTAssertEqual(noChallengeResult.goldSrc?.outcome, .noReply)
        let odd = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oobText("Zstrange")))
        let oddResult = try await run(odd, request())
        XCTAssertEqual(oddResult.goldSrc?.outcome, .incomplete)
        for outcome in [GoldSrcProbeOutcome.noReply, .incomplete, .rejected, .accepted, .notConfirmed] {
            XCTAssertNotEqual(outcome.level, .red)
        }
    }

    /// AC-75.P6 (T-75-15): accepted → never a ban, and never "no ban" either (`banned: null`).
    func testAcceptedIsNoBan() async throws {
        let transport = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oob(0x42)))
        let result = try await run(transport, request())
        XCTAssertEqual(result.goldSrc?.outcome, .accepted)
        let diagnosis = ConnectionDiagnosis(serverID: nil, label: "", host: host, port: 27015, startedAt: clock.now,
                                            probe: result, engineLog: .missing)
        XCTAssertEqual(diagnosis.verdict, .legacyVerificationUnavailable)
        XCTAssertNil(diagnosis.bannedValue)
        XCTAssertNotEqual(diagnosis.verdict, .noBan)
        XCTAssertEqual(GoldSrcProbeOutcome.accepted.level, .orange)
        XCTAssertEqual(diagnosis.historyEntry.note, "dns=ok a2sInfo=ok getChallenge=ok connect48=ok goldsrc=accepted")
    }

    /// AC-75.S1 (T-75-16): no CID, CD key, ticket or raw identity in the report, history, steps or CLI JSON.
    func testPrivacy() async throws {
        let transport = GoldSrcFixture.server(clock: clock,
                                              connect: FakeReply(bytes: FakeServer.oobText("9You have been banned from this server.\n")))
        let result = try await run(transport, request(rawID: 0x0123456789ABCDEF))
        let diagnosis = ConnectionDiagnosis(serverID: UUID(), label: "POLIGON", host: host, port: 27015, startedAt: clock.now,
                                            probe: result, engineLog: .missing, publicIP: "198.51.100.10")
        let cid = CIDCalculator.cid(rawID: 0x0123456789ABCDEF, address: TestAddresses.v4(host))
        let target = CLIServerTarget(host: host, port: 27015, serverID: UUID(), label: "", index: nil, savedCID: cid)
        let outputs = [DiagnosisReport.markdown(diagnosis, appVersion: "2.26.0", masked: false),
                       DiagnosisReport.markdown(diagnosis, appVersion: "2.26.0"),
                       CLIRunner.diagnoseText(diagnosis, target: target),
                       CLIJSON.string(CLIRunner.diagnoseJSON(diagnosis, target: target)),
                       diagnosis.historyEntry.note ?? "", result.steps.map(\.detail).joined()]
        for output in outputs {
            for secret in [cid, String(cid.prefix(8)), GoldSrcFixture.capturedCDKey, "0123456789ABCDEF", "0123456789abcdef",
                           "cdkey", "prot\\3"] {
                XCTAssertFalse(output.contains(secret), "\(secret) in \(output)")
            }
        }
    }
}

// MARK: - §75.8 / §75.9 presentation and CLI (T-75-17, T-75-18)

@MainActor
final class GoldSrcPresentationTests: XCTestCase {
    private let clock = TestClock()

    private func inLanguage<T>(_ language: String, _ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle(language)), operation: body)
    }
    private func inEnglish<T>(_ body: () throws -> T) throws -> T { try inLanguage("en", body) }
    private func inTurkish<T>(_ body: () throws -> T) throws -> T { try inLanguage("tr", body) }

    private func diagnosis(_ outcome: GoldSrcProbeOutcome, message: String = "") -> ConnectionDiagnosis {
        var facts = DiagnosisFacts(dns: .resolved, info: .replied, challenge: .challenge)
        facts.serverProtocol = .goldsrc48
        facts.goldSrc = outcome
        var probe = ConnectionProbeResult(steps: [], facts: facts, verdict: DiagnosisClassifier.verdict(facts),
                                          address: "51.68.190.91",
                                          info: ServerInfo(name: "POLIGON RPG", serverProtocol: .goldsrc48))
        probe.serverProtocol = .goldsrc48
        probe.goldSrc = GoldSrcProbeResult(outcome, message: message)
        return ConnectionDiagnosis(serverID: UUID(), label: "POLIGON", host: "51.68.190.91", port: 27015,
                                   startedAt: clock.now, probe: probe, engineLog: .missing)
    }

    /// AC-75.U1 (T-75-17): the card says "CID is not used on this server", the ban text, the administrator request and
    /// the `gs` path; the row shows N/A; every new key exists in all 26 languages.
    func testCardTexts() throws {
        let banned = diagnosis(.banned, message: "You have been banned from this server.")
        try inEnglish {
            let text = GoldSrcDiagnosisText(diagnosis: banned, goldSrc: banned.goldSrc)
            XCTAssertEqual(text.cidLine, "CID is not used on this server (GoldSrc 48).")
            XCTAssertEqual(text.outcome, "The server banned this connection.")
            XCTAssertNotNil(text.banScope)
            XCTAssertEqual(text.serverMessage, "Server message: You have been banned from this server.")
            XCTAssertEqual(text.request, "Server: POLIGON RPG\nAddress: 51.68.190.91:27015\nServer message: You have been banned from this server.")
            XCTAssertEqual(text.join, "Join Game opens this server with +connect 51.68.190.91:27015 gs.")
            XCTAssertEqual(L10n.text(.serversGoldsrcCidNA), "N/A")
        }
        try inTurkish {
            let text = GoldSrcDiagnosisText(diagnosis: banned, goldSrc: banned.goldSrc)
            XCTAssertEqual(text.cidLine, "CID bu sunucuda kullanılmıyor (GoldSrc 48).")
            XCTAssertEqual(text.outcome, "Sunucu bu bağlantıyı yasakladı (ban).")
            XCTAssertTrue(text.adminTitle?.contains("yöneticisine") ?? false)
        }
        let accepted = diagnosis(.accepted)
        let acceptedText = GoldSrcDiagnosisText(diagnosis: accepted, goldSrc: accepted.goldSrc)
        XCTAssertNil(acceptedText.request)
        XCTAssertNil(acceptedText.banScope)
        // §75.13 unverified: never "no block" / "no ban", in any wording.
        for language in ["en", "tr"] {
            try inLanguage(language) {
                for unverified in [diagnosis(.accepted), diagnosis(.noReply), diagnosis(.incomplete),
                                   diagnosis(.rejected, message: "Sorry, no-steam p48 clients are not allowed on this server")] {
                    XCTAssertEqual(unverified.verdict, .legacyVerificationUnavailable)
                    let all = GoldSrcDiagnosisText(diagnosis: unverified, goldSrc: unverified.goldSrc).lines.joined(separator: " ")
                        + unverified.verdict.sentence + unverified.verdict.advice + BanStatus.goldSrcUnverified.label
                    for phrase in [L10n.text(.banStatusNoBlock), L10n.text(.diagnoseVerdictNoBan), L10n.text(.diagnoseShortNoBan)] {
                        XCTAssertFalse(all.contains(phrase), "\(language): \(phrase) in \(all)")
                    }
                }
                XCTAssertNotEqual(BanStatus.goldSrcUnverified.label, L10n.text(.banStatusNoBlock))
            }
        }
        try inEnglish {
            XCTAssertEqual(DiagnosisVerdict.legacyVerificationUnavailable.sentence, "The GoldSrc ban status could not be verified.")
            XCTAssertTrue(DiagnosisVerdict.legacyVerificationUnavailable.advice.contains("engine log"))
        }
        // The diagnosis report names the CID as not used.
        let report = try inEnglish { DiagnosisReport.markdown(banned, appVersion: "2.26.0") }
        XCTAssertTrue(report.contains("CID: CID is not used on this server (GoldSrc 48)."))
        XCTAssertTrue(report.contains("The server banned this connection."))
        // Step list shows connect 48 instead of connect 49.
        var session = AppModel.DiagnosisSession(token: UUID(), serverID: UUID())
        session.result = banned
        XCTAssertEqual(ConnectionDiagnosisSection.visibleSteps(session), [.dns, .a2sInfo, .getChallenge, .connect48])
        XCTAssertEqual(ConnectionDiagnosisSection.visibleSteps(AppModel.DiagnosisSession(token: UUID(), serverID: UUID())),
                       DiagnosisStepKind.probeSteps)

        let keys = L10nKey.allCases.map(\.rawValue).filter { $0.hasPrefix("diagnosis.goldsrc.") || $0.hasPrefix("servers.goldsrc.") }
        XCTAssertGreaterThanOrEqual(keys.count, 20)
        let languages = ["tr", "en", "de", "fr", "es", "it", "pt", "nl", "sv", "pl", "cs", "ro", "hu", "el", "bg", "uk", "ru",
                         "ar", "fa", "hi", "zh-Hans", "ja", "ko", "id", "az", "vi"]
        for language in languages {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                    subdirectory: nil, localization: language), language)
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
            for key in keys { XCTAssertFalse(table[key]?.isEmpty ?? true, "\(language): \(key)") }
        }
    }

    /// AC-75.J1 (T-75-18): `diagnose --json` on a GoldSrc server: protocol, `cid: null`, `cidApplicable: false`,
    /// `goldSrc: true`, verdict, message, `uniqueness_verified: false`, `schemaVersion`; `--confirm` sends the probe,
    /// without it nothing is sent; `--fail-on-ban` exits 4 for the GoldSrc ban.
    func testCLIDiagnoseJSON() async throws {
        let temp = try TempDirectory()
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
        let clock = self.clock
        func context(_ transport: FakeUDPTransport) -> CLIContext {
            var context = CLIContext(version: "2.26.0", build: "54", paths: AppPaths(home: home), environment: [:],
                                     fileSystem: LocalFileSystem(), resolver: FakeAddressResolver(),
                                     udpTransport: transport, now: { clock.now })
            context.vpnActive = { false }
            return context
        }
        let banned = GoldSrcFixture.server(clock: clock,
                                           connect: FakeReply(bytes: FakeServer.oobText("9You have been banned from this server.\n")))
        let result = await CLIRunner.run(arguments: ["diagnose", "51.68.190.91:27015", "--confirm", "--json", "--fail-on-ban"],
                                         context: context(banned))
        XCTAssertEqual(result.exitCode, CLIExit.banVerdict, result.stdout + result.stderr)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? String, "goldsrc48")
        XCTAssertTrue(object["cid"] is NSNull)
        XCTAssertEqual(object["cidApplicable"] as? Bool, false)
        XCTAssertEqual(object["goldSrc"] as? Bool, true)
        XCTAssertEqual(object["verdict"] as? String, "banned")
        XCTAssertEqual(object["serverMessage"] as? String, "You have been banned from this server.")
        XCTAssertEqual(object["goldSrcEvidence"] as? String, "probe")
        XCTAssertEqual(object["goldSrcProbe"] as? String, "banned")
        XCTAssertEqual(object["message"] as? String, "You have been banned from this server.")
        XCTAssertEqual(object["uniqueness_verified"] as? Bool, false)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["banned"] as? Bool, true)
        XCTAssertEqual(banned.sentPackets.filter(GoldSrcFixture.isConnect48).count, 1)

        let quiet = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oob(0x42)))
        let unconfirmed = await CLIRunner.run(arguments: ["diagnose", "51.68.190.91:27015", "--json"], context: context(quiet))
        XCTAssertEqual(unconfirmed.exitCode, CLIExit.ok)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(unconfirmed.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(plain["goldSrcProbe"] as? String, "notConfirmed")
        XCTAssertEqual(plain["verdict"] as? String, "legacyVerificationUnavailable")
        XCTAssertTrue(plain["banned"] is NSNull)
        XCTAssertTrue(plain["cid"] is NSNull)
        XCTAssertEqual(plain["cidApplicable"] as? Bool, false)

        // The engine log of the last GoldSrc connection to this server decides: `banned: true`, `serverMessage`.
        let started = Self.sessionHeader(self.clock.now.addingTimeInterval(-600))
        try temp.write("home/Library/Application Support/Xash3D FWGS/engine.log",
                       GoldSrcLogTests.block(header: started, address: "51.68.190.91:27015",
                                             answer: "Server issued disconnect. Reason: You have been banned from this server."))
        let ping = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oobText("A00000000 1 3 1 1\n")))
        let logged = await CLIRunner.run(arguments: ["diagnose", "51.68.190.91:27015", "--confirm", "--json"], context: context(ping))
        let loggedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(logged.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(loggedObject["verdict"] as? String, "banned")
        XCTAssertEqual(loggedObject["probeVerdict"] as? String, "legacyVerificationUnavailable")
        XCTAssertEqual(loggedObject["banned"] as? Bool, true)
        XCTAssertEqual(loggedObject["serverMessage"] as? String, "You have been banned from this server.")
        XCTAssertEqual(loggedObject["goldSrcEvidence"] as? String, "engineLog")
        XCTAssertTrue(loggedObject["cid"] is NSNull)
        XCTAssertEqual(loggedObject["cidApplicable"] as? Bool, false)
        XCTAssertFalse(quiet.sentPackets.contains(where: FakeServer.isConnect))

        // Source 49: CID filled, `cidApplicable: true`.
        let source = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: GoldSrcFixture.source49())))
        let sourceResult = await CLIRunner.run(arguments: ["diagnose", "51.68.190.91:27015", "--json"], context: context(source))
        let sourceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sourceResult.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(sourceObject["protocol"] as? String, "source49")
        XCTAssertEqual(sourceObject["cidApplicable"] as? Bool, true)
        XCTAssertEqual(sourceObject["cid"] as? String, "d9de0eb4419608a8423241430581e91c")
        XCTAssertEqual(sourceObject["goldSrc"] as? Bool, false)
        XCTAssertEqual(sourceObject["banned"] as? Bool, false)   // Source 49 keeps `banned: false`
    }

    nonisolated static func sessionHeader(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMMdd yyyy '['HH:mm.ss']'"
        return formatter.string(from: date)
    }

    func testCLIParsing() {
        XCTAssertEqual(CLIParser.parse(["diagnose", "51.68.190.91:27015", "--confirm"]),
                       .success(.diagnose(target: "51.68.190.91:27015", timeout: 5, json: false, failOnBan: false, confirm: true)))
        XCTAssertEqual(CLIParser.parse(["diagnose", "--confirm", "2", "--json"]),
                       .success(.diagnose(target: "2", timeout: 5, json: true, failOnBan: false, confirm: true)))
        if case .success = CLIParser.parse(["diagnose", "2", "--confirm=yes"]) { XCTFail() }
        if case .success = CLIParser.parse(["diagnose", "--macos-identity", "--confirm"]) { XCTFail() }
        // `engine backups delete --confirm <code>` keeps its value.
        XCTAssertEqual(CLIParser.parse(["engine", "backups", "delete", "--confirm", "ABC"]),
                       .success(.engineBackupsDelete(confirm: "ABC", json: false)))
    }
}

// MARK: - §75.13 engine log evidence

final class GoldSrcLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let poligon: Set<String> = GoldSrcEngineLog.addresses(host: "51.68.190.91", port: 27015, resolved: "51.68.190.91")

    /// One engine session in the format of the real `engine.log` (`-dev 1 -log`), as seen on 2026-11-26.
    static func block(header: String, address: String, answer: String?) -> String {
        var lines = ["================================================================================",
                     "Xash3D FWGS 0.21 (4248, 11ed246-3-g03992e5, master, apple-arm64)",
                     "Game started at \(header)",
                     "================================================================================",
                     "execing config.cfg", "server \(address)", "Connecting to \(address)... (retry #1)",
                     "Warning: Unknown command \"closemenus\"", "Trying to connect with GoldSrc 48 protocol",
                     "Spooling demo header."]
        if let answer { lines.append(answer) }
        lines.append("execing mainui.cfg")
        return lines.joined(separator: "\n") + "\n"
    }

    private func header(_ date: Date) -> String { GoldSrcPresentationTests.sessionHeader(date) }

    /// The real isolated-engine answer: "Server issued disconnect. Reason: You have been banned from this server."
    func testBanFromTheLastGoldSrcBlock() throws {
        let text = Self.block(header: header(now.addingTimeInterval(-300)), address: "51.68.190.91:27015",
                              answer: "Server issued disconnect. Reason: You have been banned from this server.")
        let evidence = try XCTUnwrap(GoldSrcEngineLog.evidence(in: text, addresses: poligon, now: now))
        XCTAssertEqual(evidence.outcome, .banned)
        XCTAssertEqual(evidence.reason, "You have been banned from this server.")
        XCTAssertEqual(evidence.address, "51.68.190.91:27015")
        // The out-of-band refusal form ("Server message" + next line) and the console form (colours, `[time] `).
        let message = Self.block(header: header(now.addingTimeInterval(-60)), address: "51.68.190.91:27015",
                                 answer: "Server message\nYou have been banned from this server.")
        XCTAssertEqual(GoldSrcEngineLog.evidence(in: message, addresses: poligon, now: now)?.outcome, .banned)
        let console = message.split(separator: "\n").map { "\u{1B}[0m[15:34:24] \u{1B}[1;33m" + $0 + "\u{1B}[0m" }
            .joined(separator: "\n")
        XCTAssertEqual(GoldSrcEngineLog.evidence(in: console, addresses: poligon, now: now)?.outcome, .banned)
        // Another reason → `disconnected` (not a ban).
        let full = Self.block(header: header(now.addingTimeInterval(-60)), address: "51.68.190.91:27015",
                              answer: "Server issued disconnect. Reason: Server is full.")
        XCTAssertEqual(GoldSrcEngineLog.evidence(in: full, addresses: poligon, now: now)?.outcome, .disconnected)
    }

    /// Only the last GoldSrc block counts, and only for this server's address.
    func testUnrelatedHostIsIgnored() {
        let other = Self.block(header: header(now.addingTimeInterval(-120)), address: "192.0.2.50:27015",
                               answer: "Server issued disconnect. Reason: You have been banned from this server.")
        XCTAssertNil(GoldSrcEngineLog.evidence(in: other, addresses: poligon, now: now))
        // POLIGON banned earlier, then a later session joined another server → the last block is not POLIGON's.
        let poligonBan = Self.block(header: header(now.addingTimeInterval(-3600)), address: "51.68.190.91:27015",
                                    answer: "Server issued disconnect. Reason: You have been banned from this server.")
        let later = Self.block(header: header(now.addingTimeInterval(-60)), address: "192.0.2.50:27015", answer: nil)
        XCTAssertNil(GoldSrcEngineLog.evidence(in: poligonBan + later, addresses: poligon, now: now))
        // Same server on another port is another server.
        let port = GoldSrcEngineLog.addresses(host: "51.68.190.91", port: 27016, resolved: nil)
        XCTAssertNil(GoldSrcEngineLog.evidence(in: poligonBan, addresses: port, now: now))
        // A hostname row matches the resolved IP the engine connected to.
        let named = GoldSrcEngineLog.addresses(host: "rpg.example.test", port: 27015, resolved: "51.68.190.91")
        let recent = Self.block(header: header(now.addingTimeInterval(-60)), address: "51.68.190.91:27015",
                                answer: "Server issued disconnect. Reason: You have been banned from this server.")
        XCTAssertEqual(GoldSrcEngineLog.evidence(in: recent, addresses: named, now: now)?.outcome, .banned)
    }

    /// A stale block (older session than 24 h, older than the last Join Game, no session date) is no evidence.
    func testStaleLogIsIgnored() {
        let old = Self.block(header: header(now.addingTimeInterval(-2 * 24 * 3600)), address: "51.68.190.91:27015",
                             answer: "Server issued disconnect. Reason: You have been banned from this server.")
        XCTAssertNil(GoldSrcEngineLog.evidence(in: old, addresses: poligon, now: now))
        let hourAgo = Self.block(header: header(now.addingTimeInterval(-3600)), address: "51.68.190.91:27015",
                                 answer: "Server issued disconnect. Reason: You have been banned from this server.")
        XCTAssertNotNil(GoldSrcEngineLog.evidence(in: hourAgo, addresses: poligon, now: now))
        XCTAssertNil(GoldSrcEngineLog.evidence(in: hourAgo, addresses: poligon, now: now,
                                               notBefore: now.addingTimeInterval(-600)))
        let undated = hourAgo.replacingOccurrences(of: "Game started at", with: "Game launched")
        XCTAssertNil(GoldSrcEngineLog.evidence(in: undated, addresses: poligon, now: now))
        // No answer in the block (engine killed before the server answered) → no evidence.
        // The engine entered and nothing followed → `connected` (it only clears an older ban; never "no block").
        let silent = Self.block(header: header(now.addingTimeInterval(-60)), address: "51.68.190.91:27015", answer: nil)
        XCTAssertEqual(GoldSrcEngineLog.evidence(in: silent, addresses: poligon, now: now)?.outcome, .connected)
        let noEntry = silent.replacingOccurrences(of: "Spooling demo header.", with: "")
        XCTAssertNil(GoldSrcEngineLog.evidence(in: noEntry, addresses: poligon, now: now))
        XCTAssertNil(GoldSrcEngineLog.evidence(in: "", addresses: poligon, now: now))
    }

    /// The reason is cleaned: control characters removed, IP addresses masked, at most 200 characters.
    func testReasonIsCleaned() throws {
        let text = Self.block(header: header(now.addingTimeInterval(-60)), address: "51.68.190.91:27015",
                              answer: "Server issued disconnect. Reason: Your IP 198.51.100.10 is banned \u{07}"
                                + String(repeating: "x", count: 400))
        let evidence = try XCTUnwrap(GoldSrcEngineLog.evidence(in: text, addresses: poligon, now: now))
        XCTAssertFalse(evidence.reason.contains("198.51.100.10"))
        XCTAssertLessThanOrEqual(evidence.reason.count, 200)
        XCTAssertEqual(evidence.outcome, .banned)
    }
}

@MainActor
final class GoldSrcEngineLogAppTests: XCTestCase {
    private static let app = "/Applications/Xash3D-FWGS.app"

    /// Refresh: without engine log evidence the GoldSrc row is "unverified" (never "no block"); the engine log of the
    /// last GoldSrc connection to this server makes it "server ban"; another server's log changes nothing.
    func testRefreshReadsTheEngineLog() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let transport = GoldSrcFixture.server(clock: env.clock, connect: nil)
        let model = env.makeModel(udp: transport) {
            $0.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]),
                                               homeDirectory: URL(fileURLWithPath: "/Users/test"))
            $0.gameLaunchRunner = runner
        }
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        model.addServer(ServerDraft(label: "Other", host: "192.0.2.50"))
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcUnverified)
        XCTAssertNotEqual(model.servers.first?.banCheck?.status.label, L10n.text(.banStatusNoBlock))
        XCTAssertTrue(model.report?.reasons.contains { $0.code == .goldSrcBanUnverified } ?? false)

        // Join Game (gs + engine log), then the engine writes the server's ban.
        await model.joinGame(id)?.value
        XCTAssertEqual(runner.commands.last?.suffix(6), ["-dev", "1", "-log", "+connect", "51.68.190.91:27015", "gs"])
        env.clock.advance(60)
        let log = GoldSrcLogTests.block(header: GoldSrcPresentationTests.sessionHeader(env.clock.now),
                                        address: "51.68.190.91:27015",
                                        answer: "Server issued disconnect. Reason: You have been banned from this server.")
        try env.temp.write("home/Library/Application Support/Xash3D FWGS/engine.log", log)
        env.clock.advance(60)
        await model.refresh().value
        let check = try XCTUnwrap(model.servers.first?.banCheck)
        XCTAssertEqual(check.status, .goldSrcBanned)
        XCTAssertTrue(check.detail.contains("You have been banned from this server."))
        XCTAssertEqual(model.rowStatus(id)?.displayLevel, .red)
        XCTAssertTrue(model.report?.reasons.contains { $0.code == .goldSrcBanned } ?? false)
        XCTAssertNil(model.rowStatus(id)?.currentCID)
        // The other server (Source fixture path) is untouched by POLIGON's log.
        XCTAssertNotEqual(model.servers.last?.banCheck?.status, .goldSrcBanned)
        try inTurkish { XCTAssertEqual(MessageCode.goldSrcBanned.text, "Sunucu bağlantıyı yasakladı (motor günlüğü).") }
    }

    /// A log block older than the last Join Game of this session is stale.
    func testLogOlderThanTheLastJoinIsIgnored() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let model = env.makeModel(udp: GoldSrcFixture.server(clock: env.clock, connect: nil)) {
            $0.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]),
                                               homeDirectory: URL(fileURLWithPath: "/Users/test"))
            $0.gameLaunchRunner = runner
        }
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.refresh().value
        await model.joinGame(id)?.value
        XCTAssertNotNil(model.goldSrcJoins[id])
        // A ban block from a session an hour before this Join Game (the new session wrote nothing yet).
        let log = GoldSrcLogTests.block(header: GoldSrcPresentationTests.sessionHeader(env.clock.now.addingTimeInterval(-3600)),
                                        address: "51.68.190.91:27015",
                                        answer: "Server issued disconnect. Reason: You have been banned from this server.")
        try env.temp.write("home/Library/Application Support/Xash3D FWGS/engine.log", log)
        env.clock.advance(60)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcUnverified)
    }

    private func inTurkish<T>(_ body: () throws -> T) throws -> T {
        try L10n.$bundle.withValue(XCTUnwrap(L10n.languageBundle("tr")), operation: body)
    }
}

// MARK: - Review fixes (blockers 1–4, A–E)

final class GoldSrcBanTextTests: XCTestCase {
    /// One classifier for probe replies, the engine log, UI and CLI: real ban sentences only.
    func testBanPhrases() {
        for ban in ["You have been banned from this server.", "you are banned", "You're banned (30 min)",
                    "Banned from this server", "banned", "Your IP is banned", "Kicked: banned"] {
            XCTAssertTrue(GoldSrcBanText.isBan(ban), ban)
        }
        for notBan in ["Bandwidth limit exceeded", "bandwidth limit exceeded", "you are unbanned", "You are not banned",
                       "not banned", "You are no longer banned", "Player was un-banned", "isn't banned", "ban list reloaded",
                       "not banned from this server", "unbanned from this server", "you are not banned from this server",
                       "never banned from this server", "no longer banned from this server", "you were unbanned",
                       "Server is full.", "Sorry, no-steam p48 clients are not allowed on this server", ""] {
            XCTAssertFalse(GoldSrcBanText.isBan(notBan), notBan)
        }
        // The probe and the engine log use it.
        XCTAssertEqual(GoldSrcReplies.connect(FakeServer.oobText("9Bandwidth limit exceeded\n")).outcome, .rejected)
        XCTAssertEqual(GoldSrcReplies.connect(FakeServer.oobText("9You are not banned, server full\n")).outcome, .rejected)
        if case .challenge = GoldSrcReplies.challenge(FakeServer.oobText("A00000000 12 2\n")) {} else { XCTFail() }
        if case .banned = GoldSrcReplies.challenge(FakeServer.oobText("lYou are unbanned\n")) { XCTFail() }
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let header = GoldSrcPresentationTests.sessionHeader(now.addingTimeInterval(-60))
        for (reason, outcome) in [("Bandwidth limit exceeded", GoldSrcLogEvidence.Outcome.disconnected),
                                  ("You are unbanned", .disconnected), ("You have been banned from this server.", .banned)] {
            let log = GoldSrcLogTests.block(header: header, address: "51.68.190.91:27015",
                                            answer: "Server issued disconnect. Reason: " + reason)
            XCTAssertEqual(GoldSrcEngineLog.evidence(in: log, addresses: ["51.68.190.91:27015"], now: now)?.outcome, outcome,
                           reason)
        }
    }
}

final class GoldSrcStatusTests: XCTestCase {
    /// (C) the protocol decision comes before the address: a known GoldSrc server with an unresolved host shows no CID
    /// (not even the old saved one) and keeps the invalid-host message.
    func testKnownGoldSrcWithUnresolvedHost() {
        let entry = ServerEntry(label: "S", host: "rpg.example.test", cid: "d9de0eb4419608a8423241430581e91c")
        let status = StatusEvaluator.serverRow(entry, rawID: 0, saved: nil, knownProtocol: .goldsrc48)
        XCTAssertNil(status.currentCID)
        XCTAssertTrue(status.cidNotApplicable)
        XCTAssertEqual(status.message, .invalidHost)
        // A saved GoldSrc result decides it as well (no memory).
        var saved = entry
        saved.banCheck = BanCheck(status: .goldSrcUnverified, checkedAt: Date(), detail: "")
        XCTAssertTrue(StatusEvaluator.serverRow(saved, rawID: 0, saved: nil).cidNotApplicable)
        XCTAssertEqual(StatusEvaluator.protocolOf(saved), .goldsrc48)
    }
}

@MainActor
final class GoldSrcReviewAppTests: XCTestCase {
    private static let app = "/Applications/Xash3D-FWGS.app"
    private static let legacyCID = "d9de0eb4419608a8423241430581e91c"

    private func install(_ deps: inout AppDependencies, runner: FakeGameLaunchRunner) {
        deps.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]),
                                             homeDirectory: URL(fileURLWithPath: "/Users/test"))
        deps.gameLaunchRunner = runner
    }

    private func banLog(_ env: TestAppEnvironment, at date: Date, answer: String?) throws {
        try env.temp.write("home/Library/Application Support/Xash3D FWGS/engine.log",
                           GoldSrcLogTests.block(header: GoldSrcPresentationTests.sessionHeader(date),
                                                 address: "51.68.190.91:27015", answer: answer))
    }

    /// (C) menu bar: a GoldSrc row whose hostname no longer resolves never offers its old saved CID.
    func testMenuBarHasNoCIDForUnresolvedGoldSrcHost() async throws {
        let env = try TestAppEnvironment()
        let id = UUID()
        var entry = ServerEntry(id: id, label: "RPG", host: "rpg.example.test", cid: Self.legacyCID)
        entry.banCheck = BanCheck(status: .goldSrcUnverified, checkedAt: env.clock.now, detail: "",
                                  info: ServerInfo(name: "RPG", serverProtocol: .goldsrc48))
        let record = Snapshot(savedAt: env.clock.now, gamedir: "valve",
                              dataRoot: env.home.appendingPathComponent("Library/Application Support/Xash3D FWGS").path,
                              displayName: "N", model: "gordon", rawID: "0000000000000000", identitySource: "",
                              network: NetworkInfo(publicIP: "203.0.113.7", lanIPs: []), servers: [entry])
        try SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).save(record)
        let resolver = FakeAddressResolver(["rpg.example.test": .failure(.notFound)])
        let model = env.makeModel(udp: FakeUDPTransport(clock: env.clock,
                                                        responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil)),
                                  resolver: resolver)
        await model.refresh().value
        XCTAssertEqual(model.rowStatus(id)?.message, .invalidHost)
        XCTAssertNil(model.rowStatus(id)?.currentCID)
        XCTAssertTrue(model.rowStatus(id)?.cidNotApplicable ?? false)
        XCTAssertNil(model.menuBarCID(for: id))
    }

    /// (D) a protocol learned while the "game is running" question is open is used by the confirmation.
    func testPendingJoinUsesTheProtocolKnownAtConfirmation() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let model = env.makeModel(udp: GoldSrcFixture.server(clock: env.clock, connect: nil),
                                  game: FakeGameDetector(running: true)) { self.install(&$0, runner: runner) }
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.joinGame(id)?.value
        XCTAssertNotNil(model.pendingJoin)
        XCTAssertEqual(model.pendingJoin?.plan.command.serverProtocol, .unknown)
        await model.refresh().value   // learns GoldSrc 48 while the question is open
        await model.confirmJoin()?.value
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands.first?.last, "gs")
        XCTAssertEqual(runner.commands.first?[1], "--env")
        // The row changed while asking → nothing is launched.
        await model.joinGame(id)?.value
        model.updateServer(id: id, with: ServerDraft(label: "POLIGON", host: "51.68.190.92"))
        await model.confirmJoin()?.value
        XCTAssertEqual(runner.commands.count, 1)
    }

    /// (3) the engine log decides independently of the A2S result: a ban is applied when A2S times out, kept while
    /// later results are unknown/unreachable, and cleared only by a newer engine session; an unreadable log is logged.
    func testEngineLogEvidenceIsIndependentOfA2S() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        final class Switch: @unchecked Sendable { let lock = NSLock(); var silent = false }
        let state = Switch()
        let transport = FakeUDPTransport(clock: env.clock) { _, packet in
            if state.lock.withLock({ state.silent }) { return [] }
            if FakeServer.isInfo(packet) { return [FakeReply(bytes: GoldSrcFixture.poligonLegacy)] }
            if FakeServer.isGetChallenge(packet) { return [FakeReply(bytes: GoldSrcFixture.poligonChallenge)] }
            return []
        }
        let model = env.makeModel(udp: transport) { self.install(&$0, runner: runner) }
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcUnverified)
        await model.joinGame(id)?.value
        env.clock.advance(60)
        try banLog(env, at: env.clock.now, answer: "Server issued disconnect. Reason: You have been banned from this server.")
        env.clock.advance(60)
        state.lock.withLock { state.silent = true }
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcBanned)   // A2S timed out, the log decides

        // The log disappears (missing) and A2S stays silent → the proven ban is kept.
        try FileManager.default.removeItem(at: env.home.appendingPathComponent("Library/Application Support/Xash3D FWGS/engine.log"))
        env.clock.advance(60)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcBanned)

        // An unreadable log is logged, never silent.
        let logURL = env.home.appendingPathComponent("Library/Application Support/Xash3D FWGS/engine.log")
        try Data("x".utf8).write(to: logURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path) }
        env.clock.advance(60)
        await model.refresh().value
        XCTAssertTrue(model.errorLog.entries.contains { $0.area == .serverProtocol && $0.message.hasPrefix("engineLog:") })
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcBanned)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        // A newer session that entered the server without a ban clears it (to "unverified", never "no block").
        env.clock.advance(60)
        await model.joinGame(id)?.value
        env.clock.advance(5)
        try banLog(env, at: env.clock.now, answer: nil)
        state.lock.withLock { state.silent = false }
        env.clock.advance(60)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcUnverified)
    }

    /// (A) `playeridentityctl ban --json`: no CID for GoldSrc 48 or unknown protocol; Source 49 keeps it.
    func testCLIBanJSONNeverLeaksTheCID() async throws {
        let temp = try TempDirectory()
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
        let clock = TestClock()
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        func run(_ transport: FakeUDPTransport) async throws -> (String, [String: Any]) {
            var context = CLIContext(version: "2.26.0", build: "54", paths: AppPaths(home: home), environment: [:],
                                     fileSystem: LocalFileSystem(), resolver: FakeAddressResolver(), udpTransport: transport,
                                     now: { clock.now })
            context.vpnActive = { false }
            let result = await CLIRunner.run(arguments: ["ban", "51.68.190.91:27015", "--json", "--no-metrics"], context: context)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                                       result.stdout + result.stderr)
            return (result.stdout, object)
        }
        let goldSrc = GoldSrcFixture.server(clock: clock, connect: FakeReply(bytes: FakeServer.oob(0x42)))
        let (text, object) = try await run(goldSrc)
        XCTAssertTrue(object["cid"] is NSNull)
        XCTAssertEqual(object["cidApplicable"] as? Bool, false)
        XCTAssertEqual(object["protocol"] as? String, "goldsrc48")
        XCTAssertTrue(object["banned"] is NSNull)
        XCTAssertFalse(text.contains(Self.legacyCID))
        XCTAssertFalse(goldSrc.sentPackets.contains(where: FakeServer.isConnect))
        let unknown = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: A2SFixture.source())))
        let (unknownText, unknownObject) = try await run(unknown)
        XCTAssertTrue(unknownObject["cid"] is NSNull)
        XCTAssertFalse(unknownText.contains(Self.legacyCID))
        XCTAssertFalse(unknown.sentPackets.contains(where: FakeServer.isConnect))
        let source = FakeUDPTransport(clock: clock, responder: FakeServer.scripted())
        let (_, sourceObject) = try await run(source)
        XCTAssertEqual(sourceObject["cid"] as? String, Self.legacyCID)
        XCTAssertEqual(sourceObject["cidApplicable"] as? Bool, true)
    }
}

// MARK: - Final review fixes (effective protocol, fresh Source 49, log-first, known GoldSrc, persistence)

final class GoldSrcEffectiveProtocolTests: XCTestCase {
    private let clock = TestClock()
    private let host = "51.68.190.91"

    /// The server claims Source 49 in A2S but answers connect 49 with the real "older protocol ( 48 )" text.
    private func olderProtocolServer() -> FakeUDPTransport {
        FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: GoldSrcFixture.source49()),
                                                                      connect: FakeReply(bytes: GoldSrcFixture.poligonOlderProtocol)))
    }

    /// (1) BanChecker and the diagnosis turn "older protocol 48" into the effective protocol `goldsrc48`.
    @MainActor func testOlderProtocolMakesTheServerGoldSrc() async throws {
        let clock = self.clock
        let request = BanCheckRequest(serverID: UUID(), host: host, port: 27015,
                                      endpoint: UDPEndpoint(address: TestAddresses.v4(host), port: 27015), cid: nil,
                                      name: "N", rawID: 0)
        let check = try await BanChecker(transport: olderProtocolServer(), now: { clock.now }).check(request)
        XCTAssertEqual(check.status, .goldSrcUnverified)
        XCTAssertEqual(check.info?.serverProtocol, .goldsrc48)
        XCTAssertTrue(check.detail.contains("older protocol ( 48 )"))
        var diagnosisRequest = ConnectionDiagnosisRequest(host: host, port: 27015, rawID: 0, name: "N", checksEnabled: true,
                                                          vpnActive: false, knownRange: nil)
        diagnosisRequest.legacyProbeConfirmed = true
        let probe = try await ConnectionDiagnoser(transport: olderProtocolServer(), resolver: FakeAddressResolver(),
                                                  now: { clock.now }).run(diagnosisRequest)
        XCTAssertEqual(probe.serverProtocol, .goldsrc48)
        XCTAssertNil(probe.cid)
        XCTAssertEqual(probe.verdict, .legacyVerificationUnavailable)
        XCTAssertNotEqual(probe.verdict, .protocolMismatch)
        let diagnosis = ConnectionDiagnosis(serverID: nil, label: "", host: host, port: 27015, startedAt: clock.now,
                                            probe: probe, engineLog: .missing)
        XCTAssertNil(diagnosis.bannedValue)
        var session = AppModel.DiagnosisSession(token: UUID(), serverID: UUID())
        session.steps = probe.steps
        session.result = diagnosis
        XCTAssertTrue(ConnectionDiagnosisSection.visibleSteps(session).contains(.connect49))   // the step that ran
    }

    /// (1) CLI `diagnose --json` and `ban --json` on that answer: goldsrc48, `cid: null`, `cidApplicable: false`,
    /// `goldSrc: true`, `banned: null`.
    func testCLIOnOlderProtocol() async throws {
        let temp = try TempDirectory()
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        let clock = self.clock
        func run(_ arguments: [String]) async throws -> [String: Any] {
            var context = CLIContext(version: "2.26.0", build: "54", paths: AppPaths(home: home), environment: [:],
                                     fileSystem: LocalFileSystem(), resolver: FakeAddressResolver(),
                                     udpTransport: olderProtocolServer(), now: { clock.now })
            context.vpnActive = { false }
            let result = await CLIRunner.run(arguments: arguments, context: context)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                                 result.stdout + result.stderr)
        }
        let diagnose = try await run(["diagnose", "51.68.190.91:27015", "--json"])
        XCTAssertEqual(diagnose["protocol"] as? String, "goldsrc48")
        XCTAssertTrue(diagnose["cid"] is NSNull)
        XCTAssertEqual(diagnose["cidApplicable"] as? Bool, false)
        XCTAssertEqual(diagnose["goldSrc"] as? Bool, true)
        XCTAssertTrue(diagnose["banned"] is NSNull)
        XCTAssertEqual(diagnose["verdict"] as? String, "legacyVerificationUnavailable")
        let ban = try await run(["ban", "51.68.190.91:27015", "--json", "--no-metrics"])
        XCTAssertEqual(ban["protocol"] as? String, "goldsrc48")
        XCTAssertTrue(ban["cid"] is NSNull)
        XCTAssertEqual(ban["cidApplicable"] as? Bool, false)
        XCTAssertTrue(ban["banned"] is NSNull)
    }

    /// (5) a saved GoldSrc 48 server whose A2S times out (or whose hostname fails) never reads as "not banned".
    func testKnownGoldSrcWithNetworkFailureCLI() async throws {
        let temp = try TempDirectory()
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        let clock = self.clock
        let record = Snapshot(savedAt: clock.now, gamedir: "valve", dataRoot: temp.url.appendingPathComponent("data").path,
                              displayName: "N", model: "m", rawID: "0000000000000000", identitySource: "",
                              network: NetworkInfo(publicIP: "", lanIPs: []),
                              servers: [ServerEntry(label: "POLIGON", host: "51.68.190.91",
                                                    banCheck: BanCheck(status: .goldSrcUnverified, checkedAt: clock.now, detail: "")),
                                        ServerEntry(label: "Named", host: "rpg.example.test",
                                                    banCheck: BanCheck(status: .goldSrcUnverified, checkedAt: clock.now, detail: ""))])
        let url = temp.url.appendingPathComponent("record/profile.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SnapshotStore(fileURL: url).save(record)
        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        func run(_ arguments: [String], resolver: FakeAddressResolver = FakeAddressResolver()) async throws -> [String: Any] {
            var context = CLIContext(version: "2.26.0", build: "54", paths: AppPaths(home: home),
                                     environment: [CLIContext.snapshotEnvironmentKey: url.path],
                                     fileSystem: LocalFileSystem(), resolver: resolver, udpTransport: silent, now: { clock.now })
            context.vpnActive = { false }
            let result = await CLIRunner.run(arguments: arguments, context: context)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                                 result.stdout + result.stderr)
        }
        let timeout = try await run(["diagnose", "1", "--json"])
        XCTAssertTrue(timeout["banned"] is NSNull)
        XCTAssertTrue(timeout["cid"] is NSNull)
        XCTAssertEqual(timeout["protocol"] as? String, "goldsrc48")
        XCTAssertEqual(timeout["verdict"] as? String, "legacyVerificationUnavailable")
        XCTAssertFalse(silent.sentPackets.contains(where: FakeServer.isConnect))
        let dns = try await run(["diagnose", "2", "--json"],
                                resolver: FakeAddressResolver(["rpg.example.test": .failure(.notFound)]))
        XCTAssertTrue(dns["banned"] is NSNull)
        XCTAssertTrue(dns["cid"] is NSNull)
        let ban = try await run(["ban", "51.68.190.91:27015", "--json", "--no-metrics"])
        XCTAssertTrue(ban["banned"] is NSNull)
        XCTAssertTrue(ban["cid"] is NSNull)
        XCTAssertEqual(ban["protocol"] as? String, "goldsrc48")
        // `status --json` derives the protocol from the saved GoldSrc result (no info in the record).
        let status = try await run(["status", "--json"])
        let rows = try XCTUnwrap(status["servers"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["protocol"] as? String, "goldsrc48")
        XCTAssertTrue(rows.first?["cid"] is NSNull)
        XCTAssertTrue((rows.first?["ban"] as? [String: Any])?["banned"] is NSNull)
    }
}

@MainActor
final class GoldSrcRefreshOrderTests: XCTestCase {
    private static let app = "/Applications/Xash3D-FWGS.app"
    private var logPath: String { "home/Library/Application Support/Xash3D FWGS/engine.log" }

    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var info: [UInt8]? = GoldSrcFixture.poligonLegacy
        var connect: [UInt8]? = nil
    }

    private func transport(_ env: TestAppEnvironment, _ script: Script) -> FakeUDPTransport {
        FakeUDPTransport(clock: env.clock) { _, packet in
            script.lock.lock(); defer { script.lock.unlock() }
            if FakeServer.isInfo(packet) { return script.info.map { [FakeReply(bytes: $0)] } ?? [] }
            guard script.info != nil else { return [] }
            if FakeServer.isGetChallenge(packet) {
                return [FakeReply(bytes: script.info == GoldSrcFixture.poligonLegacy ? GoldSrcFixture.poligonChallenge
                                                                                    : FakeServer.oob(0x41, FakeServer.challengeBytes))]
            }
            if FakeServer.isConnect(packet) { return script.connect.map { [FakeReply(bytes: $0)] } ?? [] }
            return []
        }
    }

    private func banLog(_ env: TestAppEnvironment, at date: Date) throws {
        try env.temp.write(logPath, GoldSrcLogTests.block(header: GoldSrcPresentationTests.sessionHeader(date),
                                                          address: "51.68.190.91:27015",
                                                          answer: "Server issued disconnect. Reason: You have been banned from this server."))
    }

    /// (4) first refresh of a just-added server, A2S times out, a valid engine log → Server ban (also with checks off).
    func testFirstRefreshWithTimeoutAppliesTheLog() async throws {
        let env = try TestAppEnvironment()
        let script = Script()
        script.info = nil
        try banLog(env, at: env.clock.now.addingTimeInterval(-300))
        let model = env.makeModel(udp: transport(env, script))
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcBanned)
        XCTAssertEqual(model.servers.first?.banCheck?.info?.serverProtocol, .goldsrc48)
        XCTAssertTrue(model.isCIDNotApplicable(id))
        XCTAssertEqual(model.launchProtocol(for: id), .goldsrc48)

        let offEnv = try TestAppEnvironment()
        try banLog(offEnv, at: offEnv.clock.now.addingTimeInterval(-300))
        let off = offEnv.makeModel(udp: transport(offEnv, Script()))
        off.banCheckEnabled = false
        off.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        await off.refresh().value
        XCTAssertEqual(off.servers.first?.banCheck?.status, .goldSrcBanned)   // no request at all, the log still decides
    }

    /// (2) an older GoldSrc ban + a fresh Source 49 result → the Source 49 result stands.
    func testFreshSource49WinsOverAnOldGoldSrcLog() async throws {
        let env = try TestAppEnvironment()
        let script = Script()
        try banLog(env, at: env.clock.now.addingTimeInterval(-300))
        let model = env.makeModel(udp: transport(env, script))
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcBanned)
        env.clock.advance(60)
        script.lock.withLock { script.info = GoldSrcFixture.source49(); script.connect = FakeServer.oob(0x42) }
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .cidOk)
        XCTAssertEqual(model.servers.first?.banCheck?.info?.serverProtocol, .source49)
    }

    /// (1) the app learns GoldSrc from the connect answer and joins with `gs`.
    func testOlderProtocolAnswerJoinsWithGs() async throws {
        let env = try TestAppEnvironment()
        let runner = FakeGameLaunchRunner()
        let script = Script()
        script.info = GoldSrcFixture.source49()
        script.connect = GoldSrcFixture.poligonOlderProtocol
        let model = env.makeModel(udp: transport(env, script)) {
            $0.gameAppLocator = GameAppLocator(fileSystem: FakeDirectories(directories: [Self.app]),
                                               homeDirectory: URL(fileURLWithPath: "/Users/test"))
            $0.gameLaunchRunner = runner
        }
        model.addServer(ServerDraft(label: "POLIGON", host: "51.68.190.91"))
        let id = try XCTUnwrap(model.servers.first?.id)
        await model.refresh().value
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcUnverified)
        XCTAssertEqual(model.launchProtocol(for: id), .goldsrc48)
        XCTAssertNil(model.rowStatus(id)?.currentCID)
        await model.joinGame(id)?.value
        XCTAssertEqual(runner.commands.first?.last, "gs")
    }

    /// (6) the GoldSrc decision is saved with the record; after a restart an A2S time-out keeps GoldSrc, the CID stays
    /// N/A and the engine log evidence still applies.
    func testGoldSrcDecisionSurvivesARestart() async throws {
        let env = try TestAppEnvironment()
        let id = UUID()
        let record = Snapshot(savedAt: env.clock.now, gamedir: "valve",
                              dataRoot: env.home.appendingPathComponent("Library/Application Support/Xash3D FWGS").path,
                              displayName: "N", model: "gordon", rawID: "0000000000000000", identitySource: "",
                              network: NetworkInfo(publicIP: "203.0.113.7", lanIPs: ["en0 192.0.2.10"]),
                              servers: [ServerEntry(id: id, label: "POLIGON", host: "51.68.190.91",
                                                    cid: "d9de0eb4419608a8423241430581e91c")])
        let store = SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile)
        try store.save(record)
        let first = env.makeModel(udp: transport(env, Script()))
        await first.refresh().value
        let saved = try XCTUnwrap(store.load().snapshot?.servers.first)
        XCTAssertEqual(saved.cid, "")
        XCTAssertEqual(saved.banCheck?.info?.serverProtocol, .goldsrc48)   // protocol + result written together
        XCTAssertEqual(saved.banCheck?.status, .goldSrcUnverified)
        XCTAssertFalse(first.hasUnsavedChanges)

        // Restart, the server does not answer.
        env.clock.advance(60)
        let silent = Script()
        silent.info = nil
        let restarted = env.makeModel(udp: transport(env, silent))
        await restarted.refresh().value
        XCTAssertEqual(restarted.launchProtocol(for: id), .goldsrc48)
        XCTAssertTrue(restarted.isCIDNotApplicable(id))
        XCTAssertNil(restarted.rowStatus(id)?.currentCID)
        XCTAssertNil(restarted.menuBarCID(for: id))
        XCTAssertEqual(restarted.servers.first?.banCheck?.info?.serverProtocol, .goldsrc48)
        // The engine log is read and applied.
        try banLog(env, at: env.clock.now)
        env.clock.advance(60)
        await restarted.refresh().value
        XCTAssertEqual(restarted.servers.first?.banCheck?.status, .goldSrcBanned)
        XCTAssertEqual(store.load().snapshot?.servers.first?.banCheck?.status, .goldSrcBanned)
    }
}

// MARK: - Capability probe and DNS-loss address match (v5.4.5)

final class GoldSrcCapabilityProbeTests: XCTestCase {
    private let clock = TestClock()
    private let host = "51.68.190.91"
    private static let rawID: UInt64 = 0x0123456789ABCDEF

    private var realCID: String { CIDCalculator.cid(rawID: Self.rawID, address: TestAddresses.v4(host)) }

    private func connects(_ transport: FakeUDPTransport) -> [String] {
        transport.sentPackets.filter(FakeServer.isConnect).map { String(decoding: $0, as: UTF8.self) }
    }

    private func assertNoSecret(_ packets: [String], file: StaticString = #filePath, line: UInt = #line) {
        for packet in packets {
            XCTAssertFalse(packet.contains(realCID), packet, file: file, line: line)
            XCTAssertFalse(packet.lowercased().contains("0123456789abcdef"), packet, file: file, line: line)
        }
    }

    private func request() -> BanCheckRequest {
        BanCheckRequest(serverID: UUID(), host: host, port: 27015,
                        endpoint: UDPEndpoint(address: TestAddresses.v4(host), port: 27015), cid: nil, name: "N",
                        rawID: Self.rawID)
    }

    /// POLIGON answers the first, CID-less capability packet with "older protocol ( 48 )": the real CID is never
    /// sent (nor computed in the diagnosis), the server is GoldSrc 48.
    func testOlderProtocolGetsOnlyTheCIDLessProbe() async throws {
        let clock = self.clock
        let server = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: GoldSrcFixture.source49()), connect: FakeReply(bytes: GoldSrcFixture.poligonOlderProtocol)))
        let check = try await BanChecker(transport: server, now: { clock.now }).check(request())
        XCTAssertEqual(check.status, .goldSrcUnverified)
        XCTAssertEqual(check.info?.serverProtocol, .goldsrc48)
        let sent = connects(server)
        XCTAssertEqual(sent.count, 1)   // no second, real-CID packet
        XCTAssertTrue(sent[0].contains("uuid=" + BanPackets.capabilityCID))
        assertNoSecret(sent)

        let diagnosed = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: GoldSrcFixture.source49()), connect: FakeReply(bytes: GoldSrcFixture.poligonOlderProtocol)))
        let probe = try await ConnectionDiagnoser(transport: diagnosed, resolver: FakeAddressResolver(), now: { clock.now })
            .run(ConnectionDiagnosisRequest(host: host, port: 27015, rawID: Self.rawID, name: "N", checksEnabled: true,
                                            vpnActive: false, knownRange: nil))
        XCTAssertEqual(probe.serverProtocol, .goldsrc48)
        XCTAssertNil(probe.cid)
        XCTAssertEqual(probe.verdict, .legacyVerificationUnavailable)
        XCTAssertEqual(connects(diagnosed).count, 1)
        assertNoSecret(connects(diagnosed))
        assertNoSecret(probe.steps.map(\.detail))
    }

    /// A Source 49 server: capability packet first (placeholder CID), then the real CID check as before.
    func testSource49StillGetsTheRealCIDCheckAfterTheProbe() async throws {
        let clock = self.clock
        let server = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(info: FakeReply(bytes: GoldSrcFixture.source49())))
        let check = try await BanChecker(transport: server, now: { clock.now }).check(request())
        XCTAssertEqual(check.status, .cidOk)
        let sent = connects(server)
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent[0].contains("uuid=" + BanPackets.capabilityCID))
        assertNoSecret([sent[0]])
        XCTAssertTrue(sent[1].contains("uuid=" + realCID))
        // A CID ban is still found by the real-CID packet.
        let banned = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: GoldSrcFixture.source49()),
            connect: FakeReply(bytes: FakeServer.oobText("9Disconnect: You are banned (CID)"))))
        let bannedCheck = try await BanChecker(transport: banned, now: { clock.now }).check(request())
        XCTAssertEqual(bannedCheck.status, .cidBanned)
        XCTAssertEqual(connects(banned).count, 2)
        // No answer to the capability probe → no real CID either.
        let silent = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: GoldSrcFixture.source49()), connect: nil))
        let silentCheck = try await BanChecker(transport: silent, now: { clock.now }).check(request())
        XCTAssertEqual(silentCheck.status, .cidUnknown)
        XCTAssertEqual(connects(silent).count, 1)
        assertNoSecret(connects(silent))
    }

    private func diagnose(_ transport: FakeUDPTransport, clock: TestClock) async throws -> ConnectionProbeResult {
        try await ConnectionDiagnoser(transport: transport, resolver: FakeAddressResolver(), now: { clock.now })
            .run(ConnectionDiagnosisRequest(host: host, port: 27015, rawID: Self.rawID, name: "N", checksEnabled: true,
                                            vpnActive: false, knownRange: nil))
    }

    /// (v5.4.6) a ban text to the placeholder: exactly one packet, no real CID; a general/IP ban, never a CID ban.
    func testCapabilityBannedSendsNoRealCID() async throws {
        let clock = self.clock
        func server() -> FakeUDPTransport {
            FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
                info: FakeReply(bytes: GoldSrcFixture.source49()),
                connect: FakeReply(bytes: FakeServer.oob(0x42)),
                capability: .reply(FakeReply(bytes: FakeServer.oobText("9You have been banned from this server.\n")))))
        }
        let checked = server()
        let check = try await BanChecker(transport: checked, now: { clock.now }).check(request())
        XCTAssertEqual(check.status, .ipBanned)
        XCTAssertNotEqual(check.status, .cidUnknown)
        XCTAssertNotEqual(check.status, .cidBanned)
        XCTAssertEqual(connects(checked).count, 1)
        XCTAssertTrue(connects(checked)[0].contains("uuid=" + BanPackets.capabilityCID))
        assertNoSecret(connects(checked))
        let diagnosed = server()
        let probe = try await diagnose(diagnosed, clock: clock)
        XCTAssertEqual(probe.verdict, .ipBanned)
        XCTAssertNil(probe.cid)
        XCTAssertEqual(connects(diagnosed).count, 1)
        assertNoSecret(connects(diagnosed) + probe.steps.map(\.detail))
    }

    /// (v5.4.6) an unrecognized answer to the placeholder: one packet, no real CID, `banned` is null (never false).
    func testCapabilityUnrecognizedIsUndecided() async throws {
        let clock = self.clock
        func server() -> FakeUDPTransport {
            FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
                info: FakeReply(bytes: GoldSrcFixture.source49()), connect: FakeReply(bytes: FakeServer.oob(0x42)),
                capability: .reply(FakeReply(bytes: FakeServer.oobText("A00000000 1270654979 3 1 1\n")))))
        }
        let checked = server()
        let check = try await BanChecker(transport: checked, now: { clock.now }).check(request())
        XCTAssertEqual(check.status, .cidUnknown)
        XCTAssertEqual(connects(checked).count, 1)
        assertNoSecret(connects(checked))
        let diagnosed = server()
        let probe = try await diagnose(diagnosed, clock: clock)
        XCTAssertNil(probe.cid)
        XCTAssertTrue(probe.cidCheckIncomplete)
        XCTAssertEqual(connects(diagnosed).count, 1)
        let diagnosis = ConnectionDiagnosis(serverID: nil, label: "", host: host, port: 27015, startedAt: clock.now,
                                            probe: probe, engineLog: .missing)
        XCTAssertNil(diagnosis.bannedValue)
        // CLI `ban --json`: `banned: null`, no CID anywhere.
        let temp = try TempDirectory()
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
        var context = CLIContext(version: "2.26.0", build: "54", paths: AppPaths(home: temp.url.appendingPathComponent("home")),
                                 environment: [:], fileSystem: LocalFileSystem(), resolver: FakeAddressResolver(),
                                 udpTransport: server(), now: { clock.now })
        context.vpnActive = { false }
        let result = await CLIRunner.run(arguments: ["ban", "51.68.190.91:27015", "--json", "--no-metrics"], context: context)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertTrue(object["banned"] is NSNull)
        XCTAssertEqual(object["status"] as? String, "cidUnknown")
        XCTAssertFalse(result.stdout.contains("d9de0eb4419608a8423241430581e91c"))
    }

    /// (v5.4.6) an accepted placeholder but the overall budget is used up → no second packet.
    func testCapabilityOkButNoTimeLeftSendsNoRealCID() async throws {
        let clock = self.clock
        func server() -> FakeUDPTransport {
            FakeUDPTransport(clock: clock) { _, packet in
                if FakeServer.isInfo(packet) { return [FakeReply(bytes: GoldSrcFixture.source49())] }
                if FakeServer.isGetChallenge(packet) { return [FakeReply(bytes: FakeServer.oob(0x41, FakeServer.challengeBytes))] }
                if FakeServer.isCapabilityProbe(packet) {
                    clock.advance(60)   // the answer comes after the whole budget
                    return [FakeReply(bytes: FakeServer.oob(0x42))]
                }
                if FakeServer.isConnect(packet) { return [FakeReply(bytes: FakeServer.oob(0x42))] }
                return []
            }
        }
        let checked = server()
        let check = try await BanChecker(transport: checked, now: { clock.now }).check(request())
        XCTAssertEqual(check.status, .cidUnknown)
        XCTAssertEqual(connects(checked).count, 1)
        assertNoSecret(connects(checked))
        let diagnosed = server()
        let probe = try await diagnose(diagnosed, clock: clock)
        XCTAssertEqual(connects(diagnosed).count, 1)
        XCTAssertNil(probe.cid)
        XCTAssertTrue(probe.cidCheckIncomplete)
    }

    /// (v5.4.6) an accepted placeholder with time left → exactly two packets, the second with the real CID.
    func testCapabilityOkWithTimeLeftSendsTheRealCID() async throws {
        let clock = self.clock
        let server = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: GoldSrcFixture.source49()), connect: FakeReply(bytes: FakeServer.oob(0x42)),
            capability: .reply(FakeReply(bytes: FakeServer.oob(0x42)))))
        let probe = try await diagnose(server, clock: clock)
        let sent = connects(server)
        XCTAssertEqual(sent.count, 2)
        assertNoSecret([sent[0]])
        XCTAssertTrue(sent[1].contains("uuid=" + realCID))
        XCTAssertEqual(probe.cid, realCID)
        XCTAssertEqual(probe.verdict, .noBan)
        XCTAssertFalse(probe.cidCheckIncomplete)
    }

    func testReportedAddressIsOnlyAnIPLiteral() {
        XCTAssertEqual(GoldSrcEngineLog.ipLiteral("51.68.190.91:27015"), "51.68.190.91")
        XCTAssertEqual(GoldSrcEngineLog.ipLiteral("51.68.190.91"), "51.68.190.91")
        XCTAssertEqual(GoldSrcEngineLog.ipLiteral("[2001:DB8::1]:27015"), "2001:db8::1")
        XCTAssertEqual(GoldSrcEngineLog.ipLiteral("2001:db8::1"), "2001:db8::1")
        for bad in ["evil.example:27015", "/etc/passwd", "51.68.190.91; rm -rf ~", "../../x", "", "[]:1", "1.2.3:4"] {
            XCTAssertNil(GoldSrcEngineLog.ipLiteral(bad), bad)
        }
        let set = GoldSrcEngineLog.addresses(host: "rpg.example.test", port: 27015, resolved: nil,
                                             known: ["51.68.190.91:27016", nil, "evil.example:27015"])
        XCTAssertEqual(set, ["rpg.example.test:27015", "51.68.190.91:27015"])   // the row's port, IPs only
    }
}

@MainActor
final class GoldSrcDNSLossTests: XCTestCase {
    /// Hostname row, DNS fails now, the saved GoldSrc result carries the server's own address string; the engine log's
    /// ban for 51.68.190.91:27015 still matches → Server ban.
    func testDNSFailureStillMatchesTheEngineLog() async throws {
        let env = try TestAppEnvironment()
        let id = UUID()
        var entry = ServerEntry(id: id, label: "RPG", host: "rpg.example.test")
        entry.banCheck = BanCheck(status: .goldSrcUnverified, checkedAt: env.clock.now.addingTimeInterval(-600), detail: "",
                                  info: ServerInfo(name: "RPG", serverProtocol: .goldsrc48,
                                                   reportedAddress: "51.68.190.91:27015"))
        let record = Snapshot(savedAt: env.clock.now, gamedir: "valve",
                              dataRoot: env.home.appendingPathComponent("Library/Application Support/Xash3D FWGS").path,
                              displayName: "N", model: "gordon", rawID: "0000000000000000", identitySource: "",
                              network: NetworkInfo(publicIP: "203.0.113.7", lanIPs: []), servers: [entry])
        try SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).save(record)
        try env.temp.write("home/Library/Application Support/Xash3D FWGS/engine.log",
                           GoldSrcLogTests.block(header: GoldSrcPresentationTests.sessionHeader(env.clock.now.addingTimeInterval(-60)),
                                                 address: "51.68.190.91:27015",
                                                 answer: "Server issued disconnect. Reason: You have been banned from this server."))
        let model = env.makeModel(udp: FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil)),
                                  resolver: FakeAddressResolver(["rpg.example.test": .failure(.notFound)]))
        await model.refresh().value
        XCTAssertEqual(model.rowStatus(id)?.message, .invalidHost)
        XCTAssertEqual(model.servers.first?.banCheck?.status, .goldSrcBanned)
        XCTAssertEqual(model.servers.first?.banCheck?.info?.reportedAddress, "51.68.190.91:27015")
        XCTAssertTrue(model.isCIDNotApplicable(id))
    }
}

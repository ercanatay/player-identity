import AppIntents
import XCTest
@testable import PlayerIdentity

/// §41 App Intents: server parameter resolution, entity query, check ban / show CID through the service.
@MainActor
final class IntentTests: XCTestCase {
    private var temp: TempDirectory!
    private var saved: IntentService!
    private let clock = TestClock()

    override func setUp() async throws {
        temp = try TempDirectory()
        saved = IntentEnvironment.service
    }

    override func tearDown() async throws {
        IntentEnvironment.service = saved
    }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }

    private func service(servers: [ServerEntry]?, identity: Bool = true, udp: FakeUDPTransport? = nil,
                         resolver: FakeAddressResolver = FakeAddressResolver()) throws -> IntentService {
        let paths = AppPaths(home: home)
        if identity { try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB") }   // raw ID 0
        if servers == nil { try? FileManager.default.removeItem(at: paths.snapshotFile) }
        if let servers {
            try SnapshotStore(fileURL: paths.snapshotFile).save(Snapshot(
                savedAt: clock.now, gamedir: "valve", dataRoot: "", displayName: "Player", model: "gordon",
                rawID: "0000000000000000", identitySource: "", network: NetworkInfo(publicIP: "", lanIPs: [], checkedAt: nil),
                servers: servers))
        }
        let clock = self.clock
        return IntentService(paths: paths, fileSystem: LocalFileSystem(), resolver: resolver,
                             udpTransport: udp ?? FakeServer.healthy(clock: clock), now: { clock.now })
    }

    private let eu = ServerEntry(label: "POLIGON RPG", host: "51.68.190.91")
    private let tr = ServerEntry(label: "Zombie TR", host: "play.example.com", port: 27016)
    private let tr2 = ServerEntry(label: "Zombie TR 2", host: "2001:db8::1")

    func testServerParameterResolution() {
        let servers = [eu, tr, tr2]
        func resolve(_ query: String?) -> Result<ServerEntry, IntentFailure> { IntentServerResolution.resolve(query, in: servers) }
        XCTAssertEqual(resolve(eu.id.uuidString), .success(eu))
        XCTAssertEqual(resolve("poligon rpg"), .success(eu))                       // case-insensitive label
        XCTAssertEqual(resolve("zombie tr"), .success(tr))                         // exact label wins over prefix
        XCTAssertEqual(resolve("Zombie"), .failure(.ambiguous(["Zombie TR", "Zombie TR 2"])))
        XCTAssertEqual(resolve("POLI"), .success(eu))                              // unique prefix
        XCTAssertEqual(resolve("51.68.190.91"), .success(eu))
        XCTAssertEqual(resolve("Play.Example.com:27016"), .success(tr))
        XCTAssertEqual(resolve("play.example.com:27015"), .failure(.serverNotFound("play.example.com:27015")))
        XCTAssertEqual(resolve("[2001:db8::1]:27015"), .success(tr2))
        XCTAssertEqual(resolve("2001:DB8::1"), .success(tr2))
        XCTAssertEqual(resolve("nothing"), .failure(.serverNotFound("nothing")))
        XCTAssertEqual(resolve(nil), .failure(.ambiguous(["POLIGON RPG", "Zombie TR", "Zombie TR 2"])))
        XCTAssertEqual(IntentServerResolution.resolve(nil, in: [eu]), .success(eu))       // only server
        XCTAssertEqual(IntentServerResolution.resolve("x", in: []), .failure(.noServers))
    }

    func testEntityAndQuery() async throws {
        IntentEnvironment.service = try service(servers: [tr, eu, tr2])
        XCTAssertEqual(ServerEntity(entry: tr2).address, "[2001:db8::1]:27015")
        let query = ServerEntityQuery()
        let value1 = try await query.suggestedEntities().map(\.label)
        XCTAssertEqual(value1, ["Zombie TR", "POLIGON RPG", "Zombie TR 2"])
        let value2 = try await query.entities(for: [eu.id, UUID()]).map(\.id)
        XCTAssertEqual(value2, [eu.id])
        let value3 = try await query.entities(matching: "zombie").map(\.label)
        XCTAssertEqual(value3, ["Zombie TR", "Zombie TR 2"])
        let value4 = try await query.entities(matching: "51.68.190.91").map(\.id)
        XCTAssertEqual(value4, [eu.id])
        let value5 = try await query.entities(matching: "none")
        XCTAssertEqual(value5, [])

        IntentEnvironment.service = try service(servers: nil)
        let value6 = try await query.suggestedEntities()
        XCTAssertEqual(value6, [])
        XCTAssertEqual(IntentEnvironment.service.servers(), .failure(.noRecord))
    }

    func testShowCIDAndCheckBan() async throws {
        let resolver = FakeAddressResolver(["play.example.com": .success([TestAddresses.v4("51.68.190.91")])])
        IntentEnvironment.service = try service(servers: [eu, tr], resolver: resolver)
        let value7 = try await IntentRunner.cid(ServerEntity(entry: eu))
        XCTAssertEqual(value7, "d9de0eb4419608a8423241430581e91c")
        let value8 = try await IntentRunner.cid(ServerEntity(entry: tr))
        XCTAssertEqual(value8, "d9de0eb4419608a8423241430581e91c")
        let value9 = try await IntentRunner.checkBan(ServerEntity(entry: eu))
        XCTAssertEqual(value9, "cidOk")

        let banned = FakeUDPTransport(clock: clock, responder: FakeServer.scripted(
            challenge: FakeReply(bytes: FakeServer.oob(0x6C, Array("You are banned".utf8)))))
        IntentEnvironment.service = try service(servers: [eu], udp: banned)
        let value10 = try await IntentRunner.checkBan(ServerEntity(entry: eu))
        XCTAssertEqual(value10, "ipBanned")
        // The intent types run the same code.
        _ = try await CheckServerBanIntent(server: ServerEntity(entry: eu)).perform()
        _ = try await ShowCIDIntent(server: ServerEntity(entry: eu)).perform()
    }

    func testIntentErrors() async throws {
        IntentEnvironment.service = try service(servers: [eu], identity: false)
        await assertFailure(.identityMissing) { _ = try await IntentRunner.cid(ServerEntity(entry: self.eu)) }
        await assertFailure(.serverNotFound(tr.id.uuidString)) { _ = try await IntentRunner.cid(ServerEntity(entry: self.tr)) }

        IntentEnvironment.service = try service(servers: [tr])
        await assertFailure(.resolution(.notFound)) { _ = try await IntentRunner.checkBan(ServerEntity(entry: self.tr)) }
        IntentEnvironment.service = try service(servers: nil)
        await assertFailure(.noRecord) { _ = try await IntentRunner.checkBan(ServerEntity(entry: self.eu)) }
        XCTAssertFalse(String(localized: IntentError(failure: .noRecord).localizedStringResource).isEmpty)
    }

    private func assertFailure(_ expected: IntentFailure, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as IntentError {
            XCTAssertEqual(error.failure, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

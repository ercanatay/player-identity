import XCTest
@testable import PlayerIdentity

/// Records the argv instead of running anything (no game is ever started in tests).
final class FakeGameLaunchRunner: GameLaunchRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [[String]] = []
    var status: Int32 = 0

    var commands: [[String]] { lock.withLock { runs } }

    func run(_ argv: [String]) async throws -> CommandOutput {
        lock.withLock { runs.append(argv) }
        return CommandOutput(status: status, output: "")
    }
}

/// File system where only the given directories exist.
struct FakeDirectories: FileSystemReading {
    let directories: Set<String>

    func isRegularFile(_ url: URL) -> Bool { false }
    func isDirectory(_ url: URL) -> Bool { directories.contains(url.path) }
    func readData(_ url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { [] }
}

/// §29 Join the game: command building, app detection, running-game confirmation, cancel.
final class GameLaunchTests: XCTestCase {
    private static let systemApp = "/Applications/Xash3D-FWGS.app"
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    private func launcher(apps: Set<String> = [systemApp], running: Bool = false,
                          resolver: FakeAddressResolver = FakeAddressResolver(),
                          runner: FakeGameLaunchRunner = FakeGameLaunchRunner()) -> GameLauncher {
        GameLauncher(locator: GameAppLocator(fileSystem: FakeDirectories(directories: apps), homeDirectory: home),
                     resolver: resolver, detector: FakeGameDetector(running: running), runner: runner)
    }

    func testIPv4Command() async throws {
        let plan = try await launcher().plan(host: "192.0.2.10", port: 27015, gamedir: "valve")
        XCTAssertEqual(plan.command.argv, ["/usr/bin/open", "-a", Self.systemApp, "--args", "-game", "valve",
                                           "+connect", "192.0.2.10:27015"])
        XCTAssertFalse(plan.gameRunning)
        XCTAssertTrue(GameLaunchAllowlist.isAllowed(plan.command.argv))
    }

    func testIPv6CommandUsesBrackets() async throws {
        let plan = try await launcher().plan(host: "2001:DB8::1", port: 27016, gamedir: "cstrike")
        XCTAssertEqual(plan.command.connect, "[2001:db8::1]:27016")
        XCTAssertEqual(plan.command.argv[5], "cstrike")
        XCTAssertTrue(GameLaunchAllowlist.isAllowed(plan.command.argv))
    }

    func testHostnameUsesTheResolvedIP() async throws {
        let resolver = FakeAddressResolver(["play.example.com": .success([TestAddresses.v6("2001:db8::5"),
                                                                          TestAddresses.v4("198.51.100.20")])])
        let plan = try await launcher(resolver: resolver).plan(host: "Play.Example.com", port: 27015, gamedir: nil)
        XCTAssertEqual(plan.command.connect, "198.51.100.20:27015")   // IPv4 preferred
        XCTAssertEqual(plan.command.gamedir, "valve")                 // empty profile gamedir → valve
        XCTAssertEqual(resolver.requestedNames, ["play.example.com"])

        // An address already resolved by the refresh is used without a new lookup.
        let cached = try await launcher(resolver: resolver).plan(
            host: "play.example.com", port: 27015, gamedir: "valve",
            known: ["play.example.com": .resolved(TestAddresses.v4("198.51.100.30"))])
        XCTAssertEqual(cached.command.connect, "198.51.100.30:27015")
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testResolutionAndInputErrors() async {
        let resolver = FakeAddressResolver(["down.example.com": .failure(.network)])
        let launcher = launcher(resolver: resolver)
        await assertThrows(.resolutionFailed(.notFound)) { _ = try await launcher.plan(host: "missing.example.com", port: 1, gamedir: "valve") }
        await assertThrows(.resolutionFailed(.network)) { _ = try await launcher.plan(host: "down.example.com", port: 1, gamedir: "valve") }
        await assertThrows(.invalidHost) { _ = try await launcher.plan(host: "not a host", port: 27015, gamedir: "valve") }
        await assertThrows(.invalidPort) { _ = try await launcher.plan(host: "192.0.2.10", port: 70000, gamedir: "valve") }
        await assertThrows(.invalidGamedir) { _ = try await launcher.plan(host: "192.0.2.10", port: 27015, gamedir: "../x") }
        await assertThrows(.invalidGamedir) { _ = try await launcher.plan(host: "192.0.2.10", port: 27015, gamedir: "a b") }
    }

    func testAppNotFound() async {
        let runner = FakeGameLaunchRunner()
        let missing = launcher(apps: [], runner: runner)
        XCTAssertFalse(missing.isAvailable)
        await assertThrows(.appNotFound) { _ = try await missing.plan(host: "192.0.2.10", port: 27015, gamedir: "valve") }
        XCTAssertEqual(runner.commands, [])

        // ~/Applications is accepted as well.
        let user = launcher(apps: ["/Users/test/Applications/Xash3D-FWGS.app"])
        XCTAssertTrue(user.isAvailable)
        XCTAssertEqual(user.locator.locate()?.path, "/Users/test/Applications/Xash3D-FWGS.app")
    }

    func testLaunchWhenTheGameIsNotRunningNeedsNoConfirmation() async throws {
        let runner = FakeGameLaunchRunner()
        let launcher = launcher(runner: runner)
        let plan = try await launcher.plan(host: "192.0.2.10", port: 27015, gamedir: "valve")
        try await launcher.launch(plan) {
            XCTFail("no confirmation expected")
            return false
        }
        XCTAssertEqual(runner.commands, [plan.command.argv])
    }

    func testRunningGameAsksAndCancelRunsNothing() async throws {
        let runner = FakeGameLaunchRunner()
        let launcher = launcher(running: true, runner: runner)
        let plan = try await launcher.plan(host: "192.0.2.10", port: 27015, gamedir: "valve")
        XCTAssertTrue(plan.gameRunning)

        let asked = Counter()
        await assertThrows(.cancelled) {
            try await launcher.launch(plan) {
                asked.increment()
                return false
            }
        }
        XCTAssertEqual(asked.value, 1)
        XCTAssertEqual(runner.commands, [])

        try await launcher.launch(plan) { true }
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testLaunchFailure() async throws {
        let runner = FakeGameLaunchRunner()
        runner.status = 1
        let launcher = launcher(runner: runner)
        let plan = try await launcher.plan(host: "192.0.2.10", port: 27015, gamedir: "valve")
        await assertThrows(.launchFailed(status: 1)) { try await launcher.launch(plan) { true } }
    }

    func testAllowlistRejectsOtherCommands() async {
        let good = ["/usr/bin/open", "-a", "/Applications/Xash3D-FWGS.app", "--args", "-game", "valve", "+connect", "192.0.2.1:27015"]
        XCTAssertTrue(GameLaunchAllowlist.isAllowed(good))
        var injected = good
        injected[7] = "192.0.2.1:27015;quit"
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(injected))
        injected = good
        injected[5] = "-console"
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(injected))
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(good + ["+exec", "x.cfg"]))
        XCTAssertFalse(GameLaunchAllowlist.isAllowed(["/bin/sh", "-c", "open"]))
        do {
            _ = try await ProcessGameLaunchRunner().run(["/bin/echo", "x"])
            XCTFail("expected notAllowed")
        } catch {
            XCTAssertEqual(error as? CommandError, .notAllowed)
        }
    }

    private func assertThrows(_ expected: GameLaunchError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GameLaunchError, expected, file: file, line: line)
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

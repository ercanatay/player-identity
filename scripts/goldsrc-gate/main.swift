import Darwin
import Foundation

// AC-75.R1 production-path driver (built by scripts/verify-goldsrc-connection.sh together with PlayerIdentity/Core).
// It runs the app's own code: the A2S check (BanChecker) decides the protocol, GameLauncher builds the Join Game plan
// (`/usr/bin/open --env XASH3D_BASEDIR=<data root> -a <engine> --args -game <dir> -dev 1 -log +connect <ip:port> gs`),
// the allowlisted ProcessGameLaunchRunner runs it, and GoldSrcEngineLog reads `<data root>/engine.log`.
// Usage: goldsrc-gate <host:port> <data root> <gamedir> <wait seconds>
// Output: `key=value` lines; exit 0 when the production path produced engine log evidence, 1 otherwise.

let arguments = CommandLine.arguments
let hostPort = arguments.count == 5 ? arguments[1].split(separator: ":", omittingEmptySubsequences: false) : []
guard hostPort.count == 2, let port = Int(hostPort[1]), HostValidator.isValidPort(port),
      let wait = Double(arguments[4]) else {
    print("usage: goldsrc-gate <host:port> <data root> <gamedir> <wait seconds>")
    exit(2)
}
let target = (host: HostValidator.normalized(String(hostPort[0])), port: port)
let dataRoot = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
let gamedir = arguments[3]
var failed = false
@MainActor func check(_ condition: Bool, _ text: String) {
    print((condition ? "ok   " : "FAIL ") + text)
    if !condition { failed = true }
}

// 1. Protocol from the production A2S check (no connect packet and no CID for GoldSrc 48).
let resolver = SystemAddressResolver()
let address: ServerAddress
if case .address(let literal)? = HostValidator.classify(target.host) {
    address = literal
} else if let picked = AddressPreference.pick((try? await resolver.addresses(for: target.host)) ?? []) {
    address = picked
} else {
    print("FAIL the host does not resolve")
    exit(1)
}
let request = BanCheckRequest(serverID: UUID(), host: target.host, port: target.port,
                              endpoint: UDPEndpoint(address: address, port: UInt16(target.port)), cid: nil, name: "player")
let banCheck = try await BanChecker(transport: BSDUDPTransport(), now: { Date() }).check(request)
let serverProtocol = banCheck.info?.serverProtocol ?? .unknown
print("a2s_protocol=\(serverProtocol.rawValue)")
print("refresh_status=\(banCheck.status.rawValue)")
check(serverProtocol == .goldsrc48, "A2S decides goldsrc48")
check(banCheck.status != .cidOk && banCheck.status != .cidNotApplicable, "the automatic check never says \"no block\"")

// 2. The production Join Game plan and launch.
let launcher = GameLauncher()
let plan = try await launcher.plan(host: target.host, port: target.port, gamedir: gamedir, serverProtocol: serverProtocol,
                                   dataRoot: dataRoot)
let argv = plan.command.argv
print("argv=" + argv.joined(separator: " | "))
let expected = ["/usr/bin/open", "--env", "XASH3D_BASEDIR=" + dataRoot.path, "-a", plan.command.app.path, "--args",
                "-game", gamedir, "-dev", "1", "-log", "+connect",
                GameLaunchCommand.connectArgument(address: address, port: target.port) ?? "", "gs"]
check(argv == expected, "production Join Game argv: open --env XASH3D_BASEDIR=<data root> … -dev 1 -log +connect … gs")
check(GameLaunchAllowlist.isAllowed(argv), "argv passes GameLaunchAllowlist")
check(!plan.gameRunning, "the engine is not running before the launch")
guard !failed else { exit(1) }
let launchedAt = Date()
try await launcher.launch(plan) { false }
print("launched_at=\(ISO8601DateFormatter().string(from: launchedAt))")

// 3. The running engine has the production arguments (and, when ps shows it, the environment).
@MainActor func psLine() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axwwE", "-o", "pid=,command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        .first { $0.contains(plan.command.app.path + "/Contents/MacOS/xash3d") }
}
var engineLine: String?
for _ in 0..<20 where engineLine == nil {
    try await Task.sleep(for: .milliseconds(500))
    engineLine = psLine()
}
let processArgs = engineLine ?? ""
check(processArgs.contains("-game \(gamedir) -dev 1 -log +connect \(expected[12]) gs"),
      "engine process runs with -game \(gamedir) -dev 1 -log +connect \(expected[12]) gs")
check(!processArgs.contains("-dev 2"), "not the direct -dev 2 test invocation")
let envShown = processArgs.contains("XASH3D_BASEDIR=")
print("engine_env_visible=\(envShown)")
if envShown { check(processArgs.contains("XASH3D_BASEDIR=" + dataRoot.path), "engine environment has XASH3D_BASEDIR=<data root>") }

// 4. `<data root>/engine.log` written by this launch, read by the app's own reader.
let addresses = GoldSrcEngineLog.addresses(host: target.host, port: target.port, resolved: address.text)
var evidence: GoldSrcLogEvidence?
var lastRead = GoldSrcEngineLog.ReadResult.missing
let deadline = Date().addingTimeInterval(wait)
while Date() < deadline {
    try await Task.sleep(for: .seconds(1))
    lastRead = GoldSrcEngineLog.read(dataRoot: dataRoot, fileSystem: LocalFileSystem())
    if let text = lastRead.text,
       let found = GoldSrcEngineLog.evidence(in: text, addresses: addresses, now: Date(), notBefore: launchedAt),
       found.outcome != .connected || Date().addingTimeInterval(8) > deadline {
        evidence = found
        break
    }
}
if case .unreadable(let reason) = lastRead { print("engine_log_unreadable=\(reason)") }
let logText = lastRead.text ?? ""
check(lastRead != .missing, "<data root>/engine.log exists (\(GoldSrcEngineLog.url(dataRoot: dataRoot).path))")
check(logText.contains(GoldSrcEngineLog.goldSrcLine), "engine.log has \"Trying to connect with GoldSrc 48 protocol\"")
check(!FileManager.default.fileExists(atPath: "/engine.log"), "no engine.log in / (the open working directory)")
print("engine_outcome=\(evidence?.outcome.rawValue ?? "none")")
print("engine_reason=\(evidence?.reason ?? "")")
check(evidence != nil, "GoldSrcEngineLog reads the server's answer for this server after this launch")
exit(failed ? 1 : 0)

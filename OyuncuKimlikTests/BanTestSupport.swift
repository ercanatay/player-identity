import Foundation
@testable import OyuncuKimlik

/// Enjekte edilebilir saat; sahte oturum bekleme sürelerini buna ekler.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_793_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

struct FakeReply: Sendable {
    var bytes: [UInt8]
    /// Gönderimden sonra yanıtın gelme süresi (sn).
    var delay: TimeInterval = 0
}

/// Ağa çıkmayan UDP taşıyıcısı: gönderilen paketleri sayar, betikli yanıt üretir.
final class FakeUDPTransport: UDPTransport, @unchecked Sendable {
    typealias Responder = @Sendable (_ endpoint: UDPEndpoint, _ packet: [UInt8]) -> [FakeReply]

    let responder: Responder
    let clock: TestClock?
    /// `true` ise sessizlikte gerçekten bekler (iptal testleri için); aksi hâlde saat ilerletilip hemen döner.
    let waitsOnSilence: Bool
    private let lock = NSLock()
    private var sent: [(UDPEndpoint, [UInt8])] = []
    private var sessions = 0

    init(clock: TestClock? = nil, waitsOnSilence: Bool = false, responder: @escaping Responder) {
        self.clock = clock
        self.waitsOnSilence = waitsOnSilence
        self.responder = responder
    }

    var sentPackets: [[UInt8]] { lock.withLock { sent.map(\.1) } }
    var sentCount: Int { lock.withLock { sent.count } }
    var sessionCount: Int { lock.withLock { sessions } }

    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession {
        lock.withLock { sessions += 1 }
        return FakeUDPSession(transport: self, endpoint: endpoint)
    }

    fileprivate func record(_ endpoint: UDPEndpoint, _ packet: [UInt8]) -> [FakeReply] {
        lock.withLock { sent.append((endpoint, packet)) }
        return responder(endpoint, packet)
    }
}

final class FakeUDPSession: UDPSession, @unchecked Sendable {
    private let transport: FakeUDPTransport
    private let endpoint: UDPEndpoint
    private let lock = NSLock()
    private var queue: [FakeReply] = []

    init(transport: FakeUDPTransport, endpoint: UDPEndpoint) {
        self.transport = transport
        self.endpoint = endpoint
    }

    func send(_ packet: [UInt8]) throws {
        let replies = transport.record(endpoint, packet)
        lock.withLock { queue.append(contentsOf: replies) }
    }

    func receive(timeout: TimeInterval) async throws -> [UInt8]? {
        try Task.checkCancellation()
        let reply: FakeReply? = lock.withLock {
            guard let first = queue.first else { return nil }
            if first.delay <= timeout {
                queue.removeFirst()
                return first
            }
            queue[0].delay -= timeout
            return nil
        }
        if let reply {
            transport.clock?.advance(reply.delay)
            return reply.bytes
        }
        if transport.waitsOnSilence { try await Task.sleep(for: .seconds(timeout)) }
        transport.clock?.advance(timeout)
        return nil
    }

    func close() {}
}

enum FakeServer {
    static let header: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
    static let challengeBytes: [UInt8] = [0x78, 0x56, 0x34, 0x12]   // 0x12345678 LE

    static func oob(_ type: UInt8, _ rest: [UInt8] = []) -> [UInt8] { header + [type] + rest }
    static func oobText(_ text: String) -> [UInt8] { header + Array(text.utf8) }

    static func isInfo(_ p: [UInt8]) -> Bool { p.starts(with: header + Array("TSource Engine Query".utf8)) }
    static func isGetChallenge(_ p: [UInt8]) -> Bool { p.starts(with: header + Array("getchallenge".utf8)) }
    static func isConnect(_ p: [UInt8]) -> Bool { p.starts(with: header + Array("connect ".utf8)) }

    /// Adım başına yanıt betiği; `nil` = sessizlik.
    static func scripted(info: FakeReply? = FakeReply(bytes: oob(0x49, [0x30])),
                         challenge: FakeReply? = FakeReply(bytes: oob(0x41, challengeBytes)),
                         connect: FakeReply? = FakeReply(bytes: oob(0x42))) -> FakeUDPTransport.Responder {
        { _, packet in
            if isInfo(packet) { return info.map { [$0] } ?? [] }
            if isGetChallenge(packet) { return challenge.map { [$0] } ?? [] }
            if isConnect(packet) { return connect.map { [$0] } ?? [] }
            return []
        }
    }

    static func healthy(clock: TestClock? = nil) -> FakeUDPTransport {
        FakeUDPTransport(clock: clock, responder: scripted())
    }
}

/// Enjekte edilebilir oyun süreci tespiti (§15.6).
final class FakeGameDetector: GameProcessDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var checks = 0

    init(running: Bool = false) {
        self.running = running
    }

    var isRunning: Bool {
        get { lock.withLock { running } }
        set { lock.withLock { running = newValue } }
    }

    var checkCount: Int { lock.withLock { checks } }

    func isGameRunning() -> Bool {
        lock.withLock {
            checks += 1
            return running
        }
    }
}

/// §17 sahte komut yürütücüsü: gerçek komut çalıştırmaz; çağrıları kaydeder, allowlist'i uygular.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    typealias Responder = @Sendable (NetworkCommand) -> CommandOutput

    private let lock = NSLock()
    private var recorded: [NetworkCommand] = []
    private let responder: Responder

    init(responder: @escaping Responder = FakeCommandRunner.wifi()) {
        self.responder = responder
    }

    var commands: [NetworkCommand] { lock.withLock { recorded } }

    func run(_ command: NetworkCommand) async throws -> CommandOutput {
        guard CommandAllowlist.isAllowed(command.argv) else { throw CommandError.notAllowed }
        lock.withLock { recorded.append(command) }
        return responder(command)
    }

    static let routeOutput = """
       route to: default
    destination: default
           mask: default
        gateway: 192.0.2.1
      interface: en0
          flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
    """

    /// `en0` Wi-Fi arayüzü; tüm komutlar başarılı.
    static func wifi() -> Responder {
        { command in
            switch command {
            case .routeGetDefault: return CommandOutput(status: 0, output: routeOutput)
            case .airportPowerStatus: return CommandOutput(status: 0, output: "Wi-Fi Power (en0): On\n")
            case .setAirportPower, .renewDHCP: return CommandOutput(status: 0, output: "")
            }
        }
    }

    /// `en0` Ethernet; DHCP komutunun çıkış kodu verilebilir (1 = yönetici onayı reddedildi).
    static func ethernet(dhcpStatus: Int32 = 0) -> Responder {
        { command in
            switch command {
            case .routeGetDefault: return CommandOutput(status: 0, output: routeOutput)
            case .airportPowerStatus: return CommandOutput(status: 10, output: "en0 is not a Wi-Fi interface.\n** Error: Error obtaining wireless information.\n")
            case .setAirportPower: return CommandOutput(status: 0, output: "")
            case .renewDHCP: return CommandOutput(status: dhcpStatus, output: dhcpStatus == 0 ? "" : "User canceled. (-128)")
            }
        }
    }
}

/// Saati anında ilerleten bekleme; `blocking` ise gerçekten bekler (iptal testleri).
struct FakeSleeper: Sleeping {
    let clock: TestClock
    var blocking = false

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        if blocking { try await Task.sleep(for: .seconds(30)) }
        clock.advance(seconds)
        await Task.yield()
    }
}

/// Sırayla genel IP döndüren sağlayıcı; `nil` = başarısız deneme, liste bitince son değer tekrarlanır.
final class SequencedIPs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var calls = 0

    init(_ values: [String?]) {
        self.values = values
    }

    var callCount: Int { lock.withLock { calls } }

    func next() throws -> String {
        let value: String? = lock.withLock {
            calls += 1
            if values.count > 1 { return values.removeFirst() }
            return values.first ?? nil
        }
        guard let value else { throw PublicIPError.unavailable }
        return value
    }
}

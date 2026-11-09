import Darwin
import Foundation

// MARK: - Model (§13.3, §13.4)

/// Ban check result. The stored `status` is the last step the check triple reached:
/// (a) no reply → `unreachable`; (b) → `ipBanned` / `unknown`; if (b) is `ipOk` and (c) ran, the result of (c).
/// (c) runs only if the row has a CID; otherwise the result stays `ipOk`.
enum BanStatus: String, Codable, Sendable, CaseIterable {
    case ipOk
    case ipBanned
    case cidOk
    case cidBanned
    case cidNotApplicable
    case cidUnknown
    case unreachable
    case unknown

    /// §13.3 display text.
    var label: String {
        switch self {
        case .ipBanned: return L10n.text(.banStatusIPBanned)
        case .cidBanned: return L10n.text(.banStatusCIDBanned)
        case .cidOk, .cidNotApplicable: return L10n.text(.banStatusNoBlock)
        case .unreachable: return L10n.text(.banStatusUnreachable)
        case .unknown, .cidUnknown, .ipOk: return L10n.text(.banStatusUnknown)
        }
    }

    /// Effect on the overall status (§13.3): ban → red, unreachable/unknown → orange, no block → green.
    var level: StatusLevel {
        switch self {
        case .ipBanned, .cidBanned: return .red
        case .cidOk, .cidNotApplicable: return .green
        case .unreachable, .unknown, .cidUnknown, .ipOk: return .orange
        }
    }

    /// 🔴 / 🟢 / ⚪
    var symbolName: String {
        switch level {
        case .red: return StatusLevel.red.symbolName
        case .green: return StatusLevel.green.symbolName
        case .orange: return "circle"
        }
    }

    /// Reason / row message code (§13.5).
    var messageCode: MessageCode? {
        switch self {
        case .ipBanned: return .ipBanned
        case .cidBanned: return .cidBanned
        case .unreachable: return .unreachable
        case .unknown, .cidUnknown, .ipOk: return .banUnknown
        case .cidNotApplicable: return .cidNotApplicable
        case .cidOk: return nil
        }
    }
}

/// `ServerEntry.banCheck` (§13.4).
struct BanCheck: Codable, Sendable, Equatable {
    var status: BanStatus
    var checkedAt: Date
    var detail: String
    /// §21: parsed A2S_INFO reply of step (a); optional, absent in older records.
    var info: ServerInfo? = nil
}

// MARK: - UDP transport (DI)

struct UDPEndpoint: Sendable, Equatable {
    let address: ServerAddress
    let port: UInt16

    /// Key of the 10 s throttle.
    var key: String { "\(CIDCalculator.hexLower(address.bytes)):\(port)" }
}

protocol UDPSession: Sendable {
    func send(_ packet: [UInt8]) throws
    /// Waits at most `timeout` seconds; returns `nil` when it expires. Throws `CancellationError` on cancellation.
    func receive(timeout: TimeInterval) async throws -> [UInt8]?
    func close()
}

protocol UDPTransport: Sendable {
    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession
}

// MARK: - Packets (§13.2)

enum BanPackets {
    static let header: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
    static let protocolVersion = 49

    /// `FF FF FF FF` + `TSource Engine Query` + `00` [+ 4-byte challenge]
    static func info(challenge: [UInt8] = []) -> [UInt8] {
        header + Array("TSource Engine Query".utf8) + [0x00] + challenge
    }

    /// `FF FF FF FF` + `getchallenge` + `\n`
    static func getChallenge() -> [UInt8] {
        header + Array("getchallenge\n".utf8)
    }

    /// `FF FF FF FF` + `connect 49 <challenge> "<protinfo>" "<userinfo>"` + `\n`
    static func connect(challenge: UInt32, cid: String, qport: UInt16, name: String) -> [UInt8] {
        let protinfo = "prot=cidtest; uuid=\(cid); qport=\(qport); ext=0; d=1"
        let userinfo = "name=\(name)"
        let text = "connect \(protocolVersion) \(Int32(bitPattern: challenge)) \"\(protinfo)\" \"\(userinfo)\"\n"
        return header + Array(text.utf8)
    }
}

enum BanReplies {
    enum Info: Equatable {
        case info
        case challenge([UInt8])
        case other
    }

    enum GetChallenge: Equatable {
        case banned(String)
        case challenge(UInt32)
        case unrecognized(String)
    }

    enum Connect: Equatable {
        case ok
        case banned(String)
        case notApplicable(String)
        case unrecognized(String)
    }

    static func isOutOfBand(_ reply: [UInt8]) -> Bool {
        reply.count >= 5 && Array(reply.prefix(4)) == BanPackets.header
    }

    static func type(_ reply: [UInt8]) -> UInt8? {
        isOutOfBand(reply) ? reply[4] : nil
    }

    /// Text after the 4-byte header + 1-byte type.
    static func body(_ reply: [UInt8]) -> String {
        guard reply.count > 5 else { return "" }
        return String(decoding: reply[5...], as: UTF8.self)
    }

    /// Text after the 4-byte header (type byte included; for text replies such as `client_connect`, `errormsg`).
    static func text(_ reply: [UInt8]) -> String {
        guard reply.count > 4 else { return "" }
        return String(decoding: reply[4...], as: UTF8.self)
    }

    /// Late A2S_INFO reply; ignored during steps (b)/(c).
    static func isInfoReply(_ reply: [UInt8]) -> Bool {
        type(reply) == 0x6D || type(reply) == 0x49
    }

    static func classifyInfo(_ reply: [UInt8]) -> Info {
        switch type(reply) {
        case 0x6D, 0x49: return .info
        case 0x41 where reply.count >= 9: return .challenge(Array(reply[5..<9]))
        default: return .other
        }
    }

    static func classifyGetChallenge(_ reply: [UInt8]) -> GetChallenge {
        guard isOutOfBand(reply) else { return .unrecognized("") }
        let body = body(reply)
        if body.lowercased().contains("banned") { return .banned(body) }
        if reply[4] == 0x41, reply.count >= 9 {
            let value = reply[5..<9].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return .challenge(value)
        }
        return .unrecognized(body)
    }

    static func classifyConnect(_ reply: [UInt8]) -> Connect {
        guard isOutOfBand(reply) else { return .unrecognized("") }
        let text = text(reply)
        let lower = text.lowercased()
        if reply[4] == 0x42 || lower.hasPrefix("client_connect") { return .ok }
        let isReject = lower.hasPrefix("errormsg") || lower.hasPrefix("disconnect") || reply[4] == 0x39
        if isReject, lower.contains("ban") { return .banned(text) }
        if lower.contains("unsupported protocol") || lower.contains("protocol") { return .notApplicable(text) }
        return .unrecognized(text)
    }

    /// Printable, truncated server text for `detail`.
    static func printable(_ text: String, limit: Int = 120) -> String {
        let cleaned = String(text.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control || scalar == "\u{FFFD}" ? " " : Character(scalar)
        })
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}

// MARK: - Check (§13.1, §13.2)

struct BanCheckRequest: Sendable, Equatable {
    let serverID: UUID
    let host: String
    let port: Int
    let endpoint: UDPEndpoint
    /// The row's CID; if absent, step (c) is skipped.
    let cid: String?
    /// Display name from the profile.
    let name: String
}

/// One check triple per server; no retries. 4 s per step, 12 s in total.
struct BanChecker: Sendable {
    static let stepTimeout: TimeInterval = 4
    static let totalTimeout: TimeInterval = 12

    let transport: any UDPTransport
    let now: @Sendable () -> Date
    let qport: @Sendable () -> UInt16
    /// Per-step timeout (4 s in the app; `playeridentityctl ban --timeout` changes it). Total = 3 steps.
    let step: TimeInterval
    var total: TimeInterval { step * 3 }

    init(transport: any UDPTransport,
         now: @escaping @Sendable () -> Date,
         qport: @escaping @Sendable () -> UInt16 = { UInt16.random(in: 1...UInt16.max) },
         stepTimeout: TimeInterval = BanChecker.stepTimeout) {
        self.transport = transport
        self.now = now
        self.qport = qport
        self.step = stepTimeout
    }

    func check(_ request: BanCheckRequest) async throws -> BanCheck {
        let start = now()
        let overallDeadline = start.addingTimeInterval(total)
        var info: ServerInfo?
        func result(_ status: BanStatus, _ trail: [BanStatus], _ serverText: String = "") -> BanCheck {
            var detail = trail.map(\.rawValue).joined(separator: " → ")
            let text = BanReplies.printable(serverText)
            if !text.isEmpty { detail += ": " + text }
            return BanCheck(status: status, checkedAt: now(), detail: detail, info: info)
        }

        guard let session = try? transport.makeSession(to: request.endpoint) else {
            return result(.unreachable, [.unreachable])
        }
        defer { session.close() }

        // (a) A2S_INFO; its reply also yields the server info (§21), no extra query.
        let infoDeadline = min(start.addingTimeInterval(step), overallDeadline)
        var infoSentAt = now()
        guard var infoReply = try await exchange(session, BanPackets.info(), until: infoDeadline, ignoreInfo: false) else {
            return result(.unreachable, [.unreachable])
        }
        var infoReceivedAt = now()
        if case .challenge(let challenge) = BanReplies.classifyInfo(infoReply) {
            // The same packet is re-sent once with the challenge (a protocol step, not a retry).
            infoSentAt = now()
            if let reply = try await exchange(session, BanPackets.info(challenge: challenge), until: infoDeadline,
                                              ignoreInfo: false) {
                infoReply = reply
                infoReceivedAt = now()
            }
        }
        if var parsed = ServerInfoParser.parse(infoReply) {
            parsed.pingMillis = max(0, Int((infoReceivedAt.timeIntervalSince(infoSentAt) * 1000).rounded()))
            info = parsed
        }

        // (b) getchallenge
        let challengeDeadline = min(now().addingTimeInterval(step), overallDeadline)
        guard let challengeReply = try await exchange(session, BanPackets.getChallenge(),
                                                      until: challengeDeadline, ignoreInfo: true) else {
            return result(.unknown, [.unknown])
        }
        let challenge: UInt32
        switch BanReplies.classifyGetChallenge(challengeReply) {
        case .banned(let text): return result(.ipBanned, [.ipBanned], text)
        case .unrecognized(let text): return result(.unknown, [.unknown], text)
        case .challenge(let value): challenge = value
        }

        // (c) connect handshake (only if a challenge was received and a CID exists)
        guard let cid = request.cid else { return result(.ipOk, [.ipOk]) }
        let connectDeadline = min(now().addingTimeInterval(step), overallDeadline)
        let packet = BanPackets.connect(challenge: challenge, cid: cid, qport: qport(), name: request.name)
        guard let connectReply = try await exchange(session, packet, until: connectDeadline, ignoreInfo: true) else {
            return result(.cidUnknown, [.ipOk, .cidUnknown])
        }
        switch BanReplies.classifyConnect(connectReply) {
        case .ok: return result(.cidOk, [.ipOk, .cidOk])   // stop immediately: no further packets
        case .banned(let text): return result(.cidBanned, [.ipOk, .cidBanned], text)
        case .notApplicable(let text): return result(.cidNotApplicable, [.ipOk, .cidNotApplicable], text)
        case .unrecognized(let text): return result(.cidUnknown, [.ipOk, .cidUnknown], text)
        }
    }

    /// Sends the packet once and waits for the first matching reply until the deadline. Send error = no reply.
    private func exchange(_ session: any UDPSession, _ packet: [UInt8], until deadline: Date,
                          ignoreInfo: Bool) async throws -> [UInt8]? {
        try Task.checkCancellation()
        do { try session.send(packet) } catch { return nil }
        while true {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { return nil }
            let received: [UInt8]?
            do {
                received = try await session.receive(timeout: remaining)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            guard let reply = received else { return nil }
            if ignoreInfo, BanReplies.isInfoReply(reply) { continue }
            return reply
        }
    }
}

/// At least 10 s between two checks of the same server (§13.1).
actor BanCheckScheduler {
    static let minimumInterval: TimeInterval = 10

    private var lastStart: [String: Date] = [:]

    /// If allowed, records the check time and returns `true`.
    func reserve(_ key: String, now: Date) -> Bool {
        if let last = lastStart[key], now.timeIntervalSince(last) < Self.minimumInterval { return false }
        lastStart[key] = now
        return true
    }
}

enum BanCheckRunner {
    /// Runs checks in parallel; requests hitting the 10 s throttle are omitted from the result. Cancellable.
    static func run(_ requests: [BanCheckRequest], checker: BanChecker,
                    scheduler: BanCheckScheduler) async -> [UUID: BanCheck] {
        await withTaskGroup(of: (UUID, BanCheck?).self) { group in
            for request in requests {
                group.addTask {
                    guard await scheduler.reserve(request.endpoint.key, now: checker.now()) else {
                        return (request.serverID, nil)
                    }
                    return (request.serverID, try? await checker.check(request))
                }
            }
            var results: [UUID: BanCheck] = [:]
            for await (id, check) in group {
                if let check { results[id] = check }
            }
            return results
        }
    }

    /// Builds requests from rows; invalid, unresolved or failed host, local machine or invalid port → no check.
    /// Hostnames use their resolved address from `resolutions` (§20).
    static func requests(servers: [ServerEntry], rawID: UInt64?, name: String,
                         resolutions: [String: HostResolution] = [:]) -> [BanCheckRequest] {
        servers.compactMap { entry in
            guard let address = HostAddressing.address(for: entry.host, in: resolutions), address != .localMachine,
                  HostValidator.isValidPort(entry.port) else { return nil }
            return BanCheckRequest(serverID: entry.id,
                                   host: entry.host,
                                   port: entry.port,
                                   endpoint: UDPEndpoint(address: address, port: UInt16(entry.port)),
                                   cid: rawID.map { CIDCalculator.cid(rawID: $0, address: address) },
                                   name: name)
        }
    }
}

// MARK: - Real UDP (BSD socket, non-blocking)

enum UDPSocketError: Error, Equatable {
    case unsupportedAddress
    case system(Int32)
}

struct BSDUDPTransport: UDPTransport {
    init() {}

    func makeSession(to endpoint: UDPEndpoint) throws -> any UDPSession {
        try BSDUDPSession(endpoint: endpoint)
    }
}

final class BSDUDPSession: UDPSession, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(endpoint: UDPEndpoint) throws {
        let family: Int32
        switch endpoint.address {
        case .ipv4: family = AF_INET
        case .ipv6: family = AF_INET6
        case .localMachine: throw UDPSocketError.unsupportedAddress
        }
        let socketFD = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw UDPSocketError.system(errno) }

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        let status: Int32
        switch endpoint.address {
        case .ipv4(let bytes):
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = endpoint.port.bigEndian
            withUnsafeMutableBytes(of: &addr.sin_addr) { $0.copyBytes(from: bytes) }
            status = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6(let bytes):
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = endpoint.port.bigEndian
            withUnsafeMutableBytes(of: &addr.sin6_addr) { $0.copyBytes(from: bytes) }
            status = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        case .localMachine:
            status = -1
        }
        guard status == 0 else {
            let error = errno
            Darwin.close(socketFD)
            throw UDPSocketError.system(error)
        }
        fd = socketFD
    }

    deinit { close() }

    func send(_ packet: [UInt8]) throws {
        let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == packet.count else { throw UDPSocketError.system(errno) }
    }

    func receive(timeout: TimeInterval) async throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count >= 0 { return Array(buffer[0..<count]) }
            let error = errno
            // EAGAIN: no data yet; ECONNREFUSED: ICMP port closed → treated as no reply.
            guard error == EAGAIN || error == EWOULDBLOCK || error == ECONNREFUSED || error == EINTR else {
                throw UDPSocketError.system(error)
            }
            if Date() >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

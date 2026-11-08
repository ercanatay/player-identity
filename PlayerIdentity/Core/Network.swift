import Darwin
import Foundation

// MARK: - Local IPs (§3.5)

enum AddressFamily: Sendable, Equatable {
    case ipv4
    case ipv6
}

/// Raw interface address returned by `getifaddrs`.
struct InterfaceAddress: Sendable, Equatable {
    let interface: String
    let family: AddressFamily
    let bytes: [UInt8]
    let isLoopback: Bool
}

/// Local address to display.
struct LocalAddress: Sendable, Equatable {
    let interface: String
    let family: AddressFamily
    let address: String

    /// E.g. `en0 · 192.0.2.10`
    var display: String { "\(interface) · \(address)" }
}

enum LocalIPFilter {
    /// Excludes loopback (`lo0`) and IPv6 link-local (`fe80::/10`); IPv4 first, then IPv6 (system order preserved).
    static func filter(_ entries: [InterfaceAddress]) -> [LocalAddress] {
        let kept = entries.filter { entry in
            if entry.isLoopback || entry.interface == "lo0" { return false }
            if entry.family == .ipv6, isLinkLocalIPv6(entry.bytes) { return false }
            return true
        }
        let v4 = kept.filter { $0.family == .ipv4 }
        let v6 = kept.filter { $0.family == .ipv6 }
        return (v4 + v6).compactMap { entry in
            IPText.string(family: entry.family, bytes: entry.bytes)
                .map { LocalAddress(interface: entry.interface, family: entry.family, address: $0) }
        }
    }

    static func isLinkLocalIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
    }
}

enum IPText {
    static func string(family: AddressFamily, bytes: [UInt8]) -> String? {
        let af: Int32
        switch family {
        case .ipv4:
            guard bytes.count == 4 else { return nil }
            af = AF_INET
        case .ipv6:
            guard bytes.count == 16 else { return nil }
            af = AF_INET6
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(af, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard ok else { return nil }
        let utf8 = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }
}

protocol LocalIPProviding: Sendable {
    func localAddresses() -> [LocalAddress]
}

/// Reads system interfaces via `getifaddrs`.
struct SystemLocalIPProvider: LocalIPProviding {
    init() {}

    func localAddresses() -> [LocalAddress] {
        LocalIPFilter.filter(Self.interfaceAddresses())
    }

    static func interfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let entry = pointer.pointee
            cursor = entry.ifa_next
            guard let sa = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            let isLoopback = (Int32(bitPattern: entry.ifa_flags) & IFF_LOOPBACK) != 0
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var sin = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in.self)
                let bytes = withUnsafeBytes(of: &sin.sin_addr) { Array($0) }
                result.append(InterfaceAddress(interface: name, family: .ipv4, bytes: bytes, isLoopback: isLoopback))
            case AF_INET6:
                var sin6 = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in6.self)
                let bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                result.append(InterfaceAddress(interface: name, family: .ipv6, bytes: bytes, isLoopback: isLoopback))
            default:
                continue
            }
        }
        return result
    }
}

// MARK: - Public IP (§3.5)

/// Injectable HTTP GET (fake client in tests).
protocol HTTPClient: Sendable {
    /// Returns the body and the HTTP status code.
    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int)
}

struct URLSessionHTTPClient: HTTPClient {
    init() {}

    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum PublicIPError: Error, Sendable, Equatable {
    /// Both primary and fallback sources failed.
    case unavailable
}

struct PublicIPClient: Sendable {
    static let primaryURL = URL(string: "https://api.ipify.org?format=json")!
    static let fallbackURL = URL(string: "https://ifconfig.me/ip")!
    static let timeout: TimeInterval = 8

    let http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Primary → fallback. If both fail, `PublicIPError.unavailable`; if the task was cancelled, `CancellationError`.
    func fetch() async throws -> String {
        if let ip = await attempt(Self.primaryURL, parse: Self.parseIPify) { return ip }
        try Task.checkCancellation()
        if let ip = await attempt(Self.fallbackURL, parse: Self.parsePlainText) { return ip }
        try Task.checkCancellation()
        throw PublicIPError.unavailable
    }

    private func attempt(_ url: URL, parse: (Data) -> String?) async -> String? {
        guard let response = try? await http.get(url, timeout: Self.timeout),
              (200..<300).contains(response.statusCode) else { return nil }
        return parse(response.data)
    }

    /// ipify JSON `ip` field.
    static func parseIPify(_ data: Data) -> String? {
        struct Body: Decodable { let ip: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return validated(body.ip)
    }

    /// ifconfig.me plain text.
    static func parsePlainText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return validated(text)
    }

    private static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerAddress.parse(trimmed) == nil ? nil : trimmed
    }
}

import Darwin
import Foundation

// MARK: - Validation (§20)

/// Server `host` validation: IPv4/IPv6 literal or RFC 1123 hostname (≤ 253 characters); port 1…65535.
enum HostValidator {
    static let maxHostnameLength = 253
    static let maxLabelLength = 63
    static let portRange = 1...65_535

    enum Kind: Sendable, Equatable {
        case address(ServerAddress)
        case hostname(String)
    }

    /// Trimmed, lowercased, without a trailing root dot.
    static func normalized(_ host: String) -> String {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func isValidPort(_ port: Int) -> Bool { portRange.contains(port) }

    /// RFC 1123: labels of 1…63 `[a-z0-9-]` characters, no leading/trailing hyphen, total ≤ 253; the top-level
    /// label is not all digits, so a dotted-decimal lookalike (e.g. `999.1.1.1`) is never a hostname.
    static func isValidHostname(_ host: String) -> Bool {
        let text = normalized(host)
        guard !text.isEmpty, text.count <= maxHostnameLength else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...maxLabelLength).contains(label.count), label.first != "-", label.last != "-",
                  label.unicodeScalars.allSatisfy({ isHostnameScalar($0) }) else { return false }
        }
        guard let top = labels.last, !top.allSatisfy(\.isNumber) else { return false }
        return true
    }

    /// IP literal, valid hostname, or `nil` (invalid).
    static func classify(_ host: String) -> Kind? {
        if let address = ServerAddress.parse(host) { return .address(address) }
        return isValidHostname(host) ? .hostname(normalized(host)) : nil
    }

    private static func isHostnameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "0"..."9", "-": return true
        default: return false
        }
    }
}

// MARK: - Resolution model

enum ResolutionError: Error, Sendable, Equatable {
    /// Not an IP literal and not a valid hostname.
    case invalidHostname
    /// The name does not exist or has no A/AAAA record (NXDOMAIN, empty answer).
    case notFound
    /// Transient failure (no network, DNS server unreachable, timeout).
    case network
}

enum HostResolution: Sendable, Equatable {
    case resolved(ServerAddress)
    case failed(ResolutionError)

    var address: ServerAddress? {
        if case .resolved(let address) = self { return address }
        return nil
    }
}

/// Row-level resolution problem for the UI (§20); `nil` when the address is usable.
enum HostResolutionFailure: String, Sendable, Equatable {
    case invalid
    case notFound
    case network
    /// Valid hostname that has not been resolved yet.
    case pending

    init(_ error: ResolutionError) {
        switch error {
        case .invalidHostname: self = .invalid
        case .notFound: self = .notFound
        case .network: self = .network
        }
    }
}

extension ServerAddress {
    /// Textual IP (`1.2.3.4`, `2001:db8::1`); `nil` for the local machine row.
    var text: String? {
        switch self {
        case .ipv4(let bytes): return IPText.string(family: .ipv4, bytes: bytes)
        case .ipv6(let bytes): return IPText.string(family: .ipv6, bytes: bytes)
        case .localMachine: return nil
        }
    }
}

enum AddressPreference {
    /// First IPv4, otherwise first IPv6 (§20).
    static func pick(_ addresses: [ServerAddress]) -> ServerAddress? {
        addresses.first { if case .ipv4 = $0 { return true } else { return false } }
            ?? addresses.first { if case .ipv6 = $0 { return true } else { return false } }
    }
}

/// Effective address of a server host: the literal IP, or the resolved address of a hostname.
enum HostAddressing {
    /// `nil` = invalid, failed or not yet resolved.
    static func address(for host: String, in resolutions: [String: HostResolution]) -> ServerAddress? {
        switch HostValidator.classify(host) {
        case .address(let address)?: return address
        case .hostname(let name)?: return resolutions[name]?.address
        case nil: return nil
        }
    }

    /// Why the host has no usable address; `nil` if it has one.
    static func failure(for host: String, in resolutions: [String: HostResolution]) -> HostResolutionFailure? {
        switch HostValidator.classify(host) {
        case .address?: return nil
        case .hostname(let name)?:
            switch resolutions[name] {
            case .resolved?: return nil
            case .failed(let error)?: return HostResolutionFailure(error)
            case nil: return .pending
            }
        case nil: return .invalid
        }
    }
}

// MARK: - Resolver (DI)

protocol ServerAddressResolver: Sendable {
    /// All A/AAAA addresses of `hostname` in resolver order. Throws `ResolutionError`.
    func addresses(for hostname: String) async throws -> [ServerAddress]
}

/// `getaddrinfo` (A and AAAA). Blocking lookups run off the caller's executor; a lookup that takes longer
/// than `timeout` is reported as `.network`.
struct SystemAddressResolver: ServerAddressResolver {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    func addresses(for hostname: String) async throws -> [ServerAddress] {
        let timeout = self.timeout
        let result = await withTaskGroup(of: Result<[ServerAddress], ResolutionError>?.self) { group in
            group.addTask { await Task.detached { Self.lookup(hostname) }.value }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.network)
        }
        return try result.get()
    }

    static func lookup(_ hostname: String) -> Result<[ServerAddress], ResolutionError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        guard status == 0 else { return .failure(errorKind(status)) }
        var addresses: [ServerAddress] = []
        var cursor = list
        while let info = cursor?.pointee {
            if let sockaddr = info.ai_addr, let address = address(sockaddr, family: info.ai_family),
               !addresses.contains(address) {
                addresses.append(address)
            }
            cursor = info.ai_next
        }
        return addresses.isEmpty ? .failure(.notFound) : .success(addresses)
    }

    /// `EAI_NONAME`/`EAI_NODATA` = the name does not exist; everything else is a network-side failure.
    static func errorKind(_ status: Int32) -> ResolutionError {
        status == EAI_NONAME || status == EAI_NODATA ? .notFound : .network
    }

    private static func address(_ pointer: UnsafeMutablePointer<sockaddr>, family: Int32) -> ServerAddress? {
        switch family {
        case AF_INET:
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { value in
                var addr = value.pointee.sin_addr
                return .ipv4(withUnsafeBytes(of: &addr) { Array($0) })
            }
        case AF_INET6:
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value in
                var addr = value.pointee.sin6_addr
                return .ipv6(withUnsafeBytes(of: &addr) { Array($0) })
            }
        default:
            return nil
        }
    }
}

// MARK: - Cache (§20: 5 min)

/// Resolves server hosts with a 5-minute cache. IP literals and invalid names never reach the resolver.
/// Successful and "not found" answers are cached; transient network errors are not.
actor HostResolutionCache {
    static let ttl: TimeInterval = 300

    private let resolver: any ServerAddressResolver
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private var entries: [String: (resolution: HostResolution, expires: Date)] = [:]

    init(resolver: any ServerAddressResolver, now: @escaping @Sendable () -> Date, ttl: TimeInterval = HostResolutionCache.ttl) {
        self.resolver = resolver
        self.now = now
        self.ttl = ttl
    }

    func resolve(_ host: String) async -> HostResolution {
        switch HostValidator.classify(host) {
        case .address(let address)?: return .resolved(address)
        case nil: return .failed(.invalidHostname)
        case .hostname(let name)?:
            if let cached = entries[name], cached.expires > now() { return cached.resolution }
            let resolution: HostResolution
            do {
                let addresses = try await resolver.addresses(for: name)
                resolution = AddressPreference.pick(addresses).map(HostResolution.resolved) ?? .failed(.notFound)
            } catch let error as ResolutionError {
                resolution = .failed(error)
            } catch {
                resolution = .failed(.network)
            }
            if resolution != .failed(.network) {
                entries[name] = (resolution, now().addingTimeInterval(ttl))
            }
            return resolution
        }
    }

    /// Resolutions of the hostnames among `hosts`, keyed by normalized hostname (IP literals are omitted).
    func resolveAll(_ hosts: [String]) async -> [String: HostResolution] {
        var names: [String] = []
        for host in hosts {
            if case .hostname(let name)? = HostValidator.classify(host), !names.contains(name) { names.append(name) }
        }
        return await withTaskGroup(of: (String, HostResolution).self) { group in
            for name in names {
                group.addTask { (name, await self.resolve(name)) }
            }
            var result: [String: HostResolution] = [:]
            for await (name, resolution) in group { result[name] = resolution }
            return result
        }
    }
}

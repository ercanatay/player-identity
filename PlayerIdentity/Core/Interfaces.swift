import Darwin
import Foundation

// MARK: - §37 Interfaces and VPN detection

/// One `getifaddrs` entry, including interfaces without an IP address (`AF_LINK`).
struct InterfaceRecord: Sendable, Equatable {
    let name: String
    let isUp: Bool
    let isRunning: Bool
    let isLoopback: Bool
    /// `nil` for link-layer entries.
    let family: AddressFamily?
    let bytes: [UInt8]

    init(name: String, isUp: Bool = true, isRunning: Bool = true, isLoopback: Bool = false,
         family: AddressFamily? = nil, bytes: [UInt8] = []) {
        self.name = name
        self.isUp = isUp
        self.isRunning = isRunning
        self.isLoopback = isLoopback
        self.family = family
        self.bytes = bytes
    }
}

/// An interface as shown in the network card.
struct NetworkInterface: Sendable, Equatable {
    let name: String
    let ipv4: [String]
    let ipv6: [String]
    /// Up, running and with an address.
    let isActive: Bool
    /// Tunnel interface (`utun*`, `ipsec*`, `ppp*`).
    let isTunnel: Bool
    /// The interface outgoing traffic currently uses.
    let isEgress: Bool
}

struct InterfaceReport: Sendable, Equatable {
    let interfaces: [NetworkInterface]
    /// Interface of the default route (outgoing traffic); `nil` if unknown.
    let egressInterface: String?
    /// "VPN aktif": the default route goes through a tunnel interface.
    var isVPNActive: Bool { egressInterface.map(InterfaceInventory.isTunnel) ?? false }
}

protocol InterfaceListing: Sendable {
    func records() -> [InterfaceRecord]
}

/// Name of the interface the default route uses.
protocol EgressRouteProviding: Sendable {
    func egressInterface(records: [InterfaceRecord]) -> String?
}

enum InterfaceInventory {
    /// Interface kinds listed in the card (others such as `awdl`, `llw`, `anpi`, `gif`, `stf` are left out).
    static let shownPrefixes = ["en", "utun", "bridge", "ipsec", "ppp"]
    static let tunnelPrefixes = ["utun", "ipsec", "ppp"]

    static func isTunnel(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    /// Groups the records per interface. Loopback and IPv6 link-local (`fe80::/10`) addresses are left out;
    /// interfaces without a remaining address are listed only if they carry the default route.
    /// Order: egress first, then by name (`en0`, `en1`, `utun3` …).
    static func report(records: [InterfaceRecord], egress: String?) -> InterfaceReport {
        var order: [String] = []
        var flags: [String: (up: Bool, running: Bool)] = [:]
        var v4: [String: [String]] = [:]
        var v6: [String: [String]] = [:]
        for record in records where !record.isLoopback && record.name != "lo0"
            && shownPrefixes.contains(where: { record.name.hasPrefix($0) }) {
            if !order.contains(record.name) { order.append(record.name) }
            let previous = flags[record.name] ?? (false, false)
            flags[record.name] = (previous.up || record.isUp, previous.running || record.isRunning)
            switch record.family {
            case .ipv4?:
                if let text = IPText.string(family: .ipv4, bytes: record.bytes), !(v4[record.name] ?? []).contains(text) {
                    v4[record.name, default: []].append(text)
                }
            case .ipv6?:
                guard !LocalIPFilter.isLinkLocalIPv6(record.bytes) else { continue }
                if let text = IPText.string(family: .ipv6, bytes: record.bytes), !(v6[record.name] ?? []).contains(text) {
                    v6[record.name, default: []].append(text)
                }
            case nil:
                continue
            }
        }
        let interfaces = order.compactMap { name -> NetworkInterface? in
            let addresses4 = v4[name] ?? [], addresses6 = v6[name] ?? []
            let hasAddress = !addresses4.isEmpty || !addresses6.isEmpty
            guard hasAddress || name == egress else { return nil }
            let state = flags[name] ?? (false, false)
            return NetworkInterface(name: name, ipv4: addresses4, ipv6: addresses6,
                                    isActive: state.up && state.running && hasAddress,
                                    isTunnel: isTunnel(name), isEgress: name == egress)
        }
        .sorted { lhs, rhs in
            if lhs.isEgress != rhs.isEgress { return lhs.isEgress }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return InterfaceReport(interfaces: interfaces, egressInterface: egress)
    }

    /// Interface that owns `address` (used to map the egress source address to its interface).
    static func interface(owning address: [UInt8], family: AddressFamily, in records: [InterfaceRecord]) -> String? {
        records.first { $0.family == family && $0.bytes == address }?.name
    }
}

/// `getifaddrs` with flags (`IFF_UP`, `IFF_RUNNING`, `IFF_LOOPBACK`).
struct SystemInterfaceLister: InterfaceListing {
    init() {}

    func records() -> [InterfaceRecord] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceRecord] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let entry = pointer.pointee
            cursor = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            let flags = Int32(bitPattern: entry.ifa_flags)
            let up = flags & IFF_UP != 0, running = flags & IFF_RUNNING != 0, loopback = flags & IFF_LOOPBACK != 0
            var family: AddressFamily?
            var bytes: [UInt8] = []
            if let sa = entry.ifa_addr {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    var sin = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in.self)
                    family = .ipv4
                    bytes = withUnsafeBytes(of: &sin.sin_addr) { Array($0) }
                case AF_INET6:
                    var sin6 = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in6.self)
                    family = .ipv6
                    bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                default:
                    break
                }
            }
            result.append(InterfaceRecord(name: name, isUp: up, isRunning: running, isLoopback: loopback,
                                          family: family, bytes: bytes))
        }
        return result
    }
}

/// Finds the egress interface without sending anything: a UDP socket is `connect`ed to a public address
/// (only a route lookup, no packet), and its local address is matched to an interface.
struct SocketEgressRouteProvider: EgressRouteProviding {
    /// Any public address works; documentation range so nothing is ever contacted.
    static let probeIPv4: [UInt8] = [198, 51, 100, 1]

    init() {}

    func egressInterface(records: [InterfaceRecord]) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(53).bigEndian
        withUnsafeMutableBytes(of: &target.sin_addr) { $0.copyBytes(from: Self.probeIPv4) }
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        let bytes = withUnsafeBytes(of: &local.sin_addr) { Array($0) }
        return InterfaceInventory.interface(owning: bytes, family: .ipv4, in: records)
    }
}

/// Reads the interfaces and the egress interface (fakes in tests).
struct InterfaceReporter: Sendable {
    let lister: any InterfaceListing
    let egress: any EgressRouteProviding

    init(lister: any InterfaceListing = SystemInterfaceLister(), egress: any EgressRouteProviding = SocketEgressRouteProvider()) {
        self.lister = lister
        self.egress = egress
    }

    func report() -> InterfaceReport {
        let records = lister.records()
        return InterfaceInventory.report(records: records, egress: egress.egressInterface(records: records))
    }
}

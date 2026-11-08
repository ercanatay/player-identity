import CryptoKit
import Darwin
import Foundation

/// Server address bytes appended to the CID input (§4).
enum ServerAddress: Sendable, Equatable {
    /// 4 bytes, network order.
    case ipv4([UInt8])
    /// 16 bytes, network order.
    case ipv6([UInt8])
    /// "Local machine" row: no IP bytes.
    case localMachine

    var bytes: [UInt8] {
        switch self {
        case .ipv4(let bytes), .ipv6(let bytes): return bytes
        case .localMachine: return []
        }
    }

    /// Parses IPv4 or IPv6 text. Invalid text (including domain names) → `nil`.
    static func parse(_ host: String) -> ServerAddress? {
        let text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return .ipv4(withUnsafeBytes(of: &v4) { Array($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return .ipv6(withUnsafeBytes(of: &v6) { Array($0) })
        }
        return nil
    }
}

/// `CID = MD5(rawID(8 bytes, little-endian) + address bytes).hexLower()` (§4).
enum CIDCalculator {
    static func input(rawID: UInt64, address: ServerAddress) -> [UInt8] {
        withUnsafeBytes(of: rawID.littleEndian) { Array($0) } + address.bytes
    }

    /// 32 lowercase hex characters.
    static func cid(rawID: UInt64, address: ServerAddress) -> String {
        let digest = Insecure.MD5.hash(data: input(rawID: rawID, address: address))
        return hexLower(Array(digest))
    }

    /// CID from host text; `nil` if the host is invalid.
    static func cid(rawID: UInt64, host: String) -> String? {
        ServerAddress.parse(host).map { cid(rawID: rawID, address: $0) }
    }

    static func hexLower(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

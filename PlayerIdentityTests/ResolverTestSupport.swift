import Foundation
@testable import PlayerIdentity

/// Resolver that never touches DNS: scripted answers per hostname, call counting. Unknown names → `notFound`.
final class FakeAddressResolver: ServerAddressResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<[ServerAddress], ResolutionError>]
    private var calls: [String] = []

    init(_ answers: [String: Result<[ServerAddress], ResolutionError>] = [:]) {
        self.answers = answers
    }

    var callCount: Int { lock.withLock { calls.count } }
    var requestedNames: [String] { lock.withLock { calls } }

    func set(_ name: String, _ answer: Result<[ServerAddress], ResolutionError>) {
        lock.withLock { answers[name] = answer }
    }

    func addresses(for hostname: String) async throws -> [ServerAddress] {
        let answer = lock.withLock { () -> Result<[ServerAddress], ResolutionError> in
            calls.append(hostname)
            return answers[hostname] ?? .failure(.notFound)
        }
        return try answer.get()
    }
}

enum TestAddresses {
    static func v4(_ text: String) -> ServerAddress { ServerAddress.parse(text)! }
    static func v6(_ text: String) -> ServerAddress { ServerAddress.parse(text)! }
}

/// A2S_INFO reply builders (§21).
enum A2SFixture {
    static let header: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]

    static func cString(_ bytes: [UInt8]) -> [UInt8] { bytes + [0] }
    static func cString(_ text: String) -> [UInt8] { cString(Array(text.utf8)) }

    /// GoldSrc `0x6D`: address, name, map, folder, game, players, max, protocol.
    static func goldSrc(name: [UInt8] = Array("POLIGON RPG".utf8), map: String = "rpg_city",
                        players: UInt8 = 9, max: UInt8 = 26) -> [UInt8] {
        header + [0x6D] + cString("51.68.190.91:27015") + cString(name) + cString(map) + cString("valve")
            + cString("Half-Life") + [players, max, 47, 0x64, 0x6C, 0x00, 0x00]
    }

    /// Source `0x49`: protocol, name, map, folder, game, app id, players, max, bots, …
    static func source(name: [UInt8] = Array("Source Server".utf8), map: String = "de_dust2",
                       players: UInt8 = 12, max: UInt8 = 32) -> [UInt8] {
        header + [0x49, 17] + cString(name) + cString(map) + cString("cstrike") + cString("Counter-Strike")
            + [0x0A, 0x00, players, max, 0, 0x64, 0x6C, 0x00, 0x01]
    }
}

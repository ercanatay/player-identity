import Foundation
@testable import PlayerIdentity

/// §37 fake interface list.
struct FakeInterfaceLister: InterfaceListing {
    let list: [InterfaceRecord]
    init(_ list: [InterfaceRecord]) { self.list = list }
    func records() -> [InterfaceRecord] { list }
}

/// §37 fake default route.
struct FakeEgressRoute: EgressRouteProviding {
    let name: String?
    init(_ name: String?) { self.name = name }
    func egressInterface(records: [InterfaceRecord]) -> String? { name }
}

/// §40 records the opened URLs instead of opening a browser.
final class RecordingURLOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var opened: [URL] { lock.withLock { urls } }

    @MainActor func open(_ url: URL) -> Bool {
        lock.withLock { urls.append(url) }
        return true
    }
}

enum InterfaceFixture {
    static func v4(_ name: String, _ text: String, up: Bool = true) -> InterfaceRecord {
        InterfaceRecord(name: name, isUp: up, isRunning: up, family: .ipv4, bytes: ServerAddress.parse(text)!.bytes)
    }

    static func v6(_ name: String, _ text: String) -> InterfaceRecord {
        InterfaceRecord(name: name, family: .ipv6, bytes: ServerAddress.parse(text)!.bytes)
    }

    static func link(_ name: String, up: Bool = true) -> InterfaceRecord {
        InterfaceRecord(name: name, isUp: up, isRunning: up)
    }
}

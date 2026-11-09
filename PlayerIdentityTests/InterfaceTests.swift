import XCTest
@testable import PlayerIdentity

/// §37 interface list, VPN detection, egress interface.
final class InterfaceTests: XCTestCase {
    private typealias F = InterfaceFixture

    private let records: [InterfaceRecord] = [
        F.link("lo0"), F.v4("lo0", "127.0.0.1"),
        F.link("en0"), F.v4("en0", "192.0.2.10"), F.v6("en0", "fe80::1"), F.v6("en0", "2001:db8::10"),
        F.link("en1", up: false),
        F.link("utun0"), F.v6("utun0", "fe80::abcd"),            // system tunnel, link-local only
        F.link("utun4"), F.v4("utun4", "10.8.0.2"),
        F.link("bridge100"), F.v4("bridge100", "192.0.2.64"),
        F.link("awdl0"), F.v6("awdl0", "fe80::2"),
    ]

    func testListWithoutLoopbackAndLinkLocal() {
        let report = InterfaceInventory.report(records: records, egress: "en0")
        XCTAssertEqual(report.interfaces.map(\.name), ["en0", "bridge100", "utun4"])   // egress first, then by name
        let en0 = report.interfaces[0]
        XCTAssertEqual(en0.ipv4, ["192.0.2.10"])
        XCTAssertEqual(en0.ipv6, ["2001:db8::10"])                // fe80:: left out
        XCTAssertTrue(en0.isActive)
        XCTAssertTrue(en0.isEgress)
        XCTAssertFalse(en0.isTunnel)
        XCTAssertTrue(report.interfaces[2].isTunnel)
        XCTAssertFalse(report.isVPNActive)                        // utun exists but the route goes via en0
    }

    func testVPNActiveWhenTheDefaultRouteUsesATunnel() {
        let report = InterfaceInventory.report(records: records, egress: "utun4")
        XCTAssertTrue(report.isVPNActive)
        XCTAssertEqual(report.interfaces.first?.name, "utun4")
        XCTAssertEqual(report.egressInterface, "utun4")
        XCTAssertTrue(InterfaceInventory.report(records: records, egress: "ipsec0").isVPNActive)
        XCTAssertFalse(InterfaceInventory.report(records: [], egress: nil).isVPNActive)
    }

    func testInactiveInterfacesAndEgressWithoutAddress() {
        let down = [F.link("en1", up: false), F.v4("en1", "192.0.2.20", up: false)]
        let report = InterfaceInventory.report(records: down, egress: nil)
        XCTAssertEqual(report.interfaces.map(\.name), ["en1"])
        XCTAssertFalse(report.interfaces[0].isActive)
        // A tunnel carrying the default route is listed even without a global address.
        let tunnel = InterfaceInventory.report(records: [F.link("utun2"), F.v6("utun2", "fe80::9")], egress: "utun2")
        XCTAssertEqual(tunnel.interfaces.map(\.name), ["utun2"])
        XCTAssertFalse(tunnel.interfaces[0].isActive)
        XCTAssertTrue(tunnel.isVPNActive)
    }

    func testEgressInterfaceFromTheSourceAddress() {
        XCTAssertEqual(InterfaceInventory.interface(owning: [10, 8, 0, 2], family: .ipv4, in: records), "utun4")
        XCTAssertEqual(InterfaceInventory.interface(owning: [192, 0, 2, 10], family: .ipv4, in: records), "en0")
        XCTAssertNil(InterfaceInventory.interface(owning: [203, 0, 113, 1], family: .ipv4, in: records))
        let reporter = InterfaceReporter(lister: FakeInterfaceLister(records), egress: FakeEgressRoute("utun4"))
        XCTAssertTrue(reporter.report().isVPNActive)
    }

    func testRealListerAndRouteLookupSendNothingAndDoNotCrash() {
        // Read-only system calls: getifaddrs and a UDP connect (route lookup only).
        let records = SystemInterfaceLister().records()
        XCTAssertTrue(records.contains { $0.name == "lo0" })
        let egress = SocketEgressRouteProvider().egressInterface(records: records)
        if let egress { XCTAssertTrue(records.contains { $0.name == egress }) }
    }

    @MainActor
    func testRefreshStoresTheInterfaceReport() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel { deps in
            deps.interfaceReporter = InterfaceReporter(lister: FakeInterfaceLister(self.records), egress: FakeEgressRoute("utun4"))
        }
        XCTAssertNil(model.interfaceReport)
        await model.refresh().value
        XCTAssertEqual(model.interfaceReport?.isVPNActive, true)
        XCTAssertEqual(model.interfaceReport?.interfaces.count, 3)
    }
}

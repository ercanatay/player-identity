import XCTest
@testable import OyuncuKimlik

/// §17.6 + §17.9.5: sahte yürütücü/IP/saat; ağa çıkmaz, gerçek komut çalışmaz.
final class IPBanFixerTests: XCTestCase {
    private let en0 = NetworkInterfaceName("en0")!

    private func check(_ status: BanStatus, _ detail: String = "") -> BanCheck {
        BanCheck(status: status, checkedAt: Date(timeIntervalSince1970: 1_793_000_000), detail: detail)
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [FixProgress] = []
        func add(_ p: FixProgress) { lock.withLock { items.append(p) } }
        var all: [FixProgress] { lock.withLock { items } }
    }

    private func fixer(runner: FakeCommandRunner, ips: SequencedIPs, clock: TestClock, sleeper: FakeSleeper? = nil,
                       recheck: BanCheck?, log: ProgressLog = ProgressLog()) -> IPBanFixer {
        IPBanFixer(runner: runner, sleeper: sleeper ?? FakeSleeper(clock: clock), now: { clock.now },
                   fetchPublicIP: { try ips.next() }, recheck: { recheck }, progress: { log.add($0) })
    }

    // 1. IP değişti + ban kalktı → başarı
    func testIPChangedAndBanLifted() async {
        let clock = TestClock()
        let runner = FakeCommandRunner()
        let log = ProgressLog()
        let ips = SequencedIPs(["198.51.100.10", nil, "88.230.1.2"])
        let result = await fixer(runner: runner, ips: ips, clock: clock, recheck: check(.ipOk), log: log).run()
        XCTAssertEqual(result.outcome, .resolved(old: "198.51.100.10", new: "88.230.1.2"))
        XCTAssertEqual(result.outcome.message, "Çözüldü: IP değişti (198.51.100.10 → 88.230.1.2), ban kalktı.")
        XCTAssertEqual(result.newIP, "88.230.1.2")
        XCTAssertEqual(runner.commands, [.routeGetDefault, .airportPowerStatus(en0),
                                         .setAirportPower(en0, on: false), .setAirportPower(en0, on: true)])
        XCTAssertEqual(log.all, [.renewingIP, .waitingForNetwork, .rechecking])
        XCTAssertEqual(FixProgress.renewingIP.text, "IP yenileniyor…")
        XCTAssertEqual(FixProgress.waitingForNetwork.text, "Ağ bekleniyor…")
        XCTAssertEqual(FixProgress.rechecking.text, "Yeniden kontrol ediliyor…")
    }

    // 2. IP değişti + ban sürüyor → uyarı, üç neden, "çözüldü" yok (§17.9.3)
    func testIPChangedButStillBanned() async {
        let clock = TestClock()
        let result = await fixer(runner: FakeCommandRunner(), ips: SequencedIPs(["1.1.1.1", "2.2.2.2"]), clock: clock,
                                 recheck: check(.ipBanned)).run()
        XCTAssertEqual(result.outcome, .stillBanned(old: "1.1.1.1", new: "2.2.2.2"))
        XCTAssertEqual(result.outcome.message,
                       "Yeni IP de banlı olabilir (subnet/aralık banı) veya sunucu tüm aralığı engelliyor.")
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertFalse(result.outcome.message.lowercased().contains("çözüldü"))
        XCTAssertEqual(IPFixOutcome.stillBannedReasons.count, 3)
        XCTAssertTrue(IPFixOutcome.stillBannedReasons[0].hasPrefix("Aralık/subnet banı"))
        XCTAssertTrue(IPFixOutcome.stillBannedReasons[1].hasPrefix("Plugin/SQL banı"))
        XCTAssertTrue(IPFixOutcome.stillBannedReasons[2].hasPrefix("sv_filterban"))
    }

    // 3. IP değişmedi → yönlendirme metni + router bağlantısı
    func testIPUnchangedGivesNextSteps() async {
        let clock = TestClock()
        let result = await fixer(runner: FakeCommandRunner(), ips: SequencedIPs(["1.1.1.1"]), clock: clock,
                                 recheck: check(.ipOk)).run()
        XCTAssertEqual(result.outcome, .ipUnchanged(ip: "1.1.1.1", routerURL: URL(string: "http://192.0.2.1")))
        XCTAssertEqual(result.outcome.message, "IP değişmedi.")
        XCTAssertNil(result.recheck)                                   // A = B → yeniden kontrol yok
        XCTAssertEqual(IPFixOutcome.unchangedNextSteps.count, 3)
        XCTAssertTrue(IPFixOutcome.unchangedNextSteps.joined().contains("PPPoE/WAN"))
        XCTAssertTrue(IPFixOutcome.unchangedNextSteps.joined().contains("VPN"))
        XCTAssertTrue(IPFixOutcome.unchangedNextSteps.joined().contains("birkaç saat sonra"))
    }

    // 4. Ağ geri gelmedi (45 sn) → `on` yeniden çağrıldı + hata; arayüz açık
    func testNetworkTimeoutRestoresInterface() async {
        let clock = TestClock()
        let start = clock.now
        let runner = FakeCommandRunner()
        let ips = SequencedIPs(["1.1.1.1", nil])
        let result = await fixer(runner: runner, ips: ips, clock: clock, recheck: nil).run()
        XCTAssertEqual(result.outcome, .networkTimeout)
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), IPBanFixer.networkWaitTimeout)
        XCTAssertLessThan(clock.now.timeIntervalSince(start), IPBanFixer.networkWaitTimeout + 10)
        XCTAssertEqual(runner.commands.last, .setAirportPower(en0, on: true))
        XCTAssertEqual(runner.commands.filter { $0 == .setAirportPower(en0, on: true) }.count, 2)   // normal açma + geri yükleme
        // 3 sn'de bir deneme: ilk A + ~15 deneme
        XCTAssertGreaterThanOrEqual(ips.callCount, 15)
    }

    // 6. İptal → zincir durdu, arayüz açık
    func testCancellationStopsChainAndRestores() async throws {
        let clock = TestClock()
        let runner = FakeCommandRunner()
        let fixer = fixer(runner: runner, ips: SequencedIPs(["1.1.1.1", "2.2.2.2"]), clock: clock,
                          sleeper: FakeSleeper(clock: clock, blocking: true), recheck: check(.ipOk))
        let task = Task { await fixer.run() }
        // Wi-Fi kapalıyken (3 sn bekleme sırasında) iptal
        for _ in 0..<200 where !runner.commands.contains(.setAirportPower(en0, on: false)) {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.outcome.message, "Düzeltme iptal edildi. Arayüz açık bırakıldı.")
        XCTAssertEqual(runner.commands.suffix(2), [.setAirportPower(en0, on: false), .setAirportPower(en0, on: true)])
        XCTAssertNil(result.newIP)
    }

    func testEthernetUsesDHCPWithoutTouchingWiFi() async {
        let clock = TestClock()
        let runner = FakeCommandRunner(responder: FakeCommandRunner.ethernet())
        let result = await fixer(runner: runner, ips: SequencedIPs(["1.1.1.1", "2.2.2.2"]), clock: clock,
                                 recheck: check(.cidOk)).run()
        XCTAssertEqual(result.outcome, .resolved(old: "1.1.1.1", new: "2.2.2.2"))
        XCTAssertEqual(runner.commands, [.routeGetDefault, .airportPowerStatus(en0), .renewDHCP(en0)])
    }

    func testAdminDeclinedIsReportedHonestly() async {
        let clock = TestClock()
        let runner = FakeCommandRunner(responder: FakeCommandRunner.ethernet(dhcpStatus: 1))
        let result = await fixer(runner: runner, ips: SequencedIPs(["1.1.1.1"]), clock: clock, recheck: nil).run()
        XCTAssertEqual(result.outcome, .failed(.adminDeclined))
        XCTAssertFalse(runner.commands.contains { if case .setAirportPower = $0 { return true }; return false })
    }

    func testChangedIPWithOtherResultsIsNotCalledResolved() async {
        for (status, expected) in [(BanStatus.cidBanned, "sunucu CID'yi banlamış"), (.unreachable, "doğrulanamadı")] {
            let clock = TestClock()
            let result = await fixer(runner: FakeCommandRunner(), ips: SequencedIPs(["1.1.1.1", "2.2.2.2"]),
                                     clock: clock, recheck: check(status)).run()
            XCTAssertEqual(result.outcome, .changedUnverified(old: "1.1.1.1", new: "2.2.2.2", status: status))
            XCTAssertTrue(result.outcome.message.contains(expected), result.outcome.message)
            XCTAssertFalse(result.outcome.message.contains("Çözüldü"))
        }
    }

    func testNoPublicIPOrRouteStopsBeforeAnyInterfaceCommand() async {
        let clock = TestClock()
        let runner = FakeCommandRunner()
        let noIP = await fixer(runner: runner, ips: SequencedIPs([nil]), clock: clock, recheck: nil).run()
        XCTAssertEqual(noIP.outcome, .failed(.publicIPUnavailable))
        XCTAssertEqual(runner.commands, [])

        let noRoute = FakeCommandRunner { command in
            command == .routeGetDefault ? CommandOutput(status: 1, output: "route: writing to routing socket: not in table")
                                        : CommandOutput(status: 0, output: "")
        }
        let result = await fixer(runner: noRoute, ips: SequencedIPs(["1.1.1.1"]), clock: clock, recheck: nil).run()
        XCTAssertEqual(result.outcome, .failed(.noDefaultRoute))
        XCTAssertEqual(noRoute.commands, [.routeGetDefault])
    }
}

final class BanFixSafetyTests: XCTestCase {
    // 7. Eşzamanlı ikinci Düzelt → kilit reddetti; 60 sn aralık
    func testLockRejectsConcurrentAndEnforcesSixtySeconds() async {
        let lock = BanFixLock()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = await lock.acquire(now: t0)
        let concurrent = await lock.acquire(now: t0.addingTimeInterval(1))
        await lock.release()
        let tooSoon = await lock.acquire(now: t0.addingTimeInterval(59))
        let later = await lock.acquire(now: t0.addingTimeInterval(60))
        XCTAssertTrue(first)
        XCTAssertFalse(concurrent)
        XCTAssertFalse(tooSoon)
        XCTAssertTrue(later)
    }

    // 8. Allowlist dışı komut üretilemez
    func testAllowlistAcceptsOnlyFixedCommands() {
        let en0 = NetworkInterfaceName("en0")!
        let all: [NetworkCommand] = [.routeGetDefault, .airportPowerStatus(en0), .setAirportPower(en0, on: false),
                                     .setAirportPower(en0, on: true), .renewDHCP(en0)]
        for command in all {
            XCTAssertTrue(CommandAllowlist.isAllowed(command.argv), "\(command.argv)")
        }
        XCTAssertEqual(NetworkCommand.renewDHCP(en0).argv,
                       ["/usr/bin/osascript", "-e", "do shell script \"/usr/sbin/ipconfig set en0 DHCP\" with administrator privileges"])
        for bad in [["/bin/sh", "-c", "networksetup -setairportpower en0 off"],
                    ["/usr/sbin/networksetup", "-setairportpower", "en0", "off; rm -rf /"],
                    ["/usr/sbin/networksetup", "-setairportpower", "en0;ls", "off"],
                    ["/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", "1.1.1.1"],
                    ["/sbin/route", "add", "default", "10.0.0.1"],
                    ["/usr/bin/osascript", "-e", "do shell script \"rm -rf /\" with administrator privileges"],
                    ["/usr/bin/osascript", "-e", "do shell script \"/usr/sbin/ipconfig set en0 DHCP; id\" with administrator privileges"],
                    ["networksetup", "-setairportpower", "en0", "off"],
                    []] {
            XCTAssertFalse(CommandAllowlist.isAllowed(bad), "\(bad)")
        }
        for injected in ["en0; rm -rf /", "en0 DHCP", "../en0", "EN0", "en", "en0\"", "$(id)", "wifi0x"] {
            XCTAssertNil(NetworkInterfaceName(injected), injected)
        }
    }

    func testRunnerRefusesNonAllowlistedArgvAndNoServerCommandsExist() async {
        // §17.9.5/12: istemci tarafında banid/removeid gibi sunucu komutu yoktur.
        let en0 = NetworkInterfaceName("en0")!
        let argvs = [NetworkCommand.routeGetDefault, .airportPowerStatus(en0), .setAirportPower(en0, on: true),
                     .setAirportPower(en0, on: false), .renewDHCP(en0)].map { $0.argv.joined(separator: " ") }
        for word in ["banid", "removeid", "removeip", "addip", "writeid", "writeip", "rcon", "amx_unban"] {
            XCTAssertFalse(argvs.contains { $0.contains(word) }, word)
        }
    }

    func testDefaultRouteAndWiFiDetectionParsing() {
        let route = DefaultRoute.parse(FakeCommandRunner.routeOutput)
        XCTAssertEqual(route?.interface.value, "en0")
        XCTAssertEqual(route?.gateway, "192.0.2.1")
        XCTAssertEqual(route?.routerURL, URL(string: "http://192.0.2.1"))
        XCTAssertNil(DefaultRoute.parse("route: writing to routing socket: not in table"))
        XCTAssertNil(DefaultRoute.parse("interface: en0; rm\n"))
        XCTAssertTrue(AirportPowerStatus.isWiFi(CommandOutput(status: 0, output: "Wi-Fi Power (en0): On")))
        XCTAssertFalse(AirportPowerStatus.isWiFi(CommandOutput(status: 10, output: "en5 is not a Wi-Fi interface.")))
    }

    func testFixButtonVisibility() {
        XCTAssertEqual(FixKind.forStatus(.ipBanned), .ipBan)
        XCTAssertEqual(FixKind.forStatus(.cidBanned), .cidBan)
        XCTAssertEqual(FixKind.forStatus(.unreachable), .unreachable)
        for status in [BanStatus.ipOk, .cidOk, .cidNotApplicable, .cidUnknown, .unknown] {
            XCTAssertNil(FixKind.forStatus(status), status.rawValue)
        }
        XCTAssertNil(FixKind.forStatus(nil))
    }

    func testGameTrackerLink() {
        XCTAssertEqual(GameTrackerLink.url(host: "51.68.190.91", port: 27015)?.absoluteString,
                       "https://www.gametracker.com/server_info/51.68.190.91:27015/")
        XCTAssertNil(GameTrackerLink.url(host: "evil.com/x", port: 27015))
    }
}

/// §17.9.1 itiraz metni, §17.9.2 sınıflandırma.
final class AppealTextTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26T07:33:20Z

    private func input(_ check: BanCheck) -> AppealInput {
        AppealInput(serverLabel: "POLIGON RPG", host: "51.68.190.91", port: 27015, checkedAt: checkedAt,
                    playerName: "TestOyuncu", cid: "d9de0eb4419608a8423241430581e91c",
                    publicIP: "198.51.100.10", gamedir: "valve", check: check)
    }

    func testAppealContainsAllRequiredFields() {
        let check = BanCheck(status: .ipBanned, checkedAt: checkedAt,
                             detail: "ipBanned: You have been banned from this server.")
        let text = AppealText.make(input(check), timeZone: TimeZone(identifier: "Europe/Istanbul")!)
        let utc = ISO8601DateFormatter().string(from: checkedAt)
        for field in ["POLIGON RPG", "51.68.190.91:27015",                       // sunucu adı + host:port
                      "(yerel)", "\(utc) (UTC)",                                // yerel saat + UTC
                      "TestOyuncu",                                   // oyuncu adı
                      "d9de0eb4419608a8423241430581e91c",                       // CID (32 hex)
                      "198.51.100.10",                                         // çıkış IP'si
                      "gamedir valve", "Xash3D FWGS",                           // gamedir/istemci
                      "ipBanned: You have been banned from this server.",       // ham cevap
                      "engine IP (getchallenge)",                               // kontrol türü
                      "yanlışlıkla banlandım, kaldırır mısınız?",                // §17.3 şablon
                      "Ban süreliyse bitiş zamanını ve gerekçesini"] {           // süreli ban sorusu
            XCTAssertTrue(text.contains(field), "eksik alan: \(field)")
        }
        XCTAssertTrue(text.contains("26.10.2026 10:33:20 (yerel)"), text)        // Istanbul UTC+3
        XCTAssertEqual(AppealText.adminChecklist.count, 7)
        for (index, item) in AppealText.adminChecklist.enumerated() {
            XCTAssertTrue(text.contains("\(index + 1). \(item)"), item)
        }
        for command in ["listid", "listip", "removeid <id> + writeid", "removeip <ip> + writeip", "amx_unban <ip>",
                        "AMXBans", "sv_filterban"] {
            XCTAssertTrue(text.contains(command), command)
        }
        // Kontrol listesi metnin sonunda.
        XCTAssertTrue(text.hasSuffix(AppealText.adminChecklist.last!))
    }

    func testCheckTypeByClassification() {
        XCTAssertTrue(AppealText.make(input(BanCheck(status: .cidBanned, checkedAt: checkedAt,
                                                     detail: "ipOk → cidBanned: errormsg You are banned")))
            .contains("Kontrol türü: engine CID (connect 49)"))
        XCTAssertTrue(AppealText.make(input(BanCheck(status: .cidUnknown, checkedAt: checkedAt,
                                                     detail: "ipOk → cidUnknown: errormsg Server rejected")))
            .contains("Kontrol türü: bilinmiyor (plugin/SQL olabilir)"))
    }

    func testCIDUnknownRejectionIsUnverifiedTypeWithRawText() {
        let rejected = BanCheck(status: .cidUnknown, checkedAt: checkedAt,
                                detail: "ipOk → cidUnknown: disconnect Kicked by console")
        XCTAssertEqual(BanClassification.classify(rejected), .rejectedUnknownType(raw: "disconnect Kicked by console"))
        XCTAssertEqual(BanClassification.unverifiedText, "Ban türü doğrulanamadı (plugin/SQL olabilir)")
        let silent = BanCheck(status: .cidUnknown, checkedAt: checkedAt, detail: "ipOk → cidUnknown")
        XCTAssertEqual(BanClassification.classify(silent), .unknown)
        XCTAssertEqual(BanClassification.classify(BanCheck(status: .ipBanned, checkedAt: checkedAt, detail: "")), .engineIP)
        XCTAssertEqual(BanClassification.classify(BanCheck(status: .cidBanned, checkedAt: checkedAt, detail: "")), .engineCID)
        XCTAssertEqual(BanClassification.classify(BanCheck(status: .unreachable, checkedAt: checkedAt, detail: "")), .notBan)
    }
}

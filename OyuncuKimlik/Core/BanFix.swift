import Foundation

// MARK: - Komutlar ve allowlist (§17.2/3, §17.5)

/// Sistemden okunan arayüz adı (ör. `en0`). Kullanıcı girdisi değildir; yine de katı biçimde doğrulanır.
struct NetworkInterfaceName: Sendable, Equatable, CustomStringConvertible {
    let value: String

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...12).contains(text.count),
              text.range(of: "^[a-z]{2,8}[0-9]{1,3}$", options: .regularExpression) != nil else { return nil }
        value = text
    }

    var description: String { value }
}

/// Düzelt akışının çalıştırabileceği **tek** komut kümesi. Sunucu komutu (banid/removeid vb.) yoktur.
enum NetworkCommand: Sendable, Equatable {
    /// `/sbin/route -n get default` (salt okuma: varsayılan rota → arayüz, ağ geçidi)
    case routeGetDefault
    /// `/usr/sbin/networksetup -getairportpower <if>` (salt okuma: arayüz Wi-Fi mi)
    case airportPowerStatus(NetworkInterfaceName)
    /// `/usr/sbin/networksetup -setairportpower <if> on|off`
    case setAirportPower(NetworkInterfaceName, on: Bool)
    /// `ipconfig set <if> DHCP` — yönetici onayıyla (macOS sistem diyaloğu, `osascript … with administrator privileges`)
    case renewDHCP(NetworkInterfaceName)

    var argv: [String] {
        switch self {
        case .routeGetDefault:
            return ["/sbin/route", "-n", "get", "default"]
        case .airportPowerStatus(let interface):
            return ["/usr/sbin/networksetup", "-getairportpower", interface.value]
        case .setAirportPower(let interface, let on):
            return ["/usr/sbin/networksetup", "-setairportpower", interface.value, on ? "on" : "off"]
        case .renewDHCP(let interface):
            return ["/usr/bin/osascript", "-e",
                    "do shell script \"/usr/sbin/ipconfig set \(interface.value) DHCP\" with administrator privileges"]
        }
    }

    /// Arayüzü kapatır mı (geri yükleme gerektirir).
    var takesInterfaceDown: Bool {
        if case .setAirportPower(_, on: false) = self { return true }
        return false
    }
}

enum CommandAllowlist {
    private static let interfacePattern = "[a-z]{2,8}[0-9]{1,3}"

    /// Yalnız `NetworkCommand` biçimlerine birebir uyan argv'ler geçer.
    static func isAllowed(_ argv: [String]) -> Bool {
        func isInterface(_ text: String) -> Bool { NetworkInterfaceName(text)?.value == text }
        switch argv.count {
        case 4 where argv == ["/sbin/route", "-n", "get", "default"]:
            return true
        case 3 where argv[0] == "/usr/sbin/networksetup" && argv[1] == "-getairportpower":
            return isInterface(argv[2])
        case 4 where argv[0] == "/usr/sbin/networksetup" && argv[1] == "-setairportpower":
            return isInterface(argv[2]) && (argv[3] == "on" || argv[3] == "off")
        case 3 where argv[0] == "/usr/bin/osascript" && argv[1] == "-e":
            let script = argv[2]
            let pattern = "^do shell script \"/usr/sbin/ipconfig set \(interfacePattern) DHCP\" with administrator privileges$"
            return script.range(of: pattern, options: .regularExpression) != nil
        default:
            return false
        }
    }
}

struct CommandOutput: Sendable, Equatable {
    var status: Int32
    var output: String
}

enum CommandError: Error, Equatable {
    case notAllowed
    case launchFailed
}

protocol CommandRunning: Sendable {
    func run(_ command: NetworkCommand) async throws -> CommandOutput
}

/// Gerçek yürütücü: yalnız allowlist'teki argv; kabuk yorumlaması yok (`Process` doğrudan çalıştırır).
struct ProcessCommandRunner: CommandRunning {
    init() {}

    func run(_ command: NetworkCommand) async throws -> CommandOutput {
        let argv = command.argv
        guard CommandAllowlist.isAllowed(argv) else { throw CommandError.notAllowed }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { throw CommandError.launchFailed }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandOutput(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

protocol Sleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct TaskSleeper: Sleeping {
    init() {}
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}

// MARK: - Çıktı ayrıştırma

struct DefaultRoute: Sendable, Equatable {
    let interface: NetworkInterfaceName
    /// Yalnız IPv4 ağ geçidi (router arayüzü bağlantısı için).
    let gateway: String?

    static func parse(_ output: String) -> DefaultRoute? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let interface = values["interface"].flatMap(NetworkInterfaceName.init) else { return nil }
        var gateway: String?
        if let raw = values["gateway"], case .ipv4? = ServerAddress.parse(raw) { gateway = raw }
        return DefaultRoute(interface: interface, gateway: gateway)
    }

    var routerURL: URL? { gateway.flatMap { URL(string: "http://\($0)") } }
}

enum AirportPowerStatus {
    /// `Wi-Fi Power (en0): On` → Wi-Fi; "… is not a Wi-Fi interface" → değil.
    static func isWiFi(_ output: CommandOutput) -> Bool {
        output.status == 0 && output.output.range(of: #"(Wi-Fi|AirPort) Power \("#, options: .regularExpression) != nil
    }
}

// MARK: - Sonuçlar (§17.2, §17.9.3)

enum FixProgress: Sendable, Equatable {
    case renewingIP
    case waitingForNetwork
    case rechecking

    var text: String {
        switch self {
        case .renewingIP: return "IP yenileniyor…"
        case .waitingForNetwork: return "Ağ bekleniyor…"
        case .rechecking: return "Yeniden kontrol ediliyor…"
        }
    }
}

enum FixFailure: Sendable, Equatable {
    case publicIPUnavailable
    case noDefaultRoute
    case commandFailed
    case adminDeclined

    var text: String {
        switch self {
        case .publicIPUnavailable: return "Genel IP alınamadı; düzeltme başlatılmadı."
        case .noDefaultRoute: return "Varsayılan ağ arayüzü bulunamadı; düzeltme başlatılmadı."
        case .commandFailed: return "Ağ komutu başarısız oldu. Arayüz açık bırakıldı."
        case .adminDeclined: return "Yönetici onayı verilmedi veya DHCP yenilenemedi."
        }
    }
}

enum IPFixOutcome: Sendable, Equatable {
    /// A ≠ B ve yeniden kontrol IP engeli göstermiyor.
    case resolved(old: String, new: String)
    /// A ≠ B ama hâlâ `ipBanned`.
    case stillBanned(old: String, new: String)
    /// A = B.
    case ipUnchanged(ip: String, routerURL: URL?)
    /// A ≠ B ama sonuç doğrulanamadı (yeniden kontrol yok/başka sonuç).
    case changedUnverified(old: String, new: String, status: BanStatus?)
    /// Ağ 45 sn içinde geri gelmedi.
    case networkTimeout
    case failed(FixFailure)
    case cancelled

    var isSuccess: Bool {
        if case .resolved = self { return true }
        return false
    }

    /// Hiçbir durumda yalan "çözüldü" denmez: yalnız `resolved` bu ifadeyi kullanır.
    var message: String {
        switch self {
        case .resolved(let old, let new):
            return "Çözüldü: IP değişti (\(old) → \(new)), ban kalktı."
        case .stillBanned:
            return "Yeni IP de banlı olabilir (subnet/aralık banı) veya sunucu tüm aralığı engelliyor."
        case .ipUnchanged:
            return "IP değişmedi."
        case .changedUnverified(let old, let new, let status):
            if status == .cidBanned {
                return "IP değişti (\(old) → \(new)); IP engeli görünmüyor ama sunucu CID'yi banlamış."
            }
            return "IP değişti (\(old) → \(new)); ban durumu doğrulanamadı."
        case .networkTimeout:
            return "Ağ 45 sn içinde geri gelmedi. Arayüz açık bırakıldı; bağlantıyı kontrol edin."
        case .failed(let failure):
            return failure.text
        case .cancelled:
            return "Düzeltme iptal edildi. Arayüz açık bırakıldı."
        }
    }

    /// `ipUnchanged` için sonraki adımlar (§17.2/5).
    static let unchangedNextSteps = [
        "Router arayüzünü açın; oradan PPPoE/WAN bağlantısını yeniden kurun.",
        "VPN kullanın.",
        "Ban süreli olabilir: birkaç saat sonra yeniden deneyin.",
    ]

    /// `stillBanned` için olası nedenler, sırayla (§17.9.3). Otomatik çözüm önerilmez.
    static let stillBannedReasons = [
        "Aralık/subnet banı (IP banları kabadır, CGNAT havuzunu bile yakalayabilir).",
        "Plugin/SQL banı (IP'den bağımsız).",
        "sv_filterban davranışı.",
    ]
}

// MARK: - IP ban düzeltici (§17.2)

struct IPBanFixer: Sendable {
    static let networkWaitTimeout: TimeInterval = 45
    static let networkPollInterval: TimeInterval = 3
    static let wifiOffDuration: TimeInterval = 3

    let runner: any CommandRunning
    let sleeper: any Sleeping
    let now: @Sendable () -> Date
    let fetchPublicIP: @Sendable () async throws -> String
    /// A ≠ B olduğunda o sunucu için ban kontrolü; `nil` = çalıştırılamadı (ör. ayar kapalı).
    let recheck: @Sendable () async -> BanCheck?
    let progress: @Sendable (FixProgress) async -> Void

    struct Result: Sendable, Equatable {
        let outcome: IPFixOutcome
        let newIP: String?
        let recheck: BanCheck?
    }

    func run() async -> Result {
        await progress(.renewingIP)
        // 2. Eski IP (A)
        let oldIP: String
        do {
            oldIP = try await fetchPublicIP()
        } catch is CancellationError {
            return Result(outcome: .cancelled, newIP: nil, recheck: nil)
        } catch {
            return Result(outcome: .failed(.publicIPUnavailable), newIP: nil, recheck: nil)
        }

        // 3. Birincil arayüz
        let route: DefaultRoute
        do {
            guard let parsed = DefaultRoute.parse(try await runner.run(.routeGetDefault).output) else {
                return Result(outcome: .failed(.noDefaultRoute), newIP: nil, recheck: nil)
            }
            route = parsed
        } catch is CancellationError {
            return Result(outcome: .cancelled, newIP: nil, recheck: nil)
        } catch {
            return Result(outcome: .failed(.noDefaultRoute), newIP: nil, recheck: nil)
        }
        let interface = route.interface
        let isWiFi = (try? await runner.run(.airportPowerStatus(interface))).map(AirportPowerStatus.isWiFi) ?? false

        var outcome: IPFixOutcome
        var newIP: String?
        var recheckResult: BanCheck?
        var interfaceMayBeDown = false
        do {
            if isWiFi {
                interfaceMayBeDown = true
                guard try await runner.run(.setAirportPower(interface, on: false)).status == 0 else {
                    throw FixStop.failure(.commandFailed)
                }
                try await sleeper.sleep(seconds: Self.wifiOffDuration)
                guard try await runner.run(.setAirportPower(interface, on: true)).status == 0 else {
                    throw FixStop.failure(.commandFailed)
                }
                interfaceMayBeDown = false
            } else {
                guard try await runner.run(.renewDHCP(interface)).status == 0 else {
                    throw FixStop.failure(.adminDeclined)
                }
            }

            // 4. Ağ geri gelsin: en çok 45 sn, 3 sn'de bir genel IP
            await progress(.waitingForNetwork)
            let deadline = now().addingTimeInterval(Self.networkWaitTimeout)
            var fetched: String?
            while fetched == nil {
                try await sleeper.sleep(seconds: Self.networkPollInterval)
                do {
                    fetched = try await fetchPublicIP()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if now() >= deadline { throw FixStop.timeout }
                }
            }
            let ip = fetched ?? oldIP
            newIP = ip

            // 5. Karşılaştır
            if ip == oldIP {
                outcome = .ipUnchanged(ip: ip, routerURL: route.routerURL)
            } else {
                await progress(.rechecking)
                let check = await recheck()
                recheckResult = check
                switch check?.status {
                case .ipBanned?:
                    outcome = .stillBanned(old: oldIP, new: ip)
                case .ipOk?, .cidOk?, .cidNotApplicable?:
                    outcome = .resolved(old: oldIP, new: ip)
                default:
                    outcome = .changedUnverified(old: oldIP, new: ip, status: check?.status)
                }
            }
        } catch is CancellationError {
            outcome = .cancelled
        } catch FixStop.timeout {
            outcome = .networkTimeout
        } catch FixStop.failure(let failure) {
            outcome = .failed(failure)
        } catch {
            outcome = .failed(.commandFailed)
        }

        // 6. Her durumda arayüz açık bırakılır: hata/iptal/zaman aşımında `on` yeniden denenir.
        if isWiFi, interfaceMayBeDown || !(outcome.isSuccess || outcome.isComparison) {
            let runner = self.runner
            _ = await Task { try? await runner.run(.setAirportPower(interface, on: true)) }.value
        }
        return Result(outcome: outcome, newIP: newIP, recheck: recheckResult)
    }

    private enum FixStop: Error {
        case timeout
        case failure(FixFailure)
    }
}

private extension IPFixOutcome {
    /// Ağ yenilemesi tamamlandı ve IP karşılaştırıldı (arayüz zaten açık).
    var isComparison: Bool {
        switch self {
        case .resolved, .stillBanned, .ipUnchanged, .changedUnverified: return true
        case .networkTimeout, .failed, .cancelled: return false
        }
    }
}

// MARK: - Kilit (§17.5)

/// Aynı anda tek Düzelt; iki başlatma arası en az 60 sn.
actor BanFixLock {
    static let interval: TimeInterval = 60

    private var active = false
    private var lastStart: Date?

    func acquire(now: Date) -> Bool {
        if active { return false }
        if let lastStart, now.timeIntervalSince(lastStart) < Self.interval { return false }
        active = true
        lastStart = now
        return true
    }

    func release() {
        active = false
    }
}

// MARK: - Düzelt türü ve sınıflandırma (§17.1, §17.9.2)

enum FixKind: Sendable, Equatable {
    case ipBan
    case cidBan
    case unreachable

    /// Düzelt düğmesi yalnız `ipBanned`, `cidBanned`, `unreachable` satırlarında.
    static func forStatus(_ status: BanStatus?) -> FixKind? {
        switch status {
        case .ipBanned?: return .ipBan
        case .cidBanned?: return .cidBan
        case .unreachable?: return .unreachable
        default: return nil
        }
    }
}

enum BanClassification: Sendable, Equatable {
    case engineIP
    case engineCID
    /// `cidUnknown` + `errormsg`/`disconnect`: sunucu reddetti, tür bilinmiyor (plugin/SQL olabilir).
    case rejectedUnknownType(raw: String)
    case notBan
    case unknown

    static let unverifiedText = "Ban türü doğrulanamadı (plugin/SQL olabilir)"

    static func classify(_ check: BanCheck) -> BanClassification {
        switch check.status {
        case .ipBanned: return .engineIP
        case .cidBanned: return .engineCID
        case .unreachable: return .notBan
        case .cidUnknown:
            let raw = serverText(check.detail)
            let lower = raw.lowercased()
            return lower.hasPrefix("errormsg") || lower.hasPrefix("disconnect") ? .rejectedUnknownType(raw: raw) : .unknown
        case .ipOk, .cidOk, .cidNotApplicable, .unknown: return .unknown
        }
    }

    /// `detail` içindeki ham sunucu cevabı (`"ipOk → cidUnknown: <metin>"` → `<metin>`).
    static func serverText(_ detail: String) -> String {
        guard let range = detail.range(of: ": ") else { return "" }
        return String(detail[range.upperBound...])
    }

    /// İtiraz metnindeki kontrol türü (§17.9.1).
    var checkTypeText: String {
        switch self {
        case .engineIP: return "engine IP (getchallenge)"
        case .engineCID: return "engine CID (connect 49)"
        case .rejectedUnknownType, .notBan, .unknown: return "bilinmiyor (plugin/SQL olabilir)"
        }
    }
}

// MARK: - Sunucu sayfası ve itiraz metni (§17.3, §17.9.1, §17.9.4)

enum GameTrackerLink {
    static func url(host: String, port: Int) -> URL? {
        guard ServerAddress.parse(host) != nil, (1...65_535).contains(port) else { return nil }
        return URL(string: "https://www.gametracker.com/server_info/\(host):\(port)/")
    }
}

struct AppealInput: Sendable, Equatable {
    var serverLabel: String
    var host: String
    var port: Int
    var checkedAt: Date
    var playerName: String
    var cid: String
    var publicIP: String
    var gamedir: String
    var check: BanCheck
}

enum AppealText {
    static let adminChecklist = [
        "listid ve listip ile kaydı bulun.",
        "Motor ID banı ise: removeid <id> + writeid.",
        "Motor IP banı ise: removeip <ip> + writeip.",
        "AMXX ise: amx_unban <ip> (yalnız IP) veya ban-manager menüsü.",
        "SQL/AMXBans ise: panelden/DB'den silin.",
        "sv_filterban değerini kontrol edin.",
        "Sunucuyu yeniden başlatın, listid/listip ile doğrulayın ve oyuncuyu tekrar bağlanmaya çağırın.",
    ]

    static func make(_ input: AppealInput, timeZone: TimeZone = .current) -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "tr_TR")
        local.timeZone = timeZone
        local.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let classification = BanClassification.classify(input.check)
        let raw = input.check.detail.isEmpty ? input.check.status.rawValue : input.check.detail
        let checklist = adminChecklist.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        Merhaba, yanlışlıkla banlandım, kaldırır mısınız?

        Sunucu: \(input.serverLabel) (\(input.host):\(input.port))
        Kontrol zamanı: \(local.string(from: input.checkedAt)) (yerel) / \(utc.string(from: input.checkedAt)) (UTC)
        Oyuncu adı: \(input.playerName)
        CID (uuid): \(input.cid)
        Çıkış IP'si: \(input.publicIP)
        İstemci: Xash3D FWGS, protokol 49, gamedir \(input.gamedir)
        Sunucu cevabı: \(raw)
        Kontrol türü: \(classification.checkTypeText)

        Ban süreliyse bitiş zamanını ve gerekçesini paylaşabilir misiniz?

        Yönetici için kontrol listesi:
        \(checklist)
        """
    }
}

import Foundation
import Security

// MARK: - §68.2 Ban record (JSON endpoint)

/// Per-server ban record settings (`ServerEntry.banRecord`). The bearer token is never here: it lives in the
/// Keychain (`SecretStoring`, account = server id).
struct BanRecordConfig: Codable, Sendable, Equatable {
    /// `https` URL with `{cid}` and/or `{ip}` (the §40 placeholder rules).
    var urlTemplate: String
    var enabled: Bool

    /// Same rules as the ban list template, plus at least one of `{cid}` / `{ip}`.
    static func validate(_ template: String) -> Result<String, BanListTemplateError> {
        switch BanListTemplate.validate(template) {
        case .failure(let error): return .failure(error)
        case .success(let valid):
            let names = BanListTemplate.placeholders(in: valid)
            guard names.contains(BanListPlaceholder.cid.rawValue) || names.contains(BanListPlaceholder.ip.rawValue) else {
                return .failure(.noPlaceholder)
            }
            return .success(valid)
        }
    }
}

/// One ban of the reply (field names mapped flexibly).
struct BanRecordEntry: Sendable, Equatable {
    var reason: String?
    var admin: String?
    var created: Date?
    var expires: Date?
    var permanent: Bool
    var playerIP: String?
    var playerID: String?

    /// Permanent, or ends in the future.
    func isActive(now: Date) -> Bool {
        if permanent { return true }
        guard let expires else { return true }
        return expires > now
    }

    /// Seconds left of a timed, still active ban; `nil` for permanent or ended bans.
    func remaining(now: Date) -> TimeInterval? {
        guard !permanent, let expires, expires > now else { return nil }
        return expires.timeIntervalSince(now)
    }
}

struct BanRecordResult: Sendable, Equatable {
    /// Newest first (by `created`; undated last).
    var entries: [BanRecordEntry]
    var fetchedAt: Date

    var active: [BanRecordEntry] { entries.filter { $0.isActive(now: fetchedAt) } }
    var activeCount: Int { active.count }
    /// The newest active ban (shown on the card and in the unban message).
    var latestActive: BanRecordEntry? { active.first }
}

enum BanRecordError: Error, Sendable, Equatable {
    case invalidTemplate(BanListTemplateError)
    case keychain
    /// 401 / 403.
    case unauthorized(Int)
    case notFound
    case http(Int)
    case timeout
    case network
    case invalidJSON

    var text: String {
        switch self {
        case .invalidTemplate(let error): return BanListText.error(error)
        case .keychain: return L10n.text(.banRecordErrorKeychain)
        case .unauthorized(let code): return L10n.format(.banRecordErrorUnauthorized, String(code))
        case .notFound: return L10n.text(.banRecordErrorNotFound)
        case .http(let code): return L10n.format(.banRecordErrorHttp, String(code))
        case .timeout: return L10n.text(.banRecordErrorTimeout)
        case .network: return L10n.text(.banRecordErrorNetwork)
        case .invalidJSON: return L10n.text(.banRecordErrorJson)
        }
    }

    /// Technical `ErrorLog` text: the kind and status only, never the URL, token or body.
    var logMessage: String {
        switch self {
        case .invalidTemplate(let error): return "invalidTemplate: \(error)"
        case .keychain: return "keychain"
        case .unauthorized(let code): return "http \(code)"
        case .notFound: return "http 404"
        case .http(let code): return "http \(code)"
        case .timeout: return "timeout"
        case .network: return "network"
        case .invalidJSON: return "invalidJSON"
        }
    }
}

typealias BanRecordOutcome = Result<BanRecordResult, BanRecordError>

// MARK: Parsing

enum BanRecordParser {
    static let arrayKeys = ["bans", "data", "results"]

    /// Root array, or the first of `bans` / `data` / `results` (also one level down, e.g. `{"data":{"bans":[…]}}`).
    static func parse(_ data: Data, now: Date) -> BanRecordResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let items = array(in: json) else { return nil }
        let entries = items.compactMap { $0 as? [String: Any] }.map(entry)
        return BanRecordResult(entries: sortedNewestFirst(entries), fetchedAt: now)
    }

    static func array(in json: Any) -> [Any]? {
        if let array = json as? [Any] { return array }
        guard let object = json as? [String: Any] else { return nil }
        for key in arrayKeys {
            if let array = object[key] as? [Any] { return array }
        }
        for key in arrayKeys {
            if let nested = object[key] as? [String: Any], let array = array(in: nested) { return array }
        }
        return nil
    }

    static func sortedNewestFirst(_ entries: [BanRecordEntry]) -> [BanRecordEntry] {
        entries.enumerated().sorted { lhs, rhs in
            switch (lhs.element.created, rhs.element.created) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    static func entry(_ object: [String: Any]) -> BanRecordEntry {
        func value(_ keys: [String]) -> Any? {
            for key in keys {
                if let found = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
                   !(found is NSNull) {
                    return found
                }
            }
            return nil
        }
        let expires = value(["expires", "expiresAt", "ends"])
        let permanentFlag = bool(value(["permanent"]))
        return BanRecordEntry(reason: string(value(["reason"])),
                              admin: string(value(["admin", "adminName"])),
                              created: date(value(["created", "createdAt", "added"])),
                              expires: date(expires),
                              permanent: permanentFlag ?? (date(expires) == nil),
                              playerIP: string(value(["playerIp", "ip"])),
                              playerID: string(value(["playerId", "steamId", "cid"])))
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// ISO 8601 (with or without fractions), `yyyy-MM-dd HH:mm:ss` (UTC), Unix seconds or milliseconds (number or
    /// numeric text). `0` / negative = no date (many panels write `0` for "never ends").
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) { return epoch(number.doubleValue) }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) { return epoch(seconds) }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}

// MARK: Transport

/// HTTPS GET with an optional bearer token (fake in tests).
protocol BanRecordHTTP: Sendable {
    func get(_ url: URL, bearerToken: String?, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int)
}

/// Ephemeral `URLSession` (no cookies or cache kept).
struct URLSessionBanRecordHTTP: BanRecordHTTP {
    init() {}

    func get(_ url: URL, bearerToken: String?, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Default when nothing is injected (tests): every request fails as a network error.
struct UnavailableBanRecordHTTP: BanRecordHTTP {
    init() {}

    func get(_ url: URL, bearerToken: String?, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        throw URLError(.notConnectedToInternet)
    }
}

struct BanRecordClient: Sendable {
    static let timeout: TimeInterval = 10

    let http: any BanRecordHTTP

    func fetch(_ url: URL, bearerToken: String?, now: Date) async -> BanRecordOutcome {
        guard url.scheme?.lowercased() == "https" else { return .failure(.invalidTemplate(.notHTTPS)) }
        let response: (data: Data, statusCode: Int)
        do {
            response = try await http.get(url, bearerToken: bearerToken, timeout: Self.timeout)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.network)
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: return .failure(.unauthorized(response.statusCode))
        case 404: return .failure(.notFound)
        default: return .failure(.http(response.statusCode))
        }
        guard let result = BanRecordParser.parse(response.data, now: now) else { return .failure(.invalidJSON) }
        return .success(result)
    }
}

// MARK: Texts

enum BanRecordText {
    /// `2d 3h`, `45m`: the largest two units.
    static func remaining(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: L10n.currentLanguage.rawValue)
        formatter.calendar = calendar
        return formatter.string(from: max(60, seconds)) ?? "\(Int(seconds / 60)) min"
    }

    /// Medium date + short time in the app language.
    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.currentLanguage.rawValue)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Card lines of the newest active ban: reason, admin, start, time left or permanent.
    static func details(_ entry: BanRecordEntry, now: Date, includeStart: Bool = true) -> [String] {
        var lines: [String] = []
        if let reason = entry.reason { lines.append(L10n.format(.banRecordReason, reason)) }
        if let admin = entry.admin { lines.append(L10n.format(.banRecordAdmin, admin)) }
        if includeStart, let created = entry.created { lines.append(L10n.format(.banRecordCreated, date(created))) }
        if entry.permanent {
            lines.append(L10n.text(.banRecordPermanent))
        } else if let left = entry.remaining(now: now) {
            lines.append(L10n.format(.banRecordRemaining, remaining(left)))
        }
        return lines
    }

    /// Extra line of the unban message: reason + admin + time left (or permanent).
    static func appealLine(_ result: BanRecordResult) -> String? {
        guard let entry = result.latestActive else { return nil }
        let parts = details(entry, now: result.fetchedAt, includeStart: false)
        return parts.isEmpty ? nil : L10n.format(.appealBanRecord, parts.joined(separator: "; "))
    }

    /// Report line (§68.2 privacy): only the count, never the token, URL or body.
    static func reportLine(_ outcome: BanRecordOutcome) -> String {
        switch outcome {
        case .success(let result): return L10n.format(.banRecordReport, String(result.activeCount))
        case .failure: return L10n.text(.banRecordReportUnavailable)
        }
    }
}

// MARK: - Keychain

/// Secret storage (Keychain in the app, in memory in tests); `nil` removes the secret.
protocol SecretStoring: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String?, for account: String) throws
}

enum SecretStoreError: Error, Sendable, Equatable {
    case status(Int32)
}

/// Generic password items of one service.
struct KeychainSecretStore: SecretStoring {
    static let banRecordService = "tr.ercanatay.playeridentity.banrecord"

    let service: String

    init(service: String = KeychainSecretStore.banRecordService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func secret(for account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String?, for account: String) throws {
        let base = query(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.status(status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.status(update) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.status(status) }
    }
}

/// In-memory store (default when nothing is injected; never touches the Keychain).
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func secret(for account: String) throws -> String? { lock.withLock { values[account] } }

    func setSecret(_ value: String?, for account: String) throws {
        lock.withLock {
            if let value, !value.isEmpty { values[account] = value } else { values[account] = nil }
        }
    }
}

/// One prepared lookup (URL filled in, token read): runs off the main actor.
struct BanRecordLookup: Sendable {
    let url: URL
    let bearerToken: String?
    let client: BanRecordClient
    let now: @Sendable () -> Date

    func run() async -> BanRecordOutcome {
        await client.fetch(url, bearerToken: bearerToken, now: now())
    }
}

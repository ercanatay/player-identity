import Foundation

/// Overall / row status (§7). Ordering: green < orange < red.
enum StatusLevel: Int, Sendable, Comparable, CaseIterable {
    case green = 0
    case orange = 1
    case red = 2

    static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// §7.4 SF Symbol name.
    var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .orange: return "exclamationmark.triangle.fill"
        case .red: return "xmark.octagon.fill"
        }
    }

    /// §7.4 label.
    var label: String {
        switch self {
        case .green: return "Tümü tamam"
        case .orange: return "Dikkat"
        case .red: return "Kritik hata"
        }
    }
}

/// Message codes and texts (§10 verbatim). `lanIPMissing`, `nameEmpty`, `modelEmpty` exist as conditions
/// in §7.2 but have no text in §10; their texts are derived from the §7.2 wording.
enum MessageCode: String, Sendable, CaseIterable {
    case identityMissing
    case identityInvalid
    case publicIPFailed
    case snapshotMissing
    case snapshotCorrupt
    case rawIDZero
    case nameChanged
    case modelChanged
    case publicIPChanged
    case lanIPChanged
    case serverCIDChanged
    case invalidHost
    case lanIPMissing
    case nameEmpty
    case modelEmpty
    // §13.5
    case ipBanned
    case cidBanned
    case unreachable
    case banUnknown
    case cidNotApplicable

    var text: String {
        switch self {
        case .identityMissing: return "Kimlik dosyası bulunamadı. Oyun bir kez açıldıktan sonra tekrar deneyin."
        case .identityInvalid: return "Kimlik dosyası geçersiz: 16 karakterlik hex bekleniyordu."
        case .publicIPFailed: return "Genel IP alınamadı. İnternet bağlantısını kontrol edin."
        case .snapshotMissing: return "Kayıt yok. Doğrulama için Kaydet'e basın."
        case .snapshotCorrupt: return "Kayıt dosyası okunamadı; yeni kayıt oluşturabilirsiniz."
        case .rawIDZero: return "Kimlik donanımdan türetilmemiş (paylaşımlı kimlik)."
        case .nameChanged: return "Kullanıcı adı kayıttan farklı."
        case .modelChanged: return "Oyuncu modeli kayıttan farklı."
        case .publicIPChanged: return "Genel IP kayıttan farklı."
        case .lanIPChanged: return "Yerel IP listesi kayıttan farklı."
        case .serverCIDChanged: return "Sunucu CID'si kayıttan farklı."
        case .invalidHost: return "Sunucu adresi geçersiz."
        case .lanIPMissing: return "Yerel IP bulunamadı."
        case .nameEmpty: return "Kullanıcı adı boş."
        case .modelEmpty: return "Oyuncu modeli boş."
        case .ipBanned: return "Sunucu bu IP'yi banlamış."
        case .cidBanned: return "Sunucu bu CID'yi banlamış."
        case .unreachable: return "Sunucuya erişilemedi (yanıt yok)."
        case .banUnknown: return "Ban durumu belirlenemedi."
        case .cidNotApplicable: return "CID kontrolü bu sunucuda uygulanamaz."
        }
    }
}

struct StatusReason: Sendable, Equatable {
    let severity: StatusLevel
    let code: MessageCode

    var message: String { code.text }
}

struct ServerRowStatus: Sendable, Equatable {
    let id: UUID
    let level: StatusLevel
    /// CID computed from the current raw identity and host; `nil` if the host is invalid or there is no identity.
    let currentCID: String?
    /// Row reason (`invalidHost` / `serverCIDChanged`); `nil` when green.
    let message: MessageCode?
    /// §13.3 ban column; `nil` if no check was made.
    var ban: BanCheck? = nil

    /// Row icon: the worst of the CID/host status and the ban status (§7.4, §13.3).
    var displayLevel: StatusLevel {
        max(level, ban?.status.level ?? .green)
    }

    /// Tooltip text of the row icon: the reason of the dominant status.
    var displayMessage: MessageCode? {
        if let ban, ban.status.level > level, let code = ban.status.messageCode { return code }
        return message
    }
}

struct StatusReport: Sendable, Equatable {
    let overall: StatusLevel
    let reasons: [StatusReason]
    let servers: [ServerRowStatus]

    func server(_ id: UUID) -> ServerRowStatus? {
        servers.first { $0.id == id }
    }
}

/// Current data after a refresh (input of the status evaluation).
struct CurrentState: Sendable, Equatable {
    var identity: Result<Identity, IdentityError>
    var displayName: String
    var model: String
    /// In `LocalAddress.display` format.
    var lanIPs: [String]
    /// `nil` = primary and fallback failed.
    var publicIP: String?
    /// Server rows in user order.
    var servers: [ServerEntry]
}

/// §7 status matrix. Pure function; no network or file access.
enum StatusEvaluator {
    static func evaluate(current: CurrentState, snapshot: SnapshotLoadResult) -> StatusReport {
        var reasons: [StatusReason] = []
        func add(_ severity: StatusLevel, _ code: MessageCode) {
            reasons.append(StatusReason(severity: severity, code: code))
        }

        // §7.1 critical
        var rawID: UInt64?
        switch current.identity {
        case .failure(.missing): add(.red, .identityMissing)
        case .failure(.invalid): add(.red, .identityInvalid)
        case .success(let identity): rawID = identity.rawID
        }
        if current.publicIP == nil { add(.red, .publicIPFailed) }

        let saved: Snapshot?
        switch snapshot {
        case .missing:
            add(.orange, .snapshotMissing)
            saved = nil
        case .corrupt, .unsupportedSchema:
            add(.red, .snapshotCorrupt)
            saved = nil
        case .loaded(let value):
            saved = value
        }

        // §7.2 non-critical
        if rawID == 0 { add(.orange, .rawIDZero) }

        if current.displayName.isEmpty { add(.orange, .nameEmpty) }
        if let saved, current.displayName != saved.displayName { add(.orange, .nameChanged) }

        if current.model.isEmpty { add(.orange, .modelEmpty) }
        if let saved, current.model != saved.model { add(.orange, .modelChanged) }

        if let ip = current.publicIP, let saved, ip != saved.network.publicIP { add(.orange, .publicIPChanged) }

        if current.lanIPs.isEmpty { add(.orange, .lanIPMissing) }
        if let saved, current.lanIPs.sorted() != saved.network.lanIPs.sorted() { add(.orange, .lanIPChanged) }

        let rows = current.servers.map { serverRow($0, rawID: rawID, saved: saved) }
        if rows.contains(where: { $0.message == .serverCIDChanged }) { add(.orange, .serverCIDChanged) }

        // §13.3 ban results: ban → red; unreachable/unknown → orange (each code once).
        for status in rows.compactMap(\.ban?.status) where status.level != .green {
            guard let code = status.messageCode, !reasons.contains(where: { $0.code == code }) else { continue }
            add(status.level, code)
        }

        let overall = reasons.map(\.severity).max() ?? .green
        return StatusReport(overall: overall, reasons: reasons, servers: rows)
    }

    /// §7.4 row status: invalid host → red (does not affect the overall status), CID differs from record/saved CID empty → orange, equal → green.
    static func serverRow(_ entry: ServerEntry, rawID: UInt64?, saved: Snapshot?) -> ServerRowStatus {
        guard let address = ServerAddress.parse(entry.host) else {
            return ServerRowStatus(id: entry.id, level: .red, currentCID: nil, message: .invalidHost, ban: nil)
        }
        let currentCID = rawID.map { CIDCalculator.cid(rawID: $0, address: address) }
        let savedCID = saved?.servers.first(where: { $0.id == entry.id })?.cid ?? ""
        if let currentCID, !savedCID.isEmpty, currentCID == savedCID {
            return ServerRowStatus(id: entry.id, level: .green, currentCID: currentCID, message: nil, ban: entry.banCheck)
        }
        return ServerRowStatus(id: entry.id, level: .orange, currentCID: currentCID, message: .serverCIDChanged,
                               ban: entry.banCheck)
    }
}

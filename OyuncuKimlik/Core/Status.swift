import Foundation

/// Genel / satır durumu (§7). Sıralama: green < orange < red.
enum StatusLevel: Int, Sendable, Comparable, CaseIterable {
    case green = 0
    case orange = 1
    case red = 2

    static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// §7.4 SF Symbol adı.
    var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .orange: return "exclamationmark.triangle.fill"
        case .red: return "xmark.octagon.fill"
        }
    }

    /// §7.4 etiket.
    var label: String {
        switch self {
        case .green: return "Tümü tamam"
        case .orange: return "Dikkat"
        case .red: return "Kritik hata"
        }
    }
}

/// Mesaj kodları ve metinleri (§10 birebir). `lanIPMissing`, `nameEmpty`, `modelEmpty` §7.2'de
/// koşul olarak var ama §10'da metni yok; metinleri §7.2 ifadesinden türetildi.
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
    /// Şu anki ham kimlik ve host ile hesaplanan CID; host geçersizse veya kimlik yoksa `nil`.
    let currentCID: String?
    /// Satır gerekçesi (`invalidHost` / `serverCIDChanged`); yeşilse `nil`.
    let message: MessageCode?
    /// §13.3 ban kolonu; kontrol yapılmadıysa `nil`.
    var ban: BanCheck? = nil

    /// Satır ikonu: CID/host durumu ile ban durumunun en kötüsü (§7.4, §13.3).
    var displayLevel: StatusLevel {
        max(level, ban?.status.level ?? .green)
    }

    /// Satır ikonunun ipucu metni: baskın durumun gerekçesi.
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

/// Yenileme sonrası mevcut veriler (durum hesabının girdisi).
struct CurrentState: Sendable, Equatable {
    var identity: Result<Identity, IdentityError>
    var displayName: String
    var model: String
    /// `LocalAddress.display` biçiminde.
    var lanIPs: [String]
    /// `nil` = birincil ve yedek başarısız.
    var publicIP: String?
    /// Kullanıcı sırasıyla sunucu satırları.
    var servers: [ServerEntry]
}

/// §7 durum matrisi. Saf fonksiyon; ağ veya dosya erişimi yok.
enum StatusEvaluator {
    static func evaluate(current: CurrentState, snapshot: SnapshotLoadResult) -> StatusReport {
        var reasons: [StatusReason] = []
        func add(_ severity: StatusLevel, _ code: MessageCode) {
            reasons.append(StatusReason(severity: severity, code: code))
        }

        // §7.1 kritik
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

        // §7.2 kritik değil
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

        // §13.3 ban sonuçları: ban → kırmızı; erişilemiyor/belirsiz → turuncu (her kod bir kez).
        for status in rows.compactMap(\.ban?.status) where status.level != .green {
            guard let code = status.messageCode, !reasons.contains(where: { $0.code == code }) else { continue }
            add(status.level, code)
        }

        let overall = reasons.map(\.severity).max() ?? .green
        return StatusReport(overall: overall, reasons: reasons, servers: rows)
    }

    /// §7.4 satır durumu: host geçersiz → kırmızı (genel durumu bozmaz), CID kayıttan farklı/kayıtlı CID boş → turuncu, eşit → yeşil.
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

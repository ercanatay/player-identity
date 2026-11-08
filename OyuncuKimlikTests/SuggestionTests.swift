import XCTest
@testable import OyuncuKimlik

/// §14.4: öneri metinleri ve "Ne yapmalı?" metin üretimi.
final class SuggestionTests: XCTestCase {
    /// §14.3 tablosu, birebir.
    static let table: [MessageCode: String] = [
        .ipBanned: "IP'nizi değiştirin: modemi/routerı 5 dakika kapatıp açın; IP değişmezse VPN kullanın. Ban süreli olabilir, birkaç saat sonra tekrar deneyin. Kalıcıysa sunucu yöneticisinden kaldırmasını isteyin.",
        .cidBanned: "IP değiştirmek yetmez, bu CID (authid) engelli. Sunucu yöneticisinden kaldırmasını isteyin. Bu kimlik bu makinede paylaşımlı üretildiği için başka bir istemcinin banı da size yansıyabilir.",
        .unreachable: "Sunucu kapalı olabilir veya UDP erişimi engellenmiştir. GameTracker sayfasından sunucunun canlı olduğunu doğrulayın; güvenlik duvarı/VPN'yi kontrol edin.",
        .banUnknown: "Sunucu bu tür sorgulara yanıt vermiyor olabilir. Birkaç dakika sonra Yenile'ye basın; sorun sürerse sunucu yöneticisine danışın.",
        .cidNotApplicable: "Bu sunucu eski oyun protokolünü kullanıyor; CID banı burada test edilemez. IP ban sonucu geçerlidir.",
        .identityMissing: "Oyunu bir kez başlatıp kapatın; kimlik dosyası otomatik oluşur, sonra Yenile'ye basın.",
        .identityInvalid: "Kimlik dosyası bozulmuş. Dosyayı silin, oyunu bir kez açıp kapatın; yeniden oluşturulur.",
        .publicIPFailed: "İnternet bağlantısını kontrol edin. VPN/güvenlik duvarı bu isteği engelliyor olabilir.",
        .snapshotMissing: "Doğrulama yapılabilmesi için Kaydet'e basarak referans kaydı oluşturun.",
        .snapshotCorrupt: "Kayıt dosyası okunamıyor. Kaydet'e basarak yeni kayıt oluşturun.",
        .rawIDZero: "Bu sürümde beklenen durum: kimlik donanımdan üretilmiyor. Ban riski taşır, çünkü aynı CID tüm benzer kurulumlarda geçerli.",
        .nameChanged: "Oyundaki isim değişmiş. Bilinçli yaptıysanız Kaydet'e basın, aksi hâlde oyun ayarlarını kontrol edin.",
        .modelChanged: "Oyuncu modeli değişmiş. Bilinçli yaptıysanız Kaydet'e basın.",
        .publicIPChanged: "IP'niz değişmiş (dinamik IP'de normal). Doğru değer buysa Kaydet'e basın.",
        .lanIPChanged: "Yerel ağ değişmiş (Wi-Fi/Ethernet geçişi olabilir). Bilinçliyse Kaydet'e basın.",
        .serverCIDChanged: "Sunucu CID'si kayıttan farklı; kimlik kaynağı değişmiş olabilir. Yenile'den sonra Kaydet'e basın.",
        .invalidHost: "Adresi IP:port biçiminde girin (örn. 51.68.190.91:27015).",
    ]

    func testEveryCodeHasNonEmptySuggestion() {
        XCTAssertEqual(MessageCode.allCases.count, 20)
        for code in MessageCode.allCases {
            XCTAssertFalse(code.suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(code)")
            XCTAssertNotEqual(code.suggestion, code.text, "\(code) önerisi mesajın tekrarı olmamalı")
        }
    }

    func testTableTextsMatchSpecExactly() {
        XCTAssertEqual(Self.table.count, 17)
        for (code, expected) in Self.table {
            XCTAssertEqual(code.suggestion, expected, "\(code)")
        }
    }

    func testCodesOutsideSpecTableAreOnlyDerivedOnes() {
        let outside = Set(MessageCode.allCases).subtracting(Self.table.keys)
        XCTAssertEqual(outside, [.lanIPMissing, .nameEmpty, .modelEmpty])
    }

    func testSecondaryLineStartsWithArrow() {
        XCTAssertEqual(SuggestionText.secondaryLine(for: .ipBanned), "→ " + Self.table[.ipBanned]!)
        for code in MessageCode.allCases {
            XCTAssertTrue(SuggestionText.secondaryLine(for: code).hasPrefix("→ "))
        }
    }

    func testPopoverListIsNumberedInReasonOrder() {
        let reasons = [StatusReason(severity: .orange, code: .rawIDZero),
                       StatusReason(severity: .red, code: .ipBanned)]
        XCTAssertEqual(SuggestionText.numberedLines(for: reasons), [
            "1. " + Self.table[.rawIDZero]!,
            "2. " + Self.table[.ipBanned]!,
        ])
        XCTAssertEqual(SuggestionText.plainText(for: reasons),
                       "1. \(Self.table[.rawIDZero]!)\n2. \(Self.table[.ipBanned]!)")
        XCTAssertEqual(SuggestionText.plainText(for: []), "")
    }

    func testPopoverTextFromEvaluatedReport() throws {
        // Durum mantığı değişmeden, değerlendirilen raporun gerekçelerinden metin üretilir.
        let server = ServerEntry(label: "B", host: "51.68.190.91",
                                 banCheck: BanCheck(status: .ipBanned, checkedAt: Date(timeIntervalSince1970: 0), detail: ""))
        let current = CurrentState(identity: .failure(.missing), displayName: "A", model: "m",
                                   lanIPs: ["en0 · 10.0.0.2"], publicIP: "203.0.113.7", servers: [server])
        let report = StatusEvaluator.evaluate(current: current, snapshot: .missing)
        XCTAssertEqual(report.overall, .red)
        let text = SuggestionText.plainText(for: report.reasons)
        XCTAssertTrue(text.contains(Self.table[.ipBanned]!))
        XCTAssertTrue(text.contains(Self.table[.identityMissing]!))
        XCTAssertEqual(text.split(separator: "\n").count, report.reasons.count)
    }
}

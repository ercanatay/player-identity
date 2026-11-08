import Foundation

/// §14 "Yapılacaklar / öneriler": her gerekçe kodu için kullanıcının atabileceği adım.
/// Tek merkezi eşleme; `switch` tam kapsamlı olduğundan yeni bir kod eklenince derleme kırılır.
extension MessageCode {
    var suggestion: String {
        switch self {
        // §14.3 (birebir)
        case .ipBanned:
            return "IP'nizi değiştirin: modemi/routerı 5 dakika kapatıp açın; IP değişmezse VPN kullanın. Ban süreli olabilir, birkaç saat sonra tekrar deneyin. Kalıcıysa sunucu yöneticisinden kaldırmasını isteyin."
        case .cidBanned:
            return "IP değiştirmek yetmez, bu CID (authid) engelli. Sunucu yöneticisinden kaldırmasını isteyin. Bu kimlik bu makinede paylaşımlı üretildiği için başka bir istemcinin banı da size yansıyabilir."
        case .unreachable:
            return "Sunucu kapalı olabilir veya UDP erişimi engellenmiştir. GameTracker sayfasından sunucunun canlı olduğunu doğrulayın; güvenlik duvarı/VPN'yi kontrol edin."
        case .banUnknown:
            return "Sunucu bu tür sorgulara yanıt vermiyor olabilir. Birkaç dakika sonra Yenile'ye basın; sorun sürerse sunucu yöneticisine danışın."
        case .cidNotApplicable:
            return "Bu sunucu eski oyun protokolünü kullanıyor; CID banı burada test edilemez. IP ban sonucu geçerlidir."
        case .identityMissing:
            return "Oyunu bir kez başlatıp kapatın; kimlik dosyası otomatik oluşur, sonra Yenile'ye basın."
        case .identityInvalid:
            return "Kimlik dosyası bozulmuş. Dosyayı silin, oyunu bir kez açıp kapatın; yeniden oluşturulur."
        case .publicIPFailed:
            return "İnternet bağlantısını kontrol edin. VPN/güvenlik duvarı bu isteği engelliyor olabilir."
        case .snapshotMissing:
            return "Doğrulama yapılabilmesi için Kaydet'e basarak referans kaydı oluşturun."
        case .snapshotCorrupt:
            return "Kayıt dosyası okunamıyor. Kaydet'e basarak yeni kayıt oluşturun."
        case .rawIDZero:
            return "Bu sürümde beklenen durum: kimlik donanımdan üretilmiyor. Ban riski taşır, çünkü aynı CID tüm benzer kurulumlarda geçerli."
        case .nameChanged:
            return "Oyundaki isim değişmiş. Bilinçli yaptıysanız Kaydet'e basın, aksi hâlde oyun ayarlarını kontrol edin."
        case .modelChanged:
            return "Oyuncu modeli değişmiş. Bilinçli yaptıysanız Kaydet'e basın."
        case .publicIPChanged:
            return "IP'niz değişmiş (dinamik IP'de normal). Doğru değer buysa Kaydet'e basın."
        case .lanIPChanged:
            return "Yerel ağ değişmiş (Wi-Fi/Ethernet geçişi olabilir). Bilinçliyse Kaydet'e basın."
        case .serverCIDChanged:
            return "Sunucu CID'si kayıttan farklı; kimlik kaynağı değişmiş olabilir. Yenile'den sonra Kaydet'e basın."
        case .invalidHost:
            return "Adresi IP:port biçiminde girin (örn. 51.68.190.91:27015)."
        // §14.3'te yer almayan, §7.2 koşullarından türetilmiş kodlar (metinleri spec'te yok).
        case .lanIPMissing:
            return "Ağ bağlantısını (Wi-Fi/Ethernet) kontrol edin, sonra Yenile'ye basın."
        case .nameEmpty:
            return "Oyunda bir oyuncu adı belirleyin, oyunu kapatıp Yenile'ye basın."
        case .modelEmpty:
            return "Oyunda bir oyuncu modeli seçin, oyunu kapatıp Yenile'ye basın."
        }
    }
}

/// Öneri metinlerinin sunumu (§14.2). Saf fonksiyonlar.
enum SuggestionText {
    /// Gerekçe satırının ikincil katmanı: `→ <öneri>`.
    static func secondaryLine(for code: MessageCode) -> String {
        "→ " + code.suggestion
    }

    /// "Ne yapmalı?" popover'ının satırları: o anki gerekçelerin önerileri, sırayla numaralı.
    static func numberedLines(for reasons: [StatusReason]) -> [String] {
        reasons.enumerated().map { index, reason in "\(index + 1). \(reason.code.suggestion)" }
    }

    /// "Kopyala" ile panoya yazılan düz metin.
    static func plainText(for reasons: [StatusReason]) -> String {
        numberedLines(for: reasons).joined(separator: "\n")
    }
}

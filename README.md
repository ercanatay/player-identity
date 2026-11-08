# Oyuncu Kimlik Kartı (macOS)

Xash3D FWGS oyun istemcisinin kimlik verilerini (kullanıcı adı, oyuncu modeli, ham kimlik, genel/yerel IP,
sunucuya özel CID'ler) tek pencerede gösteren, "Kaydet" ile diske kayıt (snapshot) tutan ve "Yenile" ile
verileri yeniden okuyup kayıtla karşılaştırarak sonucu tek bir durum ikonuyla özetleyen SwiftUI uygulaması.

Uygulama **salt okunurdur**: oyun dosyalarını (`.xash_id`, `config.cfg`) değiştirmez, silmez, oluşturmaz.
Yazdığı tek dosya kendi kaydıdır.

## Gereksinimler
macOS 14+, Xcode (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen). Harici bağımlılık yok.

## Build ve test
```sh
xcodegen generate
xcodebuild -project OyuncuKimlik.xcodeproj -scheme OyuncuKimlik -destination 'platform=macOS' -derivedDataPath .build build
xcodebuild -project OyuncuKimlik.xcodeproj -scheme OyuncuKimlik -destination 'platform=macOS' -derivedDataPath .build test
```
Testler ağa ve kullanıcının gerçek dosyalarına bağımlı değildir (geçici klasör fixture'ları + sahte HTTP istemcisi).

## Çalıştırma
```sh
open .build/Build/Products/Debug/OyuncuKimlik.app
```
Ad-hoc imzalıdır; App Sandbox ve hardened runtime kapalıdır. Açılışta bir kez yenileme yapılır.

| Kısayol | İşlem |
|---|---|
| ⌘R | Yenile (yenileme sürerken basılırsa önceki iptal edilir, en son istek kazanır) |
| ⌘S | Kaydet |

## Veri kaynakları
- **Kimlik dosyası** (öncelik sırası): `~/.config/.xash_id` → `~/.local/.xash_id` → `~/.xash_id` → `<gamedir>/.xash_id`.
  İlk okunabilen ve geçerli (16 hex) dosya kullanılır.
- **İsim / model:** seçili gamedir'deki `config.cfg` (`name`, `model`).
- **Genel IP:** `https://api.ipify.org?format=json`, yedek `https://ifconfig.me/ip` (8 sn zaman aşımı).
- **Yerel IP'ler:** sistem arayüzleri; `lo0` ve `fe80::/10` hariç.
- **CID:** `MD5(ham kimlik 8 bayt küçük-endian + IPv4 4 / IPv6 16 bayt)`, 32 küçük harf hex.

## Veri kökü seçimi
Varsayılan veri kökü `~/Library/Application Support/Xash3D FWGS`. Profil kartındaki **Klasör Seç…** ile başka bir
kök seçilebilir; seçim UserDefaults'ta (`tr.ercanatay.oyuncukimlik` → `dataRoot`) ve Kaydet ile kayıtta saklanır.
Seçim değişince gamedir'ler yeniden keşfedilir ve yenileme yapılır. Gamedir, kartındaki seçiciden değiştirilir
(`valve` varsa varsayılan odur).

Not: `~/.config`, `~/.local` ve `~` altındaki kimlik dosyaları gamedir'den önce gelir; bu yüzden yalnızca veri
kökünü değiştirmek, ev dizinindeki kimlik dosyasını gizlemez.

## Kayıt dosyası
`~/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json` (JSON, `schemaVersion: 1`, atomik yazma).
- Yalnızca **Kaydet** yazar; Yenile kaydı değiştirmez.
- Kaydedilmemiş değişiklik (veri kökü, gamedir, sunucu listesi) varsa "Kaydedilmedi" rozeti görünür ve çıkışta
  "Kaydetmeden çık?" onayı sorulur.
- Dosya yoksa "kayıt yok" (turuncu); bozuksa veya şema desteklenmiyorsa kırmızı uyarı verilir, uygulama çalışmaya
  devam eder ve Kaydet yeni kayıt oluşturur.

## Renk anlamları
| Durum | İkon | Etiket | Anlam |
|---|---|---|---|
| Yeşil | `checkmark.circle.fill` | Tümü tamam | Kritik sorun yok, tüm alanlar kayıtla birebir uyumlu |
| Turuncu | `exclamationmark.triangle.fill` | Dikkat | Kritik olmayan fark/uyarı: kayıt yok, IP/isim/model farkı, ham kimlik 0, sunucu CID farkı, yerel IP yok |
| Kırmızı | `xmark.octagon.fill` | Kritik hata | Kimlik dosyası yok/geçersiz, genel IP alınamadı, kayıt okunamıyor |

Durum her zaman ikon **ve** metinle gösterilir. Gerekçeler pencerenin altında listelenir. Sunucu satırları da
aynı ikonları kullanır: host geçersizse kırmızı (genel durumu etkilemez), CID kayıttan farklıysa veya kayıtlı CID
boşsa turuncu, eşitse yeşil. Sunucu CID'si kayda, satır bir Yenile ile kontrol edildikten sonra yazılır.

## Ban kontrolü (v1.1)
Her Yenile'de, geçerli IP'li her sunucu satırı için UDP ile tek kontrol üçlüsü yapılır (yeniden deneme yok,
oyuna girilmez):
1. **A2S_INFO** — sunucu ayakta mı; yanıt yoksa "Erişilemiyor".
2. **getchallenge** — yanıtta `banned` geçiyorsa "IP ban"; challenge gelirse IP engeli yok.
3. **connect 49** (yalnız challenge alındıysa) — satırın CID'iyle el sıkışma; `client_connect` gelince hemen durur.

Adım başına 4 sn, toplam en fazla 12 sn; aynı sunucuya iki kontrol arası en az 10 sn; yenileme iptal edilince
kontrol de iptal edilir.

| Ban kolonu | Anlam | Genel duruma etkisi |
|---|---|---|
| IP ban / CID ban | Sunucu bu IP'yi / CID'yi banlamış | Kırmızı + gerekçe |
| Engel yok | IP engeli yok; CID el sıkışması başarılı veya CID kontrolü bu sunucuda uygulanamaz | — |
| Erişilemiyor / Belirsiz | Yanıt yok / sonuç belirlenemedi | Turuncu + gerekçe |

Sonuç satırın `banCheck` alanına (`status`, `checkedAt`, `detail`) yazılır ve Kaydet ile `profile.json`'a girer
(şema 1; bu alanı olmayan eski kayıtlar okunur). Satır üzerine gelince ipucunda son kontrol zamanı ve ayrıntı görünür.
**Oyuncu Kimlik > Ayarlar… > Ban kontrolü** anahtarı (varsayılan açık, UserDefaults `banCheckEnabled`) kapalıyken
hiçbir UDP paketi gönderilmez; önceki sonuçlar gösterilmeye devam eder.

## Bilinen sınırlar (V1 kapsamı dışı)
- Kimlik dosyalarını yazma/değiştirme, oyunu başlatma, oyuna girme (spawn). Ban kontrolü dışında sunucuya paket
  gönderilmez.
- Çoklu profil, iCloud senkronizasyonu, App Store dağıtımı, sandbox, otomatik güncelleme.
- IPv6 sunucu satırları için özel arayüz (CID mantığı aynıdır).
- Bildirim/uyarı zamanlayıcıları, arka planda periyodik yenileme.
- Host alanına alan adı yazılabilir ama DNS çözümlemesi yapılmaz; CID yalnızca IP adresleri için hesaplanır
  (alan adı satırı "Sunucu adresi geçersiz." olarak kırmızı görünür).

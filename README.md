# Oyuncu Kimlik Kartı (macOS)

Xash3D FWGS oyun istemcisinin kimlik verilerini (kullanıcı adı, oyuncu modeli, ham kimlik, genel/yerel IP,
sunucuya özel CID'ler) tek pencerede gösteren, "Kaydet" ile diske kayıt (snapshot) tutan ve "Yenile" ile
verileri yeniden okuyup kayıtla karşılaştırarak sonucu tek bir durum ikonuyla özetleyen SwiftUI uygulaması.

Uygulama oyun dosyalarını **değiştirmez**; tek istisna ad/model düzenlemedir: yalnız `config.cfg` ve (varsa) `userconfig.cfg` içindeki `name`/`model` satırları yazılır. Ayrıca kendi kaydını (`profile.json`) ve `*.appbak` yedeklerini oluşturur.

## Gereksinimler
macOS 14+, Xcode (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen). Harici bağımlılık yok.

## Build ve test
```sh
xcodegen generate
xcodebuild -project OyuncuKimlik.xcodeproj -scheme OyuncuKimlik -destination 'platform=macOS' -derivedDataPath .build build
xcodebuild -project OyuncuKimlik.xcodeproj -scheme OyuncuKimlik -destination 'platform=macOS' -derivedDataPath .build test
```
Testler ağa ve kullanıcının gerçek dosyalarına bağımlı değildir (geçici klasör fixture'ları + sahte HTTP istemcisi). Toplam **176** test.

## Çalıştırma
```sh
open .build/Build/Products/Debug/OyuncuKimlik.app
```
Ad-hoc imzalıdır; App Sandbox ve hardened runtime kapalıdır. Açılışta bir kez yenileme yapılır.

| Kısayol | İşlem |
|---|---|
| ⌘R | Yenile (yenileme sürerken basılırsa önceki iptal edilir, en son istek kazanır) |
| ⌘S | Kaydet |

## Özellikler (öne çıkanlar)
- Ban kontrolü (IP/CID) ve sunucu satırında **Düzelt** akışı (ayrıntı: aşağıdaki bölümler).
- Model önizleme: dropdown ve profil kartında BMP küçük resim.
- Gerekçe başına "ne yapmalı" önerileri ve panoya kopyalama.
- Ad/model dropdown'ları ve **Uygula** ile `config.cfg` / `userconfig.cfg` güncelleme.

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

## Ad ve model düzenleme (v1.3)
Uygulamanın tek yazma istisnası: seçili gamedir'deki `config.cfg` ve (varsa) `userconfig.cfg` içindeki
`name` / `model` satırları.
- **Etkin değer:** `userconfig.cfg` motor tarafından `config.cfg`'den sonra çalıştırıldığı için anahtar oradaysa
  o kazanır; profil kartında kaynak notu görünür (`config.cfg` veya `userconfig.cfg (config.cfg'yi ezer)`).
- **Dropdown'lar:** model listesi `<gamedir>/models/player/` klasör adlarından (alfabetik; listede olmayan mevcut
  model "(mevcut)" ile başta; klasör yoksa "Elle gir…"). Ad listesi: mevcut ad, kayıttaki ad, son kullanılan 10 ad
  (UserDefaults `recentNames`) ve "Yeni ad…".
- **Uygula (⌘⏎):** yalnız değişen anahtarlar yazılır; anahtar iki dosyada da varsa ikisi de aynı değere getirilir,
  hiçbirinde yoksa `config.cfg` sonuna eklenir. Anahtarın tüm geçişleri güncellenir, dosyanın geri kalanı bayt bayt
  ve satır sonu stiliyle korunur. Yazma atomiktir; her değişen dosyanın önceki hâli `<dosya>.appbak` olarak saklanır
  (oyunun `config.cfg.bak` dosyasına dokunulmaz). `xash3d` süreci açıksa yazma reddedilir ve uyarı bandı görünür.
- **Doğrulama:** ad 1–31 karakter ve ≤ 31 bayt (UTF-8), `"` `\` satır sonu ve kontrol karakteri yok; model 1–32
  karakter, yalnız `A-Z a-z 0-9 _ -`. Geçersizse Uygula devre dışıdır.
- Uygula sonrası dosyalar yeniden okunur ve kayıt "Kaydedilmedi" olur; Kaydet yeni ad/modeli `profile.json`'a yazar.

## Düzelt (v1.5)
Sunucu satırında ban ikonunun altında **Düzelt** düğmesi yalnız `IP ban`, `CID ban` ve `Erişilemiyor` durumlarında
görünür. Düzelt bir unban değildir; uygulama "çözüldü" ifadesini yalnız IP gerçekten değişip yeniden kontrol IP
engeli göstermediğinde kullanır.
- **IP ban:** onay sayfası (mevcut IP, adımlar, 5–20 sn kesinti, risk) → "Başlat" ile: eski IP alınır, varsayılan
  arayüz bulunur (`route get default`); Wi-Fi ise `networksetup -setairportpower <if> off` → 3 sn → `on`, Ethernet ise
  `ipconfig set <if> DHCP` (macOS yönetici diyaloğu). Ağ 45 sn beklenir (3 sn'de bir genel IP), yeni IP karşılaştırılır
  ve IP değiştiyse o sunucu yeniden kontrol edilir. Hata, iptal veya zaman aşımında Wi-Fi her durumda yeniden açılır.
  IP değişmezse router arayüzü/VPN/bekleme önerilir; yeni IP de banlıysa üç olası neden ve itiraz metni gösterilir.
- **CID ban:** ağ komutu yok. Açıklama, "Unban mesajını kopyala" (sunucu, saat yerel+UTC, ad, CID, çıkış IP'si,
  istemci, ham cevap, kontrol türü ve admin kontrol listesiyle itiraz metni), "Sunucu sayfasını aç" (GameTracker) ve
  "Yeniden kontrol et".
- **Erişilemiyor:** yalnız yeniden kontrol ve sunucu sayfası.
- `cidUnknown` + `errormsg`/`disconnect` cevabı satırda "Ban türü doğrulanamadı (plugin/SQL olabilir)" ve ham cevapla
  gösterilir.
- **Güvenlik:** aynı anda tek Düzelt, iki başlatma arası en az 60 sn, iptal edilebilir. Komutlar sabit bir allowlist'ten
  üretilir (arayüz adı sistem çıktısından okunur ve doğrulanır; kullanıcı girdisi komuta girmez, kabuk kullanılmaz).
  Parola yalnız macOS diyaloğunda girilir. Sunucu komutu (banid/removeid vb.) hiçbir akışta çalıştırılmaz.
  Düzelt sonrası satırın ban durumu güncellenir ve kayıt "Kaydedilmedi" olur.

## Model önizleme (v1.4)
Model dropdown'ının her satırında 20×24 küçük resim, profil kartında seçili model için 56×68 önizleme (8 pt köşe,
koyu `#1B2432` zemin, 1 px çerçeve; ipucunda kaynak dosya yolu) gösterilir.
- **Kaynak:** `<gamedir>/models/player/<model>/` içindeki ilk `.bmp` dosyası; arama dosya adı ve uzantıda büyük/küçük
  harf duyarsız, alfabetik (ör. `Robo.bmp`, `TMCM.bmp`, `gman.BMP`). Görsel yoksa veya bozuksa SF Symbol
  `person.crop.square` yer tutucusu kullanılır; hata mesajı gösterilmez.
- Görseller ImageIO ile decode edilir, oran korunur, yüksek kaliteli interpolasyonla çizilir; 3B render yoktur.
- **Önbellek:** yalnız bellekte, (gamedir, model, dosya mtime) anahtarıyla; yükleme arka planda yapılır, liste hemen
  açılır (yüklenmeyen satırda koyu boş kutu). Gamedir değişince liste ve görseller yenilenir. Dosyalar salt okunur.
- macOS 27'de menü öğesi görselleri varsayılan olarak gizlendiği için dropdown yerel `NSPopUpButton` ile kurulur ve
  öğe görselleri `preferredImageVisibility = .visible` ile açıkça gösterilir.

## Ne yapmalı? (v1.2)
Her gerekçenin altında gri, küçük bir `→ öneri` satırı görünür (kullanıcının atabileceği somut adım).
Üst bardaki durum etiketine (örn. "Kritik hata") tıklanınca **Ne yapmalı?** penceresi açılır: o anki tüm
gerekçelerin önerileri numaralı listelenir; **Kopyala** listeyi düz metin olarak panoya yazar. Gerekçe yoksa
etiket tıklanmaz. Öneri metinleri tek merkezi eşlemededir (`OyuncuKimlik/Core/Suggestions.swift`); yeni bir
gerekçe kodu eklenip önerisi yazılmazsa derleme kırılır. Durum/renk mantığı önerilerden etkilenmez.

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

<!-- Source: specs/player-identity/spec.md; run scripts/sync-spec.sh -->
# Ürün Spesifikasyonu — Cybokron Oyuncu Kimlik Kartı (macOS)

Sürüm: 5.4.7 · Tarih: 2026-11-26 · Durum: uygulanacak (v5.0 → v5.1: §73 macOS donanım kimliği sağlığı; v5.1 → v5.2: §73 bağımsız inceleme düzeltmeleri — kimlik özelliği spec v2.25.0; v5.2 → v5.3: §74 uyumlu motoru kur — uygulama 2.25.0 build 53, özellik spec'i E0–E21; v5.3 → v5.4: §75 GoldSrc 48 desteği — uygulama 2.26.0 build 54; v5.4 → v5.4.1: §75 yakalanmış paketlerle düzeltme, §75.12; v5.4.1 → v5.4.2: §75.13 null-ticket doğrulama sınırı ve motor günlüğü kanıtı, R1 yeniden tanımlandı; v5.4.2 → v5.4.3: §75.14 bağımsız inceleme düzeltmeleri; v5.4.3 → v5.4.4: §75.15 son inceleme düzeltmeleri; v5.4.4 → v5.4.5: §75.16 CID'siz yetenek denemesi, DNS kaybında günlük eşleşmesi; v5.4.5 → v5.4.6: §75.17 ikinci paket kuralı; v5.4.6 → v5.4.7: §33.1 paylaşım kartı DURUM/BAN TİPİ, politika istisnası ve uzun metin kuralı, uygulama 2.26.1 build 55)
Bu doküman **tek doğruluk kaynağıdır**. Dış bağlam, ek sözlü açıklama, üçüncü taraf kod veya analiz yoktur.
Belirsizlik varsa doküman esas alınır; dokümanda yazmayan davranış eklenmez.

---

## 1. Amaç

Kullanıcının oyun istemci kimliğine ait verileri tek ekranda gösteren, diske kayıt (snapshot) tutan,
"Yenile" ile tüm veriyi yeniden okuyup kayıtla karşılaştıran ve sonucu **tek bir durum ikonu**
(yeşil / turuncu / kırmızı) ile özetleyen macOS masaüstü uygulaması.

Uygulama **varsayılan olarak salt okunurdur**. Tek istisna §15'teki ad/model düzenlemesidir: yalnız `config.cfg` ve (varsa) `userconfig.cfg` içindeki `name`/`model` satırları değiştirilir; başka hiçbir oyun dosyası yazılmaz.

---

## 2. Terimler

| Terim | Anlam |
|---|---|
| Veri kökü | Oyunda kullanılan veri klasörü. Varsayılan: `~/Library/Application Support/Xash3D FWGS` |
| Gamedir | Veri kökü altındaki oyun klasörü (örn. `valve`, `gearbox`). İçinde `.xash_id` ve/veya `config.cfg` bulunur. |
| Kimlik dosyası | 16 karakterlik onaltılık (hex) sayı içeren dosya. Adı `.xash_id`. |
| Ham kimlik | Kimlik dosyasındaki değerin sabit maskeyle XOR'lanmış hâli (64 bit, hex). |
| CID | Sunucuya özel türetilmiş kimlik: 32 karakter küçük harf hex (MD5). |
| Snapshot | Kullanıcının "Kaydet" ile diske yazdığı JSON kayıt. |
| Kritik alan | Eksikliği/hata durumu kırmızı sonuç üreten alan (bkz. §7). |

---

## 3. Veri kaynakları (salt okuma)

### 3.1 Kimlik dosyaları — öncelik sırası
1. `~/.config/.xash_id`
2. `~/.local/.xash_id`
3. `~/.xash_id`
4. `<gamedir>/.xash_id`

İlk **okunabilen ve geçerli** dosya kullanılır. Hiçbiri yoksa/geçersizse: kritik hata → kırmızı.

Dosya biçimi: 16 karakter hex (0-9, a-f, A-F). Baş/son boşluk ve satır sonu toleranslı.
Farklı uzunluk veya hex olmayan karakter → geçersiz.

### 3.2 Ham kimlik hesabı
- Kaynak `~/.config/.xash_id`, `~/.local/.xash_id` veya `~/.xash_id` ise:
  `hamKimlik = dosyaDeğeri XOR 0x10331C2DCE4C91DB`
- Kaynak `<gamedir>/.xash_id` ise:
  `hamKimlik = dosyaDeğeri XOR 0x7FFC48FBAC1711F1`

Sonuç 16 karakter büyük harf hex olarak gösterilir (örn. `0000000000000000`).

**Uyarı kuralı:** `hamKimlik == 0` ise "kimlik donanımdan türetilmemiş / paylaşımlı" uyarısı üretilir (turuncu, kritik değil).

### 3.3 İsim ve oyuncu modeli
Seçili gamedir'in `config.cfg` dosyasından okunur. Satır biçimi: `anahtar "değer"`.
- `name` → görünen kullanıcı adı
- `model` → oyuncu (giysi) modeli adı

Kurallar: aynı anahtar birden fazla geçerse **son** geçen değer kazanır; değer içindeki boşluklar korunur;
tırnaklar kaldırılır; anahtar yoksa alan boş kabul edilir (turuncu uyarı, hata değil).

### 3.4 Gamedir keşfi
Veri kökü altındaki, içinde `.xash_id` veya `config.cfg` bulunan **birinci seviye** klasörler listelenir.
Varsayılan seçim: `valve` varsa o; yoksa ilk bulunan. Kullanıcı seçimi değiştirebilir; seçim kayda yazılır.

### 3.5 Ağ bilgileri
- **Genel IP:** `GET https://api.ipify.org?format=json` (zaman aşımı 8 sn), JSON `ip` alanı.
  Başarısızsa yedek: `GET https://ifconfig.me/ip` (düz metin). İkisi de başarısız → kritik hata (kırmızı).
- **Yerel IP'ler:** sistem arayüzlerinden toplanır; loopback (`lo0`) ve IPv6 link-local (`fe80::/10`) hariç.
  Her adres arayüz adıyla birlikte gösterilir (örn. `en0 · 192.0.2.10`). Sıra: IPv4 önce, sonra IPv6.
  Yerel IP bulunamazsa turuncu uyarı (kritik değil).

---

## 4. CID (sunucuya özel kimlik) hesabı

Girdi: 8 baytlık ham kimlik (küçük-endian byte sırası) + sunucu adresi baytları.
- IPv4 adres → 4 bayt
- IPv6 adres → 16 bayt
- "Yerel makine" satırı (IP baytı yok) → yalnızca 8 bayt

`CID = MD5(girdi).hexLower()` → 32 karakter küçük harf hex.

### 4.1 Doğrulama vektörleri (ham kimlik = 0 için, zorunlu birim testi)
| Sunucu adresi | Beklenen CID |
|---|---|
| `95.173.174.175` | `68f8c1fb2a23cb02409b8a3231487970` |
| `51.68.190.91` | `d9de0eb4419608a8423241430581e91c` |
| `5.161.189.195` | `5282a6daf7a33fe08469e453086de93c` |
| `127.0.0.1` | `e3f650e2c5f1293838ba8e934ba3b796` |
| Yerel makine (IP baytı yok) | `7dea362b3fac8e00956a4952a3d4f474` |

Bu tablo testlerde birebir doğrulanır. Geçersiz IP metni → o satır için hata (satır kırmızı), genel durumu bozmaz.

---

## 5. Snapshot (kayıt) modeli

Konum: `~/Library/Application Support/tr.ercanatay.playeridentity/profile.json`
Yazma: atomik (geçici dosya + `replaceItemAt`). Dosya yoksa/bozuksa uygulama çökmez; "kayıt yok" durumuna geçer.

```json
{
  "schemaVersion": 1,
  "savedAt": "2026-11-08T11:21:00Z",
  "gamedir": "valve",
  "dataRoot": "/Users/<user>/Library/Application Support/Xash3D FWGS",
  "displayName": "…",
  "model": "…",
  "rawID": "0000000000000000",
  "identitySource": "/Users/<user>/.config/.xash_id",
  "network": { "publicIP": "…", "lanIPs": ["en0 · 192.0.2.10"], "checkedAt": "…" },
  "servers": [
    { "id": "UUID", "label": "…", "host": "…", "port": 27015, "cid": "…", "lastCheckedAt": "…" }
  ]
}
```

Kurallar:
- `servers` sırası kullanıcı sırasıdır (drag ile değiştirilebilir; V1'de zorunlu değil).
- Yeni sunucu eklenince `cid` boş kaydedilir.
- **Yenile snapshot'ı otomatik güncellemez.** Yalnızca "Kaydet" yazar.
- Kaydedilmemiş değişiklik varsa arayüzde "Kaydedilmedi" rozeti görünür.

---

## 6. Yenile (Refresh) akışı

`⌘R` veya "Yenile" düğmesi. Sıra:
1. Veri kökünü ve seçili gamedir'i doğrula; kimlik dosyasını öncelik sırasına göre oku → ham kimlik.
2. `config.cfg`'den `name` ve `model` oku.
3. Yerel IP listesini topla.
4. Genel IP'yi çek (birincil → yedek).
5. Her sunucu satırı için CID hesapla.
6. Snapshot ile karşılaştır, satır ve genel durumu hesapla (§7).

Davranış:
- Adımlar birbirinden bağımsızdır; biri hata verirse diğerleri devam eder (kısmi sonuç gösterilir).
- Tüm işlem tek "yenileme" nesli (generation) altında çalışır; kullanıcı yenileme sırasında tekrar basarsa önceki iptal edilir, en son istek kazanır.
- Yenileme sırasında düğme spinner gösterir ve devre dışıdır; pencere kapanmıyor, UI donmuyor (async).
- Toplam süre hedefi: tipik < 3 sn, ağ zaman aşımı 8 sn.
- Yenileme sonunda "Son kontrol: HH:mm:ss" güncellenir.
- Hata mesajları Türkçe, kısa ve eyleme dönük (bkz. §10).

---

## 7. Durum ve renk kuralları

Tek bir genel durum vardır: `green` | `orange` | `red`. Ayrıca gerekçe listesi (`reasons: [{severity, message}]`) gösterilir.

### 7.1 Kritik (kırmızı) — herhangi biri varsa genel durum `red`
- Kimlik dosyası bulunamadı veya okunamadı.
- Kimlik dosyası içeriği geçersiz (16 hex değil).
- Ham kimlik hesaplanamadı.
- Genel IP alınamadı (birincil + yedek başarısız).
- Snapshot dosyası var ama okunamıyor/şema desteklenmiyor (uyarı olarak kırmızı; uygulama çalışmaya devam eder).

### 7.2 Kritik değil (turuncu) — kırmızı yoksa ve en az biri varsa `orange`
- Snapshot yok (ilk çalıştırma) → "Kayıt yok, doğrulama yapılamıyor. Kaydet'e basın."
- Genel IP kayıttakinden farklı.
- Yerel IP listesi kayıttan farklı (eklenen/çıkan/değişen).
- Kullanıcı adı kayıttan farklı veya boş.
- Oyuncu modeli kayıttan farklı veya boş.
- `hamKimlik == 0` (paylaşımlı/donanımsız kimlik).
- Bir veya daha fazla sunucu satırında CID kayıtlı CID'den farklı veya kayıtlı CID boş.
- Yerel IP bulunamadı.

### 7.3 Yeşil
Kırmızı ve turuncu gerekçe yoksa: kritikler tamam, tüm alanlar kayıtla birebir uyumlu.

### 7.4 İkon ve metin (renk tek başına anlam taşımaz)
| Durum | SF Symbol | Renk | Etiket |
|---|---|---|---|
| green | `checkmark.circle.fill` | `.green` | "Tümü tamam" |
| orange | `exclamationmark.triangle.fill` | `.orange` | "Dikkat" |
| red | `xmark.octagon.fill` | `.red` | "Kritik hata" |

Satır bazlı durum: her sunucu satırında küçük aynı ikon seti; sunucu satırı `host` geçersizse kırmızı, CID kayıttan farklıysa turuncu, eşitse yeşil.

---

## 8. Arayüz (tek pencere, SwiftUI)

Minimum pencere: 720×520. Yerleşim dikey:

1. **Üst bar:** durum ikonu + etiket + "Son kontrol" zamanı; sağda `Yenile` (⌘R), `Kaydet` (⌘S).
2. **Profil kartı:** Kullanıcı adı, Oyuncu modeli, Ham kimlik (monospace), Kimlik kaynağı (dosya yolu, kısaltılmış + tooltip), Gamedir seçici (Picker).
3. **Ağ kartı:** Genel IP (büyük, kopyalanabilir), Yerel IP'ler listesi.
4. **Sunucular:** tablo benzeri liste. Kolonlar: Durum ikonu · Etiket · `host:port` · CID (monospace, tıklayınca kopyala + "Kopyalandı" geri bildirimi). Satır altında ikincil metin olarak son kontrol zamanı.
   - Altında "Sunucu Ekle" düğmesi → sheet: Etiket, Host (IP veya alan adı), Port (varsayılan 27015).
   - Her satırda silme (sağ tık → Sil, ve satır üzerine gelince − düğmesi).
5. **Gerekçe listesi:** varsa turuncu/kırmızı maddeler, ikon + metin olarak alt bölümde.

Ek davranışlar:
- Boş durumlar: sunucu yoksa "Henüz sunucu eklenmedi" + ekle düğmesi.
- Kopyalama sistem panosuna yapılır.
- Değişiklik yapıldığında (host/port/etiket/gamedir) durum **anında** yeniden hesaplanır (ağ isteği olmadan, mevcut verilerle).
- Uygulama kapanırken kaydedilmemiş değişiklik varsa onay sorulur ("Kaydetmeden çık?").
- Türkçe arayüz; sayı/tarih biçimi sistem yereline uyar, saat `HH:mm:ss`.

---

## 9. Teknik kısıtlar

- macOS 14.0+ hedefi, Swift 6, SwiftUI (AppKit yalnızca gerektiğinde), harici bağımlılık yok.
- Kripto: `CryptoKit` (`Insecure.MD5`). Ağ: `URLSession` async/await. Arayüz listesi: `getifaddrs`.
- Proje: `xcodegen` ile üretilen Xcode projesi (bu makinede kurulu), 2 hedef:
  - `OyuncuKimlik` (application, bundle id `tr.ercanatay.playeridentity`)
  - `OyuncuKimlikTests` (bundle.unit-test, application hedefe bağımlı)
- Ad-hoc imza (`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`), App Sandbox **kapalı**, hardened runtime kapalı.
- Tüm saf mantık (`kimlik okuma/hesap`, `config ayrıştırma`, `durum matrisi`, `snapshot kodlama`) UI'dan ayrı, test edilebilir tiplerde olacak (protocol/DI ile dosya ve ağ erişimi enjekte edilebilir).
- Testler ağa ve kullanıcının gerçek dosyalarına bağımlı olmayacak: geçici klasör fixture'ları + sahte ağ istemcisi kullanılacak.
- Proje dizini: `~/Documents/GitHub/player-identity`
- `git init` + tek ilk commit serbest; push yok.

---

## 10. Hata mesajları (birebir kullanılacak metinler)

| Kod | Metin |
|---|---|
| identityMissing | "Kimlik dosyası bulunamadı. Oyun bir kez açıldıktan sonra tekrar deneyin." |
| identityInvalid | "Kimlik dosyası geçersiz: 16 karakterlik hex bekleniyordu." |
| publicIPFailed | "Genel IP alınamadı. İnternet bağlantısını kontrol edin." |
| snapshotMissing | "Kayıt yok. Doğrulama için Kaydet'e basın." |
| snapshotCorrupt | "Kayıt dosyası okunamadı; yeni kayıt oluşturabilirsiniz." |
| rawIDZero | "Kimlik donanımdan türetilmemiş (paylaşımlı kimlik)." |
| nameChanged | "Kullanıcı adı kayıttan farklı." |
| modelChanged | "Oyuncu modeli kayıttan farklı." |
| publicIPChanged | "Genel IP kayıttan farklı." |
| lanIPChanged | "Yerel IP listesi kayıttan farklı." |
| serverCIDChanged | "Sunucu CID'si kayıttan farklı." |
| invalidHost | "Sunucu adresi geçersiz." |

---

## 11. Kabul kriterleri

1. `xcodegen generate && xcodebuild -scheme OyuncuKimlik -destination 'platform=macOS' build` → **BUILD SUCCEEDED**.
2. `xcodebuild test -scheme OyuncuKimlik -destination 'platform=macOS'` → **TEST SUCCEEDED**; §4.1 tablosundaki 5 vektör birebir doğrulanır.
3. Birim testleri: kimlik öncelik sırası, maskeler, geçersiz dosya, config ayrıştırma (yinelenen anahtar, boşluklu değer, eksik anahtar), durum matrisi (yeşil/turuncu/kırmızı örnekleri), snapshot roundtrip + bozuk JSON, IPv6 CID biçimi (32 hex).
4. Uygulama açılır, gerçek veri köküyle Yenile → yeşil/turuncu/kırmızıdan biri görünür; gerekçe listesi doğru.
5. `hamKimlik=0` durumunda turuncu + `rawIDZero` gerekçesi görünür (bu makinede beklenen durum).
6. Kaydet → `profile.json` oluşur; uygulamayı kapatıp açınca değerler yüklenir; kayıtla eşleşiyorsa yeşil.
7. Genel IP değişimi simüle edilirse (snapshot'taki IP elle değiştirilip yeniden açılarak) turuncu + `publicIPChanged` görünür.
8. Kimlik dosyası geçici olarak görünmez yapıldığında (veri kökü fixture'a çevrilerek) kırmızı + `identityMissing` görünür.
9. Yenileme sırasında UI donmaz; ikinci Yenile isteği öncekini iptal eder.
10. Ağ isteği başarısızken (offline simülasyonu, sahte istemci) uygulama çökmez, kırmızı + `publicIPFailed` gösterir.
11. Hiçbir oyun dosyası yazılmaz/değiştirilmez (yalnızca `profile.json` yazılır).
12. Arayüz Türkçe; durum ikonu SF Symbol + metin ile birlikte gösterilir.

---

## 12. V1 kapsamı dışı

- Kimlik dosyalarını yazma/değiştirme, oyunu başlatma, oyuna gerçekten girme (spawn). §13'teki ban testi dışında sunucuya paket gönderilmez.
- Çoklu profil, iCloud senkronizasyonu, App Store dağıtımı, sandbox, otomatik güncelleme.
- IPv6 sunucu satırlarında özel arayüz (aynı CID mantığı geçerli).
- Bildirim/uyarı zamanlayıcıları, arka planda periyodik yenileme.


---

## 13. Ban kontrolü (v1.1)

### 13.1 Amaç ve kapsam
Her sunucu satırı için, o sunucunun **bu makinenin IP'sini** veya **bu makinenin CID'sini** engelleyip engellemediği belirlenir.
Kontroller UDP üzerinden yapılır; oyuna girilmez (spawn paketi gönderilmez).

Güvenlik/kota kuralları (zorunlu):
- Sunucu başına bir yenilemede **tek** kontrol üçlüsü; otomatik yeniden deneme yok.
- Aynı sunucuya iki kontrol arası en az **10 saniye**.
- Her adımda zaman aşımı **4 saniye**; toplam kontrol en fazla 12 saniye.
- CID testi başarılı el sıkışmadan sonra **hemen durur** (spawn yok, ek paket yok).
- Tüm kontrol iptal edilebilir (yenileme iptali ile birlikte).
- Ayarlar > "Ban kontrolü" anahtarı (varsayılan **açık**). Kapalıysa hiçbir ban paketi gönderilmez.

### 13.2 Kontrol adımları (sırayla)
**(a) Sunucu ayakta mı — A2S_INFO**
Gönder: `FF FF FF FF` + `TSource Engine Query` + `00`
- Yanıt tipi `0x6D` (GoldSrc info) veya `0x49` (Source info) → **ayakta**
- Yanıt tipi `0x41` (challenge) → aynı paketi 4 baytlık little-endian challenge ile tekrar gönder
- 4 sn içinde yanıt yok → `unreachable` (diğer adımlar atlanır)

**(b) IP ban — getchallenge**
Gönder: `FF FF FF FF` + `getchallenge` + `\n`
- Yanıt gövdesi (4 bayt başlık + 1 bayt tip sonrası metin), küçük/büyük harf duyarsız `banned` içeriyorsa → **`ipBanned`**
- Yanıt tipi `0x41` (challenge) → **`ipOk`**; challenge değeri (4 bayt little-endian) (c) için saklanır
- Yanıt yok veya tanınmayan yanıt → `unknown`

**(c) CID ban — connect el sıkışması (yalnız challenge alındıysa)**
Gönder: `FF FF FF FF` + `connect 49 <challenge> "<protinfo>" "<userinfo>"` + `\n`
- `protinfo`: `prot=cidtest; uuid=<satırın CID'i>; qport=<1..65535 rastgele>; ext=0; d=1`
- `userinfo`: `name=<profildeki görünen ad>`
- Yanıt `client_connect` (`0x42`) → **`cidOk`**, hemen dur
- Yanıt `errormsg` / `disconnect` / `0x39` ve metinde `ban` → **`cidBanned`**
- Metinde `unsupported protocol` / `protocol` → **`cidNotApplicable`** (sunucu modern protokolü desteklemiyor)
- Yanıt yok → `cidUnknown`

### 13.3 Sonuç modeli ve gösterim
Satır durumu (öncelik sırası):
| Koşul | Gösterim |
|---|---|
| `ipBanned` | 🔴 "IP ban" |
| `cidBanned` | 🔴 "CID ban" |
| `cidOk` (veya `cidNotApplicable`) ve `ipOk` | 🟢 "Engel yok" |
| `unreachable` | ⚪ "Erişilemiyor" |
| `unknown` / `cidUnknown` | ⚪ "Belirsiz" |

- Herhangi bir `banned` sonucu **genel durumu kırmızı** yapar ve gerekçe listesine eklenir.
- `unreachable`/`unknown` genel durumu turuncu yapar (kritik değil).
- Ban kolonu ikon + metinle gösterilir; satıra gelince son kontrol zamanı tooltip'te.

### 13.4 Saklama
`ServerEntry`'ye **opsiyonel** `banCheck` alanı eklenir (şema 1 geriye uyumlu):
```json
"banCheck": { "status": "ipOk", "checkedAt": "…", "detail": "" }
```
Eski kayıtlar bu alan olmadan da okunur.

### 13.5 Hata metinleri
| Kod | Metin |
|---|---|
| ipBanned | "Sunucu bu IP'yi banlamış." |
| cidBanned | "Sunucu bu CID'yi banlamış." |
| unreachable | "Sunucuya erişilemedi (yanıt yok)." |
| banUnknown | "Ban durumu belirlenemedi." |
| cidNotApplicable | "CID kontrolü bu sunucuda uygulanamaz." |

### 13.6 Kabul kriterleri (v1.1)
1. Sahte UDP taşıyıcısıyla birim testleri: info→challenge→`ipOk`; ban metni→`ipBanned`; `client_connect`→`cidOk`; `errormsg`+ban→`cidBanned`; `unsupported protocol`→`cidNotApplicable`; sessizlik→`unreachable`.
2. Gerçek ağ testi (manuel): `51.68.190.91:27015` → `ipBanned`; `5.161.189.195:27015` → `ipOk`.
3. Ban sonucu genel durumu kırmızıya çevirir ve gerekçede görünür.
4. "Ban kontrolü" anahtarı kapalıyken hiçbir UDP paketi gönderilmez (test: sahte taşıyıcı sayaç).
5. Aynı sunucuya 10 sn içinde ikinci kontrol yapılmaz (test: zaman kaynağı enjekte edilir).
6. Mevcut 81 test bozulmaz; yeni testler ağa çıkmaz.


---

## 14. Yapılacaklar / öneriler (v1.2)

### 14.1 Amaç
Her gerekçe (reason) için **kullanıcının atabileceği somut adım** gösterilir. Durum mantığı değişmez; yalnız sunum katmanına öneri metni eklenir.

### 14.2 Gösterim
1. Gerekçe listesinde her satır iki katmanlı:
   - Birincil: mevcut mesaj (§10, §13.5) + durum ikonu
   - İkincil (gri, küçük): `→ ` ile başlayan öneri metni (aşağıdaki tablodan birebir)
2. Üst bardaki durum etiketine tıklanınca **"Ne yapmalı?"** popover'ı açılır; o anki tüm gerekçelerin önerileri numaralı liste olarak gösterilir. Popover'da "Kopyala" düğmesi listeyi panoya yazar (düz metin).
3. Öneri metinleri kesin ve eyleme dönük; "belki", "deneyin" gibi ifadeler yalnız gerektiğinde. Banla ilgili önerilerde suçlayıcı dil yok.

### 14.3 Öneri tablosu (birebir)
| Kod | Öneri metni |
|---|---|
| ipBanned | "IP'nizi değiştirin: modemi/routerı 5 dakika kapatıp açın; IP değişmezse VPN kullanın. Ban süreli olabilir, birkaç saat sonra tekrar deneyin. Kalıcıysa sunucu yöneticisinden kaldırmasını isteyin." |
| cidBanned | "IP değiştirmek yetmez, bu CID (authid) engelli. Sunucu yöneticisinden kaldırmasını isteyin. Bu kimlik bu makinede paylaşımlı üretildiği için başka bir istemcinin banı da size yansıyabilir." |
| unreachable | "Sunucu kapalı olabilir veya UDP erişimi engellenmiştir. GameTracker sayfasından sunucunun canlı olduğunu doğrulayın; güvenlik duvarı/VPN'yi kontrol edin." |
| banUnknown | "Sunucu bu tür sorgulara yanıt vermiyor olabilir. Birkaç dakika sonra Yenile'ye basın; sorun sürerse sunucu yöneticisine danışın." |
| cidNotApplicable | "Bu sunucu eski oyun protokolünü kullanıyor; CID banı burada test edilemez. IP ban sonucu geçerlidir." |
| identityMissing | "Oyunu bir kez başlatıp kapatın; kimlik dosyası otomatik oluşur, sonra Yenile'ye basın." |
| identityInvalid | "Kimlik dosyası bozulmuş. Dosyayı silin, oyunu bir kez açıp kapatın; yeniden oluşturulur." |
| publicIPFailed | "İnternet bağlantısını kontrol edin. VPN/güvenlik duvarı bu isteği engelliyor olabilir." |
| snapshotMissing | "Doğrulama yapılabilmesi için Kaydet'e basarak referans kaydı oluşturun." |
| snapshotCorrupt | "Kayıt dosyası okunamıyor. Kaydet'e basarak yeni kayıt oluşturun." |
| rawIDZero | "Bu sürümde beklenen durum: kimlik donanımdan üretilmiyor. Ban riski taşır, çünkü aynı CID tüm benzer kurulumlarda geçerli." |
| nameChanged | "Oyundaki isim değişmiş. Bilinçli yaptıysanız Kaydet'e basın, aksi hâlde oyun ayarlarını kontrol edin." |
| modelChanged | "Oyuncu modeli değişmiş. Bilinçli yaptıysanız Kaydet'e basın." |
| publicIPChanged | "IP'niz değişmiş (dinamik IP'de normal). Doğru değer buysa Kaydet'e basın." |
| lanIPChanged | "Yerel ağ değişmiş (Wi-Fi/Ethernet geçişi olabilir). Bilinçliyse Kaydet'e basın." |
| serverCIDChanged | "Sunucu CID'si kayıttan farklı; kimlik kaynağı değişmiş olabilir. Yenile'den sonra Kaydet'e basın." |
| invalidHost | "Adresi IP:port biçiminde girin (örn. 51.68.190.91:27015)." |

### 14.4 Kabul kriterleri (v1.2)
1. Her `MessageCode` için **boş olmayan** öneri metni vardır; birim testi tüm kodları gezer (eksik varsa test kırılır).
2. Gerekçe satırlarında öneri ikincil satır olarak görünür; metinler §14.3 ile birebir.
3. "Ne yapmalı?" popover'ı o anki gerekçelerin önerilerini numaralı listeler; "Kopyala" panoya düz metin yazar.
4. `ipBanned` senaryosunda ekranda IP değiştirme önerisi görünür.
5. Durum/renk mantığı değişmez; mevcut 110 test bozulmaz.


---

## 15. Oyuncu adı ve modeli düzenleme + Uygula (v1.3)

### 15.1 Amaç
Kullanıcı, oyuna girmeden önce oyuncu adını ve modelini **dropdown** ile seçip **Uygula** ile diske yazabilir.

### 15.2 Etkin değer ve kaynak önceliği (kritik)
Aynı anahtar iki dosyada bulunabilir:
- `<gamedir>/config.cfg`
- `<gamedir>/userconfig.cfg` — motor bunu `config.cfg`'den **sonra** çalıştırır, dolayısıyla buradaki `name`/`model` **etkin değeri ezer**.

Kurallar:
- **Etkin değer** = `userconfig.cfg`'de anahtar varsa oradaki, yoksa `config.cfg`'deki.
- Arayüzde değerin yanında kaynak gösterilir: `config.cfg` veya `userconfig.cfg (config.cfg'yi ezer)`.
- Uygula, **etkin dosyayı** yazar; anahtar iki dosyada da varsa **ikisi de** aynı değere getirilir (çalışma sırası ne olursa olsun sonuç aynı olsun).
- Hiçbir dosyada anahtar yoksa `config.cfg` sonuna eklenir.

### 15.3 Model listesi (dropdown)
Kaynak: `<gamedir>/models/player/` altındaki **klasör adları**, alfabetik (ör. valve: `barney, bbbarney, gina, gman, gordon, helmet, hgrunt, ivan, recon, robo, scientist, skeleton, tmcm, zombie`).
- Mevcut model listede yoksa listenin başına eklenir ve "(mevcut)" ile işaretlenir.
- Gamedir değişince liste yeniden yüklenir.
- Klasör okunamazsa boş liste + elle giriş alanı (dropdown "Elle gir…" seçeneği).

### 15.4 Ad listesi (dropdown)
- Seçenekler: mevcut ad, kayıttaki ad, son kullanılan adlar (en fazla 10, UserDefaults) ve **"Yeni ad…"** (alert içinde metin alanı).
- Seçim değişince taslak değer güncellenir; yazma yalnız Uygula ile olur.

### 15.5 Doğrulama
Ad:
- Kırpılmış uzunluk 1…31 karakter ve UTF-8 bayt uzunluğu ≤ 31.
- `"`, `\`, satır sonu (`\n`, `\r`) ve kontrol karakterleri yasak; baş/son boşluk kırpılır.
Model:
- 1…32 karakter, boşluk ve `"` yasak; `A-Z a-z 0-9 _ -` dışı reddedilir.
Geçersizse Uygula devre dışı + satır altı hata metni.

### 15.6 Yazma kuralları (güvenlik)
- Yalnız iki anahtar; dosyanın geri kalanı **bayt bayt** korunur.
- Dosyadaki satır sonu stili korunur (LF/CRLF karışıksa baskın stil kullanılır).
- Anahtarın **tüm** geçişleri aynı değere set edilir (son geçiş kazandığı için tutarlılık).
- Anahtar yoksa dosya sonuna `name "…"` / `model "…"` eklenir (yeni satırla).
- Atomik yazma (aynı klasörde geçici dosya + `replaceItemAt`); her değişen dosya için tek yuvarlanan yedek: `<dosya>.appbak` (oyunun kendi `config.cfg.bak` dosyasına **dokunulmaz**).
- Oyun çalışıyorsa (`xash3d` süreci tespit edilirse) yazma reddedilir.
- Yazma sonrası dosyalar yeniden okunur, etkin değer/kaynak güncellenir, snapshot "Kaydedilmedi" olur (Kaydet ayrı).
- Gamedir değiştirilmişse yazma **seçili gamedir'e** yapılır.

### 15.7 Arayüz
- Profil kartında "Kullanıcı adı" ve "Oyuncu modeli" satırları düzenlenebilir: değer + `Menu`/`Picker` dropdown + kaynak notu.
- Aynı kartta **Uygula** düğmesi (`⌘⏎`); değişiklik yoksa veya doğrulama hatası varsa devre dışı.
- Uygulama sonucu tek satır: başarılıysa `Uygulandı · HH:mm:ss · config.cfg + userconfig.cfg`, hata varsa kırmızı metin.
- Yazma sırasında düğme spinner; UI donmaz.
- Oyun açıksa uyarı bandı: "Oyun açık. Değişiklikler çıkışta ezilir; önce oyunu kapatın."

### 15.8 Hata metinleri
| Kod | Metin |
|---|---|
| nameInvalid | "Kullanıcı adı 1–31 karakter olmalı; tırnak ve satır sonu kullanılamaz." |
| modelInvalid | "Model adı yalnız harf, rakam, alt çizgi ve tire içerebilir." |
| gameRunning | "Oyun açık. Değişiklikler çıkışta ezilir; önce oyunu kapatın." |
| writeFailed | "Dosya yazılamadı. Yedekten geri yüklemek için tekrar deneyin." |
| configMissing | "config.cfg bulunamadı; seçili gamedir doğru mu?" |

### 15.9 Kabul kriterleri (v1.3)
1. Fixture testleri: LF dosya, CRLF dosya, anahtar yok, çoklu geçiş, `userconfig.cfg` override, tırnak içinde boşluk. Her durumda **yalnız hedef satırlar** değişir; kalan baytlar aynı (testte bayt karşılaştırması).
2. Etkin değer önceliği testi: userconfig'de `name` varsa UI/okuma onu gösterir.
3. Uygula: iki dosyada da aynı değer; yedek dosyaları oluşur; oyunun `config.cfg.bak` dosyası değişmez.
4. Doğrulama testleri: 31 bayt sınırı (Türkçe karakter dahil), yasak karakterler, boş ad.
5. Oyun çalışıyorken yazma reddedilir (süreç tespiti enjekte edilebilir; testte sahte).
6. Uygula sonrası ekranda yeni değer + kaynak görünür; snapshot dirty olur; Kaydet sonrası `profile.json` yeni ad/modeli içerir.
7. Gerçek dosyada manuel doğrulama: geçici bir kopya gamedir fixture'ında uygula; gerçek `valve/config.cfg` ve `userconfig.cfg` **değiştirilmeden** bırakılır (sha ile kanıt).
8. Mevcut 110+ test bozulmaz; yeni testler ağa çıkmaz.

---

## 16. Model önizleme (küçük resim)

### 16.1 Amaç
Model dropdown'ında her oyuncu modelinin **küçük görseli**, seçili modelin ise daha büyük bir önizlemesi görünür; böylece hangi modelin seçili olduğu görsel olarak anlaşılır.

## 16.2 Kaynak
- Yol: `<gamedir>/models/player/<model>/` içindeki **ilk `.bmp`** dosyası (büyük/küçük harf duyarsız arama, alfabetik ilk).
- Biçim: 8-bit paletli BMP, ~164×200 (portre). Doğrulandı: valve **14/14**, gearbox **15/15**. Uzantı büyük harf olabilir (ör. `gman.BMP`); arama **dosya adı ve uzantıda** harf duyarsızdır.
- BMP yoksa/bozuksa: SF Symbol `person.crop.square` yer tutucusu + model adı. Hata mesajı gösterilmez. (Bu makinede tüm modellerde BMP var.)
- Görseller salt okunur; hiçbir dosya değiştirilmez. 3B render YOK.

## 16.3 Gösterim
- **Dropdown satırı:** 20×24 küçük resim + model adı; satır yüksekliği ~28.
- **Seçili model:** 56×68 önizleme; 8 pt köşe yuvarlatma, koyu zemin (`#1B2432`), 1 px ince çerçeve; yanında model adı ve kaynak dosya yolu (tooltip).
- Oran korunur (aspect fit, boşluklar koyu zemin). BMP'nin siyah zemini olduğu gibi bırakılır; şeffaflık uydurulmaz.
- Yüksek kaliteli interpolasyon; retina'da net.

## 16.4 Performans / önbellek
- Tüm modellerin görselleri ilk yüklemede belleğe alınır (14–15 × ~33 KB); ayrı disk önbelleği gerekmez.
- Dosya değişirse (mtime) yeniden yüklenir; gamedir değişince liste ve görseller yenilenir.
- Yükleme async; UI bloklanmaz, liste iskelet görünümüyle hemen açılır.

## 16.5 Testler
- Fixture: bmp'li model → yol bulunur, görsel decode edilir (boyut > 0).
- Fixture: bmp'siz model → yer tutucu döner, çökme yok.
- Bozuk/0 baytlık bmp → yer tutucu.
- Dosya adı büyük/küçük harf farkı → bulunur.
- `gman.BMP` (büyük uzantı) gerçek dosyada decode edilir; `barney` decode edilir; BMP'siz fixture modelde yer tutucu döner.

## 16.6 Kabul kriterleri
1. Model dropdown'ında görseller görünür; seçili modelin 56×68 önizlemesi profil kartında görünür.
2. `gman.BMP` gibi büyük uzantılı dosyalar da bulunur (valve 14/14); BMP'si olmayan modelde yer tutucu görünür, uygulama çökmez.
3. Gamedir `valve` ↔ `gearbox` değişiminde görseller doğru yenilenir.
4. Mevcut 116+ test bozulmaz; yeni testler ağa çıkmaz, oyun dosyalarına yazmaz.
5. Ekran görüntüsünde seçili modelin resmi ve dropdown'daki küçük resimler görünür.

---

## 17. Düzelt (ban sorunu çözme)

### 17.1 Amaç ve görünürlük
Sunucu satırında **Düzelt** düğmesi. Yalnız şu durumlarda görünür: `ipBanned`, `cidBanned`, `unreachable`.
Düğme, sorunun türüne göre **farklı akış** açar. Hiçbir durumda yalan "çözüldü" denmez.

### 17.2 IP ban akışı (onaylı, adım adım)
1. **Onay sayfası:** mevcut genel IP, yapılacak işlem, tahmini kesinti (5–20 sn), risk notu; "Başlat" / "Vazgeç".
2. **Eski IP** kaydedilir (A).
3. **Ağ yenileme:**
   - Birincil arayüz = varsayılan rota (`route get default` → `interface`).
   - Wi-Fi ise: `networksetup -setairportpower <if> off` → 3 sn → `on`.
   - Ethernet ise: `ipconfig set <if> DHCP` (yönetici onayı; macOS sistem diyaloğu, tek seferlik).
   - Komutlar **sabit allowlist**; kullanıcı girdisi komuta girmez.
4. **Ağ geri gelsin:** en çok 45 sn; 3 sn'de bir genel IP denenir.
5. **Yeni IP** (B):
   - A ≠ B → o sunucu için ban kontrolü yeniden çalışır.
     - `ipOk` → **"Çözüldü: IP değişti (A → B), ban kalktı."**
     - hâlâ `ipBanned` → "Yeni IP de banlı olabilir (subnet/aralık banı) veya sunucu tüm aralığı engelliyor."
   - A = B → **"IP değişmedi."** Sonraki adımlar gösterilir:
     - "Router arayüzünü aç" (`http://<gateway>`) — kullanıcı oradan PPPoE/WAN reconnect yapabilir,
     - "VPN kullan" önerisi,
     - süreli ban ihtimali için "birkaç saat sonra yeniden dene".
6. **Her durumda** arayüz açık bırakılır (finally/rollback); hata olsa da `on` komutu denenir.
7. Sonuç satırı zaman damgalı; satır ban durumu güncellenir; snapshot "Kaydedilmedi" olur.

### 17.3 CID ban akışı
Yerel düzeltme **yoktur** (ban sunucu tarafındadır). Düzelt:
- "CID banı yerel olarak kaldırılamaz" açıklaması,
- **"Unban mesajını kopyala"** (şablon: sunucu adı, saat, CID, isim, "yanlışlıkla banlandım, kaldırır mısınız?"),
- **"Sunucu sayfasını aç"** (`https://www.gametracker.com/server_info/<host>:<port>/`),
- "Yeniden kontrol et" düğmesi.

### 17.4 unreachable akışı
- "Yeniden kontrol et" + "Sunucu sayfasını aç"; ağ komutu çalıştırılmaz.

### 17.5 Güvenlik ve sınırlar
- Aynı anda tek Düzelt; 60 sn kilit; iptal edilebilir.
- Yönetici parolası yalnız macOS diyaloğunda; uygulama parola görmez/saklamaz.
- Hiçbir oyun dosyası yazılmaz; yalnız ağ arayüzü komutları ve kendi snapshot'ı.
- IP değişimi garanti değildir: ISS statik IP, CGNAT veya router PPPoE oturumu IP'yi koruyabilir. Uygulama sonucu olduğu gibi bildirir.
- Ban süresi/subnet bilgisi uzaktan okunamaz.

### 17.6 Testler (ağa çıkmaz)
Komut yürütücü + genel IP sağlayıcı + saat enjekte edilir.
1. IP değişti + ban kalktı → başarı.
2. IP değişti + ban sürüyor → uyarı.
3. IP değişmedi → yönlendirme metni.
4. Ağ geri gelmedi (45 sn timeout) → restore (`on`) çağrıldı + hata.
5. CID ban → hiçbir ağ komutu çalışmadı, mesaj üretildi.
6. İptal → komut zinciri durdu, arayüz açık.
7. Eşzamanlı ikinci Düzelt → kilit reddetti.
8. Allowlist dışı komut üretilemez (sabit komut doğrulaması).

### 17.7 Arayüz
- Satırda ban ikonunun yanında **"Düzelt"** düğmesi.
- Onay sayfası (sheet): mevcut IP, adımlar, risk, süre; "Başlat"/"Vazgeç".
- İlerleme: "IP yenileniyor…", "Ağ bekleniyor…", "Yeniden kontrol ediliyor…".
- Sonuç: yeşil/kırmızı metin + "Yeniden dene" ve "Router arayüzünü aç"/"Sunucu sayfasını aç" bağlantıları.

### 17.8 Kabul kriterleri
1. Buton yalnız `ipBanned`/`cidBanned`/`unreachable` satırlarında görünür.
2. Sahte yürütücü ile 8 senaryo testi geçer; gerçek ağ komutu testlerde çalışmaz.
3. CID ban akışında hiçbir ağ komutu çağrılmaz; unban metni panoya kopyalanır.
4. Zaman aşımında arayüzün açık bırakıldığı testle kanıtlanır.
5. Mevcut 145+ test bozulmaz; uyarı 0.
6. Gerçek ağda deneme yalnız kullanıcı onayıyla, tek sefer yapılır; kanıt olarak ekran görüntüsü/AX dökümü.


### 17.9 Ban ekosistemi — düzeltmenin sınırı (spec düzeltmesi)

Bir oyuncunun "banlı" olması **üç ayrı sistemden** kaynaklanabilir ve bunlar birbirinden bağımsızdır:

| # | Sistem | Nerede yaşar | Kim kaldırır | İstemci yapabilir mi? |
|---|---|---|---|---|
| 1 | Motor SteamID/CID banı (`banid` → `writeid`) | sunucu belleği + `banned_user.cfg`/`banned.cfg` | admin: `removeid` + **`writeid`** | ❌ |
| 2 | Motor IP banı (`addip` → `writeip`) | sunucu belleği + `listip.cfg`/`banned_ip.cfg` | admin: `removeip` + **`writeip`** | IP değişirse dolaylı |
| 3 | Plugin/SQL banı (AMXX/AMXBans) | kendi dosyası veya MySQL tablosu | admin: panel/menü/`DELETE` | ❌ |

Bu yüzden:
- **"Düzelt" bir unban değildir.** İstemci yalnız (a) IP'sini değiştirmeyi deneyebilir, (b) adminin doğru sistemi temizlemesi için **eksiksiz itiraz** üretebilir.
- Bir sistemden kaldırmak diğerini temizlemez; motor listesinden silip SQL satırını bırakmak, eklenti yeniden senkronlayınca banı geri getirir.
- `writeid`/`writeip` çalıştırılmazsa ban **map değişiminde/yeniden başlatmada geri gelir**.
- `amx_unban` stok kurulumda **IP banına** etki eder; SteamID/CID banını güvenilir şekilde kaldırmaz.
- `sv_filterban` cvar'ı IP listesinin davranışını ters çevirebilir → "beklenmedik ban" bununla açıklanabilir.

### 17.9.1 İtiraz metni (kopyalanacak) — zorunlu içerik
Şablon şu alanları **doldurulmuş** olarak üretir:
- Sunucu adı ve `host:port`, kontrol zamanı (yerel saat + UTC)
- Oyuncu adı, **CID (32 hex uuid)**, çıkış IP'si, gamedir/istemci bilgisi
- Gözlenen ham sunucu cevabı (ör. `ipBanned: You have been banned from this server.`)
- Kontrol türü: `engine IP (getchallenge)` / `engine CID (connect 49)` / `bilinmiyor (plugin/SQL olabilir)`
- Admin için kontrol listesi (metnin sonunda):
  1. `listid` ve `listip` ile kaydı bul,
  2. motor ID banı ise `removeid <id>` + `writeid`,
  3. motor IP banı ise `removeip <ip>` + `writeip`,
  4. AMXX ise `amx_unban <ip>` (yalnız IP) veya ban-manager menüsü,
  5. SQL/AMXBans ise panelden/DB'den sil,
  6. `sv_filterban` değerini kontrol et,
  7. sunucuyu yeniden başlat, `listid`/`listip` ile doğrula, oyuncuyu tekrar bağlanmaya çağır.
- Ban süreliyse bitiş zamanı ve gerekçe bilgisini soran tek cümle.

### 17.9.2 Sınıflandırma düzeltmesi
- `ipBanned` → **engine IP banı** (kanıt: getchallenge cevabı).
- `cidBanned` → **engine CID/uuid banı** (kanıt: connect 49 + `errormsg`/`disconnect` metninde ban).
- `cidUnknown` + `errormsg`/`disconnect` → **"sunucu reddetti, tür bilinmiyor"**; plugin/SQL banı olabilir. Ham metin gösterilir, kullanıcıya "ban türü doğrulanamadı" denir.
- `unreachable` → ban değil.

### 17.9.3 Yeni IP hâlâ banlıysa
Olası nedenler sırayla gösterilir:
1. Aralık/subnet banı (IP banları kabadır, CGNAT havuzunu bile yakalayabilir),
2. Plugin/SQL banı (IP'den bağımsız),
3. `sv_filterban` davranışı.
Bu durumda otomatik çözüm önerilmez; itiraz metni + sunucu sayfası verilir.

### 17.9.4 İletişim kanalı
- Sunucu sayfası bağlantısı: `https://www.gametracker.com/server_info/<host>:<port>/` — sayfada **Server Manager** adı listelenir (ör. POLIGON RPG için `leo_poligonrpg`). Uygulama bu bağlantıyı "Yöneticiye ulaş" olarak açar; sayfa içeriğini kazımaz.
- İtiraz metni panoya kopyalanır; kullanıcı GameTracker yorumu/Discord/Telegram üzerinden gönderir.

### 17.9.5 Ek kabul kriterleri
9. İtiraz metni 17.9.1'deki alanların tümünü içerir (test: alan alan doğrulama).
10. `cidUnknown` durumu "ban türü doğrulanamadı" olarak gösterilir ve ham cevap görünür.
11. "Yeni IP de banlı" sonucunda üç olası neden listelenir; uygulama "çözüldü" demez.
12. Hiçbir akışta istemci tarafında `banid`/`removeid` benzeri sunucu komutu çalıştırılmaz (uygulama yetkisi yok).

---

### 17.10 IP aralığı (range) banı — v1.6

**Gözlem:** IP değişse bile aynı sunucuda ban sürüyorsa, engel tek IP'de değil **aralıktadır** (ör. `198.51.0.0/16`). IP yenilemek bu durumda işe yaramaz.

#### 17.10.1 Gösterim
Ağ kartında genel IP'nin yanında aralık bilgisi:
`Aralık: 198.51.100.0/24 · 198.51.0.0/16` (IPv6 için `/64` ve `/48`).

#### 17.10.2 Sınıflandırma (Düzelt sonucu)
| Koşul | Sonuç |
|---|---|
| IP değişmedi, hâlâ `ipBanned` | mevcut davranış (§17.2) |
| IP değişti, hâlâ `ipBanned`, **aynı `/16`** (IPv6: aynı `/48`) | **`rangeBanned`** — "IP aralığı banı (198.51.0.0/16)" |
| IP değişti (farklı `/16`), hâlâ `ipBanned` | mevcut `stillBanned` mesajı korunur; Düzelt sayfasında ek olarak "aralık dışı — CID/plugin banı olabilir" metni gösterilir |
| IP değişti, ban kalktı | başarı (mevcut) |

#### 17.10.3 `rangeBanned` önerileri
1. "IP yenilemek işe yaramaz; aynı aralıktasınız."
2. "Farklı ağ dene: mobil hotspot (tethering) veya çıkışı farklı aralıkta olan VPN."
3. "Sunucu yöneticisinden aralık banını kaldırmasını iste" (itiraz metni aralık bilgisini içerir).
IP yenileme önerisi bu durumda **gösterilmez**.

#### 17.10.4 İtiraz metni ek alanı
`Muhtemel aralık banı: 198.51.0.0/16 (eski IP: A, yeni IP: B)` satırı eklenir; adminin `listip` çıktısında aralık girdisini araması istenir.

#### 17.10.5 Testler
- Aynı `/16` + hâlâ banlı → `rangeBanned` + üç öneri.
- Farklı `/16` + hâlâ banlı → "aralık dışı, CID/plugin olabilir".
- `/24` aynı ama `/16` farklı → range değil.
- IPv6 `/48` aynı → range; farklı → değil.
- IP ayrıştırma hatası → aralık gösterilmez, çökme yok.
- İtiraz metni aralık satırını içerir.

#### 17.10.6 Kabul kriterleri
1. Ağ kartında `/24` ve `/16` aralıkları görünür.
2. `rangeBanned` durumunda gerekçe ve üç öneri doğru; "IP yenile" önerisi görünmez.
3. İtiraz metni aralık bilgisini içerir.
4. Mevcut 176 test bozulmaz; uyarı 0.

---

## 18. Yerelleştirme (i18n) — TR + EN (v1.7)

### 18.1 Diller
- Kaynak dil: **Türkçe (tr)** — mevcut metinler birebir korunur.
- Ek dil: **İngilizce (en)**.
- Varsayılan: sistem dili; desteklenmeyen dilde **en**'e düşer.
- `CFBundleLocalizations`: `tr`, `en` · `developmentRegion`: `en`.

### 18.2 Anahtar şeması
`alan.öğe` biçiminde, kodda sabit metin yok:
`status.green.title`, `error.identityMissing`, `suggestion.ipBanned`, `fix.ipBan.step1`, `appeal.checklist.removeid`, `profile.model`, `network.range`, `server.add`, `a11y.status.green` …
Anahtarlar İngilizce; değerler dillere göre.

### 18.3 Kapsam
Buton, etiket, başlık, hata, öneri, onay, sheet, boş durum, tooltip ve **erişilebilirlik etiketleri** dahil tüm kullanıcı görünür metinler anahtar kullanır. Kodda kullanıcıya gösterilen sabit metin **yasak**; test ile taranır (string literal taraması).

### 18.4 Türkçe regresyon
TR değerleri, §10/§13.5/§14.3/§17'deki metinlerle **birebir aynı** olacak. Testler TR metinlerini bu kaynaktan doğrular.

### 18.5 Terim sözlüğü (EN)
| TR | EN |
|---|---|
| Yenile | Refresh |
| Kaydet | Save |
| Uygula | Apply |
| Düzelt | Fix |
| Gerekçe | Reason |
| Öneri | Suggestion |
| Aralık | Range |
| Genel IP | Public IP |
| Yerel IP | Local IP |
| Ham kimlik | Raw identity |
| Kimlik kaynağı | Identity source |
| Kayıt (snapshot) | Record |
| Sunucu | Server |
| Oyuncu modeli | Player model |
| Ban türü doğrulanamadı | Ban type unverified |
| IP aralığı banı | IP range ban |
| Engel yok | No block |
| Erişilemiyor | Unreachable |

### 18.6 Uygulama adı
- tr: **Cybokron Oyuncu Kimlik Kartı** · en: **Cybokron Player Identity**
- `InfoPlist.strings` ile `CFBundleDisplayName` yerelleştirilir.

### 18.7 Testler
1. Her anahtar için `tr` ve `en` değeri **dolu** (eksik/boş anahtar testi kırar).
2. TR değerleri spec metinleriyle birebir.
3. Görünür metinlerde hardcoded literal yok (kaynak taraması testi).
4. Dil değişimi (`-AppleLanguages ("en")`) ile aynı ekran EN metinlerle açılır.
5. Erişilebilirlik etiketleri de yerelleşir.

### 18.8 README
İngilizce; TR/EN ekran görüntüsü ve dil değiştirme notu.

---

## 19. İngilizce kod tabanı + veri göçü (v1.7)

### 19.1 Kod
- Tüm tanımlayıcılar, dosya/klasör adları, yorumlar, test adları ve commit mesajları **İngilizce**.
- Türkçe yalnız yerelleştirme dosyalarında (`tr` değerleri) ve kullanıcıya görünen çevirilerde.

### 19.2 Ürün kimliği
- Hedef/ürün: **PlayerIdentity**
- Bundle id: **`tr.ercanatay.playeridentity`**
- Proje dizini: `~/Documents/GitHub/player-identity` · GitHub: `ercanatay/player-identity` (private)
- Uygulama adı §18.6'ya göre yerelleşir.

### 19.3 Veri göçü (tek sefer)
- **Snapshot:** `~/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json` → `~/Library/Application Support/tr.ercanatay.playeridentity/profile.json`
  - Hedef yoksa kopyala (atomik); **eski dosyaya dokunma**.
- **UserDefaults:** eski domain (`tr.ercanatay.oyuncukimlik`) → yeni domain. Taşınacaklar: `dataRoot`, ban kontrolü anahtarı, son kullanılan adlar.
- Göç bayrağı: yeni domainde `migration.v2.completed`; bir kez çalışır, hata olursa sonraki açılışta tekrar denenir, uygulama çalışmaya devam eder.

### 19.4 Testler
- Eski snapshot var → yeni yola kopyalanır, içerik aynı, eski dosya değişmez.
- Hedef zaten var → üzerine yazılmaz.
- Bozuk eski JSON → göç atlanır, uygulama çökmez.
- Defaults taşınır; ikinci çalıştırmada tekrar taşınmaz.
- Göçten sonra profil kartında eski ad/model/IP/sunucular görünür.

### 19.5 Kabul
1. `xcodegen generate` + build + test → başarılı, uyarı 0.
2. Yeni bundle ilk açılışta eski kaydı göç eder; arayüzde aynı veriler görünür.
3. Eski `tr.ercanatay.oyuncukimlik` dosyaları değişmeden kalır (shasum).
4. TR ve EN ile açılışta tüm metinler doğru dilde.
5. Kaynak ağacında Türkçe tanımlayıcı/yorum kalmaz (yerelleştirme dosyaları hariç).
6. Mevcut 182 test güncellenerek geçer.

---

## 20. Sunucu adresi: hostname + DNS (v1.8)

- Sunucu `host` alanı IPv4, IPv6 veya **hostname** olabilir (RFC 1123; ≤253 karakter).
- Çözümleme: `getaddrinfo` (A ve AAAA). Sıra: **ilk IPv4**, yoksa ilk IPv6. Sonuç **5 dk** önbelleklenir; `port` değişmez.
- Etkin adres satırda gösterilir (`host → 1.2.3.4`); CID ve ban kontrolü **çözümlenen IP** ile yapılır.
- Çözümlenemezse: satır `invalidHost`; genel durum bozulmaz. Ağ hatası ile "böyle bir ad yok" ayrılır.
- Testler: sahte çözümleyici; A+AAAA, yalnız AAAA, boş, NXDOMAIN, önbellek TTL, port doğrulama.

## 21. Sunucu bilgisi (A2S_INFO) (v1.8)

- Ban kontrolünün (a) adımındaki A2S_INFO yanıtı ayrıştırılır: **isim, harita, oyuncu/maks, ping (RTT)**.
- GoldSrc `0x6D` ve Source `0x49` biçimleri; `0x41` challenge akışı korunur.
- Satırda: `harita · 9/26 · 42 ms`; isim tooltip'te. Bilgi yoksa gizlenir (hata değil).
- Bozuk/eksik yanıtta çökme yok; alanlar tek tek opsiyonel.
- Testler: iki biçim, eksik alan, UTF-8/latin1 isim, challenge, aşırı büyük paket.

## 22. Kontrol geçmişi (v1.8)

- `~/Library/Application Support/tr.ercanatay.playeridentity/history.jsonl` — **append-only** JSONL.
- Olaylar: `refresh`, `ipChanged`, `banAppeared`, `banLifted`, `identityChanged`, `nameChanged`, `modelChanged`, `apply`, `fixAttempt`, `appUpdateAvailable`.
- Her kayıt: `{ts, kind, serverID?, host?, old?, new?, note?}`. Aynı durum tekrarında **yeni kayıt yok** (durum geçişi bazlı).
- Saklama: son **5000** kayıt veya **90 gün** (hangisi önce dolarsa); yazma atomik değilse satır bazlı ekleme + bozuk satır toleransı.
- UI: "Geçmiş" penceresi; sunucuya/türe göre filtre, en yeni üstte, **Markdown/JSON dışa aktarma**.
- Testler: ekleme, geçiş dedupe, bozuk satır toleransı, saklama budama, filtre, dışa aktarma.

## 23. Bildirimler (v1.8)

- `UNUserNotificationCenter`; izin yalnız ilk bildirimden önce istenir.
- Bildirim üreten geçişler: `banAppeared`, `banLifted`, `ipChanged`, `identityChanged`, `fixAttempt` sonucu.
- İlk çalıştırmada ve durum değişmediğinde bildirim yok; aynı olay 10 dk içinde tekrar bildirilmez.
- Ayarlar > "Bildirimler" anahtarı (varsayılan açık). Kapalıyken hiçbir bildirim gönderilmez.
- Testler: geçiş→bildirim eşlemesi (protokol enjekte), dedupe, ayar kapalı, ilk çalıştırma.

## 24. Uygula öncesi diff (v1.8)

- Ad/model **Uygula**'ya basınca önce **önizleme sheet'i**: her dosya için değişecek satırlar (`-`/`+`, satır numarası, dosya adı).
- Değişiklik yoksa Uygula devre dışı; diff boşsa sheet açılmaz.
- "Yaz" onayı olmadan hiçbir dosya yazılmaz; iptal hiçbir şey değiştirmez.
- Testler: LF/CRLF diff, çoklu geçiş, anahtar ekleme, değişiklik yok, iptal.

## 25. Güncelleme kontrolü (v1.8)

- Açılışta en fazla **24 saatte bir** ve menüden elle: `GET https://api.github.com/repos/ercanatay/player-identity/releases/latest`.
- `tag_name` semver'i `CFBundleShortVersionString` ile karşılaştırılır (prerelease yok sayılır).
- Yeni sürüm varsa üstte **tek satır banner**: sürüm + "İndir" (release sayfası) + "Yoksay".
- Ağ hatası sessiz; kullanıcıya hata gösterilmez. Otomatik indirme/kurulum yok.
- Testler: semver karşılaştırma (1.10 > 1.9), API hatası, 24 saat önbellek, yoksay.

## 26. Developer ID imza + notarize (v1.8)

- Sertifika: **Developer ID Application: Rigicon, Inc. (GJ3Y762WQ9)**; `--options runtime`, `--timestamp`.
- Entitlements: sandbox kapalı; ağ istemci/sunucu, dosya okuma (kullanıcı seçimli) yeterli; `get-task-allow` yok.
- Notarize: `xcrun notarytool submit --wait` → `xcrun stapler staple` → `spctl -a -vv` **accepted**.
- CI: sertifika ve notary kimliği **GitHub Secrets** (`BUILD_CERT_P12`, `BUILD_CERT_PASSWORD`, `NOTARY_APPLE_ID`/`NOTARY_PASSWORD`/`NOTARY_TEAM_ID` veya API key). Secret yoksa release adımı atlanır (build yine çalışır).
- Release asset: imzalı+staple'lı `.zip` (+ SHA256). Notarize edilmemişse başlıkta "unsigned/ad-hoc" uyarısı.
- Kabul: `codesign --verify --deep --strict` ✅, `spctl` accepted ✅, `stapler validate` ✅, indirilen zip ilk açılışta uyarısız açılır.

---

## 27. Otomatik güncelleme (v1.9)

### 27.1 Akış
1. **Feed:** `GET https://api.github.com/repos/ercanatay/player-identity/releases` (stable, `draft=false`, `prerelease=false`, semver sıralı).
2. **Varlıklar:** `PlayerIdentity-<sürüm>-macos.zip` + `SHA256SUMS.txt` (satır: `<sha256>  <dosya adı>`).
3. **İndirme:** yalnız **HTTPS**; `~/Library/Application Support/tr.ercanatay.playeridentity/updates/downloads/`.
4. **Doğrulama (hepsi zorunlu):** boyut (asset.size) → SHA-256 (Sums dosyası) → zip açma (`ditto -x -k`) → `codesign --verify --deep --strict` → **TeamIdentifier `GJ3Y762WQ9`** → bundle id `tr.ercanatay.playeridentity` → sürüm = release sürümü.
5. **Kurulum:** mevcut app `updates/backup/PlayerIdentity-<eski>.app`'e taşınır → yeni app yerine konur → karantina temizlenir → yeni app açılır, eski süreç kapanır.
6. **Rollback:** kopyalama/açma başarısızsa yedek geri konur; hata kullanıcıya gösterilir.

### 27.2 Zamanlama
- Açılışta 24 saatte bir otomatik kontrol (mevcut §25 ile aynı sayaç), uygulama 6 saatten uzun açıksa 6 saatte bir tekrar.
- Manuel: menü "Güncellemeleri Denetle…" + Ayarlar > Güncellemeler > "Şimdi denetle".
- Otomatik **kurulum yok**; kullanıcı "Yükle" demeden indirme başlamaz (isteğe bağlı "otomatik indir" anahtarı varsayılan kapalı).

### 27.3 Arayüz
- Banner: "Yeni sürüm 1.2.0" · **Yükle** · "Sürüm notları" · "Yoksay".
- Ayarlar > Güncellemeler: mevcut sürüm, son kontrol, "Şimdi denetle", durum satırı (denetleniyor/indiriliyor/doğrulanıyor/kuruluyor/hata), otomatik denetim anahtarı.
- Kurulum sırasında ilerleme (yüzde + aşama) ve iptal; kurulum öncesi onay.

### 27.4 Güvenlik
- HTTPS zorunlu; HTTP yalnız `127.0.0.1` (test).
- İmza/team/bundle/sürüm doğrulaması geçmezse **kurulum yok**; indirilen dosya silinir.
- Rollback başarısızsa yedek yolu kullanıcıya gösterilir.
- `/Applications` yazılamıyorsa yönetici onayı (tek seferlik `osascript ... with administrator privileges`) veya "uygulamayı Applications'a taşıyın" yönlendirmesi.

### 27.5 Testler
Sahte feed/indirici/dosya sistemi: mutlu yol; checksum uyuşmazlığı; boyut uyuşmazlığı; yanlış team; yanlış bundle; sürüm uyuşmazlığı; rollback; iptal; HTTP reddi; 24 saat/6 saat sayaç.

---

## 28. Sürüm düşürme (v1.9)

### 28.1 Amaç
Kullanıcı yeni sürümde sorun yaşarsa **önceki kararlı sürüme** dönebilsin; veri kaybı olmasın.

### 28.2 Akış
1. Ayarlar > Güncellemeler > **"Sürüm geçmişi"**: GitHub releases listesi (stable, son 20), mevcut sürüm işaretli; daha eski sürümlerde **"Bu sürüme dön"**.
2. Onay sheet'i: hedef sürüm, uyarı ("eski sürüm yeni veriyi okuyamayabilir"), **"Önce veriyi yedekle"** (varsayılan açık).
3. Veri yedeği: `updates/backups/data-<mevcut>-to-<hedef>-<ts>/` içine `profile.json`, `history.jsonl`, UserDefaults dışa aktarımı (`defaults export`), `snapshot-info.json`.
4. Kurulum §27.1 adımlarıyla aynı (indirme+doğrulama+değiştirme), fark: hedef sürüm daha eski olabilir; sürüm eşitliği hedefe göre doğrulanır.
5. Yeniden başlatma sonrası ilk açılışta: kayıt şeması desteklenmiyorsa **"Yedekten geri yükle"** önerilir; geri yükleme dosyaları yerine koyar ve uygulamayı yeniden başlatır.
6. Aynı sürüme "dön" devre dışı; yükseltme ile aynı mekanizma.

### 28.3 Kurallar
- Sürüm düşürme yalnız **stable** sürümlere; prerelease/draft yok.
- İmza/team/bundle doğrulaması aynı; eski sürümün imzasız olması kurulumu engeller.
- Veri yedeği silinmez (kullanıcı "Yedekleri temizle" diyene kadar; en fazla 10 yedek, en eski silinir).
- Geri yükleme yalnız kullanıcı onayıyla; otomatik veri değiştirme yok.

### 28.4 Testler
Feed'de eski sürümler; downgrade seçimi; veri yedeği içeriği; şema uyumsuzluğunda geri yükleme akışı; aynı sürüm reddi; imza/team hatası; yedek budama (10).

---

## 29. Oyuna gir (connect) (v2.0)

- Sunucu satırında **"Oyuna gir"** (yalnız macOS + Xash3D kuruluysa; değilse gizli).
- Komut: `/usr/bin/open -a <Xash3D.app> --args -game <gamedir> +connect <host>:<port>`; hostname ise çözümlenen IP kullanılır.
- Oyun zaten çalışıyorsa **uyarı**: "Oyun açık; yeni bağlantı mevcut oyunu kapatır" + onay.
- `-game` profil gamedir'inden; ek argüman ayarı yok (V1).
- Hata: uygulama bulunamadı → "Xash3D bulunamadı. /Applications/Xash3D-FWGS.app gerekli."
- Testler: komut üretimi (IPv4/IPv6/hostname), uygulama yolu bulunamadı, oyun çalışıyor uyarısı, iptal.

## 30. Menü çubuğu + açılışta başlat (v2.0)

- `NSStatusItem`: durum ikonu (yeşil/turuncu/kırmızı), menüde: durum metni, **Yenile**, **Ayarlar**, **Göster**, **Çık**.
- Arka planda **30 dk**'da bir yenileme (yalnız menü çubuğu modu açıksa); oyun sunucularına giden sorgular mevcut limitlere tabi.
- Ayarlar > Genel: **"Menü çubuğunda göster"** (varsayılan kapalı), **"Açılışta başlat"** (`SMAppService.mainApp`, varsayılan kapalı; kayıt hatası kullanıcıya gösterilir).
- Menü çubuğu modunda Dock ikonu gizlenmez (V1); pencere kapanınca uygulama çıkmaz.
- Testler: durum→ikon/başlık eşlemesi, 30 dk sayaç, login item kayıt/çıkarma (protokol enjekte), hata metni.

## 31. Sunucu grupları ve favoriler (v2.0)

- `ServerEntry`: `group: String?` (varsayılan yok), `favorite: Bool`, `order: Int`.
- UI: gruplara göre bölümler (grup adı sıralı; grupsuzlar "Diğer"), favoriler üstte yıldızla; **"Yalnız banlıları göster"** ve **"Yalnız favoriler"** filtreleri.
- Sunucu ekle/düzenle sheet'inde grup seçimi (mevcut gruplar + yeni grup adı) ve favori anahtarı.
- Sıralama: satır içi ▲/▼ (sürükle-bırak V1 dışı); `order` kalıcı.
- Testler: gruplama/sıralama, filtreler, yeni grup, kayıt geriye uyumu (alanlar opsiyonel).

## 32. Notlar + itiraz takibi (v2.0)

- `ServerEntry`: `note: String` (en fazla 2000 karakter), `appeal: Appeal?`
- `Appeal`: `sentAt: Date`, `channel: String` (Discord/Telegram/forum/e-posta/diğer), `status: sent|answered|rejected|accepted`, `followUpAt: Date?`, `summary: String`.
- UI: satır detayında **Notlar** ve **İtiraz** bölümü; itiraz kaydı ekle/düzenle; durum rozeti; `followUpAt` geçmişse satırda 🔔 hatırlatma.
- İtiraz metni kopyalama mevcut §17.9.1 akışını kullanır; kaydedince geçmişe `appeal` olayı düşer.
- Testler: not doğrulama/uzunluk, itiraz CRUD, durum geçişleri, takip tarihi, geçmiş kaydı, geriye uyum.

## 33. CID paylaşım kartı (PNG) (v2.0)

- Satır menüsünde **"Paylaşım kartı oluştur"**: 1200×630 PNG; içerik: uygulama ikonu, sunucu adı/host:port, CID (monospace), kullanıcı adı, tarih-saat, **QR** (CID metni).
- "Panoya kopyala" ve "Diske kaydet" (NSSavePanel). Arka plan marka rengi, TR/EN etiketler.
- Testler: kart üretimi (boyut, boş değil), QR üretimi, uzun isim kısaltma, eksik alanlarda çökme yok.

### 33.1 Paylaşım kartı: DURUM ve BAN TİPİ (v2.26.1, spec v5.4.7)

Kapsam: ban durumu veya GoldSrc 48 sunucusu için paylaşım kartı (§33) CID satırı yerine **DURUM** ve **BAN TİPİ** alanlarını gösterir. Kart, §17/§7 ban sonuçlarını değiştirmez; yalnız sunumunu ve QR içeriğini belirler. Kart üretimi salt okunurdur ve ağ çağrısı yapmaz.

**Kart alanları (sıra):** uygulama ikonu · sunucu adı · host:port · **DURUM** · **BAN TİPİ** · CID (yalnız source49 ve CID mevcutsa, aşağıdaki kural) · kullanıcı adı · tarih-saat · QR.

#### 33.1.1 DURUM eşlemesi (tek metin, renkten bağımsız)
| Kaynak durumu | DURUM metni | Görsel durum |
|---|---|---|
| `ipBanned`, `rangeBanned`, `cidBanned`, `goldSrcBanned` | "Ban var" | kırmızı |
| `cidOk` | "Ban yok" | yeşil |
| `goldSrcUnverified`, `cidUnknown`, `unknown`, `unreachable` | "Doğrulanamadı" | gri/turuncu |
| kontrol yapılmadı (check yok) | "Kontrol edilmedi" | gri |

- `goldSrcBanned` = §75 `banned` sonucu (yalnız ban metni). `goldSrcUnverified` = §75 `legacyVerificationUnavailable`. "Ban yok" GoldSrc'de hiçbir koşulda üretilmez (§75.10 P6).

#### 33.1.2 BAN TİPİ eşlemesi
| Kaynak | BAN TİPİ metni |
|---|---|
| `ipBanned` (aralık bilinmiyor) | "IP banı" |
| aralık biliniyorsa (`rangeBanned`, §17.10; aralık `ipBanned` ile birlikte biliniyorsa da) | "IP aralık banı" |
| `cidBanned` | "CID banı" |
| `goldSrcBanned` | "Sunucu bağlantı banı (tür belirsiz)" — hesap/SteamID/IP iddiası **yok** |
| doğrulanamadı / kanıt yok (`goldSrcUnverified`, `cidUnknown`, `unknown`) | "Belirlenemedi" |
| `cidOk`, `unreachable` (ban iddiası yok), kontrol yok | "—" |

- Öncelik: aralık bilgisi varsa IP türleri için "IP aralık banı" kullanılır (daha özgül).
- `goldSrcUnverified` ve `cidUnknown` iken BAN TİPİ "Belirlenemedi"dir (tür kanıtlanamadı); `unreachable` ban iddiası taşımadığı için "—"dır.
- Source49 `cidBanned` ile IP türleri birlikte bilinmiyorsa birincil tür `cidBanned`'dır.

#### 33.1.3 CID satırı kuralı (açık istisna: source49 geriye uyum)
- **Source49:** §33'teki mevcut davranış korunur: CID doluysa kartta tam CID satırı bulunabilir ve QR CID'yi taşıyabilir. Bu, politikanın **açık istisnasıdır**. Ban durumunda DURUM ve BAN TİPİ bu satırlara **ek** gösterilir.
- **Source49 CID boşsa CID satırı yoktur** (boş metin veya yer tutucu gösterilmez).
- **GoldSrc 48:** CID satırı yoktur; hesaplanan/yerel CID hiçbir yerde yazılmaz (§75.3).

#### 33.1.4 QR içeriği
- **Source49:** mevcut CID QR davranışı korunur (CID taşıyabilir); DURUM ve BAN TİPİ QR'a eklenmez (geriye uyum).
- **GoldSrc 48:** QR payload yalnız şu alanları taşır (sabit anahtar sırası, satır sonu ayraçlı düz metin): `sunucu=<ad>`, `adres=<host:port>`, `durum=<DURUM anahtarı>`, `ban=<BAN TİPİ anahtarı>` (`ip`, `ipRange`, `cid`, `goldSrc`, `unknown`, `none`), `surum=goldsrc48`. Adres (sunucunun host:port'u) QR'da ve kartta bulunabilir; coğrafi konum/koordinat ise yoktur.
- **GoldSrc QR ve kartta yasak:** tam CID, raw ID, seri numarası, ticket, parola, coğrafi konum/koordinat, yerel dosya yolu.

#### 33.1.5 Görsel ve düzen
- Ban durumunda DURUM metni kırmızı, BAN TİPİ turuncu (kritik değil) veya kırmızı; renk tek başına anlam taşımaz: metin ve simge (`xmark.octagon` / `exclamationmark.triangle`) birlikte.
- 1200×630 tuvalde hiçbir metin taşmaz veya kesilmez.
- **Uzun metin kuralı:** sarmalanacak alanlarda (sunucu adı, BAN TİPİ, uzun kullanıcı adı) ön-kesim (`prefix`/`truncate` ile önceden kısaltma) **yoktur**. Önce satır sarma, sonra yazı ölçeği tabana kadar küçültülür (taban değer tasarımda sabitlenir ve testte doğrulanır). Taban da sığmazsa son çare **ellipsis** (`…`) ile kesilir; ellipsis yalnız bu son adımda kullanılır.
- **Player adı ve tarih-saat küçülmez** (font ölçeği dışı tutulur); gerekiyorsa kendi alanlarında sarılır, düşürülmez.
- Metinler 26 dilde `shareCard.status.*`, `shareCard.banType.*`, `shareCard.qr.*` anahtarlarıyla bulunur (TR/EN dolu, 24 dil İngilizce yer tutucu, §63 aracı). Anahtar seti eşit kalır.

#### 33.1.6 Gizlilik
- **Source49:** mevcut §33 maskeleme ve CID satırı kuralı geçerlidir (CID doluysa gösterilebilir; açık istisna).
- **GoldSrc 48:** kartta ve QR'da tam CID, raw ID, seri numarası, ticket, parola, coğrafi konum/koordinat ve yerel dosya yolu **yoktur**. Sunucu adı, host:port, DURUM ve BAN TİPİ bulunabilir.
- **Geçmiş dışa aktarımı:** kart veya QR ile birlikte geçmiş (history) verisi dışa aktarılacaksa, geçmiş aralığı tamamen yüklenmeden dışa aktarma **devre dışıdır** (kullanıcıya "geçmiş yükleniyor" durumu gösterilir).

#### 33.1.7 Kabul kriterleri ve testler
- **AC-33.1.A** GoldSrc `goldSrcBanned` kartı: "Ban var" ve "Sunucu bağlantı banı (tür belirsiz)" içerikte; CID satırı yok (T-33-1).
- **AC-33.1.B** Source49 `cidBanned`, CID dolu: DURUM "Ban var", BAN TİPİ "CID banı"; CID satırı korunur (istisna) (T-33-2).
- **AC-33.1.C** `ipBanned` (aralık yok): "IP banı" (T-33-3).
- **AC-33.1.D** `rangeBanned`/aralık biliniyor: "IP aralık banı" (T-33-4).
- **AC-33.1.E** `goldSrcUnverified`/`cidUnknown`/`unknown`: "Doğrulanamadı" + "Belirlenemedi"; `unreachable`: "Doğrulanamadı" + "—" (T-33-5).
- **AC-33.1.F** Kontrol yok: "Kontrol edilmedi" + "—" (T-33-6).
- **AC-33.1.G** `cidOk`: "Ban yok" + "—" (T-33-7).
- **AC-33.1.H** GoldSrc QR payload: `sunucu`, `adres`, `durum`, `ban`, `surum=goldsrc48` içerir; CID, raw ID, seri, ticket, parola, coğrafi konum içermez (T-33-8).
- **AC-33.1.I** Politika (iki kural, T-33-9): (a) GoldSrc kartı ve QR'ında CID/raw ID/seri/ticket/parola/konum dizgisi aranır, bulunmaz; (b) source49 CID dolu iken kart ve QR'da tam CID bulunabilir (açık istisna); source49 CID boşsa CID satırı yoktur.
- **AC-33.1.J** Düzen (T-33-10): 1200×630, uzun sunucu adı + uzun BAN TİPİ + 26 dil en uzun çeviri; ön-kesim yok; sarma → ölçek tabanı → son çare ellipsis sırası; player ve tarih ölçeklenmez/düşmez.
- **AC-33.1.K** Kanıt (T-33-11): her ban durumu ve her 26 dil için PNG üretilir (`evidence/share-card/<dil>/<durum>.png`); içerik kontrolü DURUM metninin varlığını, taşmamayı ve ellipsis yalnız son çare olduğunu doğrular.
- **AC-33.1.L** Renk tek başına değil: kırmızı/turuncu sınıflarda metin ve simge birlikte (T-33-12).
- **AC-33.1.M** l10n: `shareCard.*` anahtarları 26 dilde eşit, TR/EN dolu, 24 dil yer tutucu (T-33-13).
- **AC-33.1.N** Geçmiş dışa aktarımı: geçmiş aralığı yüklenmeden export düğmesi devre dışı; yükleme bitince etkin (T-33-14).

#### 33.1.8 Sınırlar
- "Sunucu bağlantı banı (tür belirsiz)" GoldSrc'de ban türünü (hesap, SteamID, IP, aralık) iddia etmez.
- Kart DURUM alanı tekil ölçümün anlık sonucudur; geçmiş veya kesin ban kaydı değildir.

## 34. CLI yardımcısı (`playeridentityctl`) (v2.0)

- `project.yml`'a **commandLineTool** hedefi; `PlayerIdentity/Core` kaynaklarını uygulamayla paylaşır (kopya derleme, ayrı modül yok).
- Komutlar:
  - `cid <ip> [--raw-id <hex>] [--json]`
  - `ban <host:port> [--cid <hex>] [--json] [--timeout 4]`
  - `status [--json]` — snapshot'tan özet (sürüm, rawID, sunucular, ban durumları)
  - `--version`
- Çıkış kodları: 0 başarı; 1 kullanım hatası; 2 ağ/çözümleme hatası; 3 ban var.
- JSON çıktısı kararlı alan adları (`schemaVersion: 1`).
- Uygulama bundle'ına dahil: `PlayerIdentity.app/Contents/Helpers/playeridentityctl` (release build'te kopyalanır).
- Testler: argüman ayrıştırma, JSON şeması, çıkış kodları, IPv6, stdin yok.

---

## 35. Dil seçici (TR/EN) (v2.1)

### 35.1 Ayar
- `appLanguage` tercihi (`UserDefaults`): `system` (varsayılan) · `tr` · `en`.
- **Sistem** seçiliyken: `Locale.preferredLanguages.first`; `tr*` → Türkçe, diğer her şey → İngilizce.
- Açık seçim sistem dilini ezer; geçersiz/bozuk değer `system` sayılır.

### 35.2 Arayüz
- Ayarlar > Genel'de **"Dil / Language"** açılır menüsü:
  - `Sistem / System` (varsayılan, yanında o anki çözümleme ör. "Sistem (Türkçe)")
  - `Türkçe`
  - `English`
- Seçenek etiketleri kendi dillerinde yazılır (Türkçe/English); "Sistem/System" aktif dile göre yerelleşir.
- Değişiklik **anında** uygulanır (yeniden başlatma yok): görünür tüm metinler, menüler, bildirim metinleri, erişilebilirlik etiketleri ve hata/öneri metinleri yeni dilde.
- Uygulama adı (menü çubuğu/Dock) **sistem diline** bağlıdır (InfoPlist); dil seçiciden değişmez — arayüzde not olarak belirtilir.

### 35.3 Teknik
- `L10n` çözümlemesi tercihi okur; seçili `.lproj` paketi önbelleklenir.
- Dil değişiminde görünüm ağacı yeniden kurulur (kimlik anahtarı) ve açık pencereler tazelenir.
- Menü çubuğu menüsü bir sonraki açılışta yeni dili kullanır (kabul edilebilir; pencere içi anında).

### 35.4 Testler
- Çözümleme matrisi: system+tr→tr, system+en→en, system+de→en, explicit tr/en, geçersiz değer→system.
- Tercih kalıcılığı ve yeniden yükleme.
- Dil değişince anahtar çözümlemesinin değişmesi (tr "Yenile" ↔ en "Refresh").
- tr/en anahtar sayıları eşit; yeni anahtarlar dolu; sabit literal taraması 0.

---

## 36. İtiraz takibi + hatırlatma (v2.2)

- `Appeal`'e `events: [{status, at}]` eklenir; durum değişiminde olay yazılır (en fazla 20).
- `followUpAt` geldiğinde **bir kez** bildirim: "İtiraz takibi: <sunucu>". `notifiedAt` ile tekrar engellenir.
- Kontrol anları: açılış, elle/otomatik yenileme, menü çubuğu 30 dk döngüsü.
- UI: detayda **zaman çizelgesi** (Gönderildi → Yanıtlandı → …) ve "Takip tarihini ertele (+1 gün, +3 gün)".
- Not değişiklikleri geçmişe `note` olayı olarak düşer (eski → yeni, 500 karakter kısaltma).
- Testler: olay ekleme/sınır, bildirim bir kez, erteleme, not geçmişi, kapalı bildirim ayarı.

## 37. Arayüzler ve VPN tespiti (v2.2)

- Ağ kartı: **Arayüzler** listesi (`en0`, `en1`, `utun*`, `bridge*`), IPv4/IPv6, durum (aktif/pasif) ve **VPN** işareti.
- VPN tespiti: `utun*` arayüzü varsa ve varsayılan rota onu kullanıyorsa "VPN aktif"; değilse "VPN yok".
- Çıkış IP'si tek (NAT) olduğundan arayüz başına ayrı genel IP iddiası yok; "Çıkış: <IP> · <arayüz>" gösterilir.
- Ban testi **her zaman çıkış IP'siyle** yapılır; VPN açıksa arayüzde uyarı: "VPN aktif — ban sonucu VPN çıkışına aittir."
- Testler: sahte arayüz listesi, VPN var/yok, IPv6 link-local hariç, çıkış arayüzü seçimi.

## 38. Ban matrisi (v2.2)

- Pencere/sheet: satırlar sunucular; sütunlar **IP ban**, **CID ban**, **Aralık**, **Son kontrol**; ikon + metin.
- "Ban türü doğrulanamadı" satırı ayrı işaretlenir; erişilemeyen satır "—".
- **CSV dışa aktar** (RFC 4180 kaçışı), **panoya kopyala**.
- Testler: matris üretimi, sıralama (banlılar üstte), CSV kaçışı (virgül/tırnak/satır sonu), boş durum.

## 39. Ping/uptime geçmişi (v2.2)

- `metrics.jsonl`: `{ts, serverID, host, online, ping, players, maxPlayers, map}` — her başarılı/başarısız kontrolde bir kayıt.
- Saklama: **30 gün** ve sunucu başına en fazla **5000** örnek; budama otomatik.
- UI: sunucu detayında **grafikler** (Swift Charts): ping (ms), oyuncu sayısı; üstte "son 24 saat uptime %".
- Testler: kayıt/okuma, budama, uptime hesabı (online/total), boş seri, CSV/JSON dışa aktarma, bozuk satır toleransı.

## 40. Ban listesi sorgusu (v2.2)

- Sunucu başına **ban listesi URL şablonu** (`banListURL`), örn. `https://panel.example.com/bans?q={cid}`.
- Yer tutucular: `{cid}`, `{ip}`, `{host}`, `{port}`; `https` zorunlu; en az bir yer tutucu.
- "Ban listesinde ara" → varsayılan tarayıcıda açar (URL encode). **Kazıma/otomatik okuma yok** (paneller kırılgan).
- Testler: şablon doğrulama, yer tutucu doldurma/encode, https zorunlu, eksik alan.

## 41. Altyapı paketi (v2.2)

- **Homebrew cask:** repoda `Casks/player-identity.rb`; `version`/`sha256` release asset'inden; `binary` ile `playeridentityctl` bağlanır. CI release adımı cask dosyasını güncel sha ile commit eder (opsiyonel, secret gerektirmez).
- **Teşhis paketi:** ZIP: `app-info.json` (sürüm, build, OS, mimari), `snapshot.redacted.json` (IP'ler maskeli), `history.tail.jsonl`, `metrics.tail.jsonl`, `update-state.json`; NSSavePanel.
- **App Intents / Kısayollar:** "Sunucu banını kontrol et", "CID'imi göster", "Yenile" — `AppIntents` ile; Siri/Kısayollar. (V1: 3 intent)
- **UI smoke testi:** XCUITest ile açılış + Ayarlar > Güncellemeler görünürlüğü (CI'da koşmaz, yerel etiketli).
- Testler: cask şablonu (Ruby sözdizimi lint), teşhis zip içeriği + redaksiyon, intent parametre çözümleme.

---

## 42. Sunucu izleme + bildirimler (v2.3)

### 42.1 Model
- `ServerEntry.watch: Bool` (varsayılan `false`, geriye uyumlu).
- İzlenen sunucu için geçişler kaydedilir ve bildirim üretilir:
  - `watchBanAppeared` (IP veya CID banı ortaya çıktı; tür metinde)
  - `watchBanLifted` (ban kalktı)
  - `watchOffline` (sunucu erişilemez oldu)
  - `watchOnline` (yeniden erişilebilir; aradan ≥10 dk geçtiyse)
  - `watchMapChanged` (harita değişti; eski → yeni)

### 42.2 Davranış
- Değerlendirme her **tam yenilemede** ve menü çubuğu 30 dk döngüsünde yapılır.
- Yalnız `watch == true` sunucular bildirim üretir; ilk gözlemde (önceki durum yok) **bildirim yok**.
- Aynı geçiş 10 dk içinde tekrar bildirilmez (mevcut dedupe).
- Bildirim ayarı kapalıysa hiç gönderilmez; geçmiş kayıtları yine yazılır (`watch*` olayları).
- Menü çubuğu modu kapalıysa arka plan kontrolü yoktur; arayüzde not gösterilir.

### 42.3 Arayüz
- Sunucu satırında **🔔 izle** anahtarı (sağ tık menüsünde de); detay sheet'inde "Bu sunucuyu izle" anahtarı + hangi olayların bildirileceği kısa açıklaması.
- Filtre: **"Yalnız izlenenler"** (mevcut filtrelerle birlikte çalışır).
- İzlenen satırda küçük 🔔 rozeti.

### 42.4 Testler
- Her geçiş türü için tespit + bildirim metni (TR/EN).
- `watch == false` → bildirim yok; ilk gözlem → yok; 10 dk dedupe.
- Harita değişimi eski→yeni; online/offline eşiği (10 dk).
- Filtre, kalıcılık, eski kayıt uyumu (alan yoksa `false`).
- Anahtar sayıları tr/en eşit; literal taraması 0.

---

## 43. `userconfig.cfg` override uyarısı + geniş model kataloğu (v2.4)

### 43.1 Override uyarısı
- Etkin değer `userconfig.cfg`'den geliyorsa profil kartında **belirgin uyarı** (turuncu):
  "`userconfig.cfg` içindeki `name`/`model` satırı `config.cfg`'yi eziyor. Oyun içi değişiklikler kalıcı olmaz."
- Yanında **"Satırı kaldır"** düğmesi:
  - Onay ister; dosyayı `userconfig.cfg.appbak-YYYYMMDD-HHmmss` olarak yedekler.
  - Yalnız ilgili satırı yorumlar (`// name "..."`) — başka satıra dokunmaz.
  - Sonrası: dosya yeniden okunur, etkin değer `config.cfg`'den gelir, geçmişe `configOverrideRemoved` olayı yazılır.
- Satır yoksa uyarı/düğme görünmez. Oyun açıkken kaldırma reddedilir (mevcut `gameRunning` kuralı).

### 43.2 Model kataloğu
- Model listesi şu klasörlerden toplanır (varsa):
  1. `<gamedir>/models/player/`
  2. `<veri kökü>/valve_downloads/models/player/`
  3. `<veri kökü>/<gamedir>_downloads/models/player/` (ör. `gearbox_downloads`)
- Klasör adları tekilleştirilir, alfabetik sıralanır; mevcut değer listede yoksa başa eklenir.
- Kaynak (yerel/indirilen) tooltip'te gösterilir; seçim aynı `model` anahtarına yazılır.
- Arayüzde not: "Bazı sunucular modeli kendi tarafında zorlar; bu durumda seçim o sunucuda görünmez."

### 43.3 Testler
- Uyarı yalnız override varken; satır kaldırma yedeği + yorumlama + diğer satırların korunması; oyun açıkken red.
- Model kataloğu: iki/üç kaynak, tekilleştirme, sıralama, mevcut değer, kaynak etiketi, boş klasör.
- Geçmiş olayı `configOverrideRemoved`; anahtar sayıları tr/en eşit.

---

## 44. İndirilen modellerin önizlemesi (v2.5)

- Önizleme arama sırası (ilk bulunan BMP):
  1. `<gamedir>/models/player/<model>/`
  2. `<veri kökü>/valve_downloads/models/player/<model>/`
  3. `<veri kökü>/<gamedir>_downloads/models/player/<model>/`
- Uzantı büyük/küçük harf duyarsız (mevcut davranış).
- Kaynak yolu tooltip'te; önbellek anahtarına dosya yolu + mtime girer.
- BMP yoksa yer tutucu (mevcut).
- Testler: yerel öncelik, indirilen klasörden bulma, büyük uzantı, yoksa yer tutucu, mtime değişiminde yenileme.

## 45. Bildirim inceliği + sessiz saatler (v2.5)

- Ayarlar > Genel > **Bildirimler** altında ayrı anahtarlar (varsayılan açık):
  - `notifyBanChanges` (ban başladı/kalktı)
  - `notifyOnlineChanges` (çevrimdışı/çevrimiçi)
  - `notifyMapChanges` (harita değişti)
- **Sessiz saatler:** anahtar + başlangıç/bitiş (`HH:mm`, varsayılan 23:00–08:00). Aralık gece yarısını aşabilir (23:00–08:00 gibi).
- Sessiz saatte bildirim **gönderilmez**; geçmiş kayıtları yine yazılır. Ban kalktı bildirimi de aynı kurala tabi.
- Eski `notificationsEnabled` anahtarı ana şalter olarak kalır; kapatılırsa hiçbiri gönderilmez.
- Testler: her olay türü için anahtar kapalı → bildirim yok; sessiz saat içinde/dışında; gece yarısını aşan aralık; ana şalter kapalı; kalıcılık; tr/en anahtar eşitliği.

### 45.1 README
- Homebrew kurulum: `brew tap ercanatay/tap && brew install --cask ercanatay/tap/player-identity`; `playeridentityctl` PATH'e linklenir.

---

## 46. Ayarlar dışa/içe aktarma (v2.6)

### 46.1 Dışa aktarma
- JSON dosyası: `playeridentity-settings-YYYYMMDD-HHmmss.json` (NSSavePanel).
- Kapsam seçimi:
  - **Settings only:** dil, bildirim ana şalteri + kategoriler + sessiz saatler, menü çubuğu, açılışta başlatma tercihi, güncelleme tercihleri, ban kontrolü, veri kökü, gamedir.
  - **Settings + servers:** ek olarak sunucular (etiket, host, port, grup, favori, izleme, not, itiraz, ban listesi URL'si) — ban/metrik geçmişi, CID değerleri ve kimlik **dahil değil**.
- Biçim: `{ schemaVersion: 1, appVersion, exportedAt, scope, settings: {...}, servers: [...] }`.
- `dataRoot` varsayılan olarak **dahil edilmez** (taşınabilirlik); isteğe bağlı "veri kökünü de aktar" anahtarı.

### 46.2 İçe aktarma
- Dosya seçici; şema doğrulama; bilinmeyen alanlar yok sayılır; bozuk/eksik dosya reddedilir.
- **Önizleme:** kaç ayar, kaç sunucu; çakışan sunucular (aynı `host:port`); geçersiz satırlar.
- **Modlar:**
  - **Merge (varsayılan):** ayarlar uygulanır; sunucular `host:port` ile eşleşir → etiket/grup/favori/izleme/not/itiraz/ban listesi güncellenir; yalnız yerelde olanlar korunur; yeni olanlar eklenir.
  - **Replace:** mevcut sunucu listesi değiştirilir; öncesinde `profile.json.appbak-<zaman>` yedeği alınır.
- `dataRoot` yalnız "veri kökünü de aktar" işaretliyse uygulanır; aksi hâlde mevcut değer korunur.
- İçe aktarma sonrası: dosyalar yeniden okunur, "Kaydedilmedi" durumu, sonuç özeti (eklenen/güncellenen/atlanan).
- Güvenlik: dosya yalnız JSON; sembolik bağlantı/özel yol yok; sunucu host doğrulaması mevcut kurallarla.

### 46.3 Testler
- Roundtrip: settings-only ve settings+servers; alanlar birebir.
- Şema doğrulama: eksik sürüm, bilinmeyen sürüm, bozuk JSON, yanlış tip.
- Merge: yeni ekleme, mevcut güncelleme, yerelde kalan, çakışma sayısı.
- Replace: yedek oluşturma, liste değişimi, geri alma yok.
- `dataRoot` dahil/hariç; dil/bildirim/sessiz saat değerlerinin uygulanması.
- l10n anahtarları tr/en eşit; literal taraması 0.

---

## 47. Ayarları sıfırlama ve tüm verileri silme (v2.7)

### 47.1 Ayarları Sıfırla
- Tüm tercihleri varsayılana döndürür: dil `system`, bildirimler varsayılan (ana şalter açık, kategoriler açık, sessiz saatler kapalı 23:00–08:00), menü çubuğu kapalı, açılışta başlatma kaydı kaldırılır, güncelleme tercihleri varsayılan, ban kontrolü açık.
- **Korunur:** veri kökü, gamedir, sunucular, kayıt (`profile.json`), geçmiş, metrikler, yedekler.
- Onay ister; iptal hiçbir şey değiştirmez. Sonrasında arayüz yeni tercihlere göre yeniden çizilir.

### 47.2 Tüm Verileri Sil
- Yalnız uygulamanın kendi klasörünü boşaltır: `~/Library/Application Support/tr.ercanatay.playeridentity` (kayıt, geçmiş, metrikler, watch-state, güncelleme indirmeleri/yedekleri, `*.appbak`).
- **Dokunulmaz:** oyun dosyaları (`Xash3D FWGS`), veri kökü, uygulama tercihleri.
- Onay sheet'inde **"Önce ayarları dışa aktar"** seçeneği (varsayılan kapalı); dışa aktarma başarısızsa silme yapılmaz. "Vazgeç"/Esc hiçbir şey silmez.
- Güncelleme (indirme/kurulum) sürerken devre dışı.
- Silme sonrası uygulama boş duruma döner; çökme yok.

### 47.3 Testler
- Sıfırlama sonrası tüm tercih değerleri varsayılan; korunması gerekenlerin aynı kaldığı.
- Silme kapsamı (yalnız uygulama klasörü), oyun/veri kökü/tercihlerin korunması, iptal, dışa aktarma hatasında durma, güncelleme sırasında red.
- Onay metinleri tr/en; anahtar eşitliği.

### 47.4 UI redesign referansı
- Ana pencere ve Ayarlar, Claude Design handoff'una göre uygulanır.
- Kaynak: `docs/design/handoff/` (`tokens.css` tokenları, `MainWindow.dc.html`, `SettingsWindow.dc.html`, `icons.js` SF Symbol adları, Canvas N1 notları).
- Tokenlar SwiftUI `Theme`/`Palette` içinde light/dark olarak tanımlanır; hardcoded renk yok. Sahte pencere kromu (trafik ışıkları) çizilmez.
- Sapmalar: açık temada teal metin/düğme `#177A70`/`#187A71`; koyu temada `#2FB6A8`. "Fix…" ortak eylem penceresi değil, **satır içi sunucu eylem popover'ı** açar.

---

## 48. Kalan pencerelerin tasarım dili (v2.8)

Amaç: Geçmiş, Ban Matrisi ve Metrikler pencerelerini §47.4'teki token sistemiyle aynı görsel dile getirmek.
Davranış değişmez; yalnız sunum.

### 48.1 Geçmiş penceresi
- Toolbar: başlık, tür ve sunucu filtreleri, **JSON** / **Markdown** dışa aktarma düğmeleri.
- Satır: tür ikonu + etiketi, sunucu, zaman (göreli + tam tooltip), ayrıntı; en yeni üstte.
- Boş durum ve filtreye uymayan durum ayrı metinlerle.
- Sanal liste/performans: 5000 satırda kaydırma akıcı.

### 48.2 Ban matrisi
- Toolbar: başlık, **CSV dışa aktar**, **Kopyala**.
- Tablo: sunucu, IP ban, CID ban, aralık, son kontrol; durum çipleri (ikon + metin + tint), banlılar üstte.
- Dar genişlikte sütunlar önceliklendirilir; kesilme yerine tooltip.
- Boş durum: “Henüz sunucu yok.”

### 48.3 Metrikler
- Sunucu detayında grafik kartı: uptime başlığı, ping ve oyuncu grafikleri, çevrimdışı aralıklar işaretli.
- Boş seri: “Son 24 saatte veri yok.”
- Grafik eksenleri/legend token renkleriyle; light/dark uyumlu.

### 48.4 Kurallar ve testler
- Hardcoded renk yok; `Theme`/`Palette` kullanılır; sahte pencere kromu çizilmez.
- Light/dark × TR/EN kanıt görüntüleri; mevcut davranış testleri bozulmaz.
- Kaynak taramasında view dosyalarında sabit renk/ölçü kalmadığı doğrulanır.

---

## 49. Tam veri yedeği / geri yükleme (v2.9)

### 49.1 Manuel yedek
- `NSSavePanel`; dosya: `playeridentity-backup-YYYYMMDD-HHmmss.zip`.
- İçerik: `manifest.json` (`schemaVersion:1`, `appVersion`, `createdAt`, dosya sayıları), `profile.json`, `history.jsonl`, `metrics.jsonl`, `watch-state.json` (varsa).
- **Dahil değil:** oyun dosyaları, config yedekleri (`*.appbak`), güncelleme indirmeleri/uygulama yedekleri, loglar.

### 49.2 Geri yükleme
- `NSOpenPanel` (zip); manifest/şema doğrulama; **önizleme**: kayıt tarihi, sunucu sayısı, geçmiş/metrik satır sayıları, sürüm uyumu.
- Onay sonrası **önce mevcut veri** `backups/pre-restore-YYYYMMDD-HHmmss.zip` olarak yedeklenir.
- Zip geçici klasöre açılır; JSON/JSONL parse edilir; doğrulama geçerse dosyalar atomik olarak yerine konur; arayüz yeniden yüklenir.
- Herhangi bir adım başarısızsa mevcut veri korunur; hata mesajı gösterilir.
- Güncelleme (indirme/kurulum) sürerken reddedilir; geri yükleme sırasında yenileme kilitlenir.

### 49.3 Otomatik yedek
- Varsayılan **açık** (Ayarlar > Genel > Veri).
- Günde en fazla bir kez, açılışta: `backups/auto-YYYYMMDD.zip`; içerik manuel yedekle aynı.
- İçerik değişmediyse (dosyaların birleşik SHA-256'sı aynı) yeni dosya yazılmaz.
- Saklama: en fazla **5** otomatik yedek; en eski silinir.
- Güncelleme kurulumundan **önce** ve **geri yükleme öncesi** ayrıca yedek alınır (mevcut davranışın tam veri sürümü).

### 49.4 Testler
- Manifest alanları, zip içeriği (dosya kümesi), roundtrip.
- Eksik/bozuk manifest, şema uyumsuzluğu, bozuk JSON/JSONL, zip açılamıyor → mevcut veri korunur.
- Geri yükleme öncesi yedek dosyası; güncelleme sürerken ret; yenileme kilidi.
- Otomatik yedek: günde bir, değişmeyince yazmama, 5 dosya rotasyonu.
- Yedekte oyun dosyası/appbak/update klasörü **yok**; tr/en anahtar eşitliği.

### 49.5 Veri bütünlüğü
- **Geri alma:** dosyalar yerine konamazsa önce kenara alınan önceki dosyalar geri taşınır, sonra yeni dosyalar çıkarılır; adımlar `try?` ile yutulmaz. Geri alma tamamsa hata "mevcut veriler değişmedi" der ve geçici klasör silinir. Bir adım bile başarısızsa geçici klasör (`.restore-<UUID>/previous`) **silinmez**; hata "geri yükleme tamamlanamadı" der ve klasörün yolunu verir. Geçici klasör yalnız başarıda silinir.
- **Eksik yedek:** dosya yoksa yedekte de yoktur (uyarı değil). Var olup okunamayan/bozuk dosya veya atlanan bozuk JSONL satırları manifest'e `skipped: [{file, reason[, lines]}]` (`unreadable`, `corrupt`, `corrupt-lines`) olarak yazılır; alan yalnız bir şey atlandığında bulunur (şema 1 geriye uyumlu). Manuel yedek sonucu "N dosya atlandı, bu yedek eksik" uyarısı gösterir. Eksik dosyalı yedeğin önizlemesi ve onayı "bu dosyaların mevcut sürümleri silinir" der. Geri yükleme öncesi yedek bir dosyayı alamadıysa önceki dosyalar geçici klasörde saklanır ve yolu gösterilir.
- **Tüm Verileri Sil (§47.2):** klasör listelenemezse hiçbir şey silinmeden hata verilir. Silmeden sonra klasör yeniden listelenir; kalan öğe varsa adlarıyla raporlanır ve model diskte kalan veriden yeniden yüklenir (sonraki Kaydet eski listeyi geri yazmaz).
- **Tek veri işlemi kilidi:** geri yükleme ve silme aynı kilidi kullanır; kilit sürerken başka geri yükleme/silme, kurulum, yenileme, otomatik yedek, **Kaydet** ve veri kökü değişikliği reddedilir. Silme, bekleyen yazmalardan sonra güncelleme durumunu yeniden kontrol eder.
- **Kaydedilmemiş değişiklikler:** geri yükleme onayı bunları uyarır ve **"Önce kaydet"** seçeneği sunar (varsayılan açık); kayıt geri yükleme öncesi yedeğe girer. Kaydetme başarısızsa geri yükleme yapılmaz.

---

## 50. URL / toplu metinden sunucu ekleme (v3.0)

### 50.1 Girdi biçimleri
Tek metin alanına (satır veya virgülle ayrılmış, en fazla 100 kayıt) şunlar kabul edilir:
- `host:port` (IPv4, hostname, `[IPv6]:port`)
- `https://www.gametracker.com/server_info/<host>:<port>/` (query/fragment yok sayılır)
- `steam://connect/<host>:<port>`
- Baştaki/sondaki boşluklar, `http`/`https` ve sondaki `/` toleranslı.

### 50.2 Davranış
- Ayrıştırma sonucu **önizleme**: etiket (host), host, port, **zaten var** (host+port çakışması), geçersiz satır + neden.
- Geçersiz satırlar eklenmez; geçerli ve yeni olanlar seçili olarak gelir; kullanıcı seçimi değiştirebilir.
- Ekleme sonrası satırlar kaydedilmiş sayılmaz ("Kaydedilmedi"); istenirse hemen A2S ile isim/harita alınır (mevcut yenileme).
- Etiket varsayılanı host'tur; kullanıcı sonradan düzenleyebilir.
- `port` yoksa **27015** varsayılır.
- Aynı girdi içinde tekrarlanan kayıtlar tekilleştirilir.
- IPv6 yalnız köşeli parantezle kabul edilir (`[2001:db8::1]:27015`).

### 50.3 UI
- Sunucular bölümündeki `+` menüsünde **"URL'den / toplu ekle…"**; sheet: metin alanı, "Ayrıştır" düğmesi, önizleme listesi (seçim kutuları), "Ekle" (seçili N), hata satırları.
- Klavye: ⌘V yapıştırma, ⌘⏎ ekle; boş/geçersiz durumda düğme kapalı.
- Tasarım tokenları; TR/EN; erişilebilirlik etiketleri.

### 50.4 Testler
- Tüm biçimler + toleranslar; query/fragment; büyük harfli host; port aralığı; IPv6 parantezli/parantezsiz.
- 100 kayıt sınırı; boş satır; yinelenen girdi; mevcut sunucuyla çakışma; geçersiz satırların raporlanması.
- Ekleme sonrası model/kayıt durumu; l10n anahtar eşitliği; literal taraması 0.

### 49.5 Veri güvenliği (v3.1)
- Geri yükleme geri-alma: önce eski dosyalar geri taşınır, sonra yeni artıklar silinir; geri alma başarısızsa geçici klasör **silinmez**, `rollbackFailed(staging:reason:)` yolu raporlar ve arayüz "veriler değişmedi" demez.
- Yedekte okunamayan/bozuk dosyalar `manifest.skipped` olarak yazılır; yedek sonucu uyarı taşır ve eksik yedeğin geri yükleme onayı "bu dosyalar silinecek" der.
- Tüm Verileri Sil: envanter hatası throw eder; silme sonrası kalanlar adlarıyla raporlanır; kısmi silmede model diskten yeniden yüklenir; erase/restore/install aynı veri işlemi kilidini kullanır.
- Geri yükleme kaydedilmemiş değişiklikleri uyarır ve "Önce kaydet" sunar; kilit sırasında `save`/`setDataRoot` reddedilir.

### 49.6 Sessiz hata düzeltmeleri (v3.1)
- Otomatik yedek başarısızsa gün işareti geri alınır, hata Ayarlar'da gösterilir ve sonraki açılışta yeniden denenir.
- Bildirim yalnız gerçekten gönderildiyse "bildirildi" işaretlenir; izin reddi Ayarlar'da uyarır; başarısız gönderim dedupe'a girmez.
- Sürüm düşürme sonrası yeniden başlatma hatası banner'da yerelleştirilmiş metin + "Yeniden başlat" ile gösterilir; `restoreOffer` yalnız başarılı relaunch'ta temizlenir.
- Yönetici onayı iptali `cancelledByUser`, osascript başlatma hatası `adminPromptFailed` olarak ayrılır.
- Watch-state ve metrik yazma hataları sessiz kalmaz; ilgili ekranlarda durum satırı gösterilir.

### 49.7 Hardening (v3.2)
- **Arka plan:** geri yükleme öncesi/sonrası yedek ve geri yükleme adımları ana thread dışında; arayüz adım gösterir ("yedekleniyor", "geri yükleniyor").
- **Alt süreçler:** güncelleme komutlarında 120 sn sınır; süre/iptalde `terminate` + gerekirse `SIGKILL`; `cancelled`/`processTimedOut` ayrı hata; indirilen dosyalar temizlenir.
- **Gatekeeper:** kurulum öncesi `spctl -a -vv -t exec`; `accepted` yoksa `gatekeeperRejected`.
- **Yedek doğrulama:** sayaçlar ve kayıt tarihi dosyalardan yeniden hesaplanır; manifest uyuşmazsa yedek reddedilir. Budama mtime ile; yeni yedek asla silinmez. Tüm veri okunamıyorsa `noUsableData`.
- **Ayar arşivi:** `autoBackupEnabled` dahil; eski arşivler uyumlu.
- **Ayar import:** veri işlemi kilidi; `dataRoot` yalnız var olan dizin ve güvenli yol; sonuçta geçersiz/atlanan sayıları, veri kökü ve launch-at-login yan etkileri.
- **Güncelleme UI:** eşleşmeyen hazır indirme silinir; veri işlemi sürerken onay penceresi nedeni gösterip Yükle'yi devre dışı bırakır. Sürüm düşürme tercih yedeği arka planda.

### 49.8 Doğrulama sıkılaştırma (v3.3)
- **Ayar import / veri kökü:** yol mutlak, `..` yok, `/` değil; karşılaştırma `standardizedFileURL` + **`resolvingSymlinksInPath()`** ile ( `/var` ↔ `/private/var` eşdeğer). Önizlemede var olmayan/dizin olmayan yol **geçersiz** olarak işaretlenir; uygulama anında da reddedilir.
- **Gatekeeper:** `spctl -a -vv -t exec` çıktısında `accepted` **ve** `Notarized Developer ID` birlikte aranır; eksikse `gatekeeperRejected`.

## 51. CLI güncelleme (v3.3)
- `playeridentityctl update --check [--json]`: GitHub feed'den yeni sürüm var mı; sürüm/URL/asset/sha özeti; çıkış 0 (güncel), 4 (güncelleme var).
- `playeridentityctl update --install [--yes] [--json]`: aynı doğrulama zinciri (HTTPS, boyut, SHA-256, imza/team/bundle/sürüm, Gatekeeper), uygulamayı değiştirir; `--yes` yoksa onay ister (TTY yoksa reddeder). Sonuç JSON: `from`, `to`, `installed`, `relaunchRequired`.
- Ortak `UpdateInstaller`; CLI, uygulamanın çalıştığı bundle'ı değiştirebilir; değişim sonrası `open` ile yeni sürüm başlatılmaz (çağıran yapar).
- Çıkış kodları: 0 başarı, 1 kullanım, 2 ağ/indirme/doğrulama hatası, 3 güncelleme yok/atlandı, 4 güncelleme var (check).
- Testler: feed/check JSON, `--install` sahte installer ile, onay reddi, doğrulama hatası, çıkış kodları.

## 52. CLI genişletme (v3.4)
- `playeridentityctl backup [--out <path>] [--json]` — tam yedek; varsayılan `~/Documents` altında `playeridentity-backup-*.zip`.
- `restore <zip> [--yes] [--json]` — önce pre-restore yedeği; TTY yoksa `--yes` zorunlu; doğrulama hataları çıkış 2.
- `servers list [--json]`, `servers add <host:port> [--label] [--group] [--watch] [--json]`, `servers remove <host:port|index> [--yes] [--json]`.
- `diagnostics [--out <path>] [--json]` — redakte ZIP.
- Tümü aynı Core; JSON `schemaVersion: 1`; çıkış kodları: 0 başarı, 1 kullanım/onay, 2 doğrulama/ağ, 3 bulunamadı/güncel.

## 53. URL şeması (v3.4)
- `CFBundleURLTypes`: `playeridentity`.
- `playeridentity://add?host=example.com&port=27015&label=Demo&group=EU&watch=1`; `host` birden çok kez verilebilir.
- Doğrulama mevcut import kurallarıyla; geçersizler yok sayılır ve sonuç bildirilir; eklendikten sonra ana pencere açılır, "Kaydedilmedi".

## 54. Teşhis hataları (v3.4)
- Teşhis ZIP'ine `errors.json` eklenir: son 50 uygulama hatası (zaman, alan: update/backup/metrics/watch/login, mesaj) — **diskte kalıcı** (`errors.json`, atomik, 50 kayıt); açılışta yüklenir; dosya yoksa **boş dizi ile oluşturulur** (teşhis her zaman dosyayı içerir); IP/ev yolu redaksiyonu aynı.
- Hata kaydı kullanıcıya yeni uyarı üretmez; yalnız teşhis. Yazma hatası sessizce yutulmaz (diagnostics notu).

## 55. Erişilebilirlik ve klavye (v3.4)
- Ana pencerede tam klavye: Tab sırası, sunucu tablosunda ↑/↓ seçim, ⌘F arama, filtreler ve + menüsü klavyeyle; VoiceOver etiketleri özel çip/anahtar/grafikler için.
- Durum yalnız renkle anlatılmaz (mevcut). Yüksek kontrast görünümde tokenlar korunur; min hedef 24 pt.
- Testler: etiket kapsamı, klavye eylem eşlemeleri (saf model), kontrast oranı hesabı.

## 56. Sunucu bazlı bildirim eşikleri (v3.4)
- `ServerEntry.notifications`: `mode` (inherit/all/bansOnly/off), `pingThresholdMs`, `playersAtLeast`, `quietHoursOverride` (yok/açık/kapalı).
- Değerlendirme: genel ayarlar + sunucu override; eşik altı olay bildirilmez; geçmiş yine yazılır.
- UI: sunucu detayında "Bildirimler" bölümü; geçersiz eşikler reddedilir.
- Testler: mod/eşik/override kombinasyonları, sessiz saat, geçmiş.

## 57. CI güvenlik paketi (v3.4)
- **CodeQL (Swift):** `codeql.yml`, push/PR/haftalık; `xcodegen generate` + `xcodebuild build` (manual build) ile analiz.
- **Dependabot:** GitHub Actions sürümleri için haftalık `dependabot.yml`.
- **Secret scanning / push protection:** repo ayarlarında etkinleştirilir (API); desteklenmiyorsa README'de not.
- **Homebrew tap:** Homebrew, tap adı ile `homebrew-<ad>` repo adının eşleşmesini zorunlu kılar; bu yüzden ana repo tap olarak kullanılamaz. `ercanatay/homebrew-tap` ayrı ve zorunludur. Release'te otomatik sync için `TAP_DEPLOY_KEY` (deploy key, write) veya `TAP_TOKEN` gerekir; yoksa manuel script `scripts/sync-tap.sh` ile yapılır.
- **Release bütünlüğü:** release işi, cask'taki `version`/`sha256` ile yayınlanan asset'in `SHA256SUMS.txt` değerini karşılaştırır; uyuşmazsa job **fail** (mevcut `continue-on-error` yalnız cask commit'i için).
- **Doğrulama:** YAML lint; cask/asset karşılaştırma adımının kuru çalıştırması.

## 58. Doğrulama ve yedek düzeltmeleri (v3.7)
- **58.1 Güncelleme imza doğrulaması:** `spctl -a -vv -t exec` sonucu tek başına yeterli sayılmaz.
  - Kabul: çıkış 0 **ve** `accepted` satırı **ve** `Notarized Developer ID` kaynağı.
  - `spctl` çalıştırılamıyor/hata veriyorsa (ör. araç yok, kısıtlı ortam) doğrulama **`codesign --verify --deep --strict` + TeamIdentifier + Identifier + sürüm** kontrolüne düşer; bu durum teşhis kaydına `spctlUnavailable` olarak yazılır ve kullanıcıya bilgi verilir.
  - Çıktı ayrıştırması satır sonu türünden (`\n`, `\r\n`) ve baştaki/sondaki boşluktan bağımsızdır; `notarized` bilgisi büyük/küçük harf duyarsız aranır.
  - `rejected` **hiçbir** koşulda kabul edilmez.
- **58.2 Güncelleme öncesi veri yedeği:** okunamayan dosya yedeğe girmezse yedek **`partial`** işaretlenir.
  - Sonuç: `skippedCount`, ilk 5 atlanan yol (redakte) ve neden.
  - Kullanıcıya uyarı gösterilir ("N dosya yedeklenemedi"); güncelleme ancak kullanıcı onaylarsa sürer; onay yoksa güncelleme iptal edilir ve uygulama değişmez.
  - `partial` yedek otomatik temizlikte en eski olarak önce silinir (5 dosya sınırı korunur).
- **58.3 İçe aktarma önizlemesi (`dataRoot`):** önizleme ile uygulama **aynı** sonucu vermelidir.
  - Geçersiz/erişilemeyen `dataRoot` önizlemede "uygulanamaz" olarak işaretlenir ve uygulanacak değişiklik sayısına **eklenmez**.
  - Uygulama sırasında bu alan sessizce atlanmaz; sonuç raporunda `skippedFields: ["dataRoot"]` olarak görünür.
  - Aynı yol (`~` genişletmesi ve sembolik bağ hariç) değişiklik sayılmaz.

## 59. Ban listesi URL şablonu kitaplığı (v3.7)
- Sunucu detayındaki "Ban list" alanı için **hazır şablonlar**: `SourceBans++`, `AMXBans`, `HLstatsX`, `Generic (CID)`, `Generic (IP)`.
- Her şablon: ad, açıklama, `https://` URL kalıbı, desteklenen yer tutucular `{cid}`, `{ip}`, `{host}`, `{port}`.
- Doğrulama: yalnız `https`; en az bir yer tutucu; boşluk yok; 2048 karakter sınırı. Geçersiz kalıp kaydedilmez, hata satırı gösterilir.
- Kullanıcı şablonu düzenleyebilir; seçim sunucuya özel saklanır, "Tüm sunuculara uygula" seçeneği vardır.
- Yer tutucular URL-encode edilir (CID hex olduğu için değişmez, host için gerekli).
- Testler: şablon doğrulama, yer tutucu doldurma/encode, sunucuya özel saklama, toplu uygulama, geçersiz kalıp reddi.

## 60. Menü çubuğu hızlı CID (v3.7)
- Menü çubuğu menüsünün üstünde durum satırı: genel durum + son kontrol saati; altında **"CID'yi kopyala"** (seçili/ilk sunucu) ve **"Ham kimliği kopyala"**.
- Sunucu alt menüsü: her sunucu için "CID'yi kopyala" ve "Yeniden kontrol et".
- Kopyalama sonrası menüde 2 sn "Kopyalandı" onayı; pano hatası sessiz yutulmaz, menüde hata satırı görünür.
- Menü çubuğu kapalıyken bu öğeler görünmez; ana pencere davranışı değişmez.
- Testler: menü modeli (öğe varlığı/sırası), CID kaynağı seçimi, kopyalama sonucu, hata durumu.

## 61. Çoklu profil (v3.7)
- Profil = `{id, name, dataRoot, gamedir, createdAt}`; `profile.json` içinde `profiles: [Profile]` + `activeProfileID`.
- Varsayılan profil, mevcut tek `dataRoot`/`gamedir` değerlerinden **göç** eder (ilk açılışta `Default`).
- Geçiş: ana pencerede profil seçici (araç çubuğu) + Ayarlar > Veri bölümünde profil listesi (ekle, yeniden adlandır, sil, varsayılan yap).
- Aktif profil değişince: kimlik kaynağı, gamedir, data root yeniden çözülür; CID'ler yeniden hesaplanır; **sunucu listesi ortaktır** (profile bağlı değildir) ve geçmiş/metrikler profil kimliğiyle etiketlenir.
- Silme: en az bir profil kalmalı; aktif profil silinirse varsayılana dönülür; silme onay ister ve geri alınamaz.
- Aynı `dataRoot`+`gamedir` kombinasyonu ikinci kez eklenemez (uyarı).
- Oyun çalışırken profil değişimi salt-okunur uyarısıyla engellenir (config yazımı riski).
- Testler: göç, ekle/adlandır/sil/varsayılan, aktif profil kalıcılığı, yeniden hesaplama, silme sınırı, yinelenen kombinasyon, oyun çalışırken engel.

## 62. Çok dilli arayüz — cybokron.com dil seti (v3.8)
- **Desteklenen diller (24):** `tr` (Türkçe), `en` (English) + cybokron.com ile aynı 22 dil:
  `de, fr, es, it, pt, nl, sv, pl, cs, ro, hu, el, bg, uk, ru, ar, fa, hi, zh-Hans, ja, ko, id`.
- **Kaynaklar:** her dil için `PlayerIdentity/Resources/<code>.lproj/Localizable.strings` ve `InfoPlist.strings`.
  - `Localizable.strings` anahtar kümesi **`en` ile birebir aynı** olmalı (857 anahtar); eksik/fazla anahtar kapıda hata.
  - `InfoPlist.strings` ürün adı: `tr` → "Cybokron Oyuncu Kimlik Kartı", diğer tüm diller → "Cybokron Player Identity".
- **Dil seçimi:** Ayarlar > Dil listesi `System` + 24 dil, **yerel adlarıyla** (Deutsch, Français, …). Sistem dili desteklenmiyorsa `en`.
- **Eksik çeviri davranışı:** anahtar bulunamazsa `en` değerine düşer; `%@`/`%d`/`%1$@` gibi biçim belirteçleri korunur; çeviri metinleri **literal** olarak koda gömülmez.
- **RTL:** `ar`, `fa` için arayüz yönü sistemden gelir (SwiftUI leading/trailing); ikon/ok yönü çevrilmez, metinler çevrilir.
- **Biçimlendirme:** sayı/tarih/saat sistem yerelinden; uygulama kendi biçim kalıbını dayatmaz.
- **Çeviri yöntemi (§62.1):** her dil **tek çağrıda**, o dilin tam sözlüğüyle çevrilir (dil başına bir ajan, <100.000 token). Terim sözlüğü sabittir: `ban`, `CID`, `appeal`→itiraz, `watch`→izle vb. Kodlayıcı ajanlara çeviri yaptırılmaz.
- **Testler:** (a) 24 dilde anahtar eşitliği, (b) biçim belirteci sayısı eşitliği, (c) boş değer yok, (d) literal taraması, (e) desteklenmeyen sistem dili → `en` düşüşü, (f) dil değişiminin çalışma anında uygulanması.

## 63. l10n araç zinciri — 24 dil (v3.9)
- **Tek kaynak:** `tools/l10n_keys.py` anahtar listesini ve `tr`/`en` değerlerini tutar; diğer 22 dil `tools/l10n/<dil>.json` dosyalarında (`{ "anahtar": "değer" }`) saklanır.
- **Üretim (varsayılan):** `python3 tools/l10n_keys.py` → 24 `.lproj/Localizable.strings` dosyasını **deterministik** üretir (anahtar sırası sabit, UTF-8, tek satır başlık yorumu). Mevcut çeviriler korunur.
- **`--check`:** hiçbir dosya yazmaz; eksik/fazla anahtar veya boş değer varsa **çıkış 1** ve `dil: anahtar` listesi; temizse `OK`.
- **`--add "<anahtar>" --en "<metin>" --tr "<metin>"`:** anahtarı kaynağa ekler; 22 dilde eksikse **`en` değeri yer tutucu** olarak yazılır ve "çevrilecek" olarak raporlanır (build kırılmaz, parity kapısı geçer).
- **Göç:** mevcut 24 `.lproj` dosyası birebir korunur; ilk üretim sonrası `git diff` yalnız sıra/başlık farkı üretebilir, **değer kaybı olmaz**. Göç testi bunu doğrular.
- **CI kapısı:** `ci.yml` içinde `tools/check-l10n-parity.sh` ve `python3 tools/l10n_keys.py --check` adımları; hata → iş başarısız.
- **Testler:** (a) `--check` temiz/eksik, (b) göç eşitliği (24 dosya, değerler aynı), (c) determinizm (iki üretim aynı bayt), (d) `--add` sonrası 24 dosyada anahtar var ve diğer dillerde `en` yer tutucu, (e) biçim belirteçleri korunur.

## 64. Bağlantı teşhisi — "motorun söylemediğini söyle" (v4.0)
Amaç: oyuncu "sunucuya bağlanamıyorum" dediğinde motorun sessiz kaldığı yerde **adım adım kanıt** ve **sade dille hüküm** üretmek. Uygulama motoru değiştirmez, oyun dosyalarına yazmaz; yalnız okur ve kendi UDP/HTTP sondaylarını kullanır.

### 64.1 Sonda dizisi
Bir sunucu için sırayla çalışır; her adım kaydedilir: `step`, `status` (`ok`/`failed`/`skipped`), `durationMs`, `target`, `detail`. Adımlar:
1. **DNS** — host → IP (IPv4 öncelikli, yoksa IPv6). Başarısızsa sonraki adımlar `skipped`.
2. **A2S_INFO** — UDP ulaşılabilirlik + sunucu adı/harita/oyuncu/ping.
3. **getchallenge** — IP ban / erişim yanıtı (motorun `connect` öncesi adımı).
4. **connect (protocol 49)** — CID ban sorgusu.
5. **Sınıflandırma** — aşağıdaki hüküm tablosuna göre tek sonuç.
Zaman aşımı adım başına **5 sn**, toplam **20 sn**; iptal edilebilir. Sonuç diske yalnız **geçmiş** olarak yazılır (`diagnose` olayı), sunucu kaydı değişmez.

### 64.2 Hükümler ve önerilen eylem
| hüküm | anlam | öneri |
|---|---|---|
| `serverOffline` | A2S yanıtı yok / port kapalı | sunucu adresi ve saati kontrol et, sonra tekrar dene |
| `dnsFailure` | host çözülemedi | yazımı düzelt, DNS/VPN değiştir |
| `timeout` | yanıt yok ama DNS doğru | güvenlik duvarı/VPN, farklı ağ dene |
| `protocolMismatch` | GoldSrc 48 — CID sorgusu yok | "CID testi bu sunucuda yapılamaz"; IP ban yine geçerli |
| `ipBanned` | getchallenge "banned" | unban mesajı, IP yenile, VPN |
| `cidBanned` | connect 49 CID banı | unban mesajı (CID + saat), admin iletişimi |
| `rangeBanned` | IP `/24` veya `/16` aralığında ban | ağ değiştir (mobil hotspot/VPN), admin unban |
| `cidUnverified` | 49 destekleniyor ama yanıt belirsiz | birkaç dakika sonra yeniden dene |
| `vpnConflict` | VPN çıkışı ile CID sunucusu uyuşmuyor | VPN'i kapat/aç ve tekrar dene |
| `checksDisabled` | ban kontrolü kapalı | ayarı aç |

Hüküm **tek** olur; kanıt adımları ayrıca gösterilir. "Ban yok" sonucu yalnız adım 2–4 `ok` ise verilir.

### 64.3 Motor günlüğü (read-only)
- Kaynak: `<data root>/<gamedir>/qconsole.log` (Xash3D `-condebug`), yoksa `console.log`; **en çok son 512 KB** okunur.
- Son 200 satır taranır; bilinen kalıplar: `Couldn't connect`, `Server is not responding`, `Bad challenge`, `host_error`, `NET_SendPacket ERROR`, `Connection reset`, `Invalid CD key`, `Your IP is banned`, `You have been banned` — eşleşme → `pattern`, `matchedAt`, ham satır (redakte) ve sade açıklama.
- Günlük yoksa: `engineLog: "missing"` + "Xash3D'yi `-condebug` ile çalıştırın" ipucu. Günlük okunamıyorsa `unreadable`; dosya **hiç yazılmaz**.
- Günlük kanıtı hükmü **ezmez**; hüküm sonda dizisinden gelir, günlük yalnız ek kanıttır. Sonda `serverOffline` ama günlükte `Your IP is banned` varsa hüküm `ipBanned` olur (günlük öncelikli, çünkü doğrudan motorun sözü).

### 64.4 Arayüz
- Sunucu detayında **"Bağlantıyı teşhis et"** düğmesi (⌘D kısayolu). Çalışırken adımlar canlı işaretlenir (spinner → ✅/❌/⏭).
- Sonuç: hüküm kartı (renk + ikon + tek cümle) → adım listesi (süre, hedef, ayrıntı) → motor günlüğü eşleşmeleri → eylem düğmeleri: **Unban mesajını kopyala**, **Sunucu sayfasını aç**, **Yeniden dene**, **Teşhisi kopyala**, **Raporu kaydet…**.
- Hüküm ve adımlar VoiceOver ile okunur (etiket + değer); 24 dilde yerelleştirilir.

### 64.5 Paylaşılabilir rapor
- Markdown üretir: başlık (uygulama sürümü, tarih, sunucu `host:port`), hüküm, adım tablosu, motor günlüğü eşleşmeleri, CID/IP (varsayılan **maskeli**: CID ilk 8…son 4, IP `/24`).
- "Maskesiz" seçeneği yalnız onay ile; varsayılan maskeli.
- Panoya kopyalama + `.md` dosyasına kaydetme; dosya adı `playeridentity-diagnose-<host>-<zaman>.md`.

### 64.6 Testler
(a) her adım ve her hüküm için sentetik UDP/HTTP yanıtları, (b) süre/aşama sırası, (c) günlük kalıp eşleşmeleri + eksik/okunamaz günlük, (d) günlük önceliği, (e) rapor maskesi (CID/IP), (f) 24 dilde yeni anahtarların eşitliği (parity), (g) ağ yok — tüm testler sahte taşıyıcı.

### 64.7 Sınırlar
- Uygulama **hiçbir banı kaldırmaz**; hükümler yalnız sunucu yanıtı ve motor günlüğüne dayanır, tahmin edilmez.
- Motor günlüğü kapalıysa teşhis yine çalışır (yalnız sonda katmanı).
- Yeni anahtarlar §63 akışıyla eklenir: `l10n_keys.py --add` → 22 dilde `en` yer tutucu → dil başına tek çevirmen çağrısı.

## 65. Teşhis trendi ve menü çubuğundan teşhis (v4.1)
### 65.1 Sunucuya özel trend
- Kaynak: geçmişteki `diagnose` olayları (ek depolama yok; türetilir).
- Pencere seçimi: **7 gün**, **30 gün**, **tümü**; varsayılan 7 gün.
- Sunucu detayındaki teşhis bölümünde özet: `runs`, son çalışma zamanı, hüküm başına sayı (yalnız sıfırdan büyük olanlar), **son 10 çalışmanın** renkli şeridi (yeşil = ban yok, kırmızı = ban, turuncu = belirsiz/hata).
- Boş durum: "Bu sunucu için henüz teşhis yok" + teşhisi başlat düğmesi.
- Trend, teşhis sonucunu **değiştirmez**; yalnız geçmişi özetler.

### 65.2 Menü çubuğundan teşhis
- Sunucu alt menüsüne **"Teşhis et"** öğesi (mevcut "CID'yi kopyala" / "Yeniden kontrol et" yanına).
- Çalışırken menüde sunucu satırında `teşhis sürüyor…` (en çok 20 sn; sonuç gelince otomatik güncellenir, menü açıkken de metin yenilenir).
- Sonuç menüde tek satır: hüküm + süre (ör. `CID ban · 1,2 sn`); hüküm `ipBanned`/`cidBanned`/`rangeBanned` ise ve bildirimler açıksa **tek bildirim** (sessiz saat ve sunucu eşikleri geçerli).
- Teşhis geçmişe yazılır (§64 ile aynı olay); sunucu kaydı değişmez.
- Menü çubuğu kapalıyken öğe yok; ana pencere davranışı değişmez.

### 65.3 Testler
(a) pencere filtreleri (7/30/tümü) ve saat sınırları, (b) hüküm sayımı ve şerit sırası, (c) boş durum, (d) menü modeli: öğe varlığı/sırası, "sürüyor" durumu, sonuç satırı, (e) bildirim yalnız ban hükümlerinde ve sessiz saat/eşiklerle, (f) ağ yok — sahte taşıyıcı, (g) 24 dilde yeni anahtarların eşitliği.

## 66. Teşhisin devamı (v4.2)
### 66.1 Ban matrisinde teşhis trendi
- Ban matrisine **"Son 7 gün"** kolonu eklenir: o sunucudaki son 7 günün teşhis özeti — toplam çalışma + baskın hüküm kısaltması (ör. `3 · CID ban`); çalışma yoksa `—`.
- Sıralama ve CSV kopyalama bu kolonu içerir; kolon dar pencerede gizlenebilir (mevcut davranış), geniş pencerede görünür.
- Veri §65 trendinden türetilir; ek depolama yok.

### 66.2 Aralık banı uyarısı
- Teşhis hükmü `rangeBanned` olduğunda hüküm kartı ek bir açıklama ve **"Ağı değiştir"** ipucu gösterir: IP yenilemenin yetmediği, `/24` veya `/16` aralığının engellendiği, mobil hotspot ya da farklı çıkışlı VPN gerektiği.
- Bildirim: `rangeBanned` için metin "Aralık banı algılandı — ağı değiştirin" + **"Unban mesajını kopyala"** eylemi (kullanıcı bildirime dokununca sunucu detayı açılır ve mesaj panoya kopyalanmaz; eylem düğmesi varsa doğrudan kopyalar).
- Aynı çalışma için tek bildirim; sessiz saat ve sunucu ayarları geçerli.

### 66.3 Rapor içinde trend
- Paylaşılabilir Markdown raporu, teşhis bölümünün altına **"History (last 10 runs)"** tablosu ekler: zaman, hüküm, süre.
- Maskeleme kuralları aynı (CID/IP maskeli); trend tablosu kişisel veri içermez.
- Rapor başlığına pencere bilgisi yazılır (7/30 gün seçimi).

### 66.4 Kısayollar / Siri
- App Intents: **"Diagnose Server"** (sunucu seçimi; sonuç döner) ve **"Copy Diagnosis Report"** (son teşhisin maskeli raporunu panoya kopyalar).
- Parametreler: sunucu (`host:port` veya kayıtlı sunucu seçimi), maskeleme (varsayılan açık), pencere (7/30/tümü — yalnız rapor için).
- Sonuç: kısa metin (hüküm + süre) ve hata durumunda açık mesaj; ağ yoksa hata.
- Intents 24 dilde yerelleştirilir; Kısayollar uygulamasında görünmesi için uygulama bir kez açılmalıdır (dokümanda not).

### 66.5 Testler
(a) ban matrisi kolonu (dolu/boş, dar pencere, CSV), (b) `rangeBanned` kart metni + bildirim + eylem, (c) rapor trend tablosu + maskeleme + pencere başlığı, (d) intents parametreleri ve sonuç metni, (e) 24 dilde anahtar eşitliği, (f) ağ yok.

## 62.1 Siri / Kısayollar cümleleri (v4.3)
- App Intents cümleleri de **24 dilde** yerelleştirilir: `tools/l10n/shortcuts/<dil>.json` → `<dil>.lproj/AppShortcuts.strings`.
- Her cümlede `${applicationName}` **tam bir kez** bulunur; `--check` bunu denetler.
- `InfoPlist.strings` 24 dilde üretilir (ürün adı kuralı §62'deki gibi).
- Eksik/boş/fazla anahtar veya `${applicationName}` ihlali → `l10n_keys.py --check` çıkış 1.

## 63.1 Geçmiş yazma serileştirmesi (v4.3)
- `history.jsonl` üzerindeki `load`, `append`, `compact` işlemleri **tek seri kuyrukta** çalışır; eşzamanlı `refresh()` ve ekleme sırasında satır kaybı olmaz.
- Regresyon testleri: eşzamanlı 200 ekleme + 40 compact sonrası tüm satırlar korunur; `refresh()` sürerken eklenen satırlar korunur.

## 62.2 Dil seti cybokron.com ile tam eşleşir — 26 dil (v4.4)
- Site 26 dil yayınlıyor; uygulama da **26 dil** olur: mevcut 24 + **`az`** (Azərbaycanca) + **`vi`** (Tiếng Việt).
- Yeni diller için `Localizable.strings` (977 anahtar), `AppShortcuts.strings` (10 cümle) ve `InfoPlist.strings` üretilir; `az`/`vi` için ürün adı "Cybokron Player Identity".
- `tools/l10n/az.json` + `tools/l10n/vi.json` ve `tools/l10n/shortcuts/az.json` + `.../vi.json` kaynakları eklenir; önce `en` yer tutucu, sonra dil başına tek çevirmen çağrısı.
- `CFBundleLocalizations`, Ayarlar dil listesi, `--check`, parity ve testler 26 dili kapsar.

## 67. Sprint 1 — otomasyon ve macOS entegrasyonu (v4.5)
### 67.1 CLI: `diagnose`, `trend`, `report`
- `playeridentityctl diagnose <host:port|index> [--timeout <sn>] [--json] [--fail-on-ban]`:
  - §64 sonda dizisini çalıştırır; metin çıktısı: hüküm + adımlar (süre/hedef) + günlük eşleşmeleri.
  - `--json`: `schemaVersion: 1`, `verdict`, `steps[]`, `engineLog`, `server{host,port}`.
  - Çıkış kodları: **0** başarı (ban olsa da), **4** yalnız `--fail-on-ban` ile ban hükmünde, **1** kullanım, **2** ağ/doğrulama, **3** sunucu bulunamadı.
- `playeridentityctl trend <host:port|index> [--days 7|30|all] [--json]`: çalışma sayısı, hüküm sayıları, son 10 şerit; `--json` aynı alanları taşır; veri yoksa **0** + boş sonuç.
- `playeridentityctl report <host:port|index> [--days …] [--unmasked] [--out <path>|-]`: §64.5 Markdown raporu; varsayılan maskeli; `--out -` stdout.
- Tümü Core'u kullanır; ağ yalnız `diagnose`'da.

### 67.2 `-condebug` başlatıcı
- Teşhis bölümünde **"Oyunu günlükle başlat"** düğmesi: Xash3D'yi `-condebug` argümanıyla açar (NSWorkspace, `/Applications/Xash3D-FWGS.app`).
- Oyun çalışıyorsa düğme pasif + açıklama; başlatma hatası kullanıcıya gösterilir ve `ErrorLog`'a yazılır.
- Başlatma sonrası 10 sn içinde `qconsole.log` oluşursa "günlük etkin" durumu; oluşmazsa yol ipucu (gamedir + dosya adı).
- Testler: sahte launcher (argüman doğrulama), oyun çalışırken engel, hata yolu, günlük tespiti.

### 67.3 Açılış özeti
- Uygulama açılışında son **7 gün** trendi taranır; bir sunucuda **≥2 ban hükmü** (`ipBanned`/`cidBanned`/`rangeBanned`) varsa ana pencerede üstte kart: "`<sunucu>`: son 7 günde `N` ban" + "Ayrıntılar" düğmesi (sunucu detayı/trend).
- Kart o gün için **kapatılabilir** (UserDefaults'ta tarih); ertesi gün yeniden değerlendirilir.
- Veri yoksa kart görünmez; hesap ağı kullanmaz.
- Testler: eşik (1 ban → kart yok, 2 ban → kart), kapatma kalıcılığı (aynı gün/ertesi gün), sunucu seçimi (en çok banlı), düğme hedefi.

### 67.4 Spotlight indeksleme
- Sunucular `CoreSpotlight` ile indekslenir: başlık = etiket (yoksa `host:port`), açıklama = `host:port · CID` (CID kısaltılmış), `domainIdentifier` sabit.
- Sunucu ekleme/adlandırma/silme ve "tüm verileri sil" indeksi günceller; indeksleme hatası sessiz yutulmaz (`ErrorLog` `spotlight` alanı).
- Spotlight sonucuna tıklama uygulamayı açar ve ilgili sunucu detayını gösterir (`NSUserActivity`/`CSSearchableItem` activity).
- Testler: ekle/güncelle/sil çağrıları (sahte indeksleyici), etiket/kısaltma biçimi, hata kaydı, açma eşlemesi.

## 68. Sprint 2 — sunucu ayrıntısı ve ban kanıtı (v4.6)
### 68.1 A2S_PLAYER ve A2S_RULES
- **A2S_PLAYER (`U`)**: sunucudaki oyuncular — `index`, `name`, `score`, `durationSec`. GoldSrc 48 baytlık yanıt; `A2S_SERVERQUERY_GETCHALLENGE` (`W`) ile challenge alınır, challenge yoksa tek yeniden deneme.
- **A2S_RULES (`V`)**: sunucu cvarları; arayüzde aranabilir liste + öne çıkanlar: `sv_password` (boş değilse **şifreli**), `sv_cheats`, `sv_lan`, `sv_region`, `mp_timelimit`, `mp_friendlyfire`, `maxplayers`/`sv_maxplayers`.
- **UI:** sunucu detayında **"Sunucu ayrıntıları"** bölümü: Oyuncular (isim/skor/süre) ve Kurallar (ilk 50 + arama). "Yenile" düğmesi; boş/hata durumları ayrı metinlerle.
- **Teşhis:** `A2S_RULES` şifre bilgisi verirse hüküm **`passwordProtected`** olur (adım `rules` `ok`); bu hüküm yalnız bağlantı reddedilirken değil, her teşhiste gösterilir. Şifre varsa "Sunucu şifreli" açıklaması ve "Şifreyi sunucu sahibinden isteyin" önerisi.
- **Sınırlar:** bu sorgular sunucuya ek paket gönderir; yalnız kullanıcı istediğinde (düğme) veya teşhis sırasında bir kez çalışır. Otomatik yenileme yok. Yanıt 4096 baytı aşarsa kısaltılır ve `truncated` işaretlenir.
- **Testler:** challenge akışı, oyuncu/kural ayrıştırma (eksik/bozuk yanıt, 0 oyuncu, 200 kural), `truncated`, şifreli hüküm, UI modeli, ağ yok.

### 68.2 Ban kaydı (JSON uç noktası)
- Sunucuya özel **ban kaydı** yapılandırması: `urlTemplate` (https, `{cid}`/`{ip}` yer tutucuları), isteğe bağlı `bearerToken` (**Keychain'de**), `enabled`.
- Uygulama HTTPS GET yapar (10 sn zaman aşımı) ve **esnek JSON** okur: kök dizi veya `bans`/`data`/`results` dizisi; alan adları esnek eşlenir: `reason`, `admin`/`adminName`, `created`/`createdAt`/`added`, `expires`/`expiresAt`/`ends`, `permanent` (bool), `playerIp`/`ip`, `playerId`/`steamId`/`cid`.
- Sonuç: aktif ban sayısı, sebep, admin, başlangıç, **kalan süre** (süreliyse), kalıcı bayrağı; en yeni kayıt öne.
- **UI:** teşhis bölümünde "Ban kaydı" kartı; "Unban mesajını kopyala" metni sebep+admin+süre ile zenginleşir.
- **Hata/düşüş:** istek başarısızsa sessiz yutulmaz — kartta hata + `ErrorLog` (`banLookup`); URL şablonu (mevcut "Ban list") yedek yol olarak kalır.
- **Gizlilik:** token ve yanıt gövdeleri teşhis raporuna **yazılmaz**; raporda yalnız "ban record: 1 active" gibi özet.
- **Testler:** alan eşleme varyantları, dizi kökleri, süre hesabı (kalıcı/süreli/geçmiş), 401/404/zaman aşımı hata yolu, Keychain'e yazma/okuma (sahte), raporda sızıntı yok.

### 68.3 VPN gerçeği kartı
- Teşhis hükmü `cidBanned`/`rangeBanned` ve çıkışta VPN etkinse kart: **"VPN değiştirmek CID banını çözmez"** — CID sunucu adresinden türetilir, istemci IP'sinden değil; yalnız IP banında VPN/çıkış değişimi işe yarar.
- `ipBanned` ve VPN etkinse: "VPN çıkışını değiştirmek yardımcı olabilir" + mevcut "Unban mesajını kopyala".
- Kart yalnız ilgili hükümlerde görünür; statik yardım metni teşhis bölümünde her zaman erişilebilir.
- **Testler:** hüküm × VPN durumu matrisi (4 kombinasyon), kart metni, yardım bağlantısı.

## 69. Sprint 3 — ban bitişi ve widget (v4.7)
### 69.1 Ban bitiş bildirimi
- Kaynak: §68.2 ban kaydı (yalnız `expires` bilinen ve gelecekte olan süreli banlar).
- Kayıt başına **tek** bildirim: bitişten **10 dakika önce** "Ban 10 dakika içinde kalkıyor" ve bitişte "Ban kalktı" (ikisi tek bildirimde birleşmez; yalnız bitiş anı bildirimi zorunlu, "10 dk önce" ayarla kapatılabilir).
- Kalıcılık: `profile.json` içinde `banExpiryWatch: [{serverID, cid, expiresAt, notifiedAt, kind}]`; uygulama kapalıyken bildirim **kurulmaz** (zamanlanmış yerel bildirim kullanılmaz), açılışta ve her başarılı ban kaydı sorgusunda yeniden planlanır.
- Kurallar: bildirim ana şalteri ve ban bildirimleri açık olmalı; **sessiz saat** geçerliyse bildirim ertelenir (sessiz saat bitince bir kez); sunucuya özel bildirim modu `off` ise gönderilmez; aynı ban için tekrar bildirim yok (`notifiedAt`).
- Ban kaydı artık yoksa veya ban erken kalkmışsa izleme kaydı silinir, bildirim gönderilmez.
- UI: ban kaydı kartında **"Bitişte bildir"** anahtarı (expiry varsa varsayılan açık) + planlanan zaman; ana pencerede "yaklaşan ban bitişleri" satırı (en çok 1 gün kalanlar).
- Testler: planlama (10 dk eşiği, bitiş), sessiz saat erteleme, `off` modu, tekrar engelleme, erken kalkma/temizlik, kalıcılık (yeniden yükleme), sessiz saat sonrası tek bildirim.

### 69.2 WidgetKit widget'ı
- macOS 14 widget eklentisi (`PlayerIdentityWidget`), aileler: **small** (genel durum ikonu + kısa CID + son kontrol) ve **medium** (ilk 3 sunucu: etiket + ban durumu + ping).
- Veri paylaşımı: uygulama her yenilemeden sonra **widget anlık görüntüsü** yazar (`widget-snapshot.json`, `schemaVersion: 1`, `updatedAt`, `status`, `cidShort`, `servers[{label, host, port, ban, ping}]`); widget eklentisi bu dosyayı **salt okunur** okur. Dosya yolu App Group yerine uygulamanın kendi veri klasörüdür; eklenti sandbox'sız olduğu için aynı yolu okur (App Group gerekmez).
- Zaman çizelgesi: 15 dakikada bir `.after` yenileme; veri yoksa "Uygulamayı açın" boş durumu. Widget'tan tıklama uygulamayı açar (deep link `playeridentity://show`).
- Gizlilik: widget CID'i **kısaltılmış** gösterir; IP göstermez; dosyada IP yok.
- Paketleme: `.appex` imzalanır ve uygulama içine gömülür; `spctl`/`codesign --verify --deep` temiz olmalı; notarization tüm eklentiyi kapsar.
- Testler: anlık görüntü kodlama/çözme, eksik/bozuk dosya, timeline üretimi (boş/dolu), kısaltma biçimi, deep link.

### 69.3 Sınırlar
- Widget ağ isteği yapmaz; veri yalnız uygulama açıkken/yenilenirken güncellenir.
- Bildirimler yalnız uygulama açılışında planlanır; uygulama tamamen kapalıyken ban bitişi bildirimi garanti edilmez (spec gereği zamanlanmış bildirim kullanılmıyor). Bu sınır dokümanda belirtilir.

## 70. Sunucu tarayıcı — GoldSrc master (v4.8)
### 70.1 Master sorgusu
- Kaynak: `hl1master.steampowered.com:27010` (ayarlanabilir; yedek `hl2master.steampowered.com:27011` yok — GoldSrc için yalnız hl1).
- İstek: `0x31 0xFF "<son IP>:<port>" 0x00`; ilk istek `0.0.0.0:0`; yanıt `0xFF 0xFF 0xFF 0xFF 0x66 0x0A` + **6 baytlık** (IP×4 + port×2, big-endian) kayıtlar.
- Sayfalama: son kaydın IP:port'u bir sonraki istekte kullanılır; boş yanıt veya tekrar eden son adres → dur.
- Sınırlar: istek başına 2 sn, toplam **30 sn**, en çok **5.000** sunucu adresi; kullanıcı iptal edebilir. Sonuç önbelleğe alınır (5 dk) ve diskte `master-cache.json` (24 saat, adresler yalnız).
- Hata: DNS/ağ/zaman aşımı → açık mesaj + tekrar dene; boş liste → "Sunucu bulunamadı".

### 70.2 Sunucu bilgisi toplama
- Master listesinden adresler alındıktan sonra **A2S_INFO** ile paralel sorgu: eşzamanlılık **20**, sunucu başına 2 sn, toplam 20 sn; yanıtsızlar elenir.
- Toplanan: isim, harita, oyuncu (`players/max`), ping, şifreli mi (A2S_INFO `visibility` alanı varsa), ülke yok.
- Filtreler: **harita** (içerir), **isim** (içerir), **oyuncu ≥ N**, **boş değil**, **şifresiz**, **ping ≤ N ms**; sıralama: oyuncu, ping, isim.
- Sonuç listesi en çok **300** satır gösterir (fazlası "filtreyi daraltın").

### 70.3 Arayüz
- Ana pencerede **"Sunucu bul"** düğmesi → ayrı pencere (`⌘B`): ilerleme (kaç adres / kaç yanıt), iptal, filtre çubuğu, tablo (isim, harita, oyuncu, ping, şifre), alt bilgi.
- Satır eylemleri: **"Ekle"** (listeye ekler, "Kaydedilmedi"), **"Teşhis et"** (mevcut teşhis akışı), **"Yenile"**.
- Zaten kayıtlı sunucu `host:port` eşleşmesiyle "Eklendi" olarak işaretlenir; ekleme yinelenen kayıt oluşturmaz.
- Boş/hata/iptal durumları ayrı metinlerle; VoiceOver etiketleri.

### 70.4 Gizlilik ve sınırlar
- Sorgular doğrudan üçüncü taraf sunuculara gider; telemetri yok; master yanıtı ve A2S yanıtları kalıcı saklanmaz (yalnız 5 dk bellek, 24 saat adres önbelleği).
- Master listesi zaman zaman kararsız; uygulama bunu "liste eksik olabilir" notuyla belirtir.
- Tarayıcı yalnız GoldSrc sunucularını hedefler; Source filtreleri yok.

### 70.5 Testler
(a) master istek kodlama/çözme, sayfalama, boş/tekrar eden yanıt, 5.000 sınırı, iptal; (b) A2S_INFO toplama (eşzamanlılık sınırı, yanıtsız eleme, süre); (c) filtre/sıralama matrisi; (d) ekleme/yinelenen/teşhis eylemleri; (e) önbellek (bellek 5 dk, disk 24 saat) ve bozuk dosya; (f) 26 dilde anahtar eşitliği; (g) ağ yok — sahte taşıyıcı.

## 71. Klasör tabanlı senkron (v4.9)
CloudKit/App Group yerine **kullanıcı seçimli klasör** (iCloud Drive, ağ diski, USB) üzerinden senkron. Sunucu, hesap veya entitlement gerekmez; dosya kullanıcının kendi bulutunda durur.

### 71.1 Kapsam ve biçim
- Dosya: `<sync klasörü>/playeridentity-sync.json` (`schemaVersion: 1`).
- İçerik: `deviceID`, `updatedAt`, `profiles[]`, `servers[]`, `watched[]`, `settings` (yalnız: dil, bildirim tercihleri, sessiz saat, görünüm), `notes[]` (sunucu notları/itirazlar).
- **Asla yazılmaz:** ban listesi token'ı, RCON parolası, teşhis geçmişi, metrikler, CID/parola gibi sırlar. Dosya düz JSON'dur; kullanıcıya bu uyarı gösterilir.
- Her kayıtta `updatedAt` + `deletedAt` (tombstone); birleştirme **kayıt bazında son yazan kazanır**, silme de senkronlanır.

### 71.2 Davranış
- Ayarlar > Veri > **"Senkron klasörü"**: seç / kaldır / "Şimdi senkronla".
- Senkron anları: uygulama açılışı (gecikmeli), her kayıttan sonra 5 sn debounce, "Şimdi senkronla", uygulama kapanışı (en çok 2 sn).
- Birleştirme: yerel + uzak kayıtlar `id` ile eşlenir; `updatedAt` yeni olan kazanır; yalnız yerelde olan eklenir; tombstone varsa iki tarafta da silinir. Aynı `updatedAt` ile farklı içerik → yerel kazanır ve çakışma sayacı artar.
- Hata: klasör yok/erişilemez/JSON bozuk → senkron durur, açık hata + `ErrorLog` (`sync`), yerel veri bozulmaz; bozuk uzak dosya **.corrupt-<zaman>** olarak yedeklenir.
- İki cihaz aynı anda yazarsa: dosya atomik yazılır (geçici + rename), okuma sonrası `updatedAt` kontrolü; çakışma durumunda ikinci geçiş yapar.

### 71.3 Gizlilik ve sınırlar
- Dosya kullanıcının seçtiği klasörde **şifrelenmemiş** durur; arayüzde bu açıkça yazar; hassas alanlar (token/parola) hiç yazılmaz.
- Senkron yalnız tek dosya; büyük geçmiş/metrik/teşhis verisi taşınmaz.
- Klasör kaldırılırsa uygulama yerel veriyle çalışmaya devam eder; uzak dosya silinmez.

### 71.4 Testler
(a) birleştirme: yeni/kopya/silme/tombstone/çakışma matrisi; (b) hassas alanların dosyaya **hiç** yazılmadığı; (c) atomik yazma ve bozuk dosya yedekleme; (d) debounce/kapanış senkronu (sahte saat); (e) klasör erişim hataları; (f) 26 dilde anahtar eşitliği.

## 72. Salt-okunur RCON (v5.0)
Amaç: sunucu sahibi/yoneticisinin ban listesini ve oyuncularını uygulamadan görebilmesi. **Yazma komutu yok.**

### 72.1 Protokol ve güvenlik
- Kaynak RCON (GoldSrc/Source, UDP): auth paketi (`id`, tip `3`, parola), cevap tipi `2` = komut çıktısı, `0` = hata; paket başlığı `size, id, type, body, 0x00 0x00`.
- Zaman aşımı: auth 3 sn, komut 3 sn, en çok 2 yeniden deneme; yanıt parçalıysa (çok paket) birleştirilir (üst sınır 64 KB).
- Parola **yalnız Keychain'de** (`rcon.<serverID>`); `profile.json`, `playeridentity-sync.json`, teşhis raporu ve loglara **asla** yazılmaz. Arayüzde "RCON düz UDP'dir, şifreleme yoktur" uyarısı.
- Sunucu bazında `rconEnabled` (varsayılan kapalı) ve `rconPort` (varsayılan 27015).

### 72.2 Komut beyaz listesi
- Yalnız şu komutlar çalıştırılabilir: `status`, `stats`, `listip`, `banlist` (varsa), `users` (varsa). Serbest metin girişi **yok**; düğmeler sabit komut gönderir.
- Bilinmeyen/başarısız komut: sunucunun ham çıktısı gösterilir, komut tekrar denenmez; `ErrorLog(rcon)` yalnız tür/HTTP benzeri durum kodu yazar (parola yok).
- Çıktı ayrıştırma: `status` → oyuncular (isim, skor, süre); `listip` → IP listesi; `banlist` → satır sayısı + ilk 50 satır; ayrıştırılamayan çıktı ham metin olarak gösterilir.

### 72.3 Arayüz
- Sunucu detayında **"Sunucu konsolu (salt okunur)"** bölümü: etkinleştirme anahtarı, port alanı, "Parolayı ayarla" (Keychain), komut düğmeleri (Status / Ban listesi / IP listesi), çıktı paneli, "Kopyala".
- Parola yoksa düğmeler pasif; hata durumunda açık mesaj (auth başarısız / zaman aşımı / sunucu RCON kapalı).
- VoiceOver etiketleri; çıktı seçilebilir metin.

### 72.4 Testler
(a) paket kodlama/çözme ve parçalı yanıt birleştirme; (b) auth başarısız/zaman aşımı/kapalı port; (c) beyaz liste dışı komut reddi; (d) Keychain'e yazma/okuma/silme (sahte), **hiçbir dosyaya/loga parola sızmaması**; (e) `status`/`listip`/`banlist` ayrıştırma; (f) 26 dilde anahtar eşitliği; (g) ağ yok — sahte taşıyıcı.

### 72.5 Sınırlar
- RCON düz UDP'dir; parola ağda açık gider. Uygulama yalnız okuma komutları gönderir; ban ekleme/kaldırma **yoktur**.
- Sunucuda RCON kapalıysa ya da parola yanlışsa özellik kullanılamaz; bu durum açıkça yazılır.

---

## 73. macOS donanım kimliği sağlığı (v5.1, uygulama 2.24.0; v5.2 = kimlik özelliği spec v2.25.0)
Amaç: kurulu Xash3D motoru kimliği Mac'in donanımından türetmediğinde ham kimlik `0` kalır ve bu motoru kullanan bütün Mac'ler her sunucuda **aynı CID'yi** paylaşır. Uygulama bu durumu açıkça gösterir, destekleme göstergesi olan motorda sıfır kimliğin onarımı için motoru açar, göstergesi olmayan motorda resmi sürüm sayfasına yönlendirir. **Rastgele kimlik üretimi/rotasyonu yoktur** ve vaat edilmez.

### 73.1 Bağlayıcı kurallar
- Uygulama `.xash_id` dosyalarını **yazmaz, silmez, düzenlemez**; motoru indirmez, güncellemez, değiştirmez, paketlemez; motoru sonlandırmaz; oyun verisine yazmaz (§1 istisnası genişlemez); ağ isteği yapmaz.
- Ham kimlik, tam CID, seri numarası hiçbir ekrana, CLI çıktısına, log'a, teşhis paketine veya panoya yazılmaz. Yalnız durum etiketi ve **maskeli CID** (ilk 4 + `…` + son 4 karakter; adres baytı olmadan, yalnız ham kimlikten türetilen yerel CID) gösterilir.
- Motor sürüm metni yalnız bilgi amaçlı raporlanır; karar girdisi değildir.
- **Doğruluk dili:** "unique/benzersiz/tekil" kesin garanti olarak kullanılmaz. Sıfır olmayan kimlik + statik donanım-kimliği göstergeleri tekillik kanıtı değildir; doğru ifade "Sıfır olmayan kimlik ve donanım-kimliği göstergeleri bulundu; tekillik doğrudan doğrulanmadı." `supported` yalnız "statik gösterge + sıfır olmayan kimlik" anlamına gelir. Kart başlığı "macOS donanım kimliği"dir.

### 73.2 Girdiler
- **Süreç durumu (P):** `running` / `notRunning` / `unavailable`. Süreç listesi alınamazsa, kesik görünürse veya hiçbir süreç adı okunamazsa `unavailable`; `unavailable` **asla** `notRunning` sayılmaz. Ayar düzenlemenin (§15.6) yazma öncesi evet/hayır süreç kontrolü değişmez (eski davranış: okunamayan liste = çalışmıyor); ancak ana pencerenin tam yenilemesi de `isGameRunning` bayrağını üç durumlu sonuçla günceller (`unavailable` bayrağı `false`'a çevirmez).
- **P her şeyden önce alınır:** uygulamada ve CLI'da süreç durumu, motor yolu geçersiz kılmasının doğrulanmasından (paket, `Info.plist`, ikililer) önce alınır. P `running`/`unavailable` iken motor paketine hiç dokunulmaz; istenen yol yalnız sözcüksel olarak normalize edilip raporlanır ("doğrulanmadı"). Ayarlar'da bu durumda seçilen yol okunmadan saklanır ve motor kapalıyken yapılan ilk kontrol doğrular (reddedilirse neden gösterilir ve loglanır).
- **Paket okunabilirliği (B):** `readable` / `unverifiable`. Motor yok, paket geçersiz, sembolik bağlantı, okunamıyor (izin, G/Ç), Mach-O değil/bozuk, 512 MB üstü, zaman aşımı veya iptal → `unverifiable`.
- **Statik destek (S):** `yes` / `no` / `unknown` (§73.3).
- **Ham kimlik (R):** `nonzero` / `zero` / `absent` / `unreadable` (§73.4).

### 73.3 Statik destek (S)
- Motor paketindeki ikili dosyalar salt okunur incelenir: `Contents/MacOS/<CFBundleExecutable>` (`Info.plist` yoksa veya özellik listesi değilse `xash3d`; `Info.plist` varsa ama okunamıyorsa paket `unverifiable`; çalıştırılabilir dosya en az bir POSIX çalıştırma bitine sahip normal dosya olmalı, yoksa "çalıştırılabilir yok") ve varsa motor kütüphanesi `Contents/MacOS/libxash.dylib` (bu adda normal dosya olmayan bir öğe — klasör, FIFO, soket — "kütüphane yok" sayılmaz, paket `unverifiable`). Kanıtlar dosyalar arasında birleştirilir. Evrensel (fat) dosyalarda her dilim taranır.
- Yalnız Mach-O başlığı, yükleme komutları, sembol dize tablosu ve C-dize bölümleri parça parça okunur; dosyanın tamamı belleğe alınmaz.
- Kanıtlar: **K1** yükleme komutlarında IOKit framework bağı; **K2** CoreFoundation framework bağı; **K3** IORegistry/IOService erişim sembolü veya dize izi; **K4** `IOPlatformSerialNumber` dizesi.
- `yes`: en az üç kanıt **ve** K4. `no`: ikili **geçerli Mach-O olarak ayrıştırıldı** ve koşul sağlanmıyor (K4'süz K1–K3 de `no`). `unknown`: B = `unverifiable`.
- **Yapısal bozukluk `no` değildir:** komut sayısı veya komut bayt toplamı 0, komut boyutu 4 bayta hizalı değil, komutlar bildirilen bayt toplamını tam doldurmuyor (eksik/fazla komut), dylib adı komut dışında, sembol/dize tablosu dilim dışında veya boş değilken 0 ofsetinde, segment dosya aralığı dilim dışında, dosya içerikli boş olmayan bir bölüm (gerçek zerofill türleri hariç) 0 ofsetinde veya dilim dışında, tanınmayan magic → `notMachO` → `unknown`. Geçerli ama ilgisiz yükleme komutları atlanır.
- İptal edilen kontrol (yeni Yenile veya CLI komutunun iptali taramayı da iptal eder) ham kimliği **okumaz**: rapor `unknown`, ham durum ve maskeli CID yok.
- Süre sınırı **monotonik saatle** 3 saniyedir (duvar saati değişimi etkisiz); her okuma (parça sınırı) öncesi ve sonrası iptal ve süre kontrol edilir; tarama sonunda bir kez daha kontrol edilir. Tek bir okuma çağrısının donması kesilemeyebilir (pratik sınır); bu durumda sonuç yine `unknown` (zaman aşımı) olur, asla sessiz başarı olmaz.
- Motor ikili dosyasının (kütüphane varsa o, yoksa çalıştırılabilir) SHA-256 değerinin ilk 12 karakteri raporlanır; motor açıkken/P bilinmezken hesaplanmaz (`null`).

### 73.4 Ham kimlik (R) ve dosya sistemi hataları
- R, §3.1 sırasındaki konumlardan ilk okunabilir ve geçerli dosyadan okunur: 16 hex + isteğe bağlı satır sonu, en çok 64 bayt.
- **Yalnız kesin yokluk (`ENOENT`) `absent`'tir.** Aday dosyanın yolunda (`~`, `~/.config`, `~/.local`, oyun klasörü veya üstleri) kullanıcı denetimli bir sembolik bağlantı varsa (fiziksel yol yazılan yolla eşleşmiyorsa) dosya izlenmez ve `unreadable` sayılır; yalnız macOS sistem takma adları (`/var`, `/tmp`, `/etc` → `/private/…`) bağlantı sayılmaz. Erişim reddi, G/Ç hatası, eskimiş tutamaç vb. her `lstat` hatası, sembolik bağlantı, klasör, okuma hatası, 64 bayt üstü veya hatalı biçim `unreadable`'dır. Bir konum `unreadable` ise ve geçerli dosya yoksa sonuç `absent` değil `unreadable`'dır.

### 73.5 Karar sırası ve tablosu
1. P = `unavailable` → `unknown` (processUnavailable); hiçbir şey taranmaz/okunmaz; yeniden oluşturma engellenir.
2. P = `running` → `unknown` (engineRunning); statik tarama ve hash **yapılmaz**, motor paketi incelenmez, ham kimlik **okunmaz**; kanıt yok/`null`, hash `null`; "motoru kapatıp Yenile'ye basın".
3. B = `unverifiable` → `unknown`; motor yoksa "Motor bulunamadı", diğerlerinde "Motor paketi doğrulanamadı". `unsupported` veya indirme önerisi **yapılmaz**.
4. Tablo (P = `notRunning`, B = `readable`):

| S | R | Durum | Eylem |
|---|---|---|---|
| yes | nonzero | `supported` (göstergeler bulundu; tekillik doğrulanmadı) | yok |
| no | nonzero | `unknown` (statik donanım-kimliği doğrulaması yok) | "Uyumlu motoru indir" önerisi |
| yes | zero | `unknown` | "Kimliği yeniden oluştur" |
| yes | absent | `unknown` (henüz üretilmemiş) | "Kimliği yeniden oluştur" |
| no | zero / absent | `unsupported` | "Uyumlu motoru indir" |
| yes / no | unreadable | `unknown` (kimlik dosyası erişilemiyor) | yok |

- `raw=0` durumu mevcut §7.2 `rawIDZero` nedeniyle uyumludur; kart ek olarak "kimliği sıfır olan tüm Mac'ler aynı CID'yi paylaşır" açıklamasını gösterir.
- Kontrol ana pencerenin her yenilemesinde ve kartın "Yenile" düğmesiyle arka planda çalışır.

### 73.6 Arayüz — "macOS donanım kimliği" kartı
- Ana pencerede Profil/Ağ satırının altında. Durum her zaman simge + etiket + metinle verilir (renk tek başına bilgi taşımaz); etiketler: "Göstergeler bulundu" / "Desteklenmiyor" / "Belirsiz" / "Kontrol ediliyor…". Maskeli CID, statik kanıt sayısı (`n/4`, yalnız tarandıysa) ve `~` ile kısaltılmış motor yolu gösterilir.
- Metinler: yes+nonzero → "Sıfır olmayan kimlik ve donanım-kimliği statik göstergeleri bulundu. Tekillik doğrudan doğrulanmadı."; no+nonzero → "Kimlik dolu (sıfır değil), ancak bu motorda statik donanım-kimliği doğrulaması yapılamadı. Uyumlu motor önerilir."; yes+zero/absent → "Kimlik henüz oluşmadı veya sıfır. Motoru açıp kapatarak yeniden oluşturabilirsiniz."; unsupported → "Kurulu motor macOS donanım kimliğini desteklemiyor. Uyumlu bir sürüm gerekli."; motor açık → "Motor açık; motor taranmadı ve kimlik okunmadı. Motoru kapatıp Yenile'ye basın."; P bilinmiyor → "Motor süreç durumu doğrulanamadı; motor taranmadı ve kimlik okunmadı. Yeniden oluşturma engellendi. …"; B doğrulanamadı → "Motor paketi doğrulanamadı. Motor yolunu ve dosya izinlerini kontrol edin."; R erişilemiyor → "Kimlik dosyası erişilemiyor (izin, G/Ç veya biçim hatası). …". `unknown` durumunda "Yenile" ve `playeridentityctl diagnose --macos-identity` yönlendirmesi gösterilir. Yasak: "yeni rastgele ID", "benzersiz kimlik (garantisi)".
- **Yenile / checking:** Yenile başlarken yeni bir nesil numarası atanır, önceki tarama iptal edilir ve kart yalnız "Kontrol ediliyor…" gösterir: önceki sonuç, notlar, ayrıntılar, eylemler ve geri bildirim **tamamen gizlenir**; checking durumu da VoiceOver'a duyurulur. Sonuç yalnız kendi nesline bağlanır; iptal edilmiş/eski neslin sonucu yayımlanmaz. Checking sırasında eylem istenemez.
- **"Uyumlu motoru indir"**: yalnız `unsupported` ve no+nonzero durumunda görünür; varsayılan tarayıcıda yalnız `https://github.com/FWGS/xash3d-fwgs/releases/tag/continuous` açılır (sabit https izin listesi). Hedef adres kartta yazılır. Açılamazsa **veya izin listesi bağlantıyı reddederse** kartta hata gösterilir ve `ErrorLog(launch)` yazılır; sessiz ret yoktur.
- **"Kimliği yeniden oluştur"**: yalnız yes+zero / yes+absent, P = `notRunning`, B = `readable` iken etkindir. Motor açıksa "Önce motoru kapatın.", P bilinmiyorsa süreç-doğrulanamadı nedeniyle devre dışıdır (VoiceOver da okur). Basılınca motor yeniden (üç durumlu) kontrol edilir, onay sorulur ("Motor açılsın mı?"), onaylanırsa motor argümansız açılır. Başarıda motor **açık kabul edilir** (`isGameRunning` = true), düğme "Önce motoru kapatın." ile devre dışı kalır ve "Motor açıldı. Motoru kapatın, sonra Yenile'ye basın." yazılır; **otomatik yenileme yapılmaz**. Kullanıcı motoru kapatıp Yenile'ye basınca rapor `notRunning` olur ve düğme yeniden etkinleşir. Başarısızlık sessiz yutulmaz: neden kartta gösterilir ve `ErrorLog(launch)` yazılır. Eylem sürerken yeni bir Yenile başlarsa eski eylemin sonucu (durum metni) yeni rapora bağlanmaz; yalnız log'a "eski" olarak yazılır. Ancak başarılı açılış (veya "motor açık" hatası) gerçek dünya bilgisidir: eski nesle ait olsa da süreç durumu `running` olarak senkronlanır.
- `isGameRunning` kimlik raporuyla senkron tutulur: rapor `running` → true, `notRunning` → false, `unavailable` → bayrak değiştirilmez ("bilinmiyor" ayrıca tutulur).
- Kartın altında sınır notu: rastgele kimlik değişimi yoktur; kimlik donanımdan türetilir, dosya silinse bile aynı Mac'te aynı kimlik yeniden oluşur.
- Erişilebilirlik: durum satırı tek VoiceOver öğesidir ("macOS donanım kimliği durumu: …"); düğmelerin ipucu ve devre dışı nedeni okunur; durum değişimi ve checking duyurulur; metinler kesilmeden sarılır; tüm eylemler klavyeyle kullanılabilir.

### 73.7 Motor yolu
- Varsayılan: `/Applications/Xash3D-FWGS.app`.
- Ayarlar > Veri > "Motor uygulaması": "Değiştir…" (yalnız `.app` seçilir) ve "Varsayılanı Kullan". Geçersiz seçim **saklanmaz**, varsayılan kullanılır; neden Ayarlar'da **ve kartta** gösterilir ve log'a yazılır. Kurallar: dizin ve `.app` uzantısı; yolda sembolik bağlantı yok (fiziksel/çözümlenmiş yol yazılan yolla aynı); `Contents/MacOS` altında çalıştırılabilir dosya var; okunamayan öğe → `unreadable` reddi; veri kökü veya `~/.config` / `~/.local` içinde değil.
- **Containment:** yasak kök kontrolü hem yazılan (sözcüksel) hem fiziksel (bağlantılar çözülmüş) yol üzerinden, adayın ve kökün her iki biçimiyle yapılır; aday bir takma ad/bağlantı ile yasak köke işaret etse de, yasak kökün kendisi bir bağlantı olsa da reddedilir.
- Paket içinde okunan hiçbir öğe sembolik bağlantı olamaz; bağlantılar izlenmez.

### 73.8 CLI
- `playeridentityctl diagnose --macos-identity [--json]` (salt okunur, ağsız, dosya yazmaz; geçmiş satırı da eklemez).
- Çıkış kodları: `0` supported, `1` unsupported, `2` unknown, `3` beklenmeyen hata (kullanım hatası her komutta olduğu gibi `1`). **Açıkça istenen motor yolu (`PLAYERIDENTITYCTL_ENGINE_APP` veya uygulama ayarı) reddedilirse**, varsayılan motor incelenip sonuç raporlansa bile çıkış `0` olmaz; en az `2`.
- JSON alanları: `state`, `finding`, `action`, `uniqueness_verified` (her zaman `false`), `process_state`, `package_readability` (`readable`/`unverifiable`, taranmadıysa `null`), `static_support`, `evidence` (`k1_iokit_linked`, `k2_corefoundation_linked`, `k3_ioregistry_access`, `k4_platform_serial_string`, `count`; taranmadıysa `null`), `static_failure`, `raw_state` (okunmadıysa `null`), `cid_masked`, `engine_path` (= `effective_engine_path`, `~` ile), `engine_path_validated` (motor açıkken/P bilinmezken `false`; o zaman `effective_engine_path` ve `engine_physical_path` `null`), `engine_physical_path`, `requested_engine_path`, `override_rejected`, `reject_reason`, `engine_hash_short`, `engine_running`, `engine_version_informational`, `app_version`, `timestamp` (UTC ISO-8601), `schemaVersion: 1`. Ham kimlik ve tam CID alanı **yoktur**. İnsan-okur çıktı aynı bilgiyi, istenen/etkin motor ayrımını ("REJECTED … / default fallback") ve bir sonraki adımı yazar; reddedilen yol stderr'e hata olarak yazılır.
- `PLAYERIDENTITYCTL_ENGINE_APP=<yol>` başka bir motor paketini (§73.7 kurallarıyla) inceletir; yoksa uygulamanın ayarı, o da yoksa varsayılan kullanılır. `PLAYERIDENTITYCTL_IDENTITY_HOME=<klasör>` kimlik dosyalarını ev klasörü yerine bu klasörden (yine salt okunur) okutur; kalibrasyon fixture'ları içindir.

### 73.9 Yerelleştirme
- Metinler `macIdentity.*` anahtarlarıyla 26 dilde bulunur; yeni veya değişen değerler, çevrilene kadar diğer 24 dilde İngilizce yer tutucu taşır (§63 aracı; anahtar seti korunur).

### 73.10 Testler
Karar tablosunun her satırı ve süreç önceliği (running/unavailable her S×R için); K4'süz K1–K3 → `yes` değil; çalıştırılabilir + kütüphane kanıt birleştirme; fat dosya; okunamayan / Mach-O olmayan / yapısal bozuk (yükleme komutu, dylib adı, sembol/dize tablosu, bölüm, segment sınırları) / 512 MB üstü / monotonik zaman aşımı / duvar saati sıçraması etkisiz / parça sınırında iptal / tek okuma donması → `unknown`; geçerli ilgisiz komut atlanır; `ENOENT` dışı `lstat` hataları `unreadable` (sahte ve gerçek izin reddi); okunamayan paket `unknown`, indirme önerisi yok; motor açıkken tarama/hash/okuma sayacı 0; `unavailable` asla `notRunning` değil ve yeniden oluşturmayı engeller; ayar düzenleme süreç dedektörü değişmez; `isGameRunning` senkronu; başarılı açılış sonrası motor açık kabul ve Yenile sonrası düğme yeniden etkin; checking önceki sonucu/eylemi gizler; yeni Yenile önceki taramayı iptal eder; eski nesil yeniden oluşturma sonucu yeni rapora yapışmaz; izin listesi reddi görünür + log; sembolik bağlantı / takma ad / bağlantılı kök ile veri klasörü override reddi (sahte ve gerçek); CLI JSON/insan çıktısında ham kimlik ve tam CID yok, tekillik iddiası yok, çıkış kodları, reddedilen override ≠ 0 ve istenen/etkin ayrımı; gerçek dosyalarda kontrol öncesi/sonrası SHA-256 aynı; 26 dilde anahtar eşitliği. Testler sahte dosya sistemi ve sentetik Mach-O ile gerçek motor olmadan çalışır.

### 73.11 Kalibrasyon (yayın kapısı, repo dışı)
- `scripts/calibrate-macos-identity.sh` isteğe bağlıdır ve birim testlerinden ayrıdır (birim test paketinde atlanan test yoktur); yayın kontrol listesi onu ayrıca çalıştırır.
- Resmi upstream "continuous" Apple arm64 asset'ini repo dışındaki çalışma klasörüne indirir (varsa yeniden kullanır), SHA-256'sını kaydeder (isteğe bağlı sabitlenmiş değerle karşılaştırır); geçici, salt okunur bir `Upstream.app` ve sentetik kimlik fixture klasörleri (zero/nonzero/absent) oluşturur; `playeridentityctl`'i repo dışı DerivedData ile derler ve kurulu `/Applications/Xash3D-FWGS.app` ile karşılaştırır. Gerçek kimlik dosyalarına, oyun verisine ve uygulama kaydına dokunmaz; kurulu motorun ikilileri önce/sonra hash'lenir; hiçbir motor başlatılmaz.
- Beklenen: upstream 4/4 `yes`; kurulu 0/4 `no`; upstream+nonzero → `supported`; upstream+zero → `unknown` + yeniden oluştur; kurulu+zero/absent → `unsupported`; kurulu+nonzero → `unknown` + indirme önerisi.
- Çıkış: `0` PASS, `1` FAIL, `4` NOT CONFIGURED (asset veya kurulu uygulama yok ve sağlanamıyor) — kapı kapalı kalır, sessiz atlama yoktur. Özet (`summary.txt`, `summary.json`), komutlar, asset hash'i ve vaka JSON'ları kanıt klasörüne yazılır; ham kimlik kaydedilmez.
- Ortam değişkenleri: `PI_CAL_WORK`, `PI_CAL_ASSET_NAME`, `PI_CAL_ASSET_URL`, `PI_CAL_UPSTREAM_ASSET`, `PI_CAL_UPSTREAM_SHA256`, `PI_CAL_DOWNLOAD`, `PI_CAL_INSTALLED_APP`, `PI_CAL_CTL`, `PI_CAL_DERIVED_DATA`, `PI_CAL_EVIDENCE_DIR`.

### 73.11.1 Kalıcı kanıt — S1–S7 (bu özellik için bir kez doğrulandı)
- **Tarih:** 2026-11-20. **Kanıt dizini:** `/private/var/folders/c8/h1kf9qwj6vxbltzgvh9_7q040000gn/T/opencode/player-identity-macos-identity-spike` (`REPORT.md`, `evidence/spike-run.log`, `evidence/*-before|after|after2.sha256`, `evidence/logs/`). Ortam: macOS 27.2.1, Apple silicon fiziksel Mac. Upstream asset: `xash3d-fwgs-apple-arm64.tar.xz` (continuous, commit `11ed246c`, yayın 2026-11-17), SHA-256 `a12ea04ca0165690a9c25a953aa46c5e2c8c43efa98a3e7fb3a921144826c237` = GitHub digest. Upstream binary repoya konmadı; kanıt yalnız repo dışında durur. Ham kimlik/tam CID kaydedilmedi (yalnız tuzlu parmak izi ve maskeli CID).
- Bağımsız spike (motor, ağ çıkışı ve gerçek `$HOME`/`/Applications` yazımı yasaklanmış sandbox'ta, izole fixture'da) sonuçları:

| Kod | Spike testi | Sonuç |
|---|---|---|
| S1 | S-a, S-f | Kurulu build (`libxash.dylib` `d38e3624…`): K1–K4 yok, çalışmada raw = 0 → `unsupported` |
| S2 | S-b | Upstream (`libxash.dylib` `c0ced709…`): K1–K4 var, raw ≠ 0, iki koşuda bayt bayt aynı |
| S3 | S-b-neg | Aynı upstream'de yalnız seri numarası özelliği okuması engellenince raw = 0 (nedensellik) |
| S4 | S-g | Upstream, eski raw = 0 dosyalarıyla açılınca dosyaları donanım kimliğiyle onardı |
| S5 | S-c, S-c' | Dosyalar silinip yeniden başlatılınca (ve farklı yolda) aynı raw yeniden üretildi; rastgele rotasyon yok |
| S6 | S-d | Uygulamanın Identity/CID hesabı bağımsız referansla ve sabit vektörlerle eşleşti. Sınır: motorun ağa gönderdiği CID ile uçtan uca karşılaştırma yapılmadı (sunucuya paket gönderimi yasak) |
| S7 | S-e | Gerçek kimlik dosyaları, oyun verisi (6876 dosya), kurulu uygulama ve repo SHA-256'ları önce = sonra = sonra-2 (`cmp` IDENTICAL; repo HEAD `0876c4b1`) |

- **Bu görevde 2026-11-20'de yeniden doğrulananlar:** (a) spike kanıt dosyaları `cmp` ile yeniden karşılaştırıldı: `idfiles`, `gamedata`, `installed-app`, `repo-files` before = after = after2 IDENTICAL; (b) `scripts/calibrate-macos-identity.sh` aynı asset (sabitlenmiş SHA-256) ve kurulu `/Applications/Xash3D-FWGS.app` ile koşuldu: **PASS** — upstream 4/4 `yes` (supported / zero→regenerate / absent→regenerate), kurulu 0/4 `no` (zero ve absent → unsupported, nonzero → unknown + indirme önerisi), kurulu ikililer önce = sonra (T-K1–T-K5). Bu S1 ve S2'yi uygulamanın kendi tarayıcısıyla yeniden üretir.
- **Kalıcılık:** S1–S7 bu özelliğin davranış varsayımlarını (donanım kaynaklı, deterministik, onarılabilir kimlik; okuma izolasyonu) bir kez kanıtlar ve **her sürümde yeniden koşulmaz**. Her sürüm yalnız §73.11 kalibrasyonunu (T-K1–T-K6) çalıştırır. S1–S7 ancak şu durumlarda yeniden üretilir: upstream kimlik türetme davranışı değişirse, karar kuralı/kanıt eşiği (K1–K4) değişirse, kalibrasyon başarısız olursa veya yeni bir platform/mimari (ör. amd64, başka macOS ana sürümü) desteklenirse.

### 73.12 Sınırlar
- Statik gösterge eşiği yanlış pozitif/negatif üretebilir; gerçek motor sürümleriyle kalibre edilir (§73.11). Göstergeler tekillik kanıtı değildir.
- `absent` için motorun ilk açılışta kimliği oluşturduğu varsayılır; oluşmazsa kullanıcı `unknown` + Yenile/teşhis yönlendirmesiyle kalır (otomatik yeniden deneme yok).
- Motor çalışma tespiti süreç adına (`xash3d*`) dayanır; süreç listesinin okunamadığı durumlar `unavailable` olarak raporlanır.
- Tek bir bloklayan okuma çağrısı iptal edilemeyebilir; sonuç `unknown` olur.
- Gerçek rastgele rotasyon ancak motorun açık, kullanıcı yönetimli bir kimlik geçersiz kılma protokolü desteklemesiyle ve ayrı bir spesifikasyonla mümkün olur; bu sürümün kapsamı dışındadır.

---

## 74. Uyumlu motoru kur (v5.3, uygulama 2.25.0 build 53)

Bu bölüm, ayrı davranış spec'inin (E0–E21) uygulama tarafı özetidir. Çelişkide E bölümleri geçerlidir. §73'teki "motor indirme/değiştirme yok" kuralı yalnız bu akış için, onay ve yedekle gevşetilir; §73'ün diğer kuralları (kimlik dosyasına yazma yok, rastgele kimlik yok, tekillik iddiası yok) aynen geçerlidir.

### 74.1 Görünürlük
- "Uyumlu motoru kur" yalnız §73 durumu `unsupported` iken (S = no, R ∈ {zero, absent}, paket okunabilir, motor kapalı) ve kontrol sürmüyorken gösterilir. Birincil eylem budur; resmi sürüm sayfası ikincil bağlantıdır. `unknown + S=no + R=nonzero` durumunda yalnız sayfa bağlantısı kalır.
- Motor açıksa veya süreç durumu doğrulanamıyorsa buton devre dışıdır ve nedeni yazılır. Intel (x86_64) Mac'lerde amd64 kapısı geçene kadar devre dışıdır. Bir alma veya kurulum sürerken ikinci kurulum başlamaz (çekirdekteki hedef kilidi ayrıca korur).

### 74.2 Akış
1. Tıklama: süreç durumu yeniden alınır (tri-state); yalnız `notRunning` ile devam edilir. Yalnız sürüm API'si okunur; indirme ve yazma yoktur.
2. Onay ekranı: kaynak (`FWGS/xash3d-fwgs`, `continuous`, ön sürüm), commit, dosya adı ve boyutu, değişecek motor yolu, değişecek dosyalar (motor uygulaması + etkin oyun klasöründeki 2 oyun kütüphanesi; kimlik dosyaları yalnız yedeklenir), yedek yeri, mevcut maskeli CID, ilk açılış bilgisi ve lisans atfı. Uyarı metni: "Bu güncelleme yeni bir kimlik (CID) oluşturabilir. Sunucudaki ban veya hesap kaydı yeni kimlikle eşleşmeyebilir." Uyarı kabul edilmeden "Kur" etkin değildir; varsayılan eylem Vazgeç'tir.
3. Onay: süreç durumu bir kez daha alınır; kimlik dosyalarının durum etiketleri ve maskeli CID salt okunur alınır (`cidBefore`, yalnız bellekte). Kurulum çekirdekte çalışır.
4. İlerleme: indiriliyor (bayt/toplam + yüzde), SHA-256, açılıyor, imza, ön kontrol, yedekleniyor, kuruluyor, geri alınıyor; metin + simge, VoiceOver duyurusu. İptal yalnız indirme ve açma sırasında, gerçek görev iptaliyle; yedek başladıktan sonra iptal gösterilmez.
5. Pencere kapanırsa alma/onay bırakılır, indirme/açma iptal edilir; yedek/kurulum tamamlanır veya geri alınır. Uygulamadan çıkışta kurulum görevi bitene kadar beklenir.

### 74.3 Sonuç ve doğrulama
- Kurulumdan sonra §73 kontrolü yeniden çalışır (doğrulama yapılmadan). Uygulama motoru kendiliğinden açmaz; "Motoru Aç" yalnız kullanıcı eylemiyle ve motor kapalıyken çalışır. Talimat: motoru bir kez açın, ana menüde kapatın, Yenile'ye basın; Gatekeeper engellerse Sistem Ayarları > Gizlilik ve Güvenlik > "Yine de Aç". Uygulama Gatekeeper'ı aşmaz.
- Motor kapalıyken yapılan her Yenile, öncesi/sonrası kimlik etiketlerini çekirdek doğrulayıcıyla karşılaştırır. `identityRepaired` veya `alreadyHealthy` gelene kadar kart "Kuruldu, doğrulanıyor" der; `supported`/sağlıklı denmez. `notVerified` uyarı olarak gösterilir ve bekleme sürer. CID değiştiyse "Kimlik değişti: önce → sonra" (maskeli) gösterilir.
- `failed`, `rolledBack` (yedek yolu), `rollbackIncomplete` (kritik, yedek yolu, otomatik silme yok), `cancelled`, kalıntılar, karantina hataları ve değişen kimlik dosyası `EngineInstallFailure.code` ile görünür; hata günlüğüne `engineInstall` alanıyla yazılır (yalnız kod/aşama; ham kimlik ve tam CID yok).

### 74.4 Motor yedekleri (Ayarlar > Veri)
- Envanter gösterilir; en yeni 3 yedek tutulur. "Eski Yedekleri Sil…" yalnız açık onayla ve onay anındaki envantere bağlı belirteçle siler; klasör değiştiyse hiçbir şey silinmez ve yeniden onay istenir. Kısmi hata görünür ve günlüğe yazılır; silinemeyen yedeğin kaydı korunur. Kurulum sürerken silme yapılmaz. Otomatik silme yoktur.

### 74.5 CLI
- `playeridentityctl engine status [--json]`: ağsız; süreç durumu, kimlik durumu, kurulumun sunulup sunulmadığı, yedek envanteri.
- `engine install-compatible [--yes] [--json]`: terminalde CID uyarısıyla y/N sorulur; terminal yoksa `--yes` zorunludur, yoksa ağdan önce çıkış 1. `--json` her satırda bir nesne (`stage`, `bytes`, `total`, `error`, `cidBefore`, `cidAfter`), son satır sonuçtur. Motor açılmaz; doğrulama sonra `diagnose --macos-identity` ile yapılır. Çıkış: 0 kuruldu (doğrulama bekliyor), 1 kullanım/onay yok, 2 başarısız (motor açık, hiçbir şey değişmedi veya geri alma tamamlanamadı — kritik), 3 iptal/reddedildi/geri alındı, 4 sunulmuyor (unsupported değil, Intel, reddedilen override). (Not: bu kodlar E12'deki 0–7 taslağının yerine geçer.)
- `engine backups [--json]` envanter ve onay kodu; `engine backups delete --confirm <kod>` yalnız kod güncel envanteri adlandırıyorsa siler.

### 74.6 Gizlilik, güvenlik ve sınırlar
- Ham kimlik, tam CID, seri numarası UI/CLI/JSON/günlükte yoktur; yalnız maskeli CID.
- Birim testleri sahte kurucu/indirici kullanır; gerçek ağ, gerçek `/Applications`, gerçek oyun verisi ve gerçek kimlik dosyası yazılmaz.
- Resmi asset uçtan uca testi (`scripts/test-engine-installer-e2e.sh`, T-E-GE7) sürüm kapısıdır; elle veya zamanlanmış iş akışıyla çalışır, her push'ta çalışmaz.
- Sınırlar: Gatekeeper davranışı temiz hesapta ölçülmedi; Intel kurulum kapalı; `continuous` ön sürümdür ve içerik değişebilir; aynı Mac için aynı kimlik garantisi ve rotasyon iddiası yoktur.

---

## 75. GoldSrc 48 desteği (v5.4, uygulama 2.26.0 build 54)

Amaç: GoldSrc protokol-48 sunucuları (ör. POLIGON RPG 51.68.190.91:27015) doğru tanınsın; bu sunucularda CID "uygulanamaz" gösterilsin; "Oyuna gir" `gs` ile başlasın; ban teşhisi gerçekçi olsun. Kullanıcı bu sunucuda `connect … gs` ile "You have been banned from this server." alıyor; modern connect49 ise "older protocol 48" veriyor. CID bu sunucuya gönderilmez. Kapsam: yalnız protokol tespiti, CID görünürlüğü, başlatma argümanı ve teşhis. Motor kurulumu (§74), kimlik (§73) ve tekillik iddiası değişmez.

Kaynak notu: A2S yanıt başlığı ve legacy probe paketi (75.2, 75.6) upstream ile doğrulanmış kabul edilir (bkz. her madde). **AC-75.G1 ve AC-75.P1 yakalanmış gerçek paketlerle (fixture) ve sabit bayt vektörüyle de geçmelidir**; uyuşmazlıkta spec ve parser birlikte güncellenir.

### 75.1 Protokol modeli
- `ServerInfo` protokol değeri üç durumdan birindedir: `unknown`, `source49`, `goldsrc48`.
- `source49`: Source/Xash A2S_INFO yanıtı, protokol baytı 49; alanlar: ad, harita, klasör (folder), oyun.
- `goldsrc48`: GoldSrc legacy A2S_INFO yanıtı, protokol baytı 48. Source yerleşimiyle yanlış ayrıştırılmaz (harita ve klasör yer değiştirmez).
- `unknown`: yanıt boş, kesik, tanınmayan veya iki yerleşimle de tutarsız.
- Source adres alanı (GoldSrc'de yok sayılan adres dizgisi) modelde korunur ama başlatmada kullanılmaz.
- Eski kayıt uyumluluğu: protokol alanı olmayan eski `ServerInfo` kayıtları `unknown` olarak okunur; kayıt silinmez, ilk yeniden sorguda güncellenir.

### 75.2 A2S_INFO ayrıştırıcısı
- Yanıt başlığı (5 bayt, `FF FF FF FF` ardından tip baytı):
  - `0x6D` (`m`) = GoldSrc legacy yanıt; alanlar aşağıdaki legacy yerleşimle okunur.
  - `0x49` (`I`) = Source A2S_INFO yanıtı; bir sonraki bayt protokol (49) ve Source alanları (ad, harita, klasör, oyun) gelir.
  - Diğer tip baytı: yanıt `unknown`/hata olarak reddedilir (fail); legacy veya source olarak yorumlanmaz.
- Legacy yerleşim (`0x6D` sonrası, sırayla): adres dizgisi (yok sayılır), ad, harita, gamedir, açıklama, mevcut oyuncu sayısı (numcl), azami oyuncu (maxcl), protokol baytı, sunucu tipi, işletim sistemi, parola bayrağı, mod bayrağı; mod bayrağı 1 ise mod alanları (url, indirme url, boş bayt, sürüm (4 bayt), boyut (4 bayt), mod tipi, dll bayrağı); ardından VAC baytı ve bot sayısı. **(v5.4.1 düzeltme, §75.12)** Yakalanmış gerçek yanıtta sürüm dizgisi yoktur ve protokol baytı **47**'dir (HLDS/ReHLDS legacy yanıtı 47 bildirir; ağ protokolü 48): legacy yanıtta protokol baytı 47 veya 48 → `goldsrc48`; başka değer `unknown`.
- Tüm dizgiler sonlandırıcı baytla biter; sonlandırıcı yoksa veya veri biterse `malformed`.
- Yinelenen alan veya fazla bayt: yinelenen alan `malformed`; sondaki beklenmeyen bayt yanlış pozitif üretmez (yanıt `goldsrc48` kalır, uyarı günlüğe yazılır).
- Source49 yerleşimi bu değişiklikten sonra da aynen ayrıştırılır (regresyon).
- Zaman aşımı, kesik paket ve bozuk protokol baytı `unknown`; ağ hatası teşhis adımında "A2S_INFO başarısız" olarak raporlanır.

### 75.3 CID görünürlüğü
- `goldsrc48`: CID hiç hesaplanmaz ve gösterilmez; durum `notApplicable`; `cid = nil`; UI "CID bu sunucuda kullanılmıyor" der; CLI ve JSON'da `cid = null`, `cidApplicable = false`.
- Eski profilde legacy dönemden kalan CID kaydı varsa, bir sonraki başarılı refresh (A2S yanıtı `goldsrc48` olarak alınmış) bu kaydı temizler; temizleme yalnız o refresh'te yapılır, başarısız refresh kaydı silmez.
- `source49`: §73 CID hesabı (mevcut davranış) aynen korunur; bu bölüm onu değiştirmez.
- `unknown` protokolde CID kararı verilmez; "belirlenemedi" gösterilir, yerel CID de gösterilmez.
- `uniqueness_verified = false` her durumda korunur.
- Profilde eski legacy CID kaydı varsa, bir sonraki başarılı refresh onu temizler (yukarıdaki kural); eski kayıt okunurken hata vermez.

### 75.4 Oyuna gir (başlatma)
- `source49`: `+connect <host:port>` (değişmez).
- `goldsrc48`: `+connect <host:port> gs`. Anahtar `legacy` değildir. **(v5.4.2)** Motor konsolunu `engine.log`a yazsın diye argümanlar sabit `-dev 1 -log` içerir: `-game <g> -dev 1 -log +connect <host:port> gs` (§75.13).
- `unknown`: varsayılan `source49`; ancak son başarılı A2S sonucu `goldsrc48` ise o kullanılır.
- Başlatma, en güncel A2S sonucuyla yapılır; eski önbellek protokolü yeniden sorgu olmadan geçersiz kılmaz.
- Başlatma argümanları yalnız protokol kararından türetilir; kullanıcı girdisi argüman olarak eklenmez.
- Oyuna gir, sunucu başlatmasında legacy probe göndermez; probe yalnızca §75.5/75.6'daki teşhis eylemiyle çalışır.

### 75.5 Teşhis adımları
Sıra: DNS → A2S_INFO (protokol tespiti) → challenge → bağlantı denemesi (`goldsrc48`: legacy connect48 probe; `source49`: modern connect49) → sunucu mesajı → sonuç.
- `goldsrc48` için modern connect49 probe'u **hiç gönderilmez** ve "protocolMismatch" üretilmez. **(v5.4.5)** Kural: GoldSrc 48 sunucuya **hiçbir gerçek CID gönderilmez**. A2S'i Source 49 gösteren sunucuya önce CID'siz yetenek denemesi (sıfır yer tutucu CID'li connect 49) gidebilir; bu, "connect49 hiç gönderilmez" ifadesinin tek istisnasıdır (§75.16).
- `source49` için legacy probe gönderilmez.

### 75.6 Legacy probe (GoldSrc 48)
- Doğrulama durumu: aşağıdaki paket yapısı **upstream current master `engine/client/cl_main.c` `CL_SendGoldSrcConnectPacket` ile doğrulandı** (kullanıcı bildirimi, 2026-11-26; bu oturumda upstream kaynağı yeniden okunmadı). Upstream `cl_ticket_generator null` yolunun davranışına eşdeğerdir.
- Paket alanları (sırayla):
  1. Out-of-band başlık: `FF FF FF FF`.
  2. ~~Mesaj adı: `GoldSrcConnect`.~~ **(v5.4.1 düzeltme, §75.12)** `GoldSrcConnect` motorun iç tampon adıdır; pakette **gönderilmez** (motorun yakalanmış paketinde başlıktan hemen sonra `connect` gelir).
  3. Gövde dizgisi: `connect 48 <challenge> "<protinfo>" "<userinfo>"` + sonda newline. Upstream son sıfır baytı yeniden yazar (trailing null): newline'dan hemen sonra ticket başlar. `<protinfo>` ve `<userinfo>` Xash bilgi dizgisi biçimindedir: `\prot\3\unique\-1\raw\steam\cdkey\<32 hex>` ve `\name\<ad>`.
  4. `<challenge>`: `getchallenge` yanıtından (GoldSrc yanıtı metindir: `A00000000 <challenge> <auth> …`; istek motorunki gibi `FF FF FF FF getchallenge steam\n`).
  5. `<protinfo>`: `prot=3`, `unique=-1`, `raw=steam`, `cdkey=<32 hex>` (cdkey her denemede rastgele; motor da her bağlantıda yeni değer gönderir; kimlikten türetilmez).
  6. `<userinfo>`: en az `name=<oyuncu adı>`; Xash userinfo dizgisi formatı kullanılır.
  7. Ardından upstream `cl_ticket_generator null` yolu gibi **512 adet sıfır bayt** ticket.
- Bayt vektörü birim testinde sabitlenir (AC-75.P1). Ticket sıfırdır; **gerçek hesap/SteamID doğrulaması değildir.** Probe oyuncu oturumu açmaz.
- Probe bir oyuncu oturumu açmaz; ticket ve SteamID gerçek hesap doğrulaması değildir.
- Sonuç ayrımı (**v5.4.2:** yalnız ban metni `banned` üretir; aşağıdaki diğer sonuçların hiçbiri "ban yok" değildir, karar `legacyVerificationUnavailable`'dır, §75.13):
  - Sunucu bağlantıyı reddeder ve gerekçe içerir: "Sunucu bu bağlantıyı yasakladı (ban)." Mesaj "hesap" veya "SteamID banı" türünü iddia etmez; yalnız "sunucu bağlantıyı reddetti/yasakladı" der.
  - Sunucu probe'u reddeder ama ban metni yoksa: "GoldSrc bağlantısı reddedildi; neden: <sunucu mesajı>".
  - Yanıt yok / zaman aşımı: "GoldSrc bağlantısı yanıt vermedi" (ban iddiası yok).
  - Challenge alınır ama bağlantı tamamlanmazsa: "bağlantı tamamlanmadı" (ban iddiası yok).
- Sunucu mesajı en fazla 200 karakter gösterilir; kontrol karakterleri temizlenir.

### 75.7 Teşhis kararı (verdict)
- `banned`, `connectionRejected`, `protocolMismatch`: yalnız `source49` yolunda üretilir.
- ~~`goldSrc48`~~ **(v5.4.2)** GoldSrc yolunda iki karar vardır: `banned` (probe yanıtında veya motor günlüğünde ban metni) ve `legacyVerificationUnavailable` (diğer her durum). Gerekçe: `goldsrc48` tespit edildi, CID uygulanamaz, sunucu mesajı (varsa), kanıt kaynağı (`probe` / `engineLog`).
- IP ban / CID uygulanabilirliği: GoldSrc'de CID uygulanamaz olduğu için "CID ile ban" iddiası yapılmaz; ban metni "bağlantı/IP yasağı olabilir" çerçevesiyle ve server yöneticisine başvuru önerisiyle sunulur.
- Legacy ban mesajı: kullanıcıya yönetici başvurusu (sunucu adı, IP:port, sunucu mesajı) önerilir; uygulama ban kaldırma iddiasında bulunmaz.

### 75.8 Arayüz
- GoldSrc kartı: "CID bu sunucuda kullanılmıyor" metni; yerel CID alanı gizlenir (boş değil, tamamen yok).
- "Oyuna gir" düğmesi `gs` ile başlatılır; düğme metni ve açıklaması değişmez.
- Teşhis ekranında verdict için yukarıdaki metinler ve yönetici başvuru adımı gösterilir.
- Yeni metinler `diagnosis.goldsrc.*` ve `servers.goldsrc.*` anahtarlarıyla 26 dilde bulunur; çevrilmemiş dillerde İngilizce yer tutucu kabul edilir (§63).

### 75.9 CLI ve JSON
- `playeridentityctl diagnose --json` GoldSrc sunucu için alanlar: `protocol` ("goldsrc48"), `cid` (null), `cidApplicable` (false), `goldSrc` (true), `verdict`, `message`, `uniqueness_verified` (false), `schemaVersion` (mevcut sürüm).
- Kimlik, tam CID, seri numarası, ticket içeriği ve parola alanları çıktıda **yoktur**; sunucu mesajı kısaltılmış ve temizlenmiştir.
- Source49 için `cid`, `cidApplicable = true` mevcut kurallarla dolar.
- Çıkış kodları değişmez; GoldSrc ban verdict'i kullanım hatası değil, teşhis sonucudur (mevcut teşhis çıkış kuralı uygulanır).

### 75.10 Kabul kriterleri ve testler
- **AC-75.G1** Yakalanmış legacy A2S fixture'ı `goldsrc48` olarak ayrıştırılır; ad, harita, gamedir, protokol 48 doğru (T-75-1).
- **AC-75.G2** Source49 fixture'ı mevcut sonucu korur (regresyon) (T-75-2).
- **AC-75.G3** Parola/mod/bot alanları olan legacy yanıt doğru ayrıştırılır; mod bayrağı 1 iken mod alanları atlanır (T-75-3).
- **AC-75.C1** Kesik, sonlandırıcısız, yinelenen alanlı yanıt `malformed`/`unknown`; çökme yok (T-75-4).
- **AC-75.C2** GoldSrc48 → cid=nil, status=notApplicable; hesaplanan yerel CID gösterilmez (T-75-5).
- **AC-75.C3** Source49 → mevcut CID davranışı değişmez (T-75-6).
- **AC-75.C4** Eski legacy CID kaydı yeni yenilemede temizlenir; eski profil dosyası açılır (T-75-7).
- **AC-75.L1** `goldsrc48` → `+connect host:port gs`; `source49` → `+connect host:port`; unknown → source49 (T-75-8).
- **AC-75.L2** Başlatma en güncel A2S sonucunu kullanır (T-75-9).
- **AC-75.P1** Legacy probe bayt vektörü sabit (başlık, `GoldSrcConnect`, `connect 48 <challenge> "<protinfo>" "<userinfo>"\n`, 512 sıfır ticket); protinfo ve userinfo alanları yukarıdaki sırada (T-75-10).
- **AC-75.P2** Legacy probe çalışırken modern connect49 hiç gönderilmez; source49'da legacy probe gönderilmez (T-75-11).
- **AC-75.P3** Sunucu ban mesajı → "sunucu bağlantıyı yasakladı"; hesap/SteamID banı iddiası yok (T-75-12).
- **AC-75.P4** Sunucu probe reddi (ban metni yok) → "GoldSrc bağlantısı reddedildi; neden: …" (T-75-13).
- **AC-75.P5** Yanıt yok / zaman aşımı → ban iddiası yok; teşhis "yanıt vermedi" (T-75-14).
- **AC-75.P6** Ban yok ve bağlantı başarılı → "banned" üretilmez; **(v5.4.2)** "ban yok"/"engel yok" da üretilmez: karar `legacyVerificationUnavailable`, JSON `banned: null` (T-75-15).
- **AC-75.S1** Gizlilik: UI/CLI/JSON/günlükte tam CID, ticket, parola, seri numarası yok (T-75-16).
- **AC-75.U1** GoldSrc kartında "CID bu sunucuda kullanılmıyor"; 26 dil anahtar eşitliği (T-75-17).
- **AC-75.J1** `diagnose --json` GoldSrc alanları (cid=null, cidApplicable=false, goldSrc=true) (T-75-18).
- **AC-75.R1 (yayın kapısı)** Yalıtılmış motorda `connect <host>:27015 gs` denemesi ile teşhis aynı verdict'i üretir (ban ise ban). **(v5.4.2)** Ölçüt: (a) motor konsolunda "Trying to connect with GoldSrc 48 protocol" ve sunucunun yanıtı; (b) uygulamanın yalnız-probe teşhisi "ban yok" demez (`banned` `null` veya `true`); (c) motorun konsol günlüğüyle yapılan teşhis motorun yanıtına ulaşır (ban → `banned`). Hedef: POLIGON RPG 51.68.190.91:27015. Kullanıcı bu oturumda gerçek POLIGON probe'unu açıkça istedi; bu kapı için onay verilmiş sayılır. Yine de legacy probe **yalnız kullanıcı isteğiyle** çalışır: teşhis düğmesi/komutu veya CLI'da `--confirm` bayrağı. Otomatik, periyodik veya arka plan gönderimi **yoktur**. Kanıt repo dışında kaydedilir.
- **AC-75.R2 (yayın kapısı)** Tam paket testi, CLI smoke ve 26 dil anahtar kontrolü geçer; yerel build numarası 54, pazarlama sürümü 2.26.0.
- **AC-75.R3** Changelog, `docs/spec.md` ve `FEATURES.md`/`FEATURES.tr.md` bu sürümle eşitlenir; eski sürüm notları değişmez.

### 75.11 Sınırlar
- Legacy probe bir teşhis aracıdır; sunucunun ban nedenini ya da oyuncuya özgü bir yasağı doğrulamaz.
- GoldSrc sunucuları CID göndermez; "kimlik ile ban" yolu bu sürümde yoktur.
- Sunucu mesajı sunucu tarafından değişebilir; metin eşleştirmesi yerine mesajın ham (kısaltılmış) hâli gösterilir.
- Null ticket probe (512 sıfır bayt) sunucunun gerçek hesap/SteamID davranışını birebir kanıtlamaz; sunucu yalnızca "bağlantıyı yasakladı" gibi bir sonuç döndürür, ban türünü (hesap, SteamID, IP) uygulama belirleyemez ve iddia etmez.
- Protokol 48 yanıt yapısı, sunucu yazılımına göre (ReHLDS, HLDS, Xash) küçük farklar gösterebilir; bilinmeyen alanlar `unknown` olur, sahte tespit yapılmaz.

### 75.12 Yakalanmış paketler ve yayın kapısı kanıtı (v5.4.1, 2026-11-26)
- **A2S (AC-75.G1):** 51.68.190.91:27015 tek `TSource Engine Query`'ye iki yanıt verir: `0x6D` legacy (86 bayt; adres `51.68.190.91:27015`, harita, `valve`, `Half-Life`, numcl, maxcl, protokol **47**, `d`, `l`, parola 0, mod 0, VAC 1, bot 0) ve Source yerleşimli `0x49` (protokol baytı **48**). `0x49`+48 `unknown` kalır (GoldSrc veya eski Xash olabilir); karar `0x6D` yanıtından çıkar. Fixture'lar testlerde bayt bayt sabittir.
- **Paket (AC-75.P1):** kurulu motorun kendi `connect 127.0.0.1:<port> gs` denemesi yerel dinleyiciyle yakalandı: `FF FF FF FF getchallenge steam\n`, ardından `FF FF FF FF connect 48 <challenge> "\prot\3\unique\-1\raw\steam\cdkey\<32 hex>" "<userinfo>"\n` + ticket. `cl_ticket_generator null` ile ticket tam **512 sıfır bayt**; varsayılan üreteçte (`revemu2013`) ticket sıfır değildir. Pakette `GoldSrcConnect` yoktur. Uygulamanın paketi baş kısım ve 512 sıfır kuyrukla yakalanmış paketle eşleşir; userinfo yalnız `\name\<ad>`'dır.
- **Yayın kapısı (AC-75.R1), 2026-11-26:** `scripts/verify-goldsrc-connection.sh --confirm` (APFS klon, sandbox, geçici HOME; gerçek motor/oyun verisi/kimlik dosyaları önce = sonra). Motor (gerçek kimliğin klonu, varsayılan ticket): "Trying to connect with GoldSrc 48 protocol" → "Spooling demo header." → "Server issued disconnect. Reason: You have been banned from this server." Uygulamanın probe'u (boş ticket): `goldsrc48`, sunucu reddi "Sorry, no-steam p48 clients are not allowed on this server" → `rejected`. **Kapı GEÇMEDİ** (motor `banned`, probe `rejected`). Neden: (a) sunucu boş ticket'ı Steam'siz istemci diye reddeder; (b) bu sunucuda ban, bağlantı kabul edildikten sonra oturum içinde verilir; oyuncu oturumu açmayan bir probe bunu göremez. Kapının geçmesi için spec kararı gerekir (ör. R1'in boş ticket probe'u için "aynı verdict" yerine "sunucu yanıtı gösterilir" ölçütüyle değiştirilmesi); bu sürüm ban iddiası üretmez.
- **Uygulama notu (2.26.0, karar bekliyor):** §75.3'teki "`unknown` → CID belirlenemedi, yerel CID gösterilmez" kuralı uygulanmadı; `unknown` (yanıt yok, eski kayıt, `0x49`+48, protokol 17 gibi) mevcut davranışı (source49 varsayılanı: CID hesaplanır/gösterilir, teşhiste connect 49) korur — §75.4 başlatma varsayılanıyla aynı. Gerekçe: kural uygulanırsa ban denetimi kapalı veya sunucu yanıt vermeyen her satırda CID kaybolur. Teşhis JSON'unda `unknown` için `cidApplicable: null` verilir.
- Motorun konsolu yalnız `-dev 2 -log` ile yazılır; pty üzerinden stdout yakalaması bu sürümde satırı göstermedi (0), konsol günlüğü (`engine.log`) gösterdi (1). Kanıt repo dışında: `$TMPDIR/opencode/pi-goldsrc-gate.*/evidence` (`summary.json`, `engine-excerpt.txt`, `probe.json`); ham kimlik ve ticket kaydedilmez.

### 75.13 Null-ticket doğrulama sınırı ve motor günlüğü kanıtı (v5.4.2, 2026-11-26)
- **Canlı bulgu:** geçerli RevEmu ticket'lı yalıtılmış motor (`connect 51.68.190.91:27015 gs`) "Spooling demo header." sonrasında "Server issued disconnect. Reason: You have been banned from this server." aldı; ban bağlantı kurulduktan sonra oturum içinde gelir. Uygulamanın null-ticket probe'u aynı sunucudan yalnız ping/challenge (`FF FF FF FF A …`) veya "Sorry, no-steam p48 clients are not allowed on this server" aldı. Bu yüzden probe'un sessizliği, ping'i, ban metni olmayan reddi veya kabulü **asla "ban yok" değildir**.
- **Karar:** GoldSrc yolunda `banned` yalnız ban metniyle (probe yanıtı veya motor günlüğü); aksi `legacyVerificationUnavailable` ("GoldSrc ban durumu doğrulanamadı — sunucuya “Oyuna gir” (gs) ile bağlanıp çıkın, sonra Yenile; uygulama motor günlüğünü okur"). CLI JSON: `banned` `true`/`null` (GoldSrc'de asla `false`), `verdict` `banned`/`legacyVerificationUnavailable`, `cid: null`, `cidApplicable: false`, `serverMessage`, `goldSrcEvidence` (`engineLog`/`probe`). Source49 `banned: false` davranışı değişmez.
- **Otomatik denetim (yenileme):** GoldSrc 48 sunucuya connect 49 gönderilmez; sonuç `goldSrcUnverified` (turuncu, "GoldSrc: doğrulanamadı"); asla yeşil "Engel yok" değildir. Motor günlüğü ban kanıtı varsa `goldSrcBanned` (kırmızı, "Sunucu banı" / "Sunucu bağlantıyı yasakladı (motor günlüğü).").
- **Motor günlüğü:** `<veri kökü>/engine.log` (motor `-dev 1 -log` ile açıldığında konsolu yazar; "Oyuna gir" GoldSrc 48'de bunu ekler), salt okunur, son 512 KB. Yalnız **son** "Trying to connect with GoldSrc 48 protocol" bloğu sayılır: bloğun adresi ("Connecting to <adres>…" / "server <adres>") bu sunucunun `host:port`'u veya çözümlenmiş `IP:port`'u olmalı; oturum başlığı ("Game started at …") son 24 saat içinde ve bu oturumdaki son "Oyuna gir"den eski olmamalı; blokta sunucu yanıtı ("Server issued disconnect. Reason: …" veya "Server message" + sonraki satır) olmalı. Başka sunucunun bloğu, eski blok, tarihsiz veya yanıtsız blok kanıt değildir (`unknown`). Gerekçe temizlenir (kontrol karakteri yok, IP maskeli, ≤200 karakter); "ban" içeren gerekçe = ban.
- **Bilinen protokol:** bir teşhisin A2S sorgusu yanıtsız kalırsa ve sunucu son başarılı A2S sonucuna göre `goldsrc48` ise GoldSrc yolu korunur (connect 49 gönderilmez).
- **Yayın kapısı sonucu (2026-11-26):** `scripts/verify-goldsrc-connection.sh --confirm` **PASS** — motor: "Server issued disconnect. Reason: You have been banned from this server."; yalnız probe: `legacyVerificationUnavailable`, `banned: null`; motor günlüğüyle: `banned`, `banned: true`, `goldSrcEvidence: engineLog`; gerçek motor/oyun verisi/kimlik dosyaları önce = sonra. (Aynı gün §75.12'deki eski ölçütle yapılan koşu "probe = motor" karşılaştırmasında geçmemişti.)

### 75.14 Bağımsız inceleme düzeltmeleri (v5.4.3, 2026-11-26)
- **Join Game günlük yolu:** `open` uygulamayı `/` çalışma klasörüyle başlatır; motor `engine.log`u çalışma klasörüne yazdığı için günlük kaybolurdu. GoldSrc 48 başlatması: `/usr/bin/open --env XASH3D_BASEDIR=<veri kökü> -a <motor> --args -game <g> -dev 1 -log +connect <ip:port> gs` (kabuk yok; izin listesi yalnız bu kesin biçimi ve mutlak, `..` içermeyen yolu kabul eder; veri kökü yoksa başlatma kurulmaz). `XASH3D_BASEDIR` verildiğinde motor `engine.log`u veri köküne yazar (yerelde ölçüldü). Uygulama `<veri kökü>/engine.log`u okur.
- **Protokol:** `0x49` + protokol baytı 48 de `goldsrc48`'dir (§75.1/§75.2'deki "`unknown`" kuralının yerine). Aynı sorguya `0x6D` ve `0x49`/48 gelirse en çok 0,3 sn beklenip `0x6D` tercih edilir. CID ve connect 49 **yalnız `source49`** (bu denetimin A2S'i veya bilinen protokol) için; `unknown` (§75.4'teki source49 varsayılanının yerine) hiçbir otomatik denetimde, teşhiste veya CLI `ban`da CID/connect 49 almaz. "older protocol 48" connect yanıtı `goldSrcUnverified`'dır.
- **Motor günlüğü kanıtı A2S'ten bağımsız:** yenileme ve teşhis (A2S zaman aşımı veya `unknown` olsa da) uygun blok (adres, 24 saat, son Join Game'den yeni) banını uygular. Kanıtlanmış ban, daha yeni bir motor oturumu (`connected`/başka gerekçe) veya `source49` kanıtı gelmedikçe unknown/unreachable/doğrulanamadı sonucuyla silinmez; silinirse `goldSrcUnverified` olur. Günlük okuma durumu `missing` / `unreadable(hata)` / `data`; okunamayan günlük hata günlüğüne (`serverProtocol`) yazılır.
- **Ban ifadesi:** tek sınıflandırıcı (probe, motor günlüğü, UI, CLI): "you have been banned (from this server)", "you are banned", "banned from this server" veya olumsuzlanmamış tek başına "banned"; "bandwidth", "unbanned", "not banned", "no longer banned" ban değildir.
- **CLI `ban --json`:** `cid` yalnız `source49`'da; GoldSrc 48 ve `unknown`'da `null`; `protocol`, `cidApplicable` eklenir; kayıtlı GoldSrc 48 sunucu için CID hiç hesaplanmaz.
- **Onaysız teşhis:** GoldSrc yolunda onay yoksa hiçbir legacy paket (ne `getchallenge steam` ne connect 48) gönderilmez.
- **Satır/menü çubuğu:** protokol kararı adres çözümlemesinden önce verilir; bilinen GoldSrc 48 + çözülemeyen adres → CID yok, `cidNotApplicable`, `invalidHost` mesajı korunur; menü çubuğu önce protokol belleğine bakar.
- **Bekleyen Join onayı:** sunucu kimliği/adres/port tutulur; onay anında plan güncel protokolle yeniden kurulur; adres değiştiyse hiçbir şey başlatılmaz.
- **Yayın kapısı (üretim yolu):** `scripts/verify-goldsrc-connection.sh --confirm` uygulamanın kendi kodunu (`scripts/goldsrc-gate/main.swift` + Core) çalıştırır: A2S protokol kararı → GameLauncher planı → izin listeli `open` → kurulu motor (veri kökü APFS klonu). Doğrudan `-dev 2` motor çalıştırması kapı sayılmaz. 2026-11-26 sonucu **PASS**: argv ve motor süreç argümanları/ortamı doğru, `<klon>/engine.log` var (`/engine.log` yok), "Trying to connect with GoldSrc 48 protocol" ve "You have been banned from this server." okundu; yalnız probe `legacyVerificationUnavailable`/`banned: null`/`cid: null`; günlükle `banned`/`banned: true`; gerçek motor, oyun verisi ve kimlik dosyaları değişmedi.

### 75.15 Son inceleme düzeltmeleri (v5.4.4, 2026-11-26)
- **Etkin protokol:** connect 49'a "older protocol ( 48 )" (veya "unsupported protocol") yanıtı sunucunun etkin protokolünü `goldsrc48` yapar: denetim sonucu `goldSrcUnverified` ve `info.serverProtocol = goldsrc48` (kaydedilir; CID uygulanamaz; Join Game `gs`); teşhiste `serverProtocol = goldsrc48`, `cid = nil`, karar `legacyVerificationUnavailable` (`protocolMismatch` değil); CLI JSON `protocol: goldsrc48`, `cid: null`, `cidApplicable: false`, `goldSrc: true`, `banned: null`. Gerçek yanıt (2026-11-26) test fixture'ıdır.
- **Taze Source 49 önceliği:** yenilemede sunucunun taze A2S sonucu `source49` ise eski GoldSrc motor günlüğü kanıtı uygulanmaz ve kanıtlanmış GoldSrc banı korunmaz; taze Source 49 sonucu geçerlidir.
- **Ban ifadesi:** ifade kısayolu yoktur; yalnız tek başına "banned" kelimesi, kendinden önceki üç kelimede olumsuzluk (not, never, no longer, un-, isn't …) yoksa bandır. "not/never/no longer banned from this server", "unbanned from this server", "you were unbanned", "bandwidth limit exceeded" ban değildir.
- **Günlük önce, ağdan bağımsız:** motor günlüğü her yenilemede bir kez okunur ve her sunucuya (ban denetimi isteği olmasa da, sunucu yeni eklenmiş olsa da, A2S zaman aşımında da) adres/oturum/tazelik kurallarıyla uygulanır; günlük banı sunucuyu `goldsrc48` olarak işaretler.
- **Bilinen GoldSrc + ağ/DNS hatası:** bilinen protokol (kayıt/oturum belleği; kaydın GoldSrc sonucundan türetilir) teşhis başında geçerlidir; A2S zaman aşımı veya DNS hatası `banned: false` üretmez (`null`), CID `null`. CLI `status` protokolü kaydın GoldSrc sonucundan türetir.
- **Kalıcılık:** GoldSrc kararı veren yenileme (A2S, connect yanıtı veya günlük) protokolü ve sonucu, eski CID'nin silinmesiyle aynı atomik kayıt yazımında kaydeder. Yeniden başlatma + A2S zaman aşımı sonrasında sunucu GoldSrc kalır (CID yok, `gs`, günlük okunur); karar vermeyen taze sonuca bilinen GoldSrc protokolü taşınır.

### 75.16 CID'siz yetenek denemesi ve DNS kaybında günlük eşleşmesi (v5.4.5, 2026-11-26)
- **Gerçek CID sızıntısı yok:** A2S yanıtı `0x49`/49 olsa da gerçek CID'yi içeren connect 49 tek başına gönderilmez. Challenge'dan sonra önce **CID'siz yetenek denemesi** gider: `uuid` alanı sabit, sıfır yer tutucu (`00000000000000000000000000000000`; kimlikten türetilmez). Yanıt "older protocol ( 48 )" (veya "unsupported protocol") ise sunucu `goldsrc48`'dir; gerçek CID hiç gönderilmez (teşhiste hesaplanmaz da), sonuç `goldSrcUnverified` / `legacyVerificationUnavailable`, `cid = null`. Yanıt yoksa gerçek CID de gönderilmez (`cidUnknown`). Ancak yanıt GoldSrc değilse gerçek CID ban denetimi ikinci pakette, mevcut kurallarla yapılır (otomatik denetim ve kullanıcının başlattığı teşhis; onaysız legacy `getchallenge steam`/connect 48 yine yok).
- **İzin:** "GoldSrc'ye hiçbir gerçek CID gönderilmez" kuralı mutlaktır; "connect 49 hiç gönderilmez" ifadeleri yalnız bilinen/kanıtlanmış GoldSrc 48 ve `unknown` için geçerlidir. Source 49 görünen sunucuya CID'siz yetenek denemesi açıkça izinlidir.
- **DNS kaybında günlük eşleşmesi:** satırın güncel adresi yokken (DNS hatası) motor günlüğü adres adaylarına son başarılı çözümleme ve kayıtlı A2S yanıtının adres dizgisi (`info.reportedAddress`) eklenir; yalnız IP değişmezi alınır (ana makine adı, yol veya başka metin değil), satırın portuyla. Adresi çözülen satır yalnız güncel adresiyle eşleşir.

### 75.17 Yetenek denemesinden sonra gerçek CID kuralı (v5.4.6, 2026-11-26)
Otomatik denetim ve teşhis aynı sınıflandırıcıyı kullanır. Gerçek CID'li ikinci paket **yalnız** yetenek yanıtı açıkça kabul (`B` / `client_connect`) ise **ve** genel süre bütçesi bitmemişse gönderilir (ikinci gönderimden önce açık süre denetimi):
- "older/unsupported protocol" → `goldsrc48`, ikinci paket yok.
- Ban metni → ikinci paket yok; genel/IP ban sonucu (`ipBanned`; teşhiste `ipBanned`/`rangeBanned`), asla CID banı değil.
- Tanınmayan yanıt veya yanıt yok → ikinci paket yok; `cidUnknown` (teşhiste CID doğrulanamadı), `banned` `null` — asla `false`.
- Kabul ama süre bitti → ikinci paket yok; `cidUnknown`, `banned: null`.
CLI `ban --json` `cid` alanını yalnız gerçek CID'li paket yanıtlandığında (`cidOk`/`cidBanned`) yazar.

## 76. Steam kimliğiyle bağlantı (isteğe bağlı, jenerik) — v5.5, uygulama 2.27.0 build 56

### 76.1 Amaç
Oyuncuya bir sunucuya **iki farklı kimlik yoluyla** giriş seçeneği sunmak:

- **Yöntem A — Standart (varsayılan):** Mevcut davranış; oyun motorunun kendi yerel kimlik yolu. Davranış **değişmez**.
- **Yöntem B — Steam kimliğiyle (isteğe bağlı, varsayılan KAPALI):** Gerçek Steam oturumu üzerinden kimlik doğrulama yapan **yerel bir Steam broker** aracılığıyla bağlanma.

Yöntem B **yalnızca kullanıcı açıkça seçtiğinde** kullanılır. Hiçbir sunucu için varsayılan değildir; otomatik seçilmez; kullanıcı seçeneği kapatabilir.

**Kapsam dışı:** Herhangi bir ödeme, abonelik veya entitlement kontrolünün atlatılması; kimlik taklidi; sahte ticket üretimi; sunucu tarafının değiştirilmesi; başka bir oyuncu adına bağlanma.

### 76.2 Kavramsal model
- `JoinIdentity`: `.standard` | `.steamAuth` (yeni tip; `standard` mevcut davranışın karşılığıdır).
- `SteamBrokerEndpoint`: `host` (varsayılan `127.0.0.1`), `port` (varsayılan `27420`), `executablePath` (kullanıcı tarafından belirtilen broker ikilisi).
- `SteamBrokerState`: `.notConfigured` | `.notRunning` | `.listening` | `.unreachable` | `.steamSessionMissing`.
- `ServerIdentityMemory`: sunucu kimliği (normalize edilmiş `host:port`) → **yöntem başına ayrı sonuç**: `{ outcomes: { standard: Outcome?, steamAuth: Outcome? }, lastIdentity, lastAttemptAt }`; `Outcome` = `{ result, at }`, `result` ∈ `.success`, `.rejected`, `.unknown`.
  - **Bir yöntemin sonucu diğerini silmez:** Standart denemesi Steam rozetini (veya tersini) **kaldırmaz**.
  - `Steam ✓ / Steam ✗` rozeti **yalnızca `steamAuth` sonucundan** türetilir; `standard` sonucu rozeti etkilemez.
  - **Sunucu IP/host bilgisi kod veya şablon içine gömülmez**; yalnızca kullanıcının eklediği sunucular için çalışma zamanında tutulur.
- Broker haberleşmesi: **SBK** çerçevesi — header `SBRK` (4 bayt) + uint16 LE uzunluk + payload. Komutlar: `sb_gamedir <gamedir>`, `sb_connect <ip:port> <server_steamid> <secure 0|1> <challenge>`, `sb_disconnect <ip:port> <challenge>`, `sb_terminate`. Ticket cevabı payload'ı: `"sb_connect\n"` + int32 LE challenge + uint64 LE steamid + uint32 LE boyut + ticket baytları.

### 76.3 Broker bulunabilirliği ve yönetimi
1. Ayarlar'da kullanıcı **broker ikilisinin yolunu** tanımlar (serbest metin alanı + "Gözat" seçici). Varsayılan aday yollar denenir (kullanıcının kendi kurulum yerine göre), bulunamazsa kullanıcı yönlendirilir.
2. Uygulama broker'ı **çalıştırmadan önce** doğrular: dosya var mı, çalıştırılabilir mi.
3. Broker **çalışmıyorsa** kullanıcı onayıyla başlatılabilir; bu durumda oyun kapanınca **yalnızca uygulamanın başlattığı** broker kapatılır (kullanıcının kendi başlattığı broker'a dokunulmaz).
   - Broker başlatılırken yapılandırılmış adres **tek argüman olarak** (`<host>:<port>`) geçilir; böylece özel port seçeneği gerçekten uygulanır.
   - Uygulama **kapanırken** de kendi başlattığı broker'ı kapatır (sonlandırma temizliği); aksi hâlde broker artık açıkta kalmasın.
4. Broker çalışıyor ama port dinlenmiyorsa durum `unreachable` olarak raporlanır.
5. Steam oturumu yoksa (broker Steam'e bağlanamıyorsa) durum `steamSessionMissing` olur ve mesaj **“Steam oturumu gerekli”** olur; Steam kimlik bilgisi **hiçbir şekilde uygulamada saklanmaz veya okunmaz**.
   - Steam oturumu varlığı **yalnızca Steam istemci sürecinin çalışıp çalışmadığına bakılarak** kestirilir (işaret göstergesi). Steam ID, ticket, oturum çerezleri **okunmaz, istenmez ve saklanmaz**.
6. Broker yolu/portu **profil dosyasına** yazılabilir; gizli değer yoktur.

### 76.4 Akış: "Steam kimliğiyle gir"
1. Kullanıcı sunucu satırına **sağ tıklar** → “Şunla gir ▾” → **“Steam kimliğiyle”**.
2. **Gizlilik onayı** gösterilir (76.5 metni). Onaylanmadan akış başlamaz.
3. Broker hazırlanır (bulunur / başlatılır / port dinleniyor doğrulanır).
4. Xash, standart başlatma komutuna **ek olarak** `+set cl_ticket_generator steam` argümanıyla başlatılır.
   - Bu argüman **yalnız başlatma satırında** verilir.
   - **Oyun yapılandırma dosyalarına (`config.cfg`, `userconfig.cfg`, `valve/*`) hiçbir şey yazılmaz.**
   - Mevcut `g`, `b`, `n`, `m` bind'larına dokunulmaz.
5. `engine.log` izlenir; **gerçek sunucu cevabı** okunur: başarılı bağlantı, `disconnect reason`, veya zaman aşımı.
6. Sonuç `ServerIdentityMemory`'ye yazılır ve arayüzde gösterilir.
7. Oyun süreci kapanınca, uygulamanın **kendi başlattığı** broker kapatılır.

### 76.5 Gizlilik onay metni (jenerik)
> “Steam kimliğiyle bağlantı, bu sunucuya **gerçek Steam hesabınızın kimliğini (SteamID)** bildirir. Sunucu yöneticisi bu kimliği Steam hesabınıza bağlayabilir. Oyunda görünen isim değişmez.”

Onay **her seçimde** istenir; kalıcı “her zaman onayla” seçeneği sunulmaz.

### 76.6 Arayüz
- **Sunucu satırı sağ tık menüsü:** “Şunla gir ▾” → “Standart” · “Steam kimliğiyle” · “Steam broker ayarları…”. Her yolun yanında durum rozeti gösterilir.
- **Sunucu satırı rozeti:** hafızadaki son sonuca göre `Steam ✓` / `Steam ✗` / (denenmediyse rozet yok).
- **Ayarlar → Bağlantı Yolları** (yeni bölüm): broker ikilisi yolu, port, **canlı durum** (çalışıyor/dinleniyor/Steam oturumu yok), “Broker’ı başlat”, “Broker’ı durdur”, yol doğrulama butonu.
- **GoldSrc 48 algılanan sunucularda** “Steam kimliğiyle” seçeneği **önerilen** olarak işaretlenir (p48 sunucuları çoğunlukla gerçek Steam kimliği ister); bu yalnızca bir **öneridir**, seçim kullanıcıdadır.
- Tüm yeni metinler **26 dil** için lokalizasyon anahtarı olarak eklenir; `check-l10n-parity.sh` kapısı geçmelidir.

### 76.7 CLI / JSON
- `playeridentityctl join --server <host:port> [--identity standard|steam-auth]`.
- JSON çıktısında `identity` alanı bulunur (`standard` / `steam_auth`).
- `--identity steam-auth` için broker yapılandırılmamışsa açık hata döner.

### 76.8 Kabul kriterleri ve testler
1. Mevcut testlerin tamamı geçer; yeni testler eklenir.
2. Sağ tık menüsü iki yöntemi de listeler; “Steam kimliğiyle” **yalnızca** onay sonrası başlar.
3. Onay penceresi reddedilirse **hiçbir süreç başlatılmaz**.
4. Broker yapılandırılmamışsa seçenek pasif görünür ve anlaşılır yönlendirme metni gösterilir.
5. Steam oturumu yoksa hata metni **“Steam oturumu gerekli”** olur.
6. `+set cl_ticket_generator steam` argümanı **yalnız** Steam yönteminde eklenir; standart yöntemde argv **birebir aynı** kalır (regresyon testi).
7. Oyun yapılandırma dosyalarına **hiçbir yazma** yapılmaz (test: dosya içerikleri değişmez).
8. Uygulamanın **kendi başlatmadığı** broker kapatılmaz; kendi başlattığı broker kapanır (test).
9. `engine.log` kanıtı: bağlantı başarısı, disconnect reason ve zaman aşımı üç durumda da ayrıştırılır ve sunucu hafızasına doğru yazılır.
10. Hafıza kalıcıdır (profil dosyası) ve yeniden açılışta korunur; **hafıza dosyasında sunucu adı dışında kişisel veri bulunmaz**.
11. 26 dilde lokalizasyon eşitliği ve `sync-spec.sh --check` kapısı yeşildir.

### 76.9 Sınırlar ve jeneriklik
- Spec, kod, test ve dokümantasyon **hiçbir sunucunun adresini/portunu**, hiçbir SteamID'yi, hiçbir oyuncu adını **içermez**. Özellik herhangi bir sunucuya uygulanabilir.
- Oyuncu adı oyunun kendi yapılandırmasından gelir; uygulama oyuncu adını **değiştirmez**.
- Steam broker **üçüncü taraf yerel bir araçtır**; uygulama broker kodu/kitaplığı **dağıtmaz**, yalnızca kullanıcının tanımladığı ikiliyi çalıştırır. Steam'in kütüphaneleri uygulamaya/dağıtıma **dahil edilmez**.

## 77. Broker bulma ve tek tıkla başlatma (v5.6, uygulama 2.27.1 build 57)

### 77.1 Amaç
§76’daki Steam yönteminin kullanılabilirliğini artırmak: kullanıcı broker ikilisini elle aramak zorunda kalmasın, menüdeki seçenek **neden pasif** olduğunu açıkça görsün ve tek tıkla başlatabilsin.

### 77.2 Broker adaylarının otomatik tespiti
- Uygulama, bilinen konumlarda broker ikilisini arar (sırayla):
  1. `~/Documents/steam-broker/steam-broker`
  2. `~/Applications/Steam Broker.app/Contents/MacOS/steam-broker`
  3. `/opt/homebrew/bin/steam-broker`
  4. `/usr/local/bin/steam-broker`
- **Yalnızca çalıştırılabilir düzenli dosyalar** aday sayılır (sembolik bağ/klasör değil; `isExecutableFile`).
- Ayarlar → Bağlantı Yolları’nda **“Bulunan broker’ı kullan”** düğmesi: ilk bulunan adayı yola yazar (kullanıcı onayı ile). Bulunamazsa düğme pasif ve açıklama gösterilir.
- Yol zaten tanımlıysa otomatik tespit **yol üzerine yazmaz**; yalnız “başka bir broker bulundu” bilgisi gösterilir.
- Tespit **salt okunur**dur; hiçbir dosya oluşturulmaz/değiştirilmez.

### 77.3 Menüde net yönlendirme ve tek tıkla başlatma
- **Yol tanımlı değilse:** “Steam kimliğiyle” pasif görünür; yardım metni **“Ayarlar › Bağlantı Yolları’ndan Steam broker yolunu seçin”** olur. Menüde ayrıca **“Steam broker ayarları…”** öğesi kalır.
- **Yol tanımlı ama broker çalışmıyorsa:** öğe **“Steam kimliğiyle (broker’ı başlat)”** olarak görünür; seçildiğinde gizlilik onayından **sonra** broker başlatılır ve bağlantı kurulur (§76.4 akışı aynen).
- **Broker çalışıyorsa:** öğe normal görünür (“Steam kimliğiyle”).
- Başlatma başarısız olursa: anlaşılır hata + “Tanılama”/ayarlara yönlendirme; **sessiz yutma yok**.
- Uygulamanın kendi başlattığı broker, oyun kapanınca ve uygulama kapanırken durdurulur (§76.3 korunur).

### 77.4 Metinler
- Yeni/değişen metinler 26 dilde lokalize edilir; TR/EN doğrudan, diğer diller çeviri hattıyla (orkestratör).
- Metinler jeneriktir: sunucu adı, SteamID, kişisel veri içermez.

### 77.5 Kabul kriterleri ve testler
1. Aday tespiti: sıra, çalıştırılabilirlik kontrolü, sembolik bağ/klasör reddi; dosya sistemi erişimi olmayan ortamda çökmemeli.
2. “Bulunan broker’ı kullan” yalnız onayla yazar; mevcut yolun üzerine yazmaz.
3. Yol yokken yardım metni **birebir** “Ayarlar › Bağlantı Yolları’ndan Steam broker yolunu seçin”.
4. Yol var + broker kapalıyken menü öğesi “(broker’ı başlat)” varyantını gösterir ve seçimde onaydan sonra başlatır.
5. Başlatma hatası kullanıcıya gösterilir; uygulama çökmez.
6. §76’nın tüm kuralları korunur: oyun cfg’sine yazma yok, yalnız kendi başlattığı broker’ı kapatma, her seçimde gizlilik onayı.
7. Mevcut testler + yeni testler geçer; l10n parity ve `sync-spec.sh --check` yeşil.

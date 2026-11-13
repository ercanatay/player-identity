<!-- Source: specs/player-identity/spec.md; run scripts/sync-spec.sh -->
# Ürün Spesifikasyonu — Cybokron Oyuncu Kimlik Kartı (macOS)

Sürüm: 3.7 · Tarih: 2026-11-13 · Durum: uygulanacak (v3.6 → v3.7: §58 doğrulama düzeltmeleri, §59 ban listesi şablonları, §60 menü çubuğu hızlı CID, §61 çoklu profil)
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

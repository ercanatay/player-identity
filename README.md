# Oyuncu Kimlik Kartı (macOS)

Oyun istemci kimliği verilerini salt okunur gösteren SwiftUI uygulaması. Tek doğruluk kaynağı: spesifikasyon (`spec.md`).
Bu sürüm 1. parçadır: çekirdek mantık (`OyuncuKimlik/Core`) + birim testleri; arayüz iskelet hâlindedir.

Gereksinimler: macOS 14+, Xcode (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project OyuncuKimlik.xcodeproj -scheme OyuncuKimlik -destination 'platform=macOS' -derivedDataPath .build build
xcodebuild -project OyuncuKimlik.xcodeproj -scheme OyuncuKimlik -destination 'platform=macOS' -derivedDataPath .build test
```

Testler ağa ve kullanıcının gerçek dosyalarına bağımlı değildir (geçici klasör fixture'ları + sahte HTTP istemcisi).
Uygulama yalnızca `~/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json` dosyasına yazar.

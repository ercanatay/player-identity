import XCTest
@testable import PlayerIdentity

/// §18.7: localization tables, verbatim Turkish texts, English glossary, language selection and source scan.
@MainActor
final class LocalizationTests: XCTestCase {
    private static let languages = ["tr", "en"]
    private static let turkishLetters = CharacterSet(charactersIn: "çğıöşüÇĞİÖŞÜ")

    private func table(_ name: String, _ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "strings", subdirectory: nil,
                                                localization: language), "\(language).lproj/\(name).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) \(name)")
    }

    private func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(L10n.languageBundle(language), "\(language).lproj")
    }

    private func inTurkish<T>(_ body: () throws -> T) throws -> T { try L10n.$bundle.withValue(bundle("tr"), operation: body) }
    private func inEnglish<T>(_ body: () throws -> T) throws -> T { try L10n.$bundle.withValue(bundle("en"), operation: body) }

    // MARK: Tables (§18.7/1)

    func testEveryKeyHasNonEmptyValueInEveryLanguageAndNoExtraKeys() throws {
        let keys = Set(L10nKey.allCases.map(\.rawValue))
        XCTAssertGreaterThan(keys.count, 150)
        for language in Self.languages {
            let values = try table("Localizable", language)
            XCTAssertEqual(Set(values.keys).subtracting(keys), [], "\(language): keys without an L10nKey case")
            for key in L10nKey.allCases {
                let value = values[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                XCTAssertFalse(value.isEmpty, "\(language): missing/empty \(key.rawValue)")
            }
        }
    }

    func testPlaceholdersMatchAcrossLanguages() throws {
        let tr = try table("Localizable", "tr")
        let en = try table("Localizable", "en")
        for key in L10nKey.allCases {
            let count = { (text: String?) in (text ?? "").components(separatedBy: "%@").count }
            XCTAssertEqual(count(tr[key.rawValue]), count(en[key.rawValue]), key.rawValue)
        }
    }

    func testEnglishTableIsEnglishAndTurkishTableIsTurkish() throws {
        let tr = try table("Localizable", "tr")
        let en = try table("Localizable", "en")
        for (key, value) in en where key != L10nKey.languageTurkish.rawValue {   // §35.2: own-language label
            XCTAssertNil(value.rangeOfCharacter(from: Self.turkishLetters), "Turkish letters in en \(key): \(value)")
        }
        let turkish = tr.values.filter { $0.rangeOfCharacter(from: Self.turkishLetters) != nil }
        XCTAssertGreaterThan(turkish.count, tr.count / 2)
        let different = L10nKey.allCases.filter { tr[$0.rawValue] != en[$0.rawValue] }
        XCTAssertGreaterThan(different.count, tr.count * 9 / 10)
    }

    func testAppNameIsLocalized() throws {
        XCTAssertEqual(try table("InfoPlist", "tr")["CFBundleDisplayName"], "Oyuncu Kimlik Kartı")
        XCTAssertEqual(try table("InfoPlist", "en")["CFBundleDisplayName"], "Player Identity")
        XCTAssertEqual(try table("InfoPlist", "tr")["CFBundleName"], "Oyuncu Kimlik Kartı")
        XCTAssertEqual(try table("InfoPlist", "en")["CFBundleName"], "Player Identity")
        try inTurkish { XCTAssertEqual(L10n.text(.appWindowTitle), "Oyuncu Kimlik Kartı") }
        try inEnglish { XCTAssertEqual(L10n.text(.appWindowTitle), "Player Identity") }
    }

    // MARK: Turkish regression (§18.4, §18.7/2)

    /// §10 and §13.5 verbatim.
    static let specMessages: [MessageCode: String] = [
        .identityMissing: "Kimlik dosyası bulunamadı. Oyun bir kez açıldıktan sonra tekrar deneyin.",
        .identityInvalid: "Kimlik dosyası geçersiz: 16 karakterlik hex bekleniyordu.",
        .publicIPFailed: "Genel IP alınamadı. İnternet bağlantısını kontrol edin.",
        .snapshotMissing: "Kayıt yok. Doğrulama için Kaydet'e basın.",
        .snapshotCorrupt: "Kayıt dosyası okunamadı; yeni kayıt oluşturabilirsiniz.",
        .rawIDZero: "Kimlik donanımdan türetilmemiş (paylaşımlı kimlik).",
        .nameChanged: "Kullanıcı adı kayıttan farklı.",
        .modelChanged: "Oyuncu modeli kayıttan farklı.",
        .publicIPChanged: "Genel IP kayıttan farklı.",
        .lanIPChanged: "Yerel IP listesi kayıttan farklı.",
        .serverCIDChanged: "Sunucu CID'si kayıttan farklı.",
        .invalidHost: "Sunucu adresi geçersiz.",
        .ipBanned: "Sunucu bu IP'yi banlamış.",
        .cidBanned: "Sunucu bu CID'yi banlamış.",
        .unreachable: "Sunucuya erişilemedi (yanıt yok).",
        .banUnknown: "Ban durumu belirlenemedi.",
        .cidNotApplicable: "CID kontrolü bu sunucuda uygulanamaz.",
    ]

    /// §15.8 verbatim.
    static let specEditMessages: [EditMessage: String] = [
        .nameInvalid: "Kullanıcı adı 1–31 karakter olmalı; tırnak ve satır sonu kullanılamaz.",
        .modelInvalid: "Model adı yalnız harf, rakam, alt çizgi ve tire içerebilir.",
        .gameRunning: "Oyun açık. Değişiklikler çıkışta ezilir; önce oyunu kapatın.",
        .writeFailed: "Dosya yazılamadı. Yedekten geri yüklemek için tekrar deneyin.",
        .configMissing: "config.cfg bulunamadı; seçili gamedir doğru mu?",
    ]

    func testTurkishMessagesMatchSpecVerbatim() throws {
        try inTurkish {
            for (code, expected) in Self.specMessages { XCTAssertEqual(code.text, expected, "\(code)") }
            for (code, expected) in SuggestionTests.table { XCTAssertEqual(code.suggestion, expected, "\(code)") }
            for (message, expected) in Self.specEditMessages { XCTAssertEqual(message.text, expected, "\(message)") }
            // §7.4
            XCTAssertEqual(StatusLevel.allCases.map(\.label), ["Tümü tamam", "Dikkat", "Kritik hata"])
            // §13.3
            XCTAssertEqual(BanStatus.ipBanned.label, "IP ban")
            XCTAssertEqual(BanStatus.cidBanned.label, "CID ban")
            XCTAssertEqual(BanStatus.cidOk.label, "Engel yok")
            XCTAssertEqual(BanStatus.unreachable.label, "Erişilemiyor")
            XCTAssertEqual(BanStatus.unknown.label, "Belirsiz")
        }
    }

    func testTurkishFixTextsMatchSpecVerbatim() throws {
        try inTurkish {
            // §17.2
            XCTAssertEqual(IPFixOutcome.resolved(old: "A", new: "B").message, "Çözüldü: IP değişti (A → B), ban kalktı.")
            XCTAssertEqual(IPFixOutcome.stillBanned(old: "A", new: "B").message,
                           "Yeni IP de banlı olabilir (subnet/aralık banı) veya sunucu tüm aralığı engelliyor.")
            XCTAssertEqual(IPFixOutcome.ipUnchanged(ip: "A", routerURL: nil).message, "IP değişmedi.")
            XCTAssertTrue(IPFixOutcome.unchangedNextSteps[1].hasPrefix("VPN kullan"))
            XCTAssertTrue(IPFixOutcome.unchangedNextSteps[2].contains("birkaç saat sonra yeniden dene"))
            // §17.7
            XCTAssertEqual([FixProgress.renewingIP, .waitingForNetwork, .rechecking].map(\.text),
                           ["IP yenileniyor…", "Ağ bekleniyor…", "Yeniden kontrol ediliyor…"])
            XCTAssertEqual(L10n.text(.actionStart), "Başlat")
            XCTAssertEqual(L10n.text(.actionCancel), "Vazgeç")
            XCTAssertEqual(L10n.text(.actionRetry), "Yeniden dene")
            XCTAssertEqual(L10n.text(.actionFix), "Düzelt")
            XCTAssertEqual(L10n.text(.fixOpenRouter), "Router arayüzünü aç")
            // §17.3
            XCTAssertTrue(L10n.text(.fixCIDBanExplanation).hasPrefix("CID banı yerel olarak kaldırılamaz"))
            XCTAssertEqual(L10n.text(.fixCopyAppeal), "Unban mesajını kopyala")
            XCTAssertEqual(L10n.text(.fixOpenServerPage), "Sunucu sayfasını aç")
            XCTAssertEqual(L10n.text(.actionRecheck), "Yeniden kontrol et")
            // §17.9.2, §17.9.3
            XCTAssertTrue(BanClassification.unverifiedText.lowercased().hasPrefix("ban türü doğrulanamadı"))
            let causes = ["Aralık/subnet banı (IP banları kabadır, CGNAT havuzunu bile yakalayabilir)",
                          "Plugin/SQL banı (IP'den bağımsız)", "sv_filterban davranışı"]
            XCTAssertEqual(IPFixOutcome.stillBannedReasons.map { String($0.dropLast()) }, causes)
            // §17.10
            XCTAssertEqual(IPRange.displayText(for: "198.51.100.10"), "Aralık: 198.51.100.0/24 · 198.51.0.0/16")
            XCTAssertEqual(IPFixOutcome.rangeBanned(old: "A", new: "B", cidr: "198.51.0.0/16").message,
                           "IP aralığı banı (198.51.0.0/16)")
            let range = IPFixOutcome.rangeBannedSuggestions
            XCTAssertEqual(range[0], "IP yenilemek işe yaramaz; aynı aralıktasınız.")
            XCTAssertEqual(range[1], "Farklı ağ dene: mobil hotspot (tethering) veya çıkışı farklı aralıkta olan VPN.")
            XCTAssertTrue(range[2].hasPrefix("Sunucu yöneticisinden aralık banını kaldırmasını iste"))
            XCTAssertEqual(L10n.format(.appealRangeBan, "198.51.0.0/16", "A", "B"),
                           "Muhtemel aralık banı: 198.51.0.0/16 (eski IP: A, yeni IP: B)")
        }
    }

    func testTurkishUITextsMatchSpecVerbatim() throws {
        try inTurkish {
            XCTAssertEqual(L10n.text(.actionRefresh), "Yenile")            // §6
            XCTAssertEqual(L10n.text(.actionSave), "Kaydet")               // §8
            XCTAssertEqual(L10n.text(.actionApply), "Uygula")              // §15.7
            XCTAssertEqual(L10n.text(.topbarUnsaved), "Kaydedilmedi")      // §5
            XCTAssertEqual(L10n.text(.quitTitle), "Kaydetmeden çık?")      // §8
            XCTAssertEqual(L10n.text(.serversEmpty), "Henüz sunucu eklenmedi")
            XCTAssertEqual(L10n.text(.serverAdd), "Sunucu Ekle")
            XCTAssertEqual(L10n.text(.actionCopied), "Kopyalandı")
            XCTAssertEqual(L10n.text(.actionDelete), "Sil")
            XCTAssertEqual(L10n.format(.topbarLastCheck, "12:00:00"), "Son kontrol: 12:00:00")
            XCTAssertEqual(L10n.text(.topbarWhatToDo), "Ne yapmalı?")      // §14.2
            XCTAssertEqual(L10n.text(.actionCopy), "Kopyala")
            XCTAssertEqual(L10n.text(.settingsBanCheck), "Ban kontrolü")  // §13.1
            XCTAssertEqual(ConfigFileKind.userconfig.note, "userconfig.cfg (config.cfg'yi ezer)")   // §15.2
            XCTAssertEqual(PlayerOptions.modelOptions(available: [], current: "x").first?.label, "x (mevcut)")
            XCTAssertEqual(ModelPopUpButton.manualEntryTitle, "Elle gir…")   // §15.3
            XCTAssertEqual(L10n.text(.profileNewName), "Yeni ad…")           // §15.4
        }
    }

    // MARK: English (§18.5)

    func testEnglishFollowsGlossary() throws {
        try inEnglish {
            XCTAssertEqual(L10n.text(.actionRefresh), "Refresh")
            XCTAssertEqual(L10n.text(.actionSave), "Save")
            XCTAssertEqual(L10n.text(.actionApply), "Apply")
            XCTAssertEqual(L10n.text(.actionFix), "Fix")
            XCTAssertEqual(L10n.text(.reasonsTitle), "Reasons")
            XCTAssertEqual(L10n.text(.fixSuggestionsTitle), "Suggestions")
            XCTAssertEqual(L10n.text(.networkRange), "Range")
            XCTAssertEqual(L10n.text(.networkPublicIP), "Public IP")
            XCTAssertEqual(L10n.text(.networkLocalIPs), "Local IPs")
            XCTAssertEqual(L10n.text(.profileRawID), "Raw identity")
            XCTAssertEqual(L10n.text(.profileIdentitySource), "Identity source")
            XCTAssertEqual(L10n.text(.serversTitle), "Servers")
            XCTAssertEqual(L10n.text(.profileModel), "Player model")
            XCTAssertTrue(L10n.text(.errorSnapshotMissing).contains("No record"))
            XCTAssertTrue(BanClassification.unverifiedText.hasPrefix("Ban type unverified"))
            XCTAssertTrue(IPFixOutcome.rangeBanned(old: "A", new: "B", cidr: "1.2.0.0/16").message.hasPrefix("IP range ban"))
            XCTAssertEqual(BanStatus.cidOk.label, "No block")
            XCTAssertEqual(BanStatus.unreachable.label, "Unreachable")
        }
    }

    // MARK: Language switch (§18.1, §18.7/4)

    func testLanguageSelectionFollowsSystemAndFallsBackToEnglish() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        XCTAssertEqual(Set(Bundle.main.localizations).intersection(["tr", "en"]), ["tr", "en"])
        let localizations = Bundle.main.localizations
        XCTAssertEqual(Bundle.preferredLocalizations(from: localizations, forPreferences: ["en"]).first, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: localizations, forPreferences: ["tr"]).first, "tr")
        XCTAssertEqual(Bundle.preferredLocalizations(from: localizations, forPreferences: ["tr-TR"]).first, "tr")
        XCTAssertEqual(Bundle.preferredLocalizations(from: localizations, forPreferences: ["de-DE"]).first, "en")
    }

    func testWholeTextsSwitchWithLanguage() throws {
        let check = BanCheck(status: .ipBanned, checkedAt: Date(timeIntervalSince1970: 1_793_000_000), detail: "ipBanned: x")
        let input = AppealInput(serverLabel: "S", host: "51.68.190.91", port: 27015, checkedAt: check.checkedAt,
                                playerName: "P", cid: "c", publicIP: "198.51.100.10", gamedir: "valve", check: check,
                                rangeBan: RangeBanInfo(cidr: "198.51.0.0/16", oldIP: "A", newIP: "B"))
        let english = try inEnglish { () -> String in
            XCTAssertEqual(MessageCode.ipBanned.text, "The server has banned this IP.")
            XCTAssertEqual(IPRange.displayText(for: "198.51.100.10"), "Range: 198.51.100.0/24 · 198.51.0.0/16")
            XCTAssertEqual(PlayerOptions.modelOptions(available: [], current: "x").first?.label, "x (current)")
            return AppealText.make(input)
        }
        for line in ["Hello,", "Server: S (51.68.190.91:27015)", "(local)", "Player name: P", "Egress IP: 198.51.100.10",
                     "Check type: engine IP (getchallenge)", "Possible range ban: 198.51.0.0/16 (old IP: A, new IP: B)",
                     "Checklist for the admin:", "  1. Find the entry with listid and listip."] {
            XCTAssertTrue(english.contains(line), "missing \(line)\n\(english)")
        }
        XCTAssertNil(english.rangeOfCharacter(from: Self.turkishLetters), english)

        let turkish = try inTurkish { AppealText.make(input) }
        XCTAssertTrue(turkish.contains("Yönetici için kontrol listesi:"))
        XCTAssertTrue(turkish.contains("Çıkış IP'si: 198.51.100.10"))
    }

    // MARK: Accessibility (§18.7/5)

    func testAccessibilityLabelsAreLocalized() throws {
        let view = ModelPreviewView(preview: .placeholder, modelName: "gordon")
        try inEnglish {
            XCTAssertEqual(StatusLevel.red.label, "Critical error")
            XCTAssertEqual(L10n.format(.a11yBan, BanStatus.ipBanned.label), "Ban: IP ban")
            XCTAssertEqual(L10n.format(.a11yProfileModel, "gordon"), "Player model: gordon")
            XCTAssertEqual(L10n.format(.a11yProfileName, "P"), "Player name: P")
            XCTAssertEqual(L10n.text(.serverNotChecked), "Not checked")
            XCTAssertEqual(view.accessibilityText, "No model preview: gordon")
        }
        try inTurkish {
            XCTAssertEqual(StatusLevel.red.label, "Kritik hata")
            XCTAssertEqual(L10n.format(.a11yProfileModel, "gordon"), "Oyuncu modeli: gordon")
            XCTAssertEqual(view.accessibilityText, "Model önizlemesi yok: gordon")
        }
    }

    // MARK: Source scan (§18.3, §18.7/3)

    func testAppAndCoreSourcesContainNoUserFacingLiterals() throws {
        // The test bundle carries copies of `PlayerIdentity/App` and `PlayerIdentity/Core` (folder resources), so the
        // scan never reads the repository directly (no Documents-folder access from the test host).
        let resources = try XCTUnwrap(Bundle(for: LocalizationTests.self).resourceURL)
        var files: [URL] = []
        for folder in ["App", "Core"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: resources.appendingPathComponent(folder),
                                                                          includingPropertiesForKeys: nil), folder)
            files += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        XCTAssertGreaterThan(files.count, 20)
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            violations += LiteralScanner.violations(in: source).map { "\(file.lastPathComponent):\($0)" }
        }
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testScannerDetectsUserFacingLiterals() {
        let sample = """
        Text("Merhaba")
        Button("Save") { }
        x.help("Copy")
        alert.messageText = "Quit"
        func a() -> String { return "Attention" }
        let b = "two words"
        let c = "Ağ"
        Text(L10n.text(.actionSave))
        Image(systemName: "doc.on.doc")
        Text(verbatim: "\\(host):\\(port)")
        // Text("comment")
        let d = "config.cfg"
        """
        XCTAssertEqual(LiteralScanner.violations(in: sample).count, 7, LiteralScanner.violations(in: sample).joined(separator: "\n"))
    }
}

/// Finds string literals in Swift source that look like user-facing text (§18.3).
///
/// Rules: (A) no non-ASCII letters in literals; (B) no multi-word phrases unless allowlisted as technical
/// (protocol strings, paths, shell scripts, log messages); (C) no letters in a literal passed directly to a
/// SwiftUI/AppKit text API; (D) no capitalized word returned as a literal.
enum LiteralScanner {
    private static let technicalPhrases = [
        "TSource Engine Query", "Application Support", "Xash3D FWGS", "do shell script", "unsupported protocol",
        "Power \\(", "Data migration:", "HH:mm:ss",
        "Notarized Developer ID",
    ]
    private static let uiAPI = try! NSRegularExpression(pattern:
        #"(\b(Text|Button|Label|Toggle|TextField|SecureField|LabeledContent|Picker|Menu|Window|Section|GroupBox|Link|Card|FieldRow|ServerFormSheet)\(\s*((title|confirmTitle):\s*)?|\.(help|accessibilityLabel|accessibilityHint|accessibilityValue|alert|navigationTitle|setAccessibilityLabel)\(\s*|\b(messageText|informativeText|prompt|message|title)\s*=\s*|withTitle:\s*|confirmTitle:\s*)$"#)
    private static let multiWord = try! NSRegularExpression(pattern: #"[A-Za-z]{2,} +[A-Za-z]{2,}"#)
    private static let capitalizedReturn = try! NSRegularExpression(pattern: #"\breturn\s*$"#)

    struct Literal {
        let line: Int
        let text: String      // interpolations replaced by U+0001
        let prefix: String    // code before the literal on the same line
    }

    static func violations(in source: String) -> [String] {
        literals(in: source).compactMap { literal in
            let text = literal.text
            func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
                regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
            }
            if text.unicodeScalars.contains(where: { $0.value > 127 && CharacterSet.letters.contains($0) }) {
                return "\(literal.line) non-ASCII letters: \(text)"
            }
            let hasLetters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            if matches(multiWord, text), !technicalPhrases.contains(where: text.contains) {
                return "\(literal.line) phrase: \(text)"
            }
            if hasLetters, matches(uiAPI, literal.prefix) {
                return "\(literal.line) UI literal: \(text)"
            }
            if matches(capitalizedReturn, literal.prefix),
               text.range(of: #"^[A-Z][a-z]+"#, options: .regularExpression) != nil {
                return "\(literal.line) returned word: \(text)"
            }
            return nil
        }
    }

    static func literals(in source: String) -> [Literal] {
        let chars = Array(source)
        var result: [Literal] = []
        var i = 0, line = 1, lineStart = 0
        func peek(_ s: String, at index: Int) -> Bool {
            let p = Array(s)
            return index + p.count <= chars.count && Array(chars[index..<index + p.count]) == p
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; lineStart = i + 1; i += 1; continue }
            if peek("//", at: i) {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if peek("/*", at: i) {
                i += 2
                while i < chars.count, !peek("*/", at: i) { if chars[i] == "\n" { line += 1; lineStart = i + 1 }; i += 1 }
                i += 2
                continue
            }
            let raw = peek("#\"", at: i)
            guard raw || c == "\"" else { i += 1; continue }
            let prefix = String(chars[lineStart..<i])
            let startLine = line
            let triple = peek(raw ? "#\"\"\"" : "\"\"\"", at: i)
            i += (raw ? 1 : 0) + (triple ? 3 : 1)
            let terminator = (triple ? "\"\"\"" : "\"") + (raw ? "#" : "")
            var text = ""
            while i < chars.count, !peek(terminator, at: i) {
                if chars[i] == "\\", i + 1 < chars.count {
                    let interpolation = raw ? peek("\\#(", at: i) : chars[i + 1] == "("
                    if interpolation {
                        i += raw ? 3 : 2
                        var depth = 1
                        while i < chars.count, depth > 0 {
                            if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                            if chars[i] == "\"" {   // skip nested string inside the interpolation
                                i += 1
                                while i < chars.count, chars[i] != "\"" { if chars[i] == "\\" { i += 1 }; i += 1 }
                            }
                            i += 1
                        }
                        text.append("\u{1}")
                        continue
                    }
                    if !raw { text.append(chars[i + 1]); i += 2; continue }
                }
                if chars[i] == "\n" { line += 1; lineStart = i + 1 }
                text.append(chars[i])
                i += 1
            }
            i += terminator.count
            result.append(Literal(line: startLine, text: text, prefix: prefix))
        }
        return result
    }
}

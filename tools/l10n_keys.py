#!/usr/bin/env python3
"""Single source of the localization keys.

Generates:
  PlayerIdentity/Core/L10nKey.swift
  PlayerIdentity/Resources/{tr,en}.lproj/Localizable.strings

Usage: python3 tools/l10n_keys.py   (run from the repository root)

Each entry: (swift case, key, Turkish value, English value). Turkish values are the
source texts (spec §10, §13.5, §14.3, §15.8, §17) and must stay verbatim.
"""
import os

KEYS = [
    # App, menus, common actions
    ("appWindowTitle", "app.windowTitle", "Oyuncu Kimlik Kartı", "Player Identity"),
    ("actionRefresh", "action.refresh", "Yenile", "Refresh"),
    ("actionSave", "action.save", "Kaydet", "Save"),
    ("actionApply", "action.apply", "Uygula", "Apply"),
    ("actionFix", "action.fix", "Düzelt", "Fix"),
    ("actionCancel", "action.cancel", "Vazgeç", "Cancel"),
    ("actionOK", "action.ok", "Tamam", "OK"),
    ("actionCopy", "action.copy", "Kopyala", "Copy"),
    ("actionCopied", "action.copied", "Kopyalandı", "Copied"),
    ("actionClose", "action.close", "Kapat", "Close"),
    ("actionDelete", "action.delete", "Sil", "Delete"),
    ("actionEdit", "action.edit", "Düzenle", "Edit"),
    ("actionAdd", "action.add", "Ekle", "Add"),
    ("actionStart", "action.start", "Başlat", "Start"),
    ("actionRetry", "action.retry", "Yeniden dene", "Try Again"),
    ("actionRecheck", "action.recheck", "Yeniden kontrol et", "Check Again"),
    ("actionAbort", "action.abort", "İptal", "Cancel"),
    ("helpRefresh", "help.refresh", "Yenile (⌘R)", "Refresh (⌘R)"),
    ("helpSave", "help.save", "Kaydet (⌘S)", "Save (⌘S)"),
    ("helpApply", "help.apply", "Uygula (⌘⏎)", "Apply (⌘⏎)"),

    # Quit confirmation
    ("quitTitle", "quit.title", "Kaydetmeden çık?", "Quit without saving?"),
    ("quitMessage", "quit.message", "Kaydedilmemiş değişiklikler kaybolacak.", "Unsaved changes will be lost."),
    ("quitConfirm", "quit.confirm", "Kaydetmeden Çık", "Quit Without Saving"),

    # Status (§7.4)
    ("statusGreenTitle", "status.green.title", "Tümü tamam", "All good"),
    ("statusOrangeTitle", "status.orange.title", "Dikkat", "Attention"),
    ("statusRedTitle", "status.red.title", "Kritik hata", "Critical error"),

    # Top bar
    ("topbarWhatToDo", "topbar.whatToDo", "Ne yapmalı?", "What to do?"),
    ("topbarChecking", "topbar.checking", "Kontrol ediliyor…", "Checking…"),
    ("topbarNotChecked", "topbar.notChecked", "Henüz kontrol edilmedi", "Not checked yet"),
    ("topbarLastCheck", "topbar.lastCheck", "Son kontrol: %@", "Last check: %@"),
    ("topbarUnsaved", "topbar.unsaved", "Kaydedilmedi", "Unsaved"),

    # Alerts
    ("alertNewNameTitle", "alert.newName.title", "Yeni ad", "New name"),
    ("alertManualModelTitle", "alert.manualModel.title", "Model adı", "Model name"),
    ("alertSaveFailedTitle", "alert.saveFailed.title", "Kayıt yazılamadı", "Could not save the record"),
    ("saveFailed", "save.failed", "Kayıt yazılamadı: %@", "Could not save the record: %@"),

    # Profile card
    ("profileTitle", "profile.title", "Profil", "Profile"),
    ("profileName", "profile.name", "Kullanıcı adı", "Player name"),
    ("profileModel", "profile.model", "Oyuncu modeli", "Player model"),
    ("profileNewName", "profile.newName", "Yeni ad…", "New name…"),
    ("profileRawID", "profile.rawID", "Ham kimlik", "Raw identity"),
    ("profileIdentitySource", "profile.identitySource", "Kimlik kaynağı", "Identity source"),
    ("profileGamedir", "profile.gamedir", "Gamedir", "Gamedir"),
    ("profileNoGamedir", "profile.noGamedir", "Gamedir bulunamadı", "No gamedir found"),
    ("profileDataRoot", "profile.dataRoot", "Veri kökü", "Data root"),
    ("profileChooseFolder", "profile.chooseFolder", "Klasör Seç…", "Choose Folder…"),
    ("profilePanelPrompt", "profile.panel.prompt", "Seç", "Choose"),
    ("profilePanelMessage", "profile.panel.message", "Oyun veri kökü klasörünü seçin", "Choose the game data root folder"),
    ("profileSourceConfig", "profile.source.config", "config.cfg", "config.cfg"),
    ("profileSourceUserconfig", "profile.source.userconfig", "userconfig.cfg (config.cfg'yi ezer)", "userconfig.cfg (overrides config.cfg)"),
    ("profileApplied", "profile.applied", "Uygulandı · %@", "Applied · %@"),
    ("profileModelCurrent", "profile.model.current", "%@ (mevcut)", "%@ (current)"),
    ("profileModelManualEntry", "profile.model.manualEntry", "Elle gir…", "Enter manually…"),

    # Name/model editing (§15.8)
    ("editNameInvalid", "edit.nameInvalid", "Kullanıcı adı 1–31 karakter olmalı; tırnak ve satır sonu kullanılamaz.", "The player name must be 1–31 characters; quotes and line breaks are not allowed."),
    ("editModelInvalid", "edit.modelInvalid", "Model adı yalnız harf, rakam, alt çizgi ve tire içerebilir.", "The model name may only contain letters, digits, underscores and hyphens."),
    ("editGameRunning", "edit.gameRunning", "Oyun açık. Değişiklikler çıkışta ezilir; önce oyunu kapatın.", "The game is running. Changes would be overwritten when it quits; close the game first."),
    ("editWriteFailed", "edit.writeFailed", "Dosya yazılamadı. Yedekten geri yüklemek için tekrar deneyin.", "Could not write the file. Try again to restore from the backup."),
    ("editConfigMissing", "edit.configMissing", "config.cfg bulunamadı; seçili gamedir doğru mu?", "config.cfg not found; is the selected gamedir correct?"),

    # Network card
    ("networkTitle", "network.title", "Ağ", "Network"),
    ("networkPublicIP", "network.publicIP", "Genel IP", "Public IP"),
    ("networkUnavailable", "network.unavailable", "Alınamadı", "Unavailable"),
    ("networkRange", "network.range", "Aralık", "Range"),
    ("networkRangeValue", "network.range.value", "Aralık: %@ · %@", "Range: %@ · %@"),
    ("networkLocalIPs", "network.localIPs", "Yerel IP'ler", "Local IPs"),

    # Servers
    ("serversTitle", "servers.title", "Sunucular", "Servers"),
    ("serversEmpty", "servers.empty", "Henüz sunucu eklenmedi", "No servers added yet"),
    ("serverAdd", "server.add", "Sunucu Ekle", "Add Server"),
    ("serverEditTitle", "server.edit.title", "Sunucuyu Düzenle", "Edit Server"),
    ("serverNotChecked", "server.notChecked", "Kontrol edilmedi", "Not checked"),
    ("serverCopyHint", "server.copyHint", "Kopyalamak için tıklayın", "Click to copy"),
    ("serverFormLabel", "server.form.label", "Etiket", "Label"),
    ("serverFormHost", "server.form.host", "Host (IP veya alan adı)", "Host (IP or domain name)"),
    ("serverFormPort", "server.form.port", "Port", "Port"),
    ("serverProblemLabelEmpty", "server.problem.labelEmpty", "Etiket boş olamaz.", "Label cannot be empty."),
    ("serverProblemHostEmpty", "server.problem.hostEmpty", "Host boş olamaz.", "Host cannot be empty."),
    ("serverProblemPortInvalid", "server.problem.portInvalid", "Port 1–65535 arasında bir sayı olmalı.", "Port must be a number between 1 and 65535."),

    # Reasons
    ("reasonsTitle", "reasons.title", "Gerekçeler", "Reasons"),

    # Settings
    ("settingsBanCheck", "settings.banCheck", "Ban kontrolü", "Ban check"),

    # Messages (§10, derived §7.2 texts, §13.5)
    ("errorIdentityMissing", "error.identityMissing", "Kimlik dosyası bulunamadı. Oyun bir kez açıldıktan sonra tekrar deneyin.", "Identity file not found. Try again after launching the game once."),
    ("errorIdentityInvalid", "error.identityInvalid", "Kimlik dosyası geçersiz: 16 karakterlik hex bekleniyordu.", "Identity file is invalid: expected 16 hex characters."),
    ("errorPublicIPFailed", "error.publicIPFailed", "Genel IP alınamadı. İnternet bağlantısını kontrol edin.", "Could not get the public IP. Check your internet connection."),
    ("errorSnapshotMissing", "error.snapshotMissing", "Kayıt yok. Doğrulama için Kaydet'e basın.", "No record. Press Save to enable verification."),
    ("errorSnapshotCorrupt", "error.snapshotCorrupt", "Kayıt dosyası okunamadı; yeni kayıt oluşturabilirsiniz.", "The record file could not be read; you can create a new record."),
    ("errorRawIDZero", "error.rawIDZero", "Kimlik donanımdan türetilmemiş (paylaşımlı kimlik).", "The identity is not derived from hardware (shared identity)."),
    ("errorNameChanged", "error.nameChanged", "Kullanıcı adı kayıttan farklı.", "The player name differs from the record."),
    ("errorModelChanged", "error.modelChanged", "Oyuncu modeli kayıttan farklı.", "The player model differs from the record."),
    ("errorPublicIPChanged", "error.publicIPChanged", "Genel IP kayıttan farklı.", "The public IP differs from the record."),
    ("errorLanIPChanged", "error.lanIPChanged", "Yerel IP listesi kayıttan farklı.", "The local IP list differs from the record."),
    ("errorServerCIDChanged", "error.serverCIDChanged", "Sunucu CID'si kayıttan farklı.", "The server CID differs from the record."),
    ("errorInvalidHost", "error.invalidHost", "Sunucu adresi geçersiz.", "Invalid server address."),
    ("errorLanIPMissing", "error.lanIPMissing", "Yerel IP bulunamadı.", "No local IP found."),
    ("errorNameEmpty", "error.nameEmpty", "Kullanıcı adı boş.", "The player name is empty."),
    ("errorModelEmpty", "error.modelEmpty", "Oyuncu modeli boş.", "The player model is empty."),
    ("errorIPBanned", "error.ipBanned", "Sunucu bu IP'yi banlamış.", "The server has banned this IP."),
    ("errorCIDBanned", "error.cidBanned", "Sunucu bu CID'yi banlamış.", "The server has banned this CID."),
    ("errorUnreachable", "error.unreachable", "Sunucuya erişilemedi (yanıt yok).", "The server could not be reached (no reply)."),
    ("errorBanUnknown", "error.banUnknown", "Ban durumu belirlenemedi.", "The ban status could not be determined."),
    ("errorCIDNotApplicable", "error.cidNotApplicable", "CID kontrolü bu sunucuda uygulanamaz.", "The CID check does not apply to this server."),

    # Suggestions (§14.3, derived texts for §7.2 codes)
    ("suggestionIPBanned", "suggestion.ipBanned", "IP'nizi değiştirin: modemi/routerı 5 dakika kapatıp açın; IP değişmezse VPN kullanın. Ban süreli olabilir, birkaç saat sonra tekrar deneyin. Kalıcıysa sunucu yöneticisinden kaldırmasını isteyin.", "Change your IP: turn the modem/router off for 5 minutes and back on; if the IP does not change, use a VPN. The ban may be temporary, so try again in a few hours. If it is permanent, ask the server admin to remove it."),
    ("suggestionCIDBanned", "suggestion.cidBanned", "IP değiştirmek yetmez, bu CID (authid) engelli. Sunucu yöneticisinden kaldırmasını isteyin. Bu kimlik bu makinede paylaşımlı üretildiği için başka bir istemcinin banı da size yansıyabilir.", "Changing the IP is not enough; this CID (authid) is blocked. Ask the server admin to remove it. Because this identity is generated as shared on this machine, another client's ban may also affect you."),
    ("suggestionUnreachable", "suggestion.unreachable", "Sunucu kapalı olabilir veya UDP erişimi engellenmiştir. GameTracker sayfasından sunucunun canlı olduğunu doğrulayın; güvenlik duvarı/VPN'yi kontrol edin.", "The server may be down or UDP access may be blocked. Confirm on its GameTracker page that the server is online; check your firewall/VPN."),
    ("suggestionBanUnknown", "suggestion.banUnknown", "Sunucu bu tür sorgulara yanıt vermiyor olabilir. Birkaç dakika sonra Yenile'ye basın; sorun sürerse sunucu yöneticisine danışın.", "The server may not answer this kind of query. Press Refresh in a few minutes; if the problem persists, contact the server admin."),
    ("suggestionCIDNotApplicable", "suggestion.cidNotApplicable", "Bu sunucu eski oyun protokolünü kullanıyor; CID banı burada test edilemez. IP ban sonucu geçerlidir.", "This server uses the old game protocol; a CID ban cannot be tested here. The IP ban result is valid."),
    ("suggestionIdentityMissing", "suggestion.identityMissing", "Oyunu bir kez başlatıp kapatın; kimlik dosyası otomatik oluşur, sonra Yenile'ye basın.", "Launch and quit the game once; the identity file is created automatically. Then press Refresh."),
    ("suggestionIdentityInvalid", "suggestion.identityInvalid", "Kimlik dosyası bozulmuş. Dosyayı silin, oyunu bir kez açıp kapatın; yeniden oluşturulur.", "The identity file is corrupt. Delete it, then launch and quit the game once; it will be recreated."),
    ("suggestionPublicIPFailed", "suggestion.publicIPFailed", "İnternet bağlantısını kontrol edin. VPN/güvenlik duvarı bu isteği engelliyor olabilir.", "Check your internet connection. A VPN/firewall may be blocking this request."),
    ("suggestionSnapshotMissing", "suggestion.snapshotMissing", "Doğrulama yapılabilmesi için Kaydet'e basarak referans kaydı oluşturun.", "Press Save to create a reference record so verification can run."),
    ("suggestionSnapshotCorrupt", "suggestion.snapshotCorrupt", "Kayıt dosyası okunamıyor. Kaydet'e basarak yeni kayıt oluşturun.", "The record file cannot be read. Press Save to create a new record."),
    ("suggestionRawIDZero", "suggestion.rawIDZero", "Bu sürümde beklenen durum: kimlik donanımdan üretilmiyor. Ban riski taşır, çünkü aynı CID tüm benzer kurulumlarda geçerli.", "Expected in this version: the identity is not generated from hardware. This carries a ban risk, because the same CID is valid on all similar installations."),
    ("suggestionNameChanged", "suggestion.nameChanged", "Oyundaki isim değişmiş. Bilinçli yaptıysanız Kaydet'e basın, aksi hâlde oyun ayarlarını kontrol edin.", "The in-game name has changed. If you did this on purpose, press Save; otherwise check the game settings."),
    ("suggestionModelChanged", "suggestion.modelChanged", "Oyuncu modeli değişmiş. Bilinçli yaptıysanız Kaydet'e basın.", "The player model has changed. If you did this on purpose, press Save."),
    ("suggestionPublicIPChanged", "suggestion.publicIPChanged", "IP'niz değişmiş (dinamik IP'de normal). Doğru değer buysa Kaydet'e basın.", "Your IP has changed (normal with a dynamic IP). If this is the correct value, press Save."),
    ("suggestionLanIPChanged", "suggestion.lanIPChanged", "Yerel ağ değişmiş (Wi-Fi/Ethernet geçişi olabilir). Bilinçliyse Kaydet'e basın.", "The local network has changed (possibly a Wi-Fi/Ethernet switch). If intended, press Save."),
    ("suggestionServerCIDChanged", "suggestion.serverCIDChanged", "Sunucu CID'si kayıttan farklı; kimlik kaynağı değişmiş olabilir. Yenile'den sonra Kaydet'e basın.", "The server CID differs from the record; the identity source may have changed. Press Save after Refresh."),
    ("suggestionInvalidHost", "suggestion.invalidHost", "Adresi IP:port biçiminde girin (örn. 51.68.190.91:27015).", "Enter the address as IP:port (e.g. 51.68.190.91:27015)."),
    ("suggestionLanIPMissing", "suggestion.lanIPMissing", "Ağ bağlantısını (Wi-Fi/Ethernet) kontrol edin, sonra Yenile'ye basın.", "Check the network connection (Wi-Fi/Ethernet), then press Refresh."),
    ("suggestionNameEmpty", "suggestion.nameEmpty", "Oyunda bir oyuncu adı belirleyin, oyunu kapatıp Yenile'ye basın.", "Set a player name in the game, quit the game and press Refresh."),
    ("suggestionModelEmpty", "suggestion.modelEmpty", "Oyunda bir oyuncu modeli seçin, oyunu kapatıp Yenile'ye basın.", "Choose a player model in the game, quit the game and press Refresh."),

    # Ban column (§13.3)
    ("banStatusIPBanned", "ban.status.ipBanned", "IP ban", "IP ban"),
    ("banStatusCIDBanned", "ban.status.cidBanned", "CID ban", "CID ban"),
    ("banStatusNoBlock", "ban.status.noBlock", "Engel yok", "No block"),
    ("banStatusUnreachable", "ban.status.unreachable", "Erişilemiyor", "Unreachable"),
    ("banStatusUnknown", "ban.status.unknown", "Belirsiz", "Unknown"),
    ("banUnverified", "ban.unverified", "Ban türü doğrulanamadı (plugin/SQL olabilir)", "Ban type unverified (may be plugin/SQL)"),

    # Accessibility
    ("a11yBan", "a11y.ban", "Ban: %@", "Ban: %@"),
    ("a11yReason", "a11y.reason", "%@: %@", "%@: %@"),
    ("a11yProfileName", "a11y.profile.name", "Kullanıcı adı: %@", "Player name: %@"),
    ("a11yProfileModel", "a11y.profile.model", "Oyuncu modeli: %@", "Player model: %@"),
    ("a11yPreviewImage", "a11y.preview.image", "Model önizlemesi: %@", "Model preview: %@"),
    ("a11yPreviewPlaceholder", "a11y.preview.placeholder", "Model önizlemesi yok: %@", "No model preview: %@"),
    ("a11yPreviewLoading", "a11y.preview.loading", "Model önizlemesi yükleniyor: %@", "Loading model preview: %@"),

    # Fix sheet (§17)
    ("fixTitleIPBan", "fix.title.ipBan", "IP banını düzelt", "Fix IP ban"),
    ("fixTitleCIDBan", "fix.title.cidBan", "CID banı", "CID ban"),
    ("fixTitleUnreachable", "fix.title.unreachable", "Sunucuya erişilemiyor", "Server unreachable"),
    ("fixCurrentIP", "fix.currentIP", "Mevcut genel IP", "Current public IP"),
    ("fixStepsTitle", "fix.steps.title", "Yapılacaklar", "Steps"),
    ("fixIPBanStep1", "fix.ipBan.step1", "Mevcut genel IP kaydedilir.", "The current public IP is recorded."),
    ("fixIPBanStep2", "fix.ipBan.step2", "Varsayılan ağ arayüzü bulunur (route get default).", "The default network interface is found (route get default)."),
    ("fixIPBanStep3", "fix.ipBan.step3", "Wi-Fi ise Wi-Fi 3 sn kapatılıp açılır; Ethernet ise DHCP yenilenir (macOS yönetici onayı ister).", "On Wi-Fi, Wi-Fi is turned off for 3 s and back on; on Ethernet, DHCP is renewed (macOS asks for administrator approval)."),
    ("fixIPBanStep4", "fix.ipBan.step4", "Ağ en çok 45 sn beklenir; yeni genel IP alınır.", "The app waits up to 45 s for the network; the new public IP is fetched."),
    ("fixIPBanStep5", "fix.ipBan.step5", "IP değiştiyse bu sunucu için ban yeniden kontrol edilir.", "If the IP changed, the ban is checked again for this server."),
    ("fixOutage", "fix.outage", "Tahmini kesinti: 5–20 sn.", "Estimated outage: 5–20 s."),
    ("fixRisk", "fix.risk", "Risk: IP değişimi garanti değildir; ISS statik IP, CGNAT veya router PPPoE oturumu IP'yi koruyabilir. Kesinti sırasında diğer bağlantılar kopabilir. Yönetici parolası yalnız macOS diyaloğunda istenir; uygulama parolayı görmez ve saklamaz.", "Risk: an IP change is not guaranteed; a static IP from your ISP, CGNAT or the router's PPPoE session may keep the IP. Other connections may drop during the outage. The administrator password is only requested in the macOS dialog; the app never sees or stores it."),
    ("fixOpenRouter", "fix.openRouter", "Router arayüzünü aç", "Open Router Page"),
    ("fixSuggestionsTitle", "fix.suggestions.title", "Öneriler", "Suggestions"),
    ("fixPossibleCausesTitle", "fix.possibleCauses.title", "Olası nedenler", "Possible causes"),
    ("fixCIDBanExplanation", "fix.cidBan.explanation", "CID banı yerel olarak kaldırılamaz; ban sunucu tarafındadır. Yöneticinin doğru sistemi temizlemesi için aşağıdaki itiraz metnini gönderin.", "A CID ban cannot be removed locally; the ban is on the server side. Send the appeal text below so the admin can clear the right system."),
    ("fixCopyAppeal", "fix.copyAppeal", "Unban mesajını kopyala", "Copy Unban Message"),
    ("fixOpenServerPage", "fix.openServerPage", "Sunucu sayfasını aç", "Open Server Page"),
    ("fixContactAdmin", "fix.contactAdmin", "Yöneticiye ulaş: %@", "Contact the admin: %@"),
    ("fixProgressRenewingIP", "fix.progress.renewingIP", "IP yenileniyor…", "Renewing IP…"),
    ("fixProgressWaitingForNetwork", "fix.progress.waitingForNetwork", "Ağ bekleniyor…", "Waiting for the network…"),
    ("fixProgressRechecking", "fix.progress.rechecking", "Yeniden kontrol ediliyor…", "Checking again…"),
    ("fixFailurePublicIPUnavailable", "fix.failure.publicIPUnavailable", "Genel IP alınamadı; düzeltme başlatılmadı.", "Could not get the public IP; the fix was not started."),
    ("fixFailureNoDefaultRoute", "fix.failure.noDefaultRoute", "Varsayılan ağ arayüzü bulunamadı; düzeltme başlatılmadı.", "No default network interface found; the fix was not started."),
    ("fixFailureCommandFailed", "fix.failure.commandFailed", "Ağ komutu başarısız oldu. Arayüz açık bırakıldı.", "A network command failed. The interface was left up."),
    ("fixFailureAdminDeclined", "fix.failure.adminDeclined", "Yönetici onayı verilmedi veya DHCP yenilenemedi.", "Administrator approval was not given or DHCP could not be renewed."),
    ("fixOutcomeResolved", "fix.outcome.resolved", "Çözüldü: IP değişti (%@ → %@), ban kalktı.", "Resolved: the IP changed (%@ → %@), the ban is lifted."),
    ("fixOutcomeStillBanned", "fix.outcome.stillBanned", "Yeni IP de banlı olabilir (subnet/aralık banı) veya sunucu tüm aralığı engelliyor.", "The new IP may be banned too (subnet/range ban), or the server blocks the whole range."),
    ("fixOutcomeRangeBanned", "fix.outcome.rangeBanned", "IP aralığı banı (%@)", "IP range ban (%@)"),
    ("fixOutcomeIPUnchanged", "fix.outcome.ipUnchanged", "IP değişmedi.", "The IP did not change."),
    ("fixOutcomeChangedCIDBanned", "fix.outcome.changedCIDBanned", "IP değişti (%@ → %@); IP engeli görünmüyor ama sunucu CID'yi banlamış.", "The IP changed (%@ → %@); there is no IP block, but the server has banned the CID."),
    ("fixOutcomeChangedUnverified", "fix.outcome.changedUnverified", "IP değişti (%@ → %@); ban durumu doğrulanamadı.", "The IP changed (%@ → %@); the ban status could not be verified."),
    ("fixOutcomeNetworkTimeout", "fix.outcome.networkTimeout", "Ağ 45 sn içinde geri gelmedi. Arayüz açık bırakıldı; bağlantıyı kontrol edin.", "The network did not come back within 45 s. The interface was left up; check your connection."),
    ("fixOutcomeCancelled", "fix.outcome.cancelled", "Düzeltme iptal edildi. Arayüz açık bırakıldı.", "The fix was cancelled. The interface was left up."),
    ("fixUnchangedStep1", "fix.unchanged.step1", "Router arayüzünü açın; oradan PPPoE/WAN bağlantısını yeniden kurun.", "Open the router admin page and reconnect the PPPoE/WAN connection there."),
    ("fixUnchangedStep2", "fix.unchanged.step2", "VPN kullanın.", "Use a VPN."),
    ("fixUnchangedStep3", "fix.unchanged.step3", "Ban süreli olabilir: birkaç saat sonra yeniden deneyin.", "The ban may be temporary: try again in a few hours."),
    ("fixRangeBannedSuggestion1", "fix.rangeBanned.suggestion1", "IP yenilemek işe yaramaz; aynı aralıktasınız.", "Renewing the IP will not help; you are in the same range."),
    ("fixRangeBannedSuggestion2", "fix.rangeBanned.suggestion2", "Farklı ağ dene: mobil hotspot (tethering) veya çıkışı farklı aralıkta olan VPN.", "Try a different network: a mobile hotspot (tethering) or a VPN whose exit is in a different range."),
    ("fixRangeBannedSuggestion3", "fix.rangeBanned.suggestion3", "Sunucu yöneticisinden aralık banını kaldırmasını iste (itiraz metni aralık bilgisini içerir).", "Ask the server admin to remove the range ban (the appeal text includes the range)."),
    ("fixOutOfRange", "fix.outOfRange", "Yeni IP de banlı; aralık dışı olduğu için CID/plugin banı olabilir.", "The new IP is banned too; since it is outside the range, this may be a CID/plugin ban."),
    ("fixStillBannedCause1", "fix.stillBanned.cause1", "Aralık/subnet banı (IP banları kabadır, CGNAT havuzunu bile yakalayabilir).", "Range/subnet ban (IP bans are coarse and can even catch a CGNAT pool)."),
    ("fixStillBannedCause2", "fix.stillBanned.cause2", "Plugin/SQL banı (IP'den bağımsız).", "Plugin/SQL ban (independent of the IP)."),
    ("fixStillBannedCause3", "fix.stillBanned.cause3", "sv_filterban davranışı.", "sv_filterban behavior."),
    ("fixLocked", "fix.locked", "Başka bir düzeltme sürüyor veya son 60 sn içinde yapıldı; biraz sonra tekrar deneyin.", "Another fix is running or one ran in the last 60 s; try again shortly."),
    ("fixBanCheckDisabled", "fix.banCheckDisabled", "Ban kontrolü Ayarlar'da kapalı; yeniden kontrol yapılmadı.", "The ban check is turned off in Settings; no recheck was made."),
    ("fixRecheckThrottled", "fix.recheckThrottled", "Bu sunucu son 10 sn içinde kontrol edildi; biraz sonra tekrar deneyin.", "This server was checked in the last 10 s; try again shortly."),
    ("fixRecheckResult", "fix.recheckResult", "Yeniden kontrol: %@ · %@", "Recheck: %@ · %@"),

    # Appeal text (§17.9.1, §17.10.4)
    ("appealUnknown", "appeal.unknown", "bilinmiyor", "unknown"),
    ("appealGreeting", "appeal.greeting", "Merhaba, yanlışlıkla banlandım, kaldırır mısınız?", "Hello, I think I was banned by mistake. Could you please remove the ban?"),
    ("appealServer", "appeal.server", "Sunucu: %@ (%@:%@)", "Server: %@ (%@:%@)"),
    ("appealCheckedAt", "appeal.checkedAt", "Kontrol zamanı: %@ (yerel) / %@ (UTC)", "Check time: %@ (local) / %@ (UTC)"),
    ("appealPlayerName", "appeal.playerName", "Oyuncu adı: %@", "Player name: %@"),
    ("appealCID", "appeal.cid", "CID (uuid): %@", "CID (uuid): %@"),
    ("appealPublicIP", "appeal.publicIP", "Çıkış IP'si: %@", "Egress IP: %@"),
    ("appealClient", "appeal.client", "İstemci: Xash3D FWGS, protokol 49, gamedir %@", "Client: Xash3D FWGS, protocol 49, gamedir %@"),
    ("appealServerReply", "appeal.serverReply", "Sunucu cevabı: %@", "Server reply: %@"),
    ("appealCheckType", "appeal.checkType", "Kontrol türü: %@", "Check type: %@"),
    ("appealCheckTypeEngineIP", "appeal.checkType.engineIP", "engine IP (getchallenge)", "engine IP (getchallenge)"),
    ("appealCheckTypeEngineCID", "appeal.checkType.engineCID", "engine CID (connect 49)", "engine CID (connect 49)"),
    ("appealCheckTypeUnknown", "appeal.checkType.unknown", "bilinmiyor (plugin/SQL olabilir)", "unknown (may be plugin/SQL)"),
    ("appealRangeBan", "appeal.rangeBan", "Muhtemel aralık banı: %@ (eski IP: %@, yeni IP: %@)", "Possible range ban: %@ (old IP: %@, new IP: %@)"),
    ("appealRangeBanHint", "appeal.rangeBan.hint", "Lütfen listip çıktısında bu aralığa ait bir girdi arayın (ör. %@).", "Please look for an entry covering this range in the listip output (e.g. %@)."),
    ("appealTimedBan", "appeal.timedBan", "Ban süreliyse bitiş zamanını ve gerekçesini paylaşabilir misiniz?", "If the ban is temporary, could you share when it ends and the reason?"),
    ("appealChecklistTitle", "appeal.checklist.title", "Yönetici için kontrol listesi:", "Checklist for the admin:"),
    ("appealChecklistFind", "appeal.checklist.find", "listid ve listip ile kaydı bulun.", "Find the entry with listid and listip."),
    ("appealChecklistRemoveid", "appeal.checklist.removeid", "Motor ID banı ise: removeid <id> + writeid.", "Engine ID ban: removeid <id> + writeid."),
    ("appealChecklistRemoveip", "appeal.checklist.removeip", "Motor IP banı ise: removeip <ip> + writeip.", "Engine IP ban: removeip <ip> + writeip."),
    ("appealChecklistAmxx", "appeal.checklist.amxx", "AMXX ise: amx_unban <ip> (yalnız IP) veya ban-manager menüsü.", "AMXX: amx_unban <ip> (IP only) or the ban manager menu."),
    ("appealChecklistSQL", "appeal.checklist.sql", "SQL/AMXBans ise: panelden/DB'den silin.", "SQL/AMXBans: delete it from the panel/DB."),
    ("appealChecklistFilterban", "appeal.checklist.filterban", "sv_filterban değerini kontrol edin.", "Check the sv_filterban value."),
    ("appealChecklistRestart", "appeal.checklist.restart", "Sunucuyu yeniden başlatın, listid/listip ile doğrulayın ve oyuncuyu tekrar bağlanmaya çağırın.", "Restart the server, verify with listid/listip and ask the player to reconnect."),

    # Server row details (§20, §21)
    ("serverResolving", "server.resolving", "çözülüyor…", "resolving…"),
    ("serverResolveNotFound", "server.resolve.notFound", "ad bulunamadı", "name not found"),
    ("serverResolveNetwork", "server.resolve.network", "DNS hatası (ağ)", "DNS error (network)"),
    ("serverInfoPing", "server.info.ping", "%@ ms", "%@ ms"),

    # History window (§22)
    ("historyTitle", "history.title", "Geçmiş", "History"),
    ("historyEmpty", "history.empty", "Henüz kayıt yok", "No entries yet"),
    ("historyEmptyFiltered", "history.emptyFiltered", "Bu filtreye uyan kayıt yok", "No entries match this filter"),
    ("historyFilterKind", "history.filter.kind", "Tür", "Type"),
    ("historyFilterServer", "history.filter.server", "Sunucu", "Server"),
    ("historyFilterAll", "history.filter.all", "Tümü", "All"),
    ("historyCount", "history.count", "%@ kayıt", "%@ entries"),
    ("historyExportJSON", "history.export.json", "JSON olarak dışa aktar…", "Export as JSON…"),
    ("historyExportMarkdown", "history.export.markdown", "Markdown olarak dışa aktar…", "Export as Markdown…"),
    ("historyExportFailed", "history.export.failed", "Dışa aktarılamadı: %@", "Export failed: %@"),
    ("historyKindRefresh", "history.kind.refresh", "Durum değişti", "Status changed"),
    ("historyKindIPChanged", "history.kind.ipChanged", "IP değişti", "IP changed"),
    ("historyKindBanAppeared", "history.kind.banAppeared", "Ban başladı", "Ban detected"),
    ("historyKindBanLifted", "history.kind.banLifted", "Ban kalktı", "Ban lifted"),
    ("historyKindIdentityChanged", "history.kind.identityChanged", "Kimlik değişti", "Identity changed"),
    ("historyKindNameChanged", "history.kind.nameChanged", "Ad değişti", "Name changed"),
    ("historyKindModelChanged", "history.kind.modelChanged", "Model değişti", "Model changed"),
    ("historyKindApply", "history.kind.apply", "Uygulandı", "Applied"),
    ("historyKindFixAttempt", "history.kind.fixAttempt", "Düzeltme denemesi", "Fix attempt"),
    ("historyKindAppUpdateAvailable", "history.kind.appUpdateAvailable", "Güncelleme var", "Update available"),
    ("historyFixRangeBanned", "history.fix.rangeBanned", "IP aralığı banı", "IP range ban"),
    ("historyFixFailed", "history.fix.failed", "Düzeltme başarısız", "Fix failed"),

    # Apply preview (§24)
    ("diffTitle", "diff.title", "Değişiklik önizlemesi", "Change preview"),
    ("diffMessage", "diff.message", "Aşağıdaki satırlar yazılacak. Yaz'a basmadan hiçbir dosya değişmez.", "The lines below will be written. No file changes until you press Write."),
    ("diffWrite", "diff.write", "Yaz", "Write"),

    # Update check (§25)
    ("updateAvailable", "update.available", "Yeni sürüm mevcut: %@", "A new version is available: %@"),
    ("updateIgnore", "update.ignore", "Yoksay", "Ignore"),
    ("updateCheck", "update.check", "Güncellemeleri Denetle…", "Check for Updates…"),

    # Notifications (§23)
    ("settingsNotifications", "settings.notifications", "Bildirimler", "Notifications"),
    ("notifyBanAppearedTitle", "notify.banAppeared.title", "Ban başladı", "Ban detected"),
    ("notifyBanLiftedTitle", "notify.banLifted.title", "Ban kalktı", "Ban lifted"),
    ("notifyIPChangedTitle", "notify.ipChanged.title", "Genel IP değişti", "Public IP changed"),
    ("notifyIdentityChangedTitle", "notify.identityChanged.title", "Kimlik değişti", "Identity changed"),
    ("notifyFixAttemptTitle", "notify.fixAttempt.title", "Düzeltme sonucu", "Fix result"),
    ("notifyServerBody", "notify.serverBody", "%@: %@", "%@: %@"),
    ("notifyChangeBody", "notify.changeBody", "%@ → %@", "%@ → %@"),

    # Automatic update and downgrade (§27, §28)
    ("settingsTabGeneral", "settings.tab.general", "Genel", "General"),
    ("settingsTabUpdates", "settings.tab.updates", "Güncellemeler", "Updates"),
    ("updateInstall", "update.install", "Yükle", "Install"),
    ("updateReleaseNotes", "update.releaseNotes", "Sürüm notları", "Release notes"),
    ("updateCurrentVersion", "update.currentVersion", "Mevcut sürüm", "Current version"),
    ("updateLastCheck", "update.lastCheck", "Son kontrol", "Last check"),
    ("updateNever", "update.never", "Henüz denetlenmedi", "Not checked yet"),
    ("updateAutoCheck", "update.autoCheck", "Güncellemeleri otomatik denetle", "Check for updates automatically"),
    ("updateAutoDownload", "update.autoDownload", "Güncellemeleri otomatik indir (kurulum onayla)", "Download updates automatically (install after confirmation)"),
    ("updateCheckNow", "update.checkNow", "Şimdi denetle", "Check Now"),
    ("updateStatusChecking", "update.status.checking", "Denetleniyor…", "Checking…"),
    ("updateStatusUpToDate", "update.status.upToDate", "Uygulama güncel.", "The app is up to date."),
    ("updateStatusDownloading", "update.status.downloading", "İndiriliyor… %@", "Downloading… %@"),
    ("updateStatusVerifying", "update.status.verifying", "Doğrulanıyor…", "Verifying…"),
    ("updateStatusReady", "update.status.ready", "Sürüm %@ indirildi ve doğrulandı; kurulum için Yükle'ye basın.", "Version %@ is downloaded and verified; press Install to install it."),
    ("updateStatusInstalling", "update.status.installing", "Kuruluyor…", "Installing…"),
    ("updateStatusRelaunching", "update.status.relaunching", "Yeniden başlatılıyor…", "Relaunching…"),
    ("updateStatusCancelled", "update.status.cancelled", "İndirme iptal edildi.", "The download was cancelled."),
    ("updateErrorFeed", "update.error.feed", "Sürüm listesi alınamadı.", "Could not load the release list."),
    ("updateErrorInsecure", "update.error.insecure", "Güvenli olmayan indirme adresi reddedildi.", "An insecure download address was rejected."),
    ("updateErrorMissingAsset", "update.error.missingAsset", "Bu sürümün kurulum dosyaları eksik.", "This release has no installable files."),
    ("updateErrorSameVersion", "update.error.sameVersion", "Bu sürüm zaten kurulu.", "This version is already installed."),
    ("updateErrorDownload", "update.error.download", "İndirme başarısız oldu.", "The download failed."),
    ("updateErrorSize", "update.error.size", "İndirilen dosyanın boyutu beklenenden farklı; dosya silindi.", "The downloaded file has an unexpected size; it was deleted."),
    ("updateErrorChecksum", "update.error.checksum", "SHA-256 doğrulaması başarısız; dosya silindi.", "SHA-256 verification failed; the file was deleted."),
    ("updateErrorUnpack", "update.error.unpack", "Paket açılamadı.", "The package could not be unpacked."),
    ("updateErrorSignature", "update.error.signature", "İmza doğrulanamadı; kurulum yapılmadı.", "The signature could not be verified; nothing was installed."),
    ("updateErrorTeam", "update.error.team", "Uygulama beklenen geliştirici (GJ3Y762WQ9) tarafından imzalanmamış; kurulum yapılmadı.", "The app is not signed by the expected developer (GJ3Y762WQ9); nothing was installed."),
    ("updateErrorBundle", "update.error.bundle", "Paket başka bir uygulamaya ait; kurulum yapılmadı.", "The package belongs to a different app; nothing was installed."),
    ("updateErrorVersion", "update.error.version", "Paketteki sürüm seçilen sürümle eşleşmiyor; kurulum yapılmadı.", "The version in the package does not match the selected version; nothing was installed."),
    ("updateErrorNotWritable", "update.error.notWritable", "Uygulama klasörüne yazılamıyor. Uygulamayı Applications klasörüne taşıyın veya yönetici onayı verin.", "Cannot write to the app folder. Move the app to the Applications folder or allow administrator access."),
    ("updateErrorRolledBack", "update.error.rolledBack", "Kurulum başarısız oldu; önceki sürüm geri yüklendi.", "The installation failed; the previous version was restored."),
    ("updateErrorBackupLocation", "update.error.backupLocation", "Kurulum başarısız oldu. Önceki sürüm burada: %@", "The installation failed. The previous version is here: %@"),
    ("updateErrorDataBackup", "update.error.dataBackup", "Veri yedeği oluşturulamadı; sürüm değiştirilmedi: %@", "Could not back up the data; the version was not changed: %@"),
    ("updateHistory", "update.history", "Sürüm geçmişi", "Version history"),
    ("updateHistoryEmpty", "update.history.empty", "Sürüm listesi henüz alınmadı. Şimdi denetle'ye basın.", "The release list has not been loaded yet. Press Check Now."),
    ("updateCurrentBadge", "update.currentBadge", "Mevcut", "Current"),
    ("updateDowngrade", "update.downgrade", "Bu sürüme dön", "Revert to This Version"),
    ("updateConfirmInstallTitle", "update.confirm.installTitle", "Sürüm %@ yüklensin mi?", "Install version %@?"),
    ("updateConfirmDowngradeTitle", "update.confirm.downgradeTitle", "%@ sürümüne dönülsün mü?", "Revert to version %@?"),
    ("updateConfirmSize", "update.confirm.size", "İndirme boyutu: %@", "Download size: %@"),
    ("updateConfirmDowngradeWarning", "update.confirm.downgradeWarning", "Eski sürüm, yeni sürümün yazdığı verileri okuyamayabilir. Gerekirse yedekten geri yükleyebilirsiniz.", "An older version may not be able to read data written by the newer one. You can restore from a backup if needed."),
    ("updateConfirmBackupData", "update.confirm.backupData", "Önce veriyi yedekle", "Back up data first"),
    ("updateConfirmRelaunch", "update.confirm.relaunch", "İmza ve sürüm doğrulandıktan sonra uygulama değiştirilir ve yeniden başlatılır.", "After the signature and version are verified, the app is replaced and relaunched."),
    ("updateNotesEmpty", "update.notesEmpty", "Sürüm notu yok.", "No release notes."),
    ("updateBackupsCount", "update.backups.count", "Veri yedekleri: %@", "Data backups: %@"),
    ("updateBackupsClear", "update.backups.clear", "Yedekleri temizle", "Remove Backups"),
    ("updateBackupsClearConfirm", "update.backups.clearConfirm", "Tüm veri yedekleri silinsin mi?", "Delete all data backups?"),
    ("restoreBanner", "restore.banner", "Kayıt bu sürümle okunamıyor. %@ tarihli veri yedeğini geri yükleyebilirsiniz.", "This version cannot read the record. You can restore the data backup from %@."),
    ("restoreAction", "restore.action", "Yedekten geri yükle", "Restore from Backup"),
    ("restoreConfirmTitle", "restore.confirmTitle", "Yedekten geri yüklensin mi?", "Restore from backup?"),
    ("restoreConfirmMessage", "restore.confirmMessage", "Mevcut veriler önce ayrı bir yedeğe alınır, ardından %@ tarihli yedek geri yüklenir ve uygulama yeniden başlatılır.", "The current data is backed up first; then the backup from %@ is restored and the app relaunches."),
    ("restoreFailed", "restore.failed", "Yedek geri yüklenemedi: %@", "The backup could not be restored: %@"),

    # v2.0: join the game (§29)
    ("gameJoin", "game.join", "Oyuna gir", "Join Game"),
    ("gameJoinConfirmTitle", "game.join.confirmTitle", "Oyun açık; yeni bağlantı mevcut oyunu kapatır", "The game is open; a new connection closes the current game"),
    ("gameJoinConfirmMessage", "game.join.confirmMessage", "%@ sunucusuna bağlanılsın mı?", "Connect to %@?"),
    ("gameJoinConfirmAction", "game.join.confirmAction", "Bağlan", "Connect"),
    ("gameErrorTitle", "game.error.title", "Oyuna girilemedi", "Could not join the game"),
    ("gameErrorAppNotFound", "game.error.appNotFound", "Xash3D bulunamadı. /Applications/Xash3D-FWGS.app gerekli.", "Xash3D was not found. /Applications/Xash3D-FWGS.app is required."),
    ("gameErrorInvalidHost", "game.error.invalidHost", "Sunucu adresi geçersiz; bağlanılacak IP yok.", "The server address is invalid; there is no IP to connect to."),
    ("gameErrorResolution", "game.error.resolution", "Sunucu adı IP adresine çözümlenemedi.", "The server name could not be resolved to an IP address."),
    ("gameErrorGamedir", "game.error.gamedir", "Profildeki oyun klasörü adı geçersiz.", "The game folder name in the profile is invalid."),
    ("gameErrorLaunch", "game.error.launch", "Oyun başlatılamadı (kod %@).", "The game could not be started (code %@)."),

    # v2.0: groups and favorites (§31)
    ("serversOther", "servers.other", "Diğer", "Other"),
    ("serversFilterBanned", "servers.filter.banned", "Yalnız banlıları göster", "Show banned only"),
    ("serversFilterFavorites", "servers.filter.favorites", "Yalnız favoriler", "Favorites only"),
    ("serversFilterEmpty", "servers.filter.empty", "Filtreye uyan sunucu yok.", "No server matches the filter."),
    ("serverFavorite", "server.favorite", "Favori", "Favorite"),
    ("serverFavoriteAdd", "server.favorite.add", "Favorilere ekle", "Add to Favorites"),
    ("serverFavoriteRemove", "server.favorite.remove", "Favorilerden çıkar", "Remove from Favorites"),
    ("serverMoveUp", "server.moveUp", "Yukarı taşı", "Move Up"),
    ("serverMoveDown", "server.moveDown", "Aşağı taşı", "Move Down"),
    ("serverFormGroup", "server.form.group", "Grup", "Group"),
    ("serverFormGroupNone", "server.form.groupNone", "Grup yok", "No group"),
    ("serverFormGroupNew", "server.form.groupNew", "Yeni grup…", "New group…"),
    ("serverFormGroupName", "server.form.groupName", "Yeni grup adı", "New group name"),

    # v2.0: notes and appeal tracking (§32)
    ("serverDetails", "server.details", "Notlar ve itiraz…", "Notes and Appeal…"),
    ("serverDetailsTitle", "server.details.title", "%@ · Notlar ve itiraz", "%@ · Notes and appeal"),
    ("notesTitle", "notes.title", "Notlar", "Notes"),
    ("notesCount", "notes.count", "%@ / 2000", "%@ / 2000"),
    ("notesTooLong", "notes.tooLong", "Not en fazla 2000 karakter olabilir.", "A note can have at most 2000 characters."),
    ("notesHasNote", "notes.hasNote", "Not var", "Has a note"),
    ("appealTitle", "appeal.title", "İtiraz", "Appeal"),
    ("appealNone", "appeal.none", "İtiraz kaydı yok.", "No appeal recorded."),
    ("appealAdd", "appeal.add", "İtiraz kaydı ekle", "Add Appeal"),
    ("appealEdit", "appeal.edit", "İtirazı düzenle", "Edit Appeal"),
    ("appealRemove", "appeal.remove", "İtiraz kaydını sil", "Delete Appeal"),
    ("appealSentAt", "appeal.sentAt", "Gönderim tarihi", "Sent on"),
    ("appealChannel", "appeal.channel", "Kanal", "Channel"),
    ("appealChannelDiscord", "appeal.channel.discord", "Discord", "Discord"),
    ("appealChannelTelegram", "appeal.channel.telegram", "Telegram", "Telegram"),
    ("appealChannelForum", "appeal.channel.forum", "Forum", "Forum"),
    ("appealChannelEmail", "appeal.channel.email", "E-posta", "Email"),
    ("appealChannelOther", "appeal.channel.other", "Diğer", "Other"),
    ("appealStatus", "appeal.status", "Durum", "Status"),
    ("appealStatusSent", "appeal.status.sent", "Gönderildi", "Sent"),
    ("appealStatusAnswered", "appeal.status.answered", "Yanıtlandı", "Answered"),
    ("appealStatusRejected", "appeal.status.rejected", "Reddedildi", "Rejected"),
    ("appealStatusAccepted", "appeal.status.accepted", "Kabul edildi", "Accepted"),
    ("appealFollowUp", "appeal.followUp", "Takip tarihi", "Follow-up date"),
    ("appealFollowUpSet", "appeal.followUp.set", "Takip tarihi belirle", "Set a follow-up date"),
    ("appealFollowUpDue", "appeal.followUp.due", "Takip zamanı geldi: %@", "Follow-up due: %@"),
    ("appealSummary", "appeal.summary", "Özet", "Summary"),
    ("appealProblemChannel", "appeal.problem.channel", "Kanal seçin.", "Choose a channel."),
    ("appealProblemSummary", "appeal.problem.summary", "Özet en fazla 2000 karakter olabilir.", "A summary can have at most 2000 characters."),
    ("appealProblemFollowUp", "appeal.problem.followUp", "Takip tarihi gönderim tarihinden önce olamaz.", "The follow-up date cannot be before the sent date."),
    ("appealProblemTransition", "appeal.problem.transition", "Bu durum değişikliğine izin verilmiyor: %@ → %@", "This status change is not allowed: %@ → %@"),
    ("historyKindAppeal", "history.kind.appeal", "İtiraz", "Appeal"),

    # v2.0: share card (§33)
    ("shareCardCreate", "shareCard.create", "Paylaşım kartı oluştur", "Create Share Card"),
    ("shareCardServer", "shareCard.server", "Sunucu", "Server"),
    ("shareCardCID", "shareCard.cid", "CID", "CID"),
    ("shareCardPlayer", "shareCard.player", "Oyuncu", "Player"),
    ("shareCardDate", "shareCard.date", "Tarih", "Date"),
    ("shareCardCopy", "shareCard.copy", "Panoya kopyala", "Copy to Clipboard"),
    ("shareCardSave", "shareCard.save", "Diske kaydet", "Save to Disk"),
    ("shareCardSaved", "shareCard.saved", "Kaydedildi: %@", "Saved: %@"),
    ("shareCardSaveFailed", "shareCard.saveFailed", "Kart kaydedilemedi: %@", "The card could not be saved: %@"),
    ("shareCardFailed", "shareCard.failed", "Kart oluşturulamadı.", "The card could not be created."),

    # v2.0: menu bar and launch at login (§30)
    ("menuBarShow", "menuBar.show", "Göster", "Show"),
    ("menuBarSettings", "menuBar.settings", "Ayarlar…", "Settings…"),
    ("menuBarQuit", "menuBar.quit", "Çık", "Quit"),
    ("settingsMenuBar", "settings.menuBar", "Menü çubuğunda göster", "Show in menu bar"),
    ("settingsMenuBarHint", "settings.menuBar.hint", "Açıkken pencere kapansa da uygulama çalışır ve durum 30 dakikada bir yenilenir.", "While on, the app keeps running when the window is closed and the status is refreshed every 30 minutes."),
    ("settingsLaunchAtLogin", "settings.launchAtLogin", "Açılışta başlat", "Launch at login"),
    ("settingsLaunchAtLoginApproval", "settings.launchAtLogin.approval", "Sistem Ayarları > Genel > Giriş Öğeleri'nde onay bekliyor.", "Waiting for approval in System Settings > General > Login Items."),
    ("settingsLaunchAtLoginOnFailed", "settings.launchAtLogin.onFailed", "Açılışta başlat açılamadı: %@", "Could not turn on launch at login: %@"),
    ("settingsLaunchAtLoginOffFailed", "settings.launchAtLogin.offFailed", "Açılışta başlat kapatılamadı: %@", "Could not turn off launch at login: %@"),
    # v2.1: language selector (§35)
    ("settingsLanguage", "settings.language", "Dil / Language", "Dil / Language"),
    ("languageSystem", "language.system", "Sistem", "System"),
    ("languageSystemResolved", "language.systemResolved", "Sistem (%@)", "System (%@)"),
    ("languageTurkish", "language.tr", "Türkçe", "Türkçe"),
    ("languageEnglish", "language.en", "English", "English"),
    ("settingsLanguageNote", "settings.language.note", "Uygulama adı (Dock ve menü çubuğu) sistem diline bağlıdır; buradan değişmez.", "The app name (Dock and menu bar) follows the system language and does not change here."),

    # v2.2: appeal tracking (§36)
    ("appealTimeline", "appeal.timeline", "Zaman çizelgesi", "Timeline"),
    ("appealPostpone", "appeal.postpone", "Takip tarihini ertele", "Postpone follow-up"),
    ("appealPostponeOneDay", "appeal.postpone.oneDay", "+1 gün", "+1 day"),
    ("appealPostponeThreeDays", "appeal.postpone.threeDays", "+3 gün", "+3 days"),
    ("appealReminderTitle", "appeal.reminder.title", "İtiraz takibi: %@", "Appeal follow-up: %@"),
    ("appealReminderBody", "appeal.reminder.body", "Takip tarihi geldi (%@). İtiraz durumu: %@.", "The follow-up date has come (%@). Appeal status: %@."),
    ("historyKindNote", "history.kind.note", "Not değişti", "Note changed"),

    # v2.2: interfaces and VPN (§37)
    ("networkInterfaces", "network.interfaces", "Arayüzler", "Interfaces"),
    ("networkInterfacesEmpty", "network.interfaces.empty", "Arayüz bulunamadı.", "No interfaces found."),
    ("networkInterfaceActive", "network.interface.active", "Aktif", "Active"),
    ("networkInterfaceInactive", "network.interface.inactive", "Pasif", "Inactive"),
    ("networkInterfaceVPN", "network.interface.vpn", "VPN", "VPN"),
    ("networkInterfaceEgress", "network.interface.egress", "Çıkış arayüzü", "Egress interface"),
    ("networkEgress", "network.egress", "Çıkış", "Egress"),
    ("networkVPN", "network.vpn", "VPN durumu", "VPN status"),
    ("networkVPNActive", "network.vpn.active", "VPN aktif", "VPN active"),
    ("networkVPNNone", "network.vpn.none", "VPN yok", "No VPN"),
    ("networkVPNWarning", "network.vpn.warning", "VPN aktif — ban sonucu VPN çıkışına aittir.", "VPN active — the ban result belongs to the VPN exit."),

    # v2.2: ban matrix (§38)
    ("banMatrixTitle", "banMatrix.title", "Ban matrisi", "Ban Matrix"),
    ("banMatrixOpen", "banMatrix.open", "Ban matrisi…", "Ban Matrix…"),
    ("banMatrixServer", "banMatrix.server", "Sunucu", "Server"),
    ("banMatrixAddress", "banMatrix.address", "Adres", "Address"),
    ("banMatrixIPBan", "banMatrix.ipBan", "IP banı", "IP ban"),
    ("banMatrixCIDBan", "banMatrix.cidBan", "CID banı", "CID ban"),
    ("banMatrixRange", "banMatrix.range", "Aralık", "Range"),
    ("banMatrixLastCheck", "banMatrix.lastCheck", "Son kontrol", "Last check"),
    ("banMatrixCellBanned", "banMatrix.cell.banned", "Ban var", "Banned"),
    ("banMatrixCellClear", "banMatrix.cell.clear", "Yok", "Clear"),
    ("banMatrixCellUnknown", "banMatrix.cell.unknown", "Belirsiz", "Unknown"),
    ("banMatrixCellNotApplicable", "banMatrix.cell.notApplicable", "Uygulanamaz", "Not applicable"),
    ("banMatrixCount", "banMatrix.count", "%@ sunucu · %@ banlı", "%@ servers · %@ banned"),
    ("banMatrixEmpty", "banMatrix.empty", "Henüz sunucu yok.", "No servers yet."),
    ("banMatrixExportCSV", "banMatrix.exportCSV", "CSV dışa aktar…", "Export CSV…"),
    ("exportSaved", "export.saved", "Dışa aktarıldı: %@", "Exported: %@"),
    ("exportFailed", "export.failed", "Dışa aktarılamadı: %@", "Could not export: %@"),

    # v2.2: ping/uptime charts (§39)
    ("metricsTitle", "metrics.title", "Ping ve uptime (son 24 saat)", "Ping and uptime (last 24 hours)"),
    ("metricsUptime", "metrics.uptime", "Son 24 saat uptime: %@", "Uptime, last 24 hours: %@"),
    ("metricsNoData", "metrics.noData", "Son 24 saatte veri yok.", "No data in the last 24 hours."),
    ("metricsPing", "metrics.ping", "Ping (ms)", "Ping (ms)"),
    ("metricsPlayers", "metrics.players", "Oyuncular", "Players"),
    ("metricsTime", "metrics.time", "Saat", "Time"),

    # v2.2: ban list URL (§40)
    ("banListTitle", "banList.title", "Ban listesi", "Ban list"),
    ("banListField", "banList.field", "URL şablonu", "URL template"),
    ("banListHint", "banList.hint", "Örn. https://panel.example.com/bans?q={cid} · yer tutucular: {cid}, {ip}, {host}, {port}", "E.g. https://panel.example.com/bans?q={cid} · placeholders: {cid}, {ip}, {host}, {port}"),
    ("banListSearch", "banList.search", "Ban listesinde ara", "Search Ban List"),
    ("banListErrorEmpty", "banList.error.empty", "URL şablonu girin.", "Enter a URL template."),
    ("banListErrorHTTPS", "banList.error.https", "Adres https:// ile başlamalı.", "The address must start with https://."),
    ("banListErrorPlaceholder", "banList.error.placeholder", "En az bir yer tutucu gerekli: {cid}, {ip}, {host} veya {port}.", "At least one placeholder is required: {cid}, {ip}, {host} or {port}."),
    ("banListErrorUnknown", "banList.error.unknown", "Bilinmeyen yer tutucu: {%@}", "Unknown placeholder: {%@}"),
    ("banListErrorInvalid", "banList.error.invalid", "Geçerli bir URL değil.", "Not a valid URL."),
    ("banListErrorMissing", "banList.error.missing", "Bu sunucu için {%@} değeri henüz yok; önce Yenile'ye basın.", "There is no {%@} value for this server yet; press Refresh first."),

    # v2.2: diagnostics package (§41)
    ("diagnosticsCreate", "diagnostics.create", "Teşhis paketi oluştur…", "Create Diagnostics Package…"),
    ("diagnosticsNote", "diagnostics.note", "ZIP; sürüm ve sistem bilgisi, maskelenmiş kayıt (IP adresleri ve ev klasörü gizlenir), son geçmiş ve metrik satırları ile güncelleme durumunu içerir. Oyun dosyaları eklenmez.", "ZIP with version and system info, the masked record (IP addresses and the home folder are hidden), recent history and metrics lines and the update state. No game files are included."),
    ("diagnosticsSaved", "diagnostics.saved", "Teşhis paketi kaydedildi: %@", "Diagnostics package saved: %@"),
    ("diagnosticsFailed", "diagnostics.failed", "Teşhis paketi kaydedilemedi: %@", "Could not save the diagnostics package: %@"),

    # v2.2: App Intents / Shortcuts (§41); keys are referenced by LocalizedStringResource in the intents
    ("intentCheckBanTitle", "intent.checkBan.title", "Sunucu banını kontrol et", "Check Server Ban"),
    ("intentShowCIDTitle", "intent.showCID.title", "CID'imi göster", "Show My CID"),
    ("intentRefreshTitle", "intent.refresh.title", "Yenile", "Refresh"),
    ("intentCheckBanShort", "intent.short.checkBan", "Ban kontrolü", "Ban Check"),
    ("intentShowCIDShort", "intent.short.showCID", "CID'im", "My CID"),
    ("intentRefreshShort", "intent.short.refresh", "Durumu yenile", "Refresh Status"),
    ("intentServerType", "intent.server.type", "Sunucu", "Server"),
    ("intentParameterServer", "intent.parameter.server", "Sunucu", "Server"),
    ("intentDialogBan", "intent.dialog.ban", "%@: %@", "%@: %@"),
    ("intentDialogCID", "intent.dialog.cid", "%@ için CID: %@", "CID for %@: %@"),
    ("intentDialogRefresh", "intent.dialog.refresh", "Durum: %@", "Status: %@"),
    ("intentErrorNoRecord", "intent.error.noRecord", "Kayıt yok. Uygulamada Yenile ve Kaydet'e basın.", "No record. Press Refresh and Save in the app."),
    ("intentErrorNoServers", "intent.error.noServers", "Kayıtta sunucu yok.", "The record has no servers."),
    ("intentErrorServerNotFound", "intent.error.serverNotFound", "Sunucu bulunamadı.", "Server not found."),
    ("intentErrorAmbiguous", "intent.error.ambiguous", "Birden fazla sunucu eşleşti; sunucuyu seçin.", "More than one server matches; choose the server."),
    ("intentErrorIdentityMissing", "intent.error.identityMissing", "Kimlik dosyası bulunamadı; CID hesaplanamıyor.", "No identity file was found; the CID cannot be computed."),
    ("intentErrorResolution", "intent.error.resolution", "Sunucu adresi çözümlenemedi.", "The server address could not be resolved."),
]

INFOPLIST = {
    "tr": {"CFBundleDisplayName": "Oyuncu Kimlik Kartı", "CFBundleName": "Oyuncu Kimlik Kartı"},
    "en": {"CFBundleDisplayName": "Player Identity", "CFBundleName": "Player Identity"},
}


# §41 Siri / Shortcuts phrases (AppShortcuts.strings). The key is the phrase written in the code,
# with `${applicationName}` for `\(.applicationName)`.
SHORTCUT_PHRASES = [
    ("intent.phrase.checkBan ${applicationName}",
     "${applicationName} ile sunucu banını kontrol et", "Check server ban with ${applicationName}"),
    ("intent.phrase.checkBanShort ${applicationName}",
     "${applicationName} ban kontrolü", "${applicationName} ban check"),
    ("intent.phrase.showCID ${applicationName}",
     "${applicationName} ile CID'imi göster", "Show my CID with ${applicationName}"),
    ("intent.phrase.refresh ${applicationName}",
     "${applicationName} durumunu yenile", "Refresh ${applicationName}"),
]


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def main():
    cases = [k[0] for k in KEYS]
    keys = [k[1] for k in KEYS]
    assert len(set(cases)) == len(cases), "duplicate case"
    assert len(set(keys)) == len(keys), "duplicate key"
    for case, key, tr, en in KEYS:
        assert tr.strip() and en.strip(), key
        assert tr.count("%@") == en.count("%@"), key

    swift = ["// Generated by tools/l10n_keys.py — do not edit by hand.", "",
             "/// Every localization key (§18.2). Keys are English; values live in `<lang>.lproj/Localizable.strings`.",
             "enum L10nKey: String, CaseIterable, Sendable {"]
    swift += [f'    case {case} = "{key}"' for case, key, _, _ in KEYS]
    swift += ["}", ""]
    write("PlayerIdentity/Core/L10nKey.swift", "\n".join(swift))

    for lang, index in (("tr", 2), ("en", 3)):
        lines = ["/* Generated by tools/l10n_keys.py — do not edit by hand. */", ""]
        lines += [f'"{k[1]}" = "{escape(k[index])}";' for k in KEYS]
        write(f"PlayerIdentity/Resources/{lang}.lproj/Localizable.strings", "\n".join(lines) + "\n")
        info = ["/* Generated by tools/l10n_keys.py — do not edit by hand. */", ""]
        info += [f'"{k}" = "{escape(v)}";' for k, v in INFOPLIST[lang].items()]
        write(f"PlayerIdentity/Resources/{lang}.lproj/InfoPlist.strings", "\n".join(info) + "\n")
        phrases = ["/* Generated by tools/l10n_keys.py — do not edit by hand. */", ""]
        phrases += [f'"{key}" = "{escape(p[index - 1])}";' for p in SHORTCUT_PHRASES for key in [p[0]]]
        write(f"PlayerIdentity/Resources/{lang}.lproj/AppShortcuts.strings", "\n".join(phrases) + "\n")
    print(f"{len(KEYS)} keys")


if __name__ == "__main__":
    main()

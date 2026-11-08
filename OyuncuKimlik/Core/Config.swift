import Foundation

/// `config.cfg` içinden okunan oyuncu bilgileri (§3.3). Anahtar yoksa alan boştur.
struct PlayerConfig: Sendable, Equatable {
    var name: String = ""
    var model: String = ""
}

/// `anahtar "değer"` satırlarını ayrıştırır (§3.3).
enum ConfigParser {
    static func parse(_ text: String) -> PlayerConfig {
        let entries = entries(text)
        return PlayerConfig(name: entries["name"] ?? "", model: entries["model"] ?? "")
    }

    /// `name` / `model` anahtarlarının değerleri; aynı anahtar birden fazla geçerse son geçen kazanır.
    /// Anahtar hiç yoksa sözlükte yer almaz (§15.2 kaynak çözümü için).
    static func entries(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = parseLine(line), key == "name" || key == "model" else { continue }
            result[key] = value
        }
        return result
    }

    /// Anahtar, ilk boşluğa kadar olan kısımdır; değer tırnaklar arasından alınır (iç boşluklar korunur).
    static func parseLine(_ line: Substring) -> (key: String, value: String)? {
        let trimmed = line.drop(while: \.isWhitespace)
        guard let separator = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let key = String(trimmed[..<separator])
        guard !key.isEmpty else { return nil }
        var rest = trimmed[separator...].drop(while: \.isWhitespace)
        while let last = rest.last, last.isWhitespace { rest = rest.dropLast() }

        if rest.first == "\"" {
            let afterQuote = rest.dropFirst()
            if let closing = afterQuote.firstIndex(of: "\"") {
                return (key, String(afterQuote[..<closing]))
            }
            return (key, String(afterQuote))
        }
        return (key, String(rest))
    }
}

/// Ad/model değerinin geldiği dosya (§15.2).
enum ConfigFileKind: String, Sendable, Equatable, CaseIterable {
    case config
    case userconfig

    var fileName: String {
        switch self {
        case .config: return "config.cfg"
        case .userconfig: return "userconfig.cfg"
        }
    }

    /// Arayüzdeki kaynak notu.
    var note: String {
        switch self {
        case .config: return "config.cfg"
        case .userconfig: return "userconfig.cfg (config.cfg'yi ezer)"
        }
    }
}

/// Etkin değerlerin kaynakları; anahtar hiçbir dosyada yoksa `nil`.
struct ConfigSources: Sendable, Equatable {
    var name: ConfigFileKind?
    var model: ConfigFileKind?
}

/// §15.2: `userconfig.cfg` `config.cfg`'den sonra çalışır; anahtar oradaysa etkin değer odur.
enum PlayerConfigResolver {
    static func resolve(configText: String?, userconfigText: String?) -> (config: PlayerConfig, sources: ConfigSources) {
        let base = configText.map(ConfigParser.entries) ?? [:]
        let user = userconfigText.map(ConfigParser.entries) ?? [:]
        func pick(_ key: String) -> (String, ConfigFileKind?) {
            if let value = user[key] { return (value, .userconfig) }
            if let value = base[key] { return (value, .config) }
            return ("", nil)
        }
        let (name, nameSource) = pick("name")
        let (model, modelSource) = pick("model")
        return (PlayerConfig(name: name, model: model), ConfigSources(name: nameSource, model: modelSource))
    }
}

/// Seçili gamedir'in `config.cfg` ve (varsa) `userconfig.cfg` dosyalarını okur. Dosya yoksa/okunamıyorsa boş alanlar.
struct ConfigReader: Sendable {
    let fileSystem: any FileSystemReading

    init(fileSystem: any FileSystemReading = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Etkin değerler (§15.2).
    func read(gamedir: URL) -> PlayerConfig {
        readEffective(gamedir: gamedir).config
    }

    func readEffective(gamedir: URL) -> (config: PlayerConfig, sources: ConfigSources) {
        PlayerConfigResolver.resolve(configText: text(gamedir, .config), userconfigText: text(gamedir, .userconfig))
    }

    private func text(_ gamedir: URL, _ kind: ConfigFileKind) -> String? {
        let url = gamedir.appendingPathComponent(kind.fileName, isDirectory: false)
        guard fileSystem.isRegularFile(url), let data = try? fileSystem.readData(url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// §15.3: `<gamedir>/models/player/` altındaki klasör adları, alfabetik. Okunamazsa `nil`.
enum ModelCatalog {
    static func load(gamedir: URL, fileSystem: any FileSystemReading = LocalFileSystem()) -> [String]? {
        let folder = gamedir.appendingPathComponent("models/player", isDirectory: true)
        guard let entries = try? fileSystem.contentsOfDirectory(folder) else { return nil }
        return entries
            .filter { fileSystem.isDirectory($0) && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
            .sorted { $0.lowercased() == $1.lowercased() ? $0 < $1 : $0.lowercased() < $1.lowercased() }
    }
}

/// Veri kökü altındaki birinci seviye gamedir'leri bulur (§3.4).
struct GamedirDiscovery: Sendable {
    static let preferredDefault = "valve"

    let fileSystem: any FileSystemReading

    init(fileSystem: any FileSystemReading = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// İçinde `.xash_id` veya `config.cfg` bulunan klasör adları, ada göre sıralı.
    func discover(dataRoot: URL) -> [String] {
        guard let entries = try? fileSystem.contentsOfDirectory(dataRoot) else { return [] }
        return entries
            .filter { fileSystem.isDirectory($0) }
            .filter {
                fileSystem.isRegularFile($0.appendingPathComponent(".xash_id", isDirectory: false))
                    || fileSystem.isRegularFile($0.appendingPathComponent("config.cfg", isDirectory: false))
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// `valve` varsa o; yoksa ilk bulunan.
    static func defaultSelection(from gamedirs: [String]) -> String? {
        gamedirs.contains(preferredDefault) ? preferredDefault : gamedirs.first
    }
}

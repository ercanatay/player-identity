import Foundation

/// `config.cfg` içinden okunan oyuncu bilgileri (§3.3). Anahtar yoksa alan boştur.
struct PlayerConfig: Sendable, Equatable {
    var name: String = ""
    var model: String = ""
}

/// `anahtar "değer"` satırlarını ayrıştırır (§3.3).
enum ConfigParser {
    static func parse(_ text: String) -> PlayerConfig {
        var config = PlayerConfig()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = parseLine(line) else { continue }
            // Aynı anahtar birden fazla geçerse son geçen kazanır.
            switch key {
            case "name": config.name = value
            case "model": config.model = value
            default: break
            }
        }
        return config
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

/// Seçili gamedir'in `config.cfg` dosyasını okur. Dosya yoksa/okunamıyorsa boş alanlar döner.
struct ConfigReader: Sendable {
    let fileSystem: any FileSystemReading

    init(fileSystem: any FileSystemReading = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    func read(gamedir: URL) -> PlayerConfig {
        let url = gamedir.appendingPathComponent("config.cfg", isDirectory: false)
        guard fileSystem.isRegularFile(url), let data = try? fileSystem.readData(url) else {
            return PlayerConfig()
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return ConfigParser.parse(text)
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

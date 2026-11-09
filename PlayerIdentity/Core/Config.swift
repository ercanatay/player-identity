import Foundation

/// Player info read from `config.cfg` (§3.3). A missing key leaves the field empty.
struct PlayerConfig: Sendable, Equatable {
    var name: String = ""
    var model: String = ""
}

/// Parses `key "value"` lines (§3.3).
enum ConfigParser {
    static func parse(_ text: String) -> PlayerConfig {
        let entries = entries(text)
        return PlayerConfig(name: entries["name"] ?? "", model: entries["model"] ?? "")
    }

    /// Values of the `name` / `model` keys; if a key occurs more than once, the last one wins.
    /// A key that never occurs is absent from the dictionary (for §15.2 source resolution).
    static func entries(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = parseLine(line), key == "name" || key == "model" else { continue }
            result[key] = value
        }
        return result
    }

    /// The key is the part up to the first whitespace; the value is taken from between quotes (inner spaces preserved).
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

/// File the name/model value comes from (§15.2).
enum ConfigFileKind: String, Sendable, Equatable, CaseIterable {
    case config
    case userconfig

    var fileName: String {
        switch self {
        case .config: return "config.cfg"
        case .userconfig: return "userconfig.cfg"
        }
    }

    /// Source note shown in the UI.
    var note: String {
        switch self {
        case .config: return L10n.text(.profileSourceConfig)
        case .userconfig: return L10n.text(.profileSourceUserconfig)
        }
    }
}

/// Sources of the effective values; `nil` if the key is in neither file.
struct ConfigSources: Sendable, Equatable {
    var name: ConfigFileKind?
    var model: ConfigFileKind?
}

/// §15.2: `userconfig.cfg` runs after `config.cfg`; if the key is there, that is the effective value.
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

/// Reads `config.cfg` and (if present) `userconfig.cfg` of the selected gamedir. Missing/unreadable file → empty fields.
struct ConfigReader: Sendable {
    let fileSystem: any FileSystemReading

    init(fileSystem: any FileSystemReading = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Effective values (§15.2).
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

/// §43.2: where a model folder was found.
enum ModelSource: String, Sendable, Equatable, Hashable, CaseIterable {
    /// `<gamedir>/models/player/`
    case local
    /// `<dataRoot>/valve_downloads/…` or `<dataRoot>/<gamedir>_downloads/…`
    case downloaded

    var label: String {
        switch self {
        case .local: return L10n.text(.modelSourceLocal)
        case .downloaded: return L10n.text(.modelSourceDownloaded)
        }
    }
}

/// A model folder name with every source it was found in (`local` first).
struct CatalogModel: Sendable, Equatable {
    let name: String
    let sources: [ModelSource]
}

/// §15.3 / §43.2: folder names under `models/player/` of the gamedir and of the `*_downloads` folders.
enum ModelCatalog {
    /// Local folder only; `nil` if unreadable.
    static func load(gamedir: URL, fileSystem: any FileSystemReading = LocalFileSystem()) -> [String]? {
        folders(in: gamedir.appendingPathComponent("models/player", isDirectory: true), fileSystem: fileSystem)
    }

    /// Union of the three folders (§43.2), deduplicated by name and sorted; `nil` if none of them is readable.
    static func entries(dataRoot: URL, gamedir: String,
                        fileSystem: any FileSystemReading = LocalFileSystem()) -> [CatalogModel]? {
        let gamedirURL = dataRoot.appendingPathComponent(gamedir, isDirectory: true)
        var folders: [(ModelSource, URL)] = [(.local, gamedirURL.appendingPathComponent("models/player", isDirectory: true))]
        var downloads = ["valve_downloads"]
        if gamedir != "valve" { downloads.append("\(gamedir)_downloads") }
        for folder in downloads {
            folders.append((.downloaded, dataRoot.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent("models/player", isDirectory: true)))
        }
        var sources: [String: [ModelSource]] = [:]
        var readable = false
        for (source, url) in folders {
            guard let names = Self.folders(in: url, fileSystem: fileSystem) else { continue }
            readable = true
            for name in names where !(sources[name]?.contains(source) ?? false) {
                sources[name, default: []].append(source)
            }
        }
        guard readable else { return nil }
        return sort(Array(sources.keys)).map { CatalogModel(name: $0, sources: sources[$0] ?? []) }
    }

    private static func folders(in folder: URL, fileSystem: any FileSystemReading) -> [String]? {
        guard let entries = try? fileSystem.contentsOfDirectory(folder) else { return nil }
        return sort(entries
            .filter { fileSystem.isDirectory($0) && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent))
    }

    private static func sort(_ names: [String]) -> [String] {
        names.sorted { $0.lowercased() == $1.lowercased() ? $0 < $1 : $0.lowercased() < $1.lowercased() }
    }
}

/// Finds first-level gamedirs under the data root (§3.4).
struct GamedirDiscovery: Sendable {
    static let preferredDefault = "valve"

    let fileSystem: any FileSystemReading

    init(fileSystem: any FileSystemReading = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Names of folders containing `.xash_id` or `config.cfg`, sorted by name.
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

    /// `valve` if present; otherwise the first one found.
    static func defaultSelection(from gamedirs: [String]) -> String? {
        gamedirs.contains(preferredDefault) ? preferredDefault : gamedirs.first
    }
}

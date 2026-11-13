import Foundation

// MARK: - §40 Ban list URL template

enum BanListPlaceholder: String, Sendable, CaseIterable {
    case cid
    case ip
    case host
    case port

    var token: String { "{\(rawValue)}" }
}

enum BanListTemplateError: Error, Sendable, Equatable {
    case empty
    /// Only `https` is allowed.
    case notHTTPS
    case noPlaceholder
    case unknownPlaceholder(String)
    /// Not a valid URL even with the placeholders filled in.
    case invalidURL
    /// The template needs a value the row does not have (e.g. `{cid}` without an identity).
    case missingValue(BanListPlaceholder)
    /// §59: longer than `BanListTemplate.maxLength`.
    case tooLong
    /// §59: a space, tab or line break inside the template.
    case containsWhitespace
}

/// Values for the placeholders of one server row.
struct BanListValues: Sendable, Equatable {
    var cid: String?
    /// IP the server is checked at (a hostname's resolved address).
    var ip: String?
    var host: String
    var port: Int

    func value(for placeholder: BanListPlaceholder) -> String? {
        switch placeholder {
        case .cid: return cid.flatMap { $0.isEmpty ? nil : $0 }
        case .ip: return ip.flatMap { $0.isEmpty ? nil : $0 }
        case .host: return host.isEmpty ? nil : host
        case .port: return String(port)
        }
    }
}

enum BanListTemplate {
    /// Unreserved characters (RFC 3986): safe in a path segment and a query value.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Placeholders used by the template, in order of first appearance.
    static func placeholders(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^{}]*)\}"#) else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        var names: [String] = []
        for match in regex.matches(in: template, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: template) else { continue }
            let name = String(template[nameRange])
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// §59 longest template kept.
    static let maxLength = 2048

    /// `https`, a host, at least one known placeholder and no unknown ones, no whitespace inside and at most
    /// `maxLength` characters. Returns the trimmed template.
    static func validate(_ template: String) -> Result<String, BanListTemplateError> {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= maxLength else { return .failure(.tooLong) }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return .failure(.containsWhitespace)
        }
        let names = placeholders(in: trimmed)
        if let unknown = names.first(where: { BanListPlaceholder(rawValue: $0) == nil }) {
            return .failure(.unknownPlaceholder(unknown))
        }
        guard !names.isEmpty else { return .failure(.noPlaceholder) }
        let sample = BanListValues(cid: String(repeating: "0", count: 32), ip: "192.0.2.1", host: "example.com", port: 27015)
        guard let url = substitute(trimmed, values: sample),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.invalidURL) }
        guard components.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard let host = components.host, !host.isEmpty else { return .failure(.invalidURL) }
        return .success(trimmed)
    }

    /// Fills in the placeholders (percent-encoded) and returns the URL to open.
    static func url(_ template: String, values: BanListValues) -> Result<URL, BanListTemplateError> {
        switch validate(template) {
        case .failure(let error): return .failure(error)
        case .success(let valid):
            for name in placeholders(in: valid) {
                guard let placeholder = BanListPlaceholder(rawValue: name), values.value(for: placeholder) != nil else {
                    return .failure(.missingValue(BanListPlaceholder(rawValue: name) ?? .cid))
                }
            }
            guard let url = substitute(valid, values: values) else { return .failure(.invalidURL) }
            return .success(url)
        }
    }

    private static func substitute(_ template: String, values: BanListValues) -> URL? {
        var text = template
        for placeholder in BanListPlaceholder.allCases {
            let value = values.value(for: placeholder) ?? ""
            text = text.replacingOccurrences(of: placeholder.token,
                                             with: value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }
        return URL(string: text)
    }
}

// MARK: - §59 template library

/// A ready-made ban list template; the user picks one in the server details and adapts the panel address.
struct BanListPreset: Sendable, Equatable, Identifiable {
    let id: String
    let nameKey: L10nKey
    let descriptionKey: L10nKey
    let template: String

    var name: String { L10n.text(nameKey) }
    var summary: String { L10n.text(descriptionKey) }
    /// Placeholders the template uses, in order of first appearance.
    var placeholders: [BanListPlaceholder] {
        BanListTemplate.placeholders(in: template).compactMap(BanListPlaceholder.init(rawValue:))
    }

    static let all: [BanListPreset] = [
        BanListPreset(id: "sourcebans", nameKey: .banListPresetSourceBans, descriptionKey: .banListPresetSourceBansInfo,
                      template: "https://bans.example.com/index.php?p=banlist&searchText={cid}"),
        BanListPreset(id: "amxbans", nameKey: .banListPresetAMXBans, descriptionKey: .banListPresetAMXBansInfo,
                      template: "https://amxbans.example.com/ban_search.php?steamid={cid}"),
        BanListPreset(id: "hlstatsx", nameKey: .banListPresetHLstatsX, descriptionKey: .banListPresetHLstatsXInfo,
                      template: "https://stats.example.com/hlstats.php?mode=search&st=uniqueid&q={cid}"),
        BanListPreset(id: "generic-cid", nameKey: .banListPresetGenericCID, descriptionKey: .banListPresetGenericCIDInfo,
                      template: "https://bans.example.com/search?cid={cid}&server={host}:{port}"),
        BanListPreset(id: "generic-ip", nameKey: .banListPresetGenericIP, descriptionKey: .banListPresetGenericIPInfo,
                      template: "https://bans.example.com/search?ip={ip}&server={host}:{port}"),
    ]

    static func preset(id: String) -> BanListPreset? { all.first { $0.id == id } }

    /// The preset whose template is exactly `template` (trimmed); `nil` = a custom (or empty) template.
    static func matching(_ template: String) -> BanListPreset? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.template == trimmed }
    }
}

/// Opens a URL in the default browser (NSWorkspace in the app, a recorder in tests).
protocol URLOpening: Sendable {
    @MainActor func open(_ url: URL) -> Bool
}

/// Default when nothing is injected (tests): opens nothing.
struct UnavailableURLOpener: URLOpening {
    init() {}
    @MainActor func open(_ url: URL) -> Bool { false }
}

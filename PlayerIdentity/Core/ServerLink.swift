import Foundation

/// §53 `playeridentity://add?host=…&port=…&label=…&group=…&watch=1` links. `host` may repeat; every value is checked
/// with the §50 import rules (`ServerURLImport`), so a link accepts the same entries as the paste sheet. Pure; no
/// network.
enum ServerLink {
    static let scheme = "playeridentity"
    static let addAction = "add"

    enum Failure: Error, Sendable, Equatable {
        /// Not a `playeridentity:` URL.
        case unsupportedScheme(String)
        /// A `playeridentity:` URL with another action than `add`.
        case unsupportedAction(String)
        /// No (non-empty) `host` parameter.
        case noHost

        var text: String {
            switch self {
            case .unsupportedScheme(let url): return L10n.format(.serverLinkErrorScheme, url)
            case .unsupportedAction(let action): return L10n.format(.serverLinkErrorAction, action)
            case .noHost: return L10n.text(.serverLinkErrorNoHost)
            }
        }
    }

    /// A parsed `add` link.
    struct Request: Sendable, Equatable {
        /// Valid / existing / invalid entries of the `host` values (with `port` applied to hosts without one).
        var entries: ServerURLImport.Result
        /// `label` (trimmed, `nil` when empty): the label of every added server instead of its host.
        var label: String?
        /// `group` (trimmed, `nil` when empty).
        var group: String?
        var watch = false
    }

    static func parse(_ url: URL, existing: [ServerEntry] = []) -> Result<Request, Failure> {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unsupportedScheme(url.absoluteString))
        }
        // `playeridentity://add?…` (action = host) and `playeridentity:add?…` (action = path) are both accepted.
        let action = (components.host.flatMap { $0.isEmpty ? nil : $0 } ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard action == addAction else { return .failure(.unsupportedAction(action)) }

        let items = components.queryItems ?? []
        func last(_ name: String) -> String? {
            items.last { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A host value with commas or line breaks is split like a pasted list (§50.1).
        let hosts = items.filter { $0.name.lowercased() == "host" }
            .flatMap { ($0.value ?? "").components(separatedBy: .newlines) }
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return .failure(.noHost) }
        let port = last("port").flatMap { $0.isEmpty ? nil : $0 }
        let tokens = hosts.map { host in
            guard let port, !hasPort(host) else { return host }
            return host + ":" + port
        }
        // One token per line, so the import's entry numbers are positions in `hosts`; invalid entries are reported
        // as written in the link (without the added port).
        var entries = ServerURLImport.parse(tokens.joined(separator: "\n"), existing: existing)
        entries.invalid = entries.invalid.map { invalid in
            hosts.indices.contains(invalid.index - 1)
                ? ServerURLImport.Invalid(index: invalid.index, raw: hosts[invalid.index - 1], reason: invalid.reason)
                : invalid
        }
        let label = last("label").flatMap { $0.isEmpty ? nil : $0 }
        let group = last("group").flatMap { $0.isEmpty ? nil : $0 }
        let watch = last("watch").map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? false
        return .success(Request(entries: entries, label: label, group: group, watch: watch))
    }

    /// `host:port` or `[v6]:port` carries its own port; a bare host does not. Links (GameTracker, `steam://`) are
    /// never changed: their own port (or 27015) is used.
    static func hasPort(_ host: String) -> Bool {
        if host.contains("://") { return true }
        if host.hasPrefix("[") { return host.contains("]:") }
        return host.filter { $0 == ":" }.count == 1
    }

    /// Result shown after a link was handled (the servers are added "unsaved").
    struct Outcome: Sendable, Identifiable {
        let id = UUID()
        var added = 0
        var existing = 0
        var duplicates = 0
        var overflow = 0
        var invalid: [ServerURLImport.Invalid] = []
        /// The link could not be used at all (or a data operation was running).
        var failure: String?

        /// The lines of the result message.
        var lines: [String] {
            if let failure { return [failure] }
            var lines: [String] = []
            if added > 0 { lines.append(L10n.format(.serverLinkAdded, String(added))) }
            if existing > 0 { lines.append(L10n.format(.serverLinkExisting, String(existing))) }
            if duplicates > 0 { lines.append(L10n.format(.serverImportDuplicates, String(duplicates))) }
            if overflow > 0 { lines.append(L10n.format(.serverImportOverflow, String(overflow))) }
            if !invalid.isEmpty {
                lines.append(L10n.format(.serverImportInvalidTitle, String(invalid.count)))
                lines += invalid.map { L10n.format(.serverImportInvalidLine, String($0.index), $0.raw + " · " + $0.reason.text) }
            }
            if added == 0, invalid.isEmpty, existing == 0 { lines.append(L10n.text(.serverImportNothing)) }
            return lines
        }
    }
}

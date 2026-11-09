import Foundation

/// One section of the server list (§31): a group, or the servers without a group (`group == nil`, shown last).
struct ServerSection: Sendable, Equatable {
    let group: String?
    let servers: [ServerEntry]
}

/// §31 list filters.
struct ServerListFilter: Sendable, Equatable {
    /// "Yalnız banlıları göster": the last ban check found an IP or CID ban.
    var onlyBanned = false
    /// "Yalnız favoriler".
    var onlyFavorites = false
    /// §42 "Yalnız izlenenler".
    var onlyWatched = false

    init(onlyBanned: Bool = false, onlyFavorites: Bool = false, onlyWatched: Bool = false) {
        self.onlyBanned = onlyBanned
        self.onlyFavorites = onlyFavorites
        self.onlyWatched = onlyWatched
    }

    func matches(_ entry: ServerEntry) -> Bool {
        if onlyFavorites, !entry.favorite { return false }
        if onlyWatched, !entry.watch { return false }
        if onlyBanned {
            switch entry.banCheck?.status {
            case .ipBanned?, .cidBanned?: break
            default: return false
            }
        }
        return true
    }
}

enum ServerMoveDirection: Sendable, Equatable {
    case up
    case down
}

/// Grouping, ordering and filtering of the server rows (§31). Pure functions; the array order of `servers`
/// is the tie-breaker, so old records (every `order == 0`) keep their order.
enum ServerOrganization {
    /// Trimmed group name; empty → no group.
    static func normalizedGroup(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Group typed in the form: an existing group with the same name (case-insensitive) keeps its spelling,
    /// anything else becomes a new group.
    static func resolveGroup(_ input: String?, existing: [String]) -> String? {
        guard let name = normalizedGroup(input) else { return nil }
        return existing.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? name
    }

    /// Existing group names, sorted (Finder order, case-insensitive).
    static func groups(_ servers: [ServerEntry]) -> [String] {
        var names: [String] = []
        for name in servers.compactMap({ normalizedGroup($0.group) }) where !names.contains(name) {
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Display order inside a section: favorites first, then `order`, then the array order.
    static func sorted(_ servers: [ServerEntry]) -> [ServerEntry] {
        servers.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.favorite != rhs.element.favorite { return lhs.element.favorite }
                if lhs.element.order != rhs.element.order { return lhs.element.order < rhs.element.order }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Sections: groups by name, servers without a group last; empty sections are left out.
    static func sections(_ servers: [ServerEntry], filter: ServerListFilter = ServerListFilter()) -> [ServerSection] {
        let visible = servers.filter(filter.matches)
        var result = groups(visible).map { name in
            ServerSection(group: name, servers: sorted(visible.filter { normalizedGroup($0.group) == name }))
        }
        let ungrouped = visible.filter { normalizedGroup($0.group) == nil }
        if !ungrouped.isEmpty { result.append(ServerSection(group: nil, servers: sorted(ungrouped))) }
        return result
    }

    /// `order` for a newly added server: after every existing one.
    static func nextOrder(_ servers: [ServerEntry]) -> Int {
        (servers.map(\.order).max() ?? -1) + 1
    }

    /// Whether ▲/▼ can move the row: there is a neighbour in the same section with the same favorite state.
    static func canMove(_ id: UUID, _ direction: ServerMoveDirection, in servers: [ServerEntry]) -> Bool {
        neighbour(of: id, direction, in: servers) != nil
    }

    /// ▲/▼: swaps the row with its neighbour (same group, same favorite state) and renumbers `order` in display
    /// order (0, 1, 2 …). The array order is kept. `nil` if the row cannot move.
    static func move(_ id: UUID, _ direction: ServerMoveDirection, in servers: [ServerEntry]) -> [ServerEntry]? {
        guard let other = neighbour(of: id, direction, in: servers) else { return nil }
        var display = sections(servers).flatMap(\.servers).map(\.id)
        guard let from = display.firstIndex(of: id), let to = display.firstIndex(of: other) else { return nil }
        display.swapAt(from, to)
        return renumbered(servers, displayOrder: display)
    }

    /// `order` = position in the given display order.
    static func renumbered(_ servers: [ServerEntry], displayOrder: [UUID]) -> [ServerEntry] {
        let position = Dictionary(displayOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return servers.map { entry in
            var copy = entry
            copy.order = position[entry.id] ?? entry.order
            return copy
        }
    }

    private static func neighbour(of id: UUID, _ direction: ServerMoveDirection, in servers: [ServerEntry]) -> UUID? {
        for section in sections(servers) {
            guard let index = section.servers.firstIndex(where: { $0.id == id }) else { continue }
            let target = direction == .up ? index - 1 : index + 1
            guard section.servers.indices.contains(target),
                  section.servers[target].favorite == section.servers[index].favorite else { return nil }
            return section.servers[target].id
        }
        return nil
    }
}

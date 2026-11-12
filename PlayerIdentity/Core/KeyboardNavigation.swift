import Foundation

// MARK: - §55 Main window keyboard model

/// Keys the main window handles itself (the view maps the system key press to one of these).
enum MainWindowKey: Hashable, Sendable, CaseIterable {
    /// ⌘F
    case find
    case upArrow
    case downArrow
    case home
    case end
    case returnKey
    case escape
}

/// What a key does in the main window.
enum MainWindowKeyAction: Equatable, Sendable, CaseIterable {
    /// ⌘F: focus the server search field.
    case focusSearch
    case selectPrevious
    case selectNext
    case selectFirst
    case selectLast
    /// Return: open the details of the selected server.
    case openSelected
    /// Escape: clear the selection (only when something is selected; otherwise the key is not handled).
    case clearSelection
}

/// Result of a key press in the server table.
enum ServerTableKeyOutcome: Equatable, Sendable {
    case focusSearch
    case select(UUID)
    case open(UUID)
    case clearSelection
    /// Not handled: the key goes on to the system (e.g. Escape closing a sheet, arrows scrolling).
    case ignored
}

/// Pure key → action mapping and its effect on the selection (testable without a window).
enum MainWindowKeyboard {
    /// The fixed key map (also listed in the README).
    static let bindings: [MainWindowKey: MainWindowKeyAction] = [
        .find: .focusSearch,
        .upArrow: .selectPrevious,
        .downArrow: .selectNext,
        .home: .selectFirst,
        .end: .selectLast,
        .returnKey: .openSelected,
        .escape: .clearSelection,
    ]

    static func action(for key: MainWindowKey) -> MainWindowKeyAction? { bindings[key] }

    /// Applies an action to the selection. `rows` = visible rows in display order (collapsed groups and filtered-out
    /// rows are left out); a selection that is no longer visible counts as none.
    static func apply(_ action: MainWindowKeyAction, selection: UUID?, rows: [UUID]) -> ServerTableKeyOutcome {
        let index = selection.flatMap { rows.firstIndex(of: $0) }
        switch action {
        case .focusSearch:
            return .focusSearch
        case .selectNext:
            guard !rows.isEmpty else { return .ignored }
            guard let index else { return .select(rows[0]) }
            return .select(rows[min(index + 1, rows.count - 1)])
        case .selectPrevious:
            guard !rows.isEmpty else { return .ignored }
            guard let index else { return .select(rows[rows.count - 1]) }
            return .select(rows[max(index - 1, 0)])
        case .selectFirst:
            return rows.first.map(ServerTableKeyOutcome.select) ?? .ignored
        case .selectLast:
            return rows.last.map(ServerTableKeyOutcome.select) ?? .ignored
        case .openSelected:
            guard let index else { return .ignored }
            return .open(rows[index])
        case .clearSelection:
            return index == nil ? .ignored : .clearSelection
        }
    }

    static func handle(_ key: MainWindowKey, selection: UUID?, rows: [UUID]) -> ServerTableKeyOutcome {
        guard let action = action(for: key) else { return .ignored }
        return apply(action, selection: selection, rows: rows)
    }
}

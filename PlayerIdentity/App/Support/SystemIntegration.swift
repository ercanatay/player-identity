import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// §67.2: starts an application with launch arguments through NSWorkspace (no shell, no file written).
struct WorkspaceAppLauncher: AppLaunching {
    init() {}

    func open(app: URL, arguments: [String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}

/// §67.4: the servers in the system Spotlight index (one fixed domain).
struct CoreSpotlightIndexer: SpotlightIndexing {
    init() {}

    func index(_ items: [SpotlightServerItem]) async throws {
        guard !items.isEmpty else { return }
        let searchable = items.map { item in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = item.title
            attributes.displayName = item.title
            attributes.contentDescription = item.summary
            attributes.keywords = [item.title, item.summary]
            return CSSearchableItem(uniqueIdentifier: item.identifier, domainIdentifier: SpotlightServers.domainIdentifier,
                                    attributeSet: attributes)
        }
        try await CSSearchableIndex.default().indexSearchableItems(searchable)
    }

    func delete(identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
    }

    func deleteAll() async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightServers.domainIdentifier])
    }
}

enum SpotlightActivity {
    /// `NSUserActivity` type of an opened Spotlight result.
    static let activityType = CSSearchableItemActionType

    /// The server identifier a Spotlight result's activity carries (`nil` for other activities).
    static func identifier(of activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        return activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}

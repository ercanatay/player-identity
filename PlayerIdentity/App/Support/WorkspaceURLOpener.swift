import AppKit

/// §40: opens URLs in the default browser.
struct WorkspaceURLOpener: URLOpening {
    init() {}

    @MainActor func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

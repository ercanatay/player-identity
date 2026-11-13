import AppKit

/// §40: opens URLs in the default browser.
struct WorkspaceURLOpener: URLOpening {
    init() {}

    @MainActor func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// §60: the general clipboard.
struct SystemPasteboard: PasteboardWriting {
    init() {}

    @MainActor func write(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

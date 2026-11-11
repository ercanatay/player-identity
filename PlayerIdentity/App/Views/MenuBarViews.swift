import AppKit
import SwiftUI

/// §30 status item image: the status symbol in green/orange/red (not a template, so the color stays);
/// "not checked yet" stays a template image that follows the menu bar appearance.
enum MenuBarIcon {
    static func image(for presentation: MenuBarPresentation) -> NSImage {
        let base = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.title)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let color = color(presentation.tint) else {
            let image = base.withSymbolConfiguration(size) ?? base
            image.isTemplate = true
            return image
        }
        let image = base.withSymbolConfiguration(size.applying(.init(paletteColors: [color]))) ?? base
        image.isTemplate = false
        return image
    }

    static func color(_ tint: MenuBarPresentation.Tint) -> NSColor? {
        switch tint {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .neutral: return nil
        }
    }
}

/// Status item label (`MenuBarExtra` is backed by an `NSStatusItem`).
struct MenuBarLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        let presentation = model.menuBarPresentation
        Image(nsImage: MenuBarIcon.image(for: presentation))
            .accessibilityLabel(presentation.title)
    }
}

/// §30 menu: status line, last check, Refresh, Settings, Show, Quit.
struct MenuBarMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.menuBarPresentation.title)
        Text(L10n.format(.topbarLastCheck, TimeText.format(model.lastChecked)))
        Divider()
        Button(L10n.text(.actionRefresh)) { model.refresh() }
            .keyboardShortcut("r")
            .disabled(model.isRefreshing || model.isDataOperationRunning)
        Button(L10n.text(.menuBarSettings)) {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button(L10n.text(.menuBarShow)) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(L10n.text(.menuBarQuit)) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Offscreen picture of the status item and its menu (UI evidence only; the real menu is an `NSMenu`).
struct MenuBarEvidenceView: View {
    @Bindable var model: AppModel

    var body: some View {
        let presentation = model.menuBarPresentation
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Image(nsImage: MenuBarIcon.image(for: presentation))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
            }
            .padding(6)
            .background(Color(nsColor: .windowBackgroundColor))
            VStack(alignment: .leading, spacing: 4) {
                item(presentation.title, enabled: false)
                item(L10n.format(.topbarLastCheck, TimeText.format(model.lastChecked)), enabled: false)
                Divider()
                item(L10n.text(.actionRefresh), shortcut: "⌘R")
                item(L10n.text(.menuBarSettings), shortcut: "⌘,")
                item(L10n.text(.menuBarShow))
                Divider()
                item(L10n.text(.menuBarQuit), shortcut: "⌘Q")
            }
            .padding(8)
            .frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)).shadow(radius: 4))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 6)
        }
    }

    private func item(_ title: String, shortcut: String = "", enabled: Bool = true) -> some View {
        HStack {
            Text(title).foregroundStyle(enabled ? Color.primary : Color.secondary)
            Spacer()
            Text(verbatim: shortcut).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

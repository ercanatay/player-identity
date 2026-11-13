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

/// §30/§60 menu: status line, quick copy items and the server submenu, then Refresh, Settings, Show, Quit.
struct MenuBarMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(Array(model.menuBarQuickItems.enumerated()), id: \.offset) { _, item in
            quickItem(item)
        }
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

    @ViewBuilder
    private func quickItem(_ item: MenuBarQuickItem) -> some View {
        switch item {
        case .status(let line):
            Text(line)
        case .copyCID(let id, let label, let enabled):
            Button(MenuBarText.copyCID(label: label)) {
                if let id { model.menuBarCopy(.cid(id)) }
            }
            .disabled(!enabled)
        case .copyRawID(let enabled):
            Button(L10n.text(.menuBarCopyRawID)) { model.menuBarCopy(.rawID) }
                .disabled(!enabled)
        case .copied:
            Label(L10n.text(.actionCopied), systemImage: "checkmark")
        case .copyFailed:
            Label(L10n.text(.menuBarCopyFailed), systemImage: StatusLevel.red.symbolName)
        case .servers(let choices):
            Menu(L10n.text(.menuBarServers)) {
                ForEach(choices) { choice in
                    Menu(choice.label) {
                        Button(L10n.text(.menuBarCopyCID)) { model.menuBarCopy(.cid(choice.id)) }
                            .disabled(choice.cid == nil)
                        Button(L10n.text(.actionRecheck)) { model.recheckServer(choice.id) }
                            .disabled(!choice.canRecheck)
                    }
                }
            }
        }
    }
}

enum MenuBarText {
    static func copyCID(label: String?) -> String {
        guard let label, !label.isEmpty else { return L10n.text(.menuBarCopyCID) }
        return L10n.format(.menuBarCopyCIDOf, label)
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
                ForEach(Array(model.menuBarQuickItems.enumerated()), id: \.offset) { _, quick in
                    quickItem(quick)
                }
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

    @ViewBuilder
    private func quickItem(_ quick: MenuBarQuickItem) -> some View {
        switch quick {
        case .status(let line): item(line, enabled: false)
        case .copyCID(_, let label, let enabled): item(MenuBarText.copyCID(label: label), enabled: enabled)
        case .copyRawID(let enabled): item(L10n.text(.menuBarCopyRawID), enabled: enabled)
        case .copied: item(L10n.text(.actionCopied), symbol: "checkmark", enabled: false)
        case .copyFailed: item(L10n.text(.menuBarCopyFailed), symbol: StatusLevel.red.symbolName, enabled: false)
        case .servers(let choices):
            item(L10n.text(.menuBarServers), shortcut: "▸")
            ForEach(choices) { choice in
                item(choice.label, shortcut: "▸", indent: true)
                if choice.id == choices.first?.id {
                    // The first server's submenu, shown opened.
                    item(L10n.text(.menuBarCopyCID), enabled: choice.cid != nil, indent: true, depth: 2)
                    item(L10n.text(.actionRecheck), enabled: choice.canRecheck, indent: true, depth: 2)
                }
            }
        }
    }

    private func item(_ title: String, shortcut: String = "", symbol: String? = nil, enabled: Bool = true,
                      indent: Bool = false, depth: Int = 1) -> some View {
        HStack {
            if indent { Spacer().frame(width: CGFloat(14 * depth)) }
            if let symbol { Image(systemName: symbol).foregroundStyle(enabled ? Color.primary : Color.secondary) }
            Text(title).foregroundStyle(enabled ? Color.primary : Color.secondary)
            Spacer()
            Text(verbatim: shortcut).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

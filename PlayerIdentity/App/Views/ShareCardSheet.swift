import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// §33 share card preview: 1200×630 PNG, "Copy to Clipboard" and "Save to Disk" (NSSavePanel).
struct ShareCardSheet: View {
    @Bindable var model: AppModel
    let serverID: UUID
    let onClose: () -> Void

    @State private var png: Data?
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text(.shareCardCreate)).font(.title3.bold())
            Group {
                if let png, let image = NSImage(data: png) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(CGFloat(ShareCardRenderer.width) / CGFloat(ShareCardRenderer.height), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 2)
                        .accessibilityLabel(L10n.text(.shareCardCreate))
                        .accessibilityIdentifier("shareCardPreview")
                } else {
                    Text(L10n.text(.shareCardFailed))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .frame(width: 600)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack {
                Button(L10n.text(.shareCardCopy), action: copy)
                    .disabled(png == nil)
                Button(L10n.text(.shareCardSave), action: save)
                    .disabled(png == nil)
                Spacer()
                Button(L10n.text(.actionClose), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .onAppear(perform: render)
    }

    private func render() {
        guard png == nil else { return }
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        let icon = NSApp?.applicationIconImage?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        png = model.shareCardContent(for: serverID, icon: icon).flatMap(ShareCardRenderer.png)
    }

    private func copy() {
        guard let png else { return }
        ShareCardPasteboard.write(png, to: .general)
        message = L10n.text(.actionCopied)
        isError = false
    }

    private func save() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ShareCardPasteboard.fileName(label: model.servers.first { $0.id == serverID }?.label ?? "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
            message = L10n.format(.shareCardSaved, url.path)
            isError = false
        } catch {
            message = L10n.format(.shareCardSaveFailed, error.localizedDescription)
            isError = true
        }
    }
}

enum ShareCardPasteboard {
    static let fileStem = "PlayerIdentity"

    /// PNG plus TIFF (for apps that only read TIFF images).
    @MainActor
    static func write(_ png: Data, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    /// `PlayerIdentity-<label>.png`; characters that are not allowed in file names are replaced.
    static func fileName(label: String) -> String {
        let cleaned = label.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return fileStem + (cleaned.isEmpty ? "" : "-" + cleaned) + ".png"
    }
}

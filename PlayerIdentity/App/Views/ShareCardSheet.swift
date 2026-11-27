import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// §33 share card preview: 1200×630 PNG, "Copy to Clipboard" and "Save to Disk" (NSSavePanel).
/// §33.1.2: the card is rendered once, after the range ban of the history is read; until then the preview shows a
/// progress indicator and the export buttons are disabled.
struct ShareCardSheet: View {
    @Bindable var model: AppModel
    let serverID: UUID
    let onClose: () -> Void

    @State private var preview: ShareCardPreview
    @State private var message: String?
    @State private var isError = false

    init(model: AppModel, serverID: UUID, onClose: @escaping () -> Void, preview: ShareCardPreview = ShareCardPreview()) {
        self.model = model
        self.serverID = serverID
        self.onClose = onClose
        _preview = State(initialValue: preview)
    }

    private var png: Data? { preview.png }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text(.shareCardCreate)).font(TypeScale.headline)
            Group {
                switch preview.phase {
                case .loading:
                    ProgressView()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .accessibilityLabel(L10n.text(.shareCardCreate))
                        .accessibilityIdentifier("shareCardLoading")
                case .ready(let png):
                    if let image = NSImage(data: png) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(CGFloat(ShareCardRenderer.width) / CGFloat(ShareCardRenderer.height),
                                         contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 2)
                            .accessibilityLabel(L10n.text(.shareCardCreate))
                            .accessibilityIdentifier("shareCardPreview")
                    }
                case .failed:
                    Text(L10n.text(.shareCardFailed))
                        .foregroundStyle(Palette.text2)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .frame(width: 600)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isError ? Palette.redText : Palette.text2)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack {
                Button(L10n.text(.shareCardCopy), action: copy)
                    .disabled(!preview.canExport)
                    .accessibilityIdentifier("shareCardCopy")
                Button(L10n.text(.shareCardSave), action: save)
                    .disabled(!preview.canExport)
                    .accessibilityIdentifier("shareCardSave")
                Spacer()
                Button(L10n.text(.actionClose), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .task {
            let (model, id) = (model, serverID)
            await preview.load { await model.shareCardContentWithHistory(for: id, icon: Self.appIcon()) }
        }
    }

    private static func appIcon() -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        return NSApp?.applicationIconImage?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
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

/// State of the share card preview: loading until the content (with the history's range ban) is ready, then one
/// final PNG. Export is possible only with that PNG.
@MainActor
@Observable
final class ShareCardPreview {
    enum Phase: Equatable {
        case loading
        case ready(Data)
        case failed
    }

    private(set) var phase: Phase = .loading
    @ObservationIgnored private var started = false

    var png: Data? {
        if case .ready(let png) = phase { return png }
        return nil
    }

    var canExport: Bool { png != nil }

    /// Runs once; later calls (e.g. the view's task running again) do nothing.
    func load(_ content: () async -> ShareCardContent?) async {
        guard !started else { return }
        started = true
        let loaded = await content()
        phase = loaded.flatMap(ShareCardRenderer.png).map(Phase.ready) ?? .failed
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

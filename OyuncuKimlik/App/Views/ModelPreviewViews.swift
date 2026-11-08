import AppKit
import SwiftUI

/// §16.3 gösterim yardımcıları.
enum ModelPreviewStyle {
    /// Koyu zemin `#1B2432`.
    static let background = Color(.sRGB, red: 0x1B / 255.0, green: 0x24 / 255.0, blue: 0x32 / 255.0, opacity: 1)
    static let thumbnailSize = NSSize(width: 20, height: 24)
    static let previewSize = CGSize(width: 56, height: 68)
    static let cornerRadius: CGFloat = 8

    /// Oranı koruyarak `bounds` içine ortalar (aspect fit).
    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Menü satırı için 20×24 pt küçük resim. Çizim retina ölçeğinde, yüksek kaliteli interpolasyonla yapılır.
    /// `nil` = yükleniyor (iskelet: boş koyu kutu); yer tutucu = SF Symbol `person.crop.square`.
    @MainActor
    static func thumbnail(_ preview: ModelPreview?) -> NSImage {
        if preview == .placeholder {
            // 20×24 tuvalde ortalanmış SF Symbol; şablon görsel olduğundan menü metin rengine uyar.
            let symbol = NSImage(systemSymbolName: ModelPreview.placeholderSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            let canvas = NSImage(size: thumbnailSize, flipped: false) { rect in
                guard let symbol else { return true }
                symbol.draw(in: aspectFit(symbol.size, in: rect.insetBy(dx: 1, dy: 3)))
                return true
            }
            canvas.isTemplate = true
            return canvas
        }
        let image = preview?.image
        return NSImage(size: thumbnailSize, flipped: false) { rect in
            NSColor(srgbRed: 0x1B / 255.0, green: 0x24 / 255.0, blue: 0x32 / 255.0, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            guard let image, let context = NSGraphicsContext.current else { return true }
            context.imageInterpolation = .high
            let target = aspectFit(CGSize(width: image.pixelWidth, height: image.pixelHeight), in: rect)
            context.cgContext.draw(image.cgImage, in: target)
            return true
        }
    }
}

/// Seçili model önizlemesi: 56×68, 8 pt köşe, koyu zemin, 1 px çerçeve (§16.3).
struct ModelPreviewView: View {
    let preview: ModelPreview?
    let modelName: String

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            ModelPreviewStyle.background
            switch preview {
            case .image(let image)?:
                Image(decorative: image.cgImage, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            case .placeholder?:
                Image(systemName: ModelPreview.placeholderSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            case nil:
                EmptyView()   // iskelet: yalnız koyu zemin
            }
        }
        .frame(width: ModelPreviewStyle.previewSize.width, height: ModelPreviewStyle.previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: ModelPreviewStyle.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ModelPreviewStyle.cornerRadius)
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1 / max(displayScale, 1))
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch preview {
        case .image?: return "Model önizlemesi: \(modelName)"
        case .placeholder?: return "Model önizlemesi yok: \(modelName)"
        case nil: return "Model önizlemesi yükleniyor: \(modelName)"
        }
    }
}

/// Model dropdown'ı (§15.3, §16.3): yerel pull-down menü; her satırda 20×24 küçük resim + model adı.
/// SwiftUI `Menu` görselleri 16 pt'ye küçülttüğü için `NSPopUpButton` kullanılır ve görsel 20×24 pt verilir.
struct ModelPopUpButton: NSViewRepresentable {
    let title: String
    let options: [ModelOption]
    let thumbnails: [String: NSImage]
    let allowsManualEntry: Bool
    let onSelect: (String) -> Void
    let onManualEntry: () -> Void

    static let manualEntryTitle = "Elle gir…"

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let menu = NSMenu()
        menu.addItem(withTitle: title.isEmpty ? "—" : title, action: nil, keyEquivalent: "")   // başlık satırı
        for option in options {
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            item.image = thumbnails[option.value]
            // macOS 27+ menü öğesi görsellerini varsayılan olarak gizler; küçük resim her zaman görünmeli.
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            item.representedObject = option.value
            item.state = option.value == title ? .on : .off
            menu.addItem(item)
        }
        if allowsManualEntry {
            menu.addItem(.separator())
            let manual = NSMenuItem(title: Self.manualEntryTitle, action: nil, keyEquivalent: "")
            manual.representedObject = Coordinator.manualToken
            menu.addItem(manual)
        }
        button.menu = menu
        button.setAccessibilityLabel("Oyuncu modeli: \(title)")
    }

    @MainActor
    final class Coordinator: NSObject {
        static let manualToken = "\u{0}manual"
        var parent: ModelPopUpButton

        init(parent: ModelPopUpButton) {
            self.parent = parent
        }

        @objc func selected(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            if value == Self.manualToken {
                parent.onManualEntry()
            } else {
                parent.onSelect(value)
            }
        }
    }
}

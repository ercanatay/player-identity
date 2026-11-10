import AppKit
import SwiftUI

/// §16.3 display helpers.
enum ModelPreviewStyle {
    /// Dark background `#1B2432`.
    static let background = Palette.brandSlate
    static let thumbnailSize = NSSize(width: 20, height: 24)
    static let previewSize = Metrics.modelThumbnail
    static let cornerRadius: CGFloat = 8

    /// Centers inside `bounds` keeping the aspect ratio (aspect fit).
    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// 20×24 pt thumbnail for a menu row. Drawn at retina scale with high-quality interpolation.
    /// `nil` = loading (skeleton: empty dark box); placeholder = SF Symbol `person.crop.square`.
    @MainActor
    static func thumbnail(_ preview: ModelPreview?) -> NSImage {
        if preview == .placeholder {
            // SF Symbol centered on a 20×24 canvas; as a template image it follows the menu text color.
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
            Palette.brandSlateNS.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            guard let image, let context = NSGraphicsContext.current else { return true }
            context.imageInterpolation = .high
            let target = aspectFit(CGSize(width: image.pixelWidth, height: image.pixelHeight), in: rect)
            context.cgContext.draw(image.cgImage, in: target)
            return true
        }
    }
}

/// Selected model preview (§16.3): 72×96, radius 8, 1 pt border. Image on the brand-slate background,
/// placeholder = striped box with the file name, `nil` = loading skeleton.
struct ModelPreviewView: View {
    let preview: ModelPreview?
    let modelName: String

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .bottom) {
            switch preview {
            case .image(let image)?:
                ModelPreviewStyle.background
                Image(decorative: image.cgImage, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            case .placeholder?:
                StripedBackground()
                Text(verbatim: modelName.isEmpty ? "—" : modelName + ".bmp")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                    .padding(6)
                    .accessibilityHidden(true)
            case nil:
                Palette.skeleton   // loading skeleton
            }
        }
        .frame(width: ModelPreviewStyle.previewSize.width, height: ModelPreviewStyle.previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: ModelPreviewStyle.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ModelPreviewStyle.cornerRadius)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(accessibilityText)
    }

    var accessibilityText: String {
        switch preview {
        case .image?: return L10n.format(.a11yPreviewImage, modelName)
        case .placeholder?: return L10n.format(.a11yPreviewPlaceholder, modelName)
        case nil: return L10n.format(.a11yPreviewLoading, modelName)
        }
    }
}

/// 135° stripes, 6 pt on / 6 pt off, in the `--c-stripe` token.
private struct StripedBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 12 * 2.squareRoot()
            var path = Path()
            var x = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += step
            }
            context.stroke(path, with: .color(Palette.stripe), lineWidth: 6)
        }
        .accessibilityHidden(true)
    }
}

/// Model dropdown (§15.3, §16.3): native pull-down menu; each row has a 20×24 thumbnail + model name.
/// SwiftUI `Menu` shrinks images to 16 pt, so `NSPopUpButton` is used and images are given at 20×24 pt.
struct ModelPopUpButton: NSViewRepresentable {
    let title: String
    let options: [ModelOption]
    let thumbnails: [String: NSImage]
    let allowsManualEntry: Bool
    let onSelect: (String) -> Void
    let onManualEntry: () -> Void

    static var manualEntryTitle: String { L10n.text(.profileModelManualEntry) }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let menu = NSMenu()
        menu.addItem(withTitle: title.isEmpty ? "—" : title, action: nil, keyEquivalent: "")   // title row
        for option in options {
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            item.image = thumbnails[option.value]
            // macOS 27+ hides menu item images by default; the thumbnail must always be visible.
            if #available(macOS 27.0, *) {
                // KVC keeps the build compatible with older SDKs (property exists on macOS 27+).
                item.setValue(NSNumber(value: 1), forKey: "preferredImageVisibility")
            }
            item.representedObject = option.value
            item.toolTip = option.sourceTooltip
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
        button.setAccessibilityLabel(L10n.format(.a11yProfileModel, title))
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

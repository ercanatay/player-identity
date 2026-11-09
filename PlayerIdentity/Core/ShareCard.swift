import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

// MARK: - §33 CID share card

/// Captions in the user's language; supplied by the caller (the card itself has no texts).
struct ShareCardLabels: Sendable, Equatable {
    var title: String
    var server: String
    var cid: String
    var player: String
    var date: String

    init(title: String = "", server: String = "", cid: String = "", player: String = "", date: String = "") {
        self.title = title
        self.server = server
        self.cid = cid
        self.player = player
        self.date = date
    }
}

/// Card content. Empty fields are drawn as "—"; nothing is required.
struct ShareCardContent {
    var serverName: String
    /// `host:port` as shown in the row.
    var hostPort: String
    var cid: String
    var playerName: String
    /// Date and time, already formatted for the user's locale.
    var dateText: String
    var labels: ShareCardLabels
    /// App icon (e.g. `NSApp.applicationIconImage`); left out when `nil`.
    var icon: CGImage?

    init(serverName: String = "", hostPort: String = "", cid: String = "", playerName: String = "", dateText: String = "",
         labels: ShareCardLabels = ShareCardLabels(), icon: CGImage? = nil) {
        self.serverName = serverName
        self.hostPort = hostPort
        self.cid = cid
        self.playerName = playerName
        self.dateText = dateText
        self.labels = labels
        self.icon = icon
    }
}

enum ShareCardText {
    static let placeholder = "—"
    static let ellipsis = "…"

    /// Single line, at most `maxCharacters` characters (the last one becomes "…"); empty → "—".
    static func truncated(_ text: String, maxCharacters: Int) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return placeholder }
        guard maxCharacters > 1, line.count > maxCharacters else { return line }
        return String(line.prefix(maxCharacters - 1)).trimmingCharacters(in: .whitespaces) + ellipsis
    }
}

/// Renders the 1200×630 PNG. Pure: the same content gives the same image; no file or network access.
enum ShareCardRenderer {
    static let width = 1200
    static let height = 630
    static let maxNameCharacters = 48
    static let maxLineCharacters = 64

    private static let background = (top: CGColor(srgbRed: 0.106, green: 0.145, blue: 0.212, alpha: 1),
                                     bottom: CGColor(srgbRed: 0.157, green: 0.208, blue: 0.298, alpha: 1))
    private static let accent = CGColor(srgbRed: 0.133, green: 0.690, blue: 0.490, alpha: 1)
    private static let primaryText = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let secondaryText = CGColor(srgbRed: 0.72, green: 0.77, blue: 0.84, alpha: 1)

    static func png(_ content: ShareCardContent) -> Data? {
        guard let image = image(content) else { return nil }
        return pngData(image)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func image(_ content: ShareCardContent) -> CGImage? {
        guard let context = bitmap(width: width, height: height) else { return nil }
        let size = CGSize(width: width, height: height)

        // Background: brand gradient + accent bar.
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [background.bottom, background.top] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        context.setFillColor(accent)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 10))

        let left: CGFloat = 64
        let textWidth: CGFloat = 680   // up to the QR tile; a 32-character CID fits in full

        // Header: icon + title.
        var headerX = left
        if let icon = content.icon {
            context.interpolationQuality = .high
            context.draw(icon, in: CGRect(x: left, y: size.height - 64 - 88, width: 88, height: 88))
            headerX += 108
        }
        draw(ShareCardText.truncated(content.labels.title, maxCharacters: maxLineCharacters), font: font(30, bold: true),
             color: primaryText, at: CGPoint(x: headerX, y: size.height - 120), width: textWidth + left - headerX,
             in: context, placeholderIfEmpty: false)

        // Server
        caption(content.labels.server, y: 438, x: left, in: context)
        draw(ShareCardText.truncated(content.serverName, maxCharacters: maxNameCharacters), font: font(44, bold: true),
             color: primaryText, at: CGPoint(x: left, y: 388), width: textWidth, in: context)
        draw(ShareCardText.truncated(content.hostPort, maxCharacters: maxLineCharacters), font: monospaced(26),
             color: secondaryText, at: CGPoint(x: left, y: 350), width: textWidth, in: context)

        // CID
        caption(content.labels.cid, y: 292, x: left, in: context)
        draw(ShareCardText.truncated(content.cid, maxCharacters: maxLineCharacters), font: monospaced(32),
             color: primaryText, at: CGPoint(x: left, y: 248), width: textWidth, in: context)

        // Player + date
        caption(content.labels.player, y: 188, x: left, in: context)
        draw(ShareCardText.truncated(content.playerName, maxCharacters: maxNameCharacters), font: font(36, bold: true),
             color: primaryText, at: CGPoint(x: left, y: 146), width: 400, in: context)
        caption(content.labels.date, y: 188, x: left + 420, in: context)
        draw(ShareCardText.truncated(content.dateText, maxCharacters: maxLineCharacters), font: font(26, bold: false),
             color: primaryText, at: CGPoint(x: left + 420, y: 150), width: 260, in: context)

        // QR of the CID on a white tile (right side).
        let tile = CGRect(x: 770, y: (size.height - 380) / 2 + 6, width: 380, height: 380)
        let trimmedCID = content.cid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCID.isEmpty, let qr = qrCode(trimmedCID, side: 340) {
            context.setFillColor(primaryText)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 24, cornerHeight: 24, transform: nil))
            context.fillPath()
            context.interpolationQuality = .none
            context.draw(qr, in: tile.insetBy(dx: 20, dy: 20))
        }
        return context.makeImage()
    }

    /// QR code of `text` (error correction M), `side`×`side` pixels with sharp modules.
    static func qrCode(_ text: String, side: Int) -> CGImage? {
        guard side > 0, let data = text.data(using: .utf8), !data.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let modules = ciContext.createCGImage(output, from: output.extent),
              let context = bitmap(width: side, height: side) else { return nil }
        context.setFillColor(primaryText)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(modules, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    // MARK: Drawing helpers

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func monospaced(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
    }

    private static func caption(_ text: String, y: CGFloat, x: CGFloat, in context: CGContext) {
        draw(text.uppercased(), font: font(20, bold: true), color: secondaryText, at: CGPoint(x: x, y: y), width: 400,
             in: context, placeholderIfEmpty: false)
    }

    /// One line at the baseline `point`; wider text is cut with "…" to `width`.
    private static func draw(_ text: String, font: CTFont, color: CGColor, at point: CGPoint, width: CGFloat,
                             in context: CGContext, placeholderIfEmpty: Bool = true) {
        let value = text.isEmpty && placeholderIfEmpty ? ShareCardText.placeholder : text
        guard !value.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: ShareCardText.ellipsis, attributes: attributes))
        let fitted = CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? line
        context.textPosition = point
        CTLineDraw(fitted, context)
    }
}

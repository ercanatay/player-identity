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
    /// §33.1 "DURUM" caption.
    var status: String
    /// §33.1 "BAN TİPİ" caption.
    var banType: String
    /// §33.1.4 note under a status-only QR (GoldSrc 48); empty → none.
    var qrNote: String

    init(title: String = "", server: String = "", cid: String = "", player: String = "", date: String = "",
         status: String = "", banType: String = "", qrNote: String = "") {
        self.title = title
        self.server = server
        self.cid = cid
        self.player = player
        self.date = date
        self.status = status
        self.banType = banType
        self.qrNote = qrNote
    }
}

/// §33.1.1 DURUM of the card; the raw value is the QR key.
enum ShareCardStatus: String, Sendable, CaseIterable {
    case banned
    case clear
    case unverified
    case notChecked

    var text: String {
        switch self {
        case .banned: return L10n.text(.shareCardStatusBanned)
        case .clear: return L10n.text(.shareCardStatusClear)
        case .unverified: return L10n.text(.shareCardStatusUnverified)
        case .notChecked: return L10n.text(.shareCardStatusNotChecked)
        }
    }
}

/// §33.1.2 BAN TİPİ of the card; the raw value is the QR key.
enum ShareCardBanType: String, Sendable, CaseIterable {
    case ip
    case ipRange
    case cid
    case goldSrc
    case unknown
    case none

    var text: String {
        switch self {
        case .ip: return L10n.text(.shareCardBanTypeIP)
        case .ipRange: return L10n.text(.shareCardBanTypeIPRange)
        case .cid: return L10n.text(.shareCardBanTypeCID)
        case .goldSrc: return L10n.text(.shareCardBanTypeGoldSrc)
        case .unknown: return L10n.text(.shareCardBanTypeUnknown)
        case .none: return ShareCardText.placeholder
        }
    }
}

/// §33.1.1 / §33.1.2: DURUM and BAN TİPİ of a row from its last ban check. Pure; no network, no files.
enum ShareCardBanSummary {
    /// - Parameters:
    ///   - status: the row's last ban check (`nil` = not checked).
    ///   - rangeKnown: an IP range ban is known for the row (§17.10, fix result or history).
    ///   - goldSrc: the row is a GoldSrc 48 server (§75.10 P6: never "Ban yok"). There only the GoldSrc ban proof
    ///     (`goldSrcBanned`) means banned; an older Source result (`cidBanned`, `ipBanned`, `cidOk` …) saved before the
    ///     protocol was known proves nothing about this server and reads as unverified.
    static func classify(_ status: BanStatus?, rangeKnown: Bool,
                         goldSrc: Bool) -> (status: ShareCardStatus, banType: ShareCardBanType) {
        guard let status else { return (.notChecked, .none) }
        if goldSrc {
            switch status {
            case .goldSrcBanned: return (.banned, .goldSrc)
            case .unreachable: return (.unverified, .none)
            default: return (.unverified, .unknown)
            }
        }
        switch status {
        case .ipBanned: return (.banned, rangeKnown ? .ipRange : .ip)
        case .cidBanned: return (.banned, .cid)
        case .goldSrcBanned: return (.banned, .goldSrc)
        case .cidOk, .cidNotApplicable: return goldSrc ? (.unverified, .unknown) : (.clear, .none)
        case .unreachable: return (.unverified, .none)
        case .goldSrcUnverified, .cidUnknown, .unknown, .ipOk: return (.unverified, .unknown)
        }
    }
}

/// §33.1.4 QR payloads.
enum ShareCardQR {
    static let goldSrcVersion = "goldsrc48"

    /// GoldSrc 48: server, address, status and ban type keys and the fixed version; never a CID, raw ID, serial,
    /// ticket, password or path.
    static func goldSrcPayload(serverName: String, hostPort: String, status: ShareCardStatus,
                               banType: ShareCardBanType) -> String {
        [("sunucu", oneLine(serverName)), ("adres", oneLine(hostPort)), ("durum", status.rawValue),
         ("ban", banType.rawValue), ("surum", goldSrcVersion)]
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
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
    /// §33.1 DURUM value; the status rows are drawn when this or `status` is set.
    var statusText: String
    /// §33.1 BAN TİPİ value.
    var banTypeText: String
    /// §33.1.5 colour and symbol of the DURUM value.
    var status: ShareCardStatus?
    /// §33.1.5 colour and symbol of the BAN TİPİ value.
    var banType: ShareCardBanType?
    /// §33.1.3: `false` on a GoldSrc 48 card (no CID row at all).
    var showsCID: Bool
    /// §33.1.4: explicit QR text; `nil` → the CID (Source49, §33).
    var qrPayload: String?

    init(serverName: String = "", hostPort: String = "", cid: String = "", playerName: String = "", dateText: String = "",
         labels: ShareCardLabels = ShareCardLabels(), icon: CGImage? = nil, statusText: String = "",
         banTypeText: String = "", status: ShareCardStatus? = nil, banType: ShareCardBanType? = nil,
         showsCID: Bool = true, qrPayload: String? = nil) {
        self.serverName = serverName
        self.hostPort = hostPort
        self.cid = cid
        self.playerName = playerName
        self.dateText = dateText
        self.labels = labels
        self.icon = icon
        self.statusText = statusText
        self.banTypeText = banTypeText
        self.status = status
        self.banType = banType
        self.showsCID = showsCID
        self.qrPayload = qrPayload
    }

    var showsStatus: Bool {
        status != nil || !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Text encoded in the QR; empty → no QR.
    var resolvedQRPayload: String {
        (qrPayload ?? (showsCID ? cid : "")).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ShareCardText {
    static let placeholder = "—"
    static let ellipsis = "…"

    /// Line breaks become spaces; surrounding white space is removed.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text as given to CoreText: line breaks become spaces, no character is cut; empty → "—". Width decides
    /// wrapping and the final "…" (§33.1.5).
    static func displayed(_ text: String) -> String {
        let line = oneLine(text)
        return line.isEmpty ? placeholder : line
    }
}

/// Where each text of the card goes (§33.1.5); used for drawing and checked by the tests.
struct ShareCardLayout {
    enum Role: String, CaseIterable, Sendable {
        case title, serverCaption, serverName, hostPort, cidCaption, cid, statusCaption, status, banTypeCaption, banType
        case playerCaption, player, dateCaption, date, qrNote
    }

    enum Symbol: Sendable, Equatable {
        /// `xmark.octagon`
        case octagon
        /// `exclamationmark.triangle`
        case triangle
        case check
        case circle
    }

    struct Box {
        let role: Role
        /// Text as drawn (wrapped lines joined with "\n").
        let text: String
        /// Bounds of the drawn text (and symbol), card coordinates (origin bottom left).
        let frame: CGRect
        /// The box may not grow past this width.
        let maxWidth: CGFloat
        let lineCount: Int
        let fontSize: CGFloat
        /// The last line was cut with "…" because the text did not fit the allowed lines (never a character cap).
        let truncated: Bool
        let symbol: Symbol?
        let color: CGColor
        fileprivate let lines: [CTLine]
        fileprivate let origins: [CGPoint]
        fileprivate let font: CTFont
        fileprivate let symbolRect: CGRect?
    }

    /// Font scale of the middle block (1 → `ShareCardRenderer.minimumScale`).
    let scale: CGFloat
    /// Lowest edge allowed for the middle block: above the player/date row (which grows when its texts wrap).
    let stackBottom: CGFloat
    let boxes: [Box]
    /// White QR tile; `nil` without a payload.
    let qrTile: CGRect?

    func box(_ role: Role) -> Box? { boxes.first { $0.role == role } }
}

/// Renders the 1200×630 PNG. Pure: the same content gives the same image; no file or network access.
enum ShareCardRenderer {
    static let width = 1200
    static let height = 630
    /// §33.1.5 font floor of the middle block (server, CID, status, ban type); player and date never shrink.
    static let minimumScale: CGFloat = 0.75
    /// Left column: x = `left` … `left + textWidth`; the QR tile starts at 770.
    static let left: CGFloat = 64
    static let textWidth: CGFloat = 680
    /// The middle block starts here (below the header); its lower limit is `ShareCardLayout.stackBottom`.
    static let stackTop: CGFloat = 466
    /// Lowest edge of the player/date texts (above the accent bar).
    static let bottomMargin: CGFloat = 22

    private static let background = (top: CGColor(srgbRed: 0.106, green: 0.145, blue: 0.212, alpha: 1),
                                     bottom: CGColor(srgbRed: 0.157, green: 0.208, blue: 0.298, alpha: 1))
    private static let accent = CGColor(srgbRed: 0.133, green: 0.690, blue: 0.490, alpha: 1)
    private static let primaryText = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let secondaryText = CGColor(srgbRed: 0.72, green: 0.77, blue: 0.84, alpha: 1)
    static let banRed = CGColor(srgbRed: 1.0, green: 0.333, blue: 0.333, alpha: 1)
    static let warningOrange = CGColor(srgbRed: 1.0, green: 0.651, blue: 0.239, alpha: 1)
    static let clearGreen = CGColor(srgbRed: 0.204, green: 0.827, blue: 0.533, alpha: 1)

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
        let layout = layout(content)

        // Background: brand gradient + accent bar.
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [background.bottom, background.top] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        context.setFillColor(accent)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 10))

        if let icon = content.icon {
            context.interpolationQuality = .high
            context.draw(icon, in: CGRect(x: left, y: size.height - 64 - 88, width: 88, height: 88))
        }
        for box in layout.boxes {
            if let symbol = box.symbol, let rect = box.symbolRect {
                drawSymbol(symbol, in: rect, color: box.color, context: context)
            }
            for (line, origin) in zip(box.lines, box.origins) {
                context.textPosition = origin
                CTLineDraw(line, context)
            }
        }

        // QR on a white tile (right side).
        let payload = content.resolvedQRPayload
        if let tile = layout.qrTile, let qr = qrCode(payload, side: 340) {
            context.setFillColor(primaryText)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 24, cornerHeight: 24, transform: nil))
            context.fillPath()
            context.interpolationQuality = .none
            context.draw(qr, in: tile.insetBy(dx: 20, dy: 20))
        }
        return context.makeImage()
    }

    // MARK: Layout

    /// Scale candidates of the middle block, largest first, ending at `minimumScale`.
    static let scales: [CGFloat] = stride(from: 1.0, through: Double(minimumScale) - 0.001, by: -0.05)
        .map { CGFloat($0) }

    /// §33.1.5: long texts wrap to two lines first; if the block does not fit, the middle block shrinks step by step;
    /// the first candidate where every wrapped text fits whole is used. If none does, the floor (`minimumScale`) is
    /// used and only then lines are cut with "…" (two lines, or one line each if two do not fit vertically).
    /// Player and date keep their size.
    static func layout(_ content: ShareCardContent) -> ShareCardLayout {
        let (fixed, stackBottom) = fixedBoxes(content)
        func make(_ scale: CGFloat, _ boxes: [ShareCardLayout.Box]) -> ShareCardLayout {
            Self.make(content, scale: scale, stackBottom: stackBottom, boxes: fixed + boxes)
        }
        for scale in scales {
            let (boxes, bottom) = middleBoxes(content, scale: scale, wrapLines: 2)
            if bottom >= stackBottom, !boxes.contains(where: \.truncated) { return make(scale, boxes) }
        }
        let (floor, bottom) = middleBoxes(content, scale: minimumScale, wrapLines: 2)
        if bottom >= stackBottom { return make(minimumScale, floor) }
        let (boxes, _) = middleBoxes(content, scale: minimumScale, wrapLines: 1)
        return make(minimumScale, boxes)
    }

    private static func make(_ content: ShareCardContent, scale: CGFloat, stackBottom: CGFloat,
                             boxes: [ShareCardLayout.Box]) -> ShareCardLayout {
        let hasQR = !content.resolvedQRPayload.isEmpty
        let tile = hasQR ? CGRect(x: 770, y: (CGFloat(height) - 380) / 2 + 6, width: 380, height: 380) : nil
        var all = boxes
        if hasQR, content.qrPayload != nil, !content.labels.qrNote.isEmpty {
            all.append(textBox(.qrNote, content.labels.qrNote, font: font(18, bold: false), color: secondaryText,
                               x: 770, baseline: 100, width: 380, maxLines: 1))
        }
        return ShareCardLayout(scale: scale, stackBottom: stackBottom, boxes: all, qrTile: tile)
    }

    /// Header title and the player/date row. Player and date never shrink: they wrap to two lines in their own
    /// columns (the row grows upwards) and only then are cut with "…". Returns the boxes and the middle block's limit.
    private static func fixedBoxes(_ content: ShareCardContent) -> ([ShareCardLayout.Box], CGFloat) {
        let headerX = content.icon == nil ? left : left + 108
        let locale = L10n.textLocale
        var boxes: [ShareCardLayout.Box] = []
        if !content.labels.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            boxes.append(textBox(.title, ShareCardText.displayed(content.labels.title), font: font(30, bold: true),
                                 color: primaryText, x: headerX, baseline: CGFloat(height) - 120,
                                 width: textWidth + left - headerX, maxLines: 1))
        }
        let dateX = left + 420
        let player = ShareCardText.displayed(content.playerName)
        let date = ShareCardText.displayed(content.dateText)
        let playerFont = font(36, bold: true)
        let dateFont = font(26, bold: false)
        // Measure first (top 0), then place the row so that its lowest line sits on the bottom margin.
        func box(_ role: ShareCardLayout.Role, _ text: String, _ font: CTFont, x: CGFloat,
                 width: CGFloat, top: CGFloat) -> ShareCardLayout.Box {
            textBox(role, text, font: font, color: primaryText, x: x, top: top, width: width, maxLines: 2)
        }
        let rowHeight = max(box(.player, player, playerFont, x: left, width: 400, top: 0).frame.height,
                            box(.date, date, dateFont, x: dateX, width: 260, top: 0).frame.height)
        let rowTop = bottomMargin + rowHeight
        boxes.append(box(.player, player, playerFont, x: left, width: 400, top: rowTop))
        boxes.append(box(.date, date, dateFont, x: dateX, width: 260, top: rowTop - 4))
        let captionFont = font(20, bold: true)
        let captionTop = rowTop + 8 + ceil(CTFontGetAscent(captionFont) + CTFontGetDescent(captionFont))
        if !content.labels.player.isEmpty {
            boxes.append(textBox(.playerCaption, content.labels.player.uppercased(with: locale), font: captionFont,
                                 color: secondaryText, x: left, top: captionTop, width: 400, maxLines: 1))
        }
        if !content.labels.date.isEmpty {
            boxes.append(textBox(.dateCaption, content.labels.date.uppercased(with: locale), font: captionFont,
                                 color: secondaryText, x: dateX, top: captionTop, width: 260, maxLines: 1))
        }
        return (boxes, captionTop + 14)
    }

    /// Server, CID, DURUM and BAN TİPİ from `stackTop` down; returns the boxes and the lowest edge.
    private static func middleBoxes(_ content: ShareCardContent, scale: CGFloat,
                                    wrapLines: Int) -> ([ShareCardLayout.Box], CGFloat) {
        var boxes: [ShareCardLayout.Box] = []
        var top = stackTop
        let captionFont = font(max(16, 20 * scale), bold: true)
        let locale = L10n.textLocale
        let captionGap = 6 * scale
        let blockGap = 16 * scale

        func add(_ box: ShareCardLayout.Box, gap: CGFloat) {
            boxes.append(box)
            top = box.frame.minY - gap
        }
        func caption(_ role: ShareCardLayout.Role, _ text: String) {
            guard !text.isEmpty else { return }
            add(textBox(role, text.uppercased(with: locale), font: captionFont, color: secondaryText, x: left, top: top,
                        width: textWidth, maxLines: 1), gap: captionGap)
        }

        // Server
        caption(.serverCaption, content.labels.server)
        add(textBox(.serverName, ShareCardText.displayed(content.serverName), font: font(44 * scale, bold: true),
                    color: primaryText, x: left, top: top, width: textWidth, maxLines: wrapLines), gap: 4 * scale)
        add(textBox(.hostPort, ShareCardText.displayed(content.hostPort), font: monospaced(26 * scale),
                    color: secondaryText, x: left, top: top, width: textWidth, maxLines: 1), gap: blockGap)

        // CID (§33.1.3: never on a GoldSrc 48 card)
        if content.showsCID {
            caption(.cidCaption, content.labels.cid)
            add(textBox(.cid, ShareCardText.displayed(content.cid), font: monospaced(32 * scale), color: primaryText,
                        x: left, top: top, width: textWidth, maxLines: 1), gap: blockGap)
        }

        // DURUM + BAN TİPİ (§33.1.1, §33.1.2)
        if content.showsStatus {
            caption(.statusCaption, content.labels.status)
            add(textBox(.status, ShareCardText.displayed(content.statusText), font: font(32 * scale, bold: true),
                        color: color(of: content.status), x: left, top: top, width: textWidth, maxLines: wrapLines,
                        symbol: symbol(of: content.status)), gap: blockGap)
            caption(.banTypeCaption, content.labels.banType)
            add(textBox(.banType, ShareCardText.displayed(content.banTypeText), font: font(28 * scale, bold: true),
                        color: color(of: content.banType), x: left, top: top, width: textWidth, maxLines: wrapLines,
                        symbol: symbol(of: content.banType)), gap: 0)
        }
        let bottom = boxes.map(\.frame.minY).min() ?? stackTop
        return (boxes, bottom)
    }

    static func color(of status: ShareCardStatus?) -> CGColor {
        switch status {
        case .banned?: return banRed
        case .clear?: return clearGreen
        case .unverified?: return warningOrange
        case .notChecked?, nil: return secondaryText
        }
    }

    static func color(of banType: ShareCardBanType?) -> CGColor {
        switch banType {
        case .ip?, .ipRange?, .cid?: return banRed
        case .goldSrc?, .unknown?: return warningOrange
        case .none?, nil: return secondaryText
        }
    }

    /// §33.1.5: red and orange values always carry a symbol next to the text.
    static func symbol(of status: ShareCardStatus?) -> ShareCardLayout.Symbol? {
        switch status {
        case .banned?: return .octagon
        case .unverified?: return .triangle
        case .clear?: return .check
        case .notChecked?: return .circle
        case nil: return nil
        }
    }

    static func symbol(of banType: ShareCardBanType?) -> ShareCardLayout.Symbol? {
        switch banType {
        case .ip?, .ipRange?, .cid?: return .octagon
        case .goldSrc?, .unknown?: return .triangle
        case .none?, nil: return nil
        }
    }

    // MARK: Text boxes

    private static func textBox(_ role: ShareCardLayout.Role, _ text: String, font: CTFont, color: CGColor,
                                x: CGFloat, top: CGFloat, width: CGFloat, maxLines: Int,
                                symbol: ShareCardLayout.Symbol? = nil) -> ShareCardLayout.Box {
        textBox(role, text, font: font, color: color, x: x, baseline: top - CTFontGetAscent(font), width: width,
                maxLines: maxLines, symbol: symbol)
    }

    /// Wraps `text` into at most `maxLines` lines of `width` (minus the symbol); the first baseline is `baseline`.
    private static func textBox(_ role: ShareCardLayout.Role, _ text: String, font: CTFont, color: CGColor,
                                x: CGFloat, baseline: CGFloat, width: CGFloat, maxLines: Int,
                                symbol: ShareCardLayout.Symbol? = nil) -> ShareCardLayout.Box {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = ceil(ascent + descent) + 4
        let symbolSide = symbol == nil ? 0 : ceil(ascent * 0.9)
        let textX = symbol == nil ? x : x + symbolSide + 12
        let available = width - (textX - x)
        let (wrapped, truncated) = wrap(text, font: font, color: color, width: available, maxLines: max(1, maxLines))
        let lines = wrapped.map(\.line)
        var origins: [CGPoint] = []
        var widest: CGFloat = 0
        for (index, line) in lines.enumerated() {
            origins.append(CGPoint(x: textX, y: baseline - CGFloat(index) * lineHeight))
            widest = max(widest, lineWidth(line))
        }
        let lastBaseline = origins.last?.y ?? baseline
        let frame = CGRect(x: x, y: lastBaseline - descent, width: (textX - x) + widest,
                           height: (baseline + ascent) - (lastBaseline - descent))
        let symbolRect = symbol == nil ? nil : CGRect(x: x, y: baseline - descent * 0.2, width: symbolSide, height: symbolSide)
        return ShareCardLayout.Box(role: role, text: wrapped.map(\.text).joined(separator: "\n"), frame: frame, maxWidth: width,
                                   lineCount: lines.count, fontSize: CTFontGetSize(font),
                                   truncated: truncated,
                                   symbol: symbol, color: color, lines: lines, origins: origins, font: font,
                                   symbolRect: symbolRect)
    }

    /// Line breaking with CoreText; the last allowed line takes the rest and is cut with "…" if it is wider.
    private static func wrap(_ text: String, font: CTFont, color: CGColor, width: CGFloat,
                             maxLines: Int) -> ([(line: CTLine, text: String)], Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: ShareCardText.ellipsis, attributes: attributes))
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        let source = attributed.string as NSString
        var lines: [(line: CTLine, text: String)] = []
        var start = 0
        var truncated = false
        while start < length, lines.count < maxLines {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            let isLast = lines.count == maxLines - 1
            let count = isLast || suggested <= 0 ? length - start : suggested
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            let piece = source.substring(with: NSRange(location: start, length: count))
                .trimmingCharacters(in: .whitespaces)
            if lineWidth(line) > width {
                let cut = CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? token
                // The kept runs map to the source; the last run is the "…" token standing for the rest.
                let runs = CTLineGetGlyphRuns(cut) as? [CTRun] ?? []
                let kept = runs.dropLast().map { CTRunGetStringRange($0) }
                    .map { $0.location + $0.length }.max() ?? start
                let visible = source.substring(with: NSRange(location: start, length: max(0, kept - start)))
                    .trimmingCharacters(in: .whitespaces)
                lines.append((cut, visible + ShareCardText.ellipsis))
                truncated = true
                break
            }
            lines.append((line, piece))
            start += count
        }
        return (lines, truncated)
    }

    private static func lineWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    // MARK: Symbols

    private static func drawSymbol(_ symbol: ShareCardLayout.Symbol, in rect: CGRect, color: CGColor,
                                   context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let mark = CGColor(srgbRed: 0.106, green: 0.145, blue: 0.212, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch symbol {
        case .octagon:
            let path = CGMutablePath()
            for index in 0..<8 {
                let angle = CGFloat.pi / 8 + CGFloat(index) * CGFloat.pi / 4
                let point = CGPoint(x: mid.x + radius * cos(angle), y: mid.y + radius * sin(angle))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
            let arm = radius * 0.42
            context.setStrokeColor(mark)
            context.setLineWidth(max(2, radius * 0.22))
            context.move(to: CGPoint(x: mid.x - arm, y: mid.y - arm))
            context.addLine(to: CGPoint(x: mid.x + arm, y: mid.y + arm))
            context.move(to: CGPoint(x: mid.x - arm, y: mid.y + arm))
            context.addLine(to: CGPoint(x: mid.x + arm, y: mid.y - arm))
            context.strokePath()
        case .triangle:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: mid.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.08))
            path.closeSubpath()
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(mark)
            context.setLineWidth(max(2, radius * 0.2))
            context.move(to: CGPoint(x: mid.x, y: rect.minY + rect.height * 0.68))
            context.addLine(to: CGPoint(x: mid.x, y: rect.minY + rect.height * 0.40))
            context.strokePath()
            context.setFillColor(mark)
            let dot = max(2, radius * 0.22)
            context.fillEllipse(in: CGRect(x: mid.x - dot / 2, y: rect.minY + rect.height * 0.2, width: dot, height: dot))
        case .check:
            context.setFillColor(color)
            context.fillEllipse(in: rect)
            context.setStrokeColor(mark)
            context.setLineWidth(max(2, radius * 0.22))
            context.move(to: CGPoint(x: mid.x - radius * 0.45, y: mid.y))
            context.addLine(to: CGPoint(x: mid.x - radius * 0.1, y: mid.y - radius * 0.35))
            context.addLine(to: CGPoint(x: mid.x + radius * 0.45, y: mid.y + radius * 0.35))
            context.strokePath()
        case .circle:
            context.setStrokeColor(color)
            context.setLineWidth(max(2, radius * 0.16))
            context.strokeEllipse(in: rect.insetBy(dx: radius * 0.1, dy: radius * 0.1))
            context.move(to: CGPoint(x: mid.x - radius * 0.4, y: mid.y))
            context.addLine(to: CGPoint(x: mid.x + radius * 0.4, y: mid.y))
            context.strokePath()
        }
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
}

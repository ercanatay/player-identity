import AppKit
import SwiftUI

/// Status icon; color alone carries no meaning, it has an accessibility label and tooltip (§7.4).
struct StatusIcon: View {
    let level: StatusLevel
    var help: String?

    var body: some View {
        Image(systemName: level.symbolName)
            .foregroundStyle(level.color)
            .accessibilityLabel(level.label)
            .help(help ?? level.label)
    }
}

enum Pasteboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Finder {
    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Card

/// Card: radius 12, card fill, 1 pt border, padding 16, VStack spacing 12 (N1 §6).
struct ThemedCard<Header: View, Content: View>: View {
    var spacing: CGFloat = Space.s3
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header
            content
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Card header row (24 pt): SF Symbol 16 (secondary) + label 13 semibold + optional count + trailing actions.
struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var count: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Palette.text2)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: count)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text3)
                    .monospacedDigit()
            }
            Spacer(minLength: Space.s2)
            trailing
        }
        .frame(minHeight: Metrics.control)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(symbol: String, title: String, count: String? = nil) {
        self.init(symbol: symbol, title: title, count: count) { EmptyView() }
    }
}

// MARK: - Small pieces

/// Badge: 11 semibold on a status tint, radius 4.
struct TintBadge: View {
    let text: String
    let foreground: Color
    let background: Color
    /// Optional SF Symbol 11 before the text (version history badges).
    var symbol: String?

    var body: some View {
        HStack(spacing: Space.s1) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
            Text(text)
        }
        .font(TypeScale.captionStrong)
        .foregroundStyle(foreground)
        .padding(.horizontal, symbol == nil ? 6 : Space.s2)
        .padding(.vertical, symbol == nil ? 1 : 2)
        .background(RoundedRectangle(cornerRadius: Radius.badge).fill(background))
        .fixedSize()
    }
}

/// Inline notice (radius 8, padding 8/12): icon + text + optional trailing control.
struct NoticeBox<Trailing: View>: View {
    let symbol: String
    let symbolColor: Color
    let text: String
    var textColor: Color = Palette.text
    let background: Color
    var border: Color?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(text)
                .font(TypeScale.callout)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(background))
        .overlay {
            if let border {
                RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(border, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension NoticeBox where Trailing == EmptyView {
    init(symbol: String, symbolColor: Color, text: String, textColor: Color = Palette.text, background: Color,
         border: Color? = nil) {
        self.init(symbol: symbol, symbolColor: symbolColor, text: text, textColor: textColor, background: background,
                  border: border) { EmptyView() }
    }
}

/// Skeleton bar (loading state with identical geometry).
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 10
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Palette.skeleton)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// Empty / error block: symbol 32 + title 13 semibold + body 12 + buttons; reserves 236 pt.
struct StateBlock<Actions: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let message: String
    var minHeight: CGFloat = Metrics.stateMinHeight
    var dashed = false
    var monospacedMessage = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Space.s2) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(Palette.text)
            Text(message)
                .font(monospacedMessage ? TypeScale.monoSmall : TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .help(message)
            HStack(spacing: Space.s2) { actions }
                .padding(.top, Space.s1)
        }
        .padding(.horizontal, Space.s6)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .overlay {
            if dashed {
                RoundedRectangle(cornerRadius: Radius.inner)
                    .strokeBorder(Palette.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Icon-only borderless button with a hover fill (22×22 in rows, 32×28 in the toolbar).
struct IconButton: View {
    let symbol: String
    let label: String
    var size = CGSize(width: Metrics.smallControl, height: Metrics.smallControl)
    var symbolSize: CGFloat = 12
    var tint: Color = Palette.text2
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(tint)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Palette.toolbarHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Filter chip: capsule 24 pt. Off: control fill + symbol; on: accent tint + accent border + checkmark.
struct FilterChip: View {
    let title: String
    let symbol: String
    let count: Int
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                Text(verbatim: String(count))
                    .foregroundStyle(Palette.text3)
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isOn ? Palette.accentText : Palette.text)
            .padding(.horizontal, 10)
            .frame(height: Metrics.control)
            .background(Capsule().fill(isOn ? Palette.accentTint : Palette.control))
            .overlay(Capsule().strokeBorder(isOn ? Palette.accent : Palette.controlBorder, lineWidth: isOn ? 1 : 0.5))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(String(count))
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

/// Menu-like row inside a popover (26 pt, accent fill on hover).
struct PopoverActionRow: View {
    let symbol: String
    let title: String
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(TypeScale.body)
            .foregroundStyle(hovering ? Palette.onAccent : Palette.text)
            .padding(.horizontal, Space.s2)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Palette.accentFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? title)
    }
}

/// Group title inside a popover list (11 semibold, secondary).
struct PopoverGroupTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(TypeScale.captionStrong)
            .foregroundStyle(Palette.text2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Space.s2)
            .padding(.top, Space.s1)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Status chip (§48): SF Symbol + text on the tone's tint, 22 pt, radius 6. State is always text, never colour alone.
struct StatusChip: View {
    let symbol: String
    let text: String
    let tone: ChipTone
    var monospaced = false
    /// Tooltip; defaults to the text (a chip that truncates still shows its full value).
    var help: String?

    var body: some View {
        HStack(spacing: Space.s1) {
            Image(systemName: symbol)
                .font(TypeScale.symbolSmall)
                .foregroundStyle(tone.iconColor)
                .accessibilityHidden(true)
            Text(text)
                .font(monospaced ? TypeScale.monoSmall : TypeScale.chip)
                .foregroundStyle(tone.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Space.s2)
        .frame(height: Metrics.chip)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(tone.tint))
        .help(help ?? text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Toolbar row: leading group, flexible space, trailing group. In the app the window toolbar hosts the same
/// groups (`.toolbar`); offscreen renders have no window toolbar, so they draw this 52 pt strip on the toolbar
/// token instead — the system traffic lights are not drawn, only their space is kept.
struct InlineToolbar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Palette.toolbar
            .frame(height: Metrics.toolbar)
            .overlay(alignment: .leading) {
                HStack(spacing: Space.s3) {
                    Color.clear.frame(width: Metrics.trafficLights)
                    leading
                    Spacer(minLength: Space.s2)
                    HStack(spacing: Space.s2) { trailing }
                }
                .padding(.horizontal, Space.s3)
            }
            .clipped()
            .overlay(alignment: .bottom) { ThemedDivider() }
    }
}

/// Window title + count in the toolbar (15 semibold + 12 tertiary).
struct ToolbarTitle: View {
    let title: String
    var count: String?

    var body: some View {
        HStack(spacing: Space.s2) {
            Text(title)
                .font(TypeScale.headline)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: count)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// 1 pt separator in the token colour.
struct ThemedDivider: View {
    var body: some View {
        Rectangle().fill(Palette.separator).frame(height: 1).accessibilityHidden(true)
    }
}

extension View {
    /// Default button: `.borderedProminent` tinted with `accent-fill`.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent).tint(Palette.accentFill)
    }

    /// Text that truncates in the middle, shows the full value as a tooltip and is selectable (N1 §10).
    func middleTruncated(_ full: String) -> some View {
        lineLimit(1).truncationMode(.middle).help(full).textSelection(.enabled)
    }
}

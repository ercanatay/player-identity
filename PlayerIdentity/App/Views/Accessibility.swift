import AppKit
import SwiftUI

// MARK: - §55 VoiceOver texts

/// VoiceOver label + value of a custom control. State is always spoken as text, never carried by colour alone.
struct AccessibilityElementText: Equatable, Sendable {
    let label: String
    let value: String
}

/// The server list filter chips (header) and their popover toggles.
enum ServerFilterChipKind: CaseIterable, Sendable {
    case banned
    case favorites
    case watched

    var title: String {
        switch self {
        case .banned: return L10n.text(.serversChipBanned)
        case .favorites: return L10n.text(.serversChipFavorites)
        case .watched: return L10n.text(.serversChipWatched)
        }
    }

    var symbol: String {
        switch self {
        case .banned: return "xmark.octagon.fill"
        case .favorites: return "star.fill"
        case .watched: return "bell.fill"
        }
    }
}

/// The ★ / 🔔 switches at the start of a server row.
enum ServerRowMark: CaseIterable, Sendable {
    case favorite
    case watch
}

@MainActor
enum AccessibilityText {
    static func onOff(_ isOn: Bool) -> String { L10n.text(isOn ? .a11yOn : .a11yOff) }

    /// Filter chip: "Banned" · "3 servers, On".
    static func filterChip(_ kind: ServerFilterChipKind, count: Int, isOn: Bool) -> AccessibilityElementText {
        AccessibilityElementText(label: kind.title, value: L10n.format(.a11yChipValue, String(count), onOff(isOn)))
    }

    /// Row switch: the label names the action the click performs, the value the current state.
    static func mark(_ mark: ServerRowMark, isOn: Bool) -> AccessibilityElementText {
        switch mark {
        case .favorite:
            return AccessibilityElementText(label: L10n.text(isOn ? .serverFavoriteRemove : .serverFavoriteAdd),
                                            value: L10n.text(.serverFavorite) + ": " + onOff(isOn))
        case .watch:
            return AccessibilityElementText(label: L10n.text(isOn ? .watchToggleOff : .watchToggleOn),
                                            value: L10n.text(.watchBadge) + ": " + onOff(isOn))
        }
    }

    /// Ban cell: "Ban: IP ban" · detail (last check / raw reply).
    static func ban(_ content: BanCellContent) -> AccessibilityElementText {
        AccessibilityElementText(label: L10n.format(.a11yBan, content.title), value: content.detail)
    }

    /// Overall status icon / chip.
    static func status(_ level: StatusLevel) -> AccessibilityElementText {
        AccessibilityElementText(label: L10n.text(.a11yStatus), value: level.label)
    }

    static func appeal(_ status: AppealStatus) -> AccessibilityElementText {
        AccessibilityElementText(label: L10n.text(.appealTitle), value: status.label)
    }

    /// §56 mode picker entries.
    static func notificationMode(_ mode: ServerNotificationMode) -> String {
        switch mode {
        case .inherit: return L10n.text(.serverNotifyModeInherit)
        case .all: return L10n.text(.serverNotifyModeAll)
        case .bansOnly: return L10n.text(.serverNotifyModeBansOnly)
        case .off: return L10n.text(.serverNotifyModeOff)
        }
    }

    static func quietOverride(_ override: QuietHoursOverride) -> String {
        switch override {
        case .inherit: return L10n.text(.serverNotifyQuietInherit)
        case .on: return L10n.text(.serverNotifyQuietOn)
        case .off: return L10n.text(.serverNotifyQuietOff)
        }
    }

    /// Row value when the server has its own notification settings (`nil` = inherits everything).
    static func serverNotifications(_ settings: ServerNotificationSettings?) -> String? {
        guard let settings, !settings.isDefault else { return nil }
        return L10n.format(.a11yServerNotifications, notificationMode(settings.mode))
    }
}

// MARK: - Contrast (WCAG 2.x)

/// Relative luminance and contrast ratio of the design tokens (§55: AA text, 3 : 1 for the focus ring).
enum ContrastRatio {
    /// WCAG AA for normal text.
    static let textMinimum = 4.5
    /// WCAG non-text contrast (focus indicators, control borders).
    static let nonTextMinimum = 3.0

    static func luminance(_ color: Palette.RGBA) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let c = Double(value)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    /// `(L1 + 0.05) / (L2 + 0.05)`, lighter over darker; 1 … 21. A translucent foreground is composited first.
    static func ratio(_ foreground: Palette.RGBA, on background: Palette.RGBA) -> Double {
        let fg = composite(foreground, over: background)
        let a = luminance(fg), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func composite(_ top: Palette.RGBA, over bottom: Palette.RGBA) -> Palette.RGBA {
        let a = top.alpha
        return Palette.RGBA(red: top.red * a + bottom.red * (1 - a), green: top.green * a + bottom.green * (1 - a),
                            blue: top.blue * a + bottom.blue * (1 - a), alpha: 1)
    }
}

extension Palette {
    /// sRGB value of a token in an appearance (light, dark and their high-contrast variants).
    static func resolved(_ color: Color, in appearance: NSAppearance) -> RGBA? {
        var result: RGBA?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            result = RGBA(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent,
                          alpha: srgb.alphaComponent)
        }
        return result
    }
}

// MARK: - Focus ring and hit targets

/// Visible focus ring of the custom controls (search field, server table): 2 pt accent text colour (≥ 3 : 1 on every
/// surface) inside the translucent focus halo token.
enum FocusRing {
    static let color = Palette.accentText
    static let halo = Palette.focus
    static let lineWidth: CGFloat = 2
    static let haloWidth: CGFloat = 3
}

private struct FocusRingModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius + FocusRing.haloWidth)
                        .stroke(FocusRing.halo, lineWidth: FocusRing.haloWidth)
                        .padding(-FocusRing.haloWidth)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(FocusRing.color, lineWidth: FocusRing.lineWidth)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// §55 focus ring drawn by the app (the system ring is off for these custom-drawn controls).
    func focusRing(_ isFocused: Bool, cornerRadius: CGFloat) -> some View {
        modifier(FocusRingModifier(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}

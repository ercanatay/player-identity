import AppKit
import SwiftUI

/// Design tokens of the main window redesign — a 1:1 copy of `docs/design/handoff/tokens.css`.
/// Colours are dynamic (light `Any` / dark), so every view follows the window appearance.
enum Palette {
    // Surfaces
    static let window = dynamic(.hex(0xF2F4F7), .hex(0x111821))
    static let toolbar = dynamic(.hex(0xF8F9FB), .hex(0x18202B))
    static let card = dynamic(.hex(0xFFFFFF), .hex(0x1B2432))
    static let raised = dynamic(.hex(0xFFFFFF), .hex(0x243042))
    static let field = dynamic(.hex(0xFFFFFF), .hex(0x141B25))
    static let inset = dynamic(.hex(0xF6F7F9), .hex(0x151C27))
    static let group = dynamic(.hex(0xF4F6F8), .hex(0x202A39))
    static let rowHover = dynamic(.ink(0.035), .white(0.03))
    static let border = dynamic(.ink(0.08), .white(0.08))
    static let borderStrong = dynamic(.ink(0.16), .white(0.16))
    static let separator = dynamic(.ink(0.08), .white(0.08))

    // Text
    static let text = dynamic(.hex(0x1B2432), .hex(0xE9EEF4))
    static let text2 = dynamic(.hex(0x525D6D), .hex(0xA7B1C0))
    static let text3 = dynamic(.hex(0x636D7C), .hex(0x8D99AB))

    // Accent (brand teal)
    static let accent = dynamic(.hex(0x2FB6A8), .hex(0x2FB6A8))
    static let accentText = dynamic(.hex(0x177A70), .hex(0x52D3C4))
    static let accentFill = dynamic(.hex(0x187A71), .hex(0x2FB6A8))
    static let onAccent = dynamic(.hex(0xFFFFFF), .hex(0x08201E))
    static let accentTint = dynamic(.rgba(0x2FB6A8, 0.12), .rgba(0x2FB6A8, 0.16))
    static let focus = dynamic(.rgba(0x2FB6A8, 0.55), .rgba(0x2FB6A8, 0.6))

    // Status: raw colours for icons/fills, `-text` variants for text (WCAG AA), tints for backgrounds.
    static let green = dynamic(.hex(0x34C759), .hex(0x34C759))
    static let greenText = dynamic(.hex(0x1A7F37), .hex(0x5BD97A))
    static let greenTint = dynamic(.rgba(0x34C759, 0.14), .rgba(0x34C759, 0.18))
    static let orange = dynamic(.hex(0xFF9F0A), .hex(0xFF9F0A))
    static let orangeText = dynamic(.hex(0x9A4A00), .hex(0xFFB547))
    static let orangeTint = dynamic(.rgba(0xFF9F0A, 0.16), .rgba(0xFF9F0A, 0.18))
    static let red = dynamic(.hex(0xFF453A), .hex(0xFF453A))
    static let redText = dynamic(.hex(0xC0201A), .hex(0xFF7A70))
    static let redTint = dynamic(.rgba(0xFF453A, 0.12), .rgba(0xFF453A, 0.18))

    // Controls
    static let control = dynamic(.hex(0xFFFFFF), .white(0.10))
    static let controlBorder = dynamic(.ink(0.14), .white(0.10))
    static let toolbarHover = dynamic(.ink(0.06), .white(0.07))
    /// `--c-switch-off` / `--c-knob`: switch track when off (also segmented-control track) and the knob.
    static let switchOff = dynamic(.ink(0.16), .white(0.18))
    static let knob = dynamic(.hex(0xFFFFFF), .hex(0xF2F4F7))
    static let skeleton = dynamic(.ink(0.07), .white(0.07))
    static let stripe = dynamic(.ink(0.06), .white(0.05))
    static let scrim = dynamic(.ink(0.16), .black(0.38))

    /// `--brand-slate`: dark card surface and light-mode ink.
    static let brandSlate = Color(nsColor: brandSlateNS)
    static let brandSlateNS = RGBA.hex(0x1B2432).nsColor

    /// One CSS colour value (`#RRGGBB` or `rgba(r, g, b, a)`).
    struct RGBA {
        let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat

        static func hex(_ value: UInt32) -> RGBA { rgba(value, 1) }
        static func rgba(_ value: UInt32, _ alpha: CGFloat) -> RGBA {
            RGBA(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                 blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
        }
        /// `rgba(27, 36, 50, a)` — brand slate ink at an opacity (light-mode borders, hovers, skeletons).
        static func ink(_ alpha: CGFloat) -> RGBA { rgba(0x1B2432, alpha) }
        static func white(_ alpha: CGFloat) -> RGBA { rgba(0xFFFFFF, alpha) }
        static func black(_ alpha: CGFloat) -> RGBA { rgba(0x000000, alpha) }

        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua,
                                    .accessibilityHighContrastAqua]).map {
            [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0)
        } ?? false
    }

    private static func dynamic(_ light: RGBA, _ dark: RGBA) -> Color {
        let lightColor = light.nsColor, darkColor = dark.nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in isDark(appearance) ? darkColor : lightColor })
    }
}

/// 8 pt grid (`--sp-*`).
enum Space {
    /// Icon ↔ label in compact rows, row gaps in key/value grids.
    static let s1: CGFloat = 4
    /// Default gap: icon ↔ label, buttons in a group, field label ↔ field.
    static let s2: CGFloat = 8
    /// Grid column gap, card header ↔ body.
    static let s3: CGFloat = 12
    /// Card padding, gap between cards, window content inset.
    static let s4: CGFloat = 16
    /// Empty-state padding.
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
}

/// Corner radii (`--r-*`).
enum Radius {
    static let control: CGFloat = 6
    static let inner: CGFloat = 8
    static let window: CGFloat = 10
    static let card: CGFloat = 12
    static let sheet: CGFloat = 12
    static let badge: CGFloat = 4
}

/// Fixed heights and widths (`--h-*` and N1 component specs).
enum Metrics {
    static let toolbar: CGFloat = 52
    static let control: CGFloat = 24
    static let smallControl: CGFloat = 22
    static let row: CGFloat = 48
    static let groupHeader: CGFloat = 28
    static let keyValueRow: CGFloat = 22
    static let reasonRow: CGFloat = 52
    static let interfaceRow: CGFloat = 24
    /// Skeletons and empty/error blocks reserve this height so switching state never reflows the window.
    static let stateMinHeight: CGFloat = 236
    static let nameField: CGFloat = 36
    static let modelPicker: CGFloat = 148
    static let modelThumbnail = CGSize(width: 72, height: 96)
    static let keyValueLabel: CGFloat = 104
    static let searchField: CGFloat = 168
    static let filtersPopover: CGFloat = 264
    static let actionsPopover: CGFloat = 296
    static let toolbarButton = CGSize(width: 32, height: 28)
    /// Top row stacks below this content width (N1 §2).
    static let stackedBreakpoint: CGFloat = 820
    /// Profile : network column ratio.
    static let profileShare: CGFloat = 1.38

    /// Servers table columns: star + bell | server (flex) | CID | map · players · ping | ban | row menu.
    enum Column {
        static let marks: CGFloat = 44
        static let cid: CGFloat = 150
        static let info: CGFloat = 112
        static let ban: CGFloat = 196
        static let menu: CGFloat = 20
        static let gap: CGFloat = 12
        /// Below this table width the map · players · ping column folds into the server tooltip (720 pt windows).
        static let compactTable: CGFloat = 720
    }

    /// §48 shared pieces of the secondary windows (History, Ban Matrix, Metrics card).
    /// Tinted square behind a row's kind symbol.
    static let rowIcon: CGFloat = 24
    /// Status chip (icon + text + tint) height.
    static let chip: CGFloat = 22
    /// 1 pt card / table border.
    static let hairline: CGFloat = 1
    /// Space the system traffic lights take in the in-content toolbar stand-in (offscreen renders).
    static let trafficLights: CGFloat = 64

    /// §48.1 History window.
    enum History {
        static let minWidth: CGFloat = 600
        static let minHeight: CGFloat = 360
        static let serverColumn: CGFloat = 168
        static let timeColumn: CGFloat = 120
        /// Lines of a note before it truncates (full text in the tooltip).
        static let noteLines = 2
    }

    /// §48.2 Ban matrix window: fixed columns; the server column takes the rest (never below `serverMin`).
    enum BanMatrix {
        static let minWidth: CGFloat = 520
        static let minHeight: CGFloat = 280
        static let serverMin: CGFloat = 160
        static let cell: CGFloat = 132
        static let range: CGFloat = 156
        static let lastCheck: CGFloat = 148
    }

    /// §48.3 Metrics card charts.
    enum Chart {
        static let height: CGFloat = 112
        static let emptyHeight: CGFloat = 72
        static let line: CGFloat = 1.5
        static let gridLine: CGFloat = 0.5
        static let point: CGFloat = 14
        static let legendSwatch = CGSize(width: 12, height: 8)
        /// X axis labels every 4 hours of the 24 h window.
        static let axisHours = 4
    }
}

/// Type scale (SF Pro / SF Mono).
enum TypeScale {
    /// 22 semibold — player name.
    static let title = Font.system(size: 22, weight: .semibold)
    /// 15 semibold — sheet titles, window title.
    static let headline = Font.system(size: 15, weight: .semibold)
    /// 13 semibold — section labels, card headers, ban status text.
    static let label = Font.system(size: 13, weight: .semibold)
    /// 13 — body, buttons, values.
    static let body = Font.system(size: 13)
    /// 13 medium — row titles.
    static let rowTitle = Font.system(size: 13, weight: .medium)
    /// 12 — hints, secondary row lines, captions.
    static let callout = Font.system(size: 12)
    /// 11 — field labels, badges.
    static let caption = Font.system(size: 11)
    /// 11 semibold — column / group headers, badges.
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    /// 13 mono — IDs, CIDs, IPs, paths, map names.
    static let mono = Font.system(size: 13, design: .monospaced)
    static let monoStrong = Font.system(size: 13, weight: .semibold, design: .monospaced)
    /// 12 mono — diff view.
    static let monoSmall = Font.system(size: 12, design: .monospaced)
    /// 12 medium — chip texts.
    static let chip = Font.system(size: 12, weight: .medium)
    /// 14 — row / header SF Symbols.
    static let symbol = Font.system(size: 14)
    /// 10 semibold — symbols inside chips and badges.
    static let symbolSmall = Font.system(size: 10, weight: .semibold)
    /// 28 — empty-state symbol.
    static let symbolLarge = Font.system(size: 28)
}

/// Tone of a status chip or row icon (§48): raw colour for the symbol, AA colour for the text, tint for the fill.
enum ChipTone: Equatable, CaseIterable {
    case neutral, accent, green, orange, red

    init(_ level: StatusLevel) {
        switch level {
        case .green: self = .green
        case .orange: self = .orange
        case .red: self = .red
        }
    }

    var iconColor: Color {
        switch self {
        case .neutral: return Palette.text3
        case .accent: return Palette.accent
        case .green: return Palette.green
        case .orange: return Palette.orange
        case .red: return Palette.red
        }
    }

    var textColor: Color {
        switch self {
        case .neutral: return Palette.text2
        case .accent: return Palette.accentText
        case .green: return Palette.greenText
        case .orange: return Palette.orangeText
        case .red: return Palette.redText
        }
    }

    var tint: Color {
        switch self {
        case .neutral: return Palette.group
        case .accent: return Palette.accentTint
        case .green: return Palette.greenTint
        case .orange: return Palette.orangeTint
        case .red: return Palette.redTint
        }
    }
}

extension StatusLevel {
    /// Raw status colour (icons and fills only).
    var color: Color {
        switch self {
        case .green: return Palette.green
        case .orange: return Palette.orange
        case .red: return Palette.red
        }
    }

    /// AA text colour of the status.
    var textColor: Color {
        switch self {
        case .green: return Palette.greenText
        case .orange: return Palette.orangeText
        case .red: return Palette.redText
        }
    }

    var tint: Color {
        switch self {
        case .green: return Palette.greenTint
        case .orange: return Palette.orangeTint
        case .red: return Palette.redTint
        }
    }
}

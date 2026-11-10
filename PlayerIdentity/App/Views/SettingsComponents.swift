import AppKit
import SwiftUI

// Settings window building blocks (Claude Design handoff, N1 §6 "Settings cards"): section label 13 semibold above a
// card (4 pt inset), card padding 4/16, rows ≥ 36 pt with 8 pt vertical padding and separators, label left with a
// 12 pt secondary caption under it, control trailing; sub-options indent 20 and dim when the master switch is off.

/// Tabs of the Settings window.
enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case updates

    var title: String { L10n.text(self == .general ? .settingsTabGeneral : .settingsTabUpdates) }
    var symbol: String { self == .general ? "gearshape" : "arrow.down.circle" }
}

/// One tab page: a scroll view on the window background, 16 pt top, 24 pt side and bottom inset, 16 pt between groups.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                content
            }
            .padding(.top, Space.s4)
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.window)
        .font(TypeScale.body)
        .foregroundStyle(Palette.text)
    }
}

/// Section label + optional caption above a settings card.
struct SettingsSection<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(Palette.text)
                .padding(.leading, Space.s1)
                .accessibilityAddTraits(.isHeader)
            if let caption {
                Text(caption)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Space.s1)
                    .padding(.bottom, 2)
            }
            SettingsCard { content }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Settings card: radius 12, card fill, 1 pt border, padding 4/16.
struct SettingsCard<Content: View>: View {
    var padding = EdgeInsets(top: Space.s1, leading: Space.s4, bottom: Space.s1, trailing: Space.s4)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: 1))
    }
}

/// Row: optional symbol 16 (secondary), title 13 + caption 12 secondary, trailing control. Min height 36.
struct SettingsRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var caption: String?
    var indent: CGFloat = 0
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.s3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.text2)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, Space.s2)
        .padding(.leading, indent)
        .frame(minHeight: 36)
    }
}

/// Switch row: the whole row is labelled for accessibility; the caption is the hint.
struct SettingsSwitchRow: View {
    var symbol: String?
    let title: String
    var caption: String?
    var indent: CGFloat = 0
    @Binding var isOn: Bool
    var identifier: String?

    var body: some View {
        SettingsRow(symbol: symbol, title: title, caption: caption, indent: indent) {
            SettingsSwitch(title: title, hint: caption, isOn: $isOn, identifier: identifier)
        }
    }
}

/// Native switch (small, accent fill) with its label hidden visually but kept for VoiceOver.
struct SettingsSwitch: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool
    var identifier: String?

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(TokenSwitchStyle())
            .accessibilityHint(hint ?? "")
            .accessibilityIdentifier(identifier ?? "")
            .fixedSize()
    }
}

/// Switch drawn with the design tokens (32 × 18 track: `accent-fill` on, `switch-off` off; 16 pt knob), so it keeps
/// the brand colour in every window state. VoiceOver and Full Keyboard Access see a native toggle with its label.
struct TokenSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        TokenSwitch(configuration: configuration)
    }
}

private struct TokenSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isOn = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.accentFill : Palette.switchOff)
                Circle()
                    .fill(Palette.knob)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .frame(width: 16, height: 16)
                    .padding(1)
            }
            .frame(width: 32, height: 18)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Checkbox sub-option: indent 20, checkbox, symbol 14 (secondary), label.
struct SettingsCheckboxRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text2)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title).font(TypeScale.body).foregroundStyle(Palette.text)
            }
        }
        .toggleStyle(.checkbox)
        .tint(Palette.accentFill)
        .padding(.vertical, 7)
        .padding(.leading, 20)
        .frame(minHeight: 32, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Row with a label on the left and buttons on the right, an optional full-width caption below.
struct SettingsActionRow<Buttons: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Text(title)
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                buttons
            }
            if let caption {
                Text(caption)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Space.s2)
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
    }
}

/// Separator between rows inside a settings card.
struct SettingsDivider: View {
    var indent: CGFloat = 0

    var body: some View {
        ThemedDivider().padding(.leading, indent)
    }
}

/// Inline note in an inset box (radius 8, padding 8/12): symbol 14 + 12 pt secondary text + optional trailing control.
struct SettingsNote<Trailing: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

extension SettingsNote where Trailing == EmptyView {
    init(symbol: String, text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }
}

/// One-line result under a group (`role: status`): secondary, or red for errors; selectable.
struct SettingsMessage: View {
    let text: String
    var isError = false

    var body: some View {
        Text(text)
            .font(TypeScale.callout)
            .foregroundStyle(isError ? Palette.redText : Palette.text2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, Space.s1)
    }
}

/// Button with an SF Symbol and a title (the symbol is decorative).
struct SymbolButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12)).accessibilityHidden(true)
                Text(title)
            }
            .foregroundStyle(tint ?? Palette.text)
        }
        .fixedSize()
    }
}

/// Destructive confirmation (N1 "Destructive alert"): 272 wide, warning symbol 44, bold title, 12 pt message naming
/// what is removed and where, optional checkbox, stacked Cancel (default, Return / Esc) and the destructive button,
/// which never responds to Return.
struct DestructiveConfirmSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    var checkboxTitle: String?
    @Binding var checkbox: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Palette.orange)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let checkboxTitle {
                Toggle(checkboxTitle, isOn: $checkbox)
                    .toggleStyle(.checkbox)
                    .tint(Palette.accentFill)
                    .font(TypeScale.callout)
                    .accessibilityIdentifier("confirmCheckbox")
            }
            VStack(spacing: Space.s2) {
                Button(action: onCancel) {
                    Text(L10n.text(.actionCancel)).frame(maxWidth: .infinity)
                }
                .prominentButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirmCancel")
                Button(role: .destructive, action: onConfirm) {
                    Text(confirmTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(Palette.redText)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .accessibilityIdentifier("confirmDestructive")
            }
            .padding(.top, Space.s1)
            // Esc cancels (the visible Cancel button already owns Return).
            Button(action: onCancel) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(EdgeInsets(top: 20, leading: Space.s4, bottom: Space.s4, trailing: Space.s4))
        .frame(width: 272)
        .background(Palette.raised)
        .accessibilityElement(children: .contain)
    }
}

/// Determinate progress bar from the tokens: 6 pt capsule, `switch-off` track, `accent-fill` fill. VoiceOver sees a
/// native progress view with the label and percentage.
struct TokenProgressBar: View {
    let value: Double
    let label: String
    var valueText: String

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.switchOff)
                Capsule().fill(Palette.accentFill).frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityRepresentation {
            ProgressView(value: value) { Text(label) }
                .accessibilityValue(valueText)
        }
    }
}

/// Locale-aware formatting for the Settings texts (follows the in-app language).
enum SettingsFormat {
    static var locale: Locale { Locale(identifier: L10n.currentLanguage.rawValue) }

    /// "Today at 14:30" / "Bugün 14:30"; older dates as "3 Nov 2026 at 14:30".
    static func lastCheck(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    /// "3 Nov 2026" / "3 Kas 2026".
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return formatter.string(from: date)
    }

    /// "13.4 MB" / "13,4 MB".
    static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    /// `~/…` for paths inside `home` (the model's home folder; the user's home by default).
    static func abbreviated(_ path: String, home: URL? = nil) -> String {
        guard let home else { return (path as NSString).abbreviatingWithTildeInPath }
        let prefix = home.standardizedFileURL.path
        guard path == prefix || path.hasPrefix(prefix + "/") else { return path }
        return "~" + path.dropFirst(prefix.count)
    }
}

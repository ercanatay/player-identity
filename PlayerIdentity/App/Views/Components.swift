import AppKit
import SwiftUI

extension StatusLevel {
    var color: Color {
        switch self {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        }
    }
}

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

/// Card container.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(title).font(.headline)
        }
    }
}

/// Label + value row.
struct FieldRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }
}

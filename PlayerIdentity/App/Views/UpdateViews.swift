import AppKit
import SwiftUI

/// §25 single-line banner: version + "Download" (release page) + "Ignore".
struct UpdateBanner: View {
    let update: AppUpdate
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(L10n.format(.updateAvailable, update.version))
                .fontWeight(.medium)
            Spacer()
            Button(L10n.text(.updateDownload)) { NSWorkspace.shared.open(update.url) }
                .help(update.url.absoluteString)
            Button(L10n.text(.updateIgnore), action: onIgnore)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("updateBanner")
    }
}

/// §24 preview of the lines Apply would write: per file `-`/`+` lines with line numbers.
struct ApplyPreviewSheet: View {
    let preview: AppModel.ApplyPreview
    let onWrite: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(.diffTitle)).font(.title3.bold())
            Text(L10n.text(.diffMessage))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(preview.diffs.enumerated()), id: \.offset) { _, diff in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: diff.file.fileName).font(.headline.monospaced())
                            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.diffWrite), action: onWrite)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct DiffLineRow: View {
    let line: ConfigDiffLine

    var body: some View {
        let removed = line.kind == .removed
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: String(line.number))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(verbatim: removed ? "-" : "+")
                .foregroundStyle(removed ? Color.red : Color.green)
            Text(verbatim: line.text)
                .foregroundStyle(removed ? Color.red : Color.green)
                .textSelection(.enabled)
        }
        .font(.callout.monospaced())
        .padding(.vertical, 1)
        .background((removed ? Color.red : Color.green).opacity(0.08))
    }
}

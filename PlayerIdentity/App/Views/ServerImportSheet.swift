import SwiftUI

/// §50 sheet: paste host:port / GameTracker / steam:// entries, parse, preview, add the selected ones.
struct ServerImportSheet: View {
    let existing: [ServerEntry]
    let onAdd: ([ServerURLImport.Candidate]) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var result: ServerURLImport.Result?
    /// Input the preview was made from; a later edit makes the preview stale (Add closes until re-parsed).
    @State private var parsedText: String?
    @State private var selection: Set<String> = []

    init(existing: [ServerEntry], initialText: String = "", parseOnAppear: Bool = false,
         onAdd: @escaping ([ServerURLImport.Candidate]) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onAdd = onAdd
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
        if parseOnAppear {
            let parsed = ServerURLImport.parse(initialText, existing: existing)
            _result = State(initialValue: parsed)
            _parsedText = State(initialValue: initialText)
            _selection = State(initialValue: parsed.defaultSelection)
        }
    }

    private var chosen: [ServerURLImport.Candidate] {
        (result?.fresh ?? []).filter { selection.contains($0.id) }
    }

    private var canAdd: Bool { result != nil && parsedText == text && !chosen.isEmpty }
    private var canParse: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(L10n.text(.serverImportTitle)).font(TypeScale.headline)
            Text(L10n.text(.serverImportHint))
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(TypeScale.mono)
                .scrollContentBackground(.hidden)
                .padding(Space.s1)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.controlBorder, lineWidth: 1))
                .accessibilityLabel(L10n.text(.serverImportInput))
                .accessibilityIdentifier("importInput")

            HStack {
                Button(L10n.text(.serverImportParse), action: parse)
                    .disabled(!canParse)
                    .accessibilityIdentifier("importParse")
                Spacer()
            }

            if let result {
                preview(result)
            }

            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.format(.serverImportAddCount, String(chosen.count))) { onAdd(chosen) }
                    .prominentButton()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canAdd)
                    .accessibilityIdentifier("importAdd")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func parse() {
        let parsed = ServerURLImport.parse(text, existing: existing)
        result = parsed
        parsedText = text
        selection = parsed.defaultSelection
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ result: ServerURLImport.Result) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(L10n.text(.serverImportPreview))
                .font(TypeScale.captionStrong)
                .foregroundStyle(Palette.text2)
            if result.fresh.isEmpty && result.existing.isEmpty {
                Text(L10n.text(.serverImportNothing))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .accessibilityIdentifier("importNothing")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(result.fresh) { row($0, isExisting: false) }
                        ForEach(result.existing) { row($0, isExisting: true) }
                    }
                }
                .frame(maxHeight: 176)
                .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
                .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Palette.border, lineWidth: 1))
            }
            notes(result)
            if !result.invalid.isEmpty { invalidList(result.invalid) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importPreview")
    }

    private func row(_ candidate: ServerURLImport.Candidate, isExisting: Bool) -> some View {
        HStack(spacing: Space.s2) {
            Toggle(L10n.format(.serverImportSelect, candidate.label), isOn: Binding(
                get: { selection.contains(candidate.id) },
                set: { if $0 { selection.insert(candidate.id) } else { selection.remove(candidate.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isExisting)
            Text(verbatim: candidate.label)
                .font(TypeScale.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: candidate.host)
                .font(TypeScale.mono)
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            Text(verbatim: String(candidate.port))
                .font(TypeScale.mono)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            Group {
                if isExisting {
                    TintBadge(text: L10n.text(.serverImportExists), foreground: Palette.text2, background: Palette.inset)
                } else {
                    Color.clear
                }
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, Space.s2)
        .frame(height: Metrics.row - 12)
        .opacity(isExisting ? 0.65 : 1)
        .overlay(alignment: .bottom) { ThemedDivider() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func notes(_ result: ServerURLImport.Result) -> some View {
        if result.overflow > 0 {
            Label(L10n.format(.serverImportOverflow, String(result.overflow)), systemImage: "exclamationmark.triangle.fill")
                .font(TypeScale.callout)
                .foregroundStyle(Palette.orangeText)
        }
        if result.duplicates > 0 {
            Label(L10n.format(.serverImportDuplicates, String(result.duplicates)), systemImage: "info.circle")
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
        }
    }

    private func invalidList(_ invalid: [ServerURLImport.Invalid]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.format(.serverImportInvalidTitle, String(invalid.count)))
                .font(TypeScale.captionStrong)
                .foregroundStyle(Palette.redText)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(invalid) { item in
                        Label {
                            Text(verbatim: item.raw).font(TypeScale.mono) + Text(verbatim: " — ")
                                + Text(verbatim: item.reason.text)
                        } icon: {
                            Image(systemName: StatusLevel.red.symbolName)
                        }
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.redText)
                        .lineLimit(2)
                        .accessibilityLabel(L10n.format(.serverImportInvalidLine, String(item.index), item.reason.text))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 72)
        }
        .accessibilityIdentifier("importInvalid")
    }
}

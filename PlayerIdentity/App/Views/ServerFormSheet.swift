import SwiftUI

/// Add / edit server sheet (§8): label, host (IP or domain name), port (default 27015).
struct ServerFormSheet: View {
    let title: String
    let confirmTitle: String
    let onConfirm: (ServerDraft) -> Void
    let onCancel: () -> Void

    @State private var draft: ServerDraft
    @State private var attempted = false

    init(title: String, confirmTitle: String, draft: ServerDraft = ServerDraft(),
         onConfirm: @escaping (ServerDraft) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.bold())

            Form {
                TextField(L10n.text(.serverFormLabel), text: $draft.label)
                TextField(L10n.text(.serverFormHost), text: $draft.host)
                TextField(L10n.text(.serverFormPort), text: $draft.portText)
            }

            if attempted, !draft.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(draft.problems, id: \.self) { problem in
                        Label(problem.text, systemImage: StatusLevel.red.symbolName)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    attempted = true
                    if draft.isValid { onConfirm(draft) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

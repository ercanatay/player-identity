import SwiftUI

/// Add / edit server sheet (§8, §31): label, host (IP or domain name), port (default 27015), group, favorite.
struct ServerFormSheet: View {
    /// Group picker: none, an existing group, or a new name.
    enum GroupChoice: Hashable {
        case none
        case existing(String)
        case new
    }

    let title: String
    let confirmTitle: String
    let groups: [String]
    let onConfirm: (ServerDraft) -> Void
    let onCancel: () -> Void

    @State private var draft: ServerDraft
    @State private var groupChoice: GroupChoice
    @State private var newGroupName = ""
    @State private var attempted = false

    init(title: String, confirmTitle: String, groups: [String] = [], draft: ServerDraft = ServerDraft(),
         onConfirm: @escaping (ServerDraft) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.groups = groups
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
        let current = ServerOrganization.normalizedGroup(draft.group)
        _groupChoice = State(initialValue: current.map { groups.contains($0) ? .existing($0) : .new } ?? .none)
        _newGroupName = State(initialValue: current.map { groups.contains($0) ? "" : $0 } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(TypeScale.headline)

            Form {
                TextField(L10n.text(.serverFormLabel), text: $draft.label)
                TextField(L10n.text(.serverFormHost), text: $draft.host)
                TextField(L10n.text(.serverFormPort), text: $draft.portText)
                Picker(L10n.text(.serverFormGroup), selection: $groupChoice) {
                    Text(L10n.text(.serverFormGroupNone)).tag(GroupChoice.none)
                    ForEach(groups, id: \.self) { group in
                        Text(verbatim: group).tag(GroupChoice.existing(group))
                    }
                    Text(L10n.text(.serverFormGroupNew)).tag(GroupChoice.new)
                }
                .accessibilityIdentifier("groupPicker")
                if groupChoice == .new {
                    TextField(L10n.text(.serverFormGroupName), text: $newGroupName)
                        .accessibilityIdentifier("newGroupName")
                }
                Toggle(L10n.text(.serverFavorite), isOn: $draft.favorite)
            }

            if attempted, !draft.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(draft.problems, id: \.self) { problem in
                        Label(problem.text, systemImage: StatusLevel.red.symbolName)
                            .foregroundStyle(Palette.redText)
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
                    var result = draft
                    result.group = Self.groupName(groupChoice, newName: newGroupName)
                    if result.isValid { onConfirm(result) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// Group text stored in the draft (resolved against the existing groups by the model).
    static func groupName(_ choice: GroupChoice, newName: String) -> String {
        switch choice {
        case .none: return ""
        case .existing(let name): return name
        case .new: return newName
        }
    }
}

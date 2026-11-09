import SwiftUI

/// Editable form state of an appeal (§32).
struct AppealDraft: Equatable {
    var sentAt: Date
    var channel: AppealChannel
    /// Free-text channel of an older record (kept unless another channel is picked).
    var customChannel: String?
    var status: AppealStatus
    var hasFollowUp: Bool
    var followUpAt: Date
    var summary: String

    init(now: Date) {
        sentAt = now
        channel = .discord
        status = .sent
        hasFollowUp = false
        followUpAt = now.addingTimeInterval(7 * 24 * 60 * 60)
        summary = ""
    }

    init(_ appeal: Appeal, now: Date) {
        sentAt = appeal.sentAt
        channel = appeal.knownChannel ?? .other
        customChannel = appeal.knownChannel == nil ? appeal.channel : nil
        status = appeal.status
        hasFollowUp = appeal.followUpAt != nil
        followUpAt = appeal.followUpAt ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        summary = appeal.summary
    }

    var appeal: Appeal {
        let storedChannel = channel == .other ? (customChannel ?? channel.rawValue) : channel.rawValue
        return Appeal(sentAt: sentAt, channel: storedChannel, status: status,
                      followUpAt: hasFollowUp ? followUpAt : nil, summary: summary)
    }

    /// Status choices: any for a new appeal, otherwise the current one and its allowed next states.
    static func statusOptions(for existing: Appeal?) -> [AppealStatus] {
        guard let existing else { return AppealStatus.allCases }
        return AppealStatus.allCases.filter { existing.status.canTransition(to: $0) }
    }
}

/// §32 row details: notes (at most 2000 characters) and the appeal record.
struct ServerDetailSheet: View {
    @Bindable var model: AppModel
    let serverID: UUID
    let onClose: () -> Void

    @State private var note: String
    @State private var draft: AppealDraft?
    @State private var appealError: String?
    @State private var copied = false

    init(model: AppModel, serverID: UUID, onClose: @escaping () -> Void, editingAppeal: AppealDraft? = nil) {
        self.model = model
        self.serverID = serverID
        self.onClose = onClose
        _note = State(initialValue: model.servers.first { $0.id == serverID }?.note ?? "")
        _draft = State(initialValue: editingAppeal)
    }

    private var entry: ServerEntry? { model.servers.first { $0.id == serverID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format(.serverDetailsTitle, entry?.label ?? ""))
                .font(.title3.bold())

            notesSection
            Divider()
            appealSection

            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.actionOK)) {
                    if model.setNote(note, for: serverID) == nil { onClose() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ServerNote.isValid(note) || draft != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text(.notesTitle)).font(.headline)
                Spacer()
                Text(L10n.format(.notesCount, String(note.count)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ServerNote.isValid(note) ? Color.secondary : Color.red)
            }
            TextEditor(text: $note)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(L10n.text(.notesTitle))
                .accessibilityIdentifier("notesEditor")
            if !ServerNote.isValid(note) {
                Text(L10n.text(.notesTooLong)).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Appeal

    @ViewBuilder
    private var appealSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(.appealTitle)).font(.headline)
            if draft != nil {
                appealForm
            } else if let appeal = entry?.appeal {
                appealSummary(appeal)
            } else {
                Text(L10n.text(.appealNone)).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text(.appealAdd)) { draft = AppealDraft(now: model.now) }
                    copyAppealButton
                }
            }
            if let appealError {
                Text(appealError).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func appealSummary(_ appeal: Appeal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text(L10n.text(.appealStatus)).foregroundStyle(.secondary)
                    AppealStatusBadge(status: appeal.status)
                }
                GridRow {
                    Text(L10n.text(.appealChannel)).foregroundStyle(.secondary)
                    Text(verbatim: appeal.channelLabel)
                }
                GridRow {
                    Text(L10n.text(.appealSentAt)).foregroundStyle(.secondary)
                    Text(verbatim: AppealDates.text(appeal.sentAt))
                }
                if let followUp = appeal.followUpAt {
                    GridRow {
                        Text(L10n.text(.appealFollowUp)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(verbatim: AppealDates.text(followUp))
                            if appeal.isFollowUpDue(now: model.now) {
                                Label(L10n.format(.appealFollowUpDue, AppealDates.text(followUp)), systemImage: "bell.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            if !appeal.summary.isEmpty {
                Text(verbatim: appeal.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text(.appealEdit)) { draft = AppealDraft(appeal, now: model.now) }
                Button(L10n.text(.appealRemove), role: .destructive) {
                    appealError = model.saveAppeal(nil, for: serverID)?.text
                }
                copyAppealButton
            }
        }
    }

    /// The §17.9.1 unban message (only when the row has a ban result).
    @ViewBuilder
    private var copyAppealButton: some View {
        if let text = model.appealText(for: serverID) {
            Button(L10n.text(copied ? .actionCopied : .fixCopyAppeal)) {
                Pasteboard.copy(text)
                copied = true
            }
        }
    }

    @ViewBuilder
    private var appealForm: some View {
        if let current = draft {
            let binding = Binding(get: { draft ?? current }, set: { draft = $0 })
            let problems = current.appeal.problems
            Form {
                Picker(L10n.text(.appealChannel), selection: binding.channel) {
                    ForEach(AppealChannel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(L10n.text(.appealStatus), selection: binding.status) {
                    ForEach(AppealDraft.statusOptions(for: entry?.appeal), id: \.self) { Text($0.label).tag($0) }
                }
                DatePicker(L10n.text(.appealSentAt), selection: binding.sentAt, displayedComponents: [.date])
                Toggle(L10n.text(.appealFollowUpSet), isOn: binding.hasFollowUp)
                if current.hasFollowUp {
                    DatePicker(L10n.text(.appealFollowUp), selection: binding.followUpAt, displayedComponents: [.date])
                }
                LabeledContent(L10n.text(.appealSummary)) {
                    TextEditor(text: binding.summary)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel(L10n.text(.appealSummary))
                }
            }
            .accessibilityIdentifier("appealForm")
            ForEach(problems, id: \.self) { problem in
                Label(problem.text, systemImage: StatusLevel.red.symbolName)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button(L10n.text(.actionCancel)) {
                    draft = nil
                    appealError = nil
                }
                Button(L10n.text(.actionSave)) {
                    if let error = model.saveAppeal(current.appeal, for: serverID) {
                        appealError = error.text
                    } else {
                        draft = nil
                        appealError = nil
                    }
                }
                .disabled(!problems.isEmpty)
            }
        }
    }
}

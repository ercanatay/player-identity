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

/// Row details: notes (§32), appeal + timeline + postpone (§32, §36), ping/uptime charts (§39), ban list URL (§40),
/// per-server notifications (§56).
struct ServerDetailSheet: View {
    @Bindable var model: AppModel
    let serverID: UUID
    let onClose: () -> Void

    @State private var note: String
    @State private var draft: AppealDraft?
    @State private var appealError: String?
    @State private var copied = false
    @State private var banListText: String
    @State private var banListError: String?
    @State private var banListAppliedAll: String?
    @State private var samples: [MetricSample]
    @State private var notifications: ServerNotificationDraft
    private let fixedSamples: [MetricSample]?
    private let maxContentHeight: CGFloat

    init(model: AppModel, serverID: UUID, onClose: @escaping () -> Void, editingAppeal: AppealDraft? = nil,
         metrics: [MetricSample]? = nil, maxContentHeight: CGFloat = 620, banListDraft: String? = nil,
         notificationDraft: ServerNotificationDraft? = nil) {
        self.maxContentHeight = maxContentHeight
        self.model = model
        self.serverID = serverID
        self.onClose = onClose
        let entry = model.servers.first { $0.id == serverID }
        _note = State(initialValue: entry?.note ?? "")
        _draft = State(initialValue: editingAppeal)
        _banListText = State(initialValue: banListDraft ?? entry?.banListURL ?? "")
        _samples = State(initialValue: metrics ?? [])
        _notifications = State(initialValue: notificationDraft ?? ServerNotificationDraft(entry?.notifications))
        fixedSamples = metrics
    }

    private var entry: ServerEntry? { model.servers.first { $0.id == serverID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format(.serverDetailsTitle, entry?.label ?? ""))
                .font(TypeScale.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    watchSection
                    Divider()
                    ServerNotificationSection(draft: $notifications)
                    Divider()
                    notesSection
                    Divider()
                    appealSection
                    Divider()
                    banListSection
                    MetricsSection(samples: samples, serverID: serverID, now: model.now,
                                   writeFailure: model.metricsWriteFailure)
                }
                .padding(.trailing, 8)
            }
            .frame(maxHeight: maxContentHeight)

            HStack {
                Spacer()
                Button(L10n.text(.actionCancel), role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(.actionOK), action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ServerNote.isValid(note) || draft != nil || !notifications.isValid)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            if fixedSamples == nil { samples = await model.loadMetrics() }
        }
    }

    /// Note, ban list URL and notification settings are applied together; an invalid URL or threshold keeps the
    /// sheet open.
    private func confirm() {
        guard let settings = notifications.settings else { return }
        model.setServerNotifications(settings, for: serverID)
        if let error = model.setBanListURL(banListText, for: serverID) {
            banListError = BanListText.error(error)
            return
        }
        if model.setNote(note, for: serverID) == nil { onClose() }
    }

    // MARK: Watching (§42)

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { entry?.watch ?? false }, set: { model.setWatch($0, for: serverID) })) {
                Label(L10n.text(.watchToggleOn), systemImage: "bell.fill")
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("detailWatchToggle")
            Text(L10n.text(.watchDescription))
                .font(.caption)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            if !model.menuBarEnabled {
                Label(L10n.text(.watchBackgroundNote), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("detailWatch")
    }

    // MARK: Ban list (§40, §59 template library)

    /// Picker tag of the "Custom" choice (any template that is not exactly a preset).
    static let customPresetTag = ""

    private var presetBinding: Binding<String> {
        Binding(get: { BanListPreset.matching(banListText)?.id ?? Self.customPresetTag },
                set: { id in
                    if let preset = BanListPreset.preset(id: id) { banListText = preset.template }
                })
    }

    private var banListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(.banListTitle)).font(.headline)
            Picker(L10n.text(.banListPreset), selection: presetBinding) {
                Text(L10n.text(.banListPresetCustom)).tag(Self.customPresetTag)
                ForEach(BanListPreset.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .frame(maxWidth: 320)
            .accessibilityIdentifier("banListPreset")
            if let preset = BanListPreset.matching(banListText) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.summary).font(.callout)
                    Text(L10n.format(.banListPresetPlaceholders, preset.placeholders.map(\.token).joined(separator: ", ")))
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.text2)
                    Text(L10n.text(.banListPresetHint)).font(.caption).foregroundStyle(Palette.text2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("banListPresetInfo")
            }
            TextField(L10n.text(.banListField), text: $banListText)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .accessibilityIdentifier("banListField")
                .onChange(of: banListText) {
                    banListError = nil
                    banListAppliedAll = nil
                }
            if let problem = Self.validationText(banListText) ?? banListError {
                Text(problem).font(.callout).foregroundStyle(Palette.redText).accessibilityIdentifier("banListError")
            }
            HStack {
                Button(L10n.text(.banListSearch)) {
                    if let error = model.setBanListURL(banListText, for: serverID) ?? model.openBanList(for: serverID) {
                        banListError = BanListText.error(error)
                    }
                }
                .disabled(banListText.trimmingCharacters(in: .whitespaces).isEmpty || Self.validationText(banListText) != nil)
                .accessibilityIdentifier("banListSearch")
                Button(L10n.text(.banListApplyAll)) {
                    if let error = model.applyBanListURLToAll(banListText) {
                        banListError = BanListText.error(error)
                    } else {
                        banListAppliedAll = L10n.format(.banListAppliedAll, String(model.servers.count))
                    }
                }
                .disabled(banListText.trimmingCharacters(in: .whitespaces).isEmpty || Self.validationText(banListText) != nil
                          || model.servers.count < 2)
                .accessibilityIdentifier("banListApplyAll")
            }
            if let banListAppliedAll {
                Text(banListAppliedAll).font(.caption).foregroundStyle(Palette.text2)
                    .accessibilityIdentifier("banListAppliedAll")
            }
        }
    }

    /// Live validation while typing; empty = no template (no error).
    static func validationText(_ template: String) -> String? {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if case .failure(let error) = BanListTemplate.validate(template) { return BanListText.error(error) }
        return nil
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text(.notesTitle)).font(.headline)
                Spacer()
                Text(L10n.format(.notesCount, String(note.count)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ServerNote.isValid(note) ? Palette.text2 : Palette.redText)
            }
            TextEditor(text: $note)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.borderStrong))
                .accessibilityLabel(L10n.text(.notesTitle))
                .accessibilityIdentifier("notesEditor")
            if !ServerNote.isValid(note) {
                Text(L10n.text(.notesTooLong)).font(.caption).foregroundStyle(Palette.redText)
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
                Text(L10n.text(.appealNone)).foregroundStyle(Palette.text2)
                HStack {
                    Button(L10n.text(.appealAdd)) { draft = AppealDraft(now: model.now) }
                    copyAppealButton
                }
            }
            if let appealError {
                Text(appealError).font(.callout).foregroundStyle(Palette.redText)
            }
        }
    }

    private func appealSummary(_ appeal: Appeal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text(L10n.text(.appealStatus)).foregroundStyle(Palette.text2)
                    AppealStatusBadge(status: appeal.status)
                }
                GridRow {
                    Text(L10n.text(.appealChannel)).foregroundStyle(Palette.text2)
                    Text(verbatim: appeal.channelLabel)
                }
                GridRow {
                    Text(L10n.text(.appealSentAt)).foregroundStyle(Palette.text2)
                    Text(verbatim: AppealDates.text(appeal.sentAt))
                }
                if let followUp = appeal.followUpAt {
                    GridRow {
                        Text(L10n.text(.appealFollowUp)).foregroundStyle(Palette.text2)
                        HStack(spacing: 6) {
                            Text(verbatim: AppealDates.text(followUp))
                            if appeal.isFollowUpDue(now: model.now) {
                                Label(L10n.format(.appealFollowUpDue, AppealDates.text(followUp)), systemImage: "bell.fill")
                                    .foregroundStyle(Palette.orangeText)
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
            timeline(appeal)
            if appeal.status.isOpen {
                // §36 "Takip tarihini ertele"
                HStack(spacing: 8) {
                    Text(L10n.text(.appealPostpone)).foregroundStyle(Palette.text2)
                    Button(L10n.text(.appealPostponeOneDay)) {
                        appealError = model.postponeFollowUp(byDays: 1, for: serverID)?.text
                    }
                    .accessibilityIdentifier("postponeOneDay")
                    Button(L10n.text(.appealPostponeThreeDays)) {
                        appealError = model.postponeFollowUp(byDays: 3, for: serverID)?.text
                    }
                    .accessibilityIdentifier("postponeThreeDays")
                }
                .controlSize(.small)
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

    /// §36 timeline: Sent → Answered → … with dates.
    private func timeline(_ appeal: Appeal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(.appealTimeline)).font(.caption.bold()).foregroundStyle(Palette.text2)
            ForEach(Array(appeal.timeline.enumerated()), id: \.offset) { index, event in
                HStack(spacing: 8) {
                    Image(systemName: index == appeal.timeline.count - 1 ? "largecircle.fill.circle" : "circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(index == appeal.timeline.count - 1 ? Palette.accentText : Palette.text2)
                        .accessibilityHidden(true)
                    AppealStatusBadge(status: event.status)
                    Text(verbatim: DateFormatter.localizedString(from: event.at, dateStyle: .medium, timeStyle: .short))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.text2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("appealTimeline")
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
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.borderStrong))
                        .accessibilityLabel(L10n.text(.appealSummary))
                }
            }
            .accessibilityIdentifier("appealForm")
            ForEach(problems, id: \.self) { problem in
                Label(problem.text, systemImage: StatusLevel.red.symbolName)
                    .foregroundStyle(Palette.redText)
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

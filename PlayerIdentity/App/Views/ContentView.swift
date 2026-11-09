import AppKit
import SwiftUI

/// Single-window UI (§8).
struct ContentView: View {
    @Bindable var model: AppModel

    @State private var sheet: SheetMode?
    @State private var copiedKey: String?
    @State private var showsSuggestions = false
    @State private var showsNewName = false
    @State private var newNameText = ""
    @State private var showsManualModel = false
    @State private var manualModelText = ""

    enum SheetMode: Identifiable {
        case add
        case edit(UUID)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let id): return id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let update = model.availableUpdate {
                UpdateBanner(update: update, onIgnore: model.ignoreUpdate)
                Divider()
            }
            topBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    profileCard
                    networkCard
                    serversCard
                    reasonsSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            guard !AppModel.isRunningTests else { return }
            model.refresh()
            model.checkForUpdates()
        }
        .sheet(item: $model.applyPreview) { preview in
            ApplyPreviewSheet(preview: preview, onWrite: { model.confirmApply() }, onCancel: model.cancelApply)
        }
        .alert(L10n.text(.updateUpToDateTitle), isPresented: $model.manualCheckUpToDate) {
            Button(L10n.text(.actionOK), role: .cancel) {}
        } message: {
            Text(L10n.format(.updateUpToDateMessage, model.appVersion))
        }
        .sheet(item: $sheet) { mode in
            sheetView(mode)
        }
        .sheet(item: $model.fixSession) { session in
            FixSheet(model: model, initialSession: session)
        }
        .alert(L10n.text(.alertNewNameTitle), isPresented: $showsNewName) {
            TextField(L10n.text(.profileName), text: $newNameText)
            Button(L10n.text(.actionOK)) { model.nameDraft = newNameText }
            Button(L10n.text(.actionCancel), role: .cancel) {}
        }
        .alert(L10n.text(.alertManualModelTitle), isPresented: $showsManualModel) {
            TextField(L10n.text(.profileModel), text: $manualModelText)
            Button(L10n.text(.actionOK)) { model.modelDraft = manualModelText }
            Button(L10n.text(.actionCancel), role: .cancel) {}
        }
        .alert(L10n.text(.alertSaveFailedTitle), isPresented: Binding(
            get: { model.saveErrorMessage != nil },
            set: { if !$0 { model.saveErrorMessage = nil } }
        )) {
            Button(L10n.text(.actionOK), role: .cancel) {}
        } message: {
            Text(model.saveErrorMessage ?? "")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            if let report = model.report {
                let statusLabel = Label {
                    Text(report.overall.label).font(.title3.bold())
                } icon: {
                    Image(systemName: report.overall.symbolName)
                        .foregroundStyle(report.overall.color)
                        .font(.title2)
                }
                if report.reasons.isEmpty {
                    statusLabel
                        .accessibilityElement(children: .combine)
                } else {
                    // §14.2/2: clicking the label opens the "What to do?" popover.
                    Button {
                        showsSuggestions = true
                    } label: {
                        statusLabel
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text(.topbarWhatToDo))
                    .accessibilityLabel(report.overall.label)
                    .accessibilityHint(L10n.text(.topbarWhatToDo))
                    .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) {
                        SuggestionsPopover(reasons: report.reasons)
                    }
                }
            } else {
                Text(L10n.text(model.isRefreshing ? .topbarChecking : .topbarNotChecked))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.format(.topbarLastCheck, TimeText.format(model.lastChecked)))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            if model.hasUnsavedChanges {
                Text(L10n.text(.topbarUnsaved))
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }

            Button {
                model.refresh()
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(L10n.text(.actionRefresh))
                }
            }
            .disabled(model.isRefreshing)
            .help(L10n.text(.helpRefresh))

            Button {
                model.save()
            } label: {
                Label(L10n.text(.actionSave), systemImage: "square.and.arrow.down")
            }
            .help(L10n.text(.helpSave))
        }
    }

    // MARK: Profile card

    private var profileCard: some View {
        Card(title: L10n.text(.profileTitle)) {
            if model.isGameRunning {
                // §15.7 game-running warning banner
                Label(EditMessage.gameRunning.text, systemImage: StatusLevel.orange.symbolName)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
            }
            FieldRow(title: L10n.text(.profileName)) {
                Menu {
                    ForEach(model.nameOptions, id: \.self) { option in
                        Button(option) { model.nameDraft = option }
                    }
                    Divider()
                    Button(L10n.text(.profileNewName)) {
                        newNameText = model.nameDraft
                        showsNewName = true
                    }
                } label: {
                    Text(model.nameDraft.isEmpty ? "—" : model.nameDraft)
                }
                .fixedSize()
                .accessibilityLabel(L10n.format(.a11yProfileName, model.nameDraft))
                sourceNote(model.configSources.name)
            }
            if let error = model.nameError { fieldError(error) }
            FieldRow(title: L10n.text(.profileModel)) {
                ModelPopUpButton(
                    title: model.modelDraft,
                    options: model.modelOptions,
                    thumbnails: Dictionary(uniqueKeysWithValues: model.modelOptions.map {
                        ($0.value, ModelPreviewStyle.thumbnail(model.preview(for: $0.value)))
                    }),
                    allowsManualEntry: model.allowsManualModelEntry,
                    onSelect: { model.modelDraft = $0 },
                    onManualEntry: {
                        manualModelText = model.modelDraft
                        showsManualModel = true
                    })
                .fixedSize()
                sourceNote(model.configSources.model)
            }
            if let error = model.modelError { fieldError(error) }
            FieldRow(title: "") {
                // §16.3 selected model preview; source file path in the tooltip.
                let preview = model.preview(for: model.modelDraft)
                    ?? (model.isLoadingPreviews ? nil : ModelPreview.placeholder)
                HStack(spacing: 10) {
                    ModelPreviewView(preview: preview, modelName: model.modelDraft)
                    Text(model.modelDraft.isEmpty ? "—" : model.modelDraft)
                        .foregroundStyle(.secondary)
                }
                .help(preview?.image?.url.path ?? "")
            }
            HStack(spacing: 12) {
                Spacer().frame(width: 130)
                Button {
                    model.requestApply()
                } label: {
                    HStack(spacing: 6) {
                        if model.isApplying { ProgressView().controlSize(.small) }
                        Text(L10n.text(.actionApply))
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canApply)
                .help(L10n.text(.helpApply))
                switch model.applyStatus {
                case .success(let text)?:
                    Text(text).font(.callout).foregroundStyle(.secondary)
                case .failure(let error)?:
                    Text(error.text).font(.callout).foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
                Spacer(minLength: 0)
            }
            FieldRow(title: L10n.text(.profileRawID)) {
                Text(identityValue?.rawIDHex ?? "—")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            FieldRow(title: L10n.text(.profileIdentitySource)) {
                let path = identityValue?.source.url.path
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path ?? "")
            }
            FieldRow(title: L10n.text(.profileGamedir)) {
                if gamedirOptions.isEmpty {
                    Text(L10n.text(.profileNoGamedir)).foregroundStyle(.secondary)
                } else {
                    Picker(L10n.text(.profileGamedir), selection: Binding(
                        get: { model.selectedGamedir ?? "" },
                        set: { model.selectGamedir($0) }
                    )) {
                        ForEach(gamedirOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            FieldRow(title: L10n.text(.profileDataRoot)) {
                Text((model.dataRoot.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.dataRoot.path)
                Button(L10n.text(.profileChooseFolder), action: chooseDataRoot)
            }
        }
    }

    @ViewBuilder
    private func sourceNote(_ source: ConfigFileKind?) -> some View {
        if let source {
            Text(source.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fieldError(_ error: EditMessage) -> some View {
        Text(error.text)
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.leading, 142)
    }

    private var identityValue: Identity? {
        guard case .success(let identity)? = model.identity else { return nil }
        return identity
    }

    private var gamedirOptions: [String] {
        var options = model.gamedirs
        if let selected = model.selectedGamedir, !options.contains(selected) { options.append(selected) }
        return options
    }

    private func chooseDataRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = model.dataRoot
        panel.prompt = L10n.text(.profilePanelPrompt)
        panel.message = L10n.text(.profilePanelMessage)
        if panel.runModal() == .OK, let url = panel.url {
            model.setDataRoot(url)
        }
    }

    // MARK: Network card

    private var networkCard: some View {
        Card(title: L10n.text(.networkTitle)) {
            FieldRow(title: L10n.text(.networkPublicIP)) {
                if let ip = model.publicIP {
                    Text(ip)
                        .font(.title2.monospaced())
                        .textSelection(.enabled)
                    copyButton(text: ip, key: "publicIP")
                } else {
                    Text(model.lastChecked == nil ? "—" : L10n.text(.networkUnavailable))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            if let ip = model.publicIP, let range = IPRange.displayText(for: ip) {
                FieldRow(title: L10n.text(.networkRange)) {
                    Text(range)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("publicIPRange")
                }
            }
            FieldRow(title: L10n.text(.networkLocalIPs)) {
                if model.lanAddresses.isEmpty {
                    Text(model.lastChecked == nil ? "—" : MessageCode.lanIPMissing.text)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.lanAddresses, id: \.display) { address in
                            Text(address.display)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func copyButton(text: String, key: String) -> some View {
        Button {
            copy(text, key: key)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(L10n.text(.actionCopy))
        .accessibilityLabel(L10n.text(.actionCopy))
        if copiedKey == key {
            Text(L10n.text(.actionCopied)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String, key: String) {
        Pasteboard.copy(text)
        copiedKey = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKey == key { copiedKey = nil }
        }
    }

    // MARK: Servers

    private var serversCard: some View {
        Card(title: L10n.text(.serversTitle)) {
            if model.servers.isEmpty {
                VStack(spacing: 8) {
                    Text(L10n.text(.serversEmpty)).foregroundStyle(.secondary)
                    addServerButton
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.servers) { entry in
                        ServerRowView(entry: entry,
                                      status: model.rowStatus(entry.id),
                                      copied: copiedKey == entry.id.uuidString,
                                      onCopy: { copy($0, key: entry.id.uuidString) },
                                      onEdit: { sheet = .edit(entry.id) },
                                      onDelete: { model.deleteServer(id: entry.id) },
                                      onFix: model.fixKind(for: entry.id) == nil ? nil : { model.beginFix(entry.id) })
                        if entry.id != model.servers.last?.id { Divider() }
                    }
                }
                addServerButton
            }
        }
    }

    private var addServerButton: some View {
        Button {
            sheet = .add
        } label: {
            Label(L10n.text(.serverAdd), systemImage: "plus")
        }
    }

    @ViewBuilder
    private func sheetView(_ mode: SheetMode) -> some View {
        switch mode {
        case .add:
            ServerFormSheet(title: L10n.text(.serverAdd), confirmTitle: L10n.text(.actionAdd),
                            onConfirm: { draft in
                                model.addServer(draft)
                                sheet = nil
                            },
                            onCancel: { sheet = nil })
        case .edit(let id):
            if let entry = model.servers.first(where: { $0.id == id }) {
                ServerFormSheet(title: L10n.text(.serverEditTitle), confirmTitle: L10n.text(.actionOK), draft: ServerDraft(entry: entry),
                                onConfirm: { draft in
                                    model.updateServer(id: id, with: draft)
                                    sheet = nil
                                },
                                onCancel: { sheet = nil })
            }
        }
    }

    // MARK: Reasons

    @ViewBuilder
    private var reasonsSection: some View {
        if let reasons = model.report?.reasons, !reasons.isEmpty {
            Card(title: L10n.text(.reasonsTitle)) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    // §14.2/1: primary message + secondary "→ suggestion" (gray, small).
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(reason.message)
                        } icon: {
                            Image(systemName: reason.severity.symbolName)
                                .foregroundStyle(reason.severity.color)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(L10n.format(.a11yReason, reason.severity.label, reason.message))

                        Text(SuggestionText.secondaryLine(for: reason.code))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 28)
                    }
                }
            }
        }
    }
}

/// Server row: status icon · label · host:port · CID; last check time below (§8).
struct ServerRowView: View {
    let entry: ServerEntry
    let status: ServerRowStatus?
    let copied: Bool
    let onCopy: (String) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// §17.1: only on `ipBanned` / `cidBanned` / `unreachable` rows.
    var onFix: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let status {
                    StatusIcon(level: status.displayLevel, help: status.displayMessage?.text)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text(.serverNotChecked))
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Text(entry.label).fontWeight(.medium)
                        .help(entry.banCheck?.info?.name ?? "")
                    Text(verbatim: "\(entry.host):\(String(entry.port))")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                // §20: `host → resolved IP` (or resolving/error); §21: `map · 9/26 · 42 ms`, hidden if unknown.
                if let address = ServerRowText.addressLine(host: entry.host, status: status) {
                    Text(verbatim: address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let info = ServerRowText.infoLine(entry.banCheck?.info) {
                    Text(verbatim: info)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(entry.banCheck?.info?.name ?? "")
                        .accessibilityIdentifier("serverInfo")
                }
                HStack(spacing: 8) {
                    Text(L10n.format(.topbarLastCheck, TimeText.format(entry.lastCheckedAt)))
                    if let message = status?.message {
                        Text(message.text)
                    }
                    if let check = entry.banCheck,
                       case .rejectedUnknownType(let raw) = BanClassification.classify(check) {
                        // §17.9.2: server rejected, type unknown → the raw reply is shown.
                        Text(BanClassification.unverifiedText + ": " + raw)
                    } else if let banMessage = entry.banCheck?.status.messageCode {
                        Text(banMessage.text)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 4) {
                BanColumn(check: entry.banCheck)
                if let onFix {
                    // §17.7: "Fix" next to/below the ban icon.
                    Button(L10n.text(.actionFix), action: onFix)
                        .controlSize(.small)
                }
            }

            if let cid = status?.currentCID {
                Button {
                    onCopy(cid)
                } label: {
                    Text(copied ? L10n.text(.actionCopied) : cid)
                        .font(.body.monospaced())
                        .frame(minWidth: 290, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help(L10n.text(.serverCopyHint))
            } else {
                Text("—").foregroundStyle(.secondary)
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.text(.actionDelete))
            .accessibilityLabel(L10n.text(.actionDelete))
            .opacity(hovering ? 1 : 0)
            .disabled(!hovering)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L10n.text(.actionEdit), action: onEdit)
            Button(L10n.text(.actionDelete), role: .destructive, action: onDelete)
        }
    }
}

/// §13.3 ban column: icon + text; last check time in the tooltip.
struct BanColumn: View {
    let check: BanCheck?

    var body: some View {
        if let check {
            Label {
                Text(check.status.label)
            } icon: {
                Image(systemName: check.status.symbolName)
                    .foregroundStyle(check.status.level == .orange ? Color.secondary : check.status.level.color)
            }
            .frame(minWidth: 120, alignment: .leading)
            .help(tooltip(check))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.format(.a11yBan, check.status.label))
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)
        }
    }

    private func tooltip(_ check: BanCheck) -> String {
        let time = L10n.format(.topbarLastCheck, TimeText.format(check.checkedAt))
        return check.detail.isEmpty ? time : "\(time)\n\(check.detail)"
    }
}

/// "What to do?" popover (§14.2/2): numbered list of suggestions for the reasons + "Copy".
struct SuggestionsPopover: View {
    let reasons: [StatusReason]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(.topbarWhatToDo)).font(.headline)
            ForEach(Array(SuggestionText.numberedLines(for: reasons).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if copied {
                    Text(L10n.text(.actionCopied)).font(.caption).foregroundStyle(.secondary)
                }
                Button(L10n.text(.actionCopy)) {
                    Pasteboard.copy(SuggestionText.plainText(for: reasons))
                    copied = true
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

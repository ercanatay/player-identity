import AppKit
import SwiftUI

/// Single-window UI (§8).
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

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
        /// §32 notes and appeal.
        case details(UUID)
        /// §33 share card preview.
        case shareCard(UUID)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let id): return "edit-" + id.uuidString
            case .details(let id): return "details-" + id.uuidString
            case .shareCard(let id): return "share-" + id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let backup = model.updates.restoreOffer {
                RestoreBanner(updates: model.updates, backup: backup)
                Divider()
            }
            if let update = model.availableUpdate {
                UpdateBanner(updates: model.updates, update: update)
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
            model.updates.startPeriodicChecks()
            model.activateBackgroundTasks()
        }
        .sheet(item: Binding(
            get: { model.updates.pendingInstall?.origin == .banner ? model.updates.pendingInstall : nil },
            set: { if $0 == nil { model.updates.cancelRequest() } })
        ) { request in
            InstallConfirmSheet(updates: model.updates, request: request)
        }
        .sheet(item: $model.applyPreview) { preview in
            ApplyPreviewSheet(preview: preview, onWrite: { model.confirmApply() }, onCancel: model.cancelApply)
        }
        .sheet(item: $sheet) { mode in
            sheetView(mode)
        }
        .sheet(item: $model.fixSession) { session in
            FixSheet(model: model, initialSession: session)
        }
        // §29: the game is running → confirm before replacing it; errors of "Join Game".
        .alert(L10n.text(.gameJoinConfirmTitle), isPresented: Binding(
            get: { model.pendingJoin != nil },
            set: { if !$0 { model.cancelJoin() } }
        )) {
            Button(L10n.text(.actionCancel), role: .cancel) { model.cancelJoin() }
            Button(L10n.text(.gameJoinConfirmAction)) { model.confirmJoin() }
        } message: {
            Text(L10n.format(.gameJoinConfirmMessage, model.pendingJoin?.label ?? ""))
        }
        .alert(L10n.text(.gameErrorTitle), isPresented: Binding(
            get: { model.joinError != nil && model.joinError != .cancelled },
            set: { if !$0 { model.joinError = nil } }
        )) {
            Button(L10n.text(.actionOK), role: .cancel) {}
        } message: {
            Text(model.joinError.map(GameLaunchText.error) ?? "")
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
            if model.hasConfigOverride {
                // §43.1 userconfig.cfg override warning
                HStack(spacing: 8) {
                    Label(L10n.text(.configOverrideWarning), systemImage: StatusLevel.orange.symbolName)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text(.configOverrideRemove)) { model.showsOverrideRemoval = true }
                        .disabled(model.isApplying)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
                .confirmationDialog(L10n.text(.configOverrideConfirmTitle), isPresented: $model.showsOverrideRemoval,
                                    titleVisibility: .visible) {
                    Button(L10n.text(.configOverrideRemove), role: .destructive) { model.removeOverride() }
                    Button(L10n.text(.actionCancel), role: .cancel) {}
                } message: {
                    Text(L10n.format(.configOverrideConfirmMessage, model.overriddenKeys.joined(separator: "/")))
                }
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
            Text(L10n.text(.profileModelServerNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 142)
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
            InterfacesSection(report: model.interfaceReport, publicIP: model.publicIP)
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
                ServerSectionsView(model: model, copiedKey: copiedKey, makeActions: rowActions)
                HStack {
                    addServerButton
                    // §38 ban matrix window
                    Button {
                        openWindow(id: "banMatrix")
                    } label: {
                        Label(L10n.text(.banMatrixOpen), systemImage: "tablecells")
                    }
                    .accessibilityIdentifier("openBanMatrix")
                }
            }
        }
    }

    private func rowActions(_ entry: ServerEntry) -> ServerRowActions {
        let id = entry.id
        return ServerRowActions(
            copy: { copy($0, key: id.uuidString) },
            edit: { sheet = .edit(id) },
            delete: { model.deleteServer(id: id) },
            fix: model.fixKind(for: id) == nil ? nil : { model.beginFix(id) },
            join: model.isGameAppInstalled ? { model.joinGame(id) } : nil,
            toggleFavorite: { model.setFavorite(!entry.favorite, for: id) },
            toggleWatch: { model.setWatch(!entry.watch, for: id) },
            moveUp: model.canMoveServer(id: id, .up) ? { model.moveServer(id: id, .up) } : nil,
            moveDown: model.canMoveServer(id: id, .down) ? { model.moveServer(id: id, .down) } : nil,
            details: { sheet = .details(id) },
            shareCard: { sheet = .shareCard(id) })
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
            ServerFormSheet(title: L10n.text(.serverAdd), confirmTitle: L10n.text(.actionAdd), groups: model.serverGroups,
                            onConfirm: { draft in
                                model.addServer(draft)
                                sheet = nil
                            },
                            onCancel: { sheet = nil })
        case .edit(let id):
            if let entry = model.servers.first(where: { $0.id == id }) {
                ServerFormSheet(title: L10n.text(.serverEditTitle), confirmTitle: L10n.text(.actionOK), groups: model.serverGroups,
                                draft: ServerDraft(entry: entry),
                                onConfirm: { draft in
                                    model.updateServer(id: id, with: draft)
                                    sheet = nil
                                },
                                onCancel: { sheet = nil })
            }
        case .details(let id):
            ServerDetailSheet(model: model, serverID: id, onClose: { sheet = nil })
        case .shareCard(let id):
            ShareCardSheet(model: model, serverID: id, onClose: { sheet = nil })
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

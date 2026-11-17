import SwiftUI

// MARK: - §68.1 Server details (players + rules)

/// "Server details": players (name/score/time) and rules (first 50 matching the search, highlights first). Queried
/// only by "Refresh" — never automatically.
struct ServerDetailsSection: View {
    @Bindable var model: AppModel
    let serverID: UUID
    @State private var search: String

    init(model: AppModel, serverID: UUID, search: String = "") {
        self.model = model
        self.serverID = serverID
        _search = State(initialValue: search)
    }

    private var state: AppModel.ServerDetailsState? { model.serverDetailsState(for: serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text(.serverDetailsSectionTitle)).font(.headline)
                Spacer()
                if state?.isLoading == true {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.refreshServerDetails(for: serverID)
                } label: {
                    Label(L10n.text(.actionRefresh), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state?.isLoading == true)
                .accessibilityIdentifier("serverDetailsRefresh")
            }
            if let snapshot = state?.snapshot {
                content(ServerDetailsViewModel(snapshot: snapshot, search: search), at: snapshot.at)
            } else if state?.isLoading == true {
                Text(L10n.text(.serverDetailsLoading)).font(.caption).foregroundStyle(Palette.text2)
            } else {
                Text(L10n.text(.serverDetailsIntro))
                    .font(.caption)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serverDetails")
    }

    @ViewBuilder
    private func content(_ view: ServerDetailsViewModel, at date: Date) -> some View {
        Text(L10n.format(.serverDetailsUpdated, DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)))
            .font(.caption)
            .foregroundStyle(Palette.text2)
        if view.truncated {
            Label(L10n.text(.serverDetailsTruncated), systemImage: "scissors")
                .font(.caption)
                .foregroundStyle(Palette.orangeText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("serverDetailsTruncated")
        }
        players(view)
        rules(view)
    }

    private func players(_ view: ServerDetailsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(view.playersTitle).font(.caption.bold()).foregroundStyle(Palette.text2)
            if let message = view.playersMessage {
                Text(message).font(.caption).foregroundStyle(Palette.text2)
                    .accessibilityIdentifier("serverDetailsPlayersMessage")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text(L10n.text(.serverDetailsColumnName))
                        Text(L10n.text(.serverDetailsColumnScore)).gridColumnAlignment(.trailing)
                        Text(L10n.text(.serverDetailsColumnTime)).gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.text2)
                    ForEach(view.playerRows) { row in
                        GridRow {
                            Text(verbatim: row.name).lineLimit(1)
                            Text(verbatim: row.score).monospacedDigit()
                            Text(verbatim: row.time).monospacedDigit()
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
            }
        }
        .accessibilityIdentifier("serverDetailsPlayers")
    }

    private func rules(_ view: ServerDetailsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(view.rulesTitle).font(.caption.bold()).foregroundStyle(Palette.text2)
                if let password = view.password {
                    let locked = view.passwordProtected == true
                    Label(password, systemImage: locked ? "lock.fill" : "lock.open")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(locked ? Palette.orangeText : Palette.greenText)
                        .accessibilityIdentifier("serverDetailsPassword")
                }
                Spacer()
                TextField(L10n.text(.serverDetailsRulesSearch), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("serverDetailsRulesSearch")
            }
            if !view.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(.serverDetailsHighlights)).font(.caption.weight(.semibold)).foregroundStyle(Palette.text2)
                    ruleRows(view.highlights)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.accentTint))
                .accessibilityIdentifier("serverDetailsHighlights")
            }
            if let message = view.rulesMessage {
                Text(message).font(.caption).foregroundStyle(Palette.text2)
                    .accessibilityIdentifier("serverDetailsRulesMessage")
            }
            if !view.rules.isEmpty {
                ruleRows(view.rules)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
            }
            if let more = view.moreRules {
                Text(more).font(.caption).foregroundStyle(Palette.text2)
            }
        }
        .accessibilityIdentifier("serverDetailsRules")
    }

    private func ruleRows(_ rules: [ServerRule]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            ForEach(rules, id: \.self) { rule in
                GridRow {
                    Text(verbatim: rule.name).font(.caption.monospaced())
                    Text(verbatim: rule.value).font(.caption.monospaced()).foregroundStyle(Palette.text2)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - §68.2 Ban record card and settings

/// "Ban record" card of the diagnosis section: active count, newest ban (reason, admin, start, time left or
/// permanent), the error (never swallowed) with the ban list page as the fallback.
struct BanRecordCard: View {
    @Bindable var model: AppModel
    let serverID: UUID

    private var state: AppModel.BanRecordState? { model.banRecordState(for: serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(L10n.text(.banRecordTitle), systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button(L10n.text(.banRecordCheck)) { model.refreshBanRecord(for: serverID) }
                    .controlSize(.small)
                    .disabled(state == .loading)
                    .accessibilityIdentifier("banRecordCheck")
            }
            switch state {
            case .loading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text(.banRecordLoading)).font(.caption).foregroundStyle(Palette.text2)
                }
            case .finished(.success(let result))?:
                if let entry = result.latestActive {
                    Text(L10n.format(.banRecordActive, String(result.activeCount)))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.redText)
                        .accessibilityIdentifier("banRecordActive")
                    ForEach(BanRecordText.details(entry, now: result.fetchedAt), id: \.self) { line in
                        Text(verbatim: line).font(.caption).foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(L10n.text(.banRecordNone)).font(.caption).foregroundStyle(Palette.greenText)
                        .accessibilityIdentifier("banRecordNone")
                }
            case .finished(.failure(let error))?:
                Label(error.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("banRecordError")
                if model.servers.first(where: { $0.id == serverID })?.banListURL != nil {
                    HStack(spacing: 6) {
                        Text(L10n.text(.banRecordFallback)).font(.caption).foregroundStyle(Palette.text2)
                        Button(L10n.text(.banListSearch)) { model.openBanList(for: serverID) }
                            .controlSize(.small)
                            .accessibilityIdentifier("banRecordFallback")
                    }
                }
            case nil:
                EmptyView()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banRecordCard")
    }
}

/// Ban record settings under "Ban list": template, enabled, bearer token (written to the Keychain only).
struct BanRecordSettingsView: View {
    @Bindable var model: AppModel
    let serverID: UUID
    @State private var template: String
    @State private var enabled: Bool
    @State private var token = ""
    @State private var message: String?
    @State private var failed = false

    init(model: AppModel, serverID: UUID) {
        self.model = model
        self.serverID = serverID
        let config = model.banRecordConfig(for: serverID)
        _template = State(initialValue: config?.urlTemplate ?? "")
        _enabled = State(initialValue: config?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(.banRecordSettings)).font(.subheadline.weight(.semibold))
            Toggle(L10n.text(.banRecordEnabled), isOn: $enabled)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("banRecordEnabled")
            TextField(L10n.text(.banRecordField), text: $template)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .accessibilityIdentifier("banRecordField")
            SecureField(L10n.text(.banRecordToken), text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("banRecordToken")
            Text(L10n.text(.banRecordTokenNote)).font(.caption).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L10n.text(.actionSave)) { save(token: token.isEmpty ? nil : token) }
                    .accessibilityIdentifier("banRecordSave")
                if model.hasBanRecordToken(for: serverID) {
                    Text(L10n.text(.banRecordTokenStored)).font(.caption).foregroundStyle(Palette.text2)
                    Button(L10n.text(.banRecordTokenRemove), role: .destructive) { save(token: "") }
                        .accessibilityIdentifier("banRecordTokenRemove")
                }
            }
            .controlSize(.small)
            if let message {
                Text(message).font(.caption).foregroundStyle(failed ? Palette.redText : Palette.text2)
                    .accessibilityIdentifier("banRecordMessage")
            }
        }
    }

    private func save(token: String?) {
        if let error = model.setBanRecord(urlTemplate: template, enabled: enabled, token: token, for: serverID) {
            message = error.text
            failed = true
        } else {
            message = L10n.text(.banRecordSaved)
            failed = false
            self.token = ""
        }
    }
}

// MARK: - §68.3 VPN reality card and help

struct VPNGuidanceCard: View {
    let guidance: VPNGuidance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: guidance.symbolName)
                .foregroundStyle(guidance.kind == .identityBan ? Palette.redText : Palette.orangeText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(guidance.title).font(.callout.weight(.semibold))
                Text(guidance.text).font(.caption).foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(guidance.kind == .identityBan ? Palette.redTint : Palette.orangeTint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(guidance.title)
        .accessibilityValue(guidance.text)
        .accessibilityIdentifier("vpnGuidance")
    }
}

/// The static "VPN and bans" help, always reachable in the diagnosis section.
struct VPNHelpDisclosure: View {
    @State private var expanded: Bool

    init(expanded: Bool = false) {
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(VPNGuidance.helpText)
                .font(.caption)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        } label: {
            Label(VPNGuidance.helpTitle, systemImage: "questionmark.circle").font(.caption.weight(.medium))
        }
        .accessibilityIdentifier("vpnHelp")
    }
}

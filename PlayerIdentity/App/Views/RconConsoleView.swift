import SwiftUI

/// §72.3 "Server Console (read-only)" of the server details: switch, port, Keychain password, fixed command buttons,
/// output panel and "Copy". There is no free-text command field.
struct RconConsoleSection: View {
    /// The buttons, in order (Status / Ban list / IP list, then the other allowlisted reads).
    static let commands: [RconCommand] = [.status, .banlist, .listip, .stats, .users]

    @Bindable var model: AppModel
    let serverID: UUID
    @State private var portText: String
    @State private var password = ""
    @State private var editingPassword: Bool
    @State private var message: String?
    @State private var failed = false
    @State private var copied = false

    init(model: AppModel, serverID: UUID, editingPassword: Bool = false) {
        self.model = model
        self.serverID = serverID
        let entry = model.servers.first { $0.id == serverID }
        _portText = State(initialValue: String(entry?.rconPort ?? ServerEntry.defaultPort))
        _editingPassword = State(initialValue: editingPassword)
    }

    private var entry: ServerEntry? { model.servers.first { $0.id == serverID } }
    private var enabled: Bool { entry?.rconEnabled ?? false }
    private var hasPassword: Bool { model.hasRconPassword(for: serverID) }
    private var state: AppModel.RconConsoleState? { model.rconState(for: serverID) }
    private var isRunning: Bool {
        if case .running? = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(L10n.text(.rconTitle), systemImage: "terminal").font(.headline)
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
            }
            Text(L10n.text(.rconCaption)).font(.caption).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Label(L10n.text(.rconUnencrypted), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.orangeText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rconUnencrypted")
            settings
            if enabled { passwordRow }
            commandButtons
            output
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rconConsole")
    }

    // MARK: Settings

    private var settings: some View {
        HStack(spacing: 12) {
            Toggle(L10n.text(.rconEnabled), isOn: Binding(get: { enabled }, set: { model.setRconEnabled($0, for: serverID) }))
                .toggleStyle(.switch)
                .accessibilityIdentifier("rconEnabled")
            Spacer()
            Text(L10n.text(.rconPort)).foregroundStyle(Palette.text2)
            TextField(L10n.text(.rconPort), text: $portText)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .frame(width: 80)
                .labelsHidden()
                .disabled(!enabled)
                .accessibilityLabel(L10n.text(.rconPort))
                .accessibilityIdentifier("rconPort")
                .onSubmit(applyPort)
                .onChange(of: portText) { applyPort() }
        }
    }

    private var portValid: Bool { Int(portText).map(HostValidator.isValidPort) ?? false }

    private func applyPort() {
        if let port = Int(portText) { model.setRconPort(port, for: serverID) }
    }

    @ViewBuilder
    private var passwordRow: some View {
        if !portValid {
            Text(L10n.text(.rconPortInvalid)).font(.caption).foregroundStyle(Palette.redText)
                .accessibilityIdentifier("rconPortInvalid")
        }
        if editingPassword {
            HStack(spacing: 8) {
                SecureField(L10n.text(.rconPasswordField), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("rconPasswordField")
                    .onSubmit(savePassword)
                Button(L10n.text(.actionSave), action: savePassword)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("rconPasswordSave")
                Button(L10n.text(.actionCancel)) {
                    password = ""
                    editingPassword = false
                }
            }
            .controlSize(.small)
            Text(L10n.text(.rconPasswordNote)).font(.caption).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                Button(L10n.text(.rconPasswordSet)) { editingPassword = true }
                    .accessibilityIdentifier("rconPasswordSet")
                if hasPassword {
                    Label(L10n.text(.rconPasswordStored), systemImage: "key.fill").font(.caption)
                        .foregroundStyle(Palette.text2)
                    Button(L10n.text(.rconPasswordRemove), role: .destructive) {
                        report(model.setRconPassword(nil, for: serverID), success: nil)
                    }
                    .accessibilityIdentifier("rconPasswordRemove")
                } else {
                    Text(L10n.text(.rconPasswordMissing)).font(.caption).foregroundStyle(Palette.text2)
                        .accessibilityIdentifier("rconPasswordMissing")
                }
            }
            .controlSize(.small)
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(failed ? Palette.redText : Palette.text2)
                .accessibilityIdentifier("rconMessage")
        }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        let error = model.setRconPassword(password, for: serverID)
        password = ""
        if error == nil { editingPassword = false }
        report(error, success: L10n.text(.rconPasswordSaved))
    }

    private func report(_ error: RconError?, success: String?) {
        message = error?.text ?? success
        failed = error != nil
    }

    // MARK: Commands

    private var commandButtons: some View {
        HStack(spacing: 6) {
            ForEach(Self.commands, id: \.self) { command in
                Button(command.label) {
                    copied = false
                    model.runRcon(command, for: serverID)
                }
                .accessibilityIdentifier("rconCommand-\(command.rawValue)")
            }
        }
        .controlSize(.small)
        .disabled(!enabled || !hasPassword || !portValid || isRunning)
    }

    // MARK: Output

    @ViewBuilder
    private var output: some View {
        switch state {
        case nil:
            Text(L10n.text(enabled && !hasPassword ? .rconPasswordMissing : .rconOutputEmpty))
                .font(.caption).foregroundStyle(Palette.text2)
        case .running(let command)?:
            Text(L10n.format(.rconRunning, command.label)).font(.caption).foregroundStyle(Palette.text2)
        case .finished(let command, .failure(let error))?:
            Label(error.text, systemImage: StatusLevel.red.symbolName)
                .font(.callout)
                .foregroundStyle(Palette.redText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rconError")
            if case .rejected(let raw) = error, !raw.isEmpty { panel(command: command, text: raw, parsed: .raw(raw)) }
        case .finished(let command, .success(let result))?:
            if result.isUnknownCommand {
                Label(L10n.text(.rconErrorUnknownCommand), systemImage: StatusLevel.orange.symbolName)
                    .font(.caption).foregroundStyle(Palette.orangeText)
            }
            if result.truncated {
                Label(L10n.text(.rconOutputTruncated), systemImage: "scissors").font(.caption)
                    .foregroundStyle(Palette.orangeText)
            }
            panel(command: command, text: result.text, parsed: RconParser.parse(result))
        }
    }

    private func panel(command: RconCommand, text: String, parsed: RconParsedOutput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.format(.rconOutput, command.label)).font(.caption.bold()).foregroundStyle(Palette.text2)
                Spacer()
                Button(L10n.text(copied ? .actionCopied : .actionCopy)) {
                    Pasteboard.copy(text)
                    copied = true
                }
                .controlSize(.small)
                .accessibilityIdentifier("rconCopy")
            }
            parsedView(parsed)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.window.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).stroke(Palette.borderStrong))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(.rconA11yOutput))
        .accessibilityIdentifier("rconOutput")
    }

    @ViewBuilder
    private func parsedView(_ parsed: RconParsedOutput) -> some View {
        switch parsed {
        case .players(let players):
            Text(L10n.format(.rconPlayers, String(players.count))).font(.caption.weight(.semibold))
            if players.isEmpty {
                Text(L10n.text(.rconPlayersEmpty)).font(.caption).foregroundStyle(Palette.text2)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text(L10n.text(.serverDetailsColumnName))
                        Text(L10n.text(.serverDetailsColumnScore)).gridColumnAlignment(.trailing)
                        Text(L10n.text(.serverDetailsColumnTime)).gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.text2)
                    ForEach(Array(players.enumerated()), id: \.offset) { _, player in
                        GridRow {
                            Text(verbatim: player.name).lineLimit(1)
                            Text(verbatim: player.score).monospacedDigit()
                            Text(verbatim: player.time).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                .textSelection(.enabled)
            }
        case .ips(let ips):
            Text(L10n.format(.rconIps, String(ips.count))).font(.caption.weight(.semibold))
            if ips.isEmpty {
                Text(L10n.text(.rconIpsEmpty)).font(.caption).foregroundStyle(Palette.text2)
            } else {
                monospaced(ips.joined(separator: "\n"))
            }
        case .bans(let count, let lines):
            Text(L10n.format(.rconBans, String(count))).font(.caption.weight(.semibold))
            monospaced(lines.joined(separator: "\n"))
            if count > lines.count {
                Text(L10n.format(.rconBansMore, String(lines.count))).font(.caption).foregroundStyle(Palette.text2)
            }
        case .raw(let text):
            Text(L10n.text(.rconOutputRaw)).font(.caption).foregroundStyle(Palette.text2)
            monospaced(text)
        }
    }

    private func monospaced(_ text: String) -> some View {
        ScrollView {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
    }
}

import AppKit
import SwiftUI

/// §76.6 Settings › Connection Paths: broker binary path (text + picker), port, live state, start / stop / check.
struct ConnectionPathsSection: View {
    @Bindable var model: AppModel
    @State private var path = ""
    @State private var portText = ""

    var body: some View {
        SettingsSection(title: L10n.text(.steamSettingsSection), caption: L10n.text(.steamSettingsCaption)) {
            pathRow
            SettingsDivider()
            SettingsRow(title: L10n.text(.steamSettingsPort)) {
                TextField(L10n.text(.steamSettingsPort), text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit(commit)
                    .accessibilityIdentifier("steamBrokerPort")
            }
            SettingsDivider()
            SettingsRow(title: L10n.text(.steamSettingsStatus)) {
                Text(model.steamBrokerState.title)
                    .font(TypeScale.body)
                    .foregroundStyle(model.steamBrokerState == .listening ? Palette.greenText : Palette.text2)
                    .accessibilityIdentifier("steamBrokerState")
            }
            SettingsDivider()
            HStack(spacing: Space.s2) {
                Button(L10n.text(.steamSettingsStart)) { commit(); model.startSteamBroker() }
                    .disabled(!model.isSteamBrokerConfigured)
                Button(L10n.text(.steamSettingsStop)) { model.stopSteamBroker() }
                    .disabled(!model.canStopSteamBroker)
                Button(L10n.text(.steamSettingsValidate)) { commit(); model.validateSteamBrokerPath() }
            }
            .padding(.vertical, Space.s2)
            if let check = model.steamPathCheck {
                SettingsMessage(text: check.message, isError: check != .valid)
            }
            if let error = model.steamSettingsError {
                SettingsMessage(text: GameLaunchText.error(error), isError: true)
            }
        }
        .onAppear {
            path = model.steamEndpoint.executablePath ?? ""
            portText = String(model.steamEndpoint.port)
            model.refreshSteamBrokerState()
        }
    }

    private var pathRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(.steamSettingsPath)).font(TypeScale.body)
            Text(L10n.format(.steamSettingsArgument, "\(SteamBrokerEndpoint.defaultHost):\(SteamBrokerEndpoint.defaultPort)"))
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s2) {
                TextField(L10n.text(.steamSettingsPath), text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(TypeScale.mono)
                    .onSubmit(commit)
                    .accessibilityIdentifier("steamBrokerPath")
                Button(L10n.text(.steamSettingsBrowse)) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path
                        commit()
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, Space.s2)
    }

    private func commit() {
        model.setSteamBroker(path: path, port: Int(portText) ?? model.steamEndpoint.port)
        portText = String(model.steamEndpoint.port)
    }
}

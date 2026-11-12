import SwiftUI

/// Editable form state of the §56 "Bildirimler" section; the thresholds are text until they validate.
struct ServerNotificationDraft: Equatable {
    var mode: ServerNotificationMode
    var pingText: String
    var playersText: String
    var quietHours: QuietHoursOverride

    /// Thresholds at 0 (off) show as an empty field.
    init(_ settings: ServerNotificationSettings?) {
        let settings = settings ?? ServerNotificationSettings()
        mode = settings.mode
        pingText = settings.pingThresholdMs > 0 ? String(settings.pingThresholdMs) : ""
        playersText = settings.playersAtLeast > 0 ? String(settings.playersAtLeast) : ""
        quietHours = settings.quietHoursOverride
    }

    init(mode: ServerNotificationMode, pingText: String, playersText: String, quietHours: QuietHoursOverride) {
        self.mode = mode
        self.pingText = pingText
        self.playersText = playersText
        self.quietHours = quietHours
    }

    var pingError: ServerNotificationThresholdError? {
        if case .failure(let error) = ServerNotificationThresholds.parsePing(pingText) { return error }
        return nil
    }

    var playersError: ServerNotificationThresholdError? {
        if case .failure(let error) = ServerNotificationThresholds.parsePlayers(playersText) { return error }
        return nil
    }

    /// The settings to store; `nil` while a threshold is invalid (the sheet cannot be confirmed).
    var settings: ServerNotificationSettings? {
        guard case .success(let ping) = ServerNotificationThresholds.parsePing(pingText),
              case .success(let players) = ServerNotificationThresholds.parsePlayers(playersText) else { return nil }
        return ServerNotificationSettings(mode: mode, pingThresholdMs: ping, playersAtLeast: players,
                                          quietHoursOverride: quietHours)
    }

    var isValid: Bool { settings != nil }
}

enum ServerNotificationText {
    @MainActor
    static func error(_ error: ServerNotificationThresholdError) -> String {
        switch error {
        case .notANumber: return L10n.text(.serverNotifyNotANumber)
        case .tooLarge(let max): return L10n.format(.serverNotifyTooLarge, String(max))
        }
    }
}

/// "Bildirimler" section of the server details (§56): mode, ping threshold, minimum players, quiet-hours override.
struct ServerNotificationSection: View {
    @Binding var draft: ServerNotificationDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(.serverNotifyTitle)).font(.headline).accessibilityAddTraits(.isHeader)
            Text(L10n.text(.serverNotifyDescription))
                .font(.caption)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.text(.serverNotifyMode)).foregroundStyle(Palette.text2)
                    Picker(L10n.text(.serverNotifyMode), selection: $draft.mode) {
                        ForEach(ServerNotificationMode.allCases, id: \.self) { mode in
                            Text(AccessibilityText.notificationMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L10n.text(.serverNotifyMode))
                    .accessibilityIdentifier("notifyMode")
                }
                thresholdRow(title: L10n.text(.serverNotifyPing), hint: L10n.text(.serverNotifyPingHint),
                             text: $draft.pingText, error: draft.pingError, identifier: "notifyPing")
                thresholdRow(title: L10n.text(.serverNotifyPlayers), hint: L10n.text(.serverNotifyPlayersHint),
                             text: $draft.playersText, error: draft.playersError, identifier: "notifyPlayers")
                GridRow {
                    Text(L10n.text(.serverNotifyQuiet)).foregroundStyle(Palette.text2)
                    Picker(L10n.text(.serverNotifyQuiet), selection: $draft.quietHours) {
                        ForEach(QuietHoursOverride.allCases, id: \.self) { value in
                            Text(AccessibilityText.quietOverride(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L10n.text(.serverNotifyQuiet))
                    .accessibilityIdentifier("notifyQuiet")
                }
            }
            Label(L10n.text(.serverNotifyThresholdNote), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detailNotifications")
    }

    private func thresholdRow(title: String, hint: String, text: Binding<String>,
                              error: ServerNotificationThresholdError?, identifier: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Palette.text2)
            VStack(alignment: .leading, spacing: 4) {
                TextField(title, text: text, prompt: Text(verbatim: "0"))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .frame(width: 96)
                    .accessibilityLabel(title)
                    .accessibilityHint(hint)
                    .accessibilityIdentifier(identifier)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(ServerNotificationText.error(error), systemImage: StatusLevel.red.symbolName)
                        .font(.callout)
                        .foregroundStyle(Palette.redText)
                        .accessibilityIdentifier(identifier + "Error")
                }
            }
        }
    }
}

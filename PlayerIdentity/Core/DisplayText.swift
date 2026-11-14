import Foundation

/// §20/§21 secondary texts of a server row.
enum ServerRowText {
    /// `host → 1.2.3.4`, `host → resolving…`, `host → name not found`; `nil` for IP literals and invalid hosts.
    static func addressLine(host: String, status: ServerRowStatus?) -> String? {
        guard case .hostname? = HostValidator.classify(host) else { return nil }
        let target: String
        if let ip = status?.resolvedIP {
            target = ip
        } else {
            switch status?.resolutionFailure {
            case .pending?, nil: target = L10n.text(.serverResolving)
            case .notFound?: target = L10n.text(.serverResolveNotFound)
            case .network?: target = L10n.text(.serverResolveNetwork)
            case .invalid?: return nil
            }
        }
        return host + " → " + target
    }

    /// `map · 9/26 · 42 ms`; parts that are unknown are left out, `nil` if nothing is known.
    static func infoLine(_ info: ServerInfo?) -> String? {
        guard let info else { return nil }
        var parts: [String] = []
        if let map = info.map { parts.append(map) }
        if let players = info.players {
            parts.append(info.maxPlayers.map { "\(players)/\($0)" } ?? String(players))
        }
        if let ping = info.pingMillis { parts.append(L10n.format(.serverInfoPing, String(ping))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// §22 texts of the history window.
enum HistoryText {
    static func kind(_ kind: HistoryKind) -> String {
        switch kind {
        case .refresh: return L10n.text(.historyKindRefresh)
        case .ipChanged: return L10n.text(.historyKindIPChanged)
        case .banAppeared: return L10n.text(.historyKindBanAppeared)
        case .banLifted: return L10n.text(.historyKindBanLifted)
        case .identityChanged: return L10n.text(.historyKindIdentityChanged)
        case .nameChanged: return L10n.text(.historyKindNameChanged)
        case .modelChanged: return L10n.text(.historyKindModelChanged)
        case .apply: return L10n.text(.historyKindApply)
        case .fixAttempt: return L10n.text(.historyKindFixAttempt)
        case .appUpdateAvailable: return L10n.text(.historyKindAppUpdateAvailable)
        case .appeal: return L10n.text(.historyKindAppeal)
        case .note: return L10n.text(.historyKindNote)
        case .watchBanAppeared: return L10n.text(.historyKindWatchBanAppeared)
        case .watchBanLifted: return L10n.text(.historyKindWatchBanLifted)
        case .watchOffline: return L10n.text(.historyKindWatchOffline)
        case .watchOnline: return L10n.text(.historyKindWatchOnline)
        case .watchMapChanged: return L10n.text(.historyKindWatchMapChanged)
        case .configOverrideRemoved: return L10n.text(.historyKindConfigOverrideRemoved)
        case .diagnose: return L10n.text(.historyKindDiagnose)
        }
    }

    /// Stored values shown in the user's language: ban statuses and overall levels get their labels.
    static func value(_ raw: String?, kind: HistoryKind) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch kind {
        case .banLifted where BanStatus(rawValue: raw)?.level == .orange:
            return L10n.text(.banStatusNoBlock)   // `ipOk`: the IP block is gone (CID not checked)
        case .banAppeared, .banLifted, .watchBanAppeared, .watchBanLifted:
            return BanStatus(rawValue: raw)?.label ?? raw
        case .refresh:
            return StatusLevel.allCases.first { HistoryTransitions.levelName($0) == raw }?.label ?? raw
        case .appeal:
            return AppealStatus(rawValue: raw)?.label ?? raw
        default:
            return raw
        }
    }

    /// Note line; a fix attempt's outcome code is shown as its localized result.
    static func note(_ entry: HistoryEntry) -> String? {
        guard let note = entry.note, !note.isEmpty else { return nil }
        if entry.kind == .appeal { return AppealChannel(rawValue: note)?.label ?? note }
        if entry.kind == .watchOnline { return L10n.format(.historyWatchOnlineAfter, note) }
        guard entry.kind == .fixAttempt else { return note }
        let old = entry.old ?? "—"
        let new = entry.new ?? "—"
        switch note {
        case "resolved": return L10n.format(.fixOutcomeResolved, old, new)
        case "stillBanned": return L10n.text(.fixOutcomeStillBanned)
        case "rangeBanned": return L10n.text(.historyFixRangeBanned)
        case "ipUnchanged": return L10n.text(.fixOutcomeIPUnchanged)
        case "changedUnverified": return L10n.format(.fixOutcomeChangedUnverified, old, new)
        case "networkTimeout": return L10n.text(.fixOutcomeNetworkTimeout)
        case "cancelled": return L10n.text(.fixOutcomeCancelled)
        case "failed": return L10n.text(.historyFixFailed)
        default: return note
        }
    }

    /// `old → new`, or just the known side.
    static func change(_ entry: HistoryEntry) -> String? {
        let old = value(entry.old, kind: entry.kind)
        let new = value(entry.new, kind: entry.kind)
        switch (old, new) {
        case let (old?, new?): return old + " → " + new
        case let (nil, new?): return new
        case let (old?, nil): return old + " → —"
        case (nil, nil): return nil
        }
    }
}

/// §29 "Join the game" error texts.
enum GameLaunchText {
    static func error(_ error: GameLaunchError) -> String {
        switch error {
        case .appNotFound: return L10n.text(.gameErrorAppNotFound)
        case .invalidHost, .noAddress: return L10n.text(.gameErrorInvalidHost)
        case .invalidPort: return L10n.text(.serverProblemPortInvalid)
        case .invalidGamedir: return L10n.text(.gameErrorGamedir)
        case .resolutionFailed: return L10n.text(.gameErrorResolution)
        case .cancelled: return L10n.text(.actionCancel)
        case .launchFailed(let status): return L10n.format(.gameErrorLaunch, String(status))
        }
    }
}

/// §30 launch-at-login error texts (the system's description is shown verbatim).
enum LoginItemText {
    static func error(_ error: LoginItemError) -> String {
        switch error {
        case .registerFailed(let detail): return L10n.format(.settingsLaunchAtLoginOnFailed, detail)
        case .unregisterFailed(let detail): return L10n.format(.settingsLaunchAtLoginOffFailed, detail)
        }
    }
}

/// §40 ban list template errors.
enum BanListText {
    static func error(_ error: BanListTemplateError) -> String {
        switch error {
        case .empty: return L10n.text(.banListErrorEmpty)
        case .notHTTPS: return L10n.text(.banListErrorHTTPS)
        case .noPlaceholder: return L10n.text(.banListErrorPlaceholder)
        case .unknownPlaceholder(let name): return L10n.format(.banListErrorUnknown, name)
        case .invalidURL: return L10n.text(.banListErrorInvalid)
        case .missingValue(let placeholder): return L10n.format(.banListErrorMissing, placeholder.rawValue)
        case .tooLong: return L10n.format(.banListErrorTooLong, String(BanListTemplate.maxLength))
        case .containsWhitespace: return L10n.text(.banListErrorWhitespace)
        }
    }
}

/// §38 matrix cell and export texts.
enum BanMatrixText {
    static func cell(_ cell: BanMatrixCell) -> String {
        switch cell {
        case .banned: return L10n.text(.banMatrixCellBanned)
        case .clear: return L10n.text(.banMatrixCellClear)
        case .unknown: return L10n.text(.banMatrixCellUnknown)
        case .notApplicable: return L10n.text(.banMatrixCellNotApplicable)
        case .none: return "—"
        }
    }

    static var header: [String] {
        [L10n.text(.banMatrixServer), L10n.text(.banMatrixAddress), L10n.text(.banMatrixIPBan),
         L10n.text(.banMatrixCIDBan), L10n.text(.banMatrixRange), L10n.text(.banMatrixLastCheck)]
    }

    /// Export row: label, host:port, IP ban, CID ban, range, last check; "Ban type unverified" goes into the CID cell.
    static func row(_ row: BanMatrixRow, timeZone: TimeZone = .current) -> [String] {
        let host = row.host.contains(":") ? "[\(row.host)]" : row.host
        var cid = cell(row.cidBan)
        if row.unverified { cid = BanClassification.unverifiedText }
        return [row.label, "\(host):\(row.port)", cell(row.ipBan), cid, row.range ?? "—", lastCheck(row.lastCheck, timeZone: timeZone)]
    }

    static func lastCheck(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func table(_ rows: [BanMatrixRow]) -> [[String]] {
        BanMatrix.table(rows, header: header) { self.row($0) }
    }

    /// §66.1 the app's CSV / clipboard table: the six columns plus "Last 7 days" (`3 · CID ban` or `—`).
    static func tableWithRecent(_ rows: [BanMatrixRow], timeZone: TimeZone = .current) -> [[String]] {
        BanMatrix.table(rows, header: header + [L10n.text(.banMatrixRecent)]) {
            self.row($0, timeZone: timeZone) + [recent($0.recent)]
        }
    }

    static func recent(_ recent: BanMatrixRecent?) -> String {
        recent?.text ?? "—"
    }
}

/// §36 follow-up reminder notification.
enum AppealReminderText {
    static func content(for due: AppealReminder.Due, status: AppealStatus) -> NotificationContent {
        let date = DateFormatter.localizedString(from: due.followUpAt, dateStyle: .medium, timeStyle: .none)
        return NotificationContent(key: "appealReminder|\(due.serverID.uuidString)|\(Int(due.followUpAt.timeIntervalSince1970))",
                                   title: L10n.format(.appealReminderTitle, due.label),
                                   body: L10n.format(.appealReminderBody, date, status.label))
    }
}

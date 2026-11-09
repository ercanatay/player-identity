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
        }
    }

    /// Stored values shown in the user's language: ban statuses and overall levels get their labels.
    static func value(_ raw: String?, kind: HistoryKind) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch kind {
        case .banLifted where BanStatus(rawValue: raw)?.level == .orange:
            return L10n.text(.banStatusNoBlock)   // `ipOk`: the IP block is gone (CID not checked)
        case .banAppeared, .banLifted:
            return BanStatus(rawValue: raw)?.label ?? raw
        case .refresh:
            return StatusLevel.allCases.first { HistoryTransitions.levelName($0) == raw }?.label ?? raw
        default:
            return raw
        }
    }

    /// Note line; a fix attempt's outcome code is shown as its localized result.
    static func note(_ entry: HistoryEntry) -> String? {
        guard let note = entry.note, !note.isEmpty else { return nil }
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

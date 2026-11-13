import Foundation

// MARK: - §65.1 Diagnosis trend (derived from the `diagnose` history lines; nothing extra is stored)

/// Period of the trend; 7 days by default. Days are fixed 24-hour spans counted back from "now".
enum DiagnosisTrendWindow: String, CaseIterable, Sendable, Identifiable {
    case week
    case month
    case all

    static let `default`: DiagnosisTrendWindow = .week

    var id: String { rawValue }

    /// Length in seconds; `nil` = every line still in the history.
    var duration: TimeInterval? {
        switch self {
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .all: return nil
        }
    }

    var title: String {
        switch self {
        case .week: return L10n.text(.diagnoseTrendWindowWeek)
        case .month: return L10n.text(.diagnoseTrendWindowMonth)
        case .all: return L10n.text(.diagnoseTrendWindowAll)
        }
    }

    /// The window's start is inclusive (exactly 7 × 24 h ago still counts); a line from the future (clock moved back)
    /// counts too, so no run disappears from the summary.
    func includes(_ date: Date, now: Date) -> Bool {
        guard let duration else { return true }
        return date >= now.addingTimeInterval(-duration)
    }
}

extension DiagnosisVerdict {
    /// Short label for the trend counts and the menu bar result line (`CID ban · 1,2 sn`).
    var shortLabel: String {
        switch self {
        case .serverOffline: return L10n.text(.diagnoseShortServerOffline)
        case .dnsFailure: return L10n.text(.diagnoseShortDnsFailure)
        case .timeout: return L10n.text(.diagnoseShortTimeout)
        case .protocolMismatch: return L10n.text(.diagnoseShortProtocolMismatch)
        case .ipBanned: return L10n.text(.diagnoseShortIpBanned)
        case .cidBanned: return L10n.text(.diagnoseShortCidBanned)
        case .rangeBanned: return L10n.text(.diagnoseShortRangeBanned)
        case .cidUnverified: return L10n.text(.diagnoseShortCidUnverified)
        case .vpnConflict: return L10n.text(.diagnoseShortVpnConflict)
        case .checksDisabled: return L10n.text(.diagnoseShortChecksDisabled)
        case .noBan: return L10n.text(.diagnoseShortNoBan)
        }
    }
}

/// Summary of one server's diagnoses in a window. The colour of a run is its verdict's `level`: green = no ban,
/// red = a ban, orange = unclear / error.
struct DiagnosisTrend: Sendable, Equatable {
    struct VerdictCount: Sendable, Equatable {
        let verdict: DiagnosisVerdict
        let count: Int
    }

    static let stripLength = 10

    /// Runs in the window.
    let runs: Int
    let lastRun: Date?
    /// Verdicts with at least one run, most frequent first (ties in `DiagnosisVerdict.allCases` order).
    let counts: [VerdictCount]
    /// The last (at most) 10 runs of the window, oldest first: the newest run is the right end of the strip.
    let strip: [DiagnosisVerdict]
    /// Runs of this server in the whole history (tells "no diagnosis yet" from "none in this period").
    let totalRuns: Int

    var isEmpty: Bool { runs == 0 }

    /// Builds the trend from history lines (any order). Only `diagnose` lines of `serverID` with a known verdict count.
    static func make(entries: [HistoryEntry], serverID: UUID, window: DiagnosisTrendWindow, now: Date) -> DiagnosisTrend {
        let runs = entries.enumerated()
            .compactMap { offset, entry -> (offset: Int, ts: Date, verdict: DiagnosisVerdict)? in
                guard entry.kind == .diagnose, entry.serverID == serverID,
                      let verdict = entry.new.flatMap(DiagnosisVerdict.init(rawValue:)) else { return nil }
                return (offset, entry.ts, verdict)
            }
            // Chronological; lines with the same time keep their file order.
            .sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.offset < $1.offset }
        let inWindow = runs.filter { window.includes($0.ts, now: now) }
        var tally: [DiagnosisVerdict: Int] = [:]
        for run in inWindow { tally[run.verdict, default: 0] += 1 }
        let counts = DiagnosisVerdict.allCases.compactMap { verdict in
            tally[verdict].map { VerdictCount(verdict: verdict, count: $0) }
        }
        .enumerated()
        .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
        .map(\.element)
        return DiagnosisTrend(runs: inWindow.count, lastRun: inWindow.last?.ts, counts: counts,
                              strip: inWindow.suffix(stripLength).map(\.verdict), totalRuns: runs.count)
    }

    /// Empty-state text: none at all, or none in the chosen period.
    var emptyText: String {
        L10n.text(totalRuns == 0 ? .diagnoseTrendEmpty : .diagnoseTrendEmptyWindow)
    }

    /// VoiceOver value of the strip: the short verdicts, oldest first.
    var stripAccessibilityValue: String {
        strip.map(\.shortLabel).joined(separator: ", ")
    }
}

// MARK: - §65.2 Menu bar diagnosis

/// A server's diagnosis started from the menu bar: running, or its one-line result.
enum MenuBarDiagnosisState: Sendable, Equatable {
    case running
    case finished(DiagnosisVerdict, durationMs: Int)
}

enum MenuBarDiagnosisText {
    /// Seconds with one decimal in the app language (`1,2` in Turkish, `1.2` in English).
    static func seconds(_ durationMs: Int, language: AppLanguage = L10n.currentLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language.rawValue)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let value = Double(max(0, durationMs)) / 1000
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// `teşhis sürüyor…` or `CID ban · 1,2 sn`.
    static func line(_ state: MenuBarDiagnosisState, language: AppLanguage = L10n.currentLanguage) -> String {
        switch state {
        case .running:
            return L10n.text(.menuBarDiagnoseRunning)
        case .finished(let verdict, let durationMs):
            return L10n.format(.menuBarDiagnoseResult, verdict.shortLabel, seconds(durationMs, language: language))
        }
    }

    /// The single notification of a menu bar diagnosis; only for the ban verdicts. It is a ban notification
    /// (`notifyBanChanges`, quiet hours and the server's §56 override apply); the key carries the run time, so each
    /// run notifies at most once.
    static func notification(verdict: DiagnosisVerdict, server: ServerEntry, at date: Date) -> NotificationContent? {
        guard verdict.isBan else { return nil }
        let key = ["diagnose", server.id.uuidString, verdict.rawValue, String(Int(date.timeIntervalSince1970))]
            .joined(separator: "|")
        let label = server.label.isEmpty ? "\(server.host):\(server.port)" : server.label
        return NotificationContent(key: key, title: L10n.text(.notifyDiagnoseBanTitle),
                                   body: L10n.format(.notifyServerBody, label, verdict.sentence),
                                   category: .ban, server: server.notifications)
    }
}

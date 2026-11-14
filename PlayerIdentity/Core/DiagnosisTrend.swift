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
        let runs = DiagnosisRun.all(entries: entries, serverID: serverID)
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

/// One diagnosis run read from a `diagnose` history line (§65 trend, §66 matrix column and report history).
struct DiagnosisRun: Sendable, Equatable {
    let ts: Date
    let verdict: DiagnosisVerdict
    /// §66.3 total duration; `nil` in lines written before v4.2.
    let durationMs: Int?

    /// Every run of `serverID` with a known verdict, chronological (lines with the same time keep their file order).
    static func all(entries: [HistoryEntry], serverID: UUID) -> [DiagnosisRun] {
        entries.enumerated()
            .compactMap { offset, entry -> (offset: Int, run: DiagnosisRun)? in
                guard entry.kind == .diagnose, entry.serverID == serverID,
                      let verdict = entry.new.flatMap(DiagnosisVerdict.init(rawValue:)) else { return nil }
                return (offset, DiagnosisRun(ts: entry.ts, verdict: verdict, durationMs: entry.durationMs))
            }
            .sorted { $0.run.ts != $1.run.ts ? $0.run.ts < $1.run.ts : $0.offset < $1.offset }
            .map(\.run)
    }
}

// MARK: - §66.1 Ban matrix "Last 7 days" column

/// A server's diagnoses of the last 7 days for the ban matrix: run count and the dominant verdict (most frequent;
/// ties in `DiagnosisVerdict.allCases` order). Derived from the §65 trend; nothing extra is stored.
struct BanMatrixRecent: Sendable, Equatable {
    static let window = DiagnosisTrendWindow.week

    let runs: Int
    let dominant: DiagnosisVerdict?
    /// Runs with a ban verdict (secondary sort key of the matrix).
    let banRuns: Int

    static let empty = BanMatrixRecent(runs: 0, dominant: nil, banRuns: 0)

    init(runs: Int, dominant: DiagnosisVerdict?, banRuns: Int) {
        self.runs = runs
        self.dominant = dominant
        self.banRuns = banRuns
    }

    init(trend: DiagnosisTrend) {
        self.init(runs: trend.runs, dominant: trend.counts.first?.verdict,
                  banRuns: trend.counts.filter(\.verdict.isBan).map(\.count).reduce(0, +))
    }

    /// Per server, from the history lines (servers without a run in the window get `.empty`).
    static func make(entries: [HistoryEntry], serverIDs: [UUID], now: Date) -> [UUID: BanMatrixRecent] {
        let diagnoses = entries.filter { $0.kind == .diagnose }
        var result: [UUID: BanMatrixRecent] = [:]
        for id in serverIDs {
            result[id] = BanMatrixRecent(trend: DiagnosisTrend.make(entries: diagnoses, serverID: id, window: window, now: now))
        }
        return result
    }

    /// `3 · CID ban`, or `—` without runs.
    var text: String {
        guard runs > 0, let dominant else { return "—" }
        return L10n.format(.banMatrixRecentValue, String(runs), dominant.shortLabel)
    }
}

// MARK: - §66.3 History table of the report

/// The last (at most) 10 runs of the chosen window for the shareable report, newest first. Times, verdicts and
/// durations only: no personal data.
struct DiagnosisReportHistory: Sendable, Equatable {
    static let limit = 10

    let window: DiagnosisTrendWindow
    let runs: [DiagnosisRun]

    static func make(entries: [HistoryEntry], serverID: UUID, window: DiagnosisTrendWindow, now: Date) -> DiagnosisReportHistory {
        let runs = DiagnosisRun.all(entries: entries, serverID: serverID).filter { window.includes($0.ts, now: now) }
        return DiagnosisReportHistory(window: window, runs: Array(runs.suffix(limit).reversed()))
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
    /// run notifies at most once. Tapping it opens the server details.
    /// §66.2 a range ban says "Range ban detected — change your network" and, with an unban message, carries the
    /// "Copy Unban Message" action (the action copies; a plain tap does not).
    static func notification(verdict: DiagnosisVerdict, server: ServerEntry, at date: Date,
                             appeal: String? = nil) -> NotificationContent? {
        guard verdict.isBan else { return nil }
        let key = ["diagnose", server.id.uuidString, verdict.rawValue, String(Int(date.timeIntervalSince1970))]
            .joined(separator: "|")
        let label = server.label.isEmpty ? "\(server.host):\(server.port)" : server.label
        let range = verdict == .rangeBanned
        return NotificationContent(key: key, title: L10n.text(range ? .notifyRangeBanTitle : .notifyDiagnoseBanTitle),
                                   body: L10n.format(.notifyServerBody, label, verdict.sentence),
                                   category: .ban, server: server.notifications, serverID: server.id,
                                   copyText: range ? appeal.flatMap { $0.isEmpty ? nil : $0 } : nil)
    }
}

import Foundation

// §67.1 `playeridentityctl diagnose | trend | report`: the §64 connection diagnosis, the §65 trend and the §64.5
// Markdown report from the command line. They use the app's Core; only `diagnose` uses the network. `diagnose` adds
// one `diagnose` line to `history.jsonl` (like the app); `report` writes the report file (or stdout). The texts are
// English (the app's `en` texts for verdicts and the report); JSON has `schemaVersion: 1`.
//
// Exit codes: 0 ok (also for a ban verdict), 4 a ban verdict with `diagnose --fail-on-ban`, 1 usage, 2 network /
// validation / write error, 3 server not found (no such index, no saved record for an index, no diagnosis to report).

extension CLIExit {
    /// §67.1 `diagnose --fail-on-ban`: the verdict is `ipBanned`, `cidBanned` or `rangeBanned`.
    static let banVerdict: Int32 = 4
}

extension CLIContext {
    /// `history.jsonl` next to the record (follows `PLAYERIDENTITYCTL_SNAPSHOT`).
    var historyURL: URL {
        snapshotURL.deletingLastPathComponent().appendingPathComponent("history.jsonl", isDirectory: false)
    }

    /// The app's English texts: the main bundle's `en.lproj` (tests, the app), else the app this tool is in.
    var englishBundle: Bundle? {
        if let bundle = L10n.languageBundle("en") { return bundle }
        guard let app = executableURL.flatMap(CLIAppBundle.enclosing(executable:)), let bundle = Bundle(url: app) else {
            return nil
        }
        return L10n.languageBundle("en", in: bundle)
    }
}

/// `--days 7|30|all`.
enum CLIDays {
    static func parse(_ text: String) -> DiagnosisTrendWindow? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "7": return .week
        case "30": return .month
        case "all": return .all
        default: return nil
        }
    }

    static func text(_ window: DiagnosisTrendWindow) -> String {
        switch window {
        case .week: return "7"
        case .month: return "30"
        case .all: return "all"
        }
    }

    static func description(_ window: DiagnosisTrendWindow) -> String {
        switch window {
        case .week: return "last 7 days"
        case .month: return "last 30 days"
        case .all: return "all history"
        }
    }
}

/// The server a §67.1 command refers to: a saved server (by index or `host:port`) or any `host:port`. Servers that
/// are not in the record use a stable id derived from `host:port`, so their diagnoses, trend and report match.
struct CLIServerTarget: Sendable, Equatable {
    let host: String
    let port: Int
    let serverID: UUID
    let label: String
    /// 1-based index in the record; `nil` when the server is not saved.
    let index: Int?
    /// Saved CID of the record entry (may be empty).
    let savedCID: String

    var address: String { ServerAddressText.hostPort(host: host, port: port) }
    var name: String { label.isEmpty ? address : "\(label) (\(address))" }

    static func isIndex(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
    }

    init(host: String, port: Int, serverID: UUID, label: String, index: Int?, savedCID: String) {
        self.host = host
        self.port = port
        self.serverID = serverID
        self.label = label
        self.index = index
        self.savedCID = savedCID
    }

    init(entry: ServerEntry, index: Int) {
        self.init(host: HostValidator.normalized(entry.host), port: entry.port, serverID: entry.id, label: entry.label,
                  index: index, savedCID: entry.cid)
    }
}

extension CLIRunner {
    // MARK: Target

    /// Index → the record's server (exit 3 without a record or such an index); `host:port` → the saved server with
    /// that address, else an unsaved target.
    static func serverTarget(_ text: String, command: String, json: Bool,
                             context: CLIContext) -> Result<(CLIServerTarget, Snapshot?), CLIResultFailure> {
        let load = SnapshotStore(fileURL: context.snapshotURL).load()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if CLIServerTarget.isIndex(trimmed) {
            let snapshot: Snapshot
            switch load {
            case .loaded(let value): snapshot = value
            case .missing:
                return .failure(CLIResultFailure(failure("snapshotMissing", "no saved record at \(context.snapshotURL.path); "
                                                         + "use <host:port> or open Cybokron Player Identity and save first",
                                                         command: command, json: json, code: CLIExit.notFound)))
            case .corrupt, .unsupportedSchema:
                return .failure(CLIResultFailure(failure("snapshotCorrupt", "the saved record cannot be read: \(context.snapshotURL.path)",
                                                         command: command, json: json, code: CLIExit.validation)))
            }
            guard let number = Int(trimmed), number >= 1, number <= snapshot.servers.count else {
                return .failure(CLIResultFailure(failure("serverNotFound", "no server with index \(trimmed) (the list has "
                                                         + "\(snapshot.servers.count))", command: command, json: json,
                                                         code: CLIExit.notFound)))
            }
            return .success((CLIServerTarget(entry: snapshot.servers[number - 1], index: number), snapshot))
        }
        guard let parsed = CLIHostPort.parse(trimmed) else {
            return .failure(CLIResultFailure(failure("invalidServer", "\(text) is neither an index nor a <host:port>",
                                                     command: command, json: json, code: CLIExit.usage)))
        }
        let snapshot = load.snapshot
        if let snapshot, let offset = snapshot.servers.firstIndex(where: {
            HostValidator.normalized($0.host) == parsed.host && $0.port == parsed.port
        }) {
            return .success((CLIServerTarget(entry: snapshot.servers[offset], index: offset + 1), snapshot))
        }
        let target = CLIServerTarget(host: parsed.host, port: parsed.port,
                                     serverID: MetricSample.stableServerID(host: parsed.host, port: parsed.port),
                                     label: "", index: nil, savedCID: "")
        return .success((target, snapshot))
    }

    private static func serverJSON(_ target: CLIServerTarget) -> [String: Any] {
        ["host": target.host, "port": target.port, "label": target.label.isEmpty ? NSNull() : target.label,
         "index": target.index ?? NSNull(), "id": target.serverID.uuidString]
    }

    /// Data root and game folder of the saved record (the default data root without one).
    private static func gameFolder(_ snapshot: Snapshot?, context: CLIContext) -> (root: URL, gamedir: String?) {
        let root = snapshot.flatMap { $0.dataRoot.isEmpty ? nil : URL(fileURLWithPath: $0.dataRoot, isDirectory: true) }
            ?? context.paths.defaultDataRoot
        return (root, snapshot.flatMap { $0.gamedir.isEmpty ? nil : $0.gamedir })
    }

    /// Runs `body` with the app's English texts (verdict sentences, report headings).
    private static func english<T>(_ context: CLIContext, _ body: () async -> T) async -> T {
        guard let bundle = context.englishBundle else { return await body() }
        return await L10n.$bundle.withValue(bundle) { await body() }
    }

    // MARK: diagnose

    static func diagnose(target text: String, timeout: TimeInterval, json: Bool, failOnBan: Bool,
                         context: CLIContext) async -> CLIResult {
        let target: CLIServerTarget
        let snapshot: Snapshot?
        switch serverTarget(text, command: "diagnose", json: json, context: context) {
        case .success(let value): (target, snapshot) = value
        case .failure(let failure): return failure.result
        }
        let historyStore = HistoryStore(fileURL: context.historyURL)
        let knownRange = BanMatrix.rangeBans(from: historyStore.load())[target.serverID]
        let name = snapshot.map(\.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? "player"
        let request = ConnectionDiagnosisRequest(host: target.host, port: target.port, rawID: localRawID(context: context),
                                                 name: name, checksEnabled: true, vpnActive: context.vpnActive(),
                                                 knownRange: knownRange)
        let diagnoser = ConnectionDiagnoser(transport: context.udpTransport, resolver: context.resolver, now: context.now,
                                            stepTimeout: timeout,
                                            totalTimeout: timeout * Double(DiagnosisStepKind.allCases.count))
        let started = context.now()
        let probe: ConnectionProbeResult
        do {
            probe = try await diagnoser.run(request)
        } catch {
            return failure("cancelled", "diagnosis cancelled", command: "diagnose", json: json, code: CLIExit.network)
        }
        let folder = gameFolder(snapshot, context: context)
        let log = EngineLogReader.read(dataRoot: folder.root, gamedir: folder.gamedir, fileSystem: context.fileSystem,
                                       redactor: Redactor(home: context.paths.home))
        let durationMs = max(0, Int((context.now().timeIntervalSince(started) * 1000).rounded()))
        let publicIP = snapshot.flatMap { $0.network.publicIP.isEmpty ? nil : $0.network.publicIP }
        let diagnosis = ConnectionDiagnosis(serverID: target.serverID, label: target.label, host: target.host,
                                            port: target.port, startedAt: started, probe: probe, engineLog: log,
                                            publicIP: publicIP, durationMs: durationMs)
        // §64.1: the result is written to the history only (the record is not changed).
        var stderr = ""
        do {
            try historyStore.append([diagnosis.historyEntry])
        } catch {
            stderr = "playeridentityctl: warning: the history line could not be written (\(error.localizedDescription))\n"
        }
        let verdict = diagnosis.verdict
        let exitCode = diagnosis.networkUnavailable ? CLIExit.network
            : failOnBan && verdict.isBan ? CLIExit.banVerdict : CLIExit.ok
        return await english(context) {
            if json {
                return CLIResult(exitCode: exitCode, stdout: CLIJSON.string(diagnoseJSON(diagnosis, target: target)),
                                 stderr: stderr)
            }
            return CLIResult(exitCode: exitCode, stdout: diagnoseText(diagnosis, target: target), stderr: stderr)
        }
    }

    static func diagnoseJSON(_ diagnosis: ConnectionDiagnosis, target: CLIServerTarget) -> [String: Any] {
        let log = diagnosis.engineLog
        return [
            "schemaVersion": CLIContext.jsonSchemaVersion, "command": "diagnose", "server": serverJSON(target),
            "verdict": diagnosis.verdict.rawValue, "probeVerdict": diagnosis.probeVerdict.rawValue,
            "verdictFromLog": diagnosis.verdictFromLog, "banned": diagnosis.verdict.isBan,
            "sentence": diagnosis.verdict.sentence, "advice": diagnosis.verdict.advice,
            "address": diagnosis.probe.address ?? NSNull(), "cid": diagnosis.probe.cid ?? NSNull(),
            "startedAt": iso(diagnosis.startedAt), "durationMs": diagnosis.durationMs ?? NSNull(),
            "networkUnavailable": diagnosis.networkUnavailable,
            "steps": diagnosis.steps.map { step in
                ["step": step.step.rawValue, "status": step.status.rawValue, "durationMs": step.durationMs,
                 "target": step.target, "detail": step.detail] as [String: Any]
            },
            "engineLog": [
                "status": log.status.rawValue, "fileName": log.fileName ?? NSNull(), "scannedLines": log.scannedLines,
                "matches": log.matches.map { match in
                    ["pattern": match.pattern.rawValue, "text": match.pattern.needle, "matchedAt": match.matchedAt,
                     "line": match.line] as [String: Any]
                },
            ] as [String: Any],
        ]
    }

    static func diagnoseText(_ diagnosis: ConnectionDiagnosis, target: CLIServerTarget) -> String {
        let verdict = diagnosis.verdict
        var lines = [
            "server:   \(target.name)",
            "verdict:  \(verdict.rawValue) (\(verdict.shortLabel)) - \(verdict.sentence)",
            "advice:   \(verdict.advice)",
        ]
        if diagnosis.verdictFromLog {
            lines.append("          (decided by the engine log; the probe found \(diagnosis.probeVerdict.rawValue))")
        }
        lines.append("steps:")
        let width = DiagnosisStepKind.allCases.map(\.rawValue.count).max() ?? 0
        for step in diagnosis.steps {
            let name = step.step.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            let status = step.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
            let milliseconds = step.status == .skipped ? "-" : "\(step.durationMs) ms"
            let duration = String(repeating: " ", count: max(0, 8 - milliseconds.count)) + milliseconds
            let detail = step.detail.isEmpty ? "" : "  \(step.detail)"
            lines.append("  \(name)  \(status) \(duration)  \(step.target)\(detail)")
        }
        let log = diagnosis.engineLog
        switch log.status {
        case .missing:
            lines.append("engine log: none (start Xash3D with -condebug to write qconsole.log)")
        case .unreadable:
            lines.append("engine log: \(log.fileName ?? "-") cannot be read")
        case .found:
            lines.append("engine log: \(log.fileName ?? "-"), \(log.scannedLines) lines scanned, \(log.matches.count) match(es)")
            for match in log.matches {
                lines.append("  line \(match.matchedAt)  \(match.pattern.needle): \(match.line)")
            }
        }
        if let ms = diagnosis.durationMs { lines.append("duration: \(ms) ms") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: trend

    static func trend(target text: String, window: DiagnosisTrendWindow, json: Bool, context: CLIContext) async -> CLIResult {
        let target: CLIServerTarget
        switch serverTarget(text, command: "trend", json: json, context: context) {
        case .success(let value): target = value.0
        case .failure(let failure): return failure.result
        }
        let entries = HistoryStore(fileURL: context.historyURL).load()
        let trend = DiagnosisTrend.make(entries: entries, serverID: target.serverID, window: window, now: context.now())
        return await english(context) {
            if json {
                var counts: [String: Any] = [:]
                for item in trend.counts { counts[item.verdict.rawValue] = item.count }
                return success(json: [
                    "schemaVersion": CLIContext.jsonSchemaVersion, "command": "trend", "server": serverJSON(target),
                    "days": CLIDays.text(window), "runs": trend.runs, "totalRuns": trend.totalRuns,
                    "lastRun": trend.lastRun.map(iso) ?? NSNull(), "counts": counts,
                    "strip": trend.strip.map(\.rawValue),
                ])
            }
            var lines = ["server:   \(target.name)", "period:   \(CLIDays.description(window))"]
            guard !trend.isEmpty else {
                lines.append(trend.totalRuns == 0 ? "no diagnosis for this server yet"
                                                  : "no diagnosis in this period (\(trend.totalRuns) in the whole history)")
                return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
            }
            lines.append("runs:     \(trend.runs)" + (trend.lastRun.map { " (last \(iso($0)))" } ?? ""))
            lines.append("verdicts: " + trend.counts.map { "\($0.verdict.rawValue) \($0.count)" }.joined(separator: ", "))
            lines.append("last \(trend.strip.count) (oldest first): " + trend.strip.map(\.rawValue).joined(separator: " "))
            return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
        }
    }

    // MARK: report

    static func report(target text: String, window: DiagnosisTrendWindow, unmasked: Bool, out: String?,
                       context: CLIContext) async -> CLIResult {
        let target: CLIServerTarget
        let snapshot: Snapshot?
        switch serverTarget(text, command: "report", json: false, context: context) {
        case .success(let value): (target, snapshot) = value
        case .failure(let failure): return failure.result
        }
        let entries = HistoryStore(fileURL: context.historyURL).load()
        let last = entries.enumerated()
            .filter { $0.element.kind == .diagnose && $0.element.serverID == target.serverID
                && $0.element.new.flatMap(DiagnosisVerdict.init(rawValue:)) != nil }
            .max { $0.element.ts != $1.element.ts ? $0.element.ts < $1.element.ts : $0.offset < $1.offset }?.element
        guard let last else {
            return failure("noDiagnosis", "no diagnosis of \(target.name) in the history; run "
                           + "`playeridentityctl diagnose \(text)` first", command: "report", json: false,
                           code: CLIExit.notFound)
        }
        let folder = gameFolder(snapshot, context: context)
        let log = EngineLogReader.read(dataRoot: folder.root, gamedir: folder.gamedir, fileSystem: context.fileSystem,
                                       redactor: Redactor(home: context.paths.home))
        var cid: String? = target.savedCID.isEmpty ? nil : target.savedCID
        if cid == nil, case .address(let address)? = HostValidator.classify(target.host), let rawID = localRawID(context: context) {
            cid = CIDCalculator.cid(rawID: rawID, address: address)
        }
        let publicIP = snapshot.flatMap { $0.network.publicIP.isEmpty ? nil : $0.network.publicIP }
        guard let diagnosis = ConnectionDiagnosis(recorded: last, target: target, engineLog: log, cid: cid,
                                                  publicIP: publicIP) else {
            return failure("noDiagnosis", "no readable diagnosis of \(target.name)", command: "report", json: false,
                           code: CLIExit.notFound)
        }
        let history = DiagnosisReportHistory.make(entries: entries, serverID: target.serverID, window: window,
                                                  now: context.now())
        let markdown = await english(context) {
            DiagnosisReport.markdown(diagnosis, appVersion: context.version, masked: !unmasked, history: history)
        }
        if out == "-" { return CLIResult(exitCode: CLIExit.ok, stdout: markdown, stderr: "") }
        let url: URL
        switch outputURL(out, defaultName: DiagnosisReport.fileName(host: target.host, date: last.ts), context: context) {
        case .success(let value): url = value
        case .failure(let failure): return failure.result(command: "report", json: false)
        }
        do {
            try Data(markdown.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            return failure("writeFailed", "the report could not be written to \(url.path) (\(error.localizedDescription))",
                           command: "report", json: false, code: CLIExit.validation)
        }
        return CLIResult(exitCode: CLIExit.ok,
                         stdout: "report: \(url.path)\n(\(unmasked ? "unmasked: full CID and IP" : "masked: CID and IP shortened"))\n",
                         stderr: "")
    }
}

extension ConnectionDiagnosis {
    /// §67.1 a diagnosis rebuilt from its `diagnose` history line: verdict (and the probe verdict the engine log
    /// overrode), `step=status` pairs (durations unknown), start time and total duration. The engine log is the one
    /// read now; it never changes the recorded verdict.
    init?(recorded entry: HistoryEntry, target: CLIServerTarget, engineLog: EngineLogReport, cid: String?,
          publicIP: String?) {
        guard entry.kind == .diagnose, let verdict = entry.new.flatMap(DiagnosisVerdict.init(rawValue:)) else { return nil }
        let probeVerdict = entry.old.flatMap(DiagnosisVerdict.init(rawValue:)) ?? verdict
        let stepTarget = entry.host ?? target.address
        let steps: [DiagnosisStep] = (entry.note ?? "").split(separator: " ").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = DiagnosisStepKind(rawValue: parts[0]),
                  let status = DiagnosisStepStatus(rawValue: parts[1]) else { return nil }
            return DiagnosisStep(step: kind, status: status, durationMs: DiagnosisStep.unknownDuration,
                                 target: kind == .dns ? target.host : stepTarget, detail: "")
        }
        let probe = ConnectionProbeResult(steps: steps, facts: DiagnosisFacts(), verdict: probeVerdict, cid: cid)
        self.init(serverID: target.serverID, label: target.label, host: target.host, port: target.port,
                  startedAt: entry.ts, probe: probe, engineLog: engineLog, publicIP: publicIP,
                  durationMs: entry.durationMs, recordedVerdict: verdict)
    }
}

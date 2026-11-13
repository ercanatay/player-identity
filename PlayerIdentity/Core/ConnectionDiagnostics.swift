import Foundation

// MARK: - §64 Connection diagnosis: model

/// The probe steps in the order they run (§64.1).
enum DiagnosisStepKind: String, Codable, Sendable, CaseIterable {
    case dns
    case a2sInfo
    case getChallenge
    case connect49

    var title: String {
        switch self {
        case .dns: return L10n.text(.diagnoseStepDns)
        case .a2sInfo: return L10n.text(.diagnoseStepA2sInfo)
        case .getChallenge: return L10n.text(.diagnoseStepGetChallenge)
        case .connect49: return L10n.text(.diagnoseStepConnect49)
        }
    }
}

enum DiagnosisStepStatus: String, Codable, Sendable {
    case ok
    case failed
    case skipped

    var label: String {
        switch self {
        case .ok: return L10n.text(.diagnoseStatusOk)
        case .failed: return L10n.text(.diagnoseStatusFailed)
        case .skipped: return L10n.text(.diagnoseStatusSkipped)
        }
    }
}

/// One recorded step: `step`, `status`, `durationMs`, `target`, `detail` (§64.1). `detail` is technical evidence
/// (server text, error kind), not translated.
struct DiagnosisStep: Codable, Sendable, Equatable {
    var step: DiagnosisStepKind
    var status: DiagnosisStepStatus
    var durationMs: Int
    var target: String
    var detail: String
}

/// The single verdict (§64.2): the ten table values plus `noBan` ("ban yok", only when steps 2–4 are all `ok`).
enum DiagnosisVerdict: String, Codable, Sendable, CaseIterable {
    case serverOffline
    case dnsFailure
    case timeout
    case protocolMismatch
    case ipBanned
    case cidBanned
    case rangeBanned
    case cidUnverified
    case vpnConflict
    case checksDisabled
    case noBan

    /// One sentence for the verdict card.
    var sentence: String {
        switch self {
        case .serverOffline: return L10n.text(.diagnoseVerdictServerOffline)
        case .dnsFailure: return L10n.text(.diagnoseVerdictDnsFailure)
        case .timeout: return L10n.text(.diagnoseVerdictTimeout)
        case .protocolMismatch: return L10n.text(.diagnoseVerdictProtocolMismatch)
        case .ipBanned: return L10n.text(.diagnoseVerdictIpBanned)
        case .cidBanned: return L10n.text(.diagnoseVerdictCidBanned)
        case .rangeBanned: return L10n.text(.diagnoseVerdictRangeBanned)
        case .cidUnverified: return L10n.text(.diagnoseVerdictCidUnverified)
        case .vpnConflict: return L10n.text(.diagnoseVerdictVpnConflict)
        case .checksDisabled: return L10n.text(.diagnoseVerdictChecksDisabled)
        case .noBan: return L10n.text(.diagnoseVerdictNoBan)
        }
    }

    /// Suggested action (§64.2 "öneri").
    var advice: String {
        switch self {
        case .serverOffline: return L10n.text(.diagnoseAdviceServerOffline)
        case .dnsFailure: return L10n.text(.diagnoseAdviceDnsFailure)
        case .timeout: return L10n.text(.diagnoseAdviceTimeout)
        case .protocolMismatch: return L10n.text(.diagnoseAdviceProtocolMismatch)
        case .ipBanned: return L10n.text(.diagnoseAdviceIpBanned)
        case .cidBanned: return L10n.text(.diagnoseAdviceCidBanned)
        case .rangeBanned: return L10n.text(.diagnoseAdviceRangeBanned)
        case .cidUnverified: return L10n.text(.diagnoseAdviceCidUnverified)
        case .vpnConflict: return L10n.text(.diagnoseAdviceVpnConflict)
        case .checksDisabled: return L10n.text(.diagnoseAdviceChecksDisabled)
        case .noBan: return L10n.text(.diagnoseAdviceNoBan)
        }
    }

    /// Card colour: bans red, a clean result green, everything else orange.
    var level: StatusLevel {
        switch self {
        case .ipBanned, .cidBanned, .rangeBanned: return .red
        case .noBan: return .green
        default: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .ipBanned, .cidBanned, .rangeBanned: return "xmark.octagon.fill"
        case .noBan: return "checkmark.seal.fill"
        case .dnsFailure: return "questionmark.circle.fill"
        case .serverOffline: return "powerplug"
        case .timeout: return "hourglass"
        case .protocolMismatch: return "arrow.left.arrow.right.circle"
        case .cidUnverified: return "questionmark.diamond"
        case .vpnConflict: return "lock.shield"
        case .checksDisabled: return "pause.circle"
        }
    }

    /// The verdicts a ban message (§17.9.1) makes sense for.
    var isBan: Bool { self == .ipBanned || self == .cidBanned || self == .rangeBanned }
}

// MARK: - Classification (§64.2)

/// What the probe observed; the classifier turns it into exactly one verdict.
struct DiagnosisFacts: Sendable, Equatable {
    enum DNS: Sendable, Equatable { case resolved, failed }
    enum Info: Sendable, Equatable { case replied, noReply, socketError }
    enum Challenge: Sendable, Equatable { case challenge, banned, unrecognized, noReply }
    enum Connect: Sendable, Equatable { case ok, banned, notApplicable, unrecognized, noReply, noCID }

    var checksEnabled = true
    var dns: DNS?
    var info: Info?
    var challenge: Challenge?
    var connect: Connect?
    /// The 20 s budget ran out before every step could run.
    var totalTimedOut = false
    /// §37: the default route goes through a tunnel interface.
    var vpnActive = false
    /// §17.10 suspected range ban of this server (from the history / the last fix), e.g. `198.51.0.0/16`.
    var knownRange: String?
}

enum DiagnosisClassifier {
    /// The probe verdict. "No ban" only when A2S_INFO, getchallenge and connect 49 all succeeded.
    static func verdict(_ facts: DiagnosisFacts) -> DiagnosisVerdict {
        guard facts.dns == .resolved else { return .dnsFailure }
        guard facts.checksEnabled else { return .checksDisabled }
        if facts.info == .socketError { return .timeout }
        switch facts.challenge {
        case .banned?:
            return facts.knownRange == nil ? .ipBanned : .rangeBanned
        case .challenge?:
            switch facts.connect {
            case .ok?:
                return facts.info == .replied ? .noBan : .cidUnverified
            case .banned?: return .cidBanned
            case .notApplicable?: return .protocolMismatch
            case .unrecognized?, .noReply?: return facts.vpnActive ? .vpnConflict : .cidUnverified
            case .noCID?: return .cidUnverified
            case nil: return .timeout
            }
        case .unrecognized?:
            return .cidUnverified
        case .noReply?, nil:
            if facts.info == .noReply { return facts.totalTimedOut ? .timeout : .serverOffline }
            if facts.info == .replied, facts.vpnActive { return .vpnConflict }
            return .timeout
        }
    }

    /// §64.3: a direct engine statement (`Your IP is banned` / `You have been banned`) decides the verdict, unless the
    /// probe already found a ban or proved there is none (all of steps 2–4 `ok`).
    static func final(probe: DiagnosisVerdict, log: EngineLogReport) -> DiagnosisVerdict {
        guard !probe.isBan, probe != .noBan, let direct = log.directVerdict else { return probe }
        return direct
    }
}

// MARK: - Probe (§64.1)

struct ConnectionDiagnosisRequest: Sendable, Equatable {
    let host: String
    let port: Int
    /// Raw identity for the CID (the CID depends on the resolved address); `nil` = no CID query.
    let rawID: UInt64?
    let name: String
    let checksEnabled: Bool
    let vpnActive: Bool
    let knownRange: String?
}

struct ConnectionProbeResult: Sendable, Equatable {
    var steps: [DiagnosisStep]
    var facts: DiagnosisFacts
    var verdict: DiagnosisVerdict
    var address: String?
    var cid: String?
    var info: ServerInfo?
}

/// Live progress for the UI: a step started, then finished.
enum DiagnosisProgress: Sendable, Equatable {
    case started(DiagnosisStepKind)
    case finished(DiagnosisStep)
}

/// Runs the four probe steps with the existing UDP transport, packets and reply classifiers (§13) and the
/// existing resolver (§20). 5 s per step, 20 s in total; cancellable (throws `CancellationError`).
struct ConnectionDiagnoser: Sendable {
    static let stepTimeout: TimeInterval = 5
    static let totalTimeout: TimeInterval = 20

    let transport: any UDPTransport
    let resolver: any ServerAddressResolver
    let now: @Sendable () -> Date
    let qport: @Sendable () -> UInt16
    let step: TimeInterval
    let total: TimeInterval

    init(transport: any UDPTransport, resolver: any ServerAddressResolver, now: @escaping @Sendable () -> Date,
         qport: @escaping @Sendable () -> UInt16 = { UInt16.random(in: 1...UInt16.max) },
         stepTimeout: TimeInterval = ConnectionDiagnoser.stepTimeout,
         totalTimeout: TimeInterval = ConnectionDiagnoser.totalTimeout) {
        self.transport = transport
        self.resolver = resolver
        self.now = now
        self.qport = qport
        self.step = stepTimeout
        self.total = totalTimeout
    }

    func run(_ request: ConnectionDiagnosisRequest,
             progress: @escaping @Sendable (DiagnosisProgress) async -> Void = { _ in }) async throws -> ConnectionProbeResult {
        let start = now()
        let overallDeadline = start.addingTimeInterval(total)
        let target = "\(request.host):\(request.port)"
        var facts = DiagnosisFacts(checksEnabled: request.checksEnabled, vpnActive: request.vpnActive,
                                   knownRange: request.knownRange)
        var steps: [DiagnosisStep] = []
        var result = ConnectionProbeResult(steps: [], facts: facts, verdict: .timeout)

        func millis(since date: Date) -> Int { max(0, Int((now().timeIntervalSince(date) * 1000).rounded())) }
        func record(_ kind: DiagnosisStepKind, _ status: DiagnosisStepStatus, since date: Date?, target: String,
                    _ detail: String) async {
            let step = DiagnosisStep(step: kind, status: status, durationMs: date.map(millis) ?? 0, target: target,
                                     detail: detail)
            steps.append(step)
            await progress(.finished(step))
        }
        func skipRest(from kind: DiagnosisStepKind, target: String, _ detail: String) async {
            for later in DiagnosisStepKind.allCases where later.order >= kind.order && !steps.contains(where: { $0.step == later }) {
                await record(later, .skipped, since: nil, target: target, detail)
            }
        }
        func finish() -> ConnectionProbeResult {
            result.steps = steps
            result.facts = facts
            result.verdict = DiagnosisClassifier.verdict(facts)
            return result
        }

        // 1. DNS
        try Task.checkCancellation()
        await progress(.started(.dns))
        let dnsStart = now()
        let address: ServerAddress
        switch await resolve(request.host) {
        case .success(let resolved):
            address = resolved
            facts.dns = .resolved
            result.address = resolved.text
            var family = "IPv4"
            if case .ipv6 = resolved { family = "IPv6" }
            await record(.dns, .ok, since: dnsStart, target: request.host, "\(family) \(resolved.text ?? "")")
        case .failure(let failure):
            try Task.checkCancellation()
            facts.dns = .failed
            await record(.dns, .failed, since: dnsStart, target: request.host, failure.reason)
            await skipRest(from: .a2sInfo, target: target, "dnsFailed")
            return finish()
        }
        let endpointTarget = "\(address.text ?? request.host):\(request.port)"
        guard request.checksEnabled else {
            await skipRest(from: .a2sInfo, target: endpointTarget, "banCheckOff")
            return finish()
        }
        guard HostValidator.isValidPort(request.port) else {
            facts.info = .socketError
            await skipRest(from: .a2sInfo, target: endpointTarget, "invalidPort")
            return finish()
        }

        let endpoint = UDPEndpoint(address: address, port: UInt16(request.port))
        let checker = BanChecker(transport: transport, now: now, qport: qport, stepTimeout: step)

        // 2. A2S_INFO
        try Task.checkCancellation()
        await progress(.started(.a2sInfo))
        let infoStart = now()
        let session: any UDPSession
        do {
            session = try transport.makeSession(to: endpoint)
        } catch {
            facts.info = .socketError
            await record(.a2sInfo, .failed, since: infoStart, target: endpointTarget, "socket: \(error)")
            await skipRest(from: .getChallenge, target: endpointTarget, "noSocket")
            return finish()
        }
        defer { session.close() }
        let infoDeadline = min(infoStart.addingTimeInterval(step), overallDeadline)
        var infoSentAt = now()
        if var reply = try await checker.exchange(session, BanPackets.info(), until: infoDeadline, ignoreInfo: false) {
            var receivedAt = now()
            if case .challenge(let challenge) = BanReplies.classifyInfo(reply) {
                infoSentAt = now()
                if let second = try await checker.exchange(session, BanPackets.info(challenge: challenge),
                                                           until: infoDeadline, ignoreInfo: false) {
                    reply = second
                    receivedAt = now()
                }
            }
            var info = ServerInfoParser.parse(reply)
            info?.pingMillis = max(0, Int((receivedAt.timeIntervalSince(infoSentAt) * 1000).rounded()))
            result.info = info
            if info != nil {
                facts.info = .replied
                await record(.a2sInfo, .ok, since: infoStart, target: endpointTarget, Self.infoDetail(info))
            } else {
                facts.info = .noReply
                await record(.a2sInfo, .failed, since: infoStart, target: endpointTarget,
                             "unrecognized: " + BanReplies.printable(BanReplies.text(reply)))
            }
        } else {
            facts.info = .noReply
            await record(.a2sInfo, .failed, since: infoStart, target: endpointTarget, "noReply")
        }

        // 3. getchallenge (runs even without an A2S reply: some servers only answer the handshake)
        try Task.checkCancellation()
        guard now() < overallDeadline else {
            facts.totalTimedOut = true
            await skipRest(from: .getChallenge, target: endpointTarget, "totalTimeout")
            return finish()
        }
        await progress(.started(.getChallenge))
        let challengeStart = now()
        let challengeDeadline = min(challengeStart.addingTimeInterval(step), overallDeadline)
        guard let challengeReply = try await checker.exchange(session, BanPackets.getChallenge(),
                                                              until: challengeDeadline, ignoreInfo: true) else {
            facts.challenge = .noReply
            await record(.getChallenge, .failed, since: challengeStart, target: endpointTarget, "noReply")
            await skipRest(from: .connect49, target: endpointTarget, "noChallenge")
            return finish()
        }
        let challenge: UInt32
        switch BanReplies.classifyGetChallenge(challengeReply) {
        case .banned(let text):
            facts.challenge = .banned
            await record(.getChallenge, .failed, since: challengeStart, target: endpointTarget,
                         "banned: " + BanReplies.printable(text))
            await skipRest(from: .connect49, target: endpointTarget, "ipBanned")
            return finish()
        case .unrecognized(let text):
            facts.challenge = .unrecognized
            await record(.getChallenge, .failed, since: challengeStart, target: endpointTarget,
                         "unrecognized: " + BanReplies.printable(text))
            await skipRest(from: .connect49, target: endpointTarget, "noChallenge")
            return finish()
        case .challenge(let value):
            challenge = value
            facts.challenge = .challenge
            await record(.getChallenge, .ok, since: challengeStart, target: endpointTarget, "challenge")
        }

        // 4. connect 49
        try Task.checkCancellation()
        guard let rawID = request.rawID else {
            facts.connect = .noCID
            await record(.connect49, .skipped, since: nil, target: endpointTarget, "noCID")
            return finish()
        }
        guard now() < overallDeadline else {
            facts.totalTimedOut = true
            await skipRest(from: .connect49, target: endpointTarget, "totalTimeout")
            return finish()
        }
        await progress(.started(.connect49))
        let cid = CIDCalculator.cid(rawID: rawID, address: address)
        result.cid = cid
        let connectStart = now()
        let connectDeadline = min(connectStart.addingTimeInterval(step), overallDeadline)
        let packet = BanPackets.connect(challenge: challenge, cid: cid, qport: qport(), name: request.name)
        guard let connectReply = try await checker.exchange(session, packet, until: connectDeadline, ignoreInfo: true) else {
            facts.connect = .noReply
            await record(.connect49, .failed, since: connectStart, target: endpointTarget, "noReply")
            return finish()
        }
        switch BanReplies.classifyConnect(connectReply) {
        case .ok:
            facts.connect = .ok
            await record(.connect49, .ok, since: connectStart, target: endpointTarget, "accepted")
        case .banned(let text):
            facts.connect = .banned
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         "banned: " + BanReplies.printable(text))
        case .notApplicable(let text):
            facts.connect = .notApplicable
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         "protocol: " + BanReplies.printable(text))
        case .unrecognized(let text):
            facts.connect = .unrecognized
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         "unrecognized: " + BanReplies.printable(text))
        }
        return finish()
    }

    /// IP literal, or the preferred resolved address (IPv4 first, §20). Failure = technical reason.
    private func resolve(_ host: String) async -> Result<ServerAddress, DNSFailure> {
        switch HostValidator.classify(host) {
        case .address(let address)?:
            return address == .localMachine ? .failure(DNSFailure(reason: "localMachine")) : .success(address)
        case nil:
            return .failure(DNSFailure(reason: "invalidHost"))
        case .hostname(let name)?:
            do {
                let addresses = try await resolver.addresses(for: name)
                guard let picked = AddressPreference.pick(addresses) else { return .failure(DNSFailure(reason: "notFound")) }
                return .success(picked)
            } catch let error as ResolutionError {
                switch error {
                case .invalidHostname: return .failure(DNSFailure(reason: "invalidHost"))
                case .notFound: return .failure(DNSFailure(reason: "notFound"))
                case .network: return .failure(DNSFailure(reason: "network"))
                }
            } catch {
                return .failure(DNSFailure(reason: "network"))
            }
        }
    }

    static func infoDetail(_ info: ServerInfo?) -> String {
        guard let info else { return "" }
        var parts: [String] = []
        if let name = info.name { parts.append(name) }
        if let map = info.map { parts.append(map) }
        if let players = info.players { parts.append(info.maxPlayers.map { "\(players)/\($0)" } ?? "\(players)") }
        if let ping = info.pingMillis { parts.append("\(ping) ms") }
        return parts.joined(separator: " · ")
    }
}

/// Technical DNS failure reason (step `detail`).
struct DNSFailure: Error, Sendable, Equatable {
    let reason: String
}

private extension DiagnosisStepKind {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

// MARK: - Result (probe + engine log)

struct ConnectionDiagnosis: Sendable, Equatable {
    var serverID: UUID?
    var label: String
    var host: String
    var port: Int
    var startedAt: Date
    var probe: ConnectionProbeResult
    var engineLog: EngineLogReport
    /// The player's public IP at the time (shown masked by default in the report).
    var publicIP: String?

    var steps: [DiagnosisStep] { probe.steps }
    var probeVerdict: DiagnosisVerdict { probe.verdict }
    /// The single verdict shown (§64.2, §64.3).
    var verdict: DiagnosisVerdict { DiagnosisClassifier.final(probe: probe.verdict, log: engineLog) }
    /// The verdict came from the engine log, not from the probe.
    var verdictFromLog: Bool { verdict != probe.verdict }

    /// History line (§64.1): `new` = verdict, `old` = probe verdict when the engine log overrode it, `note` = steps.
    var historyEntry: HistoryEntry {
        let summary = steps.map { "\($0.step.rawValue)=\($0.status.rawValue)" }.joined(separator: " ")
        return HistoryEntry(ts: startedAt, kind: .diagnose, serverID: serverID, host: "\(host):\(port)",
                            old: verdictFromLog ? probe.verdict.rawValue : nil, new: verdict.rawValue, note: summary)
    }
}

// MARK: - §64.5 Shareable report

enum DiagnosisReport {
    /// CID: first 8 … last 4 characters.
    static func maskCID(_ cid: String) -> String {
        guard cid.count > 12 else { return cid }
        return String(cid.prefix(8)) + "…" + String(cid.suffix(4))
    }

    /// IP: its `/24` (IPv6 `/64`) range; unparsable text is kept.
    static func maskIP(_ ip: String) -> String {
        IPRange.ranges(for: ip)?.narrow ?? ip
    }

    /// Markdown report; `masked` (default) hides the full CID and the player's public IP everywhere in it.
    static func markdown(_ diagnosis: ConnectionDiagnosis, appVersion: String, masked: Bool = true,
                         timeZone: TimeZone = .current) -> String {
        let cid = diagnosis.probe.cid
        let ip = diagnosis.publicIP
        func clean(_ text: String) -> String {
            guard masked else { return text }
            var result = text
            if let cid, !cid.isEmpty { result = result.replacingOccurrences(of: cid, with: maskCID(cid)) }
            if let ip, !ip.isEmpty { result = result.replacingOccurrences(of: ip, with: maskIP(ip)) }
            return result
        }
        func cell(_ text: String) -> String {
            clean(text).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        let server = "\(diagnosis.host):\(diagnosis.port)"
        var lines: [String] = []
        lines.append("# " + L10n.format(.diagnoseReportTitle, server))
        lines.append("")
        lines.append("- \(L10n.text(.diagnoseReportApp)): \(L10n.text(.appWindowTitle)) \(appVersion)")
        lines.append("- \(L10n.text(.diagnoseReportDate)): \(timestamp(diagnosis.startedAt, timeZone: timeZone))")
        lines.append("- \(L10n.text(.diagnoseReportServer)): \(diagnosis.label.isEmpty ? server : "\(cell(diagnosis.label)) (\(server))")")
        if let cid {
            lines.append("- \(L10n.text(.serversColumnCID)): `\(masked ? maskCID(cid) : cid)`")
        }
        if let ip {
            lines.append("- \(L10n.text(.networkPublicIP)): `\(masked ? maskIP(ip) : ip)`")
        }
        lines.append("- " + L10n.text(masked ? .diagnoseReportMasked : .diagnoseReportUnmaskedNote))
        lines.append("")
        lines.append("## \(L10n.text(.diagnoseVerdict)): `\(diagnosis.verdict.rawValue)`")
        lines.append("")
        lines.append(diagnosis.verdict.sentence)
        lines.append("")
        lines.append(diagnosis.verdict.advice)
        if diagnosis.verdictFromLog {
            lines.append("")
            lines.append(L10n.format(.diagnoseLogOverride, diagnosis.probeVerdict.rawValue))
        }
        lines.append("")
        lines.append("## " + L10n.text(.diagnoseSteps))
        lines.append("")
        lines.append("| \(L10n.text(.diagnoseColumnStep)) | \(L10n.text(.diagnoseColumnStatus)) | \(L10n.text(.diagnoseColumnDuration)) | \(L10n.text(.diagnoseColumnTarget)) | \(L10n.text(.diagnoseColumnDetail)) |")
        lines.append("|---|---|---|---|---|")
        for step in diagnosis.steps {
            lines.append("| `\(step.step.rawValue)` | \(step.status.rawValue) | \(step.durationMs) ms | \(cell(step.target)) | \(cell(step.detail)) |")
        }
        lines.append("")
        lines.append("## " + L10n.text(.diagnoseLogTitle))
        lines.append("")
        lines.append(contentsOf: logLines(diagnosis.engineLog).map { clean($0) })
        return lines.joined(separator: "\n") + "\n"
    }

    static func logLines(_ log: EngineLogReport) -> [String] {
        switch log.status {
        case .missing: return [L10n.text(.diagnoseLogMissing)]
        case .unreadable: return [L10n.format(.diagnoseLogUnreadable, log.fileName ?? "")]
        case .found where log.matches.isEmpty: return [L10n.format(.diagnoseLogNoMatch, log.fileName ?? "")]
        case .found:
            return log.matches.map { match in
                "- `\(match.pattern.needle)` (\(L10n.format(.diagnoseLogLine, String(match.matchedAt)))): "
                    + "\(match.pattern.explanation)\n  `\(match.line.replacingOccurrences(of: "`", with: "'"))`"
            }
        }
    }

    /// `playeridentity-diagnose-<host>-<yyyyMMdd-HHmmss>.md`; the host keeps only `[A-Za-z0-9.-]`.
    static func fileName(host: String, date: Date, timeZone: TimeZone = .current) -> String {
        let safeHost = String(host.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "playeridentity-diagnose-\(safeHost.isEmpty ? "server" : safeHost)-\(formatter.string(from: date)).md"
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

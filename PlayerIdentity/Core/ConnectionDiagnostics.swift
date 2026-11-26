import Foundation

// MARK: - §64 Connection diagnosis: model

/// The probe steps in the order they run (§64.1).
enum DiagnosisStepKind: String, Codable, Sendable, CaseIterable {
    case dns
    case a2sInfo
    case getChallenge
    case connect49
    /// §75.6 GoldSrc 48 legacy connect probe: replaces `connect49` on a `goldsrc48` server (never both).
    case connect48
    /// §68.1 A2S_RULES (password, cvars): only in the details' diagnosis and only after a challenge was received;
    /// never part of the fixed probe sequence (`probeSteps`).
    case rules

    /// The four probe steps every diagnosis records (§64.1).
    static let probeSteps: [DiagnosisStepKind] = [.dns, .a2sInfo, .getChallenge, .connect49]
    /// §75.5 the GoldSrc 48 path: the legacy probe takes the place of connect 49.
    static let goldSrcProbeSteps: [DiagnosisStepKind] = [.dns, .a2sInfo, .getChallenge, .connect48]

    /// The probe steps of a server with this protocol (`unknown` follows the `source49` default, §75.4).
    static func probeSteps(for serverProtocol: ServerProtocol) -> [DiagnosisStepKind] {
        serverProtocol == .goldsrc48 ? goldSrcProbeSteps : probeSteps
    }

    var title: String {
        switch self {
        case .dns: return L10n.text(.diagnoseStepDns)
        case .a2sInfo: return L10n.text(.diagnoseStepA2sInfo)
        case .getChallenge: return L10n.text(.diagnoseStepGetChallenge)
        case .connect49: return L10n.text(.diagnoseStepConnect49)
        case .connect48: return L10n.text(.diagnosisGoldsrcStep)
        case .rules: return L10n.text(.diagnoseStepRules)
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
    /// §67.1 duration of a step rebuilt from a history line (the line keeps only `step=status`); shown as `—`.
    static let unknownDuration = -1

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
    /// §68.1 A2S_RULES reports `sv_password`.
    case passwordProtected
    /// §75.7/§75.13 the GoldSrc 48 path (CID not applicable; `ipBanned`, `cidBanned`, `rangeBanned`,
    /// `protocolMismatch` and `noBan` are never produced on it): the server banned the connection — a ban text in the
    /// probe's answer or in the engine log of the last GoldSrc connection to this server.
    case goldSrcBanned = "banned"
    /// §75.13 the GoldSrc 48 path without a ban text: the null-ticket probe cannot verify the ban status (silence, a
    /// ping, a refusal for another reason or an accepted probe never mean "no ban").
    case legacyVerificationUnavailable

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
        case .passwordProtected: return L10n.text(.diagnoseVerdictPasswordProtected)
        case .goldSrcBanned: return L10n.text(.diagnosisGoldsrcBanned)
        case .legacyVerificationUnavailable: return L10n.text(.diagnosisGoldsrcUnavailableVerdict)
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
        case .passwordProtected: return L10n.text(.diagnoseAdvicePasswordProtected)
        case .goldSrcBanned: return L10n.text(.diagnosisGoldsrcBannedAdvice)
        case .legacyVerificationUnavailable: return L10n.text(.diagnosisGoldsrcUnavailableAdvice)
        }
    }

    /// Card colour: bans red, a clean result green, everything else orange.
    var level: StatusLevel {
        switch self {
        case .ipBanned, .cidBanned, .rangeBanned, .goldSrcBanned: return .red
        case .noBan: return .green
        default: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .ipBanned, .cidBanned, .rangeBanned, .goldSrcBanned: return "xmark.octagon.fill"
        case .noBan: return "checkmark.seal.fill"
        case .dnsFailure: return "questionmark.circle.fill"
        case .serverOffline: return "powerplug"
        case .timeout: return "hourglass"
        case .protocolMismatch: return "arrow.left.arrow.right.circle"
        case .cidUnverified: return "questionmark.diamond"
        case .vpnConflict: return "lock.shield"
        case .checksDisabled: return "pause.circle"
        case .passwordProtected: return "lock.fill"
        case .legacyVerificationUnavailable: return "questionmark.diamond"
        }
    }

    /// The verdicts a ban message (§17.9.1) makes sense for.
    var isBan: Bool { self == .ipBanned || self == .cidBanned || self == .rangeBanned || self == .goldSrcBanned }

    /// §75.13 a verdict of the GoldSrc 48 path.
    var isGoldSrc: Bool { self == .goldSrcBanned || self == .legacyVerificationUnavailable }
}

// MARK: - Classification (§64.2)

/// What the probe observed; the classifier turns it into exactly one verdict.
struct DiagnosisFacts: Sendable, Equatable {
    enum DNS: Sendable, Equatable { case resolved, failed }
    enum Info: Sendable, Equatable { case replied, noReply, socketError }
    enum Challenge: Sendable, Equatable { case challenge, banned, unrecognized, noReply }
    /// `capabilityBanned` (§75.3): the CID-less capability probe got a ban text — a general/IP ban, never a CID ban.
    enum Connect: Sendable, Equatable { case ok, banned, notApplicable, unrecognized, noReply, noCID, capabilityBanned }

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
    /// §68.1 A2S_RULES `sv_password` (`nil` = not asked or not reported).
    var passwordProtected: Bool? = nil
    /// §75.1 protocol of the A2S_INFO reply (`unknown` without a usable reply).
    var serverProtocol: ServerProtocol = .unknown
    /// §75.6 outcome of the GoldSrc 48 legacy probe (only on the GoldSrc path).
    var goldSrc: GoldSrcProbeOutcome? = nil
}

enum DiagnosisClassifier {
    /// The probe verdict. "No ban" only when A2S_INFO, getchallenge and connect 49 all succeeded.
    /// §68.1: a password reported by A2S_RULES decides every verdict except a ban (a ban keeps priority; the card
    /// still names the password).
    static func verdict(_ facts: DiagnosisFacts) -> DiagnosisVerdict {
        let verdict = probeVerdict(facts)
        // §75.7: the GoldSrc verdict keeps its own outcome; the card names a password next to it.
        guard !verdict.isGoldSrc, facts.passwordProtected == true, !verdict.isBan, verdict != .dnsFailure, verdict != .checksDisabled else {
            return verdict
        }
        return .passwordProtected
    }

    private static func probeVerdict(_ facts: DiagnosisFacts) -> DiagnosisVerdict {
        guard facts.dns == .resolved else { return .dnsFailure }
        guard facts.checksEnabled else { return .checksDisabled }
        if facts.info == .socketError { return .timeout }
        // §75.7: a GoldSrc 48 server gets the GoldSrc verdict (ban, rejection, time-out are its outcome).
        if facts.serverProtocol == .goldsrc48 {
            return facts.goldSrc == .banned ? .goldSrcBanned : .legacyVerificationUnavailable
        }
        switch facts.challenge {
        case .banned?:
            return facts.knownRange == nil ? .ipBanned : .rangeBanned
        case .challenge?:
            switch facts.connect {
            case .ok?:
                return facts.info == .replied ? .noBan : .cidUnverified
            case .banned?: return .cidBanned
            case .capabilityBanned?: return facts.knownRange == nil ? .ipBanned : .rangeBanned
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
        // §75.7: the engine log never turns the GoldSrc verdict into an IP/CID ban.
        guard !probe.isBan, probe != .noBan, !probe.isGoldSrc, let direct = log.directVerdict else { return probe }
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
    /// §68.1: run the A2S_RULES step after the challenge (details diagnosis only).
    var queryRules = false
    /// §75.10 AC-75.R1: the GoldSrc 48 legacy probe is sent only on a user request (the Diagnose button / command or
    /// `playeridentityctl diagnose --confirm`); without it the probe step is skipped (`notConfirmed`).
    var legacyProbeConfirmed = false
    /// §75.4 the last decided A2S protocol of the server (saved row / this session). When this run's A2S_INFO gets no
    /// usable reply, a known `goldsrc48` keeps the GoldSrc path (connect 49 is never sent to a known GoldSrc server).
    var knownProtocol: ServerProtocol = .unknown
}

struct ConnectionProbeResult: Sendable, Equatable {
    var steps: [DiagnosisStep]
    var facts: DiagnosisFacts
    var verdict: DiagnosisVerdict
    var address: String?
    var cid: String?
    var info: ServerInfo?
    /// §68.1 rules of the `rules` step.
    var rules: ServerRulesResult? = nil
    /// §75.1 protocol decided by the A2S_INFO step.
    var serverProtocol: ServerProtocol = .unknown
    /// §75.6 the GoldSrc 48 legacy probe result (only on the GoldSrc path).
    var goldSrc: GoldSrcProbeResult? = nil
    /// §75.3 (v5.4.6) the real-CID check did not run (capability probe undecided / no time left): never "not banned".
    var cidCheckIncomplete = false
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
    /// §75.6 CD key of the legacy probe (random per probe, never derived from the identity).
    let cdKey: @Sendable () -> String
    let step: TimeInterval
    let total: TimeInterval

    init(transport: any UDPTransport, resolver: any ServerAddressResolver, now: @escaping @Sendable () -> Date,
         qport: @escaping @Sendable () -> UInt16 = { UInt16.random(in: 1...UInt16.max) },
         cdKey: @escaping @Sendable () -> String = { GoldSrcPackets.randomCDKey() },
         stepTimeout: TimeInterval = ConnectionDiagnoser.stepTimeout,
         totalTimeout: TimeInterval = ConnectionDiagnoser.totalTimeout) {
        self.transport = transport
        self.resolver = resolver
        self.now = now
        self.qport = qport
        self.cdKey = cdKey
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
        // §75.4 the known protocol holds until this run's A2S reply decides one (also through a DNS or network
        // failure: a known GoldSrc 48 server never reads as "not banned").
        facts.serverProtocol = request.knownProtocol
        result.serverProtocol = request.knownProtocol

        func millis(since date: Date) -> Int { max(0, Int((now().timeIntervalSince(date) * 1000).rounded())) }
        func record(_ kind: DiagnosisStepKind, _ status: DiagnosisStepStatus, since date: Date?, target: String,
                    _ detail: String) async {
            let step = DiagnosisStep(step: kind, status: status, durationMs: date.map(millis) ?? 0, target: target,
                                     detail: detail)
            steps.append(step)
            await progress(.finished(step))
        }
        func skipRest(from kind: DiagnosisStepKind, target: String, _ detail: String) async {
            for later in DiagnosisStepKind.probeSteps(for: facts.serverProtocol)
            where later.order >= kind.order && !steps.contains(where: { $0.step == later }) {
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
        /// §68.1 A2S_RULES on the same session; never changes the probe steps, only adds `rules`.
        func rulesStep() async throws {
            guard request.queryRules, now() < overallDeadline else { return }
            try Task.checkCancellation()
            await progress(.started(.rules))
            let rulesStart = now()
            let deadline = min(rulesStart.addingTimeInterval(step), overallDeadline)
            let querier = ServerQuerier(transport: transport, now: now, attemptTimeout: max(0.5, step / 4))
            switch try await querier.rules(session, until: deadline) {
            case .success(let rules):
                result.rules = rules
                facts.passwordProtected = rules.passwordProtected
                var detail = "\(rules.rules.count) rules"
                if let password = rules.passwordProtected { detail += " · password=\(password ? 1 : 0)" }
                if rules.truncated { detail += " · truncated" }
                await record(.rules, .ok, since: rulesStart, target: endpointTarget, detail)
            case .failure(let error):
                await record(.rules, .failed, since: rulesStart, target: endpointTarget, "\(error)")
            }
        }
        let infoDeadline = min(infoStart.addingTimeInterval(step), overallDeadline)
        var infoSentAt = now()
        // §75.2: a GoldSrc 48 server's legacy `0x6D` reply is preferred over its Source-layout reply.
        if let first = try await checker.exchangeInfo(session, BanPackets.info(), until: infoDeadline) {
            var reply = first.bytes
            var receivedAt = first.receivedAt
            if case .challenge(let challenge) = BanReplies.classifyInfo(reply) {
                infoSentAt = now()
                if let second = try await checker.exchangeInfo(session, BanPackets.info(challenge: challenge),
                                                               until: infoDeadline) {
                    reply = second.bytes
                    receivedAt = second.receivedAt
                }
            }
            let inspection = ServerInfoParser.inspect(reply)
            var info = inspection.info
            info?.pingMillis = max(0, Int((receivedAt.timeIntervalSince(infoSentAt) * 1000).rounded()))
            result.info = info
            if info != nil {
                facts.info = .replied
                facts.serverProtocol = info?.serverProtocol ?? .unknown
                result.serverProtocol = facts.serverProtocol
                await record(.a2sInfo, .ok, since: infoStart, target: endpointTarget,
                             Self.infoDetail(info, trailingBytes: inspection.trailingBytes))
            } else {
                facts.info = .noReply
                await record(.a2sInfo, .failed, since: infoStart, target: endpointTarget,
                             "unrecognized: " + BanReplies.printable(BanReplies.text(reply)))
            }
        } else {
            facts.info = .noReply
            await record(.a2sInfo, .failed, since: infoStart, target: endpointTarget, "noReply")
        }

        // §75.5 GoldSrc 48: GoldSrc challenge → legacy probe; connect 49 is never sent on this path.
        func goldSrcPath() async throws -> ConnectionProbeResult {
            func outcome(_ value: GoldSrcProbeResult) {
                result.goldSrc = value
                facts.goldSrc = value.outcome
            }
            // §75.10 AC-75.R1: without the user's confirmation no legacy packet at all (no `getchallenge steam`, no
            // connect 48).
            guard request.legacyProbeConfirmed else {
                outcome(GoldSrcProbeResult(.notConfirmed))
                await record(.getChallenge, .skipped, since: nil, target: endpointTarget, "notConfirmed")
                await record(.connect48, .skipped, since: nil, target: endpointTarget, "notConfirmed")
                return finish()
            }
            // 3. getchallenge (GoldSrc form)
            try Task.checkCancellation()
            guard now() < overallDeadline else {
                facts.totalTimedOut = true
                outcome(GoldSrcProbeResult(.noReply))
                await skipRest(from: .getChallenge, target: endpointTarget, "totalTimeout")
                return finish()
            }
            await progress(.started(.getChallenge))
            let challengeStart = now()
            let challengeDeadline = min(challengeStart.addingTimeInterval(step), overallDeadline)
            guard let reply = try await checker.exchange(session, GoldSrcPackets.getChallenge(), until: challengeDeadline,
                                                         ignoreInfo: true) else {
                facts.challenge = .noReply
                outcome(GoldSrcProbeResult(.noReply))
                await record(.getChallenge, .failed, since: challengeStart, target: endpointTarget, "noReply")
                await skipRest(from: .connect48, target: endpointTarget, "noChallenge")
                return finish()
            }
            let challenge: String
            switch GoldSrcReplies.challenge(reply) {
            case .banned(let message):
                facts.challenge = .banned
                outcome(GoldSrcProbeResult(.banned, message: message))
                await record(.getChallenge, .failed, since: challengeStart, target: endpointTarget, "banned: " + message)
                await skipRest(from: .connect48, target: endpointTarget, "banned")
                return finish()
            case .unrecognized(let text):
                facts.challenge = .unrecognized
                outcome(GoldSrcProbeResult(.incomplete, message: text))
                await record(.getChallenge, .failed, since: challengeStart, target: endpointTarget, "unrecognized: " + text)
                await skipRest(from: .connect48, target: endpointTarget, "noChallenge")
                return finish()
            case .challenge(let value):
                challenge = value
                facts.challenge = .challenge
                await record(.getChallenge, .ok, since: challengeStart, target: endpointTarget, "challenge")
            }

            // 4. connect 48 (legacy probe; confirmed above).
            try Task.checkCancellation()
            guard now() < overallDeadline else {
                facts.totalTimedOut = true
                outcome(GoldSrcProbeResult(.noReply))
                await skipRest(from: .connect48, target: endpointTarget, "totalTimeout")
                return finish()
            }
            await progress(.started(.connect48))
            let connectStart = now()
            let connectDeadline = min(connectStart.addingTimeInterval(step), overallDeadline)
            guard let packet = GoldSrcPackets.connect(challenge: challenge, cdKey: cdKey(), name: request.name) else {
                outcome(GoldSrcProbeResult(.incomplete))
                await record(.connect48, .failed, since: connectStart, target: endpointTarget, "invalidChallenge")
                return finish()
            }
            guard let connectReply = try await checker.exchange(session, packet, until: connectDeadline,
                                                                ignoreInfo: true) else {
                outcome(GoldSrcProbeResult(.noReply))
                await record(.connect48, .failed, since: connectStart, target: endpointTarget, "noReply")
                try await rulesStep()
                return finish()
            }
            let probe = GoldSrcReplies.connect(connectReply)
            outcome(probe)
            await record(.connect48, probe.outcome == .accepted ? .ok : .failed, since: connectStart,
                         target: endpointTarget,
                         probe.outcome.rawValue + (probe.message.isEmpty ? "" : ": " + probe.message))
            try await rulesStep()
            return finish()
        }

        if facts.serverProtocol == .unknown, request.knownProtocol != .unknown {
            facts.serverProtocol = request.knownProtocol
            result.serverProtocol = request.knownProtocol
        }
        if facts.serverProtocol == .goldsrc48 {
            return try await goldSrcPath()
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

        // 4. connect 49 — §75.4: only for a proven Source 49 server; an unknown protocol gets no CID and no connect 49.
        try Task.checkCancellation()
        guard facts.serverProtocol == .source49 else {
            facts.connect = .noCID
            await record(.connect49, .skipped, since: nil, target: endpointTarget, "protocolUnknown")
            try await rulesStep()
            return finish()
        }
        guard let rawID = request.rawID else {
            facts.connect = .noCID
            await record(.connect49, .skipped, since: nil, target: endpointTarget, "noCID")
            try await rulesStep()
            return finish()
        }
        guard now() < overallDeadline else {
            facts.totalTimedOut = true
            await skipRest(from: .connect49, target: endpointTarget, "totalTimeout")
            return finish()
        }
        await progress(.started(.connect49))
        let connectStart = now()
        let connectDeadline = min(connectStart.addingTimeInterval(step), overallDeadline)
        // §75.3: the CID-less capability probe first; a GoldSrc 48 server ("older protocol ( 48 )") never receives or
        // gets a real CID computed.
        let capability = BanPackets.capabilityProbe(challenge: challenge, qport: qport(), name: request.name)
        let capabilityReply = try await checker.exchange(session, capability, until: connectDeadline, ignoreInfo: true)
        switch BanReplies.capability(capabilityReply) {
        case .goldSrc(let text):
            facts.connect = .notApplicable
            facts.serverProtocol = .goldsrc48
            result.serverProtocol = .goldsrc48
            result.cid = nil
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         "capability: " + BanReplies.printable(text))
            try await rulesStep()
            return finish()
        case .banned(let text):
            // Refused before any CID: a general/IP ban (never a CID ban).
            facts.connect = .capabilityBanned
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         "banned: capability: " + BanReplies.printable(text))
            try await rulesStep()
            return finish()
        case .unverified(let text):
            facts.connect = text == "noReply" ? .noReply : .unrecognized
            result.cidCheckIncomplete = true
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         text == "noReply" ? "noReply" : "capabilityUnrecognized: " + BanReplies.printable(text))
            try await rulesStep()
            return finish()
        case .proceed:
            break
        }
        // The real CID only after an explicit accept and only while the overall budget lasts.
        guard now() < overallDeadline else {
            facts.connect = .noReply
            facts.totalTimedOut = true
            result.cidCheckIncomplete = true
            await record(.connect49, .failed, since: connectStart, target: endpointTarget, "totalTimeout")
            return finish()
        }
        let cid = CIDCalculator.cid(rawID: rawID, address: address)
        result.cid = cid
        let cidDeadline = min(now().addingTimeInterval(step), overallDeadline)
        let packet = BanPackets.connect(challenge: challenge, cid: cid, qport: qport(), name: request.name)
        guard let connectReply = try await checker.exchange(session, packet, until: cidDeadline, ignoreInfo: true) else {
            facts.connect = .noReply
            await record(.connect49, .failed, since: connectStart, target: endpointTarget, "noReply")
            try await rulesStep()
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
            // §75.13 "older protocol 48": the server is GoldSrc 48 — no CID, no protocol mismatch, no ban claim.
            facts.connect = .notApplicable
            facts.serverProtocol = .goldsrc48
            result.serverProtocol = .goldsrc48
            result.cid = nil
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         "protocol: " + BanReplies.printable(text))
        case .unrecognized(let text):
            facts.connect = .unrecognized
            await record(.connect49, .failed, since: connectStart, target: endpointTarget,
                         "unrecognized: " + BanReplies.printable(text))
        }
        try await rulesStep()
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

    static func infoDetail(_ info: ServerInfo?, trailingBytes: Int = 0) -> String {
        guard let info else { return "" }
        var parts: [String] = []
        // §75.1 the decided protocol (`goldsrc48` / `source49`); `unknown` is left out (older detail format).
        if info.serverProtocol != .unknown { parts.append(info.serverProtocol.rawValue) }
        if let name = info.name { parts.append(name) }
        if let map = info.map { parts.append(map) }
        if let players = info.players { parts.append(info.maxPlayers.map { "\(players)/\($0)" } ?? "\(players)") }
        if let ping = info.pingMillis { parts.append("\(ping) ms") }
        // §75.2: unexpected bytes after a complete GoldSrc reply keep `goldsrc48`; they are only reported here.
        if trailingBytes > 0 { parts.append("trailingBytes=\(trailingBytes)") }
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
    /// §66.3 total run time (probe + engine log) in milliseconds; `nil` when unknown.
    var durationMs: Int? = nil
    /// §67.1 a diagnosis rebuilt from its history line (`playeridentityctl report`): the verdict written then, which
    /// a later engine log never changes.
    var recordedVerdict: DiagnosisVerdict? = nil
    /// §68.2 ban record lookup of this run (only when the server has one enabled); the report shows its count only.
    var banRecord: BanRecordOutcome? = nil

    /// §68.1 the rules reported a password (shown with every verdict, also next to a ban).
    var passwordProtected: Bool { probe.facts.passwordProtected == true }

    var steps: [DiagnosisStep] { probe.steps }
    var probeVerdict: DiagnosisVerdict { probe.verdict }
    /// §75.13 the engine log of the last GoldSrc connection to this server (GoldSrc 48 path only).
    var goldSrcLog: GoldSrcLogEvidence? = nil
    /// §75.13 `engine.log` exists but could not be read (shown/logged; never silently treated as "no evidence").
    var goldSrcLogError: String? = nil

    /// The single verdict shown (§64.2, §64.3); §75.13 a ban in the GoldSrc engine log decides an unverified probe.
    var verdict: DiagnosisVerdict {
        if let recordedVerdict { return recordedVerdict }
        // An A2S time-out (unknown protocol) does not hide the engine's own ban evidence for this server either.
        if goldSrcLog?.outcome == .banned,
           probe.verdict == .legacyVerificationUnavailable || probe.serverProtocol == .unknown { return .goldSrcBanned }
        return DiagnosisClassifier.final(probe: probe.verdict, log: engineLog)
    }
    /// The verdict came from the engine log, not from the probe.
    var verdictFromLog: Bool { verdict != probe.verdict }

    /// §75.1 protocol decided by this run's A2S_INFO step.
    var serverProtocol: ServerProtocol { probe.serverProtocol }
    /// §75.6 the GoldSrc legacy probe result (only on the GoldSrc path).
    var goldSrc: GoldSrcProbeResult? { verdict.isGoldSrc ? probe.goldSrc : nil }
    /// §75.13 `banned` of the JSON: `true` for a ban; on the GoldSrc path without a ban `nil` (never "not banned").
    var bannedValue: Bool? {
        if verdict.isBan { return true }
        return verdict.isGoldSrc || serverProtocol == .goldsrc48 || probe.cidCheckIncomplete ? nil : false
    }
    /// §75.13 the server's ban/refusal text: the engine log's reason, else the probe's message (GoldSrc only).
    var serverMessage: String? {
        guard verdict.isGoldSrc else { return nil }
        if let reason = goldSrcLog?.reason, !reason.isEmpty { return reason }
        guard let message = probe.goldSrc?.message, !message.isEmpty else { return nil }
        return message
    }

    /// §66.4 the run could not reach any network: the socket could not be opened or DNS had no network.
    var networkUnavailable: Bool {
        steps.contains { step in
            step.status == .failed
                && ((step.step == .a2sInfo && step.detail.hasPrefix("socket:")) || (step.step == .dns && step.detail == "network"))
        }
    }

    /// History line (§64.1): `new` = verdict, `old` = probe verdict when the engine log overrode it, `note` = steps.
    var historyEntry: HistoryEntry {
        var summary = steps.map { "\($0.step.rawValue)=\($0.status.rawValue)" }.joined(separator: " ")
        // §75.6 the GoldSrc outcome is kept with the steps (the report rebuilds it from the line).
        if let outcome = goldSrc?.outcome { summary += " goldsrc=\(outcome.rawValue)" }
        if verdict.isGoldSrc, let log = goldSrcLog { summary += " goldsrcLog=\(log.outcome.rawValue)" }
        return HistoryEntry(ts: startedAt, kind: .diagnose, serverID: serverID, host: "\(host):\(port)",
                            old: verdictFromLog ? probe.verdict.rawValue : nil, new: verdict.rawValue, note: summary,
                            durationMs: durationMs)
    }
}

// MARK: - §66.2 Range ban note

/// Extra text of the verdict card for `rangeBanned`: renewing the IP is not enough (the `/24` or `/16` range is
/// blocked), the blocked range when known, and the "Change network" hint (mobile hotspot / VPN with another exit).
struct RangeBanNote: Sendable, Equatable {
    let explanation: String
    let range: String?
    let hintTitle: String
    let hint: String

    init?(_ diagnosis: ConnectionDiagnosis) {
        guard diagnosis.verdict == .rangeBanned else { return nil }
        explanation = L10n.text(.diagnoseRangeBanExplanation)
        range = diagnosis.probe.facts.knownRange.map { L10n.format(.diagnoseRangeBanRange, $0) }
        hintTitle = L10n.text(.diagnoseRangeBanHintTitle)
        hint = L10n.text(.diagnoseRangeBanHint)
    }

    /// The texts in reading order (VoiceOver value of the card).
    var lines: [String] { [explanation] + (range.map { [$0] } ?? []) + [hintTitle, hint] }
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
    /// §66.3 with `history`, the header names the period and a "History (last 10 runs)" table (time, verdict,
    /// duration) follows the diagnosis.
    static func markdown(_ diagnosis: ConnectionDiagnosis, appVersion: String, masked: Bool = true,
                         timeZone: TimeZone = .current, history: DiagnosisReportHistory? = nil) -> String {
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
        } else if diagnosis.verdict.isGoldSrc {
            lines.append("- \(L10n.text(.serversColumnCID)): \(L10n.text(.serversGoldsrcCidNotUsed))")
        }
        if let ip {
            lines.append("- \(L10n.text(.networkPublicIP)): `\(masked ? maskIP(ip) : ip)`")
        }
        if let history {
            lines.append("- \(L10n.text(.diagnoseTrendWindow)): \(history.window.title)")
        }
        if let banRecord = diagnosis.banRecord {
            lines.append("- " + BanRecordText.reportLine(banRecord))
        }
        lines.append("- " + L10n.text(masked ? .diagnoseReportMasked : .diagnoseReportUnmaskedNote))
        lines.append("")
        lines.append("## \(L10n.text(.diagnoseVerdict)): `\(diagnosis.verdict.rawValue)`")
        lines.append("")
        lines.append(diagnosis.verdict.sentence)
        lines.append("")
        lines.append(diagnosis.verdict.advice)
        if diagnosis.verdict.isGoldSrc {
            lines.append("")
            lines.append(contentsOf: GoldSrcDiagnosisText(diagnosis: diagnosis, goldSrc: diagnosis.goldSrc).lines
                .map { "- " + clean($0) })
        }
        if diagnosis.passwordProtected, diagnosis.verdict != .passwordProtected {
            lines.append("")
            lines.append(L10n.text(.diagnosePasswordNote))
        }
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
            let duration = step.durationMs == DiagnosisStep.unknownDuration ? "—" : "\(step.durationMs) ms"
            lines.append("| `\(step.step.rawValue)` | \(step.status.rawValue) | \(duration) | \(cell(step.target)) | \(cell(step.detail)) |")
        }
        lines.append("")
        lines.append("## " + L10n.text(.diagnoseLogTitle))
        lines.append("")
        lines.append(contentsOf: logLines(diagnosis.engineLog).map { clean($0) })
        if let history {
            lines.append("")
            lines.append(contentsOf: historyLines(history, timeZone: timeZone))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// §66.3 "History (last 10 runs)": newest first; time, verdict, duration (`—` when the line has none).
    static func historyLines(_ history: DiagnosisReportHistory, timeZone: TimeZone = .current) -> [String] {
        var lines = ["## " + L10n.text(.diagnoseReportHistory), ""]
        guard !history.runs.isEmpty else {
            lines.append(L10n.text(.diagnoseTrendEmptyWindow))
            return lines
        }
        lines.append("| \(L10n.text(.diagnoseColumnTime)) | \(L10n.text(.diagnoseVerdict)) | \(L10n.text(.diagnoseColumnDuration)) |")
        lines.append("|---|---|---|")
        for run in history.runs {
            let duration = run.durationMs.map { L10n.format(.diagnoseDuration, String($0)) } ?? "—"
            lines.append("| \(timestamp(run.ts, timeZone: timeZone)) | `\(run.verdict.rawValue)` (\(run.verdict.shortLabel)) | \(duration) |")
        }
        return lines
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

// MARK: - §75.7 / §75.8 GoldSrc texts

/// The texts of the GoldSrc 48 card, the report and the CLI: protocol, "CID not used", the verdict (a ban only with
/// a ban text from the probe or the engine log; never "no ban"), the probe's own answer and its limit, the engine log
/// evidence, the server message, the administrator request for a ban/refusal (the app never claims to lift a ban)
/// and the `gs` join path.
struct GoldSrcDiagnosisText: Sendable, Equatable {
    let protocolLine: String
    let cidLine: String
    /// The verdict sentence: "The server banned this connection." or "The GoldSrc ban status could not be verified."
    let outcome: String
    /// The null-ticket probe's own answer (when it ran) and its limit.
    let probe: String?
    let probeLimit: String?
    /// The engine log evidence of the last GoldSrc connection (or that there is none).
    let engineLog: String
    let banScope: String?
    let serverMessage: String?
    let adminTitle: String?
    let adminText: String?
    /// Text for the administrator: server name, IP:port, server message.
    let request: String?
    let join: String

    init(diagnosis: ConnectionDiagnosis, goldSrc: GoldSrcProbeResult?) {
        let banned = diagnosis.verdict == .goldSrcBanned
        protocolLine = L10n.format(.diagnosisGoldsrcProtocol, L10n.text(.serversGoldsrcProtocolGoldSrc))
        cidLine = L10n.text(.serversGoldsrcCidNotUsed)
        outcome = banned ? L10n.text(.diagnosisGoldsrcBanned) : L10n.text(.diagnosisGoldsrcUnavailableVerdict)
        if let goldSrc, goldSrc.outcome != .notConfirmed || !banned {
            probe = goldSrc.sentence
        } else {
            probe = nil
        }
        probeLimit = banned && diagnosis.goldSrcLog == nil ? nil : L10n.text(.diagnosisGoldsrcProbeLimit)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let log = diagnosis.goldSrcLog {
            let date = formatter.string(from: log.sessionStart)
            engineLog = L10n.format(log.outcome == .banned ? .diagnosisGoldsrcLogBanned : .diagnosisGoldsrcLogDisconnected,
                                    log.reason, date)
        } else {
            engineLog = L10n.text(.diagnosisGoldsrcLogNone)
        }
        banScope = banned ? L10n.text(.diagnosisGoldsrcBanScope) : nil
        let message = diagnosis.serverMessage
        // A probe rejection already names its reason in `probe`.
        serverMessage = diagnosis.goldSrcLog != nil || goldSrc?.outcome == .banned
            ? message.map { L10n.format(.diagnosisGoldsrcServerMessage, $0) } : nil
        let refused = banned || goldSrc?.outcome == .rejected || diagnosis.goldSrcLog != nil
        if refused {
            adminTitle = L10n.text(.diagnosisGoldsrcAdminTitle)
            adminText = L10n.text(.diagnosisGoldsrcAdminText)
            let name = diagnosis.probe.info?.name ?? (diagnosis.label.isEmpty ? diagnosis.host : diagnosis.label)
            request = L10n.format(.diagnosisGoldsrcRequest, name,
                                  ServerAddressText.hostPort(host: diagnosis.host, port: diagnosis.port),
                                  message ?? L10n.text(.diagnosisGoldsrcNoMessage))
        } else {
            adminTitle = nil
            adminText = nil
            request = nil
        }
        let address = ServerAddressText.hostPort(host: diagnosis.probe.address ?? diagnosis.host, port: diagnosis.port)
        join = L10n.format(.diagnosisGoldsrcJoin, "+connect \(address) gs")
    }

    /// Reading order (report lines, VoiceOver value).
    var lines: [String] {
        [protocolLine, cidLine, outcome] + [probe, probeLimit].compactMap { $0 } + [engineLog]
            + [banScope, serverMessage, adminTitle, adminText].compactMap { $0 } + [join]
    }
}

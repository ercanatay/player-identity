import Foundation

// MARK: - §75.6 GoldSrc 48 legacy probe: packets

/// The packets of the GoldSrc 48 connection probe (§75.6). The layout is fixed by a byte vector test (AC-75.P1) that
/// matches a packet captured from the engine's own `connect <host> gs` with `cl_ticket_generator null`.
enum GoldSrcPackets {
    static let protocolVersion = 48
    /// Null ticket: 512 zero bytes right after the body's newline (the body's string terminator is overwritten).
    static let ticketLength = 512
    /// Longest player name sent (bytes, UTF-8); GoldSrc names are at most 31 bytes.
    static let maxNameBytes = 31
    static let defaultName = "player"

    /// `FF FF FF FF getchallenge steam\n` — the challenge request the engine sends before a GoldSrc connect.
    static func getChallenge() -> [UInt8] {
        BanPackets.header + Array("getchallenge steam\n".utf8)
    }

    /// `\prot\3\unique\-1\raw\steam\cdkey\<32 hex>` (Xash/GoldSrc info string).
    static func protinfo(cdKey: String) -> String {
        "\\prot\\3\\unique\\-1\\raw\\steam\\cdkey\\\(cdKey)"
    }

    /// `\name\<name>`: only the player name (no identity, no CID).
    static func userinfo(name: String) -> String {
        "\\name\\\(sanitizedName(name))"
    }

    /// `FF FF FF FF` + `connect 48 <challenge> "<protinfo>" "<userinfo>"\n` + 512 zero bytes. `nil` when the challenge
    /// or the CD key is not in the expected form (never sent then).
    static func connect(challenge: String, cdKey: String, name: String) -> [UInt8]? {
        guard GoldSrcReplies.isChallengeToken(challenge), isCDKey(cdKey) else { return nil }
        let text = "connect \(protocolVersion) \(challenge) \"\(protinfo(cdKey: cdKey))\" \"\(userinfo(name: name))\"\n"
        return BanPackets.header + Array(text.utf8) + [UInt8](repeating: 0, count: ticketLength)
    }

    /// 32 lowercase hexadecimal characters.
    static func isCDKey(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A random CD key per probe (the engine also sends a new one on every connect); never derived from the identity.
    static func randomCDKey() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...UInt8.max)) }.joined()
    }

    /// The name without info-string separators (`\`), quotes, `;` or control characters, trimmed, at most 31 bytes;
    /// empty → `player`.
    static func sanitizedName(_ name: String) -> String {
        let allowed = name.unicodeScalars.filter { scalar in
            scalar != "\\" && scalar != "\"" && scalar != ";" && scalar.properties.generalCategory != .control
                && scalar != "\u{FFFD}"
        }
        var result = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.utf8.count > maxNameBytes { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? defaultName : result
    }
}

// MARK: - §75.6 replies

/// Outcome of the legacy probe (§75.6). Only `banned` names a ban; none of them claims an account or SteamID ban.
enum GoldSrcProbeOutcome: String, Codable, Sendable, CaseIterable {
    /// The server refused the connection with a ban text.
    case banned
    /// The server refused the connection without a ban text.
    case rejected
    /// No reply (time-out) to the challenge or the connect packet.
    case noReply
    /// A challenge came but the connection did not complete (unrecognized reply).
    case incomplete
    /// The server accepted the null-ticket probe; this never means "no ban" (§75.13: the ban may come after the
    /// connection is established).
    case accepted
    /// The probe was not sent: it runs only on a user request (§75.10 AC-75.R1).
    case notConfirmed

    /// The sentence of the GoldSrc card (`message` = the cleaned server text, may be empty).
    func sentence(message: String) -> String {
        switch self {
        case .banned: return L10n.text(.diagnosisGoldsrcBanned)
        case .rejected:
            return L10n.format(.diagnosisGoldsrcRejected, message.isEmpty ? L10n.text(.diagnosisGoldsrcNoMessage) : message)
        case .noReply: return L10n.text(.diagnosisGoldsrcNoReply)
        case .incomplete: return L10n.text(.diagnosisGoldsrcIncomplete)
        case .accepted: return L10n.text(.diagnosisGoldsrcAcceptedNoClaim)
        case .notConfirmed: return L10n.text(.diagnosisGoldsrcNotConfirmed)
        }
    }

    var level: StatusLevel {
        switch self {
        case .banned: return .red
        default: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .banned: return "xmark.octagon.fill"
        case .rejected: return "hand.raised.fill"
        case .noReply: return "hourglass"
        case .incomplete: return "questionmark.circle.fill"
        case .accepted: return "questionmark.diamond"
        case .notConfirmed: return "pause.circle"
        }
    }

    /// The server refused the connection (with or without a ban text): the card suggests contacting the administrator.
    var isRefusal: Bool { self == .banned || self == .rejected }
}

/// The legacy probe result of one diagnosis: outcome + the cleaned server message (at most 200 characters).
struct GoldSrcProbeResult: Sendable, Equatable {
    var outcome: GoldSrcProbeOutcome
    var message: String

    init(_ outcome: GoldSrcProbeOutcome, message: String = "") {
        self.outcome = outcome
        self.message = message
    }

    var sentence: String { outcome.sentence(message: message) }
}

enum GoldSrcReplies {
    /// §75.6: the server message is shown with at most 200 characters, control characters removed.
    static let maxMessageLength = 200

    enum Challenge: Sendable, Equatable {
        /// The decimal challenge token of `A00000000 <challenge> <auth> …`.
        case challenge(String)
        case banned(String)
        case unrecognized(String)
    }

    /// Decimal challenge (`-2147483648…4294967295` as text).
    static func isChallengeToken(_ text: String) -> Bool {
        text.range(of: #"^-?[0-9]{1,10}$"#, options: .regularExpression) != nil
    }

    /// Cleaned, single-line server text, at most 200 characters (199 + `…` when cut).
    static func serverMessage(_ text: String) -> String {
        BanReplies.printable(text, limit: maxMessageLength - 1)
    }

    /// Text after the 4-byte header without the trailing NULs.
    static func text(_ reply: [UInt8]) -> String {
        guard reply.count > 4 else { return "" }
        var body = Array(reply[4...])
        while body.last == 0 { body.removeLast() }
        return ServerInfoParser.decode(body)
    }

    /// GoldSrc `getchallenge` reply: `A00000000 <challenge> <auth> …\n`; a ban text anywhere → `banned`.
    static func challenge(_ reply: [UInt8]) -> Challenge {
        guard BanReplies.isOutOfBand(reply) else { return .unrecognized("") }
        let text = text(reply)
        if GoldSrcBanText.isBan(text) { return .banned(serverMessage(stripType(text))) }
        if reply[4] == 0x41 {
            let tokens = text.dropFirst().split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count >= 2, isChallengeToken(tokens[1]) { return .challenge(tokens[1]) }
        }
        return .unrecognized(serverMessage(text))
    }

    /// GoldSrc `connect` reply: `B …` accepted; `9<reason>` (reject), `l<text>` (print) or a `disconnect` /
    /// `errormsg` text refuse it (ban text → `banned`, otherwise `rejected` with the reason); anything else →
    /// `incomplete` (the connection did not complete).
    static func connect(_ reply: [UInt8]) -> GoldSrcProbeResult {
        guard BanReplies.isOutOfBand(reply) else { return GoldSrcProbeResult(.incomplete) }
        let text = text(reply)
        let lower = text.lowercased()
        if reply[4] == 0x42 || lower.hasPrefix("client_connect") { return GoldSrcProbeResult(.accepted) }
        let refusal: String?
        if reply[4] == 0x39 || reply[4] == 0x6C {
            refusal = String(text.dropFirst())
        } else if let keyword = ["disconnect", "errormsg", "print"].first(where: { lower.hasPrefix($0) }) {
            refusal = String(text.dropFirst(keyword.count))
        } else {
            refusal = nil
        }
        guard let refusal else { return GoldSrcProbeResult(.incomplete, message: serverMessage(text)) }
        let message = serverMessage(refusal)
        return GoldSrcProbeResult(GoldSrcBanText.isBan(message) ? .banned : .rejected, message: message)
    }

    /// The text without its leading type character (`A`, `l`, `9`) when it is one.
    private static func stripType(_ text: String) -> String {
        guard let first = text.first, "Al9".contains(first) else { return text }
        return String(text.dropFirst())
    }
}

// MARK: - §75.13 ban phrase

/// The one classifier of a server's ban text (probe replies, engine log, UI and CLI): the standalone word "banned"
/// not negated by one of the three words before it. So "You have been banned from this server", "you are banned",
/// "Banned from this server" are bans; "bandwidth", "unbanned", "not banned", "never banned", "no longer banned",
/// "you are not banned from this server" are not. There is no phrase shortcut: every sentence goes through the
/// token check.
enum GoldSrcBanText {
    private static let negations: Set<String> = ["not", "never", "no", "isn't", "wasn't", "aren't", "weren't", "isnt",
                                                 "wasnt", "arent", "werent", "un", "longer", "nor", "without"]

    static func isBan(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
        for (index, word) in words.enumerated() where word == "banned" {
            let before = words[max(0, index - 3)..<index]
            if !before.contains(where: negations.contains) { return true }
        }
        return false
    }
}

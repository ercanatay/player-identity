import Foundation

// MARK: - §68.3 VPN reality card

/// The card of a ban verdict while the egress goes through a VPN (§37): a CID/range ban is not lifted by another VPN,
/// an IP ban may be. Other verdicts, or no VPN, show no card; the static help text is always reachable.
struct VPNGuidance: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// `cidBanned` / `rangeBanned` + VPN: changing the VPN does not help.
        case identityBan
        /// `ipBanned` + VPN: another exit may help (next to "Copy Unban Message").
        case ipBan
    }

    let kind: Kind

    init?(verdict: DiagnosisVerdict, vpnActive: Bool) {
        guard vpnActive else { return nil }
        switch verdict {
        case .cidBanned, .rangeBanned: kind = .identityBan
        case .ipBanned: kind = .ipBan
        default: return nil
        }
    }

    init?(_ diagnosis: ConnectionDiagnosis) {
        self.init(verdict: diagnosis.verdict, vpnActive: diagnosis.probe.facts.vpnActive)
    }

    var title: String { L10n.text(kind == .identityBan ? .vpnCardCidTitle : .vpnCardIpTitle) }
    var text: String { L10n.text(kind == .identityBan ? .vpnCardCidText : .vpnCardIpText) }
    var symbolName: String { kind == .identityBan ? "lock.trianglebadge.exclamationmark" : "arrow.triangle.swap" }
    /// The IP ban card keeps the unban message button next to it.
    var offersAppeal: Bool { kind == .ipBan }

    static var helpTitle: String { L10n.text(.vpnHelpTitle) }
    static var helpText: String { L10n.text(.vpnHelpText) }
}

import Foundation

/// §14 "To-dos / suggestions": an action the user can take for each reason code.
/// Single central mapping; the `switch` is exhaustive, so adding a new code breaks the build.
extension MessageCode {
    var suggestion: String { L10n.text(suggestionKey) }

    var suggestionKey: L10nKey {
        switch self {
        // §14.3 (verbatim Turkish values)
        case .ipBanned: return .suggestionIPBanned
        case .cidBanned: return .suggestionCIDBanned
        case .unreachable: return .suggestionUnreachable
        case .banUnknown: return .suggestionBanUnknown
        case .cidNotApplicable: return .suggestionCIDNotApplicable
        case .identityMissing: return .suggestionIdentityMissing
        case .identityInvalid: return .suggestionIdentityInvalid
        case .publicIPFailed: return .suggestionPublicIPFailed
        case .snapshotMissing: return .suggestionSnapshotMissing
        case .snapshotCorrupt: return .suggestionSnapshotCorrupt
        case .rawIDZero: return .suggestionRawIDZero
        case .nameChanged: return .suggestionNameChanged
        case .modelChanged: return .suggestionModelChanged
        case .publicIPChanged: return .suggestionPublicIPChanged
        case .lanIPChanged: return .suggestionLanIPChanged
        case .serverCIDChanged: return .suggestionServerCIDChanged
        case .invalidHost: return .suggestionInvalidHost
        // Codes not in §14.3, derived from the §7.2 conditions (their texts are not in the spec).
        case .lanIPMissing: return .suggestionLanIPMissing
        case .nameEmpty: return .suggestionNameEmpty
        case .modelEmpty: return .suggestionModelEmpty
        }
    }
}

/// Presentation of suggestion texts (§14.2). Pure functions.
enum SuggestionText {
    /// Secondary layer of a reason row: `→ <suggestion>`.
    static func secondaryLine(for code: MessageCode) -> String {
        "→ " + code.suggestion
    }

    /// Lines of the "What to do?" popover: suggestions for the current reasons, numbered in order.
    static func numberedLines(for reasons: [StatusReason]) -> [String] {
        reasons.enumerated().map { index, reason in "\(index + 1). \(reason.code.suggestion)" }
    }

    /// Plain text written to the pasteboard by "Copy".
    static func plainText(for reasons: [StatusReason]) -> String {
        numberedLines(for: reasons).joined(separator: "\n")
    }
}

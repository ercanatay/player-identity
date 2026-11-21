import Foundation

// MARK: - §74 "Install Compatible Engine": app-side flow state (pure types; AppModel drives them)
//
// idle → fetchingRelease (release API only) → confirming (CID warning) → installing(progress) → finished(outcome)
// → (user opens the engine once, quits it, presses Refresh) → finished(outcome + identity verification).
// `installed` alone is never "supported": the card claims it only after the core verification says
// `identityRepaired` or `alreadyHealthy` (spec E20.10).

/// The confirmation screen of one fetched release.
struct EngineInstallOffer: Equatable {
    let summary: EngineInstallPlanSummary
    let environment: EngineInstallEnvironment
}

/// A finished run, with the identity verification once the user has opened the engine and pressed Refresh.
struct EngineInstallFinish: Equatable {
    let outcome: EngineInstallOutcome
    let report: EngineInstallReport
    /// `nil` until a refresh with the engine closed has compared the identity before and after the install.
    var verification: EngineIdentityResult?
}

/// Why "Install Compatible Engine" cannot start right now.
enum EngineInstallBlock: String, Equatable, Sendable {
    case engineRunning
    case processUnavailable
    /// Intel Macs (D5: closed until the amd64 gate passes).
    case architecture
    /// A fetch or an install is already running.
    case busy
    /// The current report does not offer the install (only `unsupported` with the engine closed does).
    case notOffered
}

enum EngineInstallFlow: Equatable {
    case idle
    case fetchingRelease
    case confirming(EngineInstallOffer)
    /// `cancelling`: the user cancelled while downloading/extracting and the core has not stopped yet.
    case installing(EngineInstallProgress, cancelling: Bool)
    case fetchFailed(EngineInstallFailure)
    case blocked(EngineInstallBlock)
    case finished(EngineInstallFinish)

    /// A network call or an install is in flight.
    var isBusy: Bool {
        switch self {
        case .fetchingRelease, .installing: return true
        default: return false
        }
    }

    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }

    var offer: EngineInstallOffer? {
        if case .confirming(let offer) = self { return offer }
        return nil
    }

    var finish: EngineInstallFinish? {
        if case .finished(let finish) = self { return finish }
        return nil
    }
}

/// Result of "Open Engine" after an install.
enum EngineInstallLaunchStatus: Equatable, Sendable {
    case launched
    case engineRunning
    case processUnavailable
    case failed(String)
}

/// Whether the card shows the install button, and why it is disabled.
enum EngineInstallAvailability: Equatable {
    case hidden
    case enabled
    case disabled(EngineInstallBlock)

    /// AC-E1: shown only for `unsupported` (S = no, R ∈ {zero, absent}, B = readable, P = notRunning) of the current
    /// (not checking) report; disabled while the engine runs now, its state is unknown, another run is active, or on
    /// an Intel Mac.
    static func evaluate(report: MacIdentityReport?, checking: Bool, engineRunning: Bool,
                         processState: EngineProcessState?, architecture: EngineArchitecture,
                         flow: EngineInstallFlow) -> EngineInstallAvailability {
        guard let report, !checking, EngineInstallEligibility.isOffered(report) else { return .hidden }
        if flow.isBusy || flow.offer != nil { return .disabled(.busy) }
        let state = processState ?? report.processState
        if engineRunning || state == .running { return .disabled(.engineRunning) }
        if state == .unavailable { return .disabled(.processUnavailable) }
        if EngineInstallCapability.check(architecture) != nil { return .disabled(.architecture) }
        return .enabled
    }
}

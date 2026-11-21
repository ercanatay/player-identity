import Foundation

// MARK: - v2.25 (feature spec E) "Install Compatible Engine": the seam between the core installer and its callers
//
// The app (`AppModel`) and the CLI (`playeridentityctl engine …`) talk to the installer only through
// `EngineInstallServing`, so their tests use fakes (no network, no real `/Applications`, no real game data). This file
// also holds the pure summary shown on the confirmation screen / prompt and the text-free failure grouping both use.
// Nothing here holds a raw identity, a full CID or an identity checksum.

/// What the app and the CLI need from an installer.
protocol EngineInstallServing: Sendable {
    /// `checking`: the release API only (the one network call before the confirmation).
    func fetchRelease() async -> Result<EngineRelease, EngineInstallFailure>
    /// The whole install after the confirmation; never throws.
    func install(_ release: EngineRelease, confirmation: EngineInstallConfirmation,
                 progress: @escaping @Sendable (EngineInstallProgress) async -> Void) async -> EngineInstallResult
}

extension EngineInstaller: EngineInstallServing {}

/// Builds an installer for one environment (target app, data root, game folder).
typealias EngineInstallerFactory = @Sendable (EngineInstallEnvironment) -> any EngineInstallServing

/// Default when nothing is injected (tests): never touches the network or a file.
struct UnavailableEngineInstaller: EngineInstallServing {
    init() {}

    func fetchRelease() async -> Result<EngineRelease, EngineInstallFailure> { .failure(.metadataUnavailable) }

    func install(_ release: EngineRelease, confirmation: EngineInstallConfirmation,
                 progress: @escaping @Sendable (EngineInstallProgress) async -> Void) async -> EngineInstallResult {
        EngineInstallResult(outcome: .failed(.metadataUnavailable), report: EngineInstallReport(),
                            log: [])
    }
}

extension EngineInstallEnvironment {
    /// The environment of the app or the CLI: the engine app the identity check uses, the active game folder
    /// (`valve` when none is chosen or the name is not a plain folder name).
    static func make(targetApp: URL, dataRoot: URL, gamedir: String?, paths: AppPaths,
                     architecture: EngineArchitecture = .current()) -> EngineInstallEnvironment {
        let folder = gamedir.flatMap { EngineInstallNaming.isPlainGamedir($0) ? $0 : nil }
            ?? EngineArchiveLayout.packageGamedir
        return EngineInstallEnvironment(targetApp: targetApp.standardized, dataRoot: dataRoot, gamedir: folder,
                                        home: paths.home, paths: paths, architecture: architecture)
    }
}

/// Everything the confirmation screen (and the CLI prompt) shows before anything is downloaded or written (AC-E2,
/// AC-E2a, AC-E15). The CID is kept only in the strict masked form.
struct EngineInstallPlanSummary: Sendable, Equatable {
    let release: EngineRelease
    let targetApp: URL
    /// The two game libraries of the active game folder that are replaced (when they exist).
    let gameLibraries: [URL]
    /// `engine-backups` (app copy, identity copies, library copies, manifest).
    let backupRoot: URL
    /// Masked CID at confirmation time; `nil` when there is none.
    let cidMasked: String?

    init(release: EngineRelease, environment: EngineInstallEnvironment, cidMasked: String?) {
        self.release = release
        targetApp = environment.targetApp
        gameLibraries = EngineArchiveLayout.gameLibraries(architecture: environment.architecture)
            .map { environment.gamedirURL.appendingPathComponent($0.gamedirRelative, isDirectory: false) }
        backupRoot = environment.paths.engineBackupsDirectory
        self.cidMasked = EngineInstallPrivacy.strictMasked(cidMasked)
    }

    /// `5.0 MB` style size of the asset.
    var sizeText: String { ByteCountFormatter.string(fromByteCount: release.asset.size, countStyle: .file) }
    /// First 12 characters of the commit (the full SHA is shown on the commit link).
    var shortCommit: String { String(release.commitSHA.prefix(12)) }
}

/// Coarse groups of a failure for the user (the exact `code` is always shown next to it, AC-E8).
enum EngineInstallFailureGroup: String, Sendable, Equatable {
    case network
    case verification
    case archive
    case permission
    case running
    case locked
    case target
    case cancelled
    case other

    init(_ failure: EngineInstallFailure) {
        switch failure {
        case .metadataUnavailable, .downloadFailed, .insecureURL, .hostNotAllowed, .redirectRejected, .urlNotAllowed,
             .timeout:
            self = .network
        case .metadataInvalid, .assetNotFound, .assetAmbiguous, .digestMissing, .digestInvalid, .sizeTooLarge,
             .sizeMismatch, .digestMismatch, .archiveChanged:
            self = .verification
        case .unsafeArchive, .missingExpectedFile, .extractionFailed, .mixedBuild, .sdl2Reconstruction, .codesign,
             .stagingFailed:
            self = .archive
        case .permissionDenied:
            self = .permission
        case .engineRunning, .processUnavailable:
            self = .running
        case .locked, .lockUnavailable:
            self = .locked
        case .targetInvalid, .forbiddenTarget, .unsafePath, .atomicSwapUnsupported, .conflict, .unsupportedArchitecture:
            self = .target
        case .cancelled, .notConfirmed:
            self = .cancelled
        case .backupFailed, .installFailed, .confirmationRequired:
            self = .other
        }
    }
}

extension EngineBackupStore {
    /// Short code that names one exact inventory (the CLI prints it with `engine backups`; `delete --confirm <code>`
    /// deletes only when the folder still has exactly that inventory).
    static func confirmationCode(for inventory: EngineBackupInventory) -> String {
        String(fingerprint(inventory).prefix(12))
    }

    /// Token for every prune candidate of `inventory` when `code` names it; otherwise `confirmationRequired`.
    func confirmDeletion(code: String, in inventory: EngineBackupInventory)
        -> Result<EngineBackupDeletionToken, EngineInstallFailure> {
        guard !code.isEmpty, code == Self.confirmationCode(for: inventory) else { return .failure(.confirmationRequired) }
        return confirmDeletion(of: inventory.pruneCandidates.map(\.stamp), in: inventory)
    }
}

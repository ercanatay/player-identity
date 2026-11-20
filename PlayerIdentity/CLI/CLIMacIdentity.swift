import Foundation

// §73.7 `playeridentityctl diagnose --macos-identity [--json]`: the macOS hardware identity health check from the
// command line. Read-only and offline: it inspects the engine bundle and the identity files, writes nothing (no
// history line either) and never prints the raw identity or a full CID (only the state label and a masked CID).
// `supported` means "a non-zero identity and static hardware-identity indicators were found"; uniqueness itself is
// never verified or claimed.
//
// Exit codes: 0 supported, 1 unsupported, 2 unknown, 3 unexpected error. A usage error also exits 1 (with the usage
// text on stderr), like every other command. An explicitly requested engine override that was rejected never exits 0:
// the fallback result is reported, but the exit code is at least 2 (unknown).

extension CLIExit {
    static let identitySupported: Int32 = 0
    static let identityUnsupported: Int32 = 1
    static let identityUnknown: Int32 = 2
    static let identityError: Int32 = 3
}

extension CLIContext {
    /// Engine app override for the identity check (validated like the app's Settings override).
    static let engineAppEnvironmentKey = "PLAYERIDENTITYCTL_ENGINE_APP"
    /// Folder whose `.config/.xash_id`, `.local/.xash_id` and `.xash_id` the identity check reads instead of the home
    /// folder (isolated calibration fixtures; read-only like the default).
    static let identityHomeEnvironmentKey = "PLAYERIDENTITYCTL_IDENTITY_HOME"

    /// `PLAYERIDENTITYCTL_ENGINE_APP`, else the app's Settings override, else `nil` (the default path).
    var engineAppOverride: String? {
        if let path = environment[Self.engineAppEnvironmentKey], !path.isEmpty { return path }
        return UserDefaults(suiteName: defaultsSuite)?.string(forKey: DefaultsKey.engineApp).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `PLAYERIDENTITYCTL_IDENTITY_HOME` (tilde expanded), else the home folder.
    var identityHome: URL {
        guard let path = environment[Self.identityHomeEnvironmentKey], !path.isEmpty else { return paths.home }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardized
    }
}

extension CLIRunner {
    static func macIdentityExitCode(_ state: MacIdentityState) -> Int32 {
        switch state {
        case .supported: return CLIExit.identitySupported
        case .unsupported: return CLIExit.identityUnsupported
        case .unknown: return CLIExit.identityUnknown
        }
    }

    /// The exit code of a report; a rejected explicit override is never a clean result (at least `unknown`).
    static func macIdentityExitCode(_ report: MacIdentityReport, resolution: EnginePathResolution) -> Int32 {
        let code = macIdentityExitCode(report.state)
        guard resolution.rejectedOverride != nil else { return code }
        return max(code, CLIExit.identityUnknown)
    }

    static func diagnoseMacIdentity(json: Bool, context: CLIContext) async -> CLIResult {
        let home = context.identityHome
        let snapshot = SnapshotStore(fileURL: context.snapshotURL).load().snapshot
        let dataRoot = snapshot.flatMap { $0.dataRoot.isEmpty ? nil : URL(fileURLWithPath: $0.dataRoot, isDirectory: true) }
            ?? AppPaths(home: home).defaultDataRoot
        let gamedir = snapshot.flatMap { $0.gamedir.isEmpty ? nil : $0.gamedir }
            .map { dataRoot.appendingPathComponent($0, isDirectory: true) }
        let override = context.engineAppOverride
        let roots = EnginePaths.forbiddenRoots(home: home, dataRoot: dataRoot)
        let checker = MacIdentityChecker(files: context.fileProbe, detector: context.gameProcessDetector,
                                         home: home, now: context.clock, clock: context.monotonicClock)
        // Process state first, then (only with the engine closed) the override validation, scan and identity read.
        // Cancelling the command cancels the detached scan too.
        let scan = Task.detached { checker.check(override: override, forbiddenRoots: roots, gamedir: gamedir) }
        let result = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        let report = result.report
        let resolution = result.resolution
        guard !Task.isCancelled, report.capabilityFailure != .cancelled else {
            return failure("cancelled", "the identity check was cancelled", command: "diagnose", json: json,
                           code: CLIExit.identityError)
        }
        let exitCode = macIdentityExitCode(report, resolution: resolution)
        let userHome = context.paths.home
        let enginePath = CLIPath.abbreviated(report.engineApp.path, home: userHome)
        // The physical path is resolved only when the path was validated (never while the engine runs).
        let physicalPath = resolution.validated
            ? CLIPath.abbreviated(context.fileProbe.resolvedPath(report.engineApp), home: userHome) : nil
        let requestedPath = resolution.requestedPath.map { CLIPath.abbreviated($0, home: userHome) }
        var stderr = ""
        if let rejected = resolution.rejectedOverride {
            stderr = "playeridentityctl: error: requested engine override \(requestedPath ?? "-") rejected "
                + "(\(rejected.rawValue)); the default \(EnginePaths.defaultApp.path) was checked instead and the "
                + "result is not used as a pass\n"
        }
        if json {
            let evidence: Any = report.staticChecked ? [
                "k1_iokit_linked": report.evidence.ioKitLinked,
                "k2_corefoundation_linked": report.evidence.coreFoundationLinked,
                "k3_ioregistry_access": report.evidence.ioRegistryAccess,
                "k4_platform_serial_string": report.evidence.platformSerialString,
                "count": report.evidence.count,
            ] as [String: Any] : NSNull()
            let object: [String: Any] = [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "diagnose", "check": "macos-identity",
                "state": report.state.rawValue, "finding": report.finding.rawValue, "action": report.action.rawValue,
                "uniqueness_verified": false,
                "process_state": report.processState.rawValue,
                "package_readability": report.packageReadability?.rawValue ?? NSNull(),
                "static_support": report.staticSupport.rawValue, "evidence": evidence,
                "static_failure": report.capabilityFailure?.rawValue ?? NSNull(),
                "raw_state": report.rawState?.rawValue ?? NSNull(),
                "cid_masked": report.cidMasked ?? NSNull(),
                "engine_path": enginePath,
                "effective_engine_path": resolution.validated ? enginePath : NSNull(),
                "engine_physical_path": physicalPath ?? NSNull(),
                "engine_path_validated": resolution.validated,
                "requested_engine_path": requestedPath ?? NSNull(),
                "override_rejected": resolution.rejectedOverride != nil,
                "reject_reason": resolution.rejectedOverride?.rawValue ?? NSNull(),
                "engine_hash_short": report.engineHashShort ?? NSNull(),
                "engine_running": report.engineRunning,
                "engine_version_informational": report.engineVersion ?? NSNull(),
                "app_version": context.version,
                "timestamp": iso(report.generatedAt),
            ]
            return CLIResult(exitCode: exitCode, stdout: CLIJSON.string(object), stderr: stderr)
        }
        func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
        let evidence = report.evidence
        let evidenceLine = report.staticChecked
            ? "\(evidence.count)/4 (K1 IOKit \(yesNo(evidence.ioKitLinked)), K2 CoreFoundation "
                + "\(yesNo(evidence.coreFoundationLinked)), K3 IORegistry \(yesNo(evidence.ioRegistryAccess)), "
                + "K4 IOPlatformSerialNumber \(yesNo(evidence.platformSerialString)))"
            : "not checked (\(report.processState.rawValue))"
        var lines = [
            "macOS hardware identity: \(report.state.rawValue) (\(report.finding.rawValue))"
                + (resolution.rejectedOverride != nil ? " [default fallback; requested override rejected: not a pass]" : ""),
            "uniqueness:      not verified (static indicators only)",
            "process state:   \(report.processState.rawValue)",
            "static support:  \(report.staticSupport.rawValue)"
                + (report.capabilityFailure.map { " (\($0.rawValue))" } ?? ""),
            "evidence:        \(evidenceLine)",
            "raw state:       \(report.rawState?.rawValue ?? "not read (\(report.processState.rawValue))")",
            "CID (masked):    \(report.cidMasked ?? "-")",
        ]
        if let requestedPath {
            let verdict = !resolution.validated ? "not validated (\(report.processState.rawValue))"
                : resolution.rejectedOverride.map { "REJECTED (\($0.rawValue))" } ?? "accepted"
            lines.append("requested engine: \(requestedPath) — \(verdict)")
        }
        lines += [
            "engine:          \(enginePath)" + (resolution.rejectedOverride != nil ? " (default fallback)"
                : resolution.validated ? "" : " (not validated: \(report.processState.rawValue))"),
            "engine physical: \(physicalPath ?? "not resolved (\(report.processState.rawValue))")",
            "package:         \(report.packageReadability?.rawValue ?? "not checked")",
            "engine hash:     \(report.engineHashShort ?? "-")",
            "engine running:  \(report.processState == .unavailable ? "unknown" : yesNo(report.engineRunning))",
            "engine version:  \(report.engineVersion ?? "-") (informational; not used for the decision)",
            "app version:     \(context.version)",
            "timestamp:       \(iso(report.generatedAt))",
            "next step:       \(nextStep(report, resolution: resolution))",
            "note:            no random identity change: the engine derives the identity from this Mac's hardware",
        ]
        if report.rawState == .zero {
            lines.insert("warning:         the raw identity is zero; every Mac with a zero identity shares the same CID",
                         at: 6)
        }
        return CLIResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n", stderr: stderr)
    }

    static func nextStep(_ report: MacIdentityReport, resolution: EnginePathResolution? = nil) -> String {
        if let rejected = resolution?.rejectedOverride {
            return "fix or unset the engine override (\(rejected.rawValue)): \(CLIContext.engineAppEnvironmentKey) or "
                + "Settings > Data > Engine app"
        }
        switch report.finding {
        case .healthy:
            return "none (indicators found; uniqueness is not directly verified)"
        case .nonzeroWithoutEvidence:
            return "no static hardware-identity verification for this engine; a compatible engine is recommended: "
                + EngineDownloadLink.url.absoluteString
        case .zero, .notGenerated:
            return "quit the engine, use \"Regenerate Identity\" in the app (or open the engine once), quit it, check again"
        case .unsupported:
            return "install a compatible engine: \(EngineDownloadLink.url.absoluteString)"
        case .engineNotFound:
            return "install the engine or set \(CLIContext.engineAppEnvironmentKey) to its .app"
        case .engineUnverifiable:
            return "check the engine path and its permissions (\(CLIContext.engineAppEnvironmentKey) or Settings > Data > "
                + "Engine app) and retry"
        case .identityUnreadable:
            return "check the permissions and format of the .xash_id files, then retry"
        case .engineRunning:
            return "quit the engine and run this check again"
        case .processUnavailable:
            return "the engine process state could not be verified; retry (nothing was scanned or read)"
        }
    }
}

/// `~`-abbreviated path (the CLI cannot use the app's view helpers).
enum CLIPath {
    static func abbreviated(_ path: String, home: URL) -> String {
        let prefix = home.standardizedFileURL.path
        guard path == prefix || path.hasPrefix(prefix + "/") else { return path }
        return "~" + path.dropFirst(prefix.count)
    }
}

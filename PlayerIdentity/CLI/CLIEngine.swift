import Foundation

// §74 `playeridentityctl engine …`: the "Install Compatible Engine" feature from the command line (the app is the
// primary path, spec E0 D9).
//
//   engine status [--json]                    offline: engine process state, identity state, whether the install is
//                                             offered, the backup inventory. No network, no write.
//   engine install-compatible [--yes] [--json]
//                                             only for `unsupported` with the engine closed; asks y/N on a terminal
//                                             (the CID warning is part of the question), without one `--yes` is
//                                             required (else exit 1 before any network call). Progress: one JSON
//                                             object per line with --json (last line = result). The engine is never
//                                             opened: the identity is verified later with `diagnose --macos-identity`.
//   engine backups [--json]                   the backup inventory (newest 3 kept) and the confirmation code
//   engine backups delete --confirm <code> [--json]
//                                             deletes the older backups when the code still names the inventory
//
// Exit codes (install): 0 installed (identity verification pending), 1 usage error / no confirmation without a
// terminal, 2 failed (nothing changed, or the rollback could not be verified: critical), 3 cancelled / declined /
// rolled back, 4 not offered (not `unsupported`, Intel Mac, rejected override). status/backups: 0 ok, 1 usage,
// 2 read or delete error (also a partial deletion or a stale code). Raw identity and full CID are never printed;
// only masked CIDs.

extension CLIExit {
    static let engineInstalled: Int32 = 0
    static let engineFailed: Int32 = 2
    static let engineCancelled: Int32 = 3
    static let engineNotOffered: Int32 = 4
}

extension CLIJSON {
    /// One compact line (JSON lines output).
    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}\n"
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Collects the progress events of one install (called from the installer's task).
private final class CLIEngineProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineInstallProgress] = []
    private var lastPercent = -1

    func record(_ progress: EngineInstallProgress) {
        lock.withLock {
            if progress.phase == .downloading, progress.total > 0 {
                // Bytes every 10 % (the first and the last one included), not every chunk.
                let percent = Int(Double(progress.bytes) / Double(progress.total) * 100)
                guard percent / 10 != lastPercent / 10 || progress.bytes == progress.total || lastPercent < 0 else { return }
                lastPercent = percent
            }
            if let last = events.last, last == progress { return }
            events.append(progress)
        }
    }

    var all: [EngineInstallProgress] { lock.withLock { events } }
}

extension CLIRunner {
    /// Inputs of the identity check shared with `diagnose --macos-identity`.
    struct EngineCheck {
        let check: MacIdentityCheck
        let home: URL
        let dataRoot: URL
        let gamedir: String?
    }

    /// Process state first, then (only with the engine closed) the override validation, scan and identity read.
    /// `nil` when cancelled.
    static func engineCheck(context: CLIContext) async -> EngineCheck? {
        let home = context.identityHome
        let snapshot = SnapshotStore(fileURL: context.snapshotURL).load().snapshot
        let dataRoot = snapshot.flatMap { $0.dataRoot.isEmpty ? nil : URL(fileURLWithPath: $0.dataRoot, isDirectory: true) }
            ?? AppPaths(home: home).defaultDataRoot
        let gamedir = snapshot.flatMap { $0.gamedir.isEmpty ? nil : $0.gamedir }
        let gamedirURL = gamedir.map { dataRoot.appendingPathComponent($0, isDirectory: true) }
        let override = context.engineAppOverride
        let roots = EnginePaths.forbiddenRoots(home: home, dataRoot: dataRoot)
        let checker = MacIdentityChecker(files: context.fileProbe, detector: context.gameProcessDetector,
                                         home: home, now: context.clock, clock: context.monotonicClock)
        let scan = Task.detached { checker.check(override: override, forbiddenRoots: roots, gamedir: gamedirURL) }
        let check = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled, check.report.capabilityFailure != .cancelled else { return nil }
        return EngineCheck(check: check, home: home, dataRoot: dataRoot, gamedir: gamedir)
    }

    private static func engineEnvironment(_ engine: EngineCheck, context: CLIContext) -> EngineInstallEnvironment {
        var environment = EngineInstallEnvironment.make(targetApp: engine.check.report.engineApp, dataRoot: engine.dataRoot,
                                                        gamedir: engine.gamedir, paths: context.paths,
                                                        architecture: context.engineArchitecture)
        environment = EngineInstallEnvironment(targetApp: environment.targetApp, dataRoot: environment.dataRoot,
                                               gamedir: environment.gamedir, home: engine.home,
                                               paths: environment.paths, architecture: environment.architecture)
        return environment
    }

    /// Why the install is not offered (`nil` = offered).
    static func engineInstallBlock(_ engine: EngineCheck, architecture: EngineArchitecture) -> String? {
        let report = engine.check.report
        if let rejected = engine.check.resolution.rejectedOverride { return "overrideRejected:" + rejected.rawValue }
        switch report.processState {
        case .running: return "engineRunning"
        case .unavailable: return "processUnavailable"
        case .notRunning: break
        }
        guard EngineInstallEligibility.isOffered(report) else { return "notOffered:" + report.finding.rawValue }
        if let failure = EngineInstallCapability.check(architecture) { return failure.code }
        return nil
    }

    // MARK: engine status

    static func engineStatus(json: Bool, context: CLIContext) async -> CLIResult {
        guard let engine = await engineCheck(context: context) else {
            return failure("cancelled", "the check was cancelled", command: "engine status", json: json,
                           code: CLIExit.engineFailed)
        }
        let report = engine.check.report
        let block = engineInstallBlock(engine, architecture: context.engineArchitecture)
        let store = EngineBackupStore(root: context.paths.engineBackupsDirectory, files: context.engineFileOperations)
        let inventory = try? store.inventory()
        let home = context.paths.home
        let backupPath = CLIPath.abbreviated(store.root.path, home: home)
        if json {
            let object: [String: Any] = [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "engine status", "network": false,
                "architecture": context.engineArchitecture.rawValue,
                "install_enabled_for_architecture": EngineInstallCapability.check(context.engineArchitecture) == nil,
                "process_state": report.processState.rawValue,
                "state": report.state.rawValue, "finding": report.finding.rawValue,
                "static_support": report.staticSupport.rawValue,
                "raw_state": report.rawState?.rawValue ?? NSNull(),
                "cid_masked": EngineInstallPrivacy.strictMasked(report.cidMasked) ?? NSNull(),
                "engine_path": CLIPath.abbreviated(report.engineApp.path, home: home),
                "install_offered": block == nil,
                "install_blocked_reason": block ?? NSNull(),
                "release_source": EngineReleaseSource.releasePageURL.absoluteString,
                "backups": [
                    "location": backupPath,
                    "count": inventory?.groups.count ?? NSNull(),
                    "prune_candidates": inventory?.pruneCandidates.count ?? NSNull(),
                    "readable": inventory != nil,
                ] as [String: Any],
                "uniqueness_verified": false,
            ]
            return CLIResult(exitCode: CLIExit.ok, stdout: CLIJSON.string(object), stderr: "")
        }
        let lines = [
            "engine:          \(CLIPath.abbreviated(report.engineApp.path, home: home))",
            "architecture:    \(context.engineArchitecture.rawValue)"
                + (EngineInstallCapability.check(context.engineArchitecture) == nil ? "" : " (install closed on Intel)"),
            "process state:   \(report.processState.rawValue)",
            "identity:        \(report.state.rawValue) (\(report.finding.rawValue))",
            "CID (masked):    \(EngineInstallPrivacy.strictMasked(report.cidMasked) ?? "-")",
            "install offered: " + (block.map { "no (\($0))" } ?? "yes: playeridentityctl engine install-compatible"),
            "backups:         " + (inventory.map { "\($0.groups.count) (\($0.pruneCandidates.count) older can be deleted)" }
                                    ?? "not readable") + " in \(backupPath)",
            "network:         none (status is offline)",
        ]
        return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: engine install-compatible

    static func engineInstallCompatible(yes: Bool, json: Bool, context: CLIContext) async -> CLIResult {
        let command = "engine install-compatible"
        // No confirmation possible: refuse before anything is read from the network (AC-E2b).
        guard yes || context.prompt.isInteractive else {
            return failure("notConfirmed", "no terminal to confirm on; pass --yes to accept the install and the CID "
                           + "warning", command: command, json: json, code: CLIExit.usage)
        }
        guard let engine = await engineCheck(context: context) else {
            return failure("cancelled", "the check was cancelled", command: command, json: json,
                           code: CLIExit.engineCancelled)
        }
        if let block = engineInstallBlock(engine, architecture: context.engineArchitecture) {
            let code = block == "engineRunning" || block == "processUnavailable" ? CLIExit.engineFailed
                : CLIExit.engineNotOffered
            return failure(block, "the compatible engine install is not offered (\(block)); see "
                           + "playeridentityctl engine status", command: command, json: json, code: code)
        }
        let environment = engineEnvironment(engine, context: context)
        let installer = context.engineInstallerFactory(environment)
        let release: EngineRelease
        switch await installer.fetchRelease() {
        case .success(let value): release = value
        case .failure(.cancelled):
            return failure("cancelled", "cancelled", command: command, json: json, code: CLIExit.engineCancelled)
        case .failure(let failure):
            return self.failure(failure.code, "the release details could not be read (\(failure.code)); nothing was "
                                + "downloaded or changed", command: command, json: json, code: CLIExit.engineFailed)
        }
        let cidBefore = EngineInstallPrivacy.strictMasked(engine.check.report.cidMasked)
        let summary = EngineInstallPlanSummary(release: release, environment: environment, cidMasked: cidBefore)
        let summaryText = engineSummaryText(summary, home: context.paths.home)
        if !yes {
            let accepted = context.prompt.ask(summaryText + "Install the compatible engine and accept the CID warning? [y/N] ")
            guard accepted else {
                return failure("notConfirmed", "not confirmed; nothing was downloaded or changed", command: command,
                               json: json, code: CLIExit.engineCancelled)
            }
        }
        // The engine may have been opened while the question was on screen.
        let state = context.gameProcessDetector.engineProcessState()
        guard state == .notRunning else {
            let code = state == .running ? "engineRunning" : "processUnavailable"
            return failure(code, "the engine process state is \(state.rawValue); nothing was changed", command: command,
                           json: json, code: CLIExit.engineFailed)
        }
        let progress = CLIEngineProgressLog()
        let result = await installer.install(release, confirmation: EngineInstallConfirmation(acceptedCIDWarning: true,
                                                                                            cidBefore: cidBefore)) {
            progress.record($0)
        }
        let exitCode = engineExitCode(result.outcome)
        let failureCode = engineFailure(result.outcome)?.code
        let home = context.paths.home
        let report = result.report
        if json {
            var output = ""
            for event in progress.all {
                output += CLIJSON.line(["stage": event.phase.rawValue, "bytes": event.bytes, "total": event.total,
                                        "error": NSNull(), "cidBefore": cidBefore ?? NSNull(), "cidAfter": NSNull()])
            }
            let object: [String: Any] = [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": command,
                "stage": result.outcome.phase.rawValue, "outcome": engineOutcomeName(result.outcome),
                "error": failureCode ?? NSNull(), "exit": exitCode,
                "bytes": release.asset.size, "total": release.asset.size,
                "cidBefore": cidBefore ?? NSNull(), "cidAfter": NSNull(),
                "identity_verification": result.outcome == .installed ? "pending" : "notApplicable",
                "supported": false,
                "release": ["tag": release.tag, "prerelease": release.prerelease, "commit": release.commitSHA,
                            "asset": release.asset.name, "size": release.asset.size, "digest": release.asset.digest,
                            "html_url": release.htmlURL.absoluteString] as [String: Any],
                "engine_path": CLIPath.abbreviated(environment.targetApp.path, home: home),
                "backup": report.backup.map { CLIPath.abbreviated($0.root.path, home: home) + " (" + $0.stamp + ")" }
                    ?? NSNull(),
                "updated_libraries": report.updatedLibraries, "restored_libraries": report.restoredLibraries,
                "skipped_libraries": report.skippedLibraries.map { $0.path + " (" + $0.reason.rawValue + ")" },
                "quarantine_failures": report.quarantineFailures,
                "identity_files_changed": report.identityFilesChanged,
                "leftovers": report.leftovers.map { CLIPath.abbreviated($0, home: home) },
                "next_step": engineNextStep(result.outcome),
            ]
            output += CLIJSON.line(object)
            return CLIResult(exitCode: exitCode, stdout: output, stderr: "")
        }
        var lines = yes ? [summaryText.trimmingCharacters(in: .newlines)] : []
        lines += progress.all.map { "stage:           \($0.phase.rawValue)"
            + ($0.phase == .downloading && $0.total > 0 ? " \($0.bytes)/\($0.total) bytes" : "") }
        lines.append("result:          \(engineOutcomeName(result.outcome))" + (failureCode.map { " (\($0))" } ?? ""))
        if let backup = report.backup {
            lines.append("backup:          \(CLIPath.abbreviated(backup.root.path, home: home)) (\(backup.stamp))")
        }
        if !report.skippedLibraries.isEmpty {
            lines.append("unchanged libs:  " + report.skippedLibraries.map { "\($0.path) (\($0.reason.rawValue))" }
                .joined(separator: ", "))
        }
        if !report.quarantineFailures.isEmpty {
            lines.append("quarantine:      not removed from " + report.quarantineFailures.joined(separator: ", "))
        }
        if report.identityFilesChanged {
            lines.append("identity files:  changed during the install (not undone)")
        }
        if !report.leftovers.isEmpty {
            lines.append("leftovers:       " + report.leftovers.map { CLIPath.abbreviated($0, home: home) }
                .joined(separator: ", "))
        }
        lines.append("CID (masked):    before \(cidBefore ?? "-"); after: not verified yet")
        lines.append("next step:       \(engineNextStep(result.outcome))")
        let text = lines.joined(separator: "\n") + "\n"
        return exitCode == CLIExit.engineInstalled
            ? CLIResult(exitCode: exitCode, stdout: text, stderr: "")
            : CLIResult(exitCode: exitCode, stdout: text, stderr: "playeridentityctl: \(command): "
                        + "\(engineOutcomeName(result.outcome))" + (failureCode.map { " (\($0))" } ?? "") + "\n")
    }

    /// The confirmation text (also the y/N question): release, files, backup, masked CID and the CID warning.
    static func engineSummaryText(_ summary: EngineInstallPlanSummary, home: URL) -> String {
        let release = summary.release
        var lines = [
            "source:          FWGS/xash3d-fwgs, continuous (prerelease; its content can change)",
            "commit:          \(release.commitSHA)",
            "asset:           \(release.asset.name) (\(release.asset.size) bytes, \(release.asset.digest))",
            "engine:          \(CLIPath.abbreviated(summary.targetApp.path, home: home))",
            "changes:         the engine app and the 2 game libraries of the active game folder; identity files are "
                + "only backed up",
        ]
        lines += summary.gameLibraries.map { "                 \(CLIPath.abbreviated($0.path, home: home))" }
        lines += [
            "backup:          \(CLIPath.abbreviated(summary.backupRoot.path, home: home))",
            "CID (masked):    \(summary.cidMasked ?? "none")",
            "WARNING:         This update may create a new identity (CID). A ban or account record on a server may "
                + "not match the new identity.",
            "after install:   open the engine once, quit it at the main menu, then run "
                + "playeridentityctl diagnose --macos-identity",
            "license:         Xash3D-FWGS (GPL) — source: \(release.commitURL.absoluteString)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func engineExitCode(_ outcome: EngineInstallOutcome) -> Int32 {
        switch outcome {
        case .installed: return CLIExit.engineInstalled
        case .failed(.unsupportedArchitecture): return CLIExit.engineNotOffered
        case .failed, .rollbackIncomplete: return CLIExit.engineFailed
        case .rolledBack, .cancelled: return CLIExit.engineCancelled
        }
    }

    static func engineFailure(_ outcome: EngineInstallOutcome) -> EngineInstallFailure? {
        switch outcome {
        case .failed(let failure), .rolledBack(let failure), .rollbackIncomplete(let failure): return failure
        case .installed, .cancelled: return nil
        }
    }

    static func engineOutcomeName(_ outcome: EngineInstallOutcome) -> String {
        switch outcome {
        case .installed: return "installed"
        case .failed: return "failed"
        case .rolledBack: return "rolledBack"
        case .rollbackIncomplete: return "rollbackIncomplete"
        case .cancelled: return "cancelled"
        }
    }

    static func engineNextStep(_ outcome: EngineInstallOutcome) -> String {
        switch outcome {
        case .installed:
            return "open the engine once, quit it at the main menu, then run playeridentityctl diagnose --macos-identity "
                + "(if macOS blocks it: System Settings > Privacy & Security > Open Anyway, for this app only)"
        case .failed(.permissionDenied):
            return "administrator permission required: /Applications is not writable"
        case .failed:
            return "nothing was changed; fix the reason and try again"
        case .rolledBack:
            return "the previous engine was put back and verified against the backup; try again later"
        case .rollbackIncomplete:
            return "CRITICAL: the rollback could not be verified; restore the engine from the backup by hand"
        case .cancelled:
            return "nothing was changed"
        }
    }

    // MARK: engine backups

    static func engineBackups(json: Bool, context: CLIContext) -> CLIResult {
        let store = EngineBackupStore(root: context.paths.engineBackupsDirectory, files: context.engineFileOperations)
        let location = CLIPath.abbreviated(store.root.path, home: context.paths.home)
        let inventory: EngineBackupInventory
        do {
            inventory = try store.inventory()
        } catch {
            let code = (error as? EngineInstallFailure)?.code ?? "backupFailed"
            return failure(code, "the engine backups could not be read (\(code))", command: "engine backups", json: json,
                           code: CLIExit.engineFailed)
        }
        let kept = Set(inventory.kept.map(\.stamp))
        let code = inventory.pruneCandidates.isEmpty ? nil : EngineBackupStore.confirmationCode(for: inventory)
        if json {
            let object: [String: Any] = [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "engine backups", "location": location,
                "keep": EngineBackupInventory.keepCount,
                "backups": inventory.groups.map { ["stamp": $0.stamp, "kept": kept.contains($0.stamp),
                                                   "items": $0.items.count, "manifest": $0.hasManifest] as [String: Any] },
                "prune_candidates": inventory.pruneCandidates.map(\.stamp),
                "confirmation_code": code ?? NSNull(),
            ]
            return CLIResult(exitCode: CLIExit.ok, stdout: CLIJSON.string(object), stderr: "")
        }
        var lines = ["location: \(location) (newest \(EngineBackupInventory.keepCount) kept)"]
        lines += inventory.groups.map { "\($0.stamp)  \(kept.contains($0.stamp) ? "kept" : "older")" }
        if inventory.groups.isEmpty { lines.append("no backups") }
        if let code {
            lines.append("delete the \(inventory.pruneCandidates.count) older: playeridentityctl engine backups delete "
                         + "--confirm \(code)")
        }
        return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    static func engineBackupsDelete(confirm code: String, json: Bool, context: CLIContext) -> CLIResult {
        let command = "engine backups delete"
        let store = EngineBackupStore(root: context.paths.engineBackupsDirectory, files: context.engineFileOperations)
        guard let inventory = try? store.inventory() else {
            return failure("backupFailed", "the engine backups could not be read", command: command, json: json,
                           code: CLIExit.engineFailed)
        }
        let token: EngineBackupDeletionToken
        switch store.confirmDeletion(code: code, in: inventory) {
        case .success(let value): token = value
        case .failure(let failure):
            return self.failure(failure.code, "the code does not match the current backups (or there is nothing to "
                                + "delete); run playeridentityctl engine backups again", command: command, json: json,
                                code: CLIExit.engineFailed)
        }
        switch store.deleteBackups(token) {
        case .failure(let failure):
            return self.failure(failure.code, "nothing was deleted (\(failure.code))", command: command, json: json,
                                code: CLIExit.engineFailed)
        case .success(let report):
            let exitCode = report.status == .success ? CLIExit.ok : CLIExit.engineFailed
            if json {
                let object: [String: Any] = [
                    "schemaVersion": CLIContext.jsonSchemaVersion, "command": command,
                    "status": report.status.rawValue, "removed": report.removed,
                    "failed": report.failed.mapValues(\.rawValue),
                ]
                return CLIResult(exitCode: exitCode, stdout: CLIJSON.string(object), stderr: "")
            }
            var lines = ["removed: \(report.removed.isEmpty ? "-" : report.removed.joined(separator: ", "))"]
            if !report.failed.isEmpty {
                lines.append("FAILED (records kept): " + report.failed.keys.sorted()
                    .map { "\($0) (\(report.failed[$0]!.rawValue))" }.joined(separator: ", "))
            }
            return CLIResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n",
                             stderr: report.status == .success ? "" : "playeridentityctl: partial failure\n")
        }
    }
}

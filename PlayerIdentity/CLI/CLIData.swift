import Foundation

// §52 data commands of `playeridentityctl`: `backup`, `restore`, `servers list|add|remove` and `diagnostics`. They use
// the app's Core (FullBackupStore / FullBackupParser, SnapshotStore, ServerURLImport, DiagnosticsBundle) and never
// touch the network. Exit codes: 0 ok, 1 usage or not confirmed, 2 validation or write error, 3 not found (no data,
// no record, no such server, already added).

extension CLIExit {
    /// §52: a backup, record or file did not pass validation, or could not be written.
    static let validation: Int32 = 2
    /// §52: nothing to back up, no saved record, no such server / file, or the server is already in the list.
    static let notFound: Int32 = 3
}

extension CLIRunner {
    // MARK: backup

    static func backup(out: String?, json: Bool, context: CLIContext) -> CLIResult {
        let now = context.now()
        let target: URL
        switch outputURL(out, defaultName: FullBackupNaming.manualFileName(now: now), context: context) {
        case .success(let url): target = url
        case .failure(let failure): return failure.result(command: "backup", json: json)
        }
        let manifest: FullBackupManifest
        do {
            manifest = try FullBackupStore(paths: context.paths, appVersion: context.version).write(to: target, now: now)
        } catch let error as FullBackupError {
            let described = describe(error)
            return failure(described.code, described.message, command: "backup", json: json, code: described.exitCode)
        } catch {
            return failure("writeFailed", "the backup could not be written to \(target.path) (\(error.localizedDescription))",
                           command: "backup", json: json, code: CLIExit.validation)
        }
        let counts = manifest.counts
        if json {
            return success(json: [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "backup", "path": target.path,
                "createdAt": iso(manifest.createdAt), "appVersion": manifest.appVersion,
                "counts": countsJSON(counts), "files": manifest.files.map(\.name),
                "skipped": manifest.warnings.map(skippedJSON), "complete": manifest.warnings.isEmpty,
            ])
        }
        var lines = [
            "backup: \(target.path)",
            "servers: \(counts.servers), history entries: \(counts.historyEntries), metric samples: \(counts.metricSamples)",
            "files: " + manifest.files.map(\.name).joined(separator: ", "),
        ]
        if !manifest.warnings.isEmpty {
            lines.append("warning: \(manifest.warnings.count) file(s) skipped, this backup is incomplete: "
                         + manifest.warnings.map(skippedText).joined(separator: ", "))
        }
        return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: restore

    static func restore(path: String, yes: Bool, json: Bool, context: CLIContext) -> CLIResult {
        let url = fileURL(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return failure("notFound", "no such file: \(url.path)", command: "restore", json: json, code: CLIExit.notFound)
        }
        let backup: ParsedFullBackup
        switch FullBackupParser.read(url) {
        case .success(let value): backup = value
        case .failure(let error):
            let described = describe(error)
            return failure(described.code, described.message, command: "restore", json: json, code: described.exitCode)
        }
        let preview = FullBackupPreview.make(backup, currentVersion: context.version)
        // Without --yes the answer must come from a terminal; scripts are refused before anything is changed.
        guard yes || context.prompt.isInteractive else {
            return failure("confirmationRequired", "restore needs a terminal to confirm, or --yes",
                           command: "restore", json: json, code: CLIExit.usage)
        }
        if !yes {
            var question = "Restore the backup of \(iso(preview.createdAt)) (Player Identity \(preview.appVersion), "
                + "\(preview.counts.servers) servers, \(preview.counts.historyEntries) history entries, "
                + "\(preview.counts.metricSamples) metric samples) over the current data?"
            if !preview.missingFiles.isEmpty {
                question += " The current " + preview.missingFiles.joined(separator: ", ") + " will be removed."
            }
            question += " The current data is backed up first. [y/N] "
            guard context.prompt.ask(question) else {
                return failure("declined", "not confirmed; nothing restored", command: "restore", json: json,
                               code: CLIExit.usage)
            }
        }
        let store = FullBackupStore(paths: context.paths, appVersion: context.version)
        let safety: FullBackupStore.Created
        do {
            safety = try store.createBackup(.preRestore, now: context.now())
        } catch {
            let described = describe(.preRestoreBackupFailed(error.localizedDescription))
            return failure(described.code, described.message, command: "restore", json: json, code: described.exitCode)
        }
        let kept: URL?
        do {
            kept = try store.restore(backup, keepPrevious: !safety.skipped.isEmpty)
        } catch {
            let described = describe(error as? FullBackupError ?? .writeFailed(error.localizedDescription))
            return failure(described.code, described.message, command: "restore", json: json, code: described.exitCode)
        }
        if json {
            return success(json: [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "restore", "path": url.path, "restored": true,
                "backup": [
                    "createdAt": iso(preview.createdAt), "appVersion": preview.appVersion,
                    "recordSavedAt": preview.recordSavedAt.map(iso) ?? NSNull(),
                    "compatibility": compatibilityText(preview.compatibility), "counts": countsJSON(preview.counts),
                    "missingFiles": preview.missingFiles,
                ] as [String: Any],
                "preRestoreBackup": safety.url?.path ?? NSNull(), "keptPrevious": kept?.path ?? NSNull(),
            ])
        }
        var lines = [
            "restored \(url.path) (backup of \(iso(preview.createdAt)), \(preview.counts.servers) servers)",
            "previous data: \(safety.url?.path ?? "none (there was no data to back up)")",
        ]
        if let kept { lines.append("files the pre-restore backup could not include: \(kept.path)") }
        lines.append("reopen Player Identity if it is running")
        return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: servers

    static func serversList(json: Bool, context: CLIContext) -> CLIResult {
        let snapshot: Snapshot
        switch loadRecord(command: "servers", json: json, context: context) {
        case .success(let value): snapshot = value
        case .failure(let failure): return failure.result
        }
        if json {
            return success(json: [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "servers", "action": "list",
                "snapshot": context.snapshotURL.path,
                "servers": snapshot.servers.enumerated().map { serverJSON($1, index: $0 + 1) },
            ])
        }
        guard !snapshot.servers.isEmpty else {
            return CLIResult(exitCode: CLIExit.ok, stdout: "no servers in \(context.snapshotURL.path)\n", stderr: "")
        }
        let lines = snapshot.servers.enumerated().map { offset, entry in
            var parts = ["\(offset + 1)", entry.label, address(entry)]
            if let group = entry.group { parts.append("group: \(group)") }
            if entry.watch { parts.append("watch") }
            parts.append("ban: " + (entry.banCheck?.status.rawValue ?? "not checked"))
            return parts.joined(separator: "  ")
        }
        return CLIResult(exitCode: CLIExit.ok, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    static func serversAdd(entry text: String, label: String?, group: String?, watch: Bool, json: Bool,
                           context: CLIContext) -> CLIResult {
        var snapshot: Snapshot
        switch loadRecord(command: "servers", json: json, context: context) {
        case .success(let value): snapshot = value
        case .failure(let failure): return failure.result
        }
        let candidate: ServerURLImport.Candidate
        switch ServerURLImport.parseEntry(text) {
        case .success(let value): candidate = value
        case .failure(let reason):
            let described = describe(reason)
            return failure(described.code, "invalid server \(text): \(described.message)", command: "servers", json: json,
                           code: CLIExit.validation)
        }
        if let index = snapshot.servers.firstIndex(where: { matches($0, candidate) }) {
            return failure("alreadyExists", "\(candidate.id) is already in the list (index \(index + 1))",
                           command: "servers", json: json, code: CLIExit.notFound)
        }
        let entry = ServerEntry(label: label ?? candidate.label, host: candidate.host, port: candidate.port,
                                group: ServerOrganization.resolveGroup(group, existing: ServerOrganization.groups(snapshot.servers)),
                                order: ServerOrganization.nextOrder(snapshot.servers), watch: watch)
        snapshot.servers.append(entry)
        let backup: URL?
        switch saveRecord(snapshot, command: "servers", json: json, context: context) {
        case .success(let url): backup = url
        case .failure(let failure): return failure.result
        }
        if json {
            return success(json: [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "servers", "action": "add",
                "snapshot": context.snapshotURL.path, "server": serverJSON(entry, index: snapshot.servers.count),
                "recordBackup": backup?.path ?? NSNull(),
            ])
        }
        return CLIResult(exitCode: CLIExit.ok,
                         stdout: "added \(snapshot.servers.count)  \(entry.label)  \(address(entry))\n"
                             + "reopen Player Identity if it is running\n",
                         stderr: "")
    }

    static func serversRemove(target: String, yes: Bool, json: Bool, context: CLIContext) -> CLIResult {
        var snapshot: Snapshot
        switch loadRecord(command: "servers", json: json, context: context) {
        case .success(let value): snapshot = value
        case .failure(let failure): return failure.result
        }
        let index: Int
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let number = Int(trimmed), number >= 1, number <= snapshot.servers.count else {
                return failure("serverNotFound", "no server with index \(trimmed) (the list has \(snapshot.servers.count))",
                               command: "servers", json: json, code: CLIExit.notFound)
            }
            index = number - 1
        } else {
            guard case .success(let candidate) = ServerURLImport.parseEntry(trimmed) else {
                return failure("invalidServer", "\(target) is neither an index nor a <host:port>", command: "servers",
                               json: json, code: CLIExit.usage)
            }
            let found = snapshot.servers.indices.filter { matches(snapshot.servers[$0], candidate) }
            guard let first = found.first else {
                return failure("serverNotFound", "\(candidate.id) is not in the list", command: "servers", json: json,
                               code: CLIExit.notFound)
            }
            guard found.count == 1 else {
                return failure("ambiguous", "\(candidate.id) is in the list \(found.count) times (indexes "
                               + found.map { String($0 + 1) }.joined(separator: ", ") + "); remove it by index",
                               command: "servers", json: json, code: CLIExit.usage)
            }
            index = first
        }
        let entry = snapshot.servers[index]
        guard yes || context.prompt.isInteractive else {
            return failure("confirmationRequired", "servers remove needs a terminal to confirm, or --yes",
                           command: "servers", json: json, code: CLIExit.usage)
        }
        if !yes {
            guard context.prompt.ask("Remove server \(index + 1) \(entry.label) (\(address(entry))) from the saved record? [y/N] ") else {
                return failure("declined", "not confirmed; nothing removed", command: "servers", json: json, code: CLIExit.usage)
            }
        }
        snapshot.servers.remove(at: index)
        let backup: URL?
        switch saveRecord(snapshot, command: "servers", json: json, context: context) {
        case .success(let url): backup = url
        case .failure(let failure): return failure.result
        }
        if json {
            return success(json: [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "servers", "action": "remove",
                "snapshot": context.snapshotURL.path, "removed": serverJSON(entry, index: index + 1),
                "recordBackup": backup?.path ?? NSNull(),
            ])
        }
        return CLIResult(exitCode: CLIExit.ok,
                         stdout: "removed \(index + 1)  \(entry.label)  \(address(entry))\n"
                             + "previous record: \(backup?.path ?? "-")\n"
                             + "reopen Player Identity if it is running\n",
                         stderr: "")
    }

    // MARK: diagnostics

    static func diagnostics(out: String?, json: Bool, context: CLIContext) -> CLIResult {
        let now = context.now()
        let target: URL
        switch outputURL(out, defaultName: DiagnosticsBundle.defaultFileName(now: now), context: context) {
        case .success(let url): target = url
        case .failure(let failure): return failure.result(command: "diagnostics", json: json)
        }
        let defaults = UserDefaults(suiteName: context.defaultsSuite) ?? .standard
        let system = DiagnosticsAppInfo.current()
        let info = DiagnosticsAppInfo(version: context.version, build: context.build, osVersion: system.osVersion,
                                      architecture: system.architecture, language: system.language)
        let input = DiagnosticsInput(appInfo: info, paths: context.paths, defaults: defaults, now: now)
        do {
            try DiagnosticsBundle.archive(input).write(to: target, options: .atomic)
        } catch {
            return failure("writeFailed", "the diagnostics package could not be written to \(target.path) "
                           + "(\(error.localizedDescription))", command: "diagnostics", json: json, code: CLIExit.validation)
        }
        if json {
            return success(json: [
                "schemaVersion": CLIContext.jsonSchemaVersion, "command": "diagnostics", "path": target.path,
                "files": DiagnosticsBundle.fileNames, "redacted": true,
            ])
        }
        return CLIResult(exitCode: CLIExit.ok,
                         stdout: "diagnostics: \(target.path)\nfiles: " + DiagnosticsBundle.fileNames.joined(separator: ", ")
                             + "\n(IP addresses and the home folder are masked)\n",
                         stderr: "")
    }

    // MARK: Helpers

    /// A usage or validation problem found before anything was written.
    struct OutputFailure: Error {
        let code: String
        let message: String
        let exitCode: Int32

        func result(command: String, json: Bool) -> CLIResult {
            CLIRunner.failure(code, message, command: command, json: json, code: exitCode)
        }
    }

    /// `--out <path>`: a folder gets the default name inside it; an existing file is never overwritten. Without
    /// `--out` the file goes to `~/Documents`.
    static func outputURL(_ out: String?, defaultName: String, context: CLIContext) -> Result<URL, OutputFailure> {
        var target: URL
        if let out {
            target = fileURL(out)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                target = target.appendingPathComponent(defaultName, isDirectory: false)
            }
        } else {
            target = context.paths.home.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(defaultName, isDirectory: false)
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(OutputFailure(code: "outputExists", message: "\(target.path) already exists; nothing written",
                                          exitCode: CLIExit.usage))
        }
        var isDirectory: ObjCBool = false
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(OutputFailure(code: "folderMissing", message: "no such folder: \(folder.path)",
                                          exitCode: CLIExit.validation))
        }
        return .success(target)
    }

    /// `~` expanded, relative to the working directory, standardized.
    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false).standardizedFileURL
    }

    /// The saved record of `servers` (`PLAYERIDENTITYCTL_SNAPSHOT` honoured); exit 3 without one, 2 if unreadable.
    private static func loadRecord(command: String, json: Bool, context: CLIContext) -> Result<Snapshot, CLIResultFailure> {
        let url = context.snapshotURL
        switch SnapshotStore(fileURL: url).load() {
        case .loaded(let snapshot):
            return .success(snapshot)
        case .missing:
            return .failure(CLIResultFailure(failure("snapshotMissing", "no saved record at \(url.path); open Player Identity and save first",
                                                     command: command, json: json, code: CLIExit.notFound)))
        case .corrupt:
            return .failure(CLIResultFailure(failure("snapshotCorrupt", "the saved record cannot be read: \(url.path)",
                                                     command: command, json: json, code: CLIExit.validation)))
        case .unsupportedSchema(let version):
            return .failure(CLIResultFailure(failure("snapshotUnsupported", "the saved record has schema \(version), this tool reads 1",
                                                     command: command, json: json, code: CLIExit.validation)))
        }
    }

    /// Copies the record to `profile.json.appbak-<time>`, then writes the edited one atomically.
    private static func saveRecord(_ snapshot: Snapshot, command: String, json: Bool,
                                   context: CLIContext) -> Result<URL?, CLIResultFailure> {
        let url = context.snapshotURL
        let backup: URL?
        do {
            backup = try recordCopy(of: url, at: context.now())
        } catch {
            return .failure(CLIResultFailure(failure("recordBackupFailed", "the record could not be copied before the change "
                                                     + "(\(error.localizedDescription)); nothing changed",
                                                     command: command, json: json, code: CLIExit.validation)))
        }
        var edited = snapshot
        edited.savedAt = context.now()
        do {
            try SnapshotStore(fileURL: url).save(edited)
        } catch {
            return .failure(CLIResultFailure(failure("writeFailed", "the record could not be written: \(url.path) "
                                                     + "(\(error.localizedDescription))",
                                                     command: command, json: json, code: CLIExit.validation)))
        }
        return .success(backup)
    }

    /// `profile.json.appbak-<time>` like the settings import (§46), but an existing copy is never replaced: several
    /// edits in the same second get `-2`, `-3`, … so every previous state is kept.
    static func recordCopy(of file: URL, at date: Date) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let base = RecordBackup.backupURL(for: file, at: date)
        var target = base
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-\(number)",
                                                                             isDirectory: false)
            number += 1
        }
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    private static func matches(_ entry: ServerEntry, _ candidate: ServerURLImport.Candidate) -> Bool {
        HostValidator.normalized(entry.host) == candidate.host && entry.port == candidate.port
    }

    private static func address(_ entry: ServerEntry) -> String {
        entry.host.contains(":") ? "[\(entry.host)]:\(entry.port)" : "\(entry.host):\(entry.port)"
    }

    private static func serverJSON(_ entry: ServerEntry, index: Int) -> [String: Any] {
        ["index": index, "id": entry.id.uuidString, "label": entry.label, "host": entry.host, "port": entry.port,
         "group": entry.group ?? NSNull(), "favorite": entry.favorite, "watch": entry.watch, "order": entry.order,
         "cid": entry.cid, "ban": entry.banCheck?.status.rawValue ?? NSNull()]
    }

    private static func countsJSON(_ counts: FullBackupManifest.Counts) -> [String: Any] {
        ["servers": counts.servers, "historyEntries": counts.historyEntries, "metricSamples": counts.metricSamples,
         "watchedServers": counts.watchedServers]
    }

    private static func skippedJSON(_ skipped: FullBackupManifest.SkippedFile) -> [String: Any] {
        ["file": skipped.file, "reason": skipped.reason.rawValue, "lines": skipped.lines ?? NSNull()]
    }

    private static func skippedText(_ skipped: FullBackupManifest.SkippedFile) -> String {
        skipped.file + " (" + skipped.reason.rawValue + (skipped.lines.map { ", \($0) lines" } ?? "") + ")"
    }

    private static func compatibilityText(_ compatibility: FullBackupPreview.Compatibility) -> String {
        switch compatibility {
        case .sameVersion: return "sameVersion"
        case .olderVersion: return "olderVersion"
        case .newerVersion: return "newerVersion"
        }
    }

    /// Stable code, English message and exit code of a backup / restore error.
    static func describe(_ error: FullBackupError) -> (code: String, message: String, exitCode: Int32) {
        let invalid = CLIExit.validation
        switch error {
        case .nothingToBackUp: return ("nothingToBackUp", "there is no app data to back up", CLIExit.notFound)
        case .noUsableData(let files):
            return ("noUsableData", "no data file could be read (" + files.joined(separator: ", ") + "); no backup was made",
                    invalid)
        case .unreadableArchive: return ("unreadableArchive", "the file is not a readable backup ZIP", invalid)
        case .tooLarge: return ("tooLarge", "the backup is larger than \(FullBackupParser.maxArchiveBytes) bytes", invalid)
        case .unexpectedEntry(let name): return ("unexpectedEntry", "the backup contains an unexpected file: \(name)", invalid)
        case .missingManifest: return ("missingManifest", "the backup has no manifest.json", invalid)
        case .corruptManifest: return ("corruptManifest", "the manifest does not match the backup", invalid)
        case .unsupportedSchema(let version):
            return ("unsupportedSchema", "the backup has schema \(version), this version reads 1", invalid)
        case .corruptFile(let name): return ("corruptFile", "\(name) in the backup is damaged", invalid)
        case .unsupportedRecordSchema(let version):
            return ("unsupportedRecordSchema", "the record in the backup has schema \(version), this version reads 1", invalid)
        case .updateRunning: return ("updateRunning", "an update is running", invalid)
        case .busy: return ("busy", "another data operation is running", invalid)
        case .preRestoreBackupFailed(let reason):
            return ("preRestoreBackupFailed", "the current data could not be backed up (\(reason)); nothing restored", invalid)
        case .saveFailed(let reason): return ("saveFailed", "saving failed (\(reason)); nothing restored", invalid)
        case .writeFailed(let reason):
            return ("writeFailed", "the files could not be put in place (\(reason)); the current data is unchanged", invalid)
        case .rollbackFailed(let staging, let reason):
            return ("rollbackFailed", "the restore could not be completed (\(reason)); the previous files are in "
                    + staging.path, invalid)
        }
    }

    /// Stable code and English message of an import rule (§50) that rejected a server.
    static func describe(_ reason: ServerURLImport.Reason) -> (code: String, message: String) {
        switch reason {
        case .unsupportedURL: return ("unsupportedURL", "unsupported link format")
        case .ipv6NeedsBrackets: return ("ipv6NeedsBrackets", "IPv6 addresses need brackets: [address]:port")
        case .hostInvalid: return ("hostInvalid", "not an IP address or host name")
        case .portInvalid: return ("portInvalid", "the port must be 1 to 65535")
        }
    }
}

/// A finished error result carried through `Result` (the command returns it as is).
struct CLIResultFailure: Error {
    let result: CLIResult

    init(_ result: CLIResult) {
        self.result = result
    }
}

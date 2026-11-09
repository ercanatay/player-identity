import Darwin
import Foundation

// MARK: - Messages (§15.8)

enum EditMessage: String, Error, Sendable, CaseIterable {
    case nameInvalid
    case modelInvalid
    case gameRunning
    case writeFailed
    case configMissing
    /// §43.1: nothing to remove / `userconfig.cfg` unreadable.
    case overrideMissing

    var text: String {
        switch self {
        case .nameInvalid: return L10n.text(.editNameInvalid)
        case .modelInvalid: return L10n.text(.editModelInvalid)
        case .gameRunning: return L10n.text(.editGameRunning)
        case .writeFailed: return L10n.text(.editWriteFailed)
        case .configMissing: return L10n.text(.editConfigMissing)
        case .overrideMissing: return L10n.text(.editOverrideMissing)
        }
    }
}

// MARK: - Validation (§15.5)

enum PlayerValueValidator {
    static let maxNameLength = 31
    static let maxModelLength = 32

    /// Valid name with leading/trailing whitespace trimmed; `nil` if invalid.
    static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard (1...maxNameLength).contains(trimmed.count), trimmed.utf8.count <= maxNameLength else { return nil }
        let forbidden = trimmed.unicodeScalars.contains { scalar in
            scalar == "\"" || scalar == "\\" || scalar == "\n" || scalar == "\r"
                || scalar.properties.generalCategory == .control
        }
        return forbidden ? nil : trimmed
    }

    /// 1…32 characters; only `A-Z a-z 0-9 _ -`.
    static func isValidModel(_ value: String) -> Bool {
        guard (1...maxModelLength).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
            default: return false
            }
        }
    }
}

// MARK: - Dropdown options (§15.3, §15.4)

struct ModelOption: Sendable, Equatable, Hashable {
    let value: String
    let label: String
    /// §43.2 where the folder was found; empty for the "current" placeholder row.
    var sources: [ModelSource] = []

    /// Tooltip text: "Source: Local, Downloaded"; `nil` without sources.
    var sourceTooltip: String? {
        sources.isEmpty ? nil : L10n.format(.modelSourceTooltip, sources.map(\.label).joined(separator: ", "))
    }
}

enum PlayerOptions {
    static let recentNamesLimit = 10

    /// Folder names; if the current model is not listed, it is prepended with a "current" marker.
    static func modelOptions(available: [String], current: String,
                             sources: [String: [ModelSource]] = [:]) -> [ModelOption] {
        var options = available.map { ModelOption(value: $0, label: $0, sources: sources[$0] ?? []) }
        if !current.isEmpty, !available.contains(current) {
            options.insert(ModelOption(value: current, label: L10n.format(.profileModelCurrent, current)), at: 0)
        }
        return options
    }

    /// Current name, saved name, recently used names (deduplicated, blanks excluded).
    static func nameOptions(current: String, saved: String?, recent: [String]) -> [String] {
        var seen = Set<String>()
        return ([current, saved ?? ""] + recent.prefix(recentNamesLimit)).filter { name in
            guard !name.isEmpty, !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
    }

    /// Puts the new name first; deduplicated, at most 10.
    static func updatedRecentNames(_ recent: [String], adding name: String) -> [String] {
        Array(([name] + recent.filter { $0 != name }).prefix(recentNamesLimit))
    }
}

// MARK: - Byte-level editor (§15.6)

/// Changes only the target key's value; the rest of the file is preserved byte for byte.
/// Line matching rules are the same as `ConfigParser.parseLine`.
enum ConfigEditor {
    struct Line: Equatable {
        var body: [UInt8]
        /// `[]`, `\n` or `\r\n`
        var ending: [UInt8]
    }

    static let lf: [UInt8] = [0x0A]
    static let crlf: [UInt8] = [0x0D, 0x0A]

    static func split(_ bytes: [UInt8]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            var end = index
            var ending = lf
            if end > start, bytes[end - 1] == 0x0D {
                end -= 1
                ending = crlf
            }
            lines.append(Line(body: Array(bytes[start..<end]), ending: ending))
            start = index + 1
        }
        if start < bytes.count { lines.append(Line(body: Array(bytes[start...]), ending: [])) }
        return lines
    }

    static func join(_ lines: [Line]) -> [UInt8] {
        lines.flatMap { $0.body + $0.ending }
    }

    /// Dominant line ending; LF on a tie or when there is none.
    static func dominantEnding(_ lines: [Line]) -> [UInt8] {
        let crlfCount = lines.filter { $0.ending == crlf }.count
        let lfCount = lines.filter { $0.ending == lf }.count
        return crlfCount > lfCount ? crlf : lf
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C
    }

    /// Byte range of the value if the line has the form `key ...` (quotes included when quoted).
    static func valueRange(in body: [UInt8], key: String) -> Range<Int>? {
        let keyBytes = Array(key.utf8)
        var index = 0
        while index < body.count, isBlank(body[index]) { index += 1 }
        let keyStart = index
        while index < body.count, !isBlank(body[index]) { index += 1 }
        guard Array(body[keyStart..<index]) == keyBytes, index < body.count else { return nil }
        while index < body.count, isBlank(body[index]) { index += 1 }
        let valueStart = index
        if index < body.count, body[index] == 0x22 {
            if let closing = body[(index + 1)...].firstIndex(of: 0x22) {
                return valueStart..<(closing + 1)
            }
            return valueStart..<body.count
        }
        var end = body.count
        while end > valueStart, isBlank(body[end - 1]) { end -= 1 }
        return valueStart..<end
    }

    static func contains(_ key: String, in bytes: [UInt8]) -> Bool {
        split(bytes).contains { valueRange(in: $0.body, key: key) != nil }
    }

    /// Sets every occurrence of the key to `key "value"`.
    static func set(_ key: String, to value: String, in bytes: [UInt8]) -> [UInt8] {
        var lines = split(bytes)
        let quoted = [0x22] + Array(value.utf8) + [0x22]
        for index in lines.indices {
            guard let range = valueRange(in: lines[index].body, key: key) else { continue }
            lines[index].body.replaceSubrange(range, with: quoted)
        }
        return join(lines)
    }

    /// Appends a `key "value"` line at the end of the file (with the dominant line ending).
    static func append(_ key: String, value: String, to bytes: [UInt8]) -> [UInt8] {
        let lines = split(bytes)
        let ending = dominantEnding(lines)
        var output = bytes
        if let last = lines.last, last.ending.isEmpty { output += ending }
        output += Array("\(key) \"\(value)\"".utf8) + ending
        return output
    }
}

// MARK: - Game process detection

protocol GameProcessDetecting: Sendable {
    func isGameRunning() -> Bool
}

/// Process name starting with `xash3d` (case-insensitive).
struct SystemGameProcessDetector: GameProcessDetecting {
    init() {}

    func isGameRunning() -> Bool {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if String(decoding: bytes, as: UTF8.self).lowercased().hasPrefix("xash3d") { return true }
        }
        return false
    }
}

// MARK: - Writer (§15.2, §15.6)

struct ApplyOutcome: Sendable, Equatable {
    /// Changed files, `config.cfg` first.
    let changedFiles: [ConfigFileKind]

    var summary: String { changedFiles.map(\.fileName).joined(separator: " + ") }
}

/// Writes only the `name` / `model` lines. Atomic; a `<file>.appbak` backup for every changed file.
struct PlayerConfigWriter: Sendable {
    static let backupSuffix = ".appbak"

    let detector: any GameProcessDetecting

    /// File contents before and after the edit; computed without writing anything.
    struct Plan: Sendable, Equatable {
        let configURL: URL
        let userURL: URL
        let configOriginal: [UInt8]
        let configBytes: [UInt8]
        let userOriginal: [UInt8]?
        let userBytes: [UInt8]?

        /// §24: changed lines per file, `config.cfg` first; empty if nothing would change.
        var diffs: [ConfigFileDiff] {
            var result: [ConfigFileDiff] = []
            if configBytes != configOriginal {
                result.append(ConfigFileDiff(file: .config, lines: ConfigDiff.lines(old: configOriginal, new: configBytes)))
            }
            if let userOriginal, let userBytes, userBytes != userOriginal {
                result.append(ConfigFileDiff(file: .userconfig, lines: ConfigDiff.lines(old: userOriginal, new: userBytes)))
            }
            return result.filter { !$0.lines.isEmpty }
        }
    }

    /// If `name` / `model` is `nil`, that key is not written.
    func apply(gamedir: URL, name: String?, model: String?) throws -> ApplyOutcome {
        let changes = try Self.validatedChanges(name: name, model: model)
        if detector.isGameRunning() { throw EditMessage.gameRunning }
        let plan = try Self.plan(gamedir: gamedir, changes: changes)

        var changed: [ConfigFileKind] = []
        do {
            if plan.configBytes != plan.configOriginal {
                try Self.write(plan.configBytes, to: plan.configURL, original: plan.configOriginal)
                changed.append(.config)
            }
            if let userBytes = plan.userBytes, let userOriginal = plan.userOriginal, userBytes != userOriginal {
                try Self.write(userBytes, to: plan.userURL, original: userOriginal)
                changed.append(.userconfig)
            }
        } catch {
            throw EditMessage.writeFailed
        }
        return ApplyOutcome(changedFiles: changed)
    }

    /// §24 preview: the same edit as `apply`, without writing. Throws the same validation errors.
    func preview(gamedir: URL, name: String?, model: String?) throws -> Plan {
        try Self.plan(gamedir: gamedir, changes: Self.validatedChanges(name: name, model: model))
    }

    private static func validatedChanges(name: String?, model: String?) throws -> [(key: String, value: String)] {
        var changes: [(key: String, value: String)] = []
        if let name {
            guard let normalized = PlayerValueValidator.normalizedName(name) else { throw EditMessage.nameInvalid }
            changes.append(("name", normalized))
        }
        if let model {
            guard PlayerValueValidator.isValidModel(model) else { throw EditMessage.modelInvalid }
            changes.append(("model", model))
        }
        return changes
    }

    private static func plan(gamedir: URL, changes: [(key: String, value: String)]) throws -> Plan {
        let fileManager = FileManager.default
        let configURL = gamedir.appendingPathComponent(ConfigFileKind.config.fileName, isDirectory: false)
        let userURL = gamedir.appendingPathComponent(ConfigFileKind.userconfig.fileName, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw EditMessage.configMissing
        }
        guard let configOriginal = try? Array(Data(contentsOf: configURL)) else { throw EditMessage.writeFailed }
        var userOriginal: [UInt8]?
        if fileManager.fileExists(atPath: userURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            guard let bytes = try? Array(Data(contentsOf: userURL)) else { throw EditMessage.writeFailed }
            userOriginal = bytes
        }

        var configBytes = configOriginal
        var userBytes = userOriginal
        for change in changes {
            let inUser = userBytes.map { ConfigEditor.contains(change.key, in: $0) } ?? false
            let inConfig = ConfigEditor.contains(change.key, in: configBytes)
            if inUser, let current = userBytes {
                userBytes = ConfigEditor.set(change.key, to: change.value, in: current)
            }
            if inConfig {
                configBytes = ConfigEditor.set(change.key, to: change.value, in: configBytes)
            }
            if !inUser, !inConfig {
                configBytes = ConfigEditor.append(change.key, value: change.value, to: configBytes)
            }
        }
        return Plan(configURL: configURL, userURL: userURL, configOriginal: configOriginal, configBytes: configBytes,
                    userOriginal: userOriginal, userBytes: userBytes)
    }

    /// First `<file>.appbak` (single, overwritten), then a temporary file in the same folder + `replaceItemAt`.
    private static func write(_ bytes: [UInt8], to url: URL, original: [UInt8]) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let backup = directory.appendingPathComponent(url.lastPathComponent + backupSuffix, isDirectory: false)
        try Data(original).write(to: backup, options: .atomic)

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp",
                                                         isDirectory: false)
        try Data(bytes).write(to: temporary)
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

// MARK: - userconfig.cfg override removal (§43.1)

struct OverrideRemoval: Sendable, Equatable {
    /// Keys whose lines were commented out, in `name`, `model` order.
    let keys: [String]
    let backupURL: URL
}

/// Comments out the `name` / `model` lines of `userconfig.cfg` (every occurrence of the key); nothing else changes.
struct UserconfigOverrideRemover: Sendable {
    let detector: any GameProcessDetecting
    let now: @Sendable () -> Date

    static func backupName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "userconfig.cfg.appbak-" + formatter.string(from: date)
    }

    func remove(gamedir: URL, keys: [String]) throws -> OverrideRemoval {
        if detector.isGameRunning() { throw EditMessage.gameRunning }
        let url = gamedir.appendingPathComponent(ConfigFileKind.userconfig.fileName, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let original = try? Array(Data(contentsOf: url)) else { throw EditMessage.overrideMissing }

        var lines = ConfigEditor.split(original)
        var removed: [String] = []
        for key in keys {
            var found = false
            for index in lines.indices where ConfigEditor.valueRange(in: lines[index].body, key: key) != nil {
                lines[index].body = Array("// ".utf8) + lines[index].body
                found = true
            }
            if found { removed.append(key) }
        }
        guard !removed.isEmpty else { throw EditMessage.overrideMissing }

        let directory = url.deletingLastPathComponent()
        let backup = directory.appendingPathComponent(Self.backupName(at: now()), isDirectory: false)
        do {
            try Data(original).write(to: backup, options: .atomic)
            let temporary = directory.appendingPathComponent(".userconfig.cfg.\(UUID().uuidString).tmp", isDirectory: false)
            try Data(ConfigEditor.join(lines)).write(to: temporary)
            do {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } catch {
            throw EditMessage.writeFailed
        }
        return OverrideRemoval(keys: removed, backupURL: backup)
    }
}

// MARK: - Diff (§24)

struct ConfigDiffLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case removed
        case added
    }

    let kind: Kind
    /// 1-based line number in the old file (removed) or the new file (added).
    let number: Int
    let text: String
}

struct ConfigFileDiff: Sendable, Equatable {
    let file: ConfigFileKind
    let lines: [ConfigDiffLine]
}

enum ConfigDiff {
    /// Line diff of an edit made by `ConfigEditor`: values change in place and new keys are appended,
    /// so lines are compared by position. A changed line yields `-` old then `+` new; line-ending-only
    /// changes (the missing final newline added before an append) are not shown.
    static func lines(old: [UInt8], new: [UInt8]) -> [ConfigDiffLine] {
        let before = ConfigEditor.split(old)
        let after = ConfigEditor.split(new)
        var result: [ConfigDiffLine] = []
        for index in 0..<max(before.count, after.count) {
            let oldLine = index < before.count ? before[index].body : nil
            let newLine = index < after.count ? after[index].body : nil
            guard oldLine != newLine else { continue }
            if let oldLine { result.append(ConfigDiffLine(kind: .removed, number: index + 1, text: ServerInfoParser.decode(oldLine))) }
            if let newLine { result.append(ConfigDiffLine(kind: .added, number: index + 1, text: ServerInfoParser.decode(newLine))) }
        }
        return result
    }
}

import Darwin
import Foundation

// MARK: - Messages (§15.8)

enum EditMessage: String, Error, Sendable, CaseIterable {
    case nameInvalid
    case modelInvalid
    case gameRunning
    case writeFailed
    case configMissing

    var text: String {
        switch self {
        case .nameInvalid: return L10n.text(.editNameInvalid)
        case .modelInvalid: return L10n.text(.editModelInvalid)
        case .gameRunning: return L10n.text(.editGameRunning)
        case .writeFailed: return L10n.text(.editWriteFailed)
        case .configMissing: return L10n.text(.editConfigMissing)
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
}

enum PlayerOptions {
    static let recentNamesLimit = 10

    /// Folder names; if the current model is not listed, it is prepended with a "current" marker.
    static func modelOptions(available: [String], current: String) -> [ModelOption] {
        var options = available.map { ModelOption(value: $0, label: $0) }
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

    /// If `name` / `model` is `nil`, that key is not written.
    func apply(gamedir: URL, name: String?, model: String?) throws -> ApplyOutcome {
        var changes: [(key: String, value: String)] = []
        if let name {
            guard let normalized = PlayerValueValidator.normalizedName(name) else { throw EditMessage.nameInvalid }
            changes.append(("name", normalized))
        }
        if let model {
            guard PlayerValueValidator.isValidModel(model) else { throw EditMessage.modelInvalid }
            changes.append(("model", model))
        }
        if detector.isGameRunning() { throw EditMessage.gameRunning }

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

        var changed: [ConfigFileKind] = []
        do {
            if configBytes != configOriginal {
                try Self.write(configBytes, to: configURL, original: configOriginal)
                changed.append(.config)
            }
            if let userBytes, let userOriginal, userBytes != userOriginal {
                try Self.write(userBytes, to: userURL, original: userOriginal)
                changed.append(.userconfig)
            }
        } catch {
            throw EditMessage.writeFailed
        }
        return ApplyOutcome(changedFiles: changed)
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

import Darwin
import Foundation

// MARK: - Mesajlar (§15.8)

enum EditMessage: String, Error, Sendable, CaseIterable {
    case nameInvalid
    case modelInvalid
    case gameRunning
    case writeFailed
    case configMissing

    var text: String {
        switch self {
        case .nameInvalid: return "Kullanıcı adı 1–31 karakter olmalı; tırnak ve satır sonu kullanılamaz."
        case .modelInvalid: return "Model adı yalnız harf, rakam, alt çizgi ve tire içerebilir."
        case .gameRunning: return "Oyun açık. Değişiklikler çıkışta ezilir; önce oyunu kapatın."
        case .writeFailed: return "Dosya yazılamadı. Yedekten geri yüklemek için tekrar deneyin."
        case .configMissing: return "config.cfg bulunamadı; seçili gamedir doğru mu?"
        }
    }
}

// MARK: - Doğrulama (§15.5)

enum PlayerValueValidator {
    static let maxNameLength = 31
    static let maxModelLength = 32

    /// Baş/son boşluk kırpılmış geçerli ad; geçersizse `nil`.
    static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard (1...maxNameLength).contains(trimmed.count), trimmed.utf8.count <= maxNameLength else { return nil }
        let forbidden = trimmed.unicodeScalars.contains { scalar in
            scalar == "\"" || scalar == "\\" || scalar == "\n" || scalar == "\r"
                || scalar.properties.generalCategory == .control
        }
        return forbidden ? nil : trimmed
    }

    /// 1…32 karakter; yalnız `A-Z a-z 0-9 _ -`.
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

// MARK: - Dropdown seçenekleri (§15.3, §15.4)

struct ModelOption: Sendable, Equatable, Hashable {
    let value: String
    let label: String
}

enum PlayerOptions {
    static let recentNamesLimit = 10

    /// Klasör adları; mevcut model listede yoksa başa "(mevcut)" ile eklenir.
    static func modelOptions(available: [String], current: String) -> [ModelOption] {
        var options = available.map { ModelOption(value: $0, label: $0) }
        if !current.isEmpty, !available.contains(current) {
            options.insert(ModelOption(value: current, label: "\(current) (mevcut)"), at: 0)
        }
        return options
    }

    /// Mevcut ad, kayıttaki ad, son kullanılan adlar (tekrarsız, boşlar hariç).
    static func nameOptions(current: String, saved: String?, recent: [String]) -> [String] {
        var seen = Set<String>()
        return ([current, saved ?? ""] + recent.prefix(recentNamesLimit)).filter { name in
            guard !name.isEmpty, !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
    }

    /// Yeni adı en başa koyar; tekrarsız, en fazla 10.
    static func updatedRecentNames(_ recent: [String], adding name: String) -> [String] {
        Array(([name] + recent.filter { $0 != name }).prefix(recentNamesLimit))
    }
}

// MARK: - Bayt düzeyinde düzenleyici (§15.6)

/// Yalnız hedef anahtarın değerini değiştirir; dosyanın kalanı bayt bayt korunur.
/// Satır eşleştirme kuralları `ConfigParser.parseLine` ile aynıdır.
enum ConfigEditor {
    struct Line: Equatable {
        var body: [UInt8]
        /// `[]`, `\n` veya `\r\n`
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

    /// Baskın satır sonu; eşitlikte veya hiç yoksa LF.
    static func dominantEnding(_ lines: [Line]) -> [UInt8] {
        let crlfCount = lines.filter { $0.ending == crlf }.count
        let lfCount = lines.filter { $0.ending == lf }.count
        return crlfCount > lfCount ? crlf : lf
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C
    }

    /// Satır `key ...` biçimindeyse değerin bayt aralığı (tırnaklıysa tırnaklar dahil).
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

    /// Anahtarın tüm geçişlerini `key "value"` yapar.
    static func set(_ key: String, to value: String, in bytes: [UInt8]) -> [UInt8] {
        var lines = split(bytes)
        let quoted = [0x22] + Array(value.utf8) + [0x22]
        for index in lines.indices {
            guard let range = valueRange(in: lines[index].body, key: key) else { continue }
            lines[index].body.replaceSubrange(range, with: quoted)
        }
        return join(lines)
    }

    /// Dosya sonuna `key "value"` satırı ekler (baskın satır sonuyla).
    static func append(_ key: String, value: String, to bytes: [UInt8]) -> [UInt8] {
        let lines = split(bytes)
        let ending = dominantEnding(lines)
        var output = bytes
        if let last = lines.last, last.ending.isEmpty { output += ending }
        output += Array("\(key) \"\(value)\"".utf8) + ending
        return output
    }
}

// MARK: - Oyun süreci tespiti

protocol GameProcessDetecting: Sendable {
    func isGameRunning() -> Bool
}

/// `xash3d` ile başlayan süreç adı (büyük/küçük harf duyarsız).
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

// MARK: - Yazıcı (§15.2, §15.6)

struct ApplyOutcome: Sendable, Equatable {
    /// Değişen dosyalar, `config.cfg` önce.
    let changedFiles: [ConfigFileKind]

    var summary: String { changedFiles.map(\.fileName).joined(separator: " + ") }
}

/// Yalnız `name` / `model` satırlarını yazar. Atomik; her değişen dosya için `<dosya>.appbak` yedeği.
struct PlayerConfigWriter: Sendable {
    static let backupSuffix = ".appbak"

    let detector: any GameProcessDetecting

    /// `name` / `model` `nil` ise o anahtar yazılmaz.
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

    /// Önce `<dosya>.appbak` (tek, üzerine yazılır), sonra aynı klasörde geçici dosya + `replaceItemAt`.
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

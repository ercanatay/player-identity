import Darwin
import Foundation

// MARK: - §41 Diagnostics package

/// Masks IP addresses (IPv4 `a.b.x.x`, IPv6 first two groups kept) and the home folder path in texts.
struct Redactor: Sendable {
    let homePath: String?

    init(home: URL? = nil) {
        homePath = home.map { $0.standardizedFileURL.path }.flatMap { $0.count > 1 ? $0 : nil }
    }

    static func mask(_ address: ServerAddress) -> String {
        switch address {
        case .ipv4(let b): return "\(b[0]).\(b[1]).x.x"
        case .ipv6(let b):
            return String(Int(b[0]) << 8 | Int(b[1]), radix: 16) + ":" + String(Int(b[2]) << 8 | Int(b[3]), radix: 16) + "::x"
        case .localMachine: return ""
        }
    }

    /// Every IP-literal token in the text is masked; other text is kept (dates, UUIDs, CIDs are not IPs).
    func text(_ value: String) -> String {
        var source = value
        if let homePath, source.contains(homePath) { source = source.replacingOccurrences(of: homePath, with: "~") }
        var result = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            var core = token
            var trailing = ""
            while let last = core.last, last == "." || last == ":" {
                trailing.insert(last, at: trailing.startIndex)
                core.removeLast()
            }
            if let address = ServerAddress.parse(core) {
                result += Self.mask(address) + trailing
            } else {
                result += token
            }
            token = ""
        }
        for character in source {
            if character.isHexDigit || character == "." || character == ":" {
                token.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// Applies `text` to every string inside a JSON value.
    func json(_ value: Any) -> Any {
        switch value {
        case let string as String: return text(string)
        case let array as [Any]: return array.map(json)
        case let dictionary as [String: Any]: return dictionary.mapValues(json)
        default: return value
        }
    }

    /// Redacts a JSON document; `nil` if it is not JSON.
    func jsonData(_ data: Data, pretty: Bool) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try? JSONSerialization.data(withJSONObject: json(object), options: options)
    }
}

/// `app-info.json` content.
struct DiagnosticsAppInfo: Sendable, Equatable {
    var version: String
    var build: String
    var osVersion: String
    var architecture: String
    var language: String

    static func current(bundle: Bundle = .main) -> DiagnosticsAppInfo {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return DiagnosticsAppInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: machine,
            language: L10n.currentLanguage.rawValue)
    }
}

struct DiagnosticsInput {
    var appInfo: DiagnosticsAppInfo
    var paths: AppPaths
    var defaults: UserDefaults
    var now: Date
    var historyTail = 200
    var metricsTail = 500
    /// §54: the app's error log (`errors.json`); empty outside the app (e.g. the CLI).
    var errors: [ErrorLogEntry] = []
}

enum DiagnosticsBundle {
    static let fileNames = ["app-info.json", "snapshot.redacted.json", "history.tail.jsonl", "metrics.tail.jsonl",
                            "update-state.json", "errors.json"]

    /// File name offered in the save panel, e.g. `PlayerIdentity-diagnostics-20261109-1033.zip`.
    static func defaultFileName(now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "PlayerIdentity-diagnostics-\(formatter.string(from: now)).zip"
        return name
    }

    /// The files of the package (`fileNames`); nothing is written to disk.
    static func entries(_ input: DiagnosticsInput) -> [ZipEntry] {
        let redactor = Redactor(home: input.paths.home)
        let iso = ISO8601DateFormatter()
        func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                ?? Data("{}".utf8)
        }

        let info = input.appInfo
        let appInfo = json(["app": "PlayerIdentity", "version": info.version, "build": info.build, "os": info.osVersion,
                            "architecture": info.architecture, "language": info.language,
                            "generatedAt": iso.string(from: input.now)])

        let snapshot: Data
        if let raw = try? Data(contentsOf: input.paths.snapshotFile) {
            snapshot = redactor.jsonData(raw, pretty: true) ?? json(["state": "corrupt"])
        } else {
            snapshot = json(["state": "missing"])
        }

        let state = UpdateState(defaults: input.defaults)
        let preferences = UpdatePreferences(defaults: input.defaults)
        let updateState = json([
            "lastCheck": state.lastCheck.map(iso.string(from:)) ?? NSNull(),
            "latestVersion": state.latest?.version ?? NSNull(),
            "latestURL": state.latest?.url.absoluteString ?? NSNull(),
            "ignoredVersion": state.ignoredVersion ?? NSNull(),
            "autoCheck": preferences.autoCheck,
            "autoDownload": preferences.autoDownload,
        ])

        return [
            ZipEntry(name: fileNames[0], data: appInfo),
            ZipEntry(name: fileNames[1], data: snapshot),
            ZipEntry(name: fileNames[2], data: tail(input.paths.historyFile, lines: input.historyTail, redactor: redactor)),
            ZipEntry(name: fileNames[3], data: tail(input.paths.metricsFile, lines: input.metricsTail, redactor: redactor)),
            ZipEntry(name: fileNames[4], data: updateState),
            ZipEntry(name: fileNames[5], data: ErrorLog.diagnosticsJSON(input.errors, redactor: redactor)),
        ]
    }

    static func archive(_ input: DiagnosticsInput) -> Data {
        ZipArchive.make(entries(input), modified: input.now)
    }

    /// Last `lines` JSON lines, each redacted; unreadable lines are left out.
    static func tail(_ url: URL, lines: Int, redactor: Redactor) -> Data {
        guard let data = try? Data(contentsOf: url) else { return Data() }
        var result = Data()
        for line in data.split(separator: UInt8(ascii: "\n")).suffix(lines) {
            guard let redacted = redactor.jsonData(Data(line), pretty: false) else { continue }
            result.append(redacted)
            result.append(UInt8(ascii: "\n"))
        }
        return result
    }
}

// MARK: - Minimal ZIP writer (stored, no compression)

struct ZipEntry: Sendable, Equatable {
    let name: String
    let data: Data
}

enum ZipArchive {
    /// A ZIP archive with the entries stored uncompressed (readable by Finder, `unzip`, `ditto`).
    static func make(_ entries: [ZipEntry], modified: Date, calendar: Calendar = .current) -> Data {
        let (time, date) = dosDateTime(modified, calendar: calendar)
        var archive = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = UInt32(archive.count)
            // Local file header
            archive.append(le32: 0x0403_4B50)
            archive.append(le16: 20)          // version needed
            archive.append(le16: 0x0800)      // UTF-8 names
            archive.append(le16: 0)           // stored
            archive.append(le16: time)
            archive.append(le16: date)
            archive.append(le32: crc)
            archive.append(le32: UInt32(entry.data.count))
            archive.append(le32: UInt32(entry.data.count))
            archive.append(le16: UInt16(name.count))
            archive.append(le16: 0)
            archive.append(name)
            archive.append(entry.data)
            // Central directory record
            central.append(le32: 0x0201_4B50)
            central.append(le16: 0x031E)      // made by: Unix, 3.0
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: 0)
            central.append(le16: time)
            central.append(le16: date)
            central.append(le32: crc)
            central.append(le32: UInt32(entry.data.count))
            central.append(le32: UInt32(entry.data.count))
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)           // extra
            central.append(le16: 0)           // comment
            central.append(le16: 0)           // disk
            central.append(le16: 0)           // internal attributes
            central.append(le32: UInt32(0o100644) << 16)   // -rw-r--r--
            central.append(le32: offset)
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32: 0x0605_4B50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count))
        archive.append(le16: UInt16(entries.count))
        archive.append(le32: UInt32(central.count))
        archive.append(le32: centralOffset)
        archive.append(le16: 0)
        return archive
    }

    /// Reads back a stored (uncompressed) archive written by `make`; `nil` for anything else.
    static func read(_ data: Data) -> [ZipEntry]? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var entries: [ZipEntry] = []
        var position = 0
        while position + 30 <= bytes.count, u32(position) == 0x0403_4B50 {
            guard u16(position + 8) == 0 else { return nil }
            let size = u32(position + 18), nameLength = u16(position + 26), extraLength = u16(position + 28)
            let nameStart = position + 30, dataStart = nameStart + nameLength + extraLength
            guard dataStart + size <= bytes.count else { return nil }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            let content = Data(bytes[dataStart..<dataStart + size])
            guard CRC32.checksum(content) == UInt32(u32(position + 14)) else { return nil }
            entries.append(ZipEntry(name: name, data: content))
            position = dataStart + size
        }
        return entries
    }

    static func dosDateTime(_ date: Date, calendar: Calendar) -> (time: UInt16, date: UInt16) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((c.year ?? 1980) - 1980, 0)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

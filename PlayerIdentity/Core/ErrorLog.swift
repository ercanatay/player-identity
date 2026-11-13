import Foundation
import os

// MARK: - §54 Diagnostics error log

/// Where an app error happened (the `area` field of `errors.json`).
enum ErrorLogArea: String, Codable, Sendable, CaseIterable {
    case update
    case backup
    case metrics
    case watch
    case login
    /// §60: a menu bar copy did not reach the clipboard.
    case clipboard
}

struct ErrorLogEntry: Codable, Sendable, Equatable {
    var ts: Date
    var area: ErrorLogArea
    /// Technical text (an error code and its detail); redacted when written into the diagnostics package.
    var message: String
}

/// Whether the last write of the persisted error log worked (`errorLogStatus` of the diagnostics manifest).
enum ErrorLogStatus: String, Sendable, Equatable {
    case ok
    case writeFailed
}

/// Ring buffer of the last `capacity` app errors. With a `fileURL` it is persisted to `errors.json` (atomic write
/// after every record, loaded at start, oldest first); without one it lives in memory only. A write failure is never
/// shown to the user but is kept in `status` and reported in the diagnostics package. A missing file is created empty (`[]` list) at start;
/// a damaged file is ignored and overwritten by the first record.
final class ErrorLog: Sendable {
    static let capacity = 50
    /// Longest message kept (longer ones are cut).
    static let maxMessageLength = 1000

    private struct State {
        var entries: [ErrorLogEntry] = []
        var status = ErrorLogStatus.ok
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        // §54: a missing file is created empty at launch (an existing one, even a damaged one, is never touched here).
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            state.withLock { persist(&$0) }
            return
        }
        guard let data = try? Data(contentsOf: fileURL), let loaded = Self.decode(data) else { return }
        state.withLock { $0.entries = loaded }
    }

    func record(_ area: ErrorLogArea, _ message: String, at date: Date) {
        let text = String(message.prefix(Self.maxMessageLength))
        state.withLock { state in
            state.entries.append(ErrorLogEntry(ts: date, area: area, message: text))
            if state.entries.count > Self.capacity { state.entries.removeFirst(state.entries.count - Self.capacity) }
            persist(&state)
        }
    }

    /// Oldest first.
    var entries: [ErrorLogEntry] { state.withLock { $0.entries } }

    var status: ErrorLogStatus { state.withLock { $0.status } }

    /// Empties the log and removes the file.
    func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.status = .ok
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    private func persist(_ state: inout State) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(state.entries).write(to: fileURL, options: .atomic)
            state.status = .ok
        } catch {
            state.status = .writeFailed
        }
    }

    private static func encode(_ entries: [ErrorLogEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(StoredLog(schemaVersion: 1, capacity: capacity, errors: entries))
    }

    /// `nil` for a damaged file; the newest `capacity` entries otherwise.
    private static func decode(_ data: Data) -> [ErrorLogEntry]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(StoredLog.self, from: data) else { return nil }
        return Array(stored.errors.suffix(capacity))
    }

    private struct StoredLog: Codable {
        var schemaVersion: Int
        var capacity: Int
        var errors: [ErrorLogEntry]
    }

    /// `errors.json` of the diagnostics package: `{schemaVersion, capacity, errors: [{ts, area, message}]}` with the
    /// messages redacted like every other file of the package.
    static func diagnosticsJSON(_ entries: [ErrorLogEntry], redactor: Redactor) -> Data {
        let iso = ISO8601DateFormatter()
        let errors: [[String: Any]] = entries.suffix(capacity).map { entry in
            ["ts": iso.string(from: entry.ts), "area": entry.area.rawValue, "message": redactor.text(entry.message)]
        }
        let object: [String: Any] = ["schemaVersion": 1, "capacity": capacity, "errors": errors]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }
}

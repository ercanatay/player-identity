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
}

struct ErrorLogEntry: Codable, Sendable, Equatable {
    var ts: Date
    var area: ErrorLogArea
    /// Technical text (an error code and its detail); redacted when written into the diagnostics package.
    var message: String
}

/// Ring buffer of the last `capacity` app errors, kept in memory only (never written to disk by itself). It is
/// read for the diagnostics package (`errors.json`); recording an error never shows anything to the user.
final class ErrorLog: Sendable {
    static let capacity = 50
    /// Longest message kept (longer ones are cut).
    static let maxMessageLength = 1000

    private let state = OSAllocatedUnfairLock(initialState: [ErrorLogEntry]())

    init() {}

    func record(_ area: ErrorLogArea, _ message: String, at date: Date) {
        let text = String(message.prefix(Self.maxMessageLength))
        state.withLock { entries in
            entries.append(ErrorLogEntry(ts: date, area: area, message: text))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
    }

    /// Oldest first.
    var entries: [ErrorLogEntry] { state.withLock { $0 } }

    func removeAll() {
        state.withLock { $0.removeAll() }
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

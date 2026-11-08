import Foundation

/// Parsing and formatting of the 16-character hex identity value (§3.1, §3.2).
enum HexID {
    /// Tolerates leading/trailing whitespace and newlines; `nil` unless exactly 16 hex characters.
    static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard bytes.count == 16, bytes.allSatisfy(isHexDigit) else { return nil }
        return UInt64(trimmed, radix: 16)
    }

    /// 16 uppercase hex characters (e.g. `0000000000000000`).
    static func format(_ value: UInt64) -> String {
        let hex = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "a")...UInt8(ascii: "f"),
             UInt8(ascii: "A")...UInt8(ascii: "F"):
            return true
        default:
            return false
        }
    }
}

/// Identity file location; priority order is the `allCases` order (§3.1).
enum IdentityLocation: String, CaseIterable, Sendable, Equatable {
    case homeConfig   // ~/.config/.xash_id
    case homeLocal    // ~/.local/.xash_id
    case home         // ~/.xash_id
    case gamedir      // <gamedir>/.xash_id

    static let homeMask: UInt64 = 0x1033_1C2D_CE4C_91DB
    static let gamedirMask: UInt64 = 0x7FFC_48FB_AC17_11F1

    /// §3.2 XOR mask.
    var mask: UInt64 {
        switch self {
        case .homeConfig, .homeLocal, .home: return Self.homeMask
        case .gamedir: return Self.gamedirMask
        }
    }
}

struct IdentitySource: Sendable, Equatable {
    let location: IdentityLocation
    let url: URL
}

struct Identity: Sendable, Equatable {
    let source: IdentitySource
    /// Value in the file.
    let fileValue: UInt64
    /// `fileValue XOR mask`.
    let rawID: UInt64

    /// Raw identity, 16 uppercase hex characters.
    var rawIDHex: String { HexID.format(rawID) }
    var isRawIDZero: Bool { rawID == 0 }

    static func rawID(fileValue: UInt64, location: IdentityLocation) -> UInt64 {
        fileValue ^ location.mask
    }
}

enum IdentityError: Error, Sendable, Equatable {
    /// No candidate file was found or readable.
    case missing
    /// At least one file was read but none contained a valid 16-hex value.
    case invalid
}

/// Reads identity files in priority order (§3.1). Read-only.
struct IdentityReader: Sendable {
    let fileSystem: any FileSystemReading
    let homeDirectory: URL

    init(fileSystem: any FileSystemReading = LocalFileSystem(), homeDirectory: URL) {
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
    }

    func candidates(gamedir: URL?) -> [IdentitySource] {
        var list: [IdentitySource] = [
            IdentitySource(location: .homeConfig,
                           url: homeDirectory.appendingPathComponent(".config/.xash_id", isDirectory: false)),
            IdentitySource(location: .homeLocal,
                           url: homeDirectory.appendingPathComponent(".local/.xash_id", isDirectory: false)),
            IdentitySource(location: .home,
                           url: homeDirectory.appendingPathComponent(".xash_id", isDirectory: false)),
        ]
        if let gamedir {
            list.append(IdentitySource(location: .gamedir,
                                       url: gamedir.appendingPathComponent(".xash_id", isDirectory: false)))
        }
        return list
    }

    /// The first readable and valid file is used.
    func read(gamedir: URL?) -> Result<Identity, IdentityError> {
        var sawInvalid = false
        for candidate in candidates(gamedir: gamedir) {
            guard fileSystem.isRegularFile(candidate.url),
                  let data = try? fileSystem.readData(candidate.url) else { continue }
            guard let text = String(data: data, encoding: .utf8),
                  let value = HexID.parse(text) else {
                sawInvalid = true
                continue
            }
            return .success(Identity(source: candidate,
                                     fileValue: value,
                                     rawID: Identity.rawID(fileValue: value, location: candidate.location)))
        }
        return .failure(sawInvalid ? .invalid : .missing)
    }
}

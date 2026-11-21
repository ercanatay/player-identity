import CryptoKit
import Darwin
import Foundation

// MARK: - v2.26 "Install Compatible Engine" (core models and policy)
//
// Installs the official upstream Xash3D-FWGS build (`FWGS/xash3d-fwgs`, release `continuous`) over the user's engine
// app, only after explicit confirmation, with full backups and an atomic swap that is rolled back on any failure. This
// file holds the pure parts (release metadata, archive policy, state machine, results, identity verification, log
// policy); `EngineInstallAdapters.swift` holds the system adapters, `EngineInstaller.swift` the orchestration and
// `EngineBackupStore.swift` the backup inventory. Nothing here returns the raw identity, the full CID or an identity
// checksum: only state labels and strictly masked CIDs leave this layer.

// MARK: Architecture

/// Target architecture of the engine build.
enum EngineArchitecture: String, Sendable, Equatable, CaseIterable {
    case arm64
    case amd64

    /// The exact upstream asset name.
    var assetName: String { "xash3d-fwgs-apple-\(rawValue).tar.xz" }

    /// Suffix of the game libraries built for this architecture (`client_<suffix>.dylib`).
    var gameLibrarySuffix: String { rawValue }

    /// The Mac's hardware: Apple Silicon (also when this process runs under Rosetta) is `arm64`, otherwise `amd64`.
    static func current() -> EngineArchitecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return status == 0 && value == 1 ? .arm64 : .amd64
    }
}

/// D5: Intel installs stay closed until the amd64 end-to-end gate (G3) passes.
enum EngineInstallCapability {
    static let amd64Enabled = false

    static func check(_ architecture: EngineArchitecture, amd64Enabled: Bool = amd64Enabled) -> EngineInstallFailure? {
        switch architecture {
        case .arm64: return nil
        case .amd64: return amd64Enabled ? nil : .unsupportedArchitecture
        }
    }
}

// MARK: Failures

/// The time-limited stages (AC-E19, AC-E76).
enum EngineInstallTimedStage: String, Sendable, Equatable, CaseIterable {
    case metadata
    case download
    case extraction
    case install
}

/// Why an install did not complete. Every partial failure maps to exactly one value (AC-E52).
enum EngineInstallFailure: Error, Sendable, Equatable {
    /// The Mac's architecture has no enabled install path (D5).
    case unsupportedArchitecture
    /// The CID warning was not accepted: nothing was downloaded or written (AC-E2a).
    case notConfirmed
    /// The release API could not be reached or answered with an error.
    case metadataUnavailable
    /// The release metadata is not the official `continuous` prerelease, or a field is missing/invalid (AC-E44*).
    case metadataInvalid
    /// A URL is not HTTPS.
    case insecureURL
    /// The asset URL in the metadata points to a host outside the allowlist.
    case hostNotAllowed(String)
    /// A redirect left the allowlist; the redirect guard refused it (AC-E83).
    case redirectRejected(String)
    /// An HTTPS URL on an allowed host that is not the exact expected URL (fork, other tag, other asset).
    case urlNotAllowed
    /// No asset with the exact name (AC-E12).
    case assetNotFound
    /// More than one asset with the exact name (AC-E12).
    case assetAmbiguous
    /// The asset has no `digest` (AC-E13).
    case digestMissing
    /// The `digest` is not `sha256:` + 64 lowercase hex characters (AC-E13).
    case digestInvalid
    /// The asset is larger than 100 MB or has no positive size (AC-E14).
    case sizeTooLarge
    /// The downloaded byte count differs from the API size (AC-E14).
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The SHA-256 of the downloaded bytes differs from the API digest (AC-E18).
    case digestMismatch
    /// The verified archive bytes changed between verification and use (AC-E73b).
    case archiveChanged
    case downloadFailed
    case timeout(EngineInstallTimedStage)
    /// The archive contains an absolute path, `..`, a link, a device/FIFO or an entry outside the exact allowlist
    /// (AC-E21, AC-E41). The value is a sanitized entry name.
    case unsafeArchive(String)
    /// A required engine file is missing from the archive (AC-E23).
    case missingExpectedFile(String)
    case extractionFailed
    /// A staged file does not match its upstream source byte for byte (AC-E25, AC-E46, AC-E74).
    case mixedBuild(String)
    /// The SDL2 framework cannot be rebuilt (a link target is missing) (AC-E28).
    case sdl2Reconstruction
    /// Signing or `codesign --verify --deep --strict` failed (AC-E29).
    case codesign
    /// The engine app is missing, not a plain `.app` bundle or does not have the expected layout.
    case targetInvalid(EnginePathError)
    /// The engine app lies inside a forbidden root (AC-E49).
    case forbiddenTarget
    /// A path component on the way to a write, rename or delete target is a link or not a folder (AC-E70). The value
    /// is the role of the path, never the path itself.
    case unsafePath(String)
    /// The target or a game library changed after the backup (AC-E78, AC-E90).
    case conflict
    /// Another install holds the target lock (AC-E89).
    case locked
    /// The lock file cannot be opened or locked (link, permission, path error) (AC-E89a).
    case lockUnavailable
    /// The volume cannot exchange two items atomically (`RENAME_SWAP`) (AC-E39).
    case atomicSwapUnsupported
    /// A parent folder is not writable (AC-E36, AC-E39). The value is the folder path.
    case permissionDenied(String)
    /// The engine is running (AC-E3, AC-E35).
    case engineRunning
    /// The engine process state could not be verified (AC-E4).
    case processUnavailable
    /// The backup could not be written or verified (AC-E38).
    case backupFailed
    /// The staged app could not be built.
    case stagingFailed
    /// Replacing the app or a game library failed.
    case installFailed
    /// Deleting backups needs an explicit confirmation token (AC-E40a).
    case confirmationRequired
    case cancelled

    /// Short code for the log (no paths, no identity data).
    var code: String {
        switch self {
        case .unsupportedArchitecture: return "unsupportedArchitecture"
        case .notConfirmed: return "notConfirmed"
        case .metadataUnavailable: return "metadataUnavailable"
        case .metadataInvalid: return "metadataInvalid"
        case .insecureURL: return "insecureURL"
        case .hostNotAllowed: return "hostNotAllowed"
        case .redirectRejected: return "security:redirectHost"
        case .urlNotAllowed: return "urlNotAllowed"
        case .assetNotFound: return "assetNotFound"
        case .assetAmbiguous: return "assetAmbiguous"
        case .digestMissing: return "digestMissing"
        case .digestInvalid: return "digestInvalid"
        case .sizeTooLarge: return "sizeTooLarge"
        case .sizeMismatch: return "sizeMismatch"
        case .digestMismatch: return "digestMismatch"
        case .archiveChanged: return "archiveChanged"
        case .downloadFailed: return "downloadFailed"
        case .timeout(let stage): return "timeout:" + stage.rawValue
        case .unsafeArchive: return "unsafeArchive"
        case .missingExpectedFile(let name): return "missingExpectedFile:" + name
        case .extractionFailed: return "extractionFailed"
        case .mixedBuild: return "mixedBuild"
        case .sdl2Reconstruction: return "sdl2Reconstruction"
        case .codesign: return "codesign"
        case .targetInvalid(let error): return "targetInvalid:" + error.rawValue
        case .forbiddenTarget: return "forbiddenTarget"
        case .unsafePath(let role): return "unsafePath:" + role
        case .conflict: return "conflict"
        case .locked: return "conflict:locked"
        case .lockUnavailable: return "conflict:lockUnavailable"
        case .atomicSwapUnsupported: return "atomicSwapUnsupported"
        case .permissionDenied: return "permissionDenied"
        case .engineRunning: return "engineRunning"
        case .processUnavailable: return "processUnavailable"
        case .backupFailed: return "backupFailed"
        case .stagingFailed: return "stagingFailed"
        case .installFailed: return "installFailed"
        case .confirmationRequired: return "confirmationRequired"
        case .cancelled: return "cancelled"
        }
    }
}

// MARK: Release source (D2, AC-E9, AC-E10)

enum EngineReleaseSource {
    static let tag = "continuous"
    /// The only API endpoint (30 s limit).
    static let apiURL = URL(string: "https://api.github.com/repos/FWGS/xash3d-fwgs/releases/tags/continuous")!
    static let apiHost = "api.github.com"
    /// The release page the metadata must name (`html_url`).
    static let releasePageURL = EngineDownloadLink.url
    static let downloadPrefix = "https://github.com/FWGS/xash3d-fwgs/releases/download/continuous/"
    static let commitPrefix = "https://github.com/FWGS/xash3d-fwgs/commit/"
    /// Hosts an asset download (and its redirects) may use.
    static let downloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com",
                                             "release-assets.githubusercontent.com"]
    /// AC-E14.
    static let maxAssetSize: Int64 = 100 * 1024 * 1024
    /// Upper bound of the release JSON.
    static let maxMetadataSize = 2 * 1024 * 1024

    /// The exact download URL of an asset of the `continuous` release.
    static func downloadURL(for assetName: String) -> URL {
        URL(string: downloadPrefix + assetName)!
    }

    /// Only the exact API URL.
    static func isAllowedAPI(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.absoluteString == apiURL.absoluteString
    }

    /// HTTPS, an allowlisted host, the default port and no credentials (asset URL and every redirect).
    static func checkDownloadHost(_ url: URL) -> EngineInstallFailure? {
        guard url.scheme?.lowercased() == "https" else { return .insecureURL }
        let host = url.host?.lowercased() ?? ""
        guard downloadHosts.contains(host), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            return .hostNotAllowed(host)
        }
        return nil
    }

    /// The asset URL itself must be the exact official URL (no fork, tag or name change).
    static func checkAssetURL(_ url: URL, assetName: String) -> EngineInstallFailure? {
        if let failure = checkDownloadHost(url) { return failure }
        return url.absoluteString == downloadURL(for: assetName).absoluteString ? nil : .urlNotAllowed
    }
}

// MARK: Release metadata

struct EngineReleaseAsset: Sendable, Equatable {
    let name: String
    let downloadURL: URL
    let size: Int64
    /// 64 lowercase hex characters (the API `digest` without the `sha256:` prefix), read on every install (AC-E13).
    let sha256: String

    var digest: String { "sha256:" + sha256 }
}

/// The selected upstream release (shown on the confirmation screen, AC-E2/AC-E15).
struct EngineRelease: Sendable, Equatable {
    let tag: String
    /// Always `true` for an accepted release (AC-E44b).
    let prerelease: Bool
    let htmlURL: URL
    /// The 40 lowercase hex commit of the release (`target_commitish`, AC-E44a).
    let commitSHA: String
    let architecture: EngineArchitecture
    let asset: EngineReleaseAsset

    var commitURL: URL { URL(string: EngineReleaseSource.commitPrefix + commitSHA)! }
}

enum EngineReleaseParser {
    /// Validates the release JSON and selects the exact asset for `architecture`. Any deviation fails closed.
    static func parse(_ data: Data, architecture: EngineArchitecture) -> Result<EngineRelease, EngineInstallFailure> {
        guard data.count <= EngineReleaseSource.maxMetadataSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.metadataInvalid)
        }
        guard object["tag_name"] as? String == EngineReleaseSource.tag,
              let html = object["html_url"] as? String,
              html == EngineReleaseSource.releasePageURL.absoluteString,
              let htmlURL = URL(string: html),
              strictBool(object["prerelease"]) == true,
              strictBool(object["draft"]) == false,
              let commit = object["target_commitish"] as? String, isHex(commit, count: 40),
              let assets = object["assets"] as? [[String: Any]] else {
            return .failure(.metadataInvalid)
        }

        let name = architecture.assetName
        let matches = assets.filter { $0["name"] as? String == name }
        guard !matches.isEmpty else { return .failure(.assetNotFound) }
        guard matches.count == 1, let asset = matches.first else { return .failure(.assetAmbiguous) }

        guard let sizeNumber = asset["size"] as? NSNumber, strictBool(sizeNumber) == nil,
              case let size = sizeNumber.int64Value, size > 0, size <= EngineReleaseSource.maxAssetSize else {
            return .failure(.sizeTooLarge)
        }
        guard let digestValue = asset["digest"], !(digestValue is NSNull) else { return .failure(.digestMissing) }
        guard let digest = digestValue as? String, let sha = parseDigest(digest) else { return .failure(.digestInvalid) }
        guard let urlText = asset["browser_download_url"] as? String, let url = URL(string: urlText) else {
            return .failure(.urlNotAllowed)
        }
        if let failure = EngineReleaseSource.checkAssetURL(url, assetName: name) { return .failure(failure) }

        return .success(EngineRelease(tag: EngineReleaseSource.tag, prerelease: true, htmlURL: htmlURL,
                                      commitSHA: commit, architecture: architecture,
                                      asset: EngineReleaseAsset(name: name, downloadURL: url, size: size,
                                                                sha256: sha)))
    }

    /// A JSON boolean only (`true`/`false`), never a number that bridges to `Bool`.
    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// `sha256:` + exactly 64 lowercase hex characters → the hex part.
    static func parseDigest(_ text: String) -> String? {
        let prefix = "sha256:"
        guard text.hasPrefix(prefix) else { return nil }
        let hex = String(text.dropFirst(prefix.count))
        return isHex(hex, count: 64) ? hex : nil
    }

    /// Exactly `count` lowercase hex characters.
    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

// MARK: Archive policy (E19.2, E19.3, E19.6)

/// Entry type as listed by `tar -tv` (first column).
enum EngineArchiveEntryType: String, Sendable, Equatable {
    case regular
    case directory
    case symbolicLink
    case hardLink
    case characterDevice
    case blockDevice
    case fifo
    case socket
    case unknown
}

struct EngineArchiveEntry: Sendable, Equatable {
    /// The name exactly as listed.
    let path: String
    let type: EngineArchiveEntryType
}

/// What the scan accepted: normalized relative paths (no leading `./`, no trailing `/`).
struct EngineArchivePlan: Sendable, Equatable {
    let files: Set<String>
    let directories: Set<String>

    func contains(_ path: String) -> Bool { files.contains(path) }
}

/// One game library: where it comes from in the package and where it goes in the bundle and the active game folder.
struct EngineGameLibrary: Sendable, Equatable {
    /// Package path (`valve/cl_dlls/client_arm64.dylib`).
    let source: String
    /// Bundle path (`Contents/MacOS/cl_dlls/client_arm64.dylib`).
    let bundle: String
    /// Path below the active game folder (`cl_dlls/client_arm64.dylib`).
    let gamedirRelative: String
}

/// The exact upstream package (paths relative to the extraction root, `./` removed).
enum EngineArchiveLayout {
    /// Required engine modules (`./<name>` → `Contents/MacOS/<name>`, AC-E42b).
    static let requiredModules = ["xash3d", "libxash.dylib", "filesystem_stdio.dylib", "libmenu.dylib",
                                  "libref_gl.dylib"]
    /// Known engine modules that may or may not ship; one absent upstream is removed from the staged app (AC-E27).
    static let optionalModules = ["libref_soft.dylib"]
    static var knownModules: [String] { requiredModules + optionalModules }
    /// Root extras: accepted by the scan, never copied into the app (AC-E41, AC-E41a).
    static let rootExtras = ["xash-clang-format", "libmenu_tui.dylib", "xrcon-tui", "mdldec", "activities.txt",
                             "valve/extras.pk3"]
    static let framework = "SDL2.framework"
    /// The real framework version; only it is staged.
    static let frameworkVersion = "SDL2.framework/Versions/A"
    /// Plain-folder copies of the version that upstream packaging left where links used to be (E19.1).
    static let frameworkCopies = ["SDL2.framework", "SDL2.framework/Versions/Current"]
    static var frameworkRoots: [String] { [frameworkVersion] + frameworkCopies }
    /// Files a framework version may contain (besides headers).
    static let frameworkMemberFiles = ["SDL2", "Resources/Info.plist", "Resources/ReadMe.txt", "Resources/License.txt",
                                       "Resources/default.metallib", "Resources/CMake/sdl2-config.cmake",
                                       "Resources/CMake/sdl2-config-version.cmake", "_CodeSignature/CodeResources"]
    static let frameworkMemberDirectories = ["Headers", "Resources", "Resources/CMake", "_CodeSignature"]
    /// Required inside `Versions/A`.
    static let requiredFrameworkFiles = ["SDL2", "Resources/Info.plist"]
    /// The game folder the package ships its client/server libraries for.
    static let packageGamedir = "valve"
    static let executableName = "xash3d"
    /// Bundle locations of the engine (`Contents/MacOS/...`).
    static let bundleFramework = "Contents/MacOS/SDL2.framework"

    /// E19.3 source → bundle → active gamedir mapping.
    static func gameLibraries(architecture: EngineArchitecture) -> [EngineGameLibrary] {
        let suffix = architecture.gameLibrarySuffix
        return [("cl_dlls", "client_\(suffix).dylib"), ("dlls", "hl_\(suffix).dylib")].map { folder, name in
            EngineGameLibrary(source: "\(packageGamedir)/\(folder)/\(name)", bundle: "Contents/MacOS/\(folder)/\(name)",
                              gamedirRelative: "\(folder)/\(name)")
        }
    }

    /// `^(SDL[A-Za-z0-9_]*|begin_code|close_code)\.h$`: the header names SDL ships, one component in `Headers`.
    static func isHeaderName(_ name: String) -> Bool {
        guard name.hasSuffix(".h") else { return false }
        let stem = String(name.dropLast(2))
        if stem == "begin_code" || stem == "close_code" { return true }
        guard stem.hasPrefix("SDL") else { return false }
        return stem.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
            || (0x61...0x7A).contains($0) || $0 == 0x5F }
    }

    static func allowedDirectories() -> Set<String> {
        var folders: Set<String> = [packageGamedir, packageGamedir + "/cl_dlls", packageGamedir + "/dlls", framework,
                                    framework + "/Versions"]
        for root in frameworkRoots {
            folders.insert(root)
            for member in frameworkMemberDirectories { folders.insert(root + "/" + member) }
        }
        return folders
    }

    /// Exact file allowlist (headers by name inside `Headers` only).
    static func isAllowedFile(_ path: String, architecture: EngineArchitecture) -> Bool {
        if knownModules.contains(path) || rootExtras.contains(path) { return true }
        if gameLibraries(architecture: architecture).contains(where: { $0.source == path }) { return true }
        for root in frameworkRoots where path.hasPrefix(root + "/") {
            let member = String(path.dropFirst(root.count + 1))
            if frameworkMemberFiles.contains(member) { return true }
            if member.hasPrefix("Headers/") {
                let name = String(member.dropFirst("Headers/".count))
                if !name.contains("/"), isHeaderName(name) { return true }
            }
        }
        return false
    }

    /// `./` prefix and trailing `/` removed; `nil` for the root entry itself.
    static func normalize(_ name: String) -> String? {
        var path = name
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty || path == "." ? nil : path
    }

    /// Readable, bounded form of an untrusted entry name for errors and logs.
    static func sanitized(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control ? "?" : Character(scalar)
        }
        return String(String(scalars).prefix(120))
    }

    /// Structural safety of one path: relative, no `..`/`.`/empty components, no backslash or control character.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 8 else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Pre-scan: only regular files and folders, safe relative paths, no duplicates and nothing outside the exact
    /// allowlist; the required engine modules and framework files must be present (AC-E21, AC-E23, AC-E41).
    static func validate(_ entries: [EngineArchiveEntry],
                         architecture: EngineArchitecture) -> Result<EngineArchivePlan, EngineInstallFailure> {
        let directories = allowedDirectories()
        var files = Set<String>()
        var folders = Set<String>()
        for entry in entries {
            let name = sanitized(entry.path)
            if entry.path.hasPrefix("/") { return .failure(.unsafeArchive(name)) }
            guard let path = normalize(entry.path) else {
                guard entry.type == .directory else { return .failure(.unsafeArchive(name)) }
                continue
            }
            guard isSafeRelativePath(path), !files.contains(path), !folders.contains(path) else {
                return .failure(.unsafeArchive(name))
            }
            switch entry.type {
            case .regular where isAllowedFile(path, architecture: architecture):
                files.insert(path)
            case .directory where directories.contains(path):
                folders.insert(path)
            default:
                return .failure(.unsafeArchive(name))
            }
        }
        for module in requiredModules where !files.contains(module) {
            return .failure(.missingExpectedFile(module))
        }
        for member in requiredFrameworkFiles where !files.contains(frameworkVersion + "/" + member) {
            return .failure(.missingExpectedFile(frameworkVersion + "/" + member))
        }
        return .success(EngineArchivePlan(files: files, directories: folders))
    }
}

/// `tar -t` / `tar -tv` output → entries. The names come from the plain listing; the type from the first column of
/// the verbose line with the same index, which must end with the same name (a link line ends with its target).
enum EngineTarListing {
    static func parse(names: String, verbose: String) -> [EngineArchiveEntry]? {
        let nameLines = lines(names)
        let verboseLines = lines(verbose)
        guard nameLines.count == verboseLines.count else { return nil }
        var entries: [EngineArchiveEntry] = []
        for (name, line) in zip(nameLines, verboseLines) {
            guard let first = line.first else { return nil }
            var type: EngineArchiveEntryType
            switch first {
            case "-": type = .regular
            case "d": type = .directory
            case "l": type = .symbolicLink
            case "h": type = .hardLink
            case "c": type = .characterDevice
            case "b": type = .blockDevice
            case "p": type = .fifo
            case "s": type = .socket
            default: type = .unknown
            }
            if (type == .regular || type == .directory) && !line.hasSuffix(" " + name) { type = .unknown }
            entries.append(EngineArchiveEntry(path: name, type: type))
        }
        return entries
    }

    private static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}

// MARK: State machine (E2)

enum EngineInstallPhase: String, Sendable, Equatable, CaseIterable {
    case idle
    case checking
    case confirm
    case downloading
    case verifyingDigest
    case extracting
    case verifyingSignature
    case preflightPermission
    case preflightProcess
    case backingUp
    case installing
    case rollingBack
    case launchingEngine
    case awaitingIdentityRepair
    case verifyingIdentity
    case completed
    case completedWithWarning
    case failed
    case rolledBack
    case rollbackIncomplete
    case cancelled

    var isTerminal: Bool {
        [.completed, .completedWithWarning, .failed, .rolledBack, .rollbackIncomplete, .cancelled].contains(self)
    }

    /// AC-E7: cancellation is offered only while downloading or extracting.
    var isCancellable: Bool { self == .downloading || self == .extracting }
}

/// The defined transitions; anything else is an error (T-E-ST1). Rolling back is only reachable after the target was
/// changed (`installing`); a failure before that is `failed` (AC-E79).
enum EngineInstallStateMachine {
    static func next(_ phase: EngineInstallPhase) -> Set<EngineInstallPhase> {
        switch phase {
        case .idle: return [.checking]
        case .checking: return [.confirm, .failed]
        case .confirm: return [.downloading, .idle, .failed]
        case .downloading: return [.verifyingDigest, .failed, .cancelled]
        case .verifyingDigest: return [.extracting, .failed]
        case .extracting: return [.verifyingSignature, .failed, .cancelled]
        case .verifyingSignature: return [.preflightPermission, .failed]
        case .preflightPermission: return [.preflightProcess, .failed]
        case .preflightProcess: return [.backingUp, .failed]
        case .backingUp: return [.installing, .failed]
        case .installing: return [.awaitingIdentityRepair, .rollingBack, .failed]
        case .rollingBack: return [.rolledBack, .rollbackIncomplete]
        case .awaitingIdentityRepair: return [.launchingEngine, .verifyingIdentity]
        case .launchingEngine: return [.awaitingIdentityRepair, .completedWithWarning]
        case .verifyingIdentity: return [.completed, .completedWithWarning]
        case .completed, .completedWithWarning, .failed, .rolledBack, .rollbackIncomplete, .cancelled: return [.idle]
        }
    }

    static func canTransition(from: EngineInstallPhase, to: EngineInstallPhase) -> Bool {
        next(from).contains(to)
    }
}

/// One progress event (bytes only while downloading).
struct EngineInstallProgress: Sendable, Equatable {
    let phase: EngineInstallPhase
    var bytes: Int64 = 0
    var total: Int64 = 0
}

// MARK: Privacy (AC-E84)

enum EngineInstallPrivacy {
    /// The only accepted CID form: first 4 + `…` + last 4 lowercase hex characters.
    static func strictMasked(_ text: String?) -> String? {
        guard let text else { return nil }
        let characters = Array(text)
        guard characters.count == 9, characters[4] == "…" else { return nil }
        let hex = String(characters[0..<4]) + String(characters[5..<9])
        return EngineReleaseParser.isHex(hex, count: 8) ? text : nil
    }

    /// A value that is exactly a raw ID (16 hex) or a full CID (32 hex), any letter case.
    static func looksLikeIdentity(_ text: String) -> Bool {
        (text.utf8.count == 16 || text.utf8.count == 32) && text.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
        }
    }
}

// MARK: Confirmation, outcome, report

/// The user's answer on the confirmation screen. Only a strictly masked CID is kept; anything else is dropped.
struct EngineInstallConfirmation: Sendable, Equatable {
    let acceptedCIDWarning: Bool
    /// Masked CID at confirmation time (`cidBefore`, AC-E2c); `nil` when none or not strictly masked.
    let cidBefore: String?

    init(acceptedCIDWarning: Bool, cidBefore: String?) {
        self.acceptedCIDWarning = acceptedCIDWarning
        self.cidBefore = EngineInstallPrivacy.strictMasked(cidBefore)
    }
}

/// How an install ended. `installed` means only "the new engine is in place": it never means the identity is
/// supported or healthy (AC-E82a); that is decided by `EngineIdentityVerifier`.
enum EngineInstallOutcome: Sendable, Equatable {
    /// Installed; the engine has to be opened once by the user (awaitingIdentityRepair).
    case installed
    /// Nothing on the target was changed (AC-E79).
    case failed(EngineInstallFailure)
    /// The target was changed, then put back and verified against the backup.
    case rolledBack(EngineInstallFailure)
    /// The rollback could not be verified; the backup stays at `EngineInstallReport.backup` (never deleted).
    case rollbackIncomplete(EngineInstallFailure)
    case cancelled

    var phase: EngineInstallPhase {
        switch self {
        case .installed: return .awaitingIdentityRepair
        case .failed: return .failed
        case .rolledBack: return .rolledBack
        case .rollbackIncomplete: return .rollbackIncomplete
        case .cancelled: return .cancelled
        }
    }
}

enum EngineLibrarySkipReason: String, Sendable, Equatable {
    /// The package has no matching library for this file (AC-E32, AC-E33).
    case noUpstreamMatch
    /// The library does not exist at this location, so it is not created.
    case targetAbsent
}

struct EngineLibrarySkip: Sendable, Hashable {
    /// Display path: `bundle:<relative>` or `gamedir:<relative>`.
    let path: String
    let reason: EngineLibrarySkipReason
}

/// Which build of a library is on disk at the end of the run (AC-E79b).
enum EngineLibraryVersion: String, Sendable, Equatable {
    case upstream
    case original
    case unknown
}

struct EngineLibraryState: Sendable, Hashable {
    let path: String
    let version: EngineLibraryVersion
}

struct EngineBackupLocation: Sendable, Equatable {
    let root: URL
    let stamp: String
    let app: URL
    let identity: URL
    let libraries: URL
    let manifest: URL
}

/// Identity file state labels (AC-E80).
enum EngineIdentityFileState: String, Sendable, Equatable {
    case presentNonzero
    case presentZero
    case absent
    case unreadable
}

enum EngineIdentityChangeKind: String, Sendable, Equatable {
    /// Present before and after with the same content.
    case unchanged
    /// Present on both sides with different content, or present on one side only.
    case changed
    /// Absent or unreadable on at least one side: never claimed as unchanged (AC-E80).
    case notComparable
}

struct EngineIdentityLocationChange: Sendable, Equatable {
    /// `homeConfig`, `homeLocal`, `home` or `gamedir`.
    let location: String
    let before: EngineIdentityFileState
    let after: EngineIdentityFileState
    let change: EngineIdentityChangeKind
}

/// Everything the UI/CLI may show about a run. No raw identity, no full CID, no identity checksums (AC-E85).
struct EngineInstallReport: Sendable, Equatable {
    var release: EngineRelease?
    var installedApp: URL?
    var backup: EngineBackupLocation?
    /// Libraries that are the upstream build at the end of the run (final state, AC-E79a).
    var updatedLibraries: [String] = []
    /// Libraries put back by the rollback (AC-E79b).
    var restoredLibraries: [String] = []
    /// What is on disk at the end for every library the run considered (AC-E79b).
    var effectiveLibraries: [EngineLibraryState] = []
    var skippedLibraries: [EngineLibrarySkip] = []
    /// Known engine modules removed from the staged app because upstream does not ship them (AC-E27).
    var removedModules: [String] = []
    /// Unknown files in `Contents/MacOS` (and its library folders) that were kept (AC-E27, T-E-M3).
    var unknownFilesKept: [String] = []
    /// Items whose quarantine attribute could not be removed (AC-E30); the install still continued.
    var quarantineFailures: [String] = []
    var identityFilesBackedUp = 0
    /// Per identity location before/after labels (no checksums, AC-E80, AC-E85).
    var identityChanges: [EngineIdentityLocationChange] = []
    /// Items that could not be cleaned up (AC-E79c). A non-empty list must be shown.
    var leftovers: [String] = []
    var cidBefore: String?

    /// An identity file changed during the run (only the engine could have written it; never undone, AC-E38a).
    var identityFilesChanged: Bool { identityChanges.contains { $0.change == .changed } }
}

struct EngineInstallResult: Sendable, Equatable {
    let outcome: EngineInstallOutcome
    let report: EngineInstallReport
    /// Log lines (AC-E47): stage, asset, commit, digest, size, error code, tool category and masked CID only.
    let log: [String]
}

/// Builds AC-E47 log lines from a fixed set of keys. `.cid` is written only in the strict masked form and any other
/// value that looks like a raw ID or a full CID is withheld (AC-E84, AC-E84a).
struct EngineInstallLog: Sendable, Equatable {
    enum Key: String, Sendable {
        case stage
        case asset
        case commit
        case digest
        case size
        case error
        case cid
        case note
    }

    static let withheld = "withheld"

    private(set) var lines: [String] = []

    mutating func add(_ fields: [(Key, String)]) {
        lines.append(fields.map { "\($0.0.rawValue)=\(Self.value($0.0, $0.1))" }.joined(separator: " "))
    }

    static func value(_ key: Key, _ raw: String) -> String {
        switch key {
        case .cid:
            return raw == "none" ? raw : EngineInstallPrivacy.strictMasked(raw) ?? withheld
        case .commit, .digest:
            return clean(raw)
        default:
            return EngineInstallPrivacy.looksLikeIdentity(raw) ? withheld : clean(raw)
        }
    }

    /// No spaces, line breaks or control characters inside a value.
    private static func clean(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            scalar == " " || scalar.properties.generalCategory == .control ? "_" : Character(scalar)
        }.prefix(160))
    }
}

// MARK: Eligibility (AC-E1, D1)

enum EngineInstallEligibility {
    /// S = no ∧ R ∈ {zero, absent} ∧ B = readable ∧ P = notRunning.
    static func isOffered(_ report: MacIdentityReport) -> Bool {
        report.processState == .notRunning && report.staticSupport == .no
            && report.packageReadability == .readable && (report.rawState == .zero || report.rawState == .absent)
    }
}

// MARK: Identity verification (E9, E20.6)

/// Global and gamedir identity seen read-only; `rawEqual` is computed internally, the raw values never leave the
/// reader.
struct EngineIdentitySnapshot: Sendable, Equatable {
    let global: RawIdentityState
    let gamedir: RawIdentityState
    /// `true` when both are non-zero and the raw values are equal (file bytes may differ, AC-E58).
    let rawEqual: Bool
    let cidMasked: String?

    /// Global and gamedir non-zero with the same raw value.
    var isHealthy: Bool { global == .nonzero && gamedir == .nonzero && rawEqual }
    /// At least one location is zero, absent or unreadable (the state an install can repair).
    var isRepairable: Bool {
        let repairable: Set<RawIdentityState> = [.zero, .absent, .unreadable]
        return repairable.contains(global) || repairable.contains(gamedir)
    }
}

enum EngineIdentityVerification: String, Sendable, Equatable {
    /// Before was repairable, after is healthy (AC-E81).
    case identityRepaired
    /// Before and after are healthy (AC-E82).
    case alreadyHealthy
    /// After is not healthy, or before was neither repairable nor healthy (AC-E82).
    case notVerified
}

struct EngineIdentityResult: Sendable, Equatable {
    let verification: EngineIdentityVerification
    let cidBefore: String?
    let cidAfter: String?

    /// AC-E43/AC-E59: shown as "before → after".
    var cidChanged: Bool { cidBefore != nil && cidAfter != nil && cidBefore != cidAfter }
    /// AC-E45, AC-E87a: supported/healthy may only be claimed for these two results.
    var mayClaimSupported: Bool { verification == .identityRepaired || verification == .alreadyHealthy }
    var phase: EngineInstallPhase { mayClaimSupported ? .completed : .completedWithWarning }
}

enum EngineIdentityVerifier {
    /// A raw change from before is accepted (no rotation claim, AC-E62); byte equality is never required.
    static func evaluate(before: EngineIdentitySnapshot, after: EngineIdentitySnapshot) -> EngineIdentityResult {
        let verification: EngineIdentityVerification
        if !after.isHealthy {
            verification = .notVerified
        } else if before.isHealthy {
            verification = .alreadyHealthy
        } else if before.isRepairable {
            verification = .identityRepaired
        } else {
            verification = .notVerified
        }
        return EngineIdentityResult(verification: verification,
                                    cidBefore: EngineInstallPrivacy.strictMasked(before.cidMasked),
                                    cidAfter: EngineInstallPrivacy.strictMasked(after.cidMasked))
    }
}

// MARK: Manifests (AC-E34, AC-E38)

/// Every item of a folder tree (links recorded, never followed): checksums and modes of files, link targets.
struct EngineTreeManifest: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        let path: String
        let kind: String
        let sha256: String?
        let mode: UInt16?
        let target: String?
    }

    let entries: [Entry]

    static let maxEntries = 50_000

    func sha256(of path: String) -> String? { entries.first { $0.path == path }?.sha256 }
}

/// One backed-up file. Identity records (with their checksum) exist only in the `0600` private manifest file inside
/// the backup folder; they are never copied into a report (AC-E85).
struct EngineFileRecord: Codable, Sendable, Equatable {
    /// `homeConfig`, `homeLocal`, `home`, `gamedir` or a library display path.
    let label: String
    let original: String
    let backup: String
    let sha256: String
    let size: Int64
    let mode: UInt16
}

struct EngineBackupManifest: Codable, Sendable, Equatable {
    let version: Int
    let timestamp: String
    let assetName: String
    let digest: String
    let commit: String
    let originalApp: String
    let appBackup: String
    let app: EngineTreeManifest
    let identity: [EngineFileRecord]
    let libraries: [EngineFileRecord]
}

extension AppPaths {
    /// AC-E17 cache + staging: `~/Library/Application Support/tr.ercanatay.playeridentity/engine-updates`.
    var engineUpdatesDirectory: URL {
        snapshotFile.deletingLastPathComponent().appendingPathComponent("engine-updates", isDirectory: true)
    }

    /// AC-E34: `~/Library/Application Support/tr.ercanatay.playeridentity/engine-backups`.
    var engineBackupsDirectory: URL {
        snapshotFile.deletingLastPathComponent().appendingPathComponent("engine-backups", isDirectory: true)
    }
}

enum EngineInstallNaming {
    /// `yyyyMMdd-HHmmss` in UTC.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Plain folder name of the active game (no separators, no `.`/`..`).
    static func isPlainGamedir(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    static func sha256Hex(_ data: Data) -> String {
        CIDCalculator.hexLower(Array(SHA256.hash(data: data)))
    }
}

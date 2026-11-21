import CryptoKit
import Foundation

// MARK: - v2.26 engine backups: inventory and confirmed deletion (AC-E40, AC-E40a, AC-E40b)
//
// The installer never deletes an older backup. `EngineBackupStore` lists the backup groups (one group = the app copy,
// the identity folder, the library folder and the manifest of one install), marks the newest three as kept and
// returns the rest as prune candidates. Deleting needs a token that is issued only for prune candidates of the
// current inventory; a missing or stale token deletes nothing. The app asks in Settings > Data > Engine backups and
// the CLI needs `engine backups delete --confirm <code>` (EngineInstallService.swift).

/// One backup (all items that share a timestamp).
struct EngineBackupGroup: Sendable, Equatable {
    /// `yyyyMMdd-HHmmss` (optionally `-<run>`); groups sort newest first by this value.
    let stamp: String
    /// File names inside the backup folder (sorted).
    let items: [String]

    var hasManifest: Bool { items.contains("manifest-\(stamp).json") }
}

struct EngineBackupInventory: Sendable, Equatable {
    /// Newest first.
    let groups: [EngineBackupGroup]

    static let keepCount = 3

    /// The newest three: never offered for deletion.
    var kept: [EngineBackupGroup] { Array(groups.prefix(Self.keepCount)) }
    /// Everything older; deleted only with an explicit token.
    var pruneCandidates: [EngineBackupGroup] { Array(groups.dropFirst(Self.keepCount)) }
}

/// Why one backup group could not be removed completely (its manifest is then kept, AC-E98a).
enum EngineBackupDeletionFailure: String, Sendable, Equatable {
    /// An item is a link or lies outside the backup folder: refused.
    case unsafePath
    /// Removing an item failed.
    case removeFailed
}

/// AC-E98: what a confirmed deletion did. Any failed group makes it a `partialFailure`, never a success.
struct EngineBackupDeletionReport: Sendable, Equatable {
    enum Status: String, Sendable, Equatable {
        case success
        case partialFailure
    }

    let removed: [String]
    let failed: [String: EngineBackupDeletionFailure]

    var status: Status { failed.isEmpty ? .success : .partialFailure }
}

/// Proof that the user confirmed deleting exactly these groups of exactly this inventory.
struct EngineBackupDeletionToken: Sendable, Equatable {
    let stamps: [String]
    /// Fingerprint of the inventory the token was issued for (a changed folder invalidates it).
    fileprivate let inventoryFingerprint: String
}

struct EngineBackupStore: Sendable {
    let root: URL
    let files: any EngineFileOperating

    init(root: URL, files: any EngineFileOperating = LocalEngineFileOperations()) {
        self.root = root
        self.files = files
    }

    /// Reads the backup folder; names that do not belong to a backup group are ignored (never deleted).
    func inventory() throws -> EngineBackupInventory {
        guard files.kind(root) != .missing else { return EngineBackupInventory(groups: []) }
        guard files.kind(root) == .directory else { throw EngineInstallFailure.unsafePath("backup") }
        var byStamp: [String: [String]] = [:]
        for name in try files.contents(root) {
            guard let stamp = Self.stamp(of: name) else { continue }
            byStamp[stamp, default: []].append(name)
        }
        let groups = byStamp.map { EngineBackupGroup(stamp: $0.key, items: $0.value.sorted()) }
            .sorted { $0.stamp > $1.stamp }
        return EngineBackupInventory(groups: groups)
    }

    /// Issues a token for prune candidates only; asking for a kept or unknown group is `confirmationRequired`.
    func confirmDeletion(of stamps: [String],
                         in inventory: EngineBackupInventory) -> Result<EngineBackupDeletionToken, EngineInstallFailure> {
        let candidates = Set(inventory.pruneCandidates.map(\.stamp))
        guard !stamps.isEmpty, Set(stamps).isSubset(of: candidates) else { return .failure(.confirmationRequired) }
        return .success(EngineBackupDeletionToken(stamps: stamps.sorted(),
                                                  inventoryFingerprint: Self.fingerprint(inventory)))
    }

    /// Deletes the confirmed groups. No token, or a token for an inventory that has changed since, deletes nothing.
    /// Every item is removed only when it lies physically inside the backup folder; the manifest goes last, so a group
    /// that cannot be removed completely keeps its metadata (AC-E79d). Returns the stamps that were removed fully.
    func deleteBackups(_ token: EngineBackupDeletionToken?) -> Result<EngineBackupDeletionReport, EngineInstallFailure> {
        guard let token else { return .failure(.confirmationRequired) }
        guard let current = try? inventory(), Self.fingerprint(current) == token.inventoryFingerprint else {
            return .failure(.confirmationRequired)
        }
        let candidates = Dictionary(uniqueKeysWithValues: current.pruneCandidates.map { ($0.stamp, $0) })
        guard token.stamps.allSatisfy({ candidates[$0] != nil }) else { return .failure(.confirmationRequired) }
        var removed: [String] = []
        var failed: [String: EngineBackupDeletionFailure] = [:]
        for stamp in token.stamps {
            guard let group = candidates[stamp] else { continue }
            let manifest = "manifest-\(stamp).json"
            var failure: EngineBackupDeletionFailure?
            for name in group.items where name != manifest {
                if let problem = remove(name) { failure = failure ?? problem }
            }
            if failure == nil, group.items.contains(manifest) { failure = remove(manifest) }
            if let failure { failed[stamp] = failure } else { removed.append(stamp) }
        }
        return .success(EngineBackupDeletionReport(removed: removed, failed: failed))
    }

    /// `nil` when removed.
    private func remove(_ name: String) -> EngineBackupDeletionFailure? {
        let url = root.appendingPathComponent(name)
        let physicalRoot = files.resolvedPath(root)
        guard !name.contains("/"), files.kind(url) != .symbolicLink,
              EnginePaths.isInside(path: files.resolvedPath(url.deletingLastPathComponent()), root: physicalRoot) else {
            return .unsafePath
        }
        do {
            try files.removeItem(url)
            return nil
        } catch {
            return .removeFailed
        }
    }

    /// `<app>-<stamp>.app`, `identity-<stamp>`, `libs-<stamp>`, `manifest-<stamp>.json` → stamp.
    static func stamp(of name: String) -> String? {
        let candidate: Substring
        if name.hasPrefix("identity-") {
            candidate = name.dropFirst("identity-".count)
        } else if name.hasPrefix("libs-") {
            candidate = name.dropFirst("libs-".count)
        } else if name.hasPrefix("manifest-"), name.hasSuffix(".json") {
            candidate = name.dropFirst("manifest-".count).dropLast(".json".count)
        } else if name.hasSuffix(".app") {
            // `<app name may contain dashes>-yyyyMMdd-HHmmss[-run]`: the stamp is the last two or three parts.
            let parts = name.dropLast(".app".count).split(separator: "-", omittingEmptySubsequences: false)
            for count in [3, 2] where parts.count > count {
                let tail = parts.suffix(count).joined(separator: "-")
                if isStamp(tail) { return tail }
            }
            return nil
        } else {
            return nil
        }
        return isStamp(String(candidate)) ? String(candidate) : nil
    }

    /// `yyyyMMdd-HHmmss` with an optional `-` + 8 lowercase hex run suffix.
    static func isStamp(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        let digits: (Substring, Int) -> Bool = { part, count in
            part.utf8.count == count && part.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
        switch parts.count {
        case 2: return digits(parts[0], 8) && digits(parts[1], 6)
        case 3: return digits(parts[0], 8) && digits(parts[1], 6) && EngineReleaseParser.isHex(String(parts[2]), count: 8)
        default: return false
        }
    }

    static func fingerprint(_ inventory: EngineBackupInventory) -> String {
        let text = inventory.groups.map { $0.stamp + ":" + $0.items.joined(separator: ",") }.joined(separator: ";")
        return EngineInstallNaming.sha256Hex(Data(text.utf8))
    }
}

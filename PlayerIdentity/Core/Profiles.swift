import Foundation

// MARK: - §61 Multiple profiles

/// One identity setup: a data root and a game folder. Kept in `profile.json` (`profiles` + `activeProfileID`).
/// The server list is shared by every profile; history and metrics rows carry the profile they were written for.
struct Profile: Codable, Sendable, Equatable, Identifiable {
    /// Name of the profile migrated from the single `dataRoot`/`gamedir` record (§61).
    static let migratedName = "Default"

    var id: UUID
    var name: String
    /// `nil` = the default data root (`~/Library/Application Support/Xash3D FWGS`).
    var dataRoot: String?
    /// Empty = automatic selection (§3.4).
    var gamedir: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, dataRoot: String?, gamedir: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.dataRoot = dataRoot
        self.gamedir = gamedir
        self.createdAt = createdAt
    }

    /// Data root folder this profile resolves to.
    func dataRootURL(defaultDataRoot: URL) -> URL {
        guard let dataRoot, !dataRoot.isEmpty else { return defaultDataRoot.standardizedFileURL }
        return URL(fileURLWithPath: dataRoot, isDirectory: true).standardizedFileURL
    }

    /// Game folder to prefer (`nil` = automatic selection).
    var preferredGamedir: String? { gamedir.isEmpty ? nil : gamedir }
}

/// Profile stamp of a history entry or metric sample (the name is a snapshot at write time).
struct ProfileTag: Sendable, Equatable {
    let id: UUID
    let name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(_ profile: Profile) {
        self.init(id: profile.id, name: profile.name)
    }
}

/// Why a profile change was refused (§61).
enum ProfileError: Error, Sendable, Equatable {
    case nameEmpty
    /// Another profile already uses the same data root + game folder.
    case duplicateCombination
    /// The last profile cannot be removed.
    case lastProfile
    /// The game is running: switching could change the files it writes (read-only warning).
    case gameRunning
    case notFound
    /// A restore, an erase or a settings import is running.
    case busy

    var text: String {
        switch self {
        case .nameEmpty: return L10n.text(.profilesErrorNameEmpty)
        case .duplicateCombination: return L10n.text(.profilesErrorDuplicate)
        case .lastProfile: return L10n.text(.profilesErrorLastProfile)
        case .gameRunning: return L10n.text(.profilesErrorGameRunning)
        case .notFound: return L10n.text(.profilesErrorNotFound)
        case .busy: return L10n.text(.profilesErrorBusy)
        }
    }
}

/// The profile list: never empty; the first profile is the default one (the fallback after deleting the active one).
struct ProfileList: Sendable, Equatable {
    private(set) var profiles: [Profile]
    private(set) var activeID: UUID
    let defaultDataRoot: URL

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles[0] }
    var defaultProfile: Profile { profiles[0] }

    /// Reads the list from the record; a record without profiles (older versions) migrates its single
    /// `dataRoot`/`gamedir` into `Default`. `storedDataRoot` is the data root kept in UserDefaults, which older
    /// versions preferred over the record's.
    static func resolve(snapshot: Snapshot?, storedDataRoot: String?, defaultDataRoot: URL, now: Date) -> ProfileList {
        let root = defaultDataRoot.standardizedFileURL
        var seen = Set<UUID>()
        let stored = (snapshot?.profiles ?? []).filter { seen.insert($0.id).inserted }
        if !stored.isEmpty {
            let active = snapshot?.activeProfileID.flatMap { id in stored.contains { $0.id == id } ? id : nil }
            return ProfileList(profiles: stored, activeID: active ?? stored[0].id, defaultDataRoot: root)
        }
        let legacyRoot: String?
        if let storedDataRoot, !storedDataRoot.isEmpty {
            legacyRoot = storedDataRoot
        } else if let recorded = snapshot?.dataRoot, !recorded.isEmpty {
            legacyRoot = recorded
        } else {
            legacyRoot = nil
        }
        let migrated = Profile(name: Profile.migratedName, dataRoot: normalizedRoot(legacyRoot, defaultDataRoot: root),
                               gamedir: snapshot?.gamedir ?? "", createdAt: now)
        return ProfileList(profiles: [migrated], activeID: migrated.id, defaultDataRoot: root)
    }

    init(profiles: [Profile], activeID: UUID, defaultDataRoot: URL) {
        // Never empty: an empty list falls back to a single `Default` on the default data root.
        let list = profiles.isEmpty
            ? [Profile(name: Profile.migratedName, dataRoot: nil, gamedir: "", createdAt: .distantPast)]
            : profiles
        self.profiles = list
        self.activeID = list.contains { $0.id == activeID } ? activeID : list[0].id
        self.defaultDataRoot = defaultDataRoot.standardizedFileURL
    }

    /// Stored form of a data root: `nil` for the default folder, otherwise the standardized path.
    static func normalizedRoot(_ path: String?, defaultDataRoot: URL) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return standardized == defaultDataRoot.standardizedFileURL.path ? nil : standardized
    }

    /// Data root + game folder key used for the duplicate check (an empty game folder is "automatic").
    private func combination(dataRoot: String?, gamedir: String) -> String {
        let root = Profile(name: "", dataRoot: dataRoot, gamedir: gamedir, createdAt: .distantPast)
            .dataRootURL(defaultDataRoot: defaultDataRoot).path
        return root + "\u{0}" + gamedir.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasCombination(dataRoot: String?, gamedir: String, excluding id: UUID? = nil) -> Bool {
        let key = combination(dataRoot: dataRoot, gamedir: gamedir)
        return profiles.contains { $0.id != id && combination(dataRoot: $0.dataRoot, gamedir: $0.gamedir) == key }
    }

    @discardableResult
    mutating func add(name: String, dataRoot: String?, gamedir: String, now: Date) throws(ProfileError) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .nameEmpty }
        let root = Self.normalizedRoot(dataRoot, defaultDataRoot: defaultDataRoot)
        let folder = gamedir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasCombination(dataRoot: root, gamedir: folder) else { throw .duplicateCombination }
        let profile = Profile(name: trimmed, dataRoot: root, gamedir: folder, createdAt: now)
        profiles.append(profile)
        return profile
    }

    mutating func rename(_ id: UUID, to name: String) throws(ProfileError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .nameEmpty }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw .notFound }
        profiles[index].name = trimmed
    }

    /// Removes a profile; when it was the active one the default profile becomes active. Returns whether the active
    /// profile changed.
    @discardableResult
    mutating func remove(_ id: UUID) throws(ProfileError) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw .notFound }
        guard profiles.count > 1 else { throw .lastProfile }
        profiles.remove(at: index)
        guard id == activeID else { return false }
        activeID = profiles[0].id
        return true
    }

    /// Moves the profile to the top: it becomes the default (fallback) profile.
    mutating func makeDefault(_ id: UUID) throws(ProfileError) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw .notFound }
        let profile = profiles.remove(at: index)
        profiles.insert(profile, at: 0)
    }

    mutating func activate(_ id: UUID) throws(ProfileError) {
        guard profiles.contains(where: { $0.id == id }) else { throw .notFound }
        activeID = id
    }

    /// The user changed the data root or the game folder of the active profile in the main window.
    mutating func updateActive(dataRoot: URL? = nil, gamedir: String?? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        if let dataRoot {
            profiles[index].dataRoot = Self.normalizedRoot(dataRoot.path, defaultDataRoot: defaultDataRoot)
        }
        if let gamedir {
            profiles[index].gamedir = gamedir ?? ""
        }
    }
}

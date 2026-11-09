import Foundation

// MARK: - Release feed (§27.1, §28.2)

struct ReleaseAsset: Sendable, Equatable {
    let name: String
    let size: Int
    let downloadURL: URL
}

/// A stable GitHub release with its update assets.
struct AppRelease: Sendable, Equatable {
    let version: SemanticVersion
    /// `tag_name` without the leading `v` (the version string used in asset names).
    let versionString: String
    let tag: String
    let pageURL: URL?
    let notes: String
    let publishedAt: Date?
    /// `PlayerIdentity-<version>-macos.zip`
    let zip: ReleaseAsset?
    /// `SHA256SUMS.txt`
    let sums: ReleaseAsset?

    /// Both assets are present, so the release can be installed (§27.1/2).
    var isInstallable: Bool { zip != nil && sums != nil }

    static func zipName(version: String) -> String { "PlayerIdentity-\(version)-macos.zip" }
    static let sumsName = "SHA256SUMS.txt"
}

enum ReleaseFeed {
    static let url = URL(string: "https://api.github.com/repos/ercanatay/player-identity/releases?per_page=50")!
    /// Version history length (§28.2).
    static let historyLimit = 20

    /// Stable releases only (`draft == false`, `prerelease == false`, no pre-release suffix), newest first.
    static func parse(_ data: Data) -> [AppRelease]? {
        struct Asset: Decodable {
            let name: String
            let size: Int?
            let browser_download_url: String?
        }
        struct Release: Decodable {
            let tag_name: String
            let html_url: String?
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let published_at: String?
            let assets: [Asset]?
        }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        let dates = ISO8601DateFormatter()
        let parsed = releases.compactMap { release -> AppRelease? in
            guard release.draft != true, release.prerelease != true,
                  let version = SemanticVersion(release.tag_name), !version.isPrerelease else { return nil }
            var versionString = release.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
            if versionString.first == "v" || versionString.first == "V" { versionString.removeFirst() }
            func asset(_ name: String) -> ReleaseAsset? {
                guard let raw = release.assets?.first(where: { $0.name == name }),
                      let link = raw.browser_download_url.flatMap(URL.init(string:)),
                      let size = raw.size, size > 0 else { return nil }
                return ReleaseAsset(name: raw.name, size: size, downloadURL: link)
            }
            return AppRelease(version: version, versionString: versionString, tag: release.tag_name,
                              pageURL: release.html_url.flatMap(URL.init(string:)),
                              notes: release.body ?? "",
                              publishedAt: release.published_at.flatMap(dates.date(from:)),
                              zip: asset(AppRelease.zipName(version: versionString)),
                              sums: asset(AppRelease.sumsName))
        }
        return parsed.sorted { $0.version > $1.version }
    }

    /// The last 20 stable releases (§28.2).
    static func history(_ releases: [AppRelease]) -> [AppRelease] {
        Array(releases.sorted { $0.version > $1.version }.prefix(historyLimit))
    }

    /// Newest installable release newer than the running version.
    static func latestUpdate(in releases: [AppRelease], currentVersion: String) -> AppRelease? {
        guard let current = SemanticVersion(currentVersion) else { return nil }
        return releases.filter { $0.isInstallable && $0.version > current }.max { $0.version < $1.version }
    }
}

/// `GET /releases` through the injectable HTTP client.
struct ReleaseFeedClient: Sendable {
    static let timeout: TimeInterval = 15

    let http: any HTTPClient

    func fetch() async throws -> [AppRelease] {
        let response = try await http.get(ReleaseFeed.url, timeout: Self.timeout)
        guard (200..<300).contains(response.statusCode), let releases = ReleaseFeed.parse(response.data) else {
            throw UpdateError.feedUnavailable
        }
        return releases
    }
}

// MARK: - SHA256SUMS.txt

enum SHA256Sums {
    /// `<sha256>  <file>` (or `<sha256> *<file>`) lines → file name → lowercase hex. Malformed lines are skipped.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit), !name.isEmpty else { continue }
            result[name] = hash
        }
        return result
    }
}

// MARK: - Schedule (§27.2)

enum UpdateSchedule {
    /// At launch: at most once per 24 hours (same counter as §25).
    static let launchInterval: TimeInterval = UpdateChecker.interval
    /// While the app stays open: again every 6 hours.
    static let periodicInterval: TimeInterval = 6 * 60 * 60

    static func isLaunchCheckDue(lastCheck: Date?, now: Date) -> Bool {
        UpdateChecker.isDue(lastCheck: lastCheck, now: now, manual: false)
    }

    static func isPeriodicCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck, now >= lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= periodicInterval
    }

    /// When the next periodic check is due (`now` if already due).
    static func nextPeriodicCheck(lastCheck: Date?, now: Date) -> Date {
        guard let lastCheck, !isPeriodicCheckDue(lastCheck: lastCheck, now: now) else { return now }
        return lastCheck.addingTimeInterval(periodicInterval)
    }
}

/// Update preferences (UserDefaults). Automatic checks on, automatic download off by default (§27.2).
struct UpdatePreferences: Sendable, Equatable {
    var autoCheck: Bool
    var autoDownload: Bool

    enum Key {
        static let autoCheck = "update.autoCheck"
        static let autoDownload = "update.autoDownload"
    }

    init(autoCheck: Bool = true, autoDownload: Bool = false) {
        self.autoCheck = autoCheck
        self.autoDownload = autoDownload
    }

    init(defaults: UserDefaults) {
        autoCheck = defaults.object(forKey: Key.autoCheck) as? Bool ?? true
        autoDownload = defaults.object(forKey: Key.autoDownload) as? Bool ?? false
    }

    func save(to defaults: UserDefaults) {
        defaults.set(autoCheck, forKey: Key.autoCheck)
        defaults.set(autoDownload, forKey: Key.autoDownload)
    }
}

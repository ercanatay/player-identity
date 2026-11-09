import Foundation

// MARK: - Version (§25)

/// `major.minor.patch` with an optional pre-release suffix; a leading `v` is accepted (`v1.10.0`).
struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }   // build metadata
        var pre: String?
        if let dash = value.firstIndex(of: "-") {
            pre = String(value[value.index(after: dash)...])
            value = String(value[..<dash])
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        prerelease = (pre?.isEmpty ?? true) ? nil : pre
    }

    var isPrerelease: Bool { prerelease != nil }

    var description: String { "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "") }

    /// Numeric comparison (`1.10 > 1.9`); a pre-release sorts before its release.
    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let a?, let b?): return a < b
        }
    }
}

// MARK: - Release check

struct AppUpdate: Sendable, Equatable {
    let version: String
    let url: URL
}

enum UpdateCheckResult: Sendable, Equatable {
    case available(AppUpdate)
    case upToDate
    /// Network/API error; never shown to the user (§25).
    case failed
}

struct UpdateChecker: Sendable {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/ercanatay/player-identity/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/ercanatay/player-identity/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60
    static let timeout: TimeInterval = 10

    let http: any HTTPClient
    let currentVersion: String

    func check() async -> UpdateCheckResult {
        guard let response = try? await http.get(Self.latestReleaseURL, timeout: Self.timeout),
              (200..<300).contains(response.statusCode) else { return .failed }
        return Self.evaluate(response.data, currentVersion: currentVersion)
    }

    /// `tag_name` compared with the app version; drafts and pre-releases are ignored.
    static func evaluate(_ data: Data, currentVersion: String) -> UpdateCheckResult {
        struct Release: Decodable {
            let tag_name: String
            let html_url: String?
            let prerelease: Bool?
            let draft: Bool?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let latest = SemanticVersion(release.tag_name),
              let current = SemanticVersion(currentVersion) else { return .failed }
        if release.prerelease == true || release.draft == true || latest.isPrerelease { return .upToDate }
        guard latest > current else { return .upToDate }
        let url = release.html_url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            ?? releasesPageURL
        return .available(AppUpdate(version: latest.description, url: url))
    }

    /// At most once per 24 hours at launch; a manual check is always due.
    static func isDue(lastCheck: Date?, now: Date, manual: Bool) -> Bool {
        guard !manual, let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}

/// Persisted check state (UserDefaults): last check time, last found release, ignored version.
struct UpdateState: Sendable, Equatable {
    var lastCheck: Date?
    var latest: AppUpdate?
    var ignoredVersion: String?

    enum Key {
        static let lastCheck = "update.lastCheck"
        static let latestVersion = "update.latestVersion"
        static let latestURL = "update.latestURL"
        static let ignoredVersion = "update.ignoredVersion"
    }

    init(lastCheck: Date? = nil, latest: AppUpdate? = nil, ignoredVersion: String? = nil) {
        self.lastCheck = lastCheck
        self.latest = latest
        self.ignoredVersion = ignoredVersion
    }

    init(defaults: UserDefaults) {
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        if let version = defaults.string(forKey: Key.latestVersion),
           let url = defaults.string(forKey: Key.latestURL).flatMap(URL.init(string:)) {
            latest = AppUpdate(version: version, url: url)
        }
        ignoredVersion = defaults.string(forKey: Key.ignoredVersion)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(lastCheck, forKey: Key.lastCheck)
        defaults.set(latest?.version, forKey: Key.latestVersion)
        defaults.set(latest?.url.absoluteString, forKey: Key.latestURL)
        defaults.set(ignoredVersion, forKey: Key.ignoredVersion)
    }

    /// Banner content: the last found release if it is newer than the app and not ignored.
    func banner(currentVersion: String) -> AppUpdate? {
        guard let latest, latest.version != ignoredVersion,
              let latestVersion = SemanticVersion(latest.version), let current = SemanticVersion(currentVersion),
              latestVersion > current else { return nil }
        return latest
    }
}

import XCTest
@testable import PlayerIdentity

/// §41 diagnostics ZIP (content + redaction) and the Homebrew cask template.
final class DiagnosticsTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testRedaction() {
        let redactor = Redactor(home: URL(fileURLWithPath: "/Users/alice"))
        XCTAssertEqual(redactor.text("198.51.100.7"), "198.51.x.x")
        XCTAssertEqual(redactor.text("en0 · 192.0.2.10"), "en0 · 192.0.x.x")
        XCTAssertEqual(redactor.text("2001:db8:85a3::8a2e:370:7334"), "2001:db8::x")
        XCTAssertEqual(redactor.text("[2001:db8::1]:27015"), "[2001:db8::x]:27015")
        XCTAssertEqual(redactor.text("ipBanned: banned 203.0.113.5."), "ipBanned: banned 203.0.x.x.")
        XCTAssertEqual(redactor.text("/Users/alice/.config/.xash_id"), "~/.config/.xash_id")
        // Not IPs: dates, times, UUIDs, CIDs, raw IDs, versions, host names.
        for kept in ["2026-11-09T10:00:00Z", "10:33:20", "1E390D91-9114-454E-A9B3-4AB1833ACD48",
                     "d9de0eb4419608a8423241430581e91c", "0000000000000000", "2.1.0", "play.example.com", "ab:cd"] {
            XCTAssertEqual(redactor.text(kept), kept)
        }
    }

    func testZipRoundTripAndSystemUnzip() throws {
        let entries = [ZipEntry(name: "a.json", data: Data("{\"x\":1}".utf8)), ZipEntry(name: "empty.jsonl", data: Data()),
                       ZipEntry(name: "ü.txt", data: Data((0..<1000).map { UInt8($0 % 251) }))]
        let zip = ZipArchive.make(entries, modified: Self.t0)
        XCTAssertEqual(ZipArchive.read(zip), entries)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)   // standard check value

        let temp = try TempDirectory()
        let file = try temp.write("test.zip", zip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", file.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testDiagnosticsPackageFromFixture() throws {
        let temp = try TempDirectory()
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        let paths = AppPaths(home: home)
        let snapshot = Snapshot(savedAt: Self.t0, gamedir: "valve",
                                dataRoot: home.appendingPathComponent("Library/Application Support/Xash3D FWGS").path,
                                displayName: "Player", model: "gordon", rawID: "0000000000000000",
                                identitySource: home.appendingPathComponent(".config/.xash_id").path,
                                network: NetworkInfo(publicIP: "198.51.100.7", lanIPs: ["en0 · 192.0.2.10"], checkedAt: Self.t0),
                                servers: [ServerEntry(label: "EU", host: "203.0.113.20", cid: "d9de0eb4419608a8423241430581e91c",
                                                      banCheck: BanCheck(status: .ipBanned, checkedAt: Self.t0,
                                                                         detail: "ipBanned: you (198.51.100.7) are banned")),
                                          ServerEntry(label: "Name", host: "play.example.com")])
        try SnapshotStore(fileURL: paths.snapshotFile).save(snapshot)
        let history = HistoryStore(fileURL: paths.historyFile)
        try history.append((0..<250).map { HistoryEntry(ts: Self.t0 + Double($0), kind: .ipChanged, old: "198.51.100.7",
                                                        new: "198.51.100.\($0 % 200)") })
        try Data("not json\n".utf8).append(to: paths.historyFile)
        try MetricsStore(fileURL: paths.metricsFile).append([MetricSample(ts: Self.t0, serverID: UUID(), host: "203.0.113.20",
                                                                         online: true, ping: 30)])
        let suite = "DiagnosticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UpdateState(lastCheck: Self.t0, latest: AppUpdate(version: "2.2.0", url: URL(string: "https://example.com/r")!),
                    ignoredVersion: nil).save(to: defaults)

        let info = DiagnosticsAppInfo(version: "2.1.0", build: "21", osVersion: "Version 26.1", architecture: "arm64", language: "tr")
        let zip = DiagnosticsBundle.archive(DiagnosticsInput(appInfo: info, paths: paths, defaults: defaults, now: Self.t0))
        let files = try XCTUnwrap(ZipArchive.read(zip))
        XCTAssertEqual(files.map(\.name), DiagnosticsBundle.fileNames)
        func text(_ name: String) throws -> String {
            String(decoding: try XCTUnwrap(files.first { $0.name == name }).data, as: UTF8.self)
        }
        func object(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try text(name).utf8)) as? [String: Any])
        }

        let appInfo = try object("app-info.json")
        XCTAssertEqual(appInfo["version"] as? String, "2.1.0")
        XCTAssertEqual(appInfo["build"] as? String, "21")
        XCTAssertEqual(appInfo["architecture"] as? String, "arm64")
        XCTAssertEqual(appInfo["os"] as? String, "Version 26.1")

        let redacted = try text("snapshot.redacted.json")
        for leaked in ["198.51.100.7", "192.0.2.10", "203.0.113.20", home.path] {
            XCTAssertFalse(redacted.contains(leaked), leaked)
        }
        XCTAssertTrue(redacted.contains("198.51.x.x"))
        XCTAssertTrue(redacted.contains("203.0.x.x"))
        XCTAssertTrue(redacted.contains("play.example.com"))
        XCTAssertTrue(redacted.contains("d9de0eb4419608a8423241430581e91c"))
        XCTAssertTrue(redacted.contains("~/.config/.xash_id"))
        XCTAssertEqual(SnapshotStore.decode(Data(redacted.utf8)).snapshot?.servers.count, 2)   // still a readable record

        let historyLines = try text("history.tail.jsonl").split(separator: "\n")
        XCTAssertEqual(historyLines.count, 199)                     // last 200 lines, the corrupt one left out
        XCTAssertFalse(historyLines.contains { $0.contains("198.51.100.") })
        XCTAssertTrue(try text("metrics.tail.jsonl").contains("203.0.x.x"))

        let update = try object("update-state.json")
        XCTAssertEqual(update["latestVersion"] as? String, "2.2.0")
        XCTAssertEqual(update["autoCheck"] as? Bool, true)
        XCTAssertTrue(update["ignoredVersion"] is NSNull)
        XCTAssertEqual(DiagnosticsBundle.defaultFileName(now: Self.t0, timeZone: TimeZone(identifier: "UTC")!),
                       "PlayerIdentity-diagnostics-20261026-0733.zip")
    }

    func testPackageWithoutData() throws {
        let temp = try TempDirectory()
        let suite = "DiagnosticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = DiagnosticsInput(appInfo: .current(), paths: AppPaths(home: temp.url), defaults: defaults, now: Self.t0)
        let files = try XCTUnwrap(ZipArchive.read(DiagnosticsBundle.archive(input)))
        XCTAssertEqual(files.count, 5)
        XCTAssertTrue(String(decoding: files[1].data, as: UTF8.self).contains("missing"))
        XCTAssertEqual(files[2].data, Data())
        XCTAssertFalse(DiagnosticsAppInfo.current().architecture.isEmpty)
    }

    // MARK: Cask

    func testCaskTemplateSyntaxAndFields() throws {
        let resources = try XCTUnwrap(Bundle(for: DiagnosticsTests.self).resourceURL)
        let cask = resources.appendingPathComponent("Casks/player-identity.rb")
        let source = try String(contentsOf: cask, encoding: .utf8)
        XCTAssertNotNil(source.range(of: #"(?m)^  version "\d+\.\d+\.\d+"$"#, options: .regularExpression))
        XCTAssertNotNil(source.range(of: #"(?m)^  sha256 "[0-9a-f]{64}"$"#, options: .regularExpression))
        XCTAssertTrue(source.contains(##"url "https://github.com/ercanatay/player-identity/releases/download/v#{version}/PlayerIdentity-#{version}-macos.zip""##))
        XCTAssertTrue(source.contains(#"app "PlayerIdentity.app""#))
        XCTAssertTrue(source.contains(##"binary "#{appdir}/PlayerIdentity.app/Contents/Helpers/playeridentityctl""##))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["-c", cask.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertTrue(message.contains("Syntax OK"), message)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

import XCTest
@testable import PlayerIdentity

/// §22: append-only JSONL history, transition dedupe, corrupt-line tolerance, retention, filter, export.
final class HistoryTests: XCTestCase {
    private var temp: TempDirectory!
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let serverA = UUID(uuidString: "1E390D91-9114-454E-A9B3-4AB1833ACD48")!
    private let serverB = UUID(uuidString: "5E3A1D2C-0B7E-4C61-9C1F-2D7B4F0A5161")!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private var fileURL: URL { temp.url.appendingPathComponent("support/history.jsonl") }
    private var store: HistoryStore { HistoryStore(fileURL: fileURL) }
    private func lines() throws -> [String] {
        try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func observation(_ offset: TimeInterval = 0, overall: StatusLevel? = .orange, ip: String? = "203.0.113.7",
                             identity: String? = "0000000000000000", name: String? = "N", model: String? = "gordon",
                             bans: [(UUID, BanStatus?)] = []) -> HistoryObservation {
        HistoryObservation(ts: t0.addingTimeInterval(offset), overall: overall, publicIP: ip, identity: identity,
                           name: name, model: model,
                           servers: bans.map { HistoryObservation.Server(id: $0.0, host: "51.68.190.91", ban: $0.1) })
    }

    // MARK: Store

    func testAppendAndLoadWithFieldNames() throws {
        let entry = HistoryEntry(ts: t0, kind: .ipChanged, old: "1.1.1.1", new: "2.2.2.2")
        try store.append([entry])
        try store.append([HistoryEntry(ts: t0, kind: .fixAttempt, serverID: serverA, host: "h", note: "resolved")])
        XCTAssertEqual(store.load().count, 2)
        XCTAssertEqual(store.load().first, entry)
        let first = try lines()[0]
        XCTAssertEqual(first, #"{"kind":"ipChanged","new":"2.2.2.2","old":"1.1.1.1","ts":"2026-10-26T07:33:20Z"}"#)
        XCTAssertTrue(try lines()[1].contains(#""serverID":"1E390D91-9114-454E-A9B3-4AB1833ACD48""#))
        XCTAssertEqual(HistoryKind.allCases.map(\.rawValue),
                       ["refresh", "ipChanged", "banAppeared", "banLifted", "identityChanged", "nameChanged",
                        "modelChanged", "apply", "fixAttempt", "appUpdateAvailable", "appeal"])   // §32 adds `appeal`
        XCTAssertEqual(AppPaths(home: URL(fileURLWithPath: "/h")).historyFile.path,
                       "/h/Library/Application Support/tr.ercanatay.playeridentity/history.jsonl")
    }

    func testAppendIsAppendOnly() throws {
        try store.append([HistoryEntry(ts: t0, kind: .apply, note: "config.cfg")])
        let before = try Data(contentsOf: fileURL)
        try store.append([HistoryEntry(ts: t0, kind: .apply, note: "userconfig.cfg")])
        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(after.prefix(before.count), before)
    }

    func testCorruptLinesAreSkippedAndTruncatedLastLineDoesNotBreakAppend() throws {
        try store.append([HistoryEntry(ts: t0, kind: .apply, note: "a")])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"kind\":\"nope\",\"ts\":\"x\"}\n{\"kind\":\"apply\",\"ts\":\"2026-10".utf8))
        try handle.close()
        XCTAssertEqual(store.load().map(\.note), ["a"])

        try store.append([HistoryEntry(ts: t0, kind: .apply, note: "b")])
        XCTAssertEqual(store.load().map(\.note), ["a", "b"])
        XCTAssertEqual(try lines().last, #"{"kind":"apply","note":"b","ts":"2026-10-26T07:33:20Z"}"#)
    }

    func testRetentionKeepsNinetyDaysAndFiveThousandEntries() throws {
        let now = t0
        let old = HistoryEntry(ts: now.addingTimeInterval(-91 * 86_400), kind: .apply, note: "old")
        let edge = HistoryEntry(ts: now.addingTimeInterval(-90 * 86_400), kind: .apply, note: "edge")
        XCTAssertEqual(HistoryRetention.apply([old, edge], now: now).map(\.note), ["edge"])

        let many = (0..<5_003).map { HistoryEntry(ts: now.addingTimeInterval(Double($0)), kind: .apply, note: "\($0)") }
        let kept = HistoryRetention.apply(many, now: now)
        XCTAssertEqual(kept.count, 5_000)
        XCTAssertEqual(kept.first?.note, "3")
        XCTAssertEqual(kept.last?.note, "5002")
    }

    func testCompactRewritesOnlyWhenNeededAndDropsCorruptLines() throws {
        try store.append([HistoryEntry(ts: t0.addingTimeInterval(-100 * 86_400), kind: .apply, note: "old"),
                          HistoryEntry(ts: t0, kind: .apply, note: "new")])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n".utf8))
        try handle.close()
        XCTAssertEqual(try store.compact(now: t0).map(\.note), ["new"])
        XCTAssertEqual(try lines().count, 1)
        let before = try Data(contentsOf: fileURL)
        try store.compact(now: t0)
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    // MARK: Transitions

    func testSameStateTwiceRecordsNothingNew() async throws {
        let recorder = HistoryRecorder(store: store, now: { [t0] in t0 })
        let first = await recorder.observe(observation(bans: [(serverA, .ipBanned), (serverB, .ipOk)]))
        XCTAssertEqual(first.map(\.kind), [.refresh, .ipChanged, .identityChanged, .nameChanged, .modelChanged, .banAppeared])
        XCTAssertTrue(first.allSatisfy { $0.old == nil })   // first observation
        let second = await recorder.observe(observation(60, bans: [(serverA, .ipBanned), (serverB, .ipOk)]))
        XCTAssertEqual(second, [])
        XCTAssertEqual(store.load().count, 6)
    }

    func testTransitionsProduceOldAndNew() async throws {
        let recorder = HistoryRecorder(store: store, now: { [t0] in t0 })
        await recorder.observe(observation(bans: [(serverA, .ipBanned)]))
        let changed = await recorder.observe(observation(60, overall: .green, ip: "198.51.100.1", name: "M",
                                                         bans: [(serverA, .cidOk)]))
        XCTAssertEqual(changed.map(\.kind), [.refresh, .ipChanged, .nameChanged, .banLifted])
        let ip = try XCTUnwrap(changed.first { $0.kind == .ipChanged })
        XCTAssertEqual([ip.old, ip.new], ["203.0.113.7", "198.51.100.1"])
        let lifted = try XCTUnwrap(changed.last)
        XCTAssertEqual(lifted.serverID, serverA)
        XCTAssertEqual(lifted.host, "51.68.190.91")
        XCTAssertEqual([lifted.old, lifted.new], ["ipBanned", "cidOk"])

        // Ban type change is a new transition; undetermined results neither lift nor add a ban.
        let again = await recorder.observe(observation(120, overall: .green, ip: "198.51.100.1", name: "M",
                                                       bans: [(serverA, .cidBanned)]))
        XCTAssertEqual(again.map(\.kind), [.banAppeared])
        let unknown = await recorder.observe(observation(180, overall: .green, ip: "198.51.100.1", name: "M",
                                                         bans: [(serverA, .unreachable)]))
        XCTAssertEqual(unknown, [])
        // Unknown values (public IP unavailable) are not transitions.
        let noIP = await recorder.observe(observation(240, overall: .green, ip: nil, name: "M", bans: [(serverA, .cidBanned)]))
        XCTAssertEqual(noIP, [])
    }

    func testStateIsRebuiltFromFileSoARestartDoesNotDuplicate() async throws {
        let first = HistoryRecorder(store: store, now: { [t0] in t0 })
        await first.observe(observation(bans: [(serverA, .ipBanned)]))
        await first.record(HistoryEntry(ts: t0, kind: .fixAttempt, serverID: serverA, old: "1", new: "2", note: "resolved"))
        let restarted = HistoryRecorder(store: store, now: { [t0] in t0 })
        let entries = await restarted.observe(observation(60, bans: [(serverA, .ipBanned)]))
        XCTAssertEqual(entries, [])
        XCTAssertEqual(HistoryState(replaying: store.load()).bans, [serverA: "ipBanned"])
    }

    func testRecorderAppliesRetentionOnLoad() async throws {
        try store.append([HistoryEntry(ts: t0.addingTimeInterval(-120 * 86_400), kind: .ipChanged, new: "1.1.1.1")])
        let recorder = HistoryRecorder(store: store, now: { [t0] in t0 })
        let entries = await recorder.observe(observation(ip: "1.1.1.1"))
        // The 120-day-old entry is pruned, so the IP is a first observation again.
        XCTAssertTrue(entries.contains { $0.kind == .ipChanged && $0.old == nil && $0.new == "1.1.1.1" })
        XCTAssertFalse(store.load().contains { $0.ts < t0 })
    }

    // MARK: Filter and export

    func testFilterByServerAndKindNewestFirst() {
        let entries = [HistoryEntry(ts: t0, kind: .banAppeared, serverID: serverA, new: "ipBanned"),
                       HistoryEntry(ts: t0.addingTimeInterval(10), kind: .ipChanged, new: "x"),
                       HistoryEntry(ts: t0.addingTimeInterval(20), kind: .banLifted, serverID: serverA, new: "ipOk"),
                       HistoryEntry(ts: t0.addingTimeInterval(20), kind: .banAppeared, serverID: serverB, new: "cidBanned")]
        XCTAssertEqual(HistoryFilter().apply(entries).map(\.ts), [entries[3].ts, entries[2].ts, entries[1].ts, entries[0].ts])
        XCTAssertEqual(HistoryFilter().apply(entries).first?.serverID, serverB)   // equal ts: later line first
        XCTAssertEqual(HistoryFilter(serverID: serverA).apply(entries).map(\.kind), [.banLifted, .banAppeared])
        XCTAssertEqual(HistoryFilter(kinds: [.banAppeared]).apply(entries).map(\.serverID), [serverB, serverA])
        XCTAssertEqual(HistoryFilter(serverID: serverA, kinds: [.ipChanged]).apply(entries), [])
    }

    func testJSONExportRoundtrips() throws {
        let entries = [HistoryEntry(ts: t0, kind: .apply, new: "name=A", note: "config.cfg + userconfig.cfg"),
                       HistoryEntry(ts: t0, kind: .banAppeared, serverID: serverA, host: "h", old: nil, new: "ipBanned")]
        let json = HistoryExport.json(entries)
        let decoded = try HistoryCoding.makeDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, entries)
        XCTAssertEqual(try HistoryCoding.makeDecoder().decode([HistoryEntry].self, from: Data(HistoryExport.json([]).utf8)), [])
    }

    func testMarkdownExportEscapesCells() {
        let entries = [HistoryEntry(ts: t0, kind: .apply, host: "a|b", new: "x\ny", note: "back\\slash")]
        let markdown = HistoryExport.markdown(entries)
        let rows = markdown.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows[0], "| ts | kind | serverID | host | old | new | note |")
        XCTAssertEqual(rows[1], "|---|---|---|---|---|---|---|")
        XCTAssertEqual(rows[2], #"| 2026-10-26T07:33:20Z | apply |  | a\|b |  | x y | back\\slash |"#)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(HistoryExport.markdown([]).split(separator: "\n").count, 2)
    }
}

/// §22 in the app flow (fake network).
@MainActor
final class AppModelHistoryTests: XCTestCase {
    private var temp: TempDirectory!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        temp = try TempDirectory()
        suiteName = "PlayerIdentityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        try temp.write("home/Library/Application Support/Xash3D FWGS/valve/config.cfg", "name \"N\"\nmodel \"gordon\"\n")
        try temp.write("home/.config/.xash_id", "10331C2DCE4C91DB")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        temp = nil
    }

    private var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }

    private func makeModel(script: HTTPScript, udp: FakeUDPTransport) -> AppModel {
        let clock = TestClock()
        return AppModel(dependencies: AppDependencies(
            paths: AppPaths(home: home),
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: [LocalAddress(interface: "en0", family: .ipv4, address: "192.0.2.10")]),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: script)),
            snapshotStore: SnapshotStore(fileURL: AppPaths(home: home).snapshotFile),
            defaults: defaults,
            now: { clock.now },
            udpTransport: udp,
            gameProcessDetector: FakeGameDetector(),
            commandRunner: FakeCommandRunner(),
            sleeper: FakeSleeper(clock: clock),
            resolver: FakeAddressResolver()))
    }

    func testRefreshRecordsTransitionsOnly() async throws {
        let script = HTTPScript(bodies: [1: #"{"ip":"203.0.113.7"}"#, 2: #"{"ip":"203.0.113.7"}"#],
                                defaultBody: #"{"ip":"198.51.100.1"}"#)
        let model = makeModel(script: script, udp: FakeServer.healthy())
        await model.refresh().value
        await model.waitForHistory()
        let store = HistoryStore(fileURL: AppPaths(home: home).historyFile)
        let firstCount = store.load().count
        XCTAssertEqual(store.load().map(\.kind), [.refresh, .ipChanged, .identityChanged, .nameChanged, .modelChanged])
        XCTAssertGreaterThan(firstCount, 0)

        await model.refresh().value
        await model.waitForHistory()
        XCTAssertEqual(store.load().count, firstCount)   // same state → nothing new

        await model.refresh().value
        await model.waitForHistory()
        let last = try XCTUnwrap(store.load().last)
        XCTAssertEqual(last.kind, .ipChanged)
        XCTAssertEqual([last.old, last.new], ["203.0.113.7", "198.51.100.1"])
    }
}

import XCTest
@testable import PlayerIdentity

/// §39 metrics.jsonl: write/read, retention, uptime, 24 h series, export, corrupt lines.
final class MetricsTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let a = UUID(), b = UUID()
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    private var store: MetricsStore { MetricsStore(fileURL: temp.url.appendingPathComponent("metrics.jsonl")) }

    private func sample(_ id: UUID, _ offset: TimeInterval, online: Bool = true, ping: Int? = 40) -> MetricSample {
        MetricSample(ts: Self.t0 + offset, serverID: id, host: "192.0.2.10", online: online, ping: ping, players: 9,
                     maxPlayers: 26, map: "rpg_city")
    }

    func testWriteReadAndCorruptLines() throws {
        try store.append([sample(a, 0), sample(b, 1, online: false, ping: nil)])
        // A cut-short line in the middle must not break the following ones.
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"ts":"2026-"#.utf8))
        try handle.close()
        try store.append([sample(a, 2)])
        let loaded = store.load()
        XCTAssertEqual(loaded, [sample(a, 0), sample(b, 1, online: false, ping: nil), sample(a, 2)])
        let firstLine = try XCTUnwrap(String(contentsOf: store.fileURL, encoding: .utf8).split(separator: "\n").first)
        XCTAssertEqual(String(firstLine), #"{"host":"192.0.2.10","map":"rpg_city","maxPlayers":26,"online":true,"ping":40,"players":9,"serverID":"\#(a.uuidString)","ts":"2026-10-26T07:33:20Z"}"#)
        XCTAssertEqual(MetricsStore(fileURL: temp.url.appendingPathComponent("none.jsonl")).load(), [])
    }

    func testRetentionThirtyDaysAndFiveThousandPerServer() throws {
        let now = Self.t0 + 31 * 86_400
        var samples = [sample(b, 0)]                                      // older than 30 days
        samples += (0..<5010).map { sample(a, 86_400 + Double($0)) }       // 10 over the limit
        samples += [sample(b, 2 * 86_400)]
        let kept = MetricsRetention.apply(samples, now: now)
        XCTAssertEqual(kept.filter { $0.serverID == a }.count, 5000)
        XCTAssertEqual(kept.first { $0.serverID == a }?.ts, Self.t0 + 86_400 + 10)   // the oldest dropped
        XCTAssertEqual(kept.filter { $0.serverID == b }.map(\.ts), [Self.t0 + 2 * 86_400])

        try store.append(samples)
        XCTAssertEqual(try store.compact(now: now).count, 5001)
        XCTAssertEqual(store.load().count, 5001)
    }

    func testRecorderCompactsWhenAServerPassesTheLimit() async throws {
        let recorder = MetricsRecorder(store: store, now: { Self.t0 + 86_400 })
        await recorder.record((0..<4999).map { sample(a, Double($0)) })
        await recorder.record([sample(a, 5000), sample(a, 5001), sample(b, 5002)])
        XCTAssertEqual(store.load().filter { $0.serverID == a }.count, 5000)
        XCTAssertEqual(store.load().filter { $0.serverID == b }.count, 1)
    }

    func testUptimeAndSeries() {
        let now = Self.t0 + 86_400
        let samples = [sample(a, -10), sample(a, 3600), sample(a, 7200, online: false, ping: nil), sample(a, 10_800),
                       sample(a, 14_400, online: false, ping: 999), sample(b, 3600, online: false)]
        XCTAssertEqual(MetricsAnalysis.uptime(samples, serverID: a, now: now), 0.5)      // 2 of 4 in the last 24 h
        XCTAssertEqual(MetricsAnalysis.uptime(samples, serverID: b, now: now), 0)
        XCTAssertNil(MetricsAnalysis.uptime(samples, serverID: UUID(), now: now))         // empty series
        let series = MetricsAnalysis.series(samples, serverID: a, now: now)
        XCTAssertEqual(series.map(\.ts), [Self.t0 + 3600, Self.t0 + 7200, Self.t0 + 10_800, Self.t0 + 14_400])
        XCTAssertEqual(series.map(\.ping), [40, nil, 40, nil])                            // offline: no ping
        XCTAssertEqual(MetricsAnalysis.series([], serverID: a, now: now), [])
    }

    func testSampleFromBanCheck() {
        let online = BanCheck(status: .cidOk, checkedAt: Self.t0, detail: "",
                              info: ServerInfo(map: "de_dust2", players: 3, maxPlayers: 16, pingMillis: 27))
        XCTAssertEqual(MetricSample(check: online, serverID: a, host: "h"),
                       MetricSample(ts: Self.t0, serverID: a, host: "h", online: true, ping: 27, players: 3, maxPlayers: 16,
                                    map: "de_dust2"))
        let offline = BanCheck(status: .unreachable, checkedAt: Self.t0, detail: "")
        XCTAssertFalse(MetricSample(check: offline, serverID: a, host: "h").online)
        XCTAssertTrue(MetricSample(check: BanCheck(status: .ipBanned, checkedAt: Self.t0, detail: ""), serverID: a, host: "h").online)
    }

    func testExport() throws {
        let samples = [sample(a, 0), MetricSample(ts: Self.t0, serverID: b, host: "eu, 1", online: false, map: "a\"b")]
        let csv = MetricsExport.csv(samples)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "ts,serverID,host,online,ping,players,maxPlayers,map")
        XCTAssertEqual(lines[1], "2026-10-26T07:33:20Z,\(a.uuidString),192.0.2.10,true,40,9,26,rpg_city")
        XCTAssertEqual(lines[2], "2026-10-26T07:33:20Z,\(b.uuidString),\"eu, 1\",false,,,,\"a\"\"b\"")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MetricsExport.json(samples).utf8)) as? [[String: Any]])
        XCTAssertEqual(json.count, 2)
        XCTAssertEqual(json[0]["ping"] as? Int, 40)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(MetricsExport.json([]).utf8)) as? [Any])?.count, 0)
    }

    @MainActor
    func testRefreshRecordsASampleForTheCheck() async throws {
        let env = try TestAppEnvironment()
        let healthy = FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(
            info: FakeReply(bytes: A2SFixture.goldSrc(), delay: 0.03)))
        let model = env.makeModel(udp: healthy)
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        await model.refresh().value
        let first = await model.loadMetrics()
        XCTAssertEqual(first.count, 1)
        let online = try XCTUnwrap(first.first)
        XCTAssertTrue(online.online)
        XCTAssertEqual(online.map, "rpg_city")
        XCTAssertEqual(online.players, 9)
        XCTAssertNotNil(online.ping)
    }

    @MainActor
    func testUnreachableCheckIsRecordedOffline() async throws {
        let env = try TestAppEnvironment()
        let udp = FakeUDPTransport(clock: env.clock, responder: FakeServer.scripted(info: nil, challenge: nil, connect: nil))
        let model = env.makeModel(udp: udp)
        model.addServer(ServerDraft(label: "B", host: "192.0.2.20"))
        await model.refresh().value
        let samples = await model.loadMetrics()
        XCTAssertEqual(samples.map(\.online), [false])
        XCTAssertNil(samples.first?.ping)
    }
}

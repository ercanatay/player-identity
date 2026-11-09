import XCTest
@testable import PlayerIdentity

/// §31 groups, favorites, order; §32 notes and appeals; backward compatibility of the record.
@MainActor
final class ServerOrganizationTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func entry(_ label: String, group: String? = nil, favorite: Bool = false, order: Int = 0,
                       ban: BanStatus? = nil) -> ServerEntry {
        ServerEntry(label: label, host: "192.0.2.10", banCheck: ban.map { BanCheck(status: $0, checkedAt: Self.t0, detail: "") },
                    group: group, favorite: favorite, order: order)
    }

    // MARK: Backward compatibility

    func testOldRecordWithoutNewFieldsDecodes() throws {
        let json = """
        {"schemaVersion":1,"savedAt":"2026-11-08T11:21:00Z","gamedir":"valve","dataRoot":"/d","displayName":"x",
         "model":"y","rawID":"0000000000000000","identitySource":"/h/.config/.xash_id",
         "network":{"publicIP":"198.51.100.1","lanIPs":[]},
         "servers":[{"id":"1E390D91-9114-454E-A9B3-4AB1833ACD48","label":"A","host":"192.0.2.10","port":27015,"cid":""}]}
        """
        let snapshot = try XCTUnwrap(SnapshotStore.decode(Data(json.utf8)).snapshot)
        let server = try XCTUnwrap(snapshot.servers.first)
        XCTAssertNil(server.group)
        XCTAssertFalse(server.favorite)
        XCTAssertEqual(server.order, 0)
        XCTAssertEqual(server.note, "")
        XCTAssertNil(server.appeal)
    }

    func testNewFieldsRoundTrip() throws {
        var server = entry("A", group: "EU", favorite: true, order: 3)
        server.note = "not"
        server.appeal = Appeal(sentAt: Self.t0, channel: .discord, status: .answered,
                               followUpAt: Self.t0.addingTimeInterval(86_400), summary: "ozet")
        let data = try SnapshotStore.makeEncoder().encode(server)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["group"] as? String, "EU")
        XCTAssertEqual(object["favorite"] as? Bool, true)
        XCTAssertEqual(object["order"] as? Int, 3)
        let appeal = try XCTUnwrap(object["appeal"] as? [String: Any])
        XCTAssertEqual(appeal["status"] as? String, "answered")
        XCTAssertEqual(appeal["channel"] as? String, "discord")
        XCTAssertEqual(try SnapshotStore.makeDecoder().decode(ServerEntry.self, from: data), server)

        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotStore.makeEncoder().encode(entry("B")))
                                    as? [String: Any])
        XCTAssertNil(plain["group"])       // no group → key left out
        XCTAssertNil(plain["appeal"])
    }

    // MARK: Grouping and sorting

    func testSectionsSortGroupsAndPutUngroupedLast() {
        let servers = [entry("u1"), entry("b", group: "Turkey"), entry("a", group: "Europe"), entry("u2", favorite: true),
                       entry("c", group: " Europe "), entry("d", group: "asia"), entry("e", group: "  ")]
        XCTAssertEqual(ServerOrganization.groups(servers), ["asia", "Europe", "Turkey"])
        let sections = ServerOrganization.sections(servers)
        XCTAssertEqual(sections.map(\.group), ["asia", "Europe", "Turkey", nil])
        XCTAssertEqual(sections[1].servers.map(\.label), ["a", "c"])
        XCTAssertEqual(sections.last?.servers.map(\.label), ["u2", "u1", "e"])   // favorite first; blank group = none
    }

    func testSortingFavoritesThenOrderThenArrayOrder() {
        let servers = [entry("x", order: 2), entry("y", order: 1), entry("z", favorite: true, order: 9), entry("w", order: 1)]
        XCTAssertEqual(ServerOrganization.sorted(servers).map(\.label), ["z", "y", "w", "x"])
        // Old records: every order is 0 → the array order is kept.
        let legacy = [entry("1"), entry("2"), entry("3")]
        XCTAssertEqual(ServerOrganization.sorted(legacy).map(\.label), ["1", "2", "3"])
    }

    func testFilters() {
        let servers = [entry("ok", ban: .cidOk), entry("ip", ban: .ipBanned), entry("cid", favorite: true, ban: .cidBanned),
                       entry("fav", favorite: true), entry("unreachable", ban: .unreachable)]
        func labels(_ filter: ServerListFilter) -> [String] {
            ServerOrganization.sections(servers, filter: filter).flatMap(\.servers).map(\.label)
        }
        XCTAssertEqual(labels(ServerListFilter(onlyBanned: true)), ["cid", "ip"])
        XCTAssertEqual(labels(ServerListFilter(onlyFavorites: true)), ["cid", "fav"])
        XCTAssertEqual(labels(ServerListFilter(onlyBanned: true, onlyFavorites: true)), ["cid"])
        XCTAssertEqual(labels(ServerListFilter()).count, 5)
        XCTAssertEqual(ServerOrganization.sections([entry("ok")], filter: ServerListFilter(onlyBanned: true)), [])
    }

    func testNewGroupAndExistingSpelling() {
        let existing = ["Europe", "Turkey"]
        XCTAssertEqual(ServerOrganization.resolveGroup("  europe ", existing: existing), "Europe")
        XCTAssertEqual(ServerOrganization.resolveGroup("Asia", existing: existing), "Asia")
        XCTAssertNil(ServerOrganization.resolveGroup("   ", existing: existing))
        XCTAssertNil(ServerOrganization.resolveGroup(nil, existing: existing))
        XCTAssertEqual(ServerDraft(label: "a", host: "192.0.2.1", group: "TURKEY").resolvedGroup(existing: existing), "Turkey")
    }

    func testMoveUpAndDownInsideASection() throws {
        let a = entry("a"), b = entry("b"), c = entry("c"), f = entry("f", favorite: true), g = entry("g", group: "G")
        let servers = [a, b, c, f, g]
        XCTAssertFalse(ServerOrganization.canMove(a.id, .up, in: servers))      // below the favorite: different state
        XCTAssertFalse(ServerOrganization.canMove(f.id, .down, in: servers))
        XCTAssertFalse(ServerOrganization.canMove(g.id, .down, in: servers))    // alone in its group
        XCTAssertTrue(ServerOrganization.canMove(b.id, .up, in: servers))

        let moved = try XCTUnwrap(ServerOrganization.move(c.id, .up, in: servers))
        XCTAssertEqual(moved.map(\.label), ["a", "b", "c", "f", "g"])            // array order kept
        XCTAssertEqual(ServerOrganization.sections(moved).last?.servers.map(\.label), ["f", "a", "c", "b"])
        XCTAssertEqual(Set(moved.map(\.order)).count, 5)                         // renumbered, unique
        let back = try XCTUnwrap(ServerOrganization.move(c.id, .down, in: moved))
        XCTAssertEqual(ServerOrganization.sections(back).last?.servers.map(\.label), ["f", "a", "b", "c"])
        XCTAssertNil(ServerOrganization.move(UUID(), .up, in: servers))
        XCTAssertEqual(ServerOrganization.nextOrder(moved), 5)
        XCTAssertEqual(ServerOrganization.nextOrder([]), 0)
    }

    func testAppModelGroupsFavoritesAndOrderAreSaved() throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10", group: "Europe"))
        model.addServer(ServerDraft(label: "B", host: "192.0.2.11", group: " europe ", favorite: true))
        model.addServer(ServerDraft(label: "C", host: "192.0.2.12"))
        XCTAssertEqual(model.servers.map(\.order), [0, 1, 2])
        XCTAssertEqual(model.servers.map(\.group), ["Europe", "Europe", nil])
        XCTAssertEqual(model.serverGroups, ["Europe"])
        XCTAssertEqual(model.serverSections().map { $0.servers.map(\.label) }, [["B", "A"], ["C"]])

        let a = model.servers[0].id
        model.setFavorite(true, for: a)
        XCTAssertEqual(model.serverSections().first?.servers.map(\.label), ["A", "B"])
        XCTAssertFalse(model.canMoveServer(id: a, .up))
        XCTAssertTrue(model.canMoveServer(id: a, .down))
        model.moveServer(id: a, .down)
        XCTAssertEqual(model.serverSections().first?.servers.map(\.label), ["B", "A"])
        XCTAssertEqual(model.serverSections(filter: ServerListFilter(onlyFavorites: true)).flatMap(\.servers).count, 2)
        model.save()
        let saved = try XCTUnwrap(SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot)
        XCTAssertEqual(saved.servers.map(\.favorite), [true, true, false])
        XCTAssertEqual(ServerOrganization.sections(saved.servers).first?.servers.map(\.label), ["B", "A"])
        XCTAssertFalse(model.hasUnsavedChanges)

        // Editing keeps group/favorite from the form.
        model.updateServer(id: a, with: ServerDraft(label: "A", host: "192.0.2.10", group: "", favorite: false))
        XCTAssertNil(model.servers[0].group)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    // MARK: §32 notes

    func testNoteValidationAndLength() {
        XCTAssertTrue(ServerNote.isValid(String(repeating: "a", count: 2000)))
        XCTAssertFalse(ServerNote.isValid(String(repeating: "a", count: 2001)))
        XCTAssertTrue(ServerNote.isValid(String(repeating: "ğ", count: 2000)))   // characters, not bytes
        XCTAssertEqual(ServerNote.clamped(String(repeating: "b", count: 2500)).count, 2000)
        let server = entry("A")
        XCTAssertEqual(ServerAnnotations.setNote(String(repeating: "x", count: 2001), for: server.id, in: [server]),
                       .failure(.noteTooLong))
        XCTAssertEqual(ServerAnnotations.setNote("n", for: UUID(), in: [server]), .failure(.serverNotFound))
        XCTAssertEqual(try ServerAnnotations.setNote("n", for: server.id, in: [server]).get().first?.note, "n")
    }

    // MARK: §32 appeals

    func testAppealValidationAndFollowUp() {
        var appeal = Appeal(sentAt: Self.t0, channel: .telegram)
        XCTAssertTrue(appeal.isValid)
        XCTAssertEqual(appeal.knownChannel, .telegram)
        XCTAssertNil(Appeal(sentAt: Self.t0, channel: "Steam grubu").knownChannel)   // free text is kept
        XCTAssertFalse(appeal.isFollowUpDue(now: Self.t0.addingTimeInterval(1e6)))   // no date

        appeal.followUpAt = Self.t0.addingTimeInterval(3600)
        XCTAssertFalse(appeal.isFollowUpDue(now: Self.t0))
        XCTAssertTrue(appeal.isFollowUpDue(now: Self.t0.addingTimeInterval(3600)))
        appeal.status = .accepted
        XCTAssertFalse(appeal.isFollowUpDue(now: Self.t0.addingTimeInterval(7200)))  // closed: no reminder

        let bad = Appeal(sentAt: Self.t0, channel: " ", followUpAt: Self.t0.addingTimeInterval(-1),
                         summary: String(repeating: "s", count: 2001))
        XCTAssertEqual(bad.problems, [.channelEmpty, .summaryTooLong, .followUpBeforeSent])
    }

    func testAppealStatusTransitions() {
        XCTAssertEqual(AppealStatus.allCases.map(\.rawValue), ["sent", "answered", "rejected", "accepted"])
        XCTAssertTrue(AppealStatus.sent.canTransition(to: .answered))
        XCTAssertTrue(AppealStatus.sent.canTransition(to: .accepted))
        XCTAssertTrue(AppealStatus.answered.canTransition(to: .rejected))
        XCTAssertTrue(AppealStatus.rejected.canTransition(to: .sent))           // sent again
        XCTAssertFalse(AppealStatus.rejected.canTransition(to: .accepted))
        XCTAssertFalse(AppealStatus.accepted.canTransition(to: .sent))          // final
        XCTAssertTrue(AppealStatus.accepted.canTransition(to: .accepted))
        let appeal = Appeal(sentAt: Self.t0, channel: .forum, status: .accepted)
        XCTAssertNil(appeal.moved(to: .rejected))
        XCTAssertEqual(Appeal(sentAt: Self.t0, channel: .forum).moved(to: .rejected)?.status, .rejected)
    }

    func testAppealCRUDAndHistory() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)

        // Create
        let created = Appeal(sentAt: Self.t0, channel: .discord, summary: "IP ban itirazi")
        XCTAssertNil(model.saveAppeal(created, for: id))
        XCTAssertEqual(model.servers.first?.appeal?.hasSameContent(as: created), true)
        XCTAssertEqual(model.servers.first?.appeal?.events, [AppealEvent(status: .sent, at: Self.t0)])   // §36 timeline
        // Unchanged → no new history entry
        XCTAssertNil(model.saveAppeal(created, for: id))
        // Update with an allowed transition
        let answered = try XCTUnwrap(created.moved(to: .answered))
        XCTAssertNil(model.saveAppeal(answered, for: id))
        let accepted = try XCTUnwrap(answered.moved(to: .accepted))
        XCTAssertNil(model.saveAppeal(accepted, for: id))
        // Refused: final state, invalid content, unknown server
        var reopened = accepted
        reopened.status = .sent
        XCTAssertEqual(model.saveAppeal(reopened, for: id), .transitionNotAllowed(from: .accepted, to: .sent))
        XCTAssertEqual(model.saveAppeal(Appeal(sentAt: Self.t0, channel: ""), for: id), .invalid([.channelEmpty]))
        XCTAssertEqual(model.saveAppeal(created, for: UUID()), .serverNotFound)
        // Delete
        XCTAssertNil(model.saveAppeal(nil, for: id))
        XCTAssertNil(model.servers.first?.appeal)

        await model.waitForHistory()
        let entries = env.historyStore.load().filter { $0.kind == .appeal }
        XCTAssertEqual(entries.map(\.new), ["sent", "answered", "accepted", nil])
        XCTAssertEqual(entries.map(\.old), [nil, "sent", "answered", "accepted"])
        XCTAssertEqual(entries.first?.note, "discord")
        XCTAssertEqual(entries.first?.serverID, id)
        XCTAssertEqual(entries.first?.host, "192.0.2.10")
        XCTAssertNil(NotificationPlanner.content(for: entries[0], serverLabel: "A"))   // not a notification

        // Note through the model; saved with the record
        XCTAssertNil(model.setNote("admin: X", for: id))
        XCTAssertEqual(model.setNote(String(repeating: "x", count: 2001), for: id), .noteTooLong)
        model.save()
        let saved = try XCTUnwrap(SnapshotStore(fileURL: AppPaths(home: env.home).snapshotFile).load().snapshot)
        XCTAssertEqual(saved.servers.first?.note, "admin: X")
        XCTAssertEqual(HistoryState(replaying: entries), HistoryState())   // appeals do not change the dedupe state
    }
}

import XCTest
@testable import PlayerIdentity

/// §36 appeal timeline, one-time follow-up reminder, postponing, note history.
@MainActor
final class AppealTrackingTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let day: TimeInterval = 86_400
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func server(_ appeal: Appeal? = nil) -> ServerEntry {
        ServerEntry(label: "A", host: "192.0.2.10", appeal: appeal)
    }

    // MARK: Timeline

    func testEventsAreAddedOnStatusChanges() throws {
        let entry = server()
        let created = try ServerAnnotations.setAppeal(Appeal(sentAt: Self.t0, channel: .discord), for: entry.id,
                                                      in: [entry], now: Self.t0.addingTimeInterval(60)).get()
        XCTAssertEqual(created[0].appeal?.events, [AppealEvent(status: .sent, at: Self.t0)])   // starts at sentAt

        var edited = try XCTUnwrap(created[0].appeal)
        edited.summary = "only the summary"
        edited.events = []                                 // the form does not carry the timeline
        let same = try ServerAnnotations.setAppeal(edited, for: entry.id, in: created, now: Self.t0 + day).get()
        XCTAssertEqual(same[0].appeal?.events.count, 1)    // no status change → no event
        XCTAssertEqual(same[0].appeal?.summary, "only the summary")

        let answered = try XCTUnwrap(edited.moved(to: .answered))
        let next = try ServerAnnotations.setAppeal(answered, for: entry.id, in: same, now: Self.t0 + 2 * day).get()
        XCTAssertEqual(next[0].appeal?.events, [AppealEvent(status: .sent, at: Self.t0),
                                                AppealEvent(status: .answered, at: Self.t0 + 2 * day)])
        XCTAssertEqual(next[0].appeal?.timeline.map(\.status), [.sent, .answered])
    }

    func testAtMostTwentyEvents() {
        var appeal = Appeal(sentAt: Self.t0, channel: .forum)
        for index in 0..<25 {
            appeal = appeal.appendingEvent(index.isMultiple(of: 2) ? .rejected : .sent, at: Self.t0 + Double(index))
        }
        XCTAssertEqual(appeal.events.count, Appeal.maxEvents)
        XCTAssertEqual(appeal.events.first?.at, Self.t0 + 5)      // the oldest five dropped
        XCTAssertEqual(appeal.events.last?.at, Self.t0 + 24)
    }

    func testOldRecordsDecodeWithoutTimeline() throws {
        let json = #"{"sentAt":"2026-11-01T10:00:00Z","channel":"discord","status":"answered","summary":""}"#
        let appeal = try SnapshotStore.makeDecoder().decode(Appeal.self, from: Data(json.utf8))
        XCTAssertEqual(appeal.events, [])
        XCTAssertNil(appeal.notifiedAt)
        XCTAssertEqual(appeal.timeline, [AppealEvent(status: .answered, at: appeal.sentAt)])
        let encoded = try SnapshotStore.makeEncoder().encode(appeal.appendingEvent(.accepted, at: Self.t0))
        XCTAssertEqual(try SnapshotStore.makeDecoder().decode(Appeal.self, from: encoded).events.last?.status, .accepted)
    }

    // MARK: Reminder

    func testReminderOnlyOnce() {
        let appeal = Appeal(sentAt: Self.t0, channel: .discord, followUpAt: Self.t0 + day)
        let servers = [server(appeal), server(Appeal(sentAt: Self.t0, channel: .email, status: .accepted,
                                                     followUpAt: Self.t0 + day))]
        XCTAssertEqual(AppealReminder.due(servers, now: Self.t0, notificationsEnabled: true), [])   // not yet
        let due = AppealReminder.due(servers, now: Self.t0 + day, notificationsEnabled: true)
        XCTAssertEqual(due, [AppealReminder.Due(serverID: servers[0].id, label: "A", followUpAt: Self.t0 + day)])

        let marked = AppealReminder.markNotified([servers[0].id], in: servers, at: Self.t0 + day)
        XCTAssertEqual(marked[0].appeal?.notifiedAt, Self.t0 + day)
        XCTAssertEqual(AppealReminder.due(marked, now: Self.t0 + 5 * day, notificationsEnabled: true), [])   // once
    }

    func testNotificationsOffMeansNoReminderAndNothingMarked() {
        let servers = [server(Appeal(sentAt: Self.t0, channel: .discord, followUpAt: Self.t0))]
        XCTAssertEqual(AppealReminder.due(servers, now: Self.t0 + day, notificationsEnabled: false), [])
        XCTAssertEqual(AppealReminder.due(servers, now: Self.t0 + day, notificationsEnabled: true).count, 1)
    }

    func testPostponeAndChangedDateArmTheReminderAgain() throws {
        let notified = Appeal(sentAt: Self.t0, channel: "discord", followUpAt: Self.t0 + day, notifiedAt: Self.t0 + day)
        // Overdue: +1 day from now.
        let later = notified.postponed(byDays: 1, now: Self.t0 + 2 * day, calendar: utc)
        XCTAssertEqual(later.followUpAt, Self.t0 + 3 * day)
        XCTAssertNil(later.notifiedAt)
        XCTAssertFalse(later.needsReminder(now: Self.t0 + 2 * day))
        XCTAssertTrue(later.needsReminder(now: Self.t0 + 3 * day))
        // Still in the future: +3 days from the follow-up date.
        XCTAssertEqual(notified.postponed(byDays: 3, now: Self.t0, calendar: utc).followUpAt, Self.t0 + 4 * day)
        // No date yet: from now.
        XCTAssertEqual(Appeal(sentAt: Self.t0, channel: .forum).postponed(byDays: 1, now: Self.t0, calendar: utc).followUpAt,
                       Self.t0 + day)

        // Editing the date in the form resets `notifiedAt`; editing something else keeps it.
        let entry = server(notified)
        var moved = notified
        moved.followUpAt = Self.t0 + 9 * day
        XCTAssertNil(try ServerAnnotations.setAppeal(moved, for: entry.id, in: [entry], now: Self.t0).get()[0].appeal?.notifiedAt)
        var summary = notified
        summary.summary = "x"
        XCTAssertEqual(try ServerAnnotations.setAppeal(summary, for: entry.id, in: [entry], now: Self.t0).get()[0]
            .appeal?.notifiedAt, Self.t0 + day)
    }

    func testAppModelRemindersAndPostpone() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertNil(model.saveAppeal(Appeal(sentAt: env.clock.now, channel: .discord,
                                             followUpAt: env.clock.now.addingTimeInterval(3600)), for: id))
        env.clock.advance(3600)
        XCTAssertEqual(model.dueAppealReminders().map(\.serverID), [id])
        model.markAppealsNotified([id])
        XCTAssertEqual(model.dueAppealReminders(), [])

        XCTAssertNil(model.postponeFollowUp(byDays: 3, for: id))
        XCTAssertEqual(try XCTUnwrap(model.servers.first?.appeal?.followUpAt).timeIntervalSince(env.clock.now),
                       3 * day, accuracy: 3600 + 1)   // DST-safe calendar days
        env.clock.advance(4 * day)
        XCTAssertEqual(model.dueAppealReminders().count, 1)
        model.notificationsEnabled = false
        XCTAssertEqual(model.dueAppealReminders(), [])
        XCTAssertEqual(model.postponeFollowUp(byDays: 1, for: UUID()), .serverNotFound)
    }

    // MARK: Note history

    func testNoteChangesAreRecorded() async throws {
        let env = try TestAppEnvironment()
        let model = env.makeModel()
        model.addServer(ServerDraft(label: "A", host: "192.0.2.10"))
        let id = try XCTUnwrap(model.servers.first?.id)
        XCTAssertNil(model.setNote("first", for: id))
        XCTAssertNil(model.setNote("first", for: id))            // unchanged → no entry
        let long = String(repeating: "x", count: 1200)
        XCTAssertNil(model.setNote(long, for: id))
        XCTAssertNil(model.setNote("", for: id))
        await model.waitForHistory()
        let notes = env.historyStore.load().filter { $0.kind == .note }
        XCTAssertEqual(notes.count, 3)
        XCTAssertNil(notes[0].old)
        XCTAssertEqual(notes[0].new, "first")
        XCTAssertEqual(notes[1].old, "first")
        XCTAssertEqual(notes[1].new?.count, ServerAnnotations.noteHistoryLimit)
        XCTAssertTrue(notes[1].new?.hasSuffix("…") ?? false)
        XCTAssertNil(notes[2].new)
        XCTAssertEqual(notes[0].serverID, id)
        XCTAssertNil(NotificationPlanner.content(for: notes[0], serverLabel: "A"))
        XCTAssertEqual(HistoryState(replaying: notes), HistoryState())
    }
}

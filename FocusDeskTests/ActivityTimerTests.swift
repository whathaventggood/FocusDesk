import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import FocusDeskCore
#else
@testable import FocusDesk
#endif

final class ActivityTimerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_376_000)

    private func document() throws -> ActivityTimerDocument {
        var document = ActivityTimerDocument()
        try document.addActivity(name: "阅读")
        return document
    }

    func testRenamePreservesIdentityAndSessionsAndRejectsInvalidNames() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.addActivity(name: "运动")
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: start)
        document.togglePause(at: start.addingTimeInterval(60))
        let sessions = document.sessions
        try document.renameActivity(id: id, name: "  阅读书籍  ")
        XCTAssertEqual(document.activities[0], TimedActivity(id: id, name: "阅读书籍"))
        XCTAssertEqual(document.sessions, sessions)
        XCTAssertEqual(document.total(for: [id], at: start.addingTimeInterval(1000)), 60)
        try document.renameActivity(id: id, name: "阅读书籍")
        XCTAssertThrowsError(try document.renameActivity(id: id, name: "  "))
        XCTAssertThrowsError(try document.renameActivity(id: id, name: "运动"))
        XCTAssertThrowsError(try document.renameActivity(id: UUID(), name: "新名称"))
        XCTAssertEqual(document.activities[0].name, "阅读书籍")
        try document.validate()
    }

    func testDeleteRemovesOnlyMatchingActivityAndItsHistoryIncludingActiveSession() throws {
        var document = try document()
        let first = document.activities[0].id
        try document.addActivity(name: "运动")
        let second = document.activities[1].id
        try document.start(activityID: first, mode: .stopwatch, duration: nil, at: start)
        document.finish(at: start.addingTimeInterval(60))
        try document.start(activityID: second, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(60))
        document.finish(at: start.addingTimeInterval(90))
        let retainedSession = document.sessions[1]
        try document.start(activityID: first, mode: .countdown, duration: 120, at: start.addingTimeInterval(90))
        document.togglePause(at: start.addingTimeInterval(100))
        try document.deleteActivity(id: first)
        XCTAssertNil(document.activeSession)
        XCTAssertEqual(document.activities.map(\.id), [second])
        XCTAssertEqual(document.sessions, [retainedSession])
        XCTAssertEqual(document.total(for: [first, second], at: start.addingTimeInterval(1000)), 30)
        XCTAssertThrowsError(try document.deleteActivity(id: first))
        try document.addActivity(name: "阅读")
        let recreated = document.activities[1].id
        XCTAssertNotEqual(recreated, first)
        XCTAssertEqual(document.total(for: [recreated], at: start), 0)
        try document.deleteActivity(id: second)
        try document.deleteActivity(id: recreated)
        XCTAssertTrue(document.activities.isEmpty)
        XCTAssertTrue(document.sessions.isEmpty)
        try document.validate()
    }

    func testDurationSortRespectsRangeLiveSessionsAndStableTies() throws {
        var document = try document()
        try document.addActivity(name: "运动")
        try document.addActivity(name: "练字")
        try document.addActivity(name: "散步")
        let ids = document.activities.map(\.id)
        try document.start(activityID: ids[0], mode: .stopwatch, duration: nil, at: start)
        document.finish(at: start.addingTimeInterval(100))
        try document.start(activityID: ids[1], mode: .stopwatch, duration: nil, at: start.addingTimeInterval(100))
        let now = start.addingTimeInterval(140)
        XCTAssertEqual(document.durationSummaries(at: now, order: .descending).map(\.id), [ids[0], ids[1], ids[2], ids[3]])
        XCTAssertEqual(document.durationSummaries(at: now, order: .ascending).map(\.id), [ids[2], ids[3], ids[1], ids[0]])
        let interval = DateInterval(start: start.addingTimeInterval(90), end: now)
        let range = document.durationSummaries(at: now, in: interval, order: .descending)
        XCTAssertEqual(range.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertEqual(range.map(\.duration), [40, 10, 0, 0])
        XCTAssertEqual(document.durationSummaries(at: start.addingTimeInterval(200), order: .ascending).map(\.id), [ids[2], ids[3], ids[0], ids[1]])
    }

    func testStopwatchPauseResumeAndRepeatedSessionsAccumulate() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: start)
        document.togglePause(at: start.addingTimeInterval(60))
        XCTAssertEqual(document.activeSession?.elapsed(at: start.addingTimeInterval(200)), 60)
        document.togglePause(at: start.addingTimeInterval(200))
        document.finish(at: start.addingTimeInterval(230))
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(300))
        XCTAssertEqual(document.total(for: [id], at: start.addingTimeInterval(310)), 100)
        document.finish(at: start.addingTimeInterval(310))
        XCTAssertNil(document.activeSession)
        XCTAssertEqual(document.sessions.count, 2)
        try document.validate()
    }

    func testCountdownCapsAtTargetAfterWakeAndCompletesOnce() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .countdown, duration: 25 * 60, at: start)
        XCTAssertFalse(document.completeCountdown(at: start.addingTimeInterval(1499)))
        XCTAssertEqual(document.total(for: [id], at: start.addingTimeInterval(8000)), 1500)
        XCTAssertTrue(document.completeCountdown(at: start.addingTimeInterval(8000)))
        XCTAssertNil(document.activeSession)
        XCTAssertEqual(document.sessions[0].endedAt, start.addingTimeInterval(1500))
        XCTAssertEqual(document.sessions[0].savedDuration, 1500)
        XCTAssertFalse(document.completeCountdown(at: start.addingTimeInterval(9000)))
        try document.validate()
    }

    func testPausedCountdownResumesWithRemainingTimeAndCanEndEarly() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .countdown, duration: 120, at: start)
        document.togglePause(at: start.addingTimeInterval(30))
        XCTAssertFalse(document.completeCountdown(at: start.addingTimeInterval(1000)))
        XCTAssertEqual(document.activeSession?.remaining(at: start.addingTimeInterval(1000)), 90)
        document.togglePause(at: start.addingTimeInterval(1000))
        document.finish(at: start.addingTimeInterval(1010))
        XCTAssertEqual(document.sessions[0].savedDuration, 40)
        try document.validate()
    }

    func testExactCountdownBoundaryAndPauseCannotLeaveFinishedTimerActive() throws {
        var document = try document()
        try document.start(activityID: document.activities[0].id, mode: .countdown, duration: 1, at: start)
        document.togglePause(at: start.addingTimeInterval(1))
        XCTAssertNil(document.activeSession)
        XCTAssertEqual(document.sessions[0].savedDuration, 1)
    }

    func testRangeStatisticsClipCrossMidnightAndExcludePausedTime() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-31T16:00:00Z")!
        var document = try document()
        let first = document.activities[0].id
        try document.addActivity(name: "运动")
        let second = document.activities[1].id
        try document.start(activityID: first, mode: .stopwatch, duration: nil, at: midnight.addingTimeInterval(-60))
        document.togglePause(at: midnight.addingTimeInterval(60))
        document.togglePause(at: midnight.addingTimeInterval(180))
        document.finish(at: midnight.addingTimeInterval(240))
        try document.start(activityID: second, mode: .stopwatch, duration: nil, at: midnight.addingTimeInterval(240))
        let now = midnight.addingTimeInterval(300)
        let today = DateInterval(start: midnight, end: now)
        XCTAssertEqual(document.total(for: [first], at: now, in: today), 120)
        XCTAssertEqual(document.total(for: [second], at: now, in: today), 60)
        XCTAssertEqual(document.total(for: [first, second], at: now, in: today), 180)
        XCTAssertEqual(document.total(for: [first, second], at: now), 240)
        XCTAssertEqual(document.total(for: [], at: now), 0)
        XCTAssertEqual(document.total(for: [first], at: now, in: DateInterval(start: midnight.addingTimeInterval(1000), duration: 20)), 0)
    }

    func testClockRollbackNeverAddsNegativeOrOverlappingSegments() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: start)
        XCTAssertEqual(document.total(for: [id], at: start.addingTimeInterval(-100)), 0)
        document.togglePause(at: start.addingTimeInterval(60))
        document.togglePause(at: start.addingTimeInterval(-100))
        XCTAssertEqual(document.total(for: [id], at: start), 60)
        document.togglePause(at: start.addingTimeInterval(-50))
        document.finish(at: start.addingTimeInterval(-50))
        XCTAssertEqual(document.sessions[0].savedDuration, 60)
        try document.validate()
    }

    func testInvalidNamesDurationsAndSimultaneousTimersAreRejected() throws {
        var document = try document()
        let id = document.activities[0].id
        XCTAssertThrowsError(try document.addActivity(name: "  "))
        XCTAssertThrowsError(try document.addActivity(name: " 阅读 \n"))
        XCTAssertThrowsError(try document.start(activityID: UUID(), mode: .stopwatch, duration: nil, at: start))
        for duration: TimeInterval? in [nil, 0, -1, .infinity, .nan, 604_801] {
            XCTAssertThrowsError(try document.start(activityID: id, mode: .countdown, duration: duration, at: start))
        }
        try document.start(activityID: id, mode: .countdown, duration: 604_800, at: start)
        XCTAssertThrowsError(try document.start(activityID: id, mode: .stopwatch, duration: nil, at: start))
        document.togglePause(at: start.addingTimeInterval(1))
        XCTAssertThrowsError(try document.start(activityID: id, mode: .stopwatch, duration: nil, at: start))
    }

    func testRunningAndPausedTimersRoundTripAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let store = ActivityTimerStore(storageURL: url)
        XCTAssertEqual(store.load(), ActivityTimerDocument())
        var document = try document()
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .countdown, duration: 120, at: start)
        try store.save(document)
        var reloaded = ActivityTimerStore(storageURL: url).load()
        XCTAssertEqual(reloaded, document)
        XCTAssertEqual(reloaded.activeSession?.remaining(at: start.addingTimeInterval(40)), 80)
        reloaded.togglePause(at: start.addingTimeInterval(40))
        try store.save(reloaded)
        let paused = ActivityTimerStore(storageURL: url).load()
        XCTAssertEqual(paused.activeSession?.remaining(at: start.addingTimeInterval(1000)), 80)
        reloaded.togglePause(at: start.addingTimeInterval(1000))
        XCTAssertTrue(reloaded.completeCountdown(at: start.addingTimeInterval(2000)))
        try store.save(reloaded)
        XCTAssertEqual(ActivityTimerStore(storageURL: url).load().sessions[0].savedDuration, 120)
    }

    func testCorruptAndFutureVersionFilesAreProtectedFromOverwrite() throws {
        for damaged in [Data("broken".utf8), Data("{\"version\":2,\"activities\":[],\"sessions\":[]}".utf8)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("timers.json")
            try damaged.write(to: url)
            let store = ActivityTimerStore(storageURL: url)
            XCTAssertTrue(store.load().activities.isEmpty)
            XCTAssertNotNil(store.blockedSaveReason)
            XCTAssertThrowsError(try store.save(ActivityTimerDocument()))
            XCTAssertEqual(try Data(contentsOf: url), damaged)
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("timers.corrupt-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: backups[0]), damaged)
        }
    }

    func testMalformedSessionDataIsRejected() throws {
        var document = try document()
        try document.start(activityID: document.activities[0].id, mode: .stopwatch, duration: nil, at: start)
        document.sessions[0].segments = [.init(start: start, end: start.addingTimeInterval(-1))]
        XCTAssertThrowsError(try document.validate())
        document.sessions[0].segments = []
        document.sessions[0].activityID = UUID()
        XCTAssertThrowsError(try document.validate())
    }
}

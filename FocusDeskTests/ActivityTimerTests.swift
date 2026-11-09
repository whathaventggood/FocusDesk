import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import FocusDeskCore
#else
@testable import FocusDesk
#endif

final class ActivityTimerTests: XCTestCase {
    func testFileCacheDetectsInPlaceChangesWithRestoredModificationTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let storage = ActivityTimerStore(storageURL: url)
        var document = ActivityTimerDocument()
        try document.addActivity(name: "Alpha")
        try storage.save(document)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        XCTAssertEqual(storage.load().activities[0].name, "Alpha")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let changed = String(decoding: try Data(contentsOf: url), as: UTF8.self).replacingOccurrences(of: "Alpha", with: "Bravo")
        try Data(changed.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: url.path)
        XCTAssertEqual(storage.load().activities[0].name, "Bravo")
        try Data(repeating: 0x78, count: changed.utf8.count).write(to: url)
        XCTAssertThrowsError(try storage.update { try $0.addActivity(name: "Must not overwrite") })
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 0x78, count: changed.utf8.count))
    }

    private let start = Date(timeIntervalSince1970: 1_793_376_000)

    func testArchivePreservesHistoryIdentityAndBlocksStartingUntilRestored() throws {
        var document = try document()
        let activity = document.activities[0]
        try document.addNotedRecord(activityID: activity.id, startedAt: start, duration: 3600,
                                    note: "索引练习", at: start.addingTimeInterval(3600))
        let original = document.sessions
        try document.setActivityArchived(id: activity.id, archived: true)
        XCTAssertTrue(document.availableActivities.isEmpty)
        XCTAssertEqual(document.sessions, original)
        XCTAssertEqual(document.total(for: [activity.id], at: start.addingTimeInterval(7200)), 3600)
        XCTAssertThrowsError(try document.start(activityID: activity.id, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(7200)))
        let data = try JSONEncoder().encode(document)
        document = try JSONDecoder().decode(ActivityTimerDocument.self, from: data)
        try document.setActivityArchived(id: activity.id, archived: false)
        XCTAssertEqual(document.activities[0], activity)
        XCTAssertEqual(document.sessions, original)
        try document.start(activityID: activity.id, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(7200))
        let running = document
        XCTAssertThrowsError(try document.setActivityArchived(id: activity.id, archived: true))
        XCTAssertEqual(document, running)
    }

    func testVersionOneMigrationCreatesExactBackupAndRetriesWithoutOverwritingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("timers.json")
        let backup = directory.appendingPathComponent("timers.v1-backup.json")
        var legacy = try document()
        legacy.version = 1
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        var oldObject = object
        oldObject["activities"] = (object["activities"] as! [[String: Any]]).map { item in item.filter { $0.key != "isArchived" } }
        let exact = try JSONSerialization.data(withJSONObject: oldObject, options: [.prettyPrinted])
        try exact.write(to: url)
        // Represents a crash after backup creation and before atomic replacement.
        try exact.write(to: backup)
        try Data("{\"version\":2,\"activities\":[],\"sessions\":[]}".utf8)
            .write(to: directory.appendingPathComponent("timers.write-interrupted.tmp"))
        let writer = ActivityTimerStore(storageURL: url)
        let loaded = writer.load()
        XCTAssertNil(writer.blockedSaveReason)
        XCTAssertEqual(loaded.version, 2)
        XCTAssertFalse(loaded.activities[0].isArchived)
        XCTAssertEqual(loaded.activities[0].name, legacy.activities[0].name)
        XCTAssertEqual(try Data(contentsOf: backup), exact)
        XCTAssertEqual(try JSONDecoder().decode(ActivityTimerDocument.self, from: Data(contentsOf: url)).version, 2)
        _ = try writer.update { try $0.renameActivity(id: loaded.activities[0].id, name: "更新后") }
        XCTAssertEqual(try Data(contentsOf: backup), exact)

        // A later legacy file is backed up separately, preserving the first backup.
        oldObject["activities"] = [["id": loaded.activities[0].id.uuidString, "name": "旧版后来写入", "colorIndex": 0]]
        let later = try JSONSerialization.data(withJSONObject: oldObject)
        try later.write(to: url, options: .atomic)
        let second = ActivityTimerStore(storageURL: url).load()
        XCTAssertEqual(second.activities[0].name, "旧版后来写入")
        XCTAssertEqual(try Data(contentsOf: backup), exact)
        let additional = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("timers.v1-backup-") }
        XCTAssertEqual(additional.count, 1)
        XCTAssertEqual(try Data(contentsOf: additional[0]), later)
    }

    func testAtomicSwitchUsesOneBoundaryAndFailedTargetPreservesOriginalTimer() throws {
        var document = try document()
        let first = document.activities[0].id
        try document.addActivity(name: "SQL")
        let second = document.activities[1].id
        try document.start(activityID: first, mode: .stopwatch, duration: nil, at: start)
        let sessionID = document.activeSession!.id
        let original = document
        XCTAssertThrowsError(try document.switchActivity(to: second, mode: .countdown, duration: 0,
                                                        at: start.addingTimeInterval(60), expectedSessionID: sessionID))
        XCTAssertEqual(document, original)
        XCTAssertThrowsError(try document.switchActivity(to: second, mode: .stopwatch, duration: nil,
                                                        at: start.addingTimeInterval(60), expectedSessionID: UUID()))
        XCTAssertEqual(document, original)
        try document.switchActivity(to: second, mode: .countdown, duration: 300,
                                    at: start.addingTimeInterval(60), expectedSessionID: sessionID)
        XCTAssertEqual(document.sessions.filter { $0.endedAt == nil }.count, 1)
        XCTAssertEqual(document.sessions[0].savedDuration, 60)
        XCTAssertEqual(document.sessions[0].endedAt, document.activeSession?.startedAt)
        XCTAssertEqual(document.activeSession?.activityID, second)
        document.togglePause(at: start.addingTimeInterval(90))
        let pausedID = document.activeSession!.id
        try document.switchActivity(to: first, mode: .stopwatch, duration: nil,
                                    at: start.addingTimeInterval(600), expectedSessionID: pausedID)
        XCTAssertEqual(document.sessions[1].savedDuration, 30)
        XCTAssertEqual(document.activeSession?.startedAt, start.addingTimeInterval(600))
        try document.validate()
    }

    func testRecordEditUndoIsAtomicAndPreservesLaterRecords() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.addRecord(activityID: id, startedAt: start, duration: 120, at: start.addingTimeInterval(120))
        let recordID = document.sessions[0].id
        let before = document
        XCTAssertThrowsError(try document.editRecord(sessionID: recordID, duration: 60, note: String(repeating: "字", count: 2001)))
        XCTAssertEqual(document, before)
        let action = ActivityTimerAction.editRecord(recordID, 60, "  窗口函数练习  ")
        try action.apply(to: &document, at: start, expectedSessionID: nil, expectedPauseState: nil)
        let undo = try XCTUnwrap(action.undoToken(from: before, to: document))
        XCTAssertEqual(document.sessions[0].note, "窗口函数练习")
        try document.addRecord(activityID: id, startedAt: start.addingTimeInterval(300), duration: 30, at: start.addingTimeInterval(400))
        let added = document.sessions[1]
        try undo.apply(to: &document)
        XCTAssertNil(document.sessions[0].correctedDuration)
        XCTAssertNil(document.sessions[0].note)
        XCTAssertEqual(document.sessions[1], added)
        try undo.inverse.apply(to: &document)
        XCTAssertEqual(document.sessions[0].correctedDuration, 60)
        XCTAssertEqual(document.sessions[0].note, "窗口函数练习")
        try document.setSessionNote(sessionID: recordID, note: "其他窗口的新内容")
        let external = document
        XCTAssertThrowsError(try undo.apply(to: &document))
        XCTAssertEqual(document, external)
    }

    func testUndoRenameConflictsAndArchiveRedoKeepsItsOperationTitle() throws {
        var document = try document()
        let id = document.activities[0].id
        let before = document
        let rename = ActivityTimerAction.rename(id, "SQL")
        try rename.apply(to: &document, at: start, expectedSessionID: nil, expectedPauseState: nil)
        let undo = try XCTUnwrap(rename.undoToken(from: before, to: document))
        try document.renameActivity(id: id, name: "其他窗口已改名")
        let external = document
        XCTAssertThrowsError(try undo.apply(to: &document))
        XCTAssertEqual(document, external)
        let archive = ActivityTimerAction.archive(id, true)
        let active = document
        try archive.apply(to: &document, at: start, expectedSessionID: nil, expectedPauseState: nil)
        let restore = try XCTUnwrap(archive.undoToken(from: active, to: document))
        XCTAssertEqual(restore.title, restore.inverse.title)
        try restore.apply(to: &document)
        XCTAssertFalse(document.activities[0].isArchived)
        try restore.inverse.apply(to: &document)
        XCTAssertTrue(document.activities[0].isArchived)
    }

    func testBackgroundIOGeneratesUndoFromLatestCommittedValuesAndSkipsNoop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let storage = ActivityTimerStore(storageURL: url)
        let original = try document()
        let id = original.activities[0].id
        try storage.save(original)
        let io = ActivityTimerIO(storageURL: url)
        _ = await io.load(at: start)
        _ = try storage.update { try $0.renameActivity(id: id, name: "外部名称") }
        let result = try await io.apply(.rename(id, "本次名称"), at: start, expectedSessionID: nil, expectedPauseState: nil, sleepBoundary: nil)
        let undo = try XCTUnwrap(result.undo)
        let restored = try await io.apply(.undo(undo), at: start, expectedSessionID: nil, expectedPauseState: nil, sleepBoundary: nil)
        XCTAssertEqual(restored.document.activities[0].name, "外部名称")
        XCTAssertEqual(restored.undo, undo.inverse)
        let noop = try await io.apply(.rename(id, "外部名称"), at: start, expectedSessionID: nil, expectedPauseState: nil, sleepBoundary: nil)
        XCTAssertNil(noop.undo)
    }

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
        XCTAssertEqual(document.activities[0], TimedActivity(id: id, name: "阅读书籍", colorIndex: 0))
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

    func testCountdownReminderPersistsUntilHandledAndDoesNotAccumulateWaitingTime() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .countdown, duration: 60, at: start)
        let sessionID = document.activeSession?.id
        XCTAssertTrue(document.completeCountdown(at: start.addingTimeInterval(100)))
        var reloaded = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONEncoder().encode(document))
        try reloaded.validate()
        XCTAssertEqual(reloaded.displayedSession?.id, sessionID)
        XCTAssertTrue(reloaded.displayedSession?.isAwaitingCompletion == true)
        XCTAssertEqual(reloaded.total(for: [id], at: start.addingTimeInterval(10_000)), 60)
        try reloaded.addActivity(name: "运动")
        try reloaded.renameActivity(id: id, name: "读书")
        XCTAssertEqual(reloaded.pendingCountdownSessionID, sessionID)
        reloaded.finish(at: start.addingTimeInterval(10_000))
        XCTAssertNil(reloaded.displayedSession)
        XCTAssertNil(reloaded.pendingCountdownSessionID)
        XCTAssertEqual(reloaded.sessions.count, 1)
        XCTAssertEqual(reloaded.sessions[0].savedDuration, 60)
        try reloaded.validate()
    }

    func testExtensionStartsFiveMinutesFromClickAndCanRepeat() throws {
        var document = try document()
        let id = document.activities[0].id
        XCTAssertThrowsError(try document.extendCountdown(at: start))
        try document.start(activityID: id, mode: .countdown, duration: 604_800, at: start)
        XCTAssertThrowsError(try document.extendCountdown(at: start.addingTimeInterval(1)))
        let click = start.addingTimeInterval(700_000)
        // Handles a click at the deadline before the next clock refresh, including 7-day timers.
        try document.extendCountdown(at: click)
        XCTAssertNil(document.pendingCountdownSessionID)
        XCTAssertEqual(document.activeSession?.activityID, id)
        XCTAssertEqual(document.activeSession?.remaining(at: click), 300)
        XCTAssertEqual(document.total(for: [id], at: click.addingTimeInterval(20)), 604_820)
        XCTAssertTrue(document.completeCountdown(at: click.addingTimeInterval(300)))
        try document.extendCountdown(at: click.addingTimeInterval(1000))
        XCTAssertEqual(document.activeSession?.remaining(at: click.addingTimeInterval(1000)), 300)
        XCTAssertEqual(document.total(for: [id], at: click.addingTimeInterval(1000)), 605_100)
        try document.validate()
    }

    func testNewTimerAndDeletionClearOnlyTheRelevantReminder() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.addActivity(name: "运动")
        let otherID = document.activities[1].id
        try document.start(activityID: id, mode: .countdown, duration: 1, at: start)
        XCTAssertTrue(document.completeCountdown(at: start.addingTimeInterval(1)))
        let pendingID = document.pendingCountdownSessionID
        try document.deleteActivity(id: otherID)
        XCTAssertEqual(document.pendingCountdownSessionID, pendingID)
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(10))
        XCTAssertNil(document.pendingCountdownSessionID)
        XCTAssertEqual(document.displayedSession?.mode, .stopwatch)
        document.finish(at: start.addingTimeInterval(20))
        XCTAssertNil(document.displayedSession)
        try document.start(activityID: id, mode: .countdown, duration: 1, at: start.addingTimeInterval(30))
        XCTAssertTrue(document.completeCountdown(at: start.addingTimeInterval(31)))
        try document.deleteActivity(id: id)
        XCTAssertNil(document.displayedSession)
        XCTAssertNil(document.pendingCountdownSessionID)
        try document.validate()
    }

    func testOldTimerFilesLoadWithoutInventingRemindersAndInvalidReferencesAreRejected() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .countdown, duration: 60, at: start)
        document.finish(at: start.addingTimeInterval(60))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json.removeValue(forKey: "pendingCountdownSessionID")
        let legacy = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONSerialization.data(withJSONObject: json))
        try legacy.validate()
        XCTAssertNil(legacy.displayedSession)
        XCTAssertEqual(legacy.sessions, document.sessions)
        document.pendingCountdownSessionID = UUID()
        XCTAssertThrowsError(try document.validate())
        document.pendingCountdownSessionID = document.sessions[0].id
        try document.validate()
        document.sessions[0].segments = []
        XCTAssertThrowsError(try document.validate())
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
        for damaged in [Data("broken".utf8), Data("{\"version\":99,\"activities\":[],\"sessions\":[]}".utf8)] {
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

    func testNewProjectSeventeenHourStopwatchSurvivesFinishAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let writer = ActivityTimerStore(storageURL: url)
        let created = try writer.update { try $0.addActivity(name: "cpc") }
        let id = created.activities[0].id
        _ = try writer.update { try $0.start(activityID: id, mode: .stopwatch, duration: nil, at: start) }
        let nextDay = start.addingTimeInterval(17 * 3600 + 11)
        let reloadedWriter = ActivityTimerStore(storageURL: url)
        XCTAssertEqual(reloadedWriter.load().activeSession?.elapsed(at: nextDay), 61_211)
        _ = try reloadedWriter.update { $0.finish(at: nextDay) }
        let finished = ActivityTimerStore(storageURL: url).load()
        XCTAssertEqual(finished.activities[0].name, "cpc")
        XCTAssertNil(finished.activeSession)
        XCTAssertEqual(finished.sessions.count, 1)
        XCTAssertEqual(finished.total(for: [id], at: nextDay), 61_211)
    }

    func testStaleStoreUpdatesPreserveNewProjectAndItsCompletedRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let first = ActivityTimerStore(storageURL: url)
        let second = ActivityTimerStore(storageURL: url)
        _ = first.load()
        _ = second.load()
        let added = try first.update { try $0.addActivity(name: "cpc") }
        let id = added.activities[0].id
        _ = try first.update { try $0.start(activityID: id, mode: .stopwatch, duration: nil, at: start) }
        _ = try second.update { try $0.addActivity(name: "SQL") }
        _ = try first.update { $0.finish(at: start.addingTimeInterval(61_200)) }
        _ = try second.update { try $0.renameActivity(id: id, name: "CPC") }
        let saved = first.load()
        XCTAssertEqual(saved.activities.map(\.name), ["CPC", "SQL"])
        XCTAssertEqual(saved.total(for: [id], at: start.addingTimeInterval(80_000)), 61_200)
        XCTAssertEqual(saved.sessions.count, 1)
    }

    func testSleepPauseIsIdempotentAndExcludesOvernightTimeForBothModes() throws {
        for mode in ActivityTimerMode.allCases {
            var document = try document()
            let id = document.activities[0].id
            try document.start(activityID: id, mode: mode, duration: 1800, at: start)
            document.pauseForSleep(at: start.addingTimeInterval(60))
            document.pauseForSleep(at: start.addingTimeInterval(120))
            let wake = start.addingTimeInterval(17 * 3600)
            var reloaded = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONEncoder().encode(document))
            XCTAssertTrue(reloaded.activeSession!.isPaused)
            XCTAssertEqual(reloaded.activeSession?.elapsed(at: wake), 60)
            XCTAssertFalse(reloaded.completeCountdown(at: wake))
            reloaded.togglePause(at: wake)
            reloaded.finish(at: wake.addingTimeInterval(30))
            XCTAssertEqual(reloaded.total(for: [id], at: wake.addingTimeInterval(100)), 90)
            try reloaded.validate()
        }
        var due = try document()
        try due.start(activityID: due.activities[0].id, mode: .countdown, duration: 30, at: start)
        due.pauseForSleep(at: start.addingTimeInterval(60))
        XCTAssertEqual(due.pendingCountdown?.savedDuration, 30)
    }

    func testCorrectionTrimsFromStartExcludesPausesAndCanRestoreOriginal() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-11-06T16:00:00Z")!
        var document = try document()
        let id = document.activities[0].id
        let began = midnight.addingTimeInterval(-120)
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: began)
        let sessionID = document.activeSession!.id
        XCTAssertThrowsError(try document.correctDuration(sessionID: sessionID, duration: 60))
        document.togglePause(at: midnight.addingTimeInterval(-60))
        document.togglePause(at: midnight.addingTimeInterval(60))
        document.finish(at: midnight.addingTimeInterval(17 * 3600))
        let original = document.sessions[0]
        try document.correctDuration(sessionID: sessionID, duration: 90)
        let today = DateInterval(start: midnight, duration: 86400)
        XCTAssertEqual(document.total(for: [id], at: midnight, in: today), 30)
        XCTAssertEqual(document.total(for: [id], at: midnight), 90)
        XCTAssertEqual(document.sessions[0].segments, original.segments)
        XCTAssertEqual(document.sessions[0].endedAt, original.endedAt)
        try document.correctDuration(sessionID: sessionID, duration: original.recordedDuration)
        XCTAssertEqual(document.sessions[0].savedDuration, original.savedDuration)
        for invalid in [-1, .nan, .infinity, original.recordedDuration + 1] {
            XCTAssertThrowsError(try document.correctDuration(sessionID: sessionID, duration: invalid))
        }
        try document.correctDuration(sessionID: sessionID, duration: 0)
        XCTAssertEqual(document.total(for: [id], at: midnight), 0)
        let restored = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored, document)
        try restored.validate()
    }

    func testDailyChartSplitsByLocalDayAndMatchesCorrectedTotals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let midnight = ISO8601DateFormatter().date(from: "2026-11-06T16:00:00Z")!
        let now = midnight.addingTimeInterval(7200)
        var document = try document()
        let id = document.activities[0].id
        try document.addRecord(activityID: id, startedAt: midnight.addingTimeInterval(-3600), duration: 7200, at: now)
        var points = document.dailyDurations(at: now, days: 2, calendar: calendar)
        XCTAssertEqual(points.map(\.duration), [3600, 3600])
        try document.correctDuration(sessionID: document.sessions[0].id, duration: 5400)
        points = document.dailyDurations(at: now, days: 2, calendar: calendar)
        XCTAssertEqual(points.map(\.duration), [3600, 1800])
        XCTAssertEqual(points.reduce(0) { $0 + $1.duration }, document.total(for: [id], at: now))
        XCTAssertThrowsError(try document.addRecord(activityID: id, startedAt: now, duration: 60, at: now))
        XCTAssertThrowsError(try document.addRecord(activityID: id, startedAt: now, duration: -1, at: now))
        XCTAssertThrowsError(try document.addRecord(activityID: UUID(), startedAt: midnight, duration: 60, at: now))
        XCTAssertTrue(document.dailyDurations(at: now, days: 0).isEmpty)
    }

    func testProjectColorsSurviveRenameDeleteAndLegacyMigration() throws {
        var document = try document()
        try document.addActivity(name: "SQL")
        try document.addActivity(name: "cpc")
        let id = document.activities[2].id
        let color = document.colorIndex(for: id)
        try document.deleteActivity(id: document.activities[0].id)
        try document.renameActivity(id: id, name: "CPC")
        try document.addActivity(name: "新项目")
        XCTAssertEqual(document.colorIndex(for: id), color)
        XCTAssertEqual(Set(document.activities.compactMap(\.colorIndex)).count, 3)
        for index in document.activities.indices { document.activities[index].colorIndex = nil }
        document.assignActivityColors()
        XCTAssertEqual(document.activities.compactMap(\.colorIndex), [0, 1, 2])
        try document.validate()
    }

    func testChartLabelsStayDistinctBeyondPaletteAndSurviveEditsAndReload() throws {
        var document = ActivityTimerDocument()
        for index in 1...32 { try document.addActivity(name: "学习项目 \(index)") }
        let retained = document.activities[17]
        XCTAssertEqual(Set(document.activities.map(\.chartLabel)).count, 32)
        XCTAssertEqual(document.activities[8].chartLabel, "#9")
        try document.deleteActivity(id: document.activities[0].id)
        try document.renameActivity(id: retained.id, name: "新名称")
        try document.addActivity(name: "后续新增")
        let reloaded = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(reloaded.activities.first { $0.id == retained.id }?.chartLabel, retained.chartLabel)
        XCTAssertEqual(Set(reloaded.activities.map(\.chartLabel)).count, 32)
        try reloaded.validate()
    }

    func testChartStacksRestackFilteredProjectsAndUseLocalDayBounds() {
        let day = start
        let nextDay = day.addingTimeInterval(86400)
        let first = UUID(), second = UUID()
        let points = [ActivityDailyDuration(day: day, activityID: first, duration: 3600),
                      ActivityDailyDuration(day: day, activityID: second, duration: 1),
                      ActivityDailyDuration(day: nextDay, activityID: first, duration: 0),
                      ActivityDailyDuration(day: nextDay, activityID: second, duration: 1800)]
        let stack = ActivityDailyChartSegment.stacking(points)
        XCTAssertEqual(stack.map(\.lowerBound), [0, 3600, 0])
        XCTAssertEqual(stack.map(\.upperBound), [3600, 3601, 1800])
        XCTAssertEqual(stack.map { $0.point.activityID }, [first, second, second])
        let filtered = ActivityDailyChartSegment.stacking(points.filter { $0.activityID == second })
        XCTAssertEqual(filtered.map(\.lowerBound), [0, 0])
        XCTAssertEqual(filtered.map { $0.point.duration }, [1, 1800])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dst = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!
        let segment = ActivityDailyChartSegment(point: .init(day: dst, activityID: first, duration: 1), lowerBound: 0)
        let dates = segment.dateRange(calendar: calendar)
        XCTAssertEqual(dates.lowerBound.timeIntervalSince(dst), 23 * 3600 * 0.15, accuracy: 0.001)
        XCTAssertEqual(dates.upperBound.timeIntervalSince(dst), 23 * 3600 * 0.85, accuracy: 0.001)
    }
}

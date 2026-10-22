import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import FocusDeskCore
#else
@testable import FocusDesk
#endif

final class ProgressTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func task(id: UUID = UUID(), title: String = "学习") -> PlanTask {
        PlanTask(id: id, startMinutes: 540, endMinutes: 600, title: title, details: "运行示例")
    }

    func testCompletionIsExplicitAndCanBeUndone() {
        let task = task()
        let completedAt = date("2026-10-21T02:00:00Z")
        var progress = DailyProgress(tasks: [task], at: completedAt, calendar: calendar("Asia/Shanghai"))
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertEqual(progress.completionRate, 0)
        XCTAssertTrue(progress.toggleCompletion(id: task.id, at: completedAt))
        XCTAssertEqual(progress.tasks[0].completedAt, completedAt)
        XCTAssertEqual(progress.completedCount, 1)
        XCTAssertEqual(progress.completionRate, 1)
        XCTAssertTrue(progress.toggleCompletion(id: task.id, at: completedAt.addingTimeInterval(60)))
        XCTAssertNil(progress.tasks[0].completedAt)
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertFalse(progress.toggleCompletion(id: UUID(), at: completedAt))
    }

    func testEmptyPlanHasZeroCompletionRate() {
        let progress = DailyProgress(tasks: [], at: date("2026-10-21T00:00:00Z"))
        XCTAssertEqual(progress.totalCount, 0)
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertEqual(progress.completionRate, 0)
    }

    func testCountBasedCompletionIncludesAllScheduledTasks() {
        let study = task()
        let rest = PlanTask(startMinutes: 600, endMinutes: 610, title: "休息", details: "喝水")
        let time = date("2026-10-21T02:00:00Z")
        var progress = DailyProgress(tasks: [study, rest], at: time)
        progress.toggleCompletion(id: rest.id, at: time)
        XCTAssertEqual(progress.totalCount, 2)
        XCTAssertEqual(progress.completedCount, 1)
        XCTAssertEqual(progress.completionRate, 0.5)
    }

    func testGregorianLocalDateRespectsTimeZone() {
        let time = date("2026-10-20T16:30:00Z")
        XCTAssertEqual(DailyProgress.dayKey(for: time, calendar: calendar("Asia/Shanghai")), "2026-10-21")
        XCTAssertEqual(DailyProgress.dayKey(for: time, calendar: calendar("America/Los_Angeles")), "2026-10-20")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(DailyProgress.dayKey(for: time, calendar: buddhist), "2026-10-21")
    }

    func testSpringDSTAndRepeatedFallHourKeepSameLocalDate() {
        let newYork = calendar("America/New_York")
        XCTAssertEqual(DailyProgress.dayKey(for: date("2026-03-08T06:59:00Z"), calendar: newYork), "2026-03-08")
        XCTAssertEqual(DailyProgress.dayKey(for: date("2026-03-08T07:01:00Z"), calendar: newYork), "2026-03-08")
        XCTAssertEqual(DailyProgress.dayKey(for: date("2026-11-01T05:30:00Z"), calendar: newYork), "2026-11-01")
        XCTAssertEqual(DailyProgress.dayKey(for: date("2026-11-01T06:30:00Z"), calendar: newYork), "2026-11-01")
    }

    func testSynchronizingTodayPreservesIDsAndCompletionButSnapshotsAreValues() {
        let original = task()
        let completedAt = date("2026-10-21T02:00:00Z")
        let zone = calendar("Asia/Shanghai")
        var yesterday = DailyProgress(tasks: [original], at: completedAt, calendar: zone)
        yesterday.toggleCompletion(id: original.id, at: completedAt)
        var edited = original
        edited.title = "新的学习内容"
        edited.details = "新的说明"
        edited.endMinutes = 590
        let today = yesterday.synchronizing(tasks: [edited], calendar: zone)
        XCTAssertEqual(today.tasks[0].task, edited)
        XCTAssertEqual(today.tasks[0].completedAt, completedAt)
        XCTAssertEqual(yesterday.tasks[0].task, original)
        XCTAssertEqual(today.synchronizing(tasks: [], calendar: zone).totalCount, 0)
        let replaced = yesterday.synchronizing(tasks: [task()], calendar: zone)
        XCTAssertEqual(replaced.completedCount, 0)
    }

    func testNewDayDoesNotAutoCompletePastTasks() {
        let morning = task()
        let night = date("2026-10-21T15:59:00Z")
        let progress = DailyProgress(tasks: [morning], at: night, calendar: calendar("Asia/Shanghai"))
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertNil(progress.tasks[0].completedAt)
    }

    func testProgressDocumentRoundTripPreservesSnapshotsAndCompletionDates() throws {
        let item = task()
        let completedAt = date("2026-10-21T02:00:00Z")
        var progress = DailyProgress(tasks: [item], at: completedAt, calendar: calendar("Asia/Shanghai"))
        progress.toggleCompletion(id: item.id, at: completedAt)
        let document = ProgressDocument(tasks: [item], history: [progress])
        XCTAssertEqual(try JSONDecoder().decode(ProgressDocument.self, from: JSONEncoder().encode(document)), document)
    }

    func testLegacyArrayLoadsWithoutInventingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plan.json")
        let plan = [task()]
        try JSONEncoder().encode(plan).write(to: url)
        let storage = ProgressStore(storageURL: url)
        let loaded = storage.load(defaultTasks: [])
        XCTAssertNil(loaded.notice)
        XCTAssertEqual(loaded.document.tasks, plan)
        XCTAssertTrue(loaded.document.history.isEmpty)
        XCTAssertNil(storage.blockedSaveReason)
    }

    func testCorruptHistoryProtectsOriginalAndRequiresExplicitRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plan.json")
        let original = Data("{\"version\":1,\"tasks\":[],\"history\":[{\"day\":\"broken\"}]}".utf8)
        try original.write(to: url)
        let storage = ProgressStore(storageURL: url)
        let loaded = storage.load(defaultTasks: [])
        XCTAssertNotNil(loaded.notice)
        XCTAssertNotNil(storage.blockedSaveReason)
        XCTAssertThrowsError(try storage.save(ProgressDocument(tasks: [], history: [])))
        XCTAssertEqual(try Data(contentsOf: url), original)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("plan.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
        try storage.recover(with: ProgressDocument(tasks: [], history: []))
        XCTAssertNil(storage.blockedSaveReason)
        XCTAssertEqual(try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: url)).tasks, [])
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
    }

    func testRecoveryBackupFailureLeavesStoreBlocked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plan.json")
        try Data("broken".utf8).write(to: url)
        let storage = ProgressStore(storageURL: url)
        _ = storage.load(defaultTasks: [])
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try storage.recover(with: ProgressDocument(tasks: [], history: [])))
        XCTAssertNotNil(storage.blockedSaveReason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInvalidAndDuplicateHistoryDatesAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ProgressStore(storageURL: directory.appendingPathComponent("plan.json"))
        let valid = DailyProgress(day: "2026-10-21", timeZoneIdentifier: "Asia/Shanghai", tasks: [])
        let invalid = DailyProgress(day: "2026-02-30", timeZoneIdentifier: "Asia/Shanghai", tasks: [])
        XCTAssertThrowsError(try storage.save(ProgressDocument(tasks: [], history: [invalid])))
        XCTAssertThrowsError(try storage.save(ProgressDocument(tasks: [], history: [valid, valid])))
    }
}

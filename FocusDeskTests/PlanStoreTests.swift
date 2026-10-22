#if !SWIFT_PACKAGE
import Foundation
import XCTest
@testable import FocusDesk

private final class TestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "FocusDesk.XCTest.InMemory")! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
}

final class PlanStoreTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func task(title: String = "学习") -> PlanTask {
        PlanTask(startMinutes: 540, endMinutes: 600, title: title, details: "详细说明")
    }

    @MainActor
    func testLegacyMigrationCompletionUndoAndPersistenceReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = task()
        let url = directory.appendingPathComponent("plan.json")
        try JSONEncoder().encode([original]).write(to: url)
        let now = date("2026-10-21T02:00:00Z")
        let zone = calendar("Asia/Shanghai")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, calendarProvider: { zone }, startClock: false)
        defer { store.stop() }
        XCTAssertEqual(store.tasks, [original])
        XCTAssertEqual(store.history.count, 1)
        XCTAssertNil(store.toggleTaskCompletion(id: original.id))
        XCTAssertTrue(store.isTaskCompleted(original.id))
        XCTAssertEqual(store.todayProgress.tasks[0].completedAt, now)
        let reloaded = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                                 nowProvider: { now }, calendarProvider: { zone }, startClock: false)
        defer { reloaded.stop() }
        XCTAssertEqual(reloaded.todayProgress, store.todayProgress)
        XCTAssertNil(reloaded.toggleTaskCompletion(id: original.id))
        XCTAssertFalse(reloaded.isTaskCompleted(original.id))
        let persisted = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: url))
        XCTAssertNil(persisted.history[0].tasks[0].completedAt)
    }

    @MainActor
    func testRolloverSnapshotsHistoryAndSkipsAbsentDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-10-21T15:59:00Z")
        let zone = calendar("Asia/Shanghai")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, calendarProvider: { zone }, startClock: false)
        defer { store.stop() }
        let original = task()
        XCTAssertNil(store.replaceTasks([original]))
        XCTAssertNil(store.toggleTaskCompletion(id: original.id))
        let yesterday = store.todayProgress
        now = date("2026-10-24T00:00:00Z")
        store.refresh()
        XCTAssertEqual(store.todayProgress.day, "2026-10-24")
        XCTAssertEqual(store.todayProgress.completedCount, 0)
        XCTAssertEqual(store.history.map(\.day), ["2026-10-24", "2026-10-21"])
        var edited = original
        edited.title = "新的标题"
        edited.details = "新的说明"
        edited.endMinutes = 590
        XCTAssertNil(store.saveTask(edited))
        XCTAssertEqual(store.todayProgress.tasks[0].task, edited)
        XCTAssertEqual(store.history.last, yesterday)
        XCTAssertNil(store.deleteTask(id: original.id))
        XCTAssertEqual(store.todayProgress.totalCount, 0)
        XCTAssertEqual(store.todayProgress.completionRate, 0)
        XCTAssertEqual(store.history.last, yesterday)
    }

    @MainActor
    func testTodayEditsPreserveCompletionByIDAndUpdateDenominator() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-10-21T02:00:00Z")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { store.stop() }
        var first = task()
        XCTAssertNil(store.replaceTasks([first]))
        XCTAssertNil(store.toggleTaskCompletion(id: first.id))
        first.title = "新标题"
        XCTAssertNil(store.saveTask(first))
        XCTAssertEqual(store.todayProgress.completedCount, 1)
        XCTAssertEqual(store.todayProgress.tasks[0].task.title, "新标题")
        let second = PlanTask(startMinutes: 600, endMinutes: 610, title: "休息", details: "")
        XCTAssertNil(store.saveTask(second))
        XCTAssertEqual(store.todayProgress.completionRate, 0.5)
        XCTAssertNil(store.deleteTask(id: first.id))
        XCTAssertEqual(store.todayProgress.totalCount, 1)
        XCTAssertEqual(store.todayProgress.completedCount, 0)
    }

    @MainActor
    func testTimeZoneChangeUsesActualLocalDayAndCanReturnToExistingDay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-10-20T16:30:00Z")
        var zone = calendar("Asia/Shanghai")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, calendarProvider: { zone }, startClock: false)
        defer { store.stop() }
        let original = task()
        XCTAssertNil(store.replaceTasks([original]))
        XCTAssertNil(store.toggleTaskCompletion(id: original.id))
        zone = calendar("America/Los_Angeles")
        store.refresh()
        XCTAssertEqual(store.todayProgress.day, "2026-10-20")
        XCTAssertEqual(store.todayProgress.completedCount, 0)
        zone = calendar("Asia/Shanghai")
        store.refresh()
        XCTAssertEqual(store.todayProgress.day, "2026-10-21")
        XCTAssertTrue(store.isTaskCompleted(original.id))
        XCTAssertEqual(store.history.count, 2)
    }

    @MainActor
    func testDSTRepeatedHourDoesNotResetCompletions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-11-01T05:30:00Z")
        let zone = calendar("America/New_York")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, calendarProvider: { zone }, startClock: false)
        defer { store.stop() }
        let original = task()
        XCTAssertNil(store.replaceTasks([original]))
        XCTAssertNil(store.toggleTaskCompletion(id: original.id))
        now = date("2026-11-01T06:30:00Z")
        store.refresh()
        XCTAssertEqual(store.history.count, 1)
        XCTAssertTrue(store.isTaskCompleted(original.id))
    }

    @MainActor
    func testFailedWriteRollsBackCompletionAndPlanTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-10-21T02:00:00Z")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { store.stop() }
        let original = task()
        XCTAssertNil(store.replaceTasks([original]))
        let before = store.history
        try FileManager.default.removeItem(at: store.storageURL)
        try FileManager.default.createDirectory(at: store.storageURL, withIntermediateDirectories: true)
        XCTAssertNotNil(store.toggleTaskCompletion(id: original.id))
        XCTAssertFalse(store.isTaskCompleted(original.id))
        XCTAssertEqual(store.history, before)
        var edited = original
        edited.title = "不应被保存"
        XCTAssertNotNil(store.saveTask(edited))
        XCTAssertEqual(store.tasks, [original])
        XCTAssertEqual(store.history, before)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testRolloverWriteFailureRetriesAfterStorageRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-10-21T15:59:00Z")
        let zone = calendar("Asia/Shanghai")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, calendarProvider: { zone }, startClock: false)
        defer { store.stop() }
        let original = task()
        XCTAssertNil(store.replaceTasks([original]))
        XCTAssertNil(store.toggleTaskCompletion(id: original.id))
        let previousHistory = store.history
        let previousFile = try Data(contentsOf: store.storageURL)
        try FileManager.default.removeItem(at: store.storageURL)
        try FileManager.default.createDirectory(at: store.storageURL, withIntermediateDirectories: true)
        now = date("2026-10-21T16:01:00Z")
        store.refresh()
        XCTAssertEqual(store.todayProgress.day, "2026-10-22")
        XCTAssertEqual(store.todayProgress.completedCount, 0)
        XCTAssertEqual(store.history, previousHistory)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(store.toggleTaskCompletion(id: original.id))
        XCTAssertEqual(store.todayProgress.completedCount, 0)
        XCTAssertEqual(store.history, previousHistory)
        try FileManager.default.removeItem(at: store.storageURL)
        try previousFile.write(to: store.storageURL)
        store.refresh()
        XCTAssertEqual(store.history.map(\.day), ["2026-10-22", "2026-10-21"])
        XCTAssertEqual(store.history.last, previousHistory[0])
        XCTAssertNil(store.errorMessage)
        let persisted = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: store.storageURL))
        XCTAssertEqual(persisted.history, store.history)
        XCTAssertNil(store.toggleTaskCompletion(id: original.id))
        XCTAssertEqual(store.todayProgress.completedCount, 1)
    }

    @MainActor
    func testInitialWriteFailureCanBeRetriedByRefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The intended storage directory is temporarily a regular file.
        try Data("busy".utf8).write(to: directory)
        let now = date("2026-10-21T02:00:00Z")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { store.stop() }
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.needsDataRecovery)
        try FileManager.default.removeItem(at: directory)
        store.refresh()
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history[0], store.todayProgress)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    @MainActor
    func testConflictReplacementDoesNotChangePlanOrProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-10-21T02:00:00Z")
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { store.stop() }
        let original = task()
        XCTAssertNil(store.replaceTasks([original]))
        XCTAssertNil(store.toggleTaskCompletion(id: original.id))
        let before = try Data(contentsOf: store.storageURL)
        let conflict = PlanTask(startMinutes: 550, endMinutes: 590, title: "冲突", details: "")
        XCTAssertNotNil(store.replaceTasks([original, conflict]))
        XCTAssertEqual(store.tasks, [original])
        XCTAssertTrue(store.isTaskCompleted(original.id))
        XCTAssertEqual(try Data(contentsOf: store.storageURL), before)
    }

    @MainActor
    func testDamagedDataCannotBeSilentlyOverwrittenAndCanExplicitlyRecover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plan.json")
        let damaged = Data("broken history".utf8)
        try damaged.write(to: url)
        let store = PlanStore(storageDirectory: directory, defaults: TestDefaults(), allowsLoginItemChanges: false, startClock: false)
        defer { store.stop() }
        XCTAssertTrue(store.needsDataRecovery)
        XCTAssertNotNil(store.saveTask(task()))
        XCTAssertNotNil(store.toggleTaskCompletion(id: store.tasks[0].id))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertNil(store.recoverWithDefaultPlan())
        XCTAssertFalse(store.needsDataRecovery)
        XCTAssertEqual(store.tasks.count, DefaultPlan.tasks.count)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.todayProgress.completedCount, 0)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("plan.corrupt-") }
        XCTAssertFalse(backups.isEmpty)
        for backup in backups { XCTAssertEqual(try Data(contentsOf: backup), damaged) }
    }
}
#endif

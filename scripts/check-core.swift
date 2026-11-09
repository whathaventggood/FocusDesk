// Direct Foundation checks for environments without the XCTest framework.
// These checks compile the same production core files used by the macOS app.
import Foundation
import CoreGraphics

private enum CoreCheck {
    static var checks = 0
    static var failures = 0

    static func record(_ result: Bool, _ message: String, file: StaticString, line: UInt) {
        checks += 1
        if !result {
            failures += 1
            print("FAIL \(file):\(line): \(message)")
        }
    }

    static func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(lhs == rhs, "\(lhs) != \(rhs) \(message)", file: file, line: line)
    }

    static func equal<T: FloatingPoint>(_ lhs: T, _ rhs: T, accuracy: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(abs(lhs - rhs) <= accuracy, "\(lhs) != \(rhs) \(message)", file: file, line: line)
    }

    static func nilValue<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value == nil, "Expected nil. \(message)", file: file, line: line)
    }

    static func nonNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value != nil, "Expected a value. \(message)", file: file, line: line)
    }

    static func truth(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        record(value, "Expected true", file: file, line: line)
    }

    static func falseValue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        record(!value, "Expected false", file: file, line: line)
    }

    static func throwsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try expression(); record(false, "Expected an error", file: file, line: line) }
        catch { record(true, "Expected an error", file: file, line: line) }
    }

    static func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        nonNil(value, file: file, line: line)
        guard let value else { throw NSError(domain: "CoreCheck", code: 1) }
        return value
    }
}

private struct PlanValidationTests {
    private func task(_ start: Int, _ end: Int, title: String = "任务") -> PlanTask {
        PlanTask(startMinutes: start, endMinutes: end, title: title, details: "")
    }

    func testValidTimeParsing() {
        CoreCheck.equal(TimeInput.parse("00:00"), 0)
        CoreCheck.equal(TimeInput.parse("09:05"), 545)
        CoreCheck.equal(TimeInput.parse("23:59"), 1_439)
        CoreCheck.equal(TimeInput.parse("24:00"), 1_440)
        CoreCheck.equal(TimeInput.parse(" 09:00 \n"), 540)
    }

    func testInvalidTimeParsing() {
        for input in ["9:00", "09:0", "09：00", "09:60", "24:01", "25:00", "-1:00", "ab:cd", "", "09:00:00", "０９:００"] {
            CoreCheck.nilValue(TimeInput.parse(input), input)
        }
    }

    func testFormattingAndMidnightEndNormalization() {
        CoreCheck.equal(TimeInput.format(0), "00:00")
        CoreCheck.equal(TimeInput.format(545), "09:05")
        CoreCheck.equal(TimeInput.format(1_440), "00:00")
        CoreCheck.equal(TimeInput.endMinutes(from: "00:00", startMinutes: 1_380), 1_440)
        CoreCheck.equal(TimeInput.endMinutes(from: "00:00", startMinutes: 0), 0)
        CoreCheck.equal(TimeInput.endMinutes(from: "24:00", startMinutes: 1_380), 1_440)
        CoreCheck.equal(TimeInput.endMinutes(from: "09:00", startMinutes: 480), 540)
        CoreCheck.nilValue(TimeInput.endMinutes(from: "wrong", startMinutes: 480))
    }

    func testOverlappingTasksAreRejectedRegardlessOfOrder() {
        CoreCheck.nonNil(PlanValidator.validate([task(540, 600), task(590, 650)]))
        CoreCheck.nonNil(PlanValidator.validate([task(590, 650), task(540, 600)]))
        CoreCheck.nonNil(PlanValidator.validate([task(540, 600), task(540, 600)]))
        CoreCheck.nonNil(PlanValidator.validate([task(540, 700), task(600, 650)]))
    }

    func testAdjacentTasksAndFreeGapsAreAllowed() {
        CoreCheck.nilValue(PlanValidator.validate([task(600, 660), task(540, 600), task(720, 780)]))
        CoreCheck.nilValue(PlanValidator.validate([task(0, 480), task(1_380, 1_440)]))
        CoreCheck.nilValue(PlanValidator.validate([]))
    }

    func testDuplicateIdentifiersAreRejected() {
        let identifier = UUID()
        let first = PlanTask(id: identifier, startMinutes: 540, endMinutes: 600, title: "学习", details: "")
        let second = PlanTask(id: identifier, startMinutes: 600, endMinutes: 660, title: "实践", details: "")
        CoreCheck.nonNil(PlanValidator.validate([first, second]))
    }

    func testInvalidRangesAreRejected() {
        for invalid in [task(-1, 60), task(1_440, 1_440), task(0, 1_441), task(0, 0), task(600, 540), task(600, 600)] {
            CoreCheck.nonNil(PlanValidator.validate([invalid]))
        }
        CoreCheck.nonNil(PlanValidator.validate([task(540, 600, title: " \n ")]))
    }

    func testDefaultPlanCoversWholeDayWithoutConflicts() {
        CoreCheck.equal(DefaultPlan.tasks.count, 28)
        CoreCheck.nilValue(PlanValidator.validate(DefaultPlan.tasks))
        CoreCheck.equal(DefaultPlan.tasks.first?.startMinutes, 0)
        CoreCheck.equal(DefaultPlan.tasks.last?.endMinutes, 1_440)
        for (first, second) in zip(DefaultPlan.tasks, DefaultPlan.tasks.dropFirst()) {
            CoreCheck.equal(first.endMinutes, second.startMinutes)
        }
    }

    func testTaskJSONRoundTripPreservesIdentityAndContents() throws {
        let task = PlanTask(startMinutes: 540, endMinutes: 600, title: "学习", details: "学习 Agent\n运行示例")
        let data = try JSONEncoder().encode([task])
        CoreCheck.equal(try JSONDecoder().decode([PlanTask].self, from: data), [task])
    }
}

private struct ScheduleEngineTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ value: String, timeZone: String = "Asia/Shanghai") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZone)!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)!
    }

    private func task(_ start: Int, _ end: Int, title: String = "学习") -> PlanTask {
        PlanTask(startMinutes: start, endMinutes: end, title: title, details: "详细说明")
    }

    func testCurrentTaskAndRemainingSeconds() {
        let current = task(540, 590)
        let next = task(590, 600, title: "休息")
        let snapshot = ScheduleEngine.snapshot(tasks: [current, next], at: date("2026-10-21 09:20:15"), calendar: calendar)
        CoreCheck.equal(snapshot.current, current)
        CoreCheck.equal(snapshot.next, next)
        CoreCheck.equal(snapshot.remaining, 1_785, accuracy: 0.001)
        CoreCheck.equal(snapshot.progress, 1_215.0 / 3_000, accuracy: 0.000001)
        CoreCheck.equal(snapshot.nextStart, date("2026-10-21 09:50:00"))
    }

    func testStartIsInclusiveAndEndIsExclusive() {
        let first = task(540, 590)
        let second = task(590, 600, title: "休息")
        let start = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 09:00:00"), calendar: calendar)
        CoreCheck.equal(start.current, first)
        CoreCheck.equal(start.progress, 0)
        CoreCheck.equal(start.remaining, 3_000)
        let boundary = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 09:50:00"), calendar: calendar)
        CoreCheck.equal(boundary.current, second)
        CoreCheck.equal(boundary.remaining, 600)
        let end = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 10:00:00"), calendar: calendar)
        CoreCheck.nilValue(end.current)
        CoreCheck.equal(end.next, first)
        CoreCheck.equal(end.nextStart, date("2026-10-22 09:00:00"))
    }

    func testMidnightSwitchesToNewDaysTask() {
        let sleep = task(0, 480, title: "睡眠")
        let late = task(1_380, 1_440, title: "睡前休息")
        let before = ScheduleEngine.snapshot(tasks: [late, sleep], at: date("2026-10-21 23:59:59"), calendar: calendar)
        CoreCheck.equal(before.current, late)
        CoreCheck.equal(before.remaining, 1)
        CoreCheck.equal(before.next, sleep)
        CoreCheck.equal(before.nextStart, date("2026-10-22 00:00:00"))
        let after = ScheduleEngine.snapshot(tasks: [late, sleep], at: date("2026-10-22 00:00:00"), calendar: calendar)
        CoreCheck.equal(after.current, sleep)
        CoreCheck.equal(after.remaining, 8 * 3_600)
    }

    func testFreeIntervalBetweenTasks() {
        let first = task(480, 540)
        let second = task(600, 660)
        let snapshot = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 09:30:00"), calendar: calendar)
        CoreCheck.nilValue(snapshot.current)
        CoreCheck.equal(snapshot.next, second)
        CoreCheck.equal(snapshot.intervalStart, date("2026-10-21 09:00:00"))
        CoreCheck.equal(snapshot.intervalEnd, date("2026-10-21 10:00:00"))
        CoreCheck.equal(snapshot.remaining, 1_800)
        CoreCheck.equal(snapshot.progress, 0.5)
    }

    func testFreeIntervalAcrossDays() {
        let only = task(540, 600)
        let night = ScheduleEngine.snapshot(tasks: [only], at: date("2026-10-21 23:00:00"), calendar: calendar)
        CoreCheck.nilValue(night.current)
        CoreCheck.equal(night.next, only)
        CoreCheck.equal(night.intervalStart, date("2026-10-21 10:00:00"))
        CoreCheck.equal(night.intervalEnd, date("2026-10-22 09:00:00"))
        CoreCheck.equal(night.remaining, 10 * 3_600)
        let morning = ScheduleEngine.snapshot(tasks: [only], at: date("2026-10-21 06:00:00"), calendar: calendar)
        CoreCheck.equal(morning.intervalStart, date("2026-10-20 10:00:00"))
        CoreCheck.equal(morning.nextStart, date("2026-10-21 09:00:00"))
    }

    func testEmptyPlanUsesLocalDay() {
        let snapshot = ScheduleEngine.snapshot(tasks: [], at: date("2026-10-21 12:00:00"), calendar: calendar)
        CoreCheck.nilValue(snapshot.current)
        CoreCheck.nilValue(snapshot.next)
        CoreCheck.nilValue(snapshot.nextStart)
        CoreCheck.equal(snapshot.intervalStart, date("2026-10-21 00:00:00"))
        CoreCheck.equal(snapshot.intervalEnd, date("2026-10-22 00:00:00"))
        CoreCheck.equal(snapshot.remaining, 12 * 3_600)
        CoreCheck.equal(snapshot.progress, 0.5)
    }

    func testUnsortedInputIsMatchedChronologically() {
        let first = task(480, 540)
        let current = task(540, 600)
        let next = task(600, 660)
        let snapshot = ScheduleEngine.snapshot(tasks: [next, first, current], at: date("2026-10-21 09:15:00"), calendar: calendar)
        CoreCheck.equal(snapshot.current, current)
        CoreCheck.equal(snapshot.next, next)
    }

    func testSystemClockJumpRecomputesFromActualTime() {
        let tasks = [task(540, 600), task(660, 720)]
        let beforeSleep = ScheduleEngine.snapshot(tasks: tasks, at: date("2026-10-21 09:15:00"), calendar: calendar)
        let afterWake = ScheduleEngine.snapshot(tasks: tasks, at: date("2026-10-21 11:45:00"), calendar: calendar)
        CoreCheck.equal(beforeSleep.current, tasks[0])
        CoreCheck.equal(afterWake.current, tasks[1])
        CoreCheck.equal(afterWake.remaining, 900)
    }

    func testSpringDSTUsesActualElapsedSeconds() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = task(90, 210)
        let snapshot = ScheduleEngine.snapshot(tasks: [morning], at: date("2026-03-08 03:00:00", timeZone: "America/Los_Angeles"), calendar: dstCalendar)
        CoreCheck.equal(snapshot.current, morning)
        CoreCheck.equal(snapshot.intervalEnd.timeIntervalSince(snapshot.intervalStart), 3_600)
        CoreCheck.equal(snapshot.remaining, 1_800)
        CoreCheck.equal(snapshot.progress, 0.5)
    }

    func testFallDSTUsesActualElapsedSeconds() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = task(30, 150)
        let snapshot = ScheduleEngine.snapshot(tasks: [morning], at: date("2026-11-01 02:00:00", timeZone: "America/Los_Angeles"), calendar: dstCalendar)
        CoreCheck.equal(snapshot.current, morning)
        CoreCheck.equal(snapshot.intervalEnd.timeIntervalSince(snapshot.intervalStart), 10_800)
        CoreCheck.equal(snapshot.remaining, 1_800)
        CoreCheck.equal(snapshot.progress, 5.0 / 6, accuracy: 0.000001)
    }

    func testEmptySpringDSTDayHas23Hours() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let snapshot = ScheduleEngine.snapshot(tasks: [], at: date("2026-03-08 12:00:00", timeZone: "America/Los_Angeles"), calendar: dstCalendar)
        CoreCheck.equal(snapshot.intervalEnd.timeIntervalSince(snapshot.intervalStart), 23 * 3_600)
    }
}

private struct PlanEditingChecks {
    private func task(_ start: Int, _ end: Int, title: String = "原任务") -> PlanTask {
        PlanTask(startMinutes: start, endMinutes: end, title: title, details: "原说明")
    }

    func testFullDefaultDayOffersNoFreeSlot() {
        CoreCheck.equal(PlanEditing.freeSlots(in: DefaultPlan.tasks), [])
        CoreCheck.equal(PlanEditing.conflicts(for: task(540, 550), in: DefaultPlan.tasks).count, 1)
    }

    func testFreeSlotAndAdjacentEdit() {
        let first = task(540, 600)
        let second = task(660, 720)
        CoreCheck.equal(PlanEditing.freeSlots(in: [first, second]), [
            PlanTimeSlot(startMinutes: 0, endMinutes: 540),
            PlanTimeSlot(startMinutes: 600, endMinutes: 660),
            PlanTimeSlot(startMinutes: 720, endMinutes: 1_440)
        ])
        CoreCheck.equal(PlanEditing.draft(in: [first, second], at: 600).startMinutes, 600)
        CoreCheck.equal(PlanEditing.conflicts(for: task(600, 660), in: [first, second]), [])
    }

    func testReplacementKeepsFragmentsAndUniqueIDs() throws {
        let original = task(540, 600)
        let incoming = task(550, 570, title: "插入")
        let result = try PlanEditing.replacingConflicts(with: incoming, in: [original])
        CoreCheck.equal(result.map(\.startMinutes), [540, 550, 570])
        CoreCheck.equal(result.map(\.endMinutes), [550, 570, 600])
        CoreCheck.equal(result[0].id, original.id)
        CoreCheck.record(result[2].id != original.id, "The split right fragment needs a distinct ID", file: #filePath, line: #line)
        CoreCheck.nilValue(PlanValidator.validate(result))
    }

    func testInvalidReplacementLeavesOriginalUntouched() {
        let base = [task(540, 600)]
        do {
            _ = try PlanEditing.replacingConflicts(with: task(590, 580), in: base)
            CoreCheck.record(false, "Invalid replacement should throw", file: #filePath, line: #line)
        } catch {
            CoreCheck.equal(base[0].startMinutes, 540)
            CoreCheck.equal(base[0].endMinutes, 600)
        }
    }
}

private struct ProgressChecks {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    func testManualCompletionAndUndo() {
        let item = PlanTask(startMinutes: 540, endMinutes: 600, title: "学习", details: "")
        let date = Date(timeIntervalSince1970: 1_792_548_000)
        var day = DailyProgress(tasks: [item], at: date, calendar: calendar)
        CoreCheck.equal(day.completionRate, 0)
        CoreCheck.equal(day.toggleCompletion(id: item.id, at: date), true)
        CoreCheck.equal(day.completedCount, 1)
        CoreCheck.equal(day.completionRate, 1)
        CoreCheck.equal(day.toggleCompletion(id: item.id, at: date), true)
        CoreCheck.equal(day.completedCount, 0)
        CoreCheck.equal(day.toggleCompletion(id: UUID(), at: date), false)
    }

    func testLocalDayAndIDReconciliation() {
        let item = PlanTask(startMinutes: 540, endMinutes: 600, title: "学习", details: "")
        let date = ISO8601DateFormatter().date(from: "2026-10-20T16:30:00Z")!
        var day = DailyProgress(tasks: [item], at: date, calendar: calendar)
        CoreCheck.equal(day.day, "2026-10-21")
        day.toggleCompletion(id: item.id, at: date)
        var edited = item
        edited.title = "新标题"
        let revised = day.synchronizing(tasks: [edited], calendar: calendar)
        CoreCheck.equal(revised.completedCount, 1)
        CoreCheck.equal(revised.tasks[0].task.title, "新标题")
        CoreCheck.equal(day.tasks[0].task.title, "学习")
        CoreCheck.equal(day.synchronizing(tasks: [], calendar: calendar).completionRate, 0)
    }

    func testLegacyPlanMigrationToSingleDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plan.json")
        let item = PlanTask(startMinutes: 540, endMinutes: 600, title: "学习", details: "")
        try JSONEncoder().encode([item]).write(to: url)
        let storage = ProgressStore(storageURL: url)
        let loaded = storage.load(defaultTasks: [])
        CoreCheck.equal(loaded.document.tasks, [item])
        CoreCheck.equal(loaded.document.history, [])
        try storage.save(loaded.document)
        CoreCheck.equal(try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: url)), loaded.document)
    }
}

private struct ActivityTimerChecks {
    private let start = Date(timeIntervalSince1970: 1_793_376_000)

    func testArchivePreservesHistoryIdentityAndBlocksStartingUntilRestored() throws {
        var document = try document()
        let activity = document.activities[0]
        try document.addNotedRecord(activityID: activity.id, startedAt: start, duration: 3600,
                                    note: "索引练习", at: start.addingTimeInterval(3600))
        let original = document.sessions
        try document.setActivityArchived(id: activity.id, archived: true)
        CoreCheck.truth(document.availableActivities.isEmpty)
        CoreCheck.equal(document.sessions, original)
        CoreCheck.equal(document.total(for: [activity.id], at: start.addingTimeInterval(7200)), 3600)
        CoreCheck.throwsError(try document.start(activityID: activity.id, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(7200)))
        let data = try JSONEncoder().encode(document)
        document = try JSONDecoder().decode(ActivityTimerDocument.self, from: data)
        try document.setActivityArchived(id: activity.id, archived: false)
        CoreCheck.equal(document.activities[0], activity)
        CoreCheck.equal(document.sessions, original)
        try document.start(activityID: activity.id, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(7200))
        let running = document
        CoreCheck.throwsError(try document.setActivityArchived(id: activity.id, archived: true))
        CoreCheck.equal(document, running)
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
        CoreCheck.nilValue(writer.blockedSaveReason)
        CoreCheck.equal(loaded.version, 2)
        CoreCheck.falseValue(loaded.activities[0].isArchived)
        CoreCheck.equal(loaded.activities[0].name, legacy.activities[0].name)
        CoreCheck.equal(try Data(contentsOf: backup), exact)
        CoreCheck.equal(try JSONDecoder().decode(ActivityTimerDocument.self, from: Data(contentsOf: url)).version, 2)
        _ = try writer.update { try $0.renameActivity(id: loaded.activities[0].id, name: "更新后") }
        CoreCheck.equal(try Data(contentsOf: backup), exact)

        // A later legacy file is backed up separately, preserving the first backup.
        oldObject["activities"] = [["id": loaded.activities[0].id.uuidString, "name": "旧版后来写入", "colorIndex": 0]]
        let later = try JSONSerialization.data(withJSONObject: oldObject)
        try later.write(to: url, options: .atomic)
        let second = ActivityTimerStore(storageURL: url).load()
        CoreCheck.equal(second.activities[0].name, "旧版后来写入")
        CoreCheck.equal(try Data(contentsOf: backup), exact)
        let additional = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("timers.v1-backup-") }
        CoreCheck.equal(additional.count, 1)
        CoreCheck.equal(try Data(contentsOf: additional[0]), later)
    }

    func testAtomicSwitchUsesOneBoundaryAndFailedTargetPreservesOriginalTimer() throws {
        var document = try document()
        let first = document.activities[0].id
        try document.addActivity(name: "SQL")
        let second = document.activities[1].id
        try document.start(activityID: first, mode: .stopwatch, duration: nil, at: start)
        let sessionID = document.activeSession!.id
        let original = document
        CoreCheck.throwsError(try document.switchActivity(to: second, mode: .countdown, duration: 0,
                                                        at: start.addingTimeInterval(60), expectedSessionID: sessionID))
        CoreCheck.equal(document, original)
        CoreCheck.throwsError(try document.switchActivity(to: second, mode: .stopwatch, duration: nil,
                                                        at: start.addingTimeInterval(60), expectedSessionID: UUID()))
        CoreCheck.equal(document, original)
        try document.switchActivity(to: second, mode: .countdown, duration: 300,
                                    at: start.addingTimeInterval(60), expectedSessionID: sessionID)
        CoreCheck.equal(document.sessions.filter { $0.endedAt == nil }.count, 1)
        CoreCheck.equal(document.sessions[0].savedDuration, 60)
        CoreCheck.equal(document.sessions[0].endedAt, document.activeSession?.startedAt)
        CoreCheck.equal(document.activeSession?.activityID, second)
        document.togglePause(at: start.addingTimeInterval(90))
        let pausedID = document.activeSession!.id
        try document.switchActivity(to: first, mode: .stopwatch, duration: nil,
                                    at: start.addingTimeInterval(600), expectedSessionID: pausedID)
        CoreCheck.equal(document.sessions[1].savedDuration, 30)
        CoreCheck.equal(document.activeSession?.startedAt, start.addingTimeInterval(600))
        try document.validate()
    }

    func testRecordEditUndoIsAtomicAndPreservesLaterRecords() throws {
        var document = try document()
        let id = document.activities[0].id
        try document.addRecord(activityID: id, startedAt: start, duration: 120, at: start.addingTimeInterval(120))
        let recordID = document.sessions[0].id
        let before = document
        CoreCheck.throwsError(try document.editRecord(sessionID: recordID, duration: 60, note: String(repeating: "字", count: 2001)))
        CoreCheck.equal(document, before)
        let action = ActivityTimerAction.editRecord(recordID, 60, "  窗口函数练习  ")
        try action.apply(to: &document, at: start, expectedSessionID: nil, expectedPauseState: nil)
        let undo = try CoreCheck.unwrap(action.undoToken(from: before, to: document))
        CoreCheck.equal(document.sessions[0].note, "窗口函数练习")
        try document.addRecord(activityID: id, startedAt: start.addingTimeInterval(300), duration: 30, at: start.addingTimeInterval(400))
        let added = document.sessions[1]
        try undo.apply(to: &document)
        CoreCheck.nilValue(document.sessions[0].correctedDuration)
        CoreCheck.nilValue(document.sessions[0].note)
        CoreCheck.equal(document.sessions[1], added)
        try undo.inverse.apply(to: &document)
        CoreCheck.equal(document.sessions[0].correctedDuration, 60)
        CoreCheck.equal(document.sessions[0].note, "窗口函数练习")
        try document.setSessionNote(sessionID: recordID, note: "其他窗口的新内容")
        let external = document
        CoreCheck.throwsError(try undo.apply(to: &document))
        CoreCheck.equal(document, external)
    }

    func testUndoRenameConflictsAndArchiveRedoKeepsItsOperationTitle() throws {
        var document = try document()
        let id = document.activities[0].id
        let before = document
        let rename = ActivityTimerAction.rename(id, "SQL")
        try rename.apply(to: &document, at: start, expectedSessionID: nil, expectedPauseState: nil)
        let undo = try CoreCheck.unwrap(rename.undoToken(from: before, to: document))
        try document.renameActivity(id: id, name: "其他窗口已改名")
        let external = document
        CoreCheck.throwsError(try undo.apply(to: &document))
        CoreCheck.equal(document, external)
        let archive = ActivityTimerAction.archive(id, true)
        let active = document
        try archive.apply(to: &document, at: start, expectedSessionID: nil, expectedPauseState: nil)
        let restore = try CoreCheck.unwrap(archive.undoToken(from: active, to: document))
        CoreCheck.equal(restore.title, restore.inverse.title)
        try restore.apply(to: &document)
        CoreCheck.falseValue(document.activities[0].isArchived)
        try restore.inverse.apply(to: &document)
        CoreCheck.truth(document.activities[0].isArchived)
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
        let undo = try CoreCheck.unwrap(result.undo)
        let restored = try await io.apply(.undo(undo), at: start, expectedSessionID: nil, expectedPauseState: nil, sleepBoundary: nil)
        CoreCheck.equal(restored.document.activities[0].name, "外部名称")
        CoreCheck.equal(restored.undo, undo.inverse)
        let noop = try await io.apply(.rename(id, "外部名称"), at: start, expectedSessionID: nil, expectedPauseState: nil, sleepBoundary: nil)
        CoreCheck.nilValue(noop.undo)
    }

    func testSwitchSleepJournalSurvivesCommitAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ActivityTimerStore(storageURL: directory.appendingPathComponent("timers.json"))
        var value = try document()
        try value.addActivity(name: "SQL")
        let first = value.activities[0].id, second = value.activities[1].id
        try value.start(activityID: first, mode: .stopwatch, duration: nil, at: start)
        let source = value.activeSession!
        let boundary = ActivitySleepBoundary(sessionID: source.id, runningSince: source.runningSince, date: start.addingTimeInterval(60))
        try value.switchActivity(to: second, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(30), expectedSessionID: source.id)
        try storage.save(value)
        // The journal may arrive after the successor has already been committed,
        // and recovery must work without any remaining in-memory request state.
        try storage.recordSleepBoundary(boundary)
        var recovered = ActivityTimerStore(storageURL: storage.storageURL).load()
        CoreCheck.equal(recovered.activeSession?.isPaused, true)
        CoreCheck.equal(recovered.total(for: [first, second], at: start.addingTimeInterval(17 * 3600)), 60)
        CoreCheck.equal(recovered.activeSession?.elapsed(at: start.addingTimeInterval(17 * 3600)), 30)
        recovered.togglePause(at: start.addingTimeInterval(120))
        try storage.save(recovered)
        try storage.recordSleepBoundary(boundary)
        let resumed = ActivityTimerStore(storageURL: storage.storageURL).load()
        CoreCheck.equal(resumed.activeSession?.runningSince, start.addingTimeInterval(120))

        var chain = value
        let middle = chain.activeSession!.id
        try chain.switchActivity(to: first, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(45), expectedSessionID: middle)
        try storage.save(chain)
        try storage.recordSleepBoundary(boundary)
        let chained = ActivityTimerStore(storageURL: storage.storageURL).load()
        CoreCheck.equal(chained.activeSession?.isPaused, true)
        CoreCheck.equal(chained.activeSession?.elapsed(at: start.addingTimeInterval(3600)), 15)
        CoreCheck.equal(chained.total(for: [first, second], at: start.addingTimeInterval(3600)), 60)
    }

    func testWorkerStatisticsTransferAndMetadataReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ActivityTimerStore(storageURL: directory.appendingPathComponent("timers.json"))
        var value = try document()
        let id = value.activities[0].id
        try value.addRecord(activityID: id, startedAt: start, duration: 60, at: start.addingTimeInterval(60))
        try storage.save(value)
        let date = start.addingTimeInterval(120)
        let worker = ActivityTimerIO(storageURL: storage.storageURL)
        let loaded = await worker.load(at: date)
        let cache = try CoreCheck.unwrap(loaded.preparedStatistics)
        CoreCheck.equal(cache.buildCount, 1)
        let snapshot = cache.value(document: loaded.document, revision: 100, at: date)
        CoreCheck.equal(snapshot.allTimeTotals[id], 60)
        CoreCheck.equal(cache.buildCount, 1)
        let unchanged = try await worker.refresh(at: date, sleepBoundary: nil)
        CoreCheck.nilValue(unchanged.preparedStatistics)
        let renamed = try await worker.apply(.rename(id, "改名复用"), at: date, expectedSessionID: nil, expectedPauseState: nil, sleepBoundary: nil)
        CoreCheck.nilValue(renamed.preparedStatistics)
        _ = cache.value(document: renamed.document, revision: 101, at: date)
        CoreCheck.equal(cache.buildCount, 1)
        let noted = try await worker.apply(.note(value.sessions[0].id, "新备注"), at: date, expectedSessionID: nil, expectedPauseState: nil, sleepBoundary: nil)
        let replacement = try CoreCheck.unwrap(noted.preparedStatistics)
        CoreCheck.equal(replacement.buildCount, 1)
        CoreCheck.equal(cache.buildCount, 1)
        CoreCheck.equal(replacement.value(document: noted.document, revision: 102, at: date).completedSessions[0].note, "新备注")
    }

    private func document() throws -> ActivityTimerDocument { var value = ActivityTimerDocument(); try value.addActivity(name: "阅读"); return value }

    func testSelectionReconciliationAndSleepJournal() throws {
        let date = Date(timeIntervalSince1970: 1_793_376_000)
        var document = ActivityTimerDocument()
        try document.addActivity(name: "SQL")
        try document.addActivity(name: "HTTP")
        let first = document.activities[0]
        var selection = ActivitySelectionState()
        selection.synchronize(with: document)
        selection.activityID = first.id
        selection.beginEditing(first, order: document.activities.map(\.id))
        selection.editedName = "未提交的草稿"
        try document.renameActivity(id: first.id, name: "外部更新的名称")
        selection.synchronize(with: document)
        CoreCheck.equal(selection.editedName, "未提交的草稿")
        selection.selectedForTotal.remove(document.activities[1].id)
        try document.addActivity(name: "新增项目")
        selection.synchronize(with: document)
        CoreCheck.equal(selection.selectedForTotal.contains(document.activities[1].id), false)
        CoreCheck.equal(selection.selectedForTotal.contains(document.activities[2].id), true)
        selection.pendingDeletion = first
        try document.deleteActivity(id: first.id)
        selection.synchronize(with: document)
        CoreCheck.nilValue(selection.activityID)
        CoreCheck.nilValue(selection.editingActivityID)
        CoreCheck.nilValue(selection.pendingDeletion)
        CoreCheck.equal(selection.editedName, "")
        CoreCheck.equal(selection.editingOrder, [])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ActivityTimerStore(storageURL: directory.appendingPathComponent("timers.json"))
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: date)
        try storage.save(document)
        let running = document.activeSession!
        try storage.recordSleepBoundary(.init(sessionID: running.id, runningSince: running.runningSince, date: date.addingTimeInterval(60)))
        let recovered = ActivityTimerStore(storageURL: storage.storageURL).load()
        CoreCheck.equal(recovered.activeSession?.isPaused, true)
        CoreCheck.equal(recovered.total(for: [id], at: date.addingTimeInterval(17 * 3600)), 60)
        CoreCheck.equal(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("timers.sleep-") }.count, 0)

        // A request queued before sleep must pause even if the record was created afterward.
        var empty = document
        empty.sessions = []
        try storage.save(empty)
        try storage.recordSleepBoundary(.init(date: date.addingTimeInterval(60)))
        let queued = try storage.update { try $0.start(activityID: id, mode: .stopwatch, duration: nil, at: date) }
        CoreCheck.equal(queued.activeSession?.isPaused, true)
        CoreCheck.equal(queued.total(for: [id], at: date.addingTimeInterval(17 * 3600)), 60)

        var resumed = recovered
        resumed.togglePause(at: date.addingTimeInterval(120))
        try storage.save(resumed)
        try storage.recordSleepBoundary(.init(sessionID: running.id, runningSince: running.runningSince, date: date.addingTimeInterval(60)))
        let retained = storage.load()
        CoreCheck.equal(retained.activeSession?.runningSince, date.addingTimeInterval(120))

        let cache = ActivityStatisticsCache()
        _ = cache.value(document: recovered, revision: 0, at: date.addingTimeInterval(200))
        let builds = cache.buildCount
        var renamed = recovered
        try renamed.renameActivity(id: id, name: "改名后")
        let metadata = cache.value(document: renamed, revision: 1, at: date.addingTimeInterval(200))
        CoreCheck.equal(cache.buildCount, builds)
        CoreCheck.equal(cache.metadataUpdateCount, 1)
        CoreCheck.equal(metadata.summaries(days: 0, order: .descending).first?.activity.name, "改名后")
    }

    func testIndexedChartHitTestingMatchesReference() {
        let day = Date(timeIntervalSince1970: 1_793_376_000)
        let plot = CGRect(x: 0, y: 0, width: 31 * 24, height: 600)
        var regions: [ActivityChartRegion] = []
        let activities = (0..<50).map { (index: Int) in TimedActivity(name: "项目\(index)", colorIndex: index) }
        for column in 0..<31 {
            var height: Double = 0
            for row in 0..<50 {
                let value = row % 7 == 0 ? 0.1 : Double((column * 13 + row * 7) % 80 + 1) / 10
                let point = ActivityDailyDuration(day: day.addingTimeInterval(Double(column * 86400)), activityID: activities[row].id, duration: value)
                let segment = ActivityDailyChartSegment(point: point, lowerBound: height)
                height += value
                regions.append(.init(segment: segment, activity: activities[row],
                                     frame: CGRect(x: Double(column * 24 + 4), y: 600 - height, width: 16, height: value)))
            }
        }
        let index = ActivityChartHitIndex(regions: regions, plot: plot)
        var seed: UInt64 = 0xF0C05
        for _ in 0..<6000 {
            seed = seed &* 6364136223846793005 &+ 1
            let x = Double((seed >> 32) % 75000) / 100 - 3
            seed = seed &* 6364136223846793005 &+ 1
            let y = Double((seed >> 32) % 60600) / 100 - 3
            let point = CGPoint(x: x, y: y)
            CoreCheck.equal(index.hitTest(point)?.id, ActivityChartRegion.hitTest(point, regions: regions, plot: plot)?.id)
        }
    }

    func testCachedStatisticsAndExternalWrites() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let first = ActivityTimerStore(storageURL: url)
        var document = ActivityTimerDocument()
        try document.addActivity(name: "Alpha")
        try document.addRecord(activityID: document.activities[0].id, startedAt: now.addingTimeInterval(-90000), duration: 7200, at: now)
        try first.save(document)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        let loaded = first.load()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let external = String(decoding: try Data(contentsOf: url), as: UTF8.self).replacingOccurrences(of: "Alpha", with: "Bravo")
        try Data(external.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: url.path)
        CoreCheck.equal(first.load().activities[0].name, "Bravo", "Same-size in-place edits must invalidate the file cache even if mtime is restored")
        let second = ActivityTimerStore(storageURL: url)
        _ = try second.update { try $0.addActivity(name: "Second") }
        let latest = try first.update { try $0.renameActivity(id: loaded.activities[0].id, name: "Charlie") }
        CoreCheck.equal(latest.activities.map(\.name), ["Charlie", "Second"])
        CoreCheck.equal(latest.sessions, document.sessions)
        let valid = try Data(contentsOf: url)
        try Data(repeating: 0x78, count: valid.count).write(to: url)
        var rejected = false
        do { _ = try first.update { try $0.addActivity(name: "Must not overwrite") } } catch { rejected = true }
        CoreCheck.equal(rejected, true)
        CoreCheck.equal(try Data(contentsOf: url), Data(repeating: 0x78, count: valid.count))
        try valid.write(to: url, options: .atomic)
        CoreCheck.equal(first.load(), latest)
        try FileManager.default.removeItem(at: url)
        let recreated = try first.update { try $0.addActivity(name: "Recreated") }
        CoreCheck.equal(recreated.activities.map(\.name), ["Recreated"])
        CoreCheck.equal(recreated.sessions.isEmpty, true)
        let cache = ActivityStatisticsCache()
        let snapshot = cache.value(document: document, revision: 0, at: now)
        CoreCheck.equal(snapshot.summaries(days: 0, order: .descending).map(\.duration), [7200])
        let builds = cache.buildCount
        _ = cache.value(document: document, revision: 0, at: now.addingTimeInterval(60))
        CoreCheck.equal(cache.buildCount, builds)
        _ = cache.value(document: recreated, revision: 1, at: now)
        CoreCheck.equal(cache.buildCount, builds + 1)
    }

    func testChartLabelsAndFilteredStacks() throws {
        var document = ActivityTimerDocument()
        for index in 1...32 { try document.addActivity(name: "学习项目 \(index)") }
        let retained = document.activities[17]
        CoreCheck.equal(Set(document.activities.map(\.chartLabel)).count, 32)
        CoreCheck.equal(document.activities[8].chartLabel, "#9")
        try document.deleteActivity(id: document.activities[0].id)
        try document.renameActivity(id: retained.id, name: "新名称")
        try document.addActivity(name: "后续新增")
        let restored = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONEncoder().encode(document))
        CoreCheck.equal(restored.activities.first { $0.id == retained.id }?.chartLabel, retained.chartLabel)
        CoreCheck.equal(Set(restored.activities.map(\.chartLabel)).count, 32)
        try restored.validate()
        let day = Date(timeIntervalSince1970: 1_793_376_000)
        let nextDay = day.addingTimeInterval(86400)
        let first = restored.activities[0].id, second = restored.activities[1].id
        let points = [ActivityDailyDuration(day: day, activityID: first, duration: 3600),
                      ActivityDailyDuration(day: day, activityID: second, duration: 1),
                      ActivityDailyDuration(day: nextDay, activityID: first, duration: 0),
                      ActivityDailyDuration(day: nextDay, activityID: second, duration: 1800)]
        let stack = ActivityDailyChartSegment.stacking(points)
        CoreCheck.equal(stack.map(\.lowerBound), [0, 3600, 0])
        CoreCheck.equal(stack.map(\.upperBound), [3600, 3601, 1800])
        CoreCheck.equal(stack.map { $0.point.activityID }, [first, second, second])
        let filtered = ActivityDailyChartSegment.stacking(points.filter { $0.activityID == second })
        CoreCheck.equal(filtered.map(\.lowerBound), [0, 0])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dst = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!
        let segment = ActivityDailyChartSegment(point: .init(day: dst, activityID: first, duration: 1), lowerBound: 0)
        let dates = segment.dateRange(calendar: calendar)
        CoreCheck.equal(dates.lowerBound.timeIntervalSince(dst), 23 * 3600 * 0.15, accuracy: 0.001)
        CoreCheck.equal(dates.upperBound.timeIntervalSince(dst), 23 * 3600 * 0.85, accuracy: 0.001)
    }

    func testSleepCorrectionsAndDailyColors() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-11-06T16:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for mode in ActivityTimerMode.allCases {
            var document = ActivityTimerDocument()
            try document.addActivity(name: "cpc")
            let id = document.activities[0].id
            try document.start(activityID: id, mode: mode, duration: 1800, at: midnight.addingTimeInterval(-60))
            document.pauseForSleep(at: midnight)
            document.pauseForSleep(at: midnight.addingTimeInterval(30))
            let wake = midnight.addingTimeInterval(17 * 3600)
            CoreCheck.equal(document.activeSession?.isPaused, true)
            CoreCheck.equal(document.total(for: [id], at: wake), 60)
            CoreCheck.equal(document.completeCountdown(at: wake), false)
            document.togglePause(at: wake)
            document.finish(at: wake.addingTimeInterval(30))
            CoreCheck.equal(document.total(for: [id], at: wake), 90)
            let sessionID = document.sessions[0].id
            try document.correctDuration(sessionID: sessionID, duration: 75)
            let points = document.dailyDurations(at: wake.addingTimeInterval(60), days: 2, calendar: calendar)
            CoreCheck.equal(points.map(\.duration), [60, 15])
            CoreCheck.equal(document.total(for: [id], at: wake), 75)
            CoreCheck.equal(document.sessions[0].recordedDuration, 90)
            for invalid: TimeInterval in [-1, .nan, .infinity, 91] {
                var rejected = false
                do { try document.correctDuration(sessionID: sessionID, duration: invalid) } catch { rejected = true }
                CoreCheck.equal(rejected, true)
            }
            try document.correctDuration(sessionID: sessionID, duration: 0)
            CoreCheck.equal(document.total(for: [id], at: wake), 0)
            try document.correctDuration(sessionID: sessionID, duration: 90)
            CoreCheck.equal(document.total(for: [id], at: wake), 90)
            let restored = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONEncoder().encode(document))
            CoreCheck.equal(restored, document)
            try restored.validate()
            try document.addActivity(name: "SQL")
            let sqlID = document.activities[1].id
            let color = document.colorIndex(for: sqlID)
            try document.deleteActivity(id: id)
            try document.addActivity(name: "Python")
            CoreCheck.equal(document.colorIndex(for: sqlID), color)
            CoreCheck.equal(Set(document.activities.compactMap(\.colorIndex)).count, 2)
        }
        var manual = ActivityTimerDocument()
        try manual.addActivity(name: "cpc")
        let id = manual.activities[0].id
        try manual.addRecord(activityID: id, startedAt: midnight.addingTimeInterval(-3600), duration: 7200, at: midnight.addingTimeInterval(7200))
        CoreCheck.equal(manual.dailyDurations(at: midnight.addingTimeInterval(7200), days: 2, calendar: calendar).map(\.duration), [3600, 3600])
        for invalid: TimeInterval in [0, -1, .nan, .infinity, 604_801] {
            var rejected = false
            do { try manual.addRecord(activityID: id, startedAt: midnight, duration: invalid, at: midnight.addingTimeInterval(7200)) } catch { rejected = true }
            CoreCheck.equal(rejected, true)
        }
        // Local calendar days, including the 23-hour daylight-saving day.
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dst = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!
        var spring = ActivityTimerDocument()
        try spring.addActivity(name: "DST")
        try spring.addRecord(activityID: spring.activities[0].id, startedAt: dst, duration: 23 * 3600, at: dst.addingTimeInterval(24 * 3600))
        CoreCheck.equal(spring.dailyDurations(at: dst.addingTimeInterval(24 * 3600), days: 2, calendar: calendar).map(\.duration), [TimeInterval(23 * 3600), 0])
    }

    func testStaleStoresAndLongFinish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let first = ActivityTimerStore(storageURL: url)
        let stale = ActivityTimerStore(storageURL: url)
        _ = first.load(); _ = stale.load()
        let created = try first.update { try $0.addActivity(name: "cpc") }
        let id = created.activities[0].id
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = try first.update { try $0.start(activityID: id, mode: .stopwatch, duration: nil, at: start) }
        _ = try stale.update { try $0.addActivity(name: "SQL") }
        _ = try first.update { $0.finish(at: start.addingTimeInterval(61_200)) }
        _ = try stale.update { try $0.renameActivity(id: id, name: "CPC") }
        let finished = first.load()
        CoreCheck.equal(finished.activities.map(\.name), ["CPC", "SQL"])
        CoreCheck.equal(finished.sessions.count, 1)
        CoreCheck.equal(finished.total(for: [id], at: start.addingTimeInterval(70_000)), 61_200)
        _ = try stale.update { try $0.correctDuration(sessionID: finished.sessions[0].id, duration: 5400) }
        CoreCheck.equal(first.load().total(for: [id], at: start.addingTimeInterval(70_000)), 5400)
        let original = try Data(contentsOf: url)
        var rejected = false
        do { _ = try first.update { try $0.correctDuration(sessionID: finished.sessions[0].id, duration: -1) } } catch { rejected = true }
        CoreCheck.equal(rejected, true)
        CoreCheck.equal(try Data(contentsOf: url), original)
        // Real concurrent transactions, rather than just alternating snapshots.
        let errors = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                _ = try ActivityTimerStore(storageURL: url).update { try $0.addActivity(name: "Parallel \(index)") }
            } catch {
                errors.lock(); failures.append(error.localizedDescription); errors.unlock()
            }
        }
        CoreCheck.equal(failures, [])
        CoreCheck.equal(first.load().activities.count, 14)
        CoreCheck.equal(first.load().total(for: [id], at: start.addingTimeInterval(70_000)), 5400)
    }

    func testRenameDeleteAndDurationSorting() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var document = ActivityTimerDocument()
        for name in ["阅读", "运动", "练字", "散步"] { try document.addActivity(name: name) }
        let ids = document.activities.map(\.id)
        try document.start(activityID: ids[0], mode: .stopwatch, duration: nil, at: start)
        document.finish(at: start.addingTimeInterval(100))
        try document.start(activityID: ids[1], mode: .stopwatch, duration: nil, at: start.addingTimeInterval(100))
        let now = start.addingTimeInterval(140)
        CoreCheck.equal(document.durationSummaries(at: now, order: .descending).map(\.id), [ids[0], ids[1], ids[2], ids[3]])
        CoreCheck.equal(document.durationSummaries(at: now, order: .ascending).map(\.id), [ids[2], ids[3], ids[1], ids[0]])
        let interval = DateInterval(start: start.addingTimeInterval(90), end: now)
        let range = document.durationSummaries(at: now, in: interval, order: .descending)
        CoreCheck.equal(range.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        CoreCheck.equal(range.map(\.duration), [40, 10, 0, 0])
        let originalSessions = document.sessions
        try document.renameActivity(id: ids[0], name: " 阅读书籍 ")
        CoreCheck.equal(document.activities[0].name, "阅读书籍")
        CoreCheck.equal(document.sessions, originalSessions)
        var rejected = false
        do { try document.renameActivity(id: ids[0], name: "运动") } catch { rejected = true }
        CoreCheck.equal(rejected, true)
        rejected = false
        do { try document.renameActivity(id: ids[0], name: " ") } catch { rejected = true }
        CoreCheck.equal(rejected, true)
        try document.deleteActivity(id: ids[1])
        CoreCheck.nilValue(document.activeSession)
        CoreCheck.equal(document.sessions, [originalSessions[0]])
        CoreCheck.equal(document.total(for: Set(ids), at: now), 100)
        try document.deleteActivity(id: ids[0])
        CoreCheck.equal(document.sessions.isEmpty, true)
        try document.addActivity(name: "阅读书籍")
        CoreCheck.equal(document.total(for: [document.activities.last!.id], at: now), 0)
        try document.validate()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timers-management-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityTimerStore(storageURL: url)
        try store.save(document)
        CoreCheck.equal(ActivityTimerStore(storageURL: url).load(), document)
    }

    func testAccumulationAndRangeClipping() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var document = ActivityTimerDocument()
        try document.addActivity(name: " 阅读 ")
        try document.addActivity(name: "运动")
        let first = document.activities[0].id
        let second = document.activities[1].id
        CoreCheck.equal(document.activities[0].name, "阅读")
        try document.start(activityID: first, mode: .stopwatch, duration: nil, at: start)
        document.togglePause(at: start.addingTimeInterval(60))
        CoreCheck.equal(document.activeSession?.elapsed(at: start.addingTimeInterval(200)), 60)
        document.togglePause(at: start.addingTimeInterval(200))
        document.finish(at: start.addingTimeInterval(260))
        try document.start(activityID: second, mode: .stopwatch, duration: nil, at: start.addingTimeInterval(260))
        let now = start.addingTimeInterval(300)
        CoreCheck.equal(document.total(for: [first, second], at: now), 160)
        CoreCheck.equal(document.total(for: [first], at: now, in: DateInterval(start: start.addingTimeInterval(30), end: now)), 90)
        CoreCheck.equal(document.total(for: [first, second], at: now, in: DateInterval(start: start.addingTimeInterval(30), end: now)), 130)
        CoreCheck.equal(document.total(for: [], at: now), 0)
        try document.validate()
    }

    func testCountdownPauseBoundaryAndWake() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var document = ActivityTimerDocument()
        try document.addActivity(name: "阅读")
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .countdown, duration: 120, at: start)
        document.togglePause(at: start.addingTimeInterval(30))
        CoreCheck.equal(document.completeCountdown(at: start.addingTimeInterval(1000)), false)
        CoreCheck.equal(document.activeSession?.remaining(at: start.addingTimeInterval(1000)), 90)
        document.togglePause(at: start.addingTimeInterval(1000))
        CoreCheck.equal(document.completeCountdown(at: start.addingTimeInterval(1089)), false)
        CoreCheck.equal(document.total(for: [id], at: start.addingTimeInterval(5000)), 120)
        CoreCheck.equal(document.completeCountdown(at: start.addingTimeInterval(5000)), true)
        CoreCheck.nilValue(document.activeSession)
        CoreCheck.equal(document.sessions[0].endedAt, start.addingTimeInterval(1090))
        CoreCheck.equal(document.completeCountdown(at: start.addingTimeInterval(6000)), false)
        try document.start(activityID: id, mode: .countdown, duration: 1, at: start.addingTimeInterval(6000))
        document.togglePause(at: start.addingTimeInterval(6001))
        CoreCheck.nilValue(document.activeSession)
        CoreCheck.equal(document.total(for: [id], at: start.addingTimeInterval(7000)), 121)
        try document.validate()
    }

    func testQuietReminderMigrationExtensionAndValidation() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var document = ActivityTimerDocument()
        try document.addActivity(name: "阅读")
        let id = document.activities[0].id
        try document.start(activityID: id, mode: .countdown, duration: 604_800, at: start)
        document.completeCountdown(at: start.addingTimeInterval(604_800))
        var restored = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONEncoder().encode(document))
        try restored.validate()
        CoreCheck.equal(restored.displayedSession?.id, document.sessions[0].id)
        CoreCheck.equal(restored.displayedSession?.progress(at: start.addingTimeInterval(800_000)), 1)
        CoreCheck.equal(restored.total(for: [id], at: start.addingTimeInterval(800_000)), 604_800)
        try restored.extendCountdown(at: start.addingTimeInterval(800_000))
        CoreCheck.nilValue(restored.pendingCountdownSessionID)
        CoreCheck.equal(restored.displayedSession?.remaining(at: start.addingTimeInterval(800_000)), 300)
        CoreCheck.equal(restored.total(for: [id], at: start.addingTimeInterval(800_020)), 604_820)
        restored.completeCountdown(at: start.addingTimeInterval(800_300))
        restored.finish(at: start.addingTimeInterval(900_000))
        CoreCheck.nilValue(restored.displayedSession)
        CoreCheck.equal(restored.total(for: [id], at: start.addingTimeInterval(900_000)), 605_100)
        try restored.validate()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
        json.removeValue(forKey: "pendingCountdownSessionID")
        let legacy = try JSONDecoder().decode(ActivityTimerDocument.self, from: JSONSerialization.data(withJSONObject: json))
        try legacy.validate()
        CoreCheck.nilValue(legacy.displayedSession)
        CoreCheck.equal(legacy.sessions, document.sessions)
        document.pendingCountdownSessionID = UUID()
        var rejected = false
        do { try document.validate() } catch { rejected = true }
        CoreCheck.equal(rejected, true)
    }

    func testPersistenceAndCorruptionProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timers.json")
        let store = ActivityTimerStore(storageURL: url)
        CoreCheck.equal(store.load(), ActivityTimerDocument())
        var document = ActivityTimerDocument()
        try document.addActivity(name: "阅读")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try document.start(activityID: document.activities[0].id, mode: .stopwatch, duration: nil, at: start)
        try store.save(document)
        var reloaded = ActivityTimerStore(storageURL: url).load()
        CoreCheck.equal(reloaded, document)
        CoreCheck.equal(reloaded.activeSession?.elapsed(at: start.addingTimeInterval(45)), 45)
        reloaded.togglePause(at: start.addingTimeInterval(45))
        try store.save(reloaded)
        CoreCheck.equal(ActivityTimerStore(storageURL: url).load().activeSession?.elapsed(at: start.addingTimeInterval(1000)), 45)
        let damaged = Data("broken timer file".utf8)
        try damaged.write(to: url)
        let protected = ActivityTimerStore(storageURL: url)
        CoreCheck.equal(protected.load(), ActivityTimerDocument())
        CoreCheck.nonNil(protected.blockedSaveReason)
        var rejected = false
        do { try protected.save(document) } catch { rejected = true }
        CoreCheck.equal(rejected, true)
        CoreCheck.equal(try Data(contentsOf: url), damaged)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("timers.corrupt-") }
        CoreCheck.equal(backups.count, 1)
        CoreCheck.equal(try Data(contentsOf: backups[0]), damaged)
    }
}

@main
private struct CoreCheckRunner {
    static func main() async throws {
        let planValidationTests = PlanValidationTests()
        planValidationTests.testValidTimeParsing()
        planValidationTests.testInvalidTimeParsing()
        planValidationTests.testFormattingAndMidnightEndNormalization()
        planValidationTests.testOverlappingTasksAreRejectedRegardlessOfOrder()
        planValidationTests.testAdjacentTasksAndFreeGapsAreAllowed()
        planValidationTests.testDuplicateIdentifiersAreRejected()
        planValidationTests.testInvalidRangesAreRejected()
        planValidationTests.testDefaultPlanCoversWholeDayWithoutConflicts()
        try planValidationTests.testTaskJSONRoundTripPreservesIdentityAndContents()
        let scheduleEngineTests = ScheduleEngineTests()
        scheduleEngineTests.testCurrentTaskAndRemainingSeconds()
        scheduleEngineTests.testStartIsInclusiveAndEndIsExclusive()
        scheduleEngineTests.testMidnightSwitchesToNewDaysTask()
        scheduleEngineTests.testFreeIntervalBetweenTasks()
        scheduleEngineTests.testFreeIntervalAcrossDays()
        scheduleEngineTests.testEmptyPlanUsesLocalDay()
        scheduleEngineTests.testUnsortedInputIsMatchedChronologically()
        scheduleEngineTests.testSystemClockJumpRecomputesFromActualTime()
        scheduleEngineTests.testSpringDSTUsesActualElapsedSeconds()
        scheduleEngineTests.testFallDSTUsesActualElapsedSeconds()
        scheduleEngineTests.testEmptySpringDSTDayHas23Hours()
        let planEditingChecks = PlanEditingChecks()
        planEditingChecks.testFullDefaultDayOffersNoFreeSlot()
        planEditingChecks.testFreeSlotAndAdjacentEdit()
        try planEditingChecks.testReplacementKeepsFragmentsAndUniqueIDs()
        planEditingChecks.testInvalidReplacementLeavesOriginalUntouched()
        let progressChecks = ProgressChecks()
        progressChecks.testManualCompletionAndUndo()
        progressChecks.testLocalDayAndIDReconciliation()
        try progressChecks.testLegacyPlanMigrationToSingleDocument()
        let activityTimerChecks = ActivityTimerChecks()
        try activityTimerChecks.testRenameDeleteAndDurationSorting()
        try activityTimerChecks.testAccumulationAndRangeClipping()
        try activityTimerChecks.testCountdownPauseBoundaryAndWake()
        try activityTimerChecks.testPersistenceAndCorruptionProtection()
        try activityTimerChecks.testQuietReminderMigrationExtensionAndValidation()
        try activityTimerChecks.testSleepCorrectionsAndDailyColors()
        try activityTimerChecks.testStaleStoresAndLongFinish()
        try activityTimerChecks.testChartLabelsAndFilteredStacks()
        try activityTimerChecks.testCachedStatisticsAndExternalWrites()
        try activityTimerChecks.testSelectionReconciliationAndSleepJournal()
        activityTimerChecks.testIndexedChartHitTestingMatchesReference()
        try activityTimerChecks.testArchivePreservesHistoryIdentityAndBlocksStartingUntilRestored()
        try activityTimerChecks.testVersionOneMigrationCreatesExactBackupAndRetriesWithoutOverwritingIt()
        try activityTimerChecks.testAtomicSwitchUsesOneBoundaryAndFailedTargetPreservesOriginalTimer()
        try activityTimerChecks.testRecordEditUndoIsAtomicAndPreservesLaterRecords()
        try activityTimerChecks.testUndoRenameConflictsAndArchiveRedoKeepsItsOperationTitle()
        try await activityTimerChecks.testBackgroundIOGeneratesUndoFromLatestCommittedValuesAndSkipsNoop()
        try activityTimerChecks.testSwitchSleepJournalSurvivesCommitAndRestart()
        try await activityTimerChecks.testWorkerStatisticsTransferAndMetadataReuse()
        print("Foundation checks: 46 cases, \(CoreCheck.checks) checks, \(CoreCheck.failures) failures")
        exit(CoreCheck.failures == 0 ? 0 : 1)
    }
}

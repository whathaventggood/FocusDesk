// Direct Foundation checks for environments without the XCTest framework.
// These checks compile the same production core files used by the macOS app.
import Foundation

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

@main
private struct CoreCheckRunner {
    static func main() throws {
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
        print("Foundation checks: 27 cases, \(CoreCheck.checks) checks, \(CoreCheck.failures) failures")
        exit(CoreCheck.failures == 0 ? 0 : 1)
    }
}

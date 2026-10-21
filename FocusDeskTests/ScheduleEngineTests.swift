import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import FocusDeskCore
#else
@testable import FocusDesk
#endif

final class ScheduleEngineTests: XCTestCase {
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
        XCTAssertEqual(snapshot.current, current)
        XCTAssertEqual(snapshot.next, next)
        XCTAssertEqual(snapshot.remaining, 1_785, accuracy: 0.001)
        XCTAssertEqual(snapshot.progress, 1_215.0 / 3_000, accuracy: 0.000001)
        XCTAssertEqual(snapshot.nextStart, date("2026-10-21 09:50:00"))
    }

    func testStartIsInclusiveAndEndIsExclusive() {
        let first = task(540, 590)
        let second = task(590, 600, title: "休息")
        let start = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 09:00:00"), calendar: calendar)
        XCTAssertEqual(start.current, first)
        XCTAssertEqual(start.progress, 0)
        XCTAssertEqual(start.remaining, 3_000)
        let boundary = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 09:50:00"), calendar: calendar)
        XCTAssertEqual(boundary.current, second)
        XCTAssertEqual(boundary.remaining, 600)
        let end = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 10:00:00"), calendar: calendar)
        XCTAssertNil(end.current)
        XCTAssertEqual(end.next, first)
        XCTAssertEqual(end.nextStart, date("2026-10-22 09:00:00"))
    }

    func testMidnightSwitchesToNewDaysTask() {
        let sleep = task(0, 480, title: "睡眠")
        let late = task(1_380, 1_440, title: "睡前休息")
        let before = ScheduleEngine.snapshot(tasks: [late, sleep], at: date("2026-10-21 23:59:59"), calendar: calendar)
        XCTAssertEqual(before.current, late)
        XCTAssertEqual(before.remaining, 1)
        XCTAssertEqual(before.next, sleep)
        XCTAssertEqual(before.nextStart, date("2026-10-22 00:00:00"))
        let after = ScheduleEngine.snapshot(tasks: [late, sleep], at: date("2026-10-22 00:00:00"), calendar: calendar)
        XCTAssertEqual(after.current, sleep)
        XCTAssertEqual(after.remaining, 8 * 3_600)
    }

    func testFreeIntervalBetweenTasks() {
        let first = task(480, 540)
        let second = task(600, 660)
        let snapshot = ScheduleEngine.snapshot(tasks: [first, second], at: date("2026-10-21 09:30:00"), calendar: calendar)
        XCTAssertNil(snapshot.current)
        XCTAssertEqual(snapshot.next, second)
        XCTAssertEqual(snapshot.intervalStart, date("2026-10-21 09:00:00"))
        XCTAssertEqual(snapshot.intervalEnd, date("2026-10-21 10:00:00"))
        XCTAssertEqual(snapshot.remaining, 1_800)
        XCTAssertEqual(snapshot.progress, 0.5)
    }

    func testFreeIntervalAcrossDays() {
        let only = task(540, 600)
        let night = ScheduleEngine.snapshot(tasks: [only], at: date("2026-10-21 23:00:00"), calendar: calendar)
        XCTAssertNil(night.current)
        XCTAssertEqual(night.next, only)
        XCTAssertEqual(night.intervalStart, date("2026-10-21 10:00:00"))
        XCTAssertEqual(night.intervalEnd, date("2026-10-22 09:00:00"))
        XCTAssertEqual(night.remaining, 10 * 3_600)
        let morning = ScheduleEngine.snapshot(tasks: [only], at: date("2026-10-21 06:00:00"), calendar: calendar)
        XCTAssertEqual(morning.intervalStart, date("2026-10-20 10:00:00"))
        XCTAssertEqual(morning.nextStart, date("2026-10-21 09:00:00"))
    }

    func testEmptyPlanUsesLocalDay() {
        let snapshot = ScheduleEngine.snapshot(tasks: [], at: date("2026-10-21 12:00:00"), calendar: calendar)
        XCTAssertNil(snapshot.current)
        XCTAssertNil(snapshot.next)
        XCTAssertNil(snapshot.nextStart)
        XCTAssertEqual(snapshot.intervalStart, date("2026-10-21 00:00:00"))
        XCTAssertEqual(snapshot.intervalEnd, date("2026-10-22 00:00:00"))
        XCTAssertEqual(snapshot.remaining, 12 * 3_600)
        XCTAssertEqual(snapshot.progress, 0.5)
    }

    func testUnsortedInputIsMatchedChronologically() {
        let first = task(480, 540)
        let current = task(540, 600)
        let next = task(600, 660)
        let snapshot = ScheduleEngine.snapshot(tasks: [next, first, current], at: date("2026-10-21 09:15:00"), calendar: calendar)
        XCTAssertEqual(snapshot.current, current)
        XCTAssertEqual(snapshot.next, next)
    }

    func testSystemClockJumpRecomputesFromActualTime() {
        let tasks = [task(540, 600), task(660, 720)]
        let beforeSleep = ScheduleEngine.snapshot(tasks: tasks, at: date("2026-10-21 09:15:00"), calendar: calendar)
        let afterWake = ScheduleEngine.snapshot(tasks: tasks, at: date("2026-10-21 11:45:00"), calendar: calendar)
        XCTAssertEqual(beforeSleep.current, tasks[0])
        XCTAssertEqual(afterWake.current, tasks[1])
        XCTAssertEqual(afterWake.remaining, 900)
    }

    func testSpringDSTUsesActualElapsedSeconds() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = task(90, 210)
        let snapshot = ScheduleEngine.snapshot(tasks: [morning], at: date("2026-03-08 03:00:00", timeZone: "America/Los_Angeles"), calendar: dstCalendar)
        XCTAssertEqual(snapshot.current, morning)
        XCTAssertEqual(snapshot.intervalEnd.timeIntervalSince(snapshot.intervalStart), 3_600)
        XCTAssertEqual(snapshot.remaining, 1_800)
        XCTAssertEqual(snapshot.progress, 0.5)
    }

    func testFallDSTUsesActualElapsedSeconds() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = task(30, 150)
        let snapshot = ScheduleEngine.snapshot(tasks: [morning], at: date("2026-11-01 02:00:00", timeZone: "America/Los_Angeles"), calendar: dstCalendar)
        XCTAssertEqual(snapshot.current, morning)
        XCTAssertEqual(snapshot.intervalEnd.timeIntervalSince(snapshot.intervalStart), 10_800)
        XCTAssertEqual(snapshot.remaining, 1_800)
        XCTAssertEqual(snapshot.progress, 5.0 / 6, accuracy: 0.000001)
    }

    func testEmptySpringDSTDayHas23Hours() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let snapshot = ScheduleEngine.snapshot(tasks: [], at: date("2026-03-08 12:00:00", timeZone: "America/Los_Angeles"), calendar: dstCalendar)
        XCTAssertEqual(snapshot.intervalEnd.timeIntervalSince(snapshot.intervalStart), 23 * 3_600)
    }
}

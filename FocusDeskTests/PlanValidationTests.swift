import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import FocusDeskCore
#else
@testable import FocusDesk
#endif

final class PlanValidationTests: XCTestCase {
    private func task(_ start: Int, _ end: Int, title: String = "任务") -> PlanTask {
        PlanTask(startMinutes: start, endMinutes: end, title: title, details: "")
    }

    func testValidTimeParsing() {
        XCTAssertEqual(TimeInput.parse("00:00"), 0)
        XCTAssertEqual(TimeInput.parse("09:05"), 545)
        XCTAssertEqual(TimeInput.parse("23:59"), 1_439)
        XCTAssertEqual(TimeInput.parse("24:00"), 1_440)
        XCTAssertEqual(TimeInput.parse(" 09:00 \n"), 540)
    }

    func testInvalidTimeParsing() {
        for input in ["9:00", "09:0", "09：00", "09:60", "24:01", "25:00", "-1:00", "ab:cd", "", "09:00:00", "０９:００"] {
            XCTAssertNil(TimeInput.parse(input), input)
        }
    }

    func testFormattingAndMidnightEndNormalization() {
        XCTAssertEqual(TimeInput.format(0), "00:00")
        XCTAssertEqual(TimeInput.format(545), "09:05")
        XCTAssertEqual(TimeInput.format(1_440), "00:00")
        XCTAssertEqual(TimeInput.endMinutes(from: "00:00", startMinutes: 1_380), 1_440)
        XCTAssertEqual(TimeInput.endMinutes(from: "00:00", startMinutes: 0), 0)
        XCTAssertEqual(TimeInput.endMinutes(from: "24:00", startMinutes: 1_380), 1_440)
        XCTAssertEqual(TimeInput.endMinutes(from: "09:00", startMinutes: 480), 540)
        XCTAssertNil(TimeInput.endMinutes(from: "wrong", startMinutes: 480))
    }

    func testOverlappingTasksAreRejectedRegardlessOfOrder() {
        XCTAssertNotNil(PlanValidator.validate([task(540, 600), task(590, 650)]))
        XCTAssertNotNil(PlanValidator.validate([task(590, 650), task(540, 600)]))
        XCTAssertNotNil(PlanValidator.validate([task(540, 600), task(540, 600)]))
        XCTAssertNotNil(PlanValidator.validate([task(540, 700), task(600, 650)]))
    }

    func testAdjacentTasksAndFreeGapsAreAllowed() {
        XCTAssertNil(PlanValidator.validate([task(600, 660), task(540, 600), task(720, 780)]))
        XCTAssertNil(PlanValidator.validate([task(0, 480), task(1_380, 1_440)]))
        XCTAssertNil(PlanValidator.validate([]))
    }

    func testDuplicateIdentifiersAreRejected() {
        let identifier = UUID()
        let first = PlanTask(id: identifier, startMinutes: 540, endMinutes: 600, title: "学习", details: "")
        let second = PlanTask(id: identifier, startMinutes: 600, endMinutes: 660, title: "实践", details: "")
        XCTAssertNotNil(PlanValidator.validate([first, second]))
    }

    func testInvalidRangesAreRejected() {
        for invalid in [task(-1, 60), task(1_440, 1_440), task(0, 1_441), task(0, 0), task(600, 540), task(600, 600)] {
            XCTAssertNotNil(PlanValidator.validate([invalid]))
        }
        XCTAssertNotNil(PlanValidator.validate([task(540, 600, title: " \n ")]))
    }

    func testDefaultPlanCoversWholeDayWithoutConflicts() {
        XCTAssertEqual(DefaultPlan.tasks.count, 28)
        XCTAssertNil(PlanValidator.validate(DefaultPlan.tasks))
        XCTAssertEqual(DefaultPlan.tasks.first?.startMinutes, 0)
        XCTAssertEqual(DefaultPlan.tasks.last?.endMinutes, 1_440)
        for (first, second) in zip(DefaultPlan.tasks, DefaultPlan.tasks.dropFirst()) {
            XCTAssertEqual(first.endMinutes, second.startMinutes)
        }
    }

    func testTaskJSONRoundTripPreservesIdentityAndContents() throws {
        let task = PlanTask(startMinutes: 540, endMinutes: 600, title: "学习", details: "学习 Agent\n运行示例")
        let data = try JSONEncoder().encode([task])
        XCTAssertEqual(try JSONDecoder().decode([PlanTask].self, from: data), [task])
    }
}

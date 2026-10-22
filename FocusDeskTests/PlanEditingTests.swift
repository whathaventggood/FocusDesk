import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import FocusDeskCore
#else
@testable import FocusDesk
#endif

final class PlanEditingTests: XCTestCase {
    private func task(_ start: Int, _ end: Int, title: String = "任务", details: String = "原始说明") -> PlanTask {
        PlanTask(startMinutes: start, endMinutes: end, title: title, details: details)
    }

    func testFullDefaultDayHasNoFreeSlot() {
        XCTAssertTrue(PlanEditing.freeSlots(in: DefaultPlan.tasks).isEmpty)
        XCTAssertNil(PlanValidator.validate(DefaultPlan.tasks))
    }

    func testEmptyPlanHasWholeDayAvailable() {
        XCTAssertEqual(PlanEditing.freeSlots(in: []), [PlanTimeSlot(startMinutes: 0, endMinutes: 1_440)])
    }

    func testFreeSlotsIncludesLeadingInternalAndTrailingGapsRegardlessOfOrder() {
        let tasks = [task(200, 300), task(60, 120), task(120, 180)]
        XCTAssertEqual(PlanEditing.freeSlots(in: tasks), [
            PlanTimeSlot(startMinutes: 0, endMinutes: 60),
            PlanTimeSlot(startMinutes: 180, endMinutes: 200),
            PlanTimeSlot(startMinutes: 300, endMinutes: 1_440)
        ])
    }

    func testDraftUsesFirstGapAndFitsShortGap() {
        let draft = PlanEditing.draft(in: [task(0, 60), task(70, 1_440)])
        XCTAssertEqual(draft.startMinutes, 60)
        XCTAssertEqual(draft.endMinutes, 70)
        XCTAssertTrue(draft.title.isEmpty)
    }

    func testDraftCanPreferGapAtCurrentMinute() {
        let draft = PlanEditing.draft(in: [task(0, 60), task(120, 180), task(240, 1_440)], at: 190)
        XCTAssertEqual(draft.startMinutes, 190)
        XCTAssertEqual(draft.endMinutes, 220)
    }

    func testConflictDetectionExcludesSelfAndAdjacentBoundaries() {
        let original = task(60, 120)
        let previous = task(0, 60)
        let next = task(120, 180)
        XCTAssertTrue(PlanEditing.conflicts(for: original, in: [original, previous, next]).isEmpty)
        var edited = original
        edited.endMinutes = 121
        XCTAssertEqual(PlanEditing.conflicts(for: edited, in: [original, previous, next]), [next])
        XCTAssertEqual(PlanEditing.freeSlots(in: [previous, original, next], excluding: original.id), [
            PlanTimeSlot(startMinutes: 60, endMinutes: 120),
            PlanTimeSlot(startMinutes: 180, endMinutes: 1_440)
        ])
    }

    func testReplacementSplitsContainingTaskWithoutLosingContentsOrReusingID() throws {
        let original = task(60, 240, title: "旧任务", details: "保留的说明")
        let replacement = task(120, 180, title: "新任务")
        let result = try PlanEditing.replacingConflicts(with: replacement, in: [original])
        XCTAssertEqual(result.map(\.startMinutes), [60, 120, 180])
        XCTAssertEqual(result.map(\.endMinutes), [120, 180, 240])
        XCTAssertEqual(result[0].id, original.id)
        XCTAssertNotEqual(result[2].id, original.id)
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
        XCTAssertEqual(result[0].title, original.title)
        XCTAssertEqual(result[2].title, original.title)
        XCTAssertEqual(result[0].details, original.details)
        XCTAssertEqual(result[2].details, original.details)
        XCTAssertEqual(result[1], replacement)
        XCTAssertNil(PlanValidator.validate(result))
        // A preview candidate never mutates the caller's original value.
        XCTAssertEqual(original.startMinutes, 60)
        XCTAssertEqual(original.endMinutes, 240)
    }

    func testReplacementAcrossSeveralTasksTrimsEdgesAndDeletesFullyCoveredTask() throws {
        let left = task(0, 100, title: "左侧")
        let covered = task(100, 200, title: "完全覆盖")
        let right = task(200, 300, title: "右侧")
        let unaffected = task(400, 500, title: "不受影响")
        let replacement = task(50, 250, title: "新任务")
        let result = try PlanEditing.replacingConflicts(with: replacement, in: [right, unaffected, covered, left])
        XCTAssertEqual(result.map(\.startMinutes), [0, 50, 250, 400])
        XCTAssertEqual(result.map(\.endMinutes), [50, 250, 300, 500])
        XCTAssertEqual(result[0].id, left.id)
        XCTAssertEqual(result[2].id, right.id)
        XCTAssertFalse(result.contains { $0.id == covered.id })
        XCTAssertEqual(result.last, unaffected)
        XCTAssertNil(PlanValidator.validate(result))
    }

    func testReplacementOfExactRangePreservesAdjacentTasks() throws {
        let before = task(0, 60)
        let covered = task(60, 120)
        let after = task(120, 180)
        let replacement = task(60, 120, title: "新任务")
        XCTAssertEqual(try PlanEditing.replacingConflicts(with: replacement, in: [before, covered, after]), [before, replacement, after])
    }

    func testEditingExistingTaskRemovesItsOldSpanWithoutTreatingSelfAsConflict() throws {
        let original = task(60, 120)
        var edited = original
        edited.startMinutes = 0
        edited.endMinutes = 180
        let next = task(180, 240)
        let result = try PlanEditing.replacingConflicts(with: edited, in: [original, next])
        XCTAssertEqual(result, [edited, next])
        XCTAssertNil(PlanValidator.validate(result))
    }

    func testReplacementCanCoverWholeDayIncludingMidnight() throws {
        let replacement = task(0, 1_440, title: "休息日")
        let result = try PlanEditing.replacingConflicts(with: replacement, in: DefaultPlan.tasks)
        XCTAssertEqual(result, [replacement])
        XCTAssertNil(PlanValidator.validate(result))
    }

    func testInvalidReplacementCannotProduceAPlan() {
        let tasks = [task(0, 1_440)]
        for invalid in [task(-1, 100), task(1_440, 1_440), task(100, 100), task(120, 60), task(0, 1_441), task(60, 120, title: " ")] {
            XCTAssertThrowsError(try PlanEditing.replacingConflicts(with: invalid, in: tasks))
        }
    }

    func testReplacementRejectsAnAlreadyInvalidBasePlanInsteadOfSilentlyRepairingIt() {
        let duplicateID = UUID()
        let first = PlanTask(id: duplicateID, startMinutes: 0, endMinutes: 100, title: "A", details: "")
        let second = PlanTask(id: duplicateID, startMinutes: 100, endMinutes: 200, title: "B", details: "")
        XCTAssertThrowsError(try PlanEditing.replacingConflicts(with: task(200, 300), in: [first, second]))
        XCTAssertThrowsError(try PlanEditing.replacingConflicts(with: task(200, 300), in: [task(0, 100), task(50, 150)]))
    }

    func testSlotFormatsDayEndWithoutAmbiguousMidnight() {
        let slot = PlanTimeSlot(startMinutes: 1_380, endMinutes: 1_440)
        XCTAssertEqual(slot.displayRange, "23:00–24:00")
        XCTAssertEqual(slot.durationMinutes, 60)
    }
}

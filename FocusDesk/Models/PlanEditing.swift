import Foundation

struct PlanTimeSlot: Identifiable, Equatable {
    var startMinutes: Int
    var endMinutes: Int

    var id: String { "\(startMinutes)-\(endMinutes)" }
    var durationMinutes: Int { endMinutes - startMinutes }
    var displayRange: String { "\(TimeInput.format(startMinutes))–\(endMinutes == 1_440 ? "24:00" : TimeInput.format(endMinutes))" }
}

enum PlanEditingError: LocalizedError {
    case invalidPlan(String)

    var errorDescription: String? {
        switch self {
        case .invalidPlan(let reason): return reason
        }
    }
}

enum PlanEditing {
    static func freeSlots(in tasks: [PlanTask], excluding identifier: UUID? = nil) -> [PlanTimeSlot] {
        var cursor = 0
        var slots: [PlanTimeSlot] = []
        for task in tasks.filter({ $0.id != identifier }).sorted(by: { $0.startMinutes < $1.startMinutes }) {
            let start = max(0, min(1_440, task.startMinutes))
            let end = max(0, min(1_440, task.endMinutes))
            guard end > start else { continue }
            if start > cursor { slots.append(PlanTimeSlot(startMinutes: cursor, endMinutes: start)) }
            cursor = max(cursor, end)
        }
        if cursor < 1_440 { slots.append(PlanTimeSlot(startMinutes: cursor, endMinutes: 1_440)) }
        return slots
    }

    /// A full day produces an empty-title draft only; the editor leaves its time fields blank.
    static func draft(in tasks: [PlanTask], at minutes: Int = 0) -> PlanTask {
        let slots = freeSlots(in: tasks)
        let preferred = slots.first(where: { $0.endMinutes > minutes }) ?? slots.first
        let start = preferred.map { max($0.startMinutes, min(minutes, $0.endMinutes - 1)) } ?? 0
        let end = preferred.map { min(start + 30, $0.endMinutes) } ?? 30
        return PlanTask(startMinutes: start, endMinutes: end, title: "", details: "")
    }

    static func conflicts(for task: PlanTask, in tasks: [PlanTask]) -> [PlanTask] {
        guard task.startMinutes < task.endMinutes else { return [] }
        return tasks.filter {
            $0.id != task.id && $0.startMinutes < task.endMinutes && task.startMinutes < $0.endMinutes
        }.sorted { $0.startMinutes < $1.startMinutes }
    }

    /// Builds a complete candidate without mutating the original plan. The caller must confirm and save atomically.
    static func replacingConflicts(with task: PlanTask, in tasks: [PlanTask]) throws -> [PlanTask] {
        if let reason = PlanValidator.validate([task]) { throw PlanEditingError.invalidPlan(reason) }
        if let reason = PlanValidator.validate(tasks) { throw PlanEditingError.invalidPlan(reason) }
        var candidate: [PlanTask] = []
        for original in tasks where original.id != task.id {
            guard original.startMinutes < task.endMinutes && task.startMinutes < original.endMinutes else {
                candidate.append(original)
                continue
            }
            if original.startMinutes < task.startMinutes {
                var left = original
                left.endMinutes = task.startMinutes
                candidate.append(left)
            }
            if original.endMinutes > task.endMinutes {
                var right = original
                // Keep the identity of a single remaining fragment; a split requires a new right-hand ID.
                if original.startMinutes < task.startMinutes { right.id = UUID() }
                right.startMinutes = task.endMinutes
                candidate.append(right)
            }
        }
        candidate.append(task)
        if let reason = PlanValidator.validate(candidate) { throw PlanEditingError.invalidPlan(reason) }
        return candidate.sorted { $0.startMinutes < $1.startMinutes }
    }
}

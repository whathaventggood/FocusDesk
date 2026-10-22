import Foundation

/// A value snapshot of one task, so editing tomorrow's plan cannot rewrite yesterday.
struct TaskProgress: Identifiable, Codable, Equatable {
    var task: PlanTask
    var completedAt: Date?

    var id: UUID { task.id }
    var isCompleted: Bool { completedAt != nil }
}

struct DailyProgress: Identifiable, Codable, Equatable {
    var day: String
    var timeZoneIdentifier: String
    var tasks: [TaskProgress]

    var id: String { day }
    var totalCount: Int { tasks.count }
    var completedCount: Int { tasks.filter(\.isCompleted).count }
    var completionRate: Double {
        totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount)
    }

    init(day: String, timeZoneIdentifier: String, tasks: [TaskProgress]) {
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.tasks = tasks
    }

    init(tasks: [PlanTask], at date: Date, calendar: Calendar = .current) {
        day = Self.dayKey(for: date, calendar: calendar)
        timeZoneIdentifier = calendar.timeZone.identifier
        self.tasks = tasks.sorted { $0.startMinutes < $1.startMinutes }
            .map { TaskProgress(task: $0, completedAt: nil) }
    }

    /// Always use the local Gregorian date, even if the system uses another calendar.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let gregorian = localCalendar(calendar)
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func localCalendar(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// Only today's snapshot is reconciled with the editable recurring plan.
    func synchronizing(tasks plan: [PlanTask], calendar: Calendar) -> DailyProgress {
        let completed = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.completedAt) })
        return DailyProgress(
            day: day,
            timeZoneIdentifier: calendar.timeZone.identifier,
            tasks: plan.sorted { $0.startMinutes < $1.startMinutes }.map {
                TaskProgress(task: $0, completedAt: completed[$0.id] ?? nil)
            }
        )
    }

    @discardableResult
    mutating func toggleCompletion(id: UUID, at date: Date) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].completedAt = tasks[index].isCompleted ? nil : date
        return true
    }
}

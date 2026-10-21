import Foundation

struct ScheduleSnapshot {
    let current: PlanTask?
    let next: PlanTask?
    let intervalStart: Date
    let intervalEnd: Date
    let nextStart: Date?
    private let observedAt: Date

    var remaining: TimeInterval {
        max(0, intervalEnd.timeIntervalSince(observedAt))
    }

    var progress: Double {
        let duration = intervalEnd.timeIntervalSince(intervalStart)
        guard duration > 0 else { return 0 }
        return min(1, max(0, observedAt.timeIntervalSince(intervalStart) / duration))
    }

    fileprivate init(
        current: PlanTask?,
        next: PlanTask?,
        intervalStart: Date,
        intervalEnd: Date,
        nextStart: Date?,
        observedAt: Date
    ) {
        self.current = current
        self.next = next
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.nextStart = nextStart
        self.observedAt = observedAt
    }
}

enum ScheduleEngine {
    private struct Occurrence {
        let task: PlanTask
        let start: Date
        let end: Date
    }

    static func snapshot(
        tasks: [PlanTask],
        at now: Date,
        calendar: Calendar = .current
    ) -> ScheduleSnapshot {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        // Include neighboring days so a free interval and the next task can cross midnight.
        let occurrences = (-1...1).flatMap { offset -> [Occurrence] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }
            return tasks.compactMap { task in
                guard (0..<1_440).contains(task.startMinutes),
                      (1...1_440).contains(task.endMinutes),
                      task.endMinutes > task.startMinutes,
                      let start = date(at: task.startMinutes, on: day, calendar: calendar),
                      let end = date(at: task.endMinutes, on: day, calendar: calendar),
                      end > start else { return nil }
                return Occurrence(task: task, start: start, end: end)
            }
        }.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }

        let current = occurrences.first { $0.start <= now && now < $0.end }
        let next = occurrences.first { $0.start > now }
        let intervalStart: Date
        let intervalEnd: Date
        if let current {
            intervalStart = current.start
            intervalEnd = current.end
        } else {
            intervalStart = occurrences.filter { $0.end <= now }.map(\.end).max() ?? today
            intervalEnd = next?.start ?? tomorrow
        }

        return ScheduleSnapshot(
            current: current?.task,
            next: next?.task,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            nextStart: next?.start,
            observedAt: now
        )
    }

    private static func date(at minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        if minutes == 1_440 {
            return calendar.date(byAdding: .day, value: 1, to: day)
        }
        // Use wall-clock components rather than adding seconds: DST days are not always 24 hours.
        // A nonexistent local time advances to the next valid time; repeated times use the first instance.
        return calendar.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

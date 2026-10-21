import Foundation

/// A recurring daily time block, expressed as minutes after local midnight.
struct PlanTask: Identifiable, Codable, Equatable {
    var id: UUID
    var startMinutes: Int
    var endMinutes: Int
    var title: String
    var details: String

    init(
        id: UUID = UUID(),
        startMinutes: Int,
        endMinutes: Int,
        title: String,
        details: String
    ) {
        self.id = id
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.title = title
        self.details = details
    }
}

enum TimeInput {
    /// Accepts HH:mm, including 24:00 as the end of a day.
    static func parse(_ value: String) -> Int? {
        let characters = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard characters.count == 5,
              characters[2] == 58,
              [0, 1, 3, 4].allSatisfy({ (48...57).contains(characters[$0]) }) else {
            return nil
        }
        let hour = Int(characters[0] - 48) * 10 + Int(characters[1] - 48)
        let minute = Int(characters[3] - 48) * 10 + Int(characters[4] - 48)
        guard minute < 60, hour < 24 || (hour == 24 && minute == 0) else {
            return nil
        }
        return hour * 60 + minute
    }

    static func format(_ minutes: Int) -> String {
        let normalized = ((minutes % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    /// The UI displays midnight as 00:00; a non-midnight block ends at 1440.
    static func endMinutes(from value: String, startMinutes: Int) -> Int? {
        guard let minutes = parse(value) else { return nil }
        return minutes == 0 && startMinutes > 0 ? 1_440 : minutes
    }
}

enum PlanValidator {
    /// Adjacent blocks are allowed; overnight blocks must be split at midnight.
    static func validate(_ tasks: [PlanTask]) -> String? {
        var identifiers = Set<UUID>()
        for task in tasks {
            guard identifiers.insert(task.id).inserted else {
                return "计划中存在重复的任务标识，请删除并重新创建重复的任务。"
            }
            let label = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return "请输入任务名称。" }
            guard (0..<1_440).contains(task.startMinutes) else {
                return "“\(label)”的开始时间必须在 00:00 至 23:59 之间。"
            }
            guard (1...1_440).contains(task.endMinutes) else {
                return "“\(label)”的结束时间必须在 00:01 至 24:00 之间。"
            }
            guard task.endMinutes > task.startMinutes else {
                return "“\(label)”的结束时间必须晚于开始时间；跨午夜的任务请拆成两段。"
            }
        }

        let sorted = tasks.sorted {
            if $0.startMinutes == $1.startMinutes { return $0.endMinutes < $1.endMinutes }
            return $0.startMinutes < $1.startMinutes
        }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            if next.startMinutes < previous.endMinutes {
                return "“\(previous.title)”与“\(next.title)”的时间段重叠，请调整时间。"
            }
        }
        return nil
    }
}

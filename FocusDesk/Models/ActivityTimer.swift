import Foundation

struct TimedActivity: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
}

enum ActivityTimerMode: String, Codable, CaseIterable {
    case stopwatch, countdown

    var title: String { self == .stopwatch ? "正计时" : "倒计时" }
}

enum ActivityDurationSortOrder: String, CaseIterable {
    case descending, ascending

    var title: String { self == .ascending ? "时长升序（短 → 长）" : "时长降序（长 → 短）" }
}

struct ActivityDurationSummary: Identifiable {
    var activity: TimedActivity
    var duration: TimeInterval
    var id: UUID { activity.id }
}

/// Each running stretch is retained separately, so paused time never enters statistics.
struct ActivityTimeSegment: Codable, Equatable {
    var start: Date
    var end: Date

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func duration(in interval: DateInterval?) -> TimeInterval {
        guard let interval else { return duration }
        return max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
    }
}

struct ActivityTimerSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var activityID: UUID
    var mode: ActivityTimerMode
    var targetDuration: TimeInterval?
    var startedAt: Date
    var segments: [ActivityTimeSegment] = []
    var runningSince: Date?
    var endedAt: Date?

    var isPaused: Bool { runningSince == nil && endedAt == nil }
    var savedDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    func elapsed(at date: Date) -> TimeInterval {
        savedDuration + (liveSegment(at: date)?.duration ?? 0)
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, (targetDuration ?? 0) - elapsed(at: date))
    }

    func duration(at date: Date, in interval: DateInterval? = nil) -> TimeInterval {
        segments.reduce(0) { $0 + $1.duration(in: interval) }
            + (liveSegment(at: date)?.duration(in: interval) ?? 0)
    }

    private func liveSegment(at date: Date) -> ActivityTimeSegment? {
        guard let start = runningSince else { return nil }
        let elapsed = max(0, date.timeIntervalSince(start))
        let duration = targetDuration.map { min(elapsed, max(0, $0 - savedDuration)) } ?? elapsed
        return ActivityTimeSegment(start: start, end: start.addingTimeInterval(duration))
    }

    mutating func pause(at date: Date) {
        guard let segment = liveSegment(at: date) else { return }
        if segment.duration > 0 { segments.append(segment) }
        runningSince = nil
    }

    mutating func finish(at date: Date) {
        let actualEnd = liveSegment(at: date)?.end ?? date
        pause(at: date)
        endedAt = max(segments.last?.end ?? startedAt, actualEnd)
    }
}

struct ActivityTimerDocument: Codable, Equatable {
    var version = 1
    var activities: [TimedActivity] = []
    var sessions: [ActivityTimerSession] = []

    var activeSession: ActivityTimerSession? { sessions.first { $0.endedAt == nil } }

    mutating func addActivity(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActivityTimerError.invalid("请输入事项名称。") }
        guard !activities.contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw ActivityTimerError.invalid("已有同名事项，请选择已有事项继续累计。")
        }
        activities.append(TimedActivity(name: trimmed))
    }

    mutating func renameActivity(id: UUID, name: String) throws {
        guard let index = activities.firstIndex(where: { $0.id == id }) else {
            throw ActivityTimerError.invalid("这个事项已不存在，请刷新后重试。")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActivityTimerError.invalid("请输入事项名称。") }
        guard !activities.contains(where: {
            $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw ActivityTimerError.invalid("已有同名事项，请使用其他名称。")
        }
        activities[index].name = trimmed
    }

    /// Removing the sessions in the same commit prevents orphaned records and stale running timers.
    mutating func deleteActivity(id: UUID) throws {
        guard activities.contains(where: { $0.id == id }) else {
            throw ActivityTimerError.invalid("这个事项已不存在，请刷新后重试。")
        }
        activities.removeAll { $0.id == id }
        sessions.removeAll { $0.activityID == id }
    }

    mutating func start(activityID: UUID, mode: ActivityTimerMode, duration: TimeInterval?, at date: Date) throws {
        guard activeSession == nil else { throw ActivityTimerError.invalid("请先结束当前计时，再开始其他计时。") }
        guard activities.contains(where: { $0.id == activityID }) else { throw ActivityTimerError.invalid("请选择一个事项。") }
        if mode == .countdown {
            guard let duration, duration.isFinite, duration >= 1, duration <= 604_800 else {
                throw ActivityTimerError.invalid("倒计时时长须为 1 秒至 7 天。")
            }
        }
        sessions.append(ActivityTimerSession(activityID: activityID, mode: mode,
                                            targetDuration: mode == .countdown ? duration : nil,
                                            startedAt: date, runningSince: date))
    }

    @discardableResult
    mutating func completeCountdown(at date: Date) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.endedAt == nil }),
              sessions[index].mode == .countdown, sessions[index].runningSince != nil,
              sessions[index].remaining(at: date) <= 0 else { return false }
        sessions[index].finish(at: date)
        return true
    }

    mutating func togglePause(at date: Date) {
        if completeCountdown(at: date) { return }
        guard let index = sessions.firstIndex(where: { $0.endedAt == nil }) else { return }
        if sessions[index].runningSince == nil {
            sessions[index].runningSince = max(date, sessions[index].segments.last?.end ?? sessions[index].startedAt)
        } else {
            sessions[index].pause(at: date)
        }
    }

    mutating func finish(at date: Date) {
        guard let index = sessions.firstIndex(where: { $0.endedAt == nil }) else { return }
        sessions[index].finish(at: date)
    }

    func total(for activityIDs: Set<UUID>, at date: Date, in interval: DateInterval? = nil) -> TimeInterval {
        sessions.filter { activityIDs.contains($0.activityID) }.reduce(0) { $0 + $1.duration(at: date, in: interval) }
    }

    func durationSummaries(at date: Date, in interval: DateInterval? = nil,
                           order: ActivityDurationSortOrder) -> [ActivityDurationSummary] {
        var totals: [UUID: TimeInterval] = [:]
        for session in sessions {
            totals[session.activityID, default: 0] += session.duration(at: date, in: interval)
        }
        // Preserve creation order for equal durations, including activities without records.
        return activities.enumerated().map { index, activity in
            (index: index, summary: ActivityDurationSummary(activity: activity, duration: totals[activity.id] ?? 0))
        }.sorted { left, right in
            if left.summary.duration == right.summary.duration { return left.index < right.index }
            return order == .ascending
                ? left.summary.duration < right.summary.duration
                : left.summary.duration > right.summary.duration
        }.map(\.summary)
    }

    func validate() throws {
        guard version == 1 else { throw ActivityTimerError.invalid("无法识别事项计时数据版本。") }
        let ids = Set(activities.map(\.id))
        guard ids.count == activities.count,
              activities.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.filter({ $0.endedAt == nil }).count <= 1 else {
            throw ActivityTimerError.invalid("事项名称、标识或运行中的计时无效。")
        }
        for session in sessions {
            guard ids.contains(session.activityID), session.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  session.endedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  session.runningSince?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  session.endedAt == nil || session.runningSince == nil else {
                throw ActivityTimerError.invalid("事项计时记录无效。")
            }
            if session.mode == .countdown {
                guard let target = session.targetDuration, target.isFinite, (1...604_800).contains(target),
                      session.savedDuration <= target + 0.001 else {
                    throw ActivityTimerError.invalid("倒计时时长无效。")
                }
            } else if session.targetDuration != nil {
                throw ActivityTimerError.invalid("正计时记录包含无效的目标时长。")
            }
            var previous = session.startedAt
            for segment in session.segments {
                guard segment.start.timeIntervalSinceReferenceDate.isFinite,
                      segment.end.timeIntervalSinceReferenceDate.isFinite,
                      segment.start >= previous, segment.end >= segment.start else {
                    throw ActivityTimerError.invalid("事项计时片段无效。")
                }
                previous = segment.end
            }
            guard session.runningSince.map({ $0 >= previous }) ?? true,
                  session.endedAt.map({ $0 >= previous }) ?? true else {
                throw ActivityTimerError.invalid("事项计时顺序无效。")
            }
        }
    }
}

enum ActivityTimerError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum ActivityDurationFormat {
    static func clock(_ duration: TimeInterval, roundUp: Bool = false) -> String {
        let seconds = Int(max(0, roundUp ? ceil(duration) : floor(duration)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    static func summary(_ duration: TimeInterval) -> String {
        let seconds = Int(max(0, floor(duration)))
        return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分 \(seconds % 60) 秒"
    }
}


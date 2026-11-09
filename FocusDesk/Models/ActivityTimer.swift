import Foundation
import CoreGraphics

struct TimedActivity: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var colorIndex: Int?
    var isArchived = false

    init(id: UUID = UUID(), name: String, colorIndex: Int? = nil, isArchived: Bool = false) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorIndex, isArchived }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        colorIndex = try values.decodeIfPresent(Int.self, forKey: .colorIndex)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    // A stable visible identifier also distinguishes projects with similar colors.
    var chartLabel: String { "#\(UInt(max(0, colorIndex ?? 0)) + 1)" }
}

enum ActivityTimerMode: String, Codable, CaseIterable {
    case stopwatch, countdown

    var title: String { self == .stopwatch ? L("正计时") : L("倒计时") }
}

enum ActivityDurationSortOrder: String, CaseIterable {
    case descending, ascending

    var title: String { self == .ascending ? L("时长升序（短 → 长）") : L("时长降序（长 → 短）") }
}

struct ActivityDurationSummary: Identifiable {
    var activity: TimedActivity
    var duration: TimeInterval
    var id: UUID { activity.id }
}

struct ActivityDailyDuration: Identifiable, Equatable {
    var day: Date
    var activityID: UUID
    var duration: TimeInterval
    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(activityID)" }
}

struct ActivityDailyChartSegment: Identifiable, Equatable {
    var point: ActivityDailyDuration
    var lowerBound: TimeInterval
    var upperBound: TimeInterval { lowerBound + point.duration }
    var id: String { point.id }

    /// Both the drawing and hover regions use these explicit stack bounds.
    static func stacking(_ points: [ActivityDailyDuration]) -> [Self] {
        var totals: [Date: TimeInterval] = [:]
        return points.compactMap { point in
            guard point.duration > 0, point.duration.isFinite else { return nil }
            let lower = totals[point.day, default: 0]
            totals[point.day] = lower + point.duration
            return Self(point: point, lowerBound: lower)
        }
    }

    func dateRange(calendar: Calendar = .current) -> ClosedRange<Date> {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: point.day) ?? point.day
        let length = nextDay.timeIntervalSince(point.day)
        return point.day.addingTimeInterval(length * 0.15)...point.day.addingTimeInterval(length * 0.85)
    }
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
    // Keep the original segments so a correction can be changed or restored later.
    var correctedDuration: TimeInterval?
    // Retain the switch predecessor so a sleep journal written while a switch
    // was in flight can also pause its successor after a process restart.
    var switchedFromSessionID: UUID?
    var note: String?

    var isPaused: Bool { runningSince == nil && endedAt == nil }
    var isAwaitingCompletion: Bool { mode == .countdown && endedAt != nil }
    var recordedDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    var savedDuration: TimeInterval { correctedDuration ?? recordedDuration }

    private var effectiveSegments: [ActivityTimeSegment] {
        guard var remaining = correctedDuration else { return segments }
        return segments.compactMap { segment in
            let duration = min(segment.duration, remaining)
            remaining -= duration
            return duration > 0 ? ActivityTimeSegment(start: segment.start, end: segment.start.addingTimeInterval(duration)) : nil
        }
    }

    fileprivate func forEachSavedSegment(_ visit: (ActivityTimeSegment) -> Void) {
        var remaining = correctedDuration ?? .infinity
        for segment in segments where remaining > 0 {
            let duration = min(segment.duration, remaining)
            if duration > 0 { visit(ActivityTimeSegment(start: segment.start, end: segment.start.addingTimeInterval(duration))) }
            remaining -= duration
        }
    }

    func progress(at date: Date) -> Double {
        guard let targetDuration, targetDuration > 0 else { return 0 }
        return min(1, max(0, elapsed(at: date) / targetDuration))
    }

    func elapsed(at date: Date) -> TimeInterval {
        savedDuration + (liveSegment(at: date)?.duration ?? 0)
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, (targetDuration ?? 0) - elapsed(at: date))
    }

    func duration(at date: Date, in interval: DateInterval? = nil) -> TimeInterval {
        effectiveSegments.reduce(0) { $0 + $1.duration(in: interval) }
            + (liveSegment(at: date)?.duration(in: interval) ?? 0)
    }

    fileprivate func liveSegment(at date: Date) -> ActivityTimeSegment? {
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
    var version = 2
    var activities: [TimedActivity] = []
    var sessions: [ActivityTimerSession] = []
    // Optional for compatibility with timer files created before quiet reminders.
    var pendingCountdownSessionID: UUID?

    var activeSession: ActivityTimerSession? { sessions.first { $0.endedAt == nil } }
    var pendingCountdown: ActivityTimerSession? { sessions.first { $0.id == pendingCountdownSessionID } }
    var displayedSession: ActivityTimerSession? { activeSession ?? pendingCountdown }
    var availableActivities: [TimedActivity] { activities.filter { !$0.isArchived } }

    mutating func addActivity(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActivityTimerError.invalid(L("请输入项目名称。")) }
        guard !activities.contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw ActivityTimerError.invalid(L("已有同名项目，请选择已有项目继续累计。"))
        }
        assignActivityColors()
        let usedColors = Set(activities.compactMap(\.colorIndex))
        let nextColor = (0...activities.count).first { !usedColors.contains($0) }!
        activities.append(TimedActivity(name: trimmed, colorIndex: nextColor))
    }

    /// Migrates old records without changing their identities or durations.
    mutating func assignActivityColors() {
        var used = Set(activities.compactMap(\.colorIndex))
        for index in activities.indices where activities[index].colorIndex == nil {
            let color = (0...activities.count).first { !used.contains($0) }!
            activities[index].colorIndex = color
            used.insert(color)
        }
    }

    func colorIndex(for activityID: UUID) -> Int {
        var colored = self
        colored.assignActivityColors()
        return colored.activities.first { $0.id == activityID }?.colorIndex ?? 0
    }

    mutating func renameActivity(id: UUID, name: String) throws {
        guard let index = activities.firstIndex(where: { $0.id == id }) else {
            throw ActivityTimerError.invalid(L("这个项目已不存在，请刷新后重试。"))
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActivityTimerError.invalid(L("请输入项目名称。")) }
        guard !activities.contains(where: {
            $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw ActivityTimerError.invalid(L("已有同名项目，请使用其他名称。"))
        }
        activities[index].name = trimmed
    }

    mutating func setActivityArchived(id: UUID, archived: Bool) throws {
        guard let index = activities.firstIndex(where: { $0.id == id }) else {
            throw ActivityTimerError.invalid(L("这个项目已不存在，请刷新后重试。"))
        }
        guard !archived || displayedSession?.activityID != id else {
            throw ActivityTimerError.invalid(L("请先结束或完成当前计时，再归档这个项目。"))
        }
        activities[index].isArchived = archived
    }

    /// Removing the sessions in the same commit prevents orphaned records and stale running timers.
    mutating func deleteActivity(id: UUID) throws {
        guard activities.contains(where: { $0.id == id }) else {
            throw ActivityTimerError.invalid(L("这个项目已不存在，请刷新后重试。"))
        }
        activities.removeAll { $0.id == id }
        sessions.removeAll { $0.activityID == id }
        if pendingCountdown == nil { pendingCountdownSessionID = nil }
    }

    mutating func start(activityID: UUID, mode: ActivityTimerMode, duration: TimeInterval?, at date: Date) throws {
        guard activeSession == nil else { throw ActivityTimerError.invalid(L("请先结束当前计时，再开始其他计时。")) }
        guard let activity = activities.first(where: { $0.id == activityID }) else { throw ActivityTimerError.invalid(L("请选择一个项目。")) }
        guard !activity.isArchived else { throw ActivityTimerError.invalid(L("请先恢复归档项目，再开始计时。")) }
        if mode == .countdown {
            guard let duration, duration.isFinite, duration >= 1, duration <= 604_800 else {
                throw ActivityTimerError.invalid(L("倒计时时长须为 1 秒至 7 天。"))
            }
        }
        sessions.append(ActivityTimerSession(activityID: activityID, mode: mode,
                                            targetDuration: mode == .countdown ? duration : nil,
                                            startedAt: date, runningSince: date))
        pendingCountdownSessionID = nil
    }

    /// Validate the complete transition before replacing either side of the timer.
    mutating func switchActivity(to activityID: UUID, mode: ActivityTimerMode, duration: TimeInterval?,
                                 at date: Date, expectedSessionID: UUID?) throws {
        guard let previous = displayedSession, expectedSessionID == previous.id else {
            throw ActivityTimerError.invalid(L("计时状态已更新，请重试。"))
        }
        guard previous.activityID != activityID else {
            throw ActivityTimerError.invalid(L("当前已经在计时这个项目。"))
        }
        var candidate = self
        let boundary = max(date, previous.segments.last?.end ?? previous.startedAt, previous.runningSince ?? previous.startedAt)
        candidate.finish(at: boundary)
        try candidate.start(activityID: activityID, mode: mode, duration: duration, at: boundary)
        candidate.sessions[candidate.sessions.count - 1].switchedFromSessionID = previous.id
        self = candidate
    }

    @discardableResult
    mutating func completeCountdown(at date: Date) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.endedAt == nil }),
              sessions[index].mode == .countdown, sessions[index].runningSince != nil,
              sessions[index].remaining(at: date) <= 0 else { return false }
        sessions[index].finish(at: date)
        pendingCountdownSessionID = sessions[index].id
        return true
    }

    /// A fresh stretch excludes the time spent waiting for the user to respond.
    mutating func extendCountdown(at date: Date) throws {
        completeCountdown(at: date)
        guard let completed = pendingCountdown else {
            throw ActivityTimerError.invalid(L("请在倒计时到时后延长计时。"))
        }
        try start(activityID: completed.activityID, mode: .countdown, duration: 300, at: date)
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
        pendingCountdownSessionID = nil
        guard let index = sessions.firstIndex(where: { $0.endedAt == nil }) else { return }
        sessions[index].finish(at: date)
    }

    /// Sleep is idempotent: an already paused timer must never resume here.
    mutating func pauseForSleep(at date: Date) {
        if completeCountdown(at: date) { return }
        guard let index = sessions.firstIndex(where: { $0.endedAt == nil }),
              sessions[index].runningSince != nil else { return }
        sessions[index].pause(at: date)
    }

    mutating func correctDuration(sessionID: UUID, duration: TimeInterval) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw ActivityTimerError.invalid(L("这条计时记录已不存在，请刷新后重试。"))
        }
        guard sessions[index].endedAt != nil, pendingCountdownSessionID != sessionID else {
            throw ActivityTimerError.invalid(L("请先完成这次计时，再修改学习时长。"))
        }
        guard duration.isFinite, duration >= 0, duration <= sessions[index].recordedDuration else {
            throw ActivityTimerError.invalid(L("修改后的时长须在 0 和原始计时时长之间。"))
        }
        sessions[index].correctedDuration = duration
    }

    mutating func setSessionNote(sessionID: UUID, note: String?) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw ActivityTimerError.invalid(L("这条计时记录已不存在，请刷新后重试。"))
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed?.count ?? 0) <= 2000 else {
            throw ActivityTimerError.invalid(L("本次学习内容最多填写 2000 个字符。"))
        }
        sessions[index].note = trimmed?.isEmpty == false ? trimmed : nil
    }

    mutating func editRecord(sessionID: UUID, duration: TimeInterval, note: String?) throws {
        var candidate = self
        try candidate.correctDuration(sessionID: sessionID, duration: duration)
        try candidate.setSessionNote(sessionID: sessionID, note: note)
        self = candidate
    }

    mutating func addNotedRecord(activityID: UUID, startedAt: Date, duration: TimeInterval, note: String?, at date: Date) throws {
        var candidate = self
        try candidate.addRecord(activityID: activityID, startedAt: startedAt, duration: duration, at: date)
        try candidate.setSessionNote(sessionID: candidate.sessions.last!.id, note: note)
        self = candidate
    }

    mutating func addRecord(activityID: UUID, startedAt: Date, duration: TimeInterval, at date: Date) throws {
        guard activities.contains(where: { $0.id == activityID }) else {
            throw ActivityTimerError.invalid(L("请选择一个项目。"))
        }
        guard startedAt.timeIntervalSinceReferenceDate.isFinite, duration.isFinite,
              duration >= 1, duration <= 604_800,
              startedAt.addingTimeInterval(duration) <= date else {
            throw ActivityTimerError.invalid(L("补记时长须为 1 秒至 7 天，结束时间不能晚于现在。"))
        }
        let end = startedAt.addingTimeInterval(duration)
        sessions.append(ActivityTimerSession(activityID: activityID, mode: .stopwatch,
                                            startedAt: startedAt,
                                            segments: [.init(start: startedAt, end: end)], endedAt: end))
    }

    func dailyDurations(at date: Date, days: Int, calendar: Calendar = .current) -> [ActivityDailyDuration] {
        guard (1...31).contains(days) else { return [] }
        return ActivityStatisticsIndex(document: self, at: date, calendar: calendar, days: days,
                                       includeRecords: false).snapshot(at: date).dailyPoints
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
        guard (1...2).contains(version) else { throw ActivityTimerError.invalid(L("无法识别事项计时数据版本。")) }
        let ids = Set(activities.map(\.id))
        guard ids.count == activities.count,
              activities.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              activities.allSatisfy({ $0.colorIndex.map { $0 >= 0 } ?? true }),
              Set(activities.compactMap(\.colorIndex)).count == activities.compactMap(\.colorIndex).count,
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.filter({ $0.endedAt == nil }).count <= 1 else {
            throw ActivityTimerError.invalid(L("事项名称、标识或运行中的计时无效。"))
        }
        if pendingCountdownSessionID != nil {
            guard activeSession == nil, let pending = pendingCountdown,
                  pending.mode == .countdown, pending.endedAt != nil,
                  let target = pending.targetDuration, abs(pending.savedDuration - target) <= 0.001 else {
                throw ActivityTimerError.invalid(L("倒计时到时提醒无效。"))
            }
        }
        if let displayedSession, activities.first(where: { $0.id == displayedSession.activityID })?.isArchived == true {
            throw ActivityTimerError.invalid(L("归档项目不能包含当前计时。"))
        }
        for session in sessions {
            guard ids.contains(session.activityID), session.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  session.endedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  session.runningSince?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  session.endedAt == nil || session.runningSince == nil else {
                throw ActivityTimerError.invalid(L("事项计时记录无效。"))
            }
            guard (session.note?.count ?? 0) <= 2000 else {
                throw ActivityTimerError.invalid(L("本次学习内容最多填写 2000 个字符。"))
            }
            if let corrected = session.correctedDuration {
                guard session.endedAt != nil, corrected.isFinite, corrected >= 0,
                      corrected <= session.recordedDuration else {
                    throw ActivityTimerError.invalid(L("修改后的时长须在 0 和原始计时时长之间。"))
                }
            }
            if session.mode == .countdown {
                guard let target = session.targetDuration, target.isFinite, (1...604_800).contains(target),
                      session.recordedDuration <= target + 0.001 else {
                    throw ActivityTimerError.invalid(L("倒计时时长无效。"))
                }
            } else if session.targetDuration != nil {
                throw ActivityTimerError.invalid(L("正计时记录包含无效的目标时长。"))
            }
            var previous = session.startedAt
            for segment in session.segments {
                guard segment.start.timeIntervalSinceReferenceDate.isFinite,
                      segment.end.timeIntervalSinceReferenceDate.isFinite,
                      segment.start >= previous, segment.end >= segment.start else {
                    throw ActivityTimerError.invalid(L("事项计时片段无效。"))
                }
                previous = segment.end
            }
            guard session.runningSince.map({ $0 >= previous }) ?? true,
                  session.endedAt.map({ $0 >= previous }) ?? true else {
                throw ActivityTimerError.invalid(L("事项计时顺序无效。"))
            }
        }
    }
}

/// A field-level inverse checks the value written by its operation before
/// restoring anything. New sessions and unrelated edits remain untouched.
enum ActivityTimerUndo: Equatable {
    case rename(UUID, before: String, after: String)
    case archive(UUID, before: Bool, after: Bool, originalArchived: Bool? = nil)
    case correction(UUID, before: TimeInterval?, after: TimeInterval?)
    case note(UUID, before: String?, after: String?)
    case recordEdit(UUID, beforeDuration: TimeInterval?, beforeNote: String?, afterDuration: TimeInterval?, afterNote: String?)

    var title: String {
        switch self {
        case .rename: return L("修改项目名称")
        case .archive(_, _, let after, let original): return (original ?? after) ? L("归档项目") : L("恢复项目")
        case .correction: return L("修改学习时长")
        case .note: return L("修改学习内容")
        case .recordEdit: return L("修改学习记录")
        }
    }

    var inverse: ActivityTimerUndo {
        switch self {
        case .rename(let id, let before, let after): return .rename(id, before: after, after: before)
        case .archive(let id, let before, let after, let original):
            return .archive(id, before: after, after: before, originalArchived: original ?? after)
        case .correction(let id, let before, let after): return .correction(id, before: after, after: before)
        case .note(let id, let before, let after): return .note(id, before: after, after: before)
        case .recordEdit(let id, let beforeDuration, let beforeNote, let afterDuration, let afterNote):
            return .recordEdit(id, beforeDuration: afterDuration, beforeNote: afterNote, afterDuration: beforeDuration, afterNote: beforeNote)
        }
    }

    func apply(to document: inout ActivityTimerDocument) throws {
        let conflict = ActivityTimerError.invalid(L("这项内容已被更新，无法撤销，以保留较新的修改。"))
        var candidate = document
        switch self {
        case .rename(let id, let before, let after):
            guard candidate.activities.first(where: { $0.id == id })?.name == after else { throw conflict }
            try candidate.renameActivity(id: id, name: before)
        case .archive(let id, let before, let after, _):
            guard candidate.activities.first(where: { $0.id == id })?.isArchived == after else { throw conflict }
            try candidate.setActivityArchived(id: id, archived: before)
        case .correction(let id, let before, let after):
            guard let index = candidate.sessions.firstIndex(where: { $0.id == id }), candidate.sessions[index].correctedDuration == after,
                  candidate.sessions[index].endedAt != nil, candidate.pendingCountdownSessionID != id else { throw conflict }
            candidate.sessions[index].correctedDuration = before
        case .note(let id, let before, let after):
            guard let index = candidate.sessions.firstIndex(where: { $0.id == id }), candidate.sessions[index].note == after else { throw conflict }
            try candidate.setSessionNote(sessionID: id, note: before)
        case .recordEdit(let id, let beforeDuration, let beforeNote, let afterDuration, let afterNote):
            guard let index = candidate.sessions.firstIndex(where: { $0.id == id }),
                  candidate.sessions[index].correctedDuration == afterDuration, candidate.sessions[index].note == afterNote,
                  candidate.sessions[index].endedAt != nil, candidate.pendingCountdownSessionID != id else { throw conflict }
            candidate.sessions[index].correctedDuration = beforeDuration
            try candidate.setSessionNote(sessionID: id, note: beforeNote)
        }
        try candidate.validate()
        document = candidate
    }
}

enum ActivityTimerAction {
    case add(String), rename(UUID, String), delete(UUID)
    case archive(UUID, Bool), note(UUID, String?)
    case start(UUID, ActivityTimerMode, TimeInterval?)
    case switchActivity(UUID, ActivityTimerMode, TimeInterval?)
    case togglePause, finish, extend
    case correct(UUID, TimeInterval), addRecord(UUID, Date, TimeInterval)
    case editRecord(UUID, TimeInterval, String?), addNotedRecord(UUID, Date, TimeInterval, String?)
    case undo(ActivityTimerUndo)

    func undoToken(from before: ActivityTimerDocument, to after: ActivityTimerDocument) -> ActivityTimerUndo? {
        switch self {
        case .rename(let id, _):
            guard let old = before.activities.first(where: { $0.id == id }), let new = after.activities.first(where: { $0.id == id }), old.name != new.name else { return nil }
            return .rename(id, before: old.name, after: new.name)
        case .archive(let id, _):
            guard let old = before.activities.first(where: { $0.id == id }), let new = after.activities.first(where: { $0.id == id }), old.isArchived != new.isArchived else { return nil }
            return .archive(id, before: old.isArchived, after: new.isArchived)
        case .correct(let id, _):
            guard let old = before.sessions.first(where: { $0.id == id }), let new = after.sessions.first(where: { $0.id == id }), old.correctedDuration != new.correctedDuration else { return nil }
            return .correction(id, before: old.correctedDuration, after: new.correctedDuration)
        case .note(let id, _):
            guard let old = before.sessions.first(where: { $0.id == id }), let new = after.sessions.first(where: { $0.id == id }), old.note != new.note else { return nil }
            return .note(id, before: old.note, after: new.note)
        case .editRecord(let id, _, _):
            guard let old = before.sessions.first(where: { $0.id == id }), let new = after.sessions.first(where: { $0.id == id }),
                  old.correctedDuration != new.correctedDuration || old.note != new.note else { return nil }
            return .recordEdit(id, beforeDuration: old.correctedDuration, beforeNote: old.note,
                               afterDuration: new.correctedDuration, afterNote: new.note)
        case .undo(let token): return token.inverse
        default: return nil
        }
    }

    func apply(to document: inout ActivityTimerDocument, at date: Date,
               expectedSessionID: UUID?, expectedPauseState: Bool?) throws {
        switch self {
        case .add(let name): try document.addActivity(name: name)
        case .rename(let id, let name): try document.renameActivity(id: id, name: name)
        case .archive(let id, let archived): try document.setActivityArchived(id: id, archived: archived)
        case .note(let id, let note): try document.setSessionNote(sessionID: id, note: note)
        case .delete(let id): try document.deleteActivity(id: id)
        case .start(let id, let mode, let duration): try document.start(activityID: id, mode: mode, duration: duration, at: date)
        case .switchActivity(let id, let mode, let duration):
            try document.switchActivity(to: id, mode: mode, duration: duration, at: date, expectedSessionID: expectedSessionID)
        case .togglePause:
            guard expectedSessionID != nil, document.activeSession?.id == expectedSessionID,
                  document.activeSession?.isPaused == expectedPauseState else {
                throw ActivityTimerError.invalid(L("计时状态已更新，请重试。"))
            }
            document.togglePause(at: date)
        case .finish, .extend:
            guard expectedSessionID != nil, document.displayedSession?.id == expectedSessionID else {
                throw ActivityTimerError.invalid(L("计时状态已更新，请重试。"))
            }
            if case .finish = self { document.finish(at: date) } else { try document.extendCountdown(at: date) }
        case .correct(let id, let duration): try document.correctDuration(sessionID: id, duration: duration)
        case .addRecord(let id, let start, let duration): try document.addRecord(activityID: id, startedAt: start, duration: duration, at: date)
        case .editRecord(let id, let duration, let note): try document.editRecord(sessionID: id, duration: duration, note: note)
        case .addNotedRecord(let id, let start, let duration, let note):
            try document.addNotedRecord(activityID: id, startedAt: start, duration: duration, note: note, at: date)
        case .undo(let token): try token.apply(to: &document)
        }
    }
}

struct ActivitySleepBoundary: Codable, Equatable {
    var id = UUID()
    var sessionID: UUID?
    var runningSince: Date?
    var date: Date

    func apply(to document: inout ActivityTimerDocument) {
        guard let session = document.activeSession, let running = session.runningSince else { return }
        if let sessionID, sessionID != session.id {
            // Explicit resumes are a new stretch and must never be paused by
            // a stale predecessor journal. A queued switch's first stretch is
            // eligible, including when it was persisted before the journal.
            guard running == session.startedAt, running <= date else { return }
            var source = session.switchedFromSessionID
            var visited = Set<UUID>()
            while let id = source, visited.insert(id).inserted {
                if id == sessionID { document.pauseForSleep(at: date); return }
                source = document.sessions.first(where: { $0.id == id })?.switchedFromSessionID
            }
            return
        }
        guard runningSince.map({ $0 == running }) ?? (running <= date) else { return }
        document.pauseForSleep(at: date)
    }
}

struct ActivitySelectionState {
    var activityID: UUID?
    var editingActivityID: UUID?
    var editedName = ""
    var editingOrder: [UUID] = []
    var selectedForTotal: Set<UUID> = []
    var knownActivityIDs: Set<UUID> = []
    var editingSession: ActivityTimerSession?
    var pendingDeletion: TimedActivity?

    mutating func synchronize(with document: ActivityTimerDocument) {
        let ids = Set(document.activities.map(\.id))
        selectedForTotal.formIntersection(ids)
        selectedForTotal.formUnion(ids.subtracting(knownActivityIDs))
        knownActivityIDs = ids
        if let activityID, !ids.contains(activityID) { self.activityID = nil }
        if let editingActivityID, !ids.contains(editingActivityID) { cancelEditing() }
        if let editingSession, !document.sessions.contains(where: { $0.id == editingSession.id }) { self.editingSession = nil }
        if let pendingDeletion { self.pendingDeletion = document.activities.first { $0.id == pendingDeletion.id } }
    }

    mutating func beginEditing(_ activity: TimedActivity, order: [UUID]) {
        editingActivityID = activity.id
        editedName = activity.name
        editingOrder = order
    }

    mutating func cancelEditing() {
        editingActivityID = nil
        editedName = ""
        editingOrder = []
    }
}

struct ActivityStatisticsSnapshot {
    var activities: [TimedActivity]
    var allTimeTotals: [UUID: TimeInterval]
    var dailyPoints: [ActivityDailyDuration]
    var completedSessions: [ActivityTimerSession]

    func dailyDurations(days: Int) -> [ActivityDailyDuration] {
        guard days > 0 else { return [] }
        return Array(dailyPoints.suffix(min(days, 31) * activities.count))
    }

    func summaries(days: Int, order: ActivityDurationSortOrder) -> [ActivityDurationSummary] {
        var totals = allTimeTotals
        if days > 0 {
            totals = [:]
            for point in dailyDurations(days: days) { totals[point.activityID, default: 0] += point.duration }
        }
        return activities.enumerated().map { index, activity in
            (index, ActivityDurationSummary(activity: activity, duration: totals[activity.id, default: 0]))
        }.sorted { left, right in
            if left.1.duration == right.1.duration { return left.0 < right.0 }
            return order == .ascending ? left.1.duration < right.1.duration : left.1.duration > right.1.duration
        }.map(\.1)
    }
}

/// Index saved stretches once. Clock ticks add only the current running stretch.
private struct ActivityStatisticsIndex {
    var base: ActivityStatisticsSnapshot
    let calendar: Calendar
    let days: [Date]
    let dayIndices: [Date: Int]
    var activityIndices: [UUID: Int]
    let liveSession: ActivityTimerSession?
    let latestSavedEnd: Date?

    init(document: ActivityTimerDocument, at date: Date, calendar: Calendar, days count: Int = 31,
         includeRecords: Bool = true) {
        self.calendar = calendar
        let today = calendar.startOfDay(for: date)
        days = (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        dayIndices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })
        activityIndices = Dictionary(uniqueKeysWithValues: document.activities.enumerated().map { ($0.element.id, $0.offset) })
        liveSession = document.activeSession
        latestSavedEnd = document.sessions.compactMap { $0.segments.last?.end }.max()
        base = ActivityStatisticsSnapshot(activities: document.activities, allTimeTotals: [:],
                                          dailyPoints: days.flatMap { day in
                                              document.activities.map { ActivityDailyDuration(day: day, activityID: $0.id, duration: 0) }
                                          }, completedSessions: includeRecords
                                          ? document.sessions.filter { $0.endedAt != nil }.sorted { $0.startedAt > $1.startedAt } : [])
        var points = base.dailyPoints
        for session in document.sessions {
            base.allTimeTotals[session.activityID, default: 0] += session.savedDuration
            session.forEachSavedSegment { add($0, activityID: session.activityID, at: date, to: &points) }
        }
        base.dailyPoints = points
    }

    func snapshot(at date: Date) -> ActivityStatisticsSnapshot {
        guard let session = liveSession, let stretch = session.liveSegment(at: date), stretch.duration > 0 else { return base }
        var value = base
        value.allTimeTotals[session.activityID, default: 0] += stretch.duration
        add(stretch, activityID: session.activityID, at: date, to: &value.dailyPoints)
        return value
    }

    mutating func updateActivities(_ activities: [TimedActivity]) {
        let previous = Dictionary(grouping: base.dailyPoints, by: \.day).mapValues { points in
            Dictionary(uniqueKeysWithValues: points.map { ($0.activityID, $0.duration) })
        }
        activityIndices = Dictionary(uniqueKeysWithValues: activities.enumerated().map { ($0.element.id, $0.offset) })
        base.activities = activities
        base.allTimeTotals = base.allTimeTotals.filter { activityIndices[$0.key] != nil }
        base.dailyPoints = days.flatMap { day in
            activities.map { ActivityDailyDuration(day: day, activityID: $0.id, duration: previous[day]?[$0.id] ?? 0) }
        }
    }

    private func add(_ segment: ActivityTimeSegment, activityID: UUID, at date: Date,
                     to points: inout [ActivityDailyDuration]) {
        guard let first = days.first, let activity = activityIndices[activityID] else { return }
        var cursor = max(first, segment.start)
        let end = min(date, segment.end)
        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            guard let index = dayIndices[day], let next = calendar.date(byAdding: .day, value: 1, to: day), next > cursor else { break }
            let boundary = min(next, end)
            points[index * activityIndices.count + activity].duration += boundary.timeIntervalSince(cursor)
            cursor = boundary
        }
    }
}

final class ActivityStatisticsCache {
    private var index: ActivityStatisticsIndex?
    private var revision: Int?
    private var indexedDay: Date?
    private var indexedAt: Date?
    private var indexedCalendar: Calendar?
    private var indexedSessions: [ActivityTimerSession]?
    private(set) var buildCount = 0
    private(set) var metadataUpdateCount = 0

    func value(document: ActivityTimerDocument, revision: Int, at date: Date,
               calendar: Calendar = .current, liveAt: Date? = nil) -> ActivityStatisticsSnapshot {
        let day = calendar.startOfDay(for: date)
        // A clock rollback can temporarily put saved records in the future. Reclip those until time catches up.
        let needsReclip = index?.latestSavedEnd.map { $0 > min(date, indexedAt ?? date) } == true && indexedAt != date
        let boundaryChanged = indexedDay != day || indexedCalendar != calendar || needsReclip
        if self.revision != revision, !boundaryChanged, indexedSessions == document.sessions, index != nil {
            index!.updateActivities(document.activities)
            self.revision = revision
            metadataUpdateCount += 1
        } else if self.revision != revision || boundaryChanged {
            index = ActivityStatisticsIndex(document: document, at: date, calendar: calendar)
            indexedSessions = document.sessions
            self.revision = revision
            indexedDay = day
            indexedCalendar = calendar
            indexedAt = date
            buildCount += 1
        }
        return index!.snapshot(at: liveAt ?? date)
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
        return L("%@ 小时 %@ 分 %@ 秒", "\(seconds / 3600)", "\(seconds % 3600 / 60)", "\(seconds % 60)")
    }
}


struct ActivityChartRegion: Identifiable, Equatable {
    var segment: ActivityDailyChartSegment
    var activity: TimedActivity
    var frame: CGRect
    var id: String { segment.id }
    var detail: String {
        activity.chartLabel + " " + activity.name + "\n"
            + segment.point.day.formatted(date: .abbreviated, time: .omitted) + "\n"
            + ActivityDurationFormat.summary(segment.point.duration)
    }

    static func hitTest(_ point: CGPoint, regions: [Self], plot: CGRect) -> Self? {
        guard plot.contains(point) else { return nil }
        // An exact block always wins, even next to a very thin neighboring record.
        if let exact = regions.first(where: { $0.frame.contains(point) }) { return exact }
        return regions.filter { $0.frame.insetBy(dx: -3, dy: $0.frame.height < 4 ? -2 : 0).contains(point) }
            .min { left, right in
                func distance(_ rect: CGRect) -> CGFloat {
                    hypot(max(0, max(rect.minX - point.x, point.x - rect.maxX)),
                          max(0, max(rect.minY - point.y, point.y - rect.maxY)))
                }
                return distance(left.frame) < distance(right.frame)
            }
    }
}

/// Spatial lookup is bounded to nearby date columns and vertical segments.
struct ActivityChartHitIndex {
    private struct Entry { var region: ActivityChartRegion; var order: Int }
    private struct Column { var left: CGFloat; var entries: [Entry] }
    private var columns: [Column]
    private var plot: CGRect

    init(regions: [ActivityChartRegion] = [], plot: CGRect = .zero) {
        self.plot = plot
        let entries = regions.enumerated().map { Entry(region: $0.element, order: $0.offset) }
        columns = Dictionary(grouping: entries, by: { $0.region.segment.point.day }).values.map { entries in
            Column(left: entries.map { $0.region.frame.minX }.min() ?? 0,
                   entries: entries.sorted { $0.region.frame.minY < $1.region.frame.minY })
        }.sorted { $0.left < $1.left }
    }

    func hitTest(_ point: CGPoint) -> ActivityChartRegion? {
        guard plot.contains(point), !columns.isEmpty else { return nil }
        var low = 0, high = columns.count
        while low < high {
            let middle = (low + high) / 2
            if columns[middle].left <= point.x { low = middle + 1 } else { high = middle }
        }
        var candidates: [Entry] = []
        for columnIndex in max(0, low - 2)..<min(columns.count, low + 1) {
            let entries = columns[columnIndex].entries
            var lower = 0, upper = entries.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if entries[middle].region.frame.minY <= point.y { lower = middle + 1 } else { upper = middle }
            }
            candidates.append(contentsOf: entries[max(0, lower - 2)..<min(entries.count, lower + 1)])
        }
        if let exact = candidates.filter({ $0.region.frame.contains(point) }).min(by: { $0.order < $1.order }) { return exact.region }
        func distance(_ entry: Entry) -> CGFloat {
            let rect = entry.region.frame
            return hypot(max(0, max(rect.minX - point.x, point.x - rect.maxX)),
                         max(0, max(rect.minY - point.y, point.y - rect.maxY)))
        }
        return candidates.filter {
            $0.region.frame.insetBy(dx: -3, dy: $0.region.frame.height < 4 ? -2 : 0).contains(point)
        }.min { left, right in
            let a = distance(left), b = distance(right)
            return a == b ? left.order < right.order : a < b
        }?.region
    }
}


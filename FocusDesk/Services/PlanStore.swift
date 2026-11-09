import AppKit
import Combine
import Foundation
import ServiceManagement

enum ActivityWorkspaceSection: Int, Codable, CaseIterable, Identifiable {
    case timer = 0, statistics = 1, records = 2
    var id: Int { rawValue }
    var title: String {
        switch self { case .timer: return L("计时"); case .statistics: return L("学习统计"); case .records: return L("学习记录") }
    }
}

struct ActivityTimerPreference: Codable, Equatable {
    private var modeValue = ActivityTimerMode.stopwatch.rawValue
    var duration: TimeInterval? = 1500
    var mode: ActivityTimerMode {
        get { ActivityTimerMode(rawValue: modeValue) ?? .stopwatch }
        set { modeValue = newValue.rawValue }
    }
    init(mode: ActivityTimerMode = .stopwatch, duration: TimeInterval? = 1500) {
        modeValue = mode.rawValue
        self.duration = duration
    }
    private enum CodingKeys: String, CodingKey { case modeValue, duration }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modeValue = try values.decodeIfPresent(String.self, forKey: .modeValue) ?? ActivityTimerMode.stopwatch.rawValue
        let savedDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 1500
        duration = savedDuration.isFinite && (1...604800).contains(savedDuration) ? savedDuration : 1500
    }
}

struct ActivityExperiencePreferences: Codable, Equatable {
    var section = ActivityWorkspaceSection.timer
    var range = 7
    private var sortValue = ActivityDurationSortOrder.descending.rawValue
    var selectedActivityIDs: Set<UUID>?
    var knownActivityIDs: Set<UUID> = []
    var recentActivityIDs: [UUID] = []
    var timerPreferences: [String: ActivityTimerPreference] = [:]
    var sortOrder: ActivityDurationSortOrder {
        get { ActivityDurationSortOrder(rawValue: sortValue) ?? .descending }
        set { sortValue = newValue.rawValue }
    }
    init() {}
    private enum CodingKeys: String, CodingKey {
        case section, range, sortValue, selectedActivityIDs, knownActivityIDs, recentActivityIDs, timerPreferences
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sectionValue = try values.decodeIfPresent(Int.self, forKey: .section) ?? 0
        section = ActivityWorkspaceSection(rawValue: sectionValue) ?? .timer
        let savedRange = try values.decodeIfPresent(Int.self, forKey: .range) ?? 7
        range = [0, 1, 7, 30].contains(savedRange) ? savedRange : 7
        sortValue = try values.decodeIfPresent(String.self, forKey: .sortValue) ?? ActivityDurationSortOrder.descending.rawValue
        selectedActivityIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .selectedActivityIDs)
        knownActivityIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .knownActivityIDs) ?? []
        recentActivityIDs = try values.decodeIfPresent([UUID].self, forKey: .recentActivityIDs) ?? []
        timerPreferences = try values.decodeIfPresent([String: ActivityTimerPreference].self, forKey: .timerPreferences) ?? [:]
    }
}

@MainActor
final class FocusClock: ObservableObject {
    @Published private(set) var now: Date
    init(now: Date) { self.now = now }
    func update(_ date: Date) { if date != now { now = date } }
}

@MainActor
final class PlanStore: ObservableObject {
    static let defaultCompactSize = 56.0
    static let compactSizeRange = 32.0...112.0

    @Published private(set) var tasks: [PlanTask]
    private(set) var snapshot: ScheduleSnapshot {
        willSet {
            if snapshot.current != newValue.current || snapshot.next != newValue.next
                || snapshot.intervalStart != newValue.intervalStart || snapshot.intervalEnd != newValue.intervalEnd {
                objectWillChange.send()
            }
        }
    }
    private(set) var now: Date { didSet { clock.update(now) } }
    let clock: FocusClock
    @Published private(set) var motivationalQuote: MotivationalQuote
    @Published private(set) var errorMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginStatus = L("未开启")
    @Published private(set) var isFloatingVisible = true
    @Published private(set) var isExpanded = false
    @Published private(set) var todayProgress: DailyProgress
    @Published private(set) var history: [DailyProgress]
    @Published private(set) var needsDataRecovery = false
    @Published private(set) var activityTimers: ActivityTimerDocument {
        didSet {
            activityStatisticsRevision &+= 1
            reconcileActivityExperience()
        }
    }
    private var activityStatisticsRevision = 0
    private var activityStatisticsCache = ActivityStatisticsCache()
    @Published private(set) var activityTimerError: String?
    @Published private(set) var activityDataReady = true
    @Published private(set) var activitySaveInProgress = false
    var activityIsBusy: Bool { !activityDataReady || activitySaveInProgress }
    var activityRevision: Int { activityStatisticsRevision }
    var activityDisplayNow: Date { activityFreezeAt.map { min(now, $0) } ?? now }
    var activityReadInProgress: Bool { activityRefreshTask != nil || activityLoadTask != nil }
    @Published private(set) var countdownCompletionEventID: UUID?
    @Published var activityExperience = ActivityExperiencePreferences() {
        didSet {
            if let data = try? JSONEncoder().encode(activityExperience) {
                defaults.set(data, forKey: "activity.experience.v1")
            }
        }
    }
    @Published private var activityUndoHistory: [ActivityTimerUndo] = []
    @Published private var activityRedoHistory: [ActivityTimerUndo] = []
    var activityUndoTitle: String? { activityUndoHistory.last.map { L("撤销%@", $0.title) } }
    var activityRedoTitle: String? { activityRedoHistory.last.map { L("重做%@", $0.title) } }
    var recentActivities: [TimedActivity] {
        let active = Dictionary(uniqueKeysWithValues: activityTimers.activities.filter { !$0.isArchived }.map { ($0.id, $0) })
        return Array(activityExperience.recentActivityIDs.compactMap { active[$0] }.prefix(3))
    }

    func timerPreference(for activityID: UUID) -> ActivityTimerPreference {
        activityExperience.timerPreferences[activityID.uuidString] ?? ActivityTimerPreference()
    }

    func rememberActivitySelection(_ ids: Set<UUID>) {
        let valid = ids.intersection(activityTimers.activities.map(\.id))
        if activityExperience.selectedActivityIDs != valid { activityExperience.selectedActivityIDs = valid }
    }
    func rememberActivityRange(_ range: Int) {
        guard [0, 1, 7, 30].contains(range), activityExperience.range != range else { return }
        activityExperience.range = range
    }
    func rememberActivitySort(_ order: ActivityDurationSortOrder) {
        if activityExperience.sortOrder != order { activityExperience.sortOrder = order }
    }
    func rememberActivitySection(_ section: ActivityWorkspaceSection) {
        if activityExperience.section != section { activityExperience.section = section }
    }

    private func reconcileActivityExperience() {
        let ids = Set(activityTimers.activities.map(\.id))
        var experience = activityExperience
        if let selection = experience.selectedActivityIDs {
            let previous = experience.knownActivityIDs.isEmpty ? ids : experience.knownActivityIDs
            experience.selectedActivityIDs = selection.intersection(ids).union(ids.subtracting(previous))
        }
        experience.knownActivityIDs = ids
        let available = Set(activityTimers.activities.filter { !$0.isArchived }.map(\.id))
        var recent = Set<UUID>()
        experience.recentActivityIDs = experience.recentActivityIDs.filter { available.contains($0) && recent.insert($0).inserted }
        experience.timerPreferences = experience.timerPreferences.filter { key, _ in UUID(uuidString: key).map(ids.contains) ?? false }
        if experience.recentActivityIDs.isEmpty, !activityTimers.sessions.isEmpty {
            // One linear pass restores useful defaults for existing users without
            // sorting their entire record history on the main thread.
            var latest: [UUID: ActivityTimerSession] = [:]
            for session in activityTimers.sessions where ids.contains(session.activityID) {
                if latest[session.activityID].map({ $0.startedAt < session.startedAt }) ?? true { latest[session.activityID] = session }
            }
            experience.recentActivityIDs = latest.values.filter { available.contains($0.activityID) }
                .sorted { $0.startedAt > $1.startedAt }.prefix(3).map(\.activityID)
            for (id, session) in latest where experience.timerPreferences[id.uuidString] == nil {
                experience.timerPreferences[id.uuidString] = ActivityTimerPreference(mode: session.mode, duration: session.targetDuration ?? 1500)
            }
        }
        if activityExperience != experience { activityExperience = experience }
    }

    private func rememberSuccessfulActivityAction(_ action: ActivityTimerAction) {
        let id: UUID, mode: ActivityTimerMode, duration: TimeInterval?
        switch action {
        case .start(let activityID, let timerMode, let target), .switchActivity(let activityID, let timerMode, let target):
            id = activityID; mode = timerMode; duration = target
        default: return
        }
        var experience = activityExperience
        experience.timerPreferences[id.uuidString] = ActivityTimerPreference(mode: mode, duration: duration ?? experience.timerPreferences[id.uuidString]?.duration ?? 1500)
        experience.recentActivityIDs.removeAll { $0 == id }
        experience.recentActivityIDs.insert(id, at: 0)
        experience.recentActivityIDs = Array(experience.recentActivityIDs.prefix(3))
        if experience != activityExperience { activityExperience = experience }
    }

    var timerNotice: String? {
        guard let session = activityTimers.pendingCountdown else { return nil }
        let name = activityTimers.activities.first { $0.id == session.activityID }?.name ?? L("事项")
        return L("%@已到时 · 可继续专注", "\(name)")
    }

    @Published var compactSize: Double {
        didSet {
            let side = Self.clampedCompactSize(compactSize)
            if compactSize != side { compactSize = side }
            defaults.set(side, forKey: "compactSize")
        }
    }

    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }

    @Published var language: AppLanguage = .chinese {
        didSet {
            AppLanguage.current = language
            defaults.set(language.rawValue, forKey: "appearance.language")
            motivationalQuote = quoteRotation.quote(at: now)
        }
    }

    @Published var theme: DeskTheme = .classic {
        didSet { defaults.set(theme.rawValue, forKey: "appearance.theme") }
    }
    @Published var countdownEffect: CountdownEffect = .soft {
        didSet { defaults.set(countdownEffect.rawValue, forKey: "appearance.effect") }
    }
    @Published var effectIntensity: EffectIntensity = .standard {
        didSet {
            defaults.set(effectIntensity.rawValue, forKey: "appearance.intensity")
            effectConfiguration = effectIntensity.configuration
        }
    }
    @Published var effectsEnabled = true {
        didSet { defaults.set(effectsEnabled, forKey: "appearance.effectsEnabled") }
    }
    @Published var effectConfiguration = EffectConfiguration() {
        didSet { if let data = try? JSONEncoder().encode(effectConfiguration.normalized) { defaults.set(data, forKey: "appearance.screenEffect") } }
    }
    var onStopEffect: (() -> Void)?
    var onPreviewEffect: (() -> Void)?

    var onShowPlan: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onShowTimers: (() -> Void)?
    var onShowQuoteDetails: ((MotivationalQuote) -> Void)?
    var onToggleFloating: (() -> Void)?

    let defaults: UserDefaults
    let storageURL: URL
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let allowsLoginItemChanges: Bool
    private let progressStore: ProgressStore
    private let activityTimerStore: ActivityTimerStore
    private let activityIO: ActivityTimerIO
    private let useBackgroundActivityIO: Bool
    private var activityMutationVersion = 0
    private var activityFreezeAt: Date?
    private var activityRefreshTask: Task<Void, Never>?
    private var activityRefreshID: UUID?
    private var lastActivityClockPoll: TimeInterval = -.infinity
    private var activityLoadTask: Task<Void, Never>?
    private var stopped = false
    private let quoteRotation: QuoteRotation
    private let nowProvider: () -> Date
    private let calendarProvider: () -> Calendar
    private var pendingSleepPause: ActivitySleepBoundary?

    init(
        storageDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        allowsLoginItemChanges: Bool = true,
        nowProvider: @escaping () -> Date = { Date() },
        calendarProvider: @escaping () -> Calendar = { .current },
        startClock: Bool = true,
        useBackgroundActivityIO: Bool? = nil
    ) {
        let date = nowProvider()
        self.clock = FocusClock(now: date)
        let backgroundIO = useBackgroundActivityIO ?? startClock
        self.useBackgroundActivityIO = backgroundIO
        let calendar = DailyProgress.localCalendar(calendarProvider())
        let initialLanguage = AppLanguage(rawValue: defaults.object(forKey: "appearance.language") as? String ?? "") ?? AppLanguage.packagedDefault
        AppLanguage.current = initialLanguage
        self.language = initialLanguage
        let initialTasks = DefaultPlan.tasks.sorted { $0.startMinutes < $1.startMinutes }
        self.defaults = defaults
        if let data = defaults.object(forKey: "activity.experience.v1") as? Data,
           var experience = try? JSONDecoder().decode(ActivityExperiencePreferences.self, from: data) {
            if ![0, 1, 7, 30].contains(experience.range) { experience.range = 7 }
            experience.timerPreferences = experience.timerPreferences.filter { _, preference in
                preference.duration.map { $0.isFinite && (1...604_800).contains($0) } ?? true
            }
            activityExperience = experience
        }
        theme = DeskTheme(rawValue: defaults.object(forKey: "appearance.theme") as? String ?? "") ?? .classic
        countdownEffect = CountdownEffect(rawValue: defaults.object(forKey: "appearance.effect") as? String ?? "") ?? .soft
        let initialIntensity = EffectIntensity(rawValue: defaults.object(forKey: "appearance.intensity") as? String ?? "") ?? .standard
        effectIntensity = initialIntensity
        effectConfiguration = (defaults.object(forKey: "appearance.screenEffect") as? Data)
            .flatMap { try? JSONDecoder().decode(EffectConfiguration.self, from: $0) }?.normalized ?? initialIntensity.configuration
        effectsEnabled = defaults.object(forKey: "appearance.effectsEnabled") as? Bool ?? true
        self.allowsLoginItemChanges = allowsLoginItemChanges
        self.nowProvider = nowProvider
        self.calendarProvider = calendarProvider
        let quoteRotation = QuoteRotation(defaults: defaults)
        self.quoteRotation = quoteRotation
        motivationalQuote = quoteRotation.quote(at: date)
        let directory = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("FocusDesk", isDirectory: true)
        storageURL = directory.appendingPathComponent("plan.json")
        progressStore = ProgressStore(storageURL: storageURL)
        let activityTimerStore = ActivityTimerStore(storageURL: directory.appendingPathComponent("timers.json"))
        self.activityTimerStore = activityTimerStore
        activityIO = ActivityTimerIO(storageURL: activityTimerStore.storageURL)
        activityTimers = backgroundIO ? ActivityTimerDocument() : activityTimerStore.load()
        activityDataReady = !backgroundIO
        activityTimerError = activityTimerStore.blockedSaveReason
        tasks = initialTasks
        now = date
        snapshot = ScheduleEngine.snapshot(tasks: initialTasks, at: date, calendar: calendar)
        todayProgress = DailyProgress(tasks: initialTasks, at: date, calendar: calendar)
        history = []
        alwaysOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
        compactSize = Self.clampedCompactSize(
            defaults.object(forKey: "compactSize") as? Double ?? Self.defaultCompactSize
        )
        let loaded = progressStore.load(defaultTasks: initialTasks)
        tasks = loaded.document.tasks.sorted { $0.startMinutes < $1.startMinutes }
        history = loaded.document.history.sorted { $0.day > $1.day }
        errorMessage = loaded.notice
        needsDataRecovery = progressStore.blockedSaveReason != nil
        snapshot = ScheduleEngine.snapshot(tasks: tasks, at: date, calendar: calendar)
        let initialProgress = progress(for: tasks, at: date, calendar: calendar)
        todayProgress = initialProgress
        // Also migrates old task-array files in one atomic write, without inventing past days.
        if !needsDataRecovery {
            do {
                let updatedHistory = replacingDay(initialProgress)
                try progressStore.save(ProgressDocument(tasks: tasks, history: updatedHistory))
                history = updatedHistory
            } catch {
                errorMessage = saveFailure(error)
            }
        }
        if backgroundIO {
            activityLoadTask = Task { [weak self] in
                guard let self else { return }
                var result = await self.activityIO.load(at: self.nowProvider())
                guard !self.stopped else { return }
                // Sleep may arrive while the initial read is in flight.
                // Never replace the visible pause with that earlier snapshot.
                self.applyPendingSleepPause(to: &result.document)
                self.publishActivityResult(result)
                self.activityDataReady = true
                self.activityLoadTask = nil
                if self.pendingSleepPause != nil { self.scheduleActivityRefresh(at: self.nowProvider()) }
            }
        } else {
            refreshActivityTimer(at: date)
        }
        if !backgroundIO { reconcileActivityExperience() }
        refreshLoginStatus()
        if startClock { beginClock() }
    }

    /// Updates from the wall clock, including after a wake or manual clock change.
    func refresh() {
        refresh(clockTick: false)
    }

    private func refresh(clockTick: Bool) {
        now = nowProvider()
        if useBackgroundActivityIO {
            let uptime = ProcessInfo.processInfo.systemUptime
            let running = activityTimers.activeSession?.runningSince != nil
            if !clockTick || running || pendingSleepPause != nil || uptime - lastActivityClockPoll >= 5 {
                if activityRefreshTask == nil && !activityIsBusy { lastActivityClockPoll = uptime }
                scheduleActivityRefresh(at: now)
            }
        } else { refreshActivityTimer(at: now) }
        let quote = quoteRotation.quote(at: now)
        if motivationalQuote != quote { motivationalQuote = quote }
        let calendar = DailyProgress.localCalendar(calendarProvider())
        snapshot = ScheduleEngine.snapshot(tasks: tasks, at: now, calendar: calendar)
        let current = progress(for: tasks, at: now, calendar: calendar)
        let persisted = history.first { $0.day == current.day }
        guard current != todayProgress || persisted != current else { return }
        // A failed rollover still displays the correct new local day with no auto-completions.
        if todayProgress != current { todayProgress = current }
        guard !needsDataRecovery else { return }
        do {
            let updatedHistory = replacingDay(current)
            try progressStore.save(ProgressDocument(tasks: tasks, history: updatedHistory))
            history = updatedHistory
            errorMessage = nil
        } catch {
            errorMessage = saveFailure(error)
        }
    }

    @discardableResult
    func addTimedActivity(name: String) -> String? {
        updateActivityTimers { try $0.addActivity(name: name) }
    }

    func activityStatistics(calendar: Calendar = .current) -> ActivityStatisticsSnapshot {
        activityStatisticsCache.value(document: activityTimers, revision: activityStatisticsRevision, at: now,
                                      calendar: calendar, liveAt: activityDisplayNow)
    }

    @discardableResult
    func renameTimedActivity(id: UUID, name: String) -> String? {
        updateActivityTimers { try $0.renameActivity(id: id, name: name) }
    }

    @discardableResult
    func deleteTimedActivity(id: UUID) -> String? {
        updateActivityTimers { try $0.deleteActivity(id: id) }
    }

    @discardableResult
    func startActivityTimer(activityID: UUID, mode: ActivityTimerMode, duration: TimeInterval?) -> String? {
        let date = nowProvider()
        return updateActivityTimers { try $0.start(activityID: activityID, mode: mode, duration: duration, at: date) }
    }

    @discardableResult
    func toggleActivityTimerPause() -> String? {
        let date = nowProvider()
        let sessionID = activityTimers.activeSession?.id
        let wasPaused = activityTimers.activeSession?.isPaused
        return updateActivityTimers {
            guard $0.activeSession?.id == sessionID, $0.activeSession?.isPaused == wasPaused else { return }
            $0.togglePause(at: date)
        }
    }

    @discardableResult
    func finishActivityTimer() -> String? {
        let date = nowProvider()
        let sessionID = activityTimers.displayedSession?.id
        return updateActivityTimers {
            guard $0.displayedSession?.id == sessionID else { return }
            $0.finish(at: date)
        }
    }

    @discardableResult
    func extendActivityCountdown() -> String? {
        let date = nowProvider()
        let sessionID = activityTimers.displayedSession?.id
        return updateActivityTimers {
            guard $0.displayedSession?.id == sessionID else { return }
            try $0.extendCountdown(at: date)
        }
    }

    @discardableResult
    func correctActivityDuration(sessionID: UUID, duration: TimeInterval) -> String? {
        updateActivityTimers { try $0.correctDuration(sessionID: sessionID, duration: duration) }
    }

    @discardableResult
    func addActivityRecord(activityID: UUID, startedAt: Date, duration: TimeInterval) -> String? {
        let date = nowProvider()
        return updateActivityTimers { try $0.addRecord(activityID: activityID, startedAt: startedAt, duration: duration, at: date) }
    }

    func pauseActivityTimerForSleep() {
        let date = nowProvider()
        if let session = activityTimers.activeSession, let runningSince = session.runningSince, pendingSleepPause == nil {
            pendingSleepPause = ActivitySleepBoundary(sessionID: session.id, runningSince: runningSince, date: date)
        }
        now = date
        if useBackgroundActivityIO {
            activityMutationVersion &+= 1
            if pendingSleepPause == nil { pendingSleepPause = ActivitySleepBoundary(date: date) }
            if let boundary = pendingSleepPause {
                do { try activityTimerStore.recordSleepBoundary(boundary) }
                catch { activityTimerError = L("睡眠暂停记录暂未保存，将自动重试：%@", error.localizedDescription) }
            }
            cancelActivityRefresh()
            scheduleActivityRefresh(at: date)
        } else {
            refreshActivityTimer(at: date)
        }
        if pendingSleepPause != nil {
            // A disk failure must not leave the visible timer running. Keep the
            // boundary for retry while immediately excluding sleep in memory.
            var paused = activityTimers
            applyPendingSleepPause(to: &paused)
            if paused != activityTimers { activityTimers = paused }
        }
    }

    private func applyPendingSleepPause(to document: inout ActivityTimerDocument) {
        pendingSleepPause?.apply(to: &document)
    }

    private func updateActivityTimers(_ change: (inout ActivityTimerDocument) throws -> Void) -> String? {
        activityMutationVersion &+= 1
        do {
            let candidate = try activityTimerStore.update {
                applyPendingSleepPause(to: &$0)
                try change(&$0)
            }
            let newlyCompletedID = candidate.pendingCountdownSessionID != activityTimers.pendingCountdownSessionID
                ? candidate.pendingCountdownSessionID : nil
            if activityTimers != candidate { activityTimers = candidate }
            pendingSleepPause = nil
            if activityTimerError != nil { activityTimerError = nil }
            if let newlyCompletedID { countdownCompletionEventID = newlyCompletedID }
            now = nowProvider()
            return nil
        } catch {
            let message = L("事项计时未保存：%@", "\(error.localizedDescription)")
            activityTimerError = message
            return message
        }
    }

    private func refreshActivityTimer(at date: Date) {
        do {
            var completed = false
            let candidate = try activityTimerStore.update {
                applyPendingSleepPause(to: &$0)
                completed = $0.completeCountdown(at: date)
            }
            if activityTimers != candidate { activityTimers = candidate }
            pendingSleepPause = nil
            if activityTimerError != nil { activityTimerError = nil }
            // Views react once to this event; loading a saved reminder does not replay it.
            if completed { countdownCompletionEventID = candidate.pendingCountdownSessionID }
        } catch {
            activityTimerError = L("计时记录同步失败，将自动重试：%@", "\(error.localizedDescription)")
        }
    }

    private enum ActivityHistoryOperation { case normal, undo, redo }

    func performActivityAction(_ action: ActivityTimerAction) async -> String? {
        await executeActivityAction(action, historyOperation: .normal)
    }

    func undoActivityChange() async -> String? {
        guard let change = activityUndoHistory.last else { return nil }
        return await executeActivityAction(.undo(change), historyOperation: .undo)
    }

    func redoActivityChange() async -> String? {
        guard let change = activityRedoHistory.last else { return nil }
        return await executeActivityAction(.undo(change), historyOperation: .redo)
    }

    private func executeActivityAction(_ action: ActivityTimerAction, historyOperation: ActivityHistoryOperation) async -> String? {
        guard !activityIsBusy else { return L("正在保存记录，请稍候。") }
        let requestedAt = nowProvider()
        let expectedSession = activityTimers.displayedSession?.id
        let expectedPause = activityTimers.activeSession?.isPaused
        if (isPauseAction(action) && expectedPause == false) || isFinishAction(action) || isSwitchAction(action) {
            activityFreezeAt = requestedAt
        }
        activitySaveInProgress = true
        cancelActivityRefresh()
        activityMutationVersion &+= 1
        let version = activityMutationVersion
        let sleepBoundary = pendingSleepPause
        defer { activityFreezeAt = nil; activitySaveInProgress = false }
        do {
            let result = try await activityIO.apply(action, at: requestedAt, expectedSessionID: expectedSession,
                                                    expectedPauseState: expectedPause, sleepBoundary: sleepBoundary)
            switch historyOperation {
            case .normal:
                if let undo = result.undo { activityUndoHistory.append(undo) }
                activityRedoHistory.removeAll()
            case .undo:
                _ = activityUndoHistory.popLast()
                if let redo = result.undo { activityRedoHistory.append(redo) }
            case .redo:
                _ = activityRedoHistory.popLast()
                if let undo = result.undo { activityUndoHistory.append(undo) }
            }
            if version == activityMutationVersion {
                publishActivityResult(result)
                if pendingSleepPause == sleepBoundary { pendingSleepPause = nil }
            } else {
                scheduleActivityRefresh(at: nowProvider(), afterSave: true)
            }
            rememberSuccessfulActivityAction(action)
            now = nowProvider()
            return nil
        } catch {
            // A field conflict invalidates this inverse, while a temporary I/O
            // failure leaves it available for retry. Never roll back a document.
            if error is ActivityTimerError {
                switch historyOperation {
                case .normal: break
                case .undo: _ = activityUndoHistory.popLast()
                case .redo: _ = activityRedoHistory.popLast()
                }
            }
            let message = L("事项计时未保存：%@", error.localizedDescription)
            if activityTimerError != message { activityTimerError = message }
            return message
        }
    }

    private func isPauseAction(_ action: ActivityTimerAction) -> Bool { if case .togglePause = action { return true }; return false }
    private func isFinishAction(_ action: ActivityTimerAction) -> Bool { if case .finish = action { return true }; return false }
    private func isSwitchAction(_ action: ActivityTimerAction) -> Bool { if case .switchActivity = action { return true }; return false }

    private func cancelActivityRefresh() {
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
        activityRefreshID = nil
    }

    private func scheduleActivityRefresh(at date: Date, afterSave: Bool = false) {
        guard activityDataReady, !stopped, activityRefreshTask == nil,
              afterSave || !activitySaveInProgress else { return }
        let version = activityMutationVersion
        let boundary = pendingSleepPause
        let refreshID = UUID()
        activityRefreshID = refreshID
        activityRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activityRefreshID == refreshID {
                    self.activityRefreshTask = nil
                    self.activityRefreshID = nil
                }
            }
            do {
                let result = try await self.activityIO.refresh(at: date, sleepBoundary: boundary)
                guard !Task.isCancelled, !self.stopped, self.activityMutationVersion == version,
                      !self.activitySaveInProgress || afterSave else { return }
                self.publishActivityResult(result)
                if self.pendingSleepPause == boundary { self.pendingSleepPause = nil }
            } catch {
                guard !Task.isCancelled, !self.stopped, self.activityMutationVersion == version else { return }
                let message = L("计时记录同步失败，将自动重试：%@", error.localizedDescription)
                if self.activityTimerError != message { self.activityTimerError = message }
            }
        }
    }

    private func publishActivityResult(_ result: ActivityTimerIOResult) {
        if let prepared = result.preparedStatistics { activityStatisticsCache = prepared }
        if activityTimers != result.document { activityTimers = result.document }
        if activityTimerError != result.error { activityTimerError = result.error }
        if let completionID = result.completionID, countdownCompletionEventID != completionID {
            countdownCompletionEventID = completionID
        }
    }

    var needsActivityFlush: Bool { activitySaveInProgress || !activityDataReady || pendingSleepPause != nil }

    func prepareForTermination() async -> Bool {
        let wasSaving = activitySaveInProgress
        if let activityLoadTask { await activityLoadTask.value }
        while activitySaveInProgress { try? await Task.sleep(nanoseconds: 10_000_000) }
        if let boundary = pendingSleepPause {
            do {
                let result = try await activityIO.refresh(at: nowProvider(), sleepBoundary: boundary)
                publishActivityResult(result)
                if pendingSleepPause == boundary { pendingSleepPause = nil }
            } catch {
                activityTimerError = L("事项计时未保存：%@", error.localizedDescription)
                return false
            }
        }
        return !wasSaving || activityTimerError == nil
    }

    func isTaskCompleted(_ id: UUID) -> Bool {
        todayProgress.tasks.first { $0.id == id }?.isCompleted ?? false
    }

    @discardableResult
    func toggleTaskCompletion(id: UUID) -> String? {
        let date = nowProvider()
        let calendar = DailyProgress.localCalendar(calendarProvider())
        var updated = progress(for: tasks, at: date, calendar: calendar)
        guard updated.toggleCompletion(id: id, at: date) else {
            return L("这个任务已不存在，请刷新今日计划后重试。")
        }
        return commit(tasks: tasks, progress: updated, at: date, calendar: calendar)
    }

    @discardableResult
    func replaceTasks(_ tasks: [PlanTask]) -> String? {
        save(tasks.map { task in
            var trimmed = task
            trimmed.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            trimmed.details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
        })
    }

    /// Requires the user to explicitly confirm that both the plan and history will be reset.
    @discardableResult
    func recoverWithDefaultPlan() -> String? {
        guard needsDataRecovery else { return nil }
        let date = nowProvider()
        let calendar = DailyProgress.localCalendar(calendarProvider())
        let defaults = DefaultPlan.tasks.sorted { $0.startMinutes < $1.startMinutes }
        let progress = DailyProgress(tasks: defaults, at: date, calendar: calendar)
        do {
            try progressStore.recover(with: ProgressDocument(tasks: defaults, history: [progress]))
            tasks = defaults
            history = [progress]
            todayProgress = progress
            now = date
            snapshot = ScheduleEngine.snapshot(tasks: defaults, at: date, calendar: calendar)
            needsDataRecovery = false
            errorMessage = nil
            return nil
        } catch {
            let message = L("恢复失败：%@", "\(error.localizedDescription)")
            errorMessage = message
            return message
        }
    }

    @discardableResult
    func saveTask(_ task: PlanTask) -> String? {
        var edited = task
        edited.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = tasks.filter { $0.id != edited.id }
        candidate.append(edited)
        return save(candidate)
    }

    @discardableResult
    func deleteTask(id: UUID) -> String? {
        save(tasks.filter { $0.id != id })
    }

    func clearError() {
        errorMessage = nil
    }

    func setFloatingVisible(_ visible: Bool) {
        isFloatingVisible = visible
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    static func clampedCompactSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultCompactSize }
        return min(compactSizeRange.upperBound, max(compactSizeRange.lowerBound, value))
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard allowsLoginItemChanges else {
            errorMessage = L("测试模式下不会更改系统登录项。")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            errorMessage = L("无法更改登录时启动：%@\n请将 FocusDesk.app 放入“应用程序”后重试。", "\(error.localizedDescription)")
        }
    }

    func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginStatus = L("已开启，登录 macOS 后自动启动")
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginStatus = L("等待系统批准，请在系统设置 → 通用 → 登录项中允许 FocusDesk")
        case .notRegistered:
            launchAtLogin = false
            launchAtLoginStatus = L("未开启")
        case .notFound:
            launchAtLogin = false
            launchAtLoginStatus = L("请先将 FocusDesk.app 放入“应用程序”")
        @unknown default:
            launchAtLogin = false
            launchAtLoginStatus = L("无法读取登录项状态")
        }
    }

    func stop() {
        stopped = true
        activityRefreshTask?.cancel()
        activityLoadTask?.cancel()
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func save(_ candidate: [PlanTask]) -> String? {
        if let reason = PlanValidator.validate(candidate) { return reason }
        let sorted = candidate.sorted { $0.startMinutes < $1.startMinutes }
        let date = nowProvider()
        let calendar = DailyProgress.localCalendar(calendarProvider())
        return commit(tasks: sorted, progress: progress(for: sorted, at: date, calendar: calendar), at: date, calendar: calendar)
    }

    private func progress(for tasks: [PlanTask], at date: Date, calendar: Calendar) -> DailyProgress {
        let day = DailyProgress.dayKey(for: date, calendar: calendar)
        return history.first { $0.day == day }?.synchronizing(tasks: tasks, calendar: calendar)
            ?? DailyProgress(tasks: tasks, at: date, calendar: calendar)
    }

    private func replacingDay(_ progress: DailyProgress) -> [DailyProgress] {
        (history.filter { $0.day != progress.day } + [progress]).sorted { $0.day > $1.day }
    }

    private func commit(tasks: [PlanTask], progress: DailyProgress, at date: Date, calendar: Calendar) -> String? {
        if let reason = progressStore.blockedSaveReason {
            errorMessage = reason
            return reason
        }
        do {
            let updatedHistory = replacingDay(progress)
            try progressStore.save(ProgressDocument(tasks: tasks, history: updatedHistory))
            self.tasks = tasks
            history = updatedHistory
            todayProgress = progress
            now = date
            snapshot = ScheduleEngine.snapshot(tasks: tasks, at: date, calendar: calendar)
            errorMessage = nil
            return nil
        } catch {
            let message = saveFailure(error)
            errorMessage = message
            return message
        }
    }

    private func saveFailure(_ error: Error) -> String {
        L("计划与完成记录保存失败，本次修改未保存：%@\n请检查存储空间和文件夹权限。", "\(error.localizedDescription)")
    }

    private func beginClock() {
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(clockTick: true) }
        }
        clock.tolerance = 0.15
        RunLoop.main.add(clock, forMode: .common)
        timer = clock

        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observe(center, name: name) { [weak self] in self?.refresh() }
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification) { [weak self] in
            self?.refresh()
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification) { [weak self] in
            self?.pauseActivityTimerForSleep()
        }
        observe(center, name: NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refresh()
            self?.refreshLoginStatus()
        }
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            // In particular, persist the pause before willSleep returns.
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }
}

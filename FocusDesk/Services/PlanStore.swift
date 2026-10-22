import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class PlanStore: ObservableObject {
    static let defaultCompactSize = 56.0
    static let compactSizeRange = 32.0...112.0

    @Published private(set) var tasks: [PlanTask]
    @Published private(set) var snapshot: ScheduleSnapshot
    @Published private(set) var now: Date
    @Published private(set) var errorMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginStatus = "未开启"
    @Published private(set) var isFloatingVisible = true
    @Published private(set) var isExpanded = false
    @Published private(set) var todayProgress: DailyProgress
    @Published private(set) var history: [DailyProgress]
    @Published private(set) var needsDataRecovery = false

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

    var onShowPlan: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onToggleFloating: (() -> Void)?

    let defaults: UserDefaults
    let storageURL: URL
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let allowsLoginItemChanges: Bool
    private let progressStore: ProgressStore
    private let nowProvider: () -> Date
    private let calendarProvider: () -> Calendar

    init(
        storageDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        allowsLoginItemChanges: Bool = true,
        nowProvider: @escaping () -> Date = { Date() },
        calendarProvider: @escaping () -> Calendar = { .current },
        startClock: Bool = true
    ) {
        let date = nowProvider()
        let calendar = DailyProgress.localCalendar(calendarProvider())
        let initialTasks = DefaultPlan.tasks.sorted { $0.startMinutes < $1.startMinutes }
        self.defaults = defaults
        self.allowsLoginItemChanges = allowsLoginItemChanges
        self.nowProvider = nowProvider
        self.calendarProvider = calendarProvider
        let directory = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("FocusDesk", isDirectory: true)
        storageURL = directory.appendingPathComponent("plan.json")
        progressStore = ProgressStore(storageURL: storageURL)
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
        refreshLoginStatus()
        if startClock { beginClock() }
    }

    /// Updates from the wall clock, including after a wake or manual clock change.
    func refresh() {
        now = nowProvider()
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

    func isTaskCompleted(_ id: UUID) -> Bool {
        todayProgress.tasks.first { $0.id == id }?.isCompleted ?? false
    }

    @discardableResult
    func toggleTaskCompletion(id: UUID) -> String? {
        let date = nowProvider()
        let calendar = DailyProgress.localCalendar(calendarProvider())
        var updated = progress(for: tasks, at: date, calendar: calendar)
        guard updated.toggleCompletion(id: id, at: date) else {
            return "这个任务已不存在，请刷新今日计划后重试。"
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
            let message = "恢复失败：\(error.localizedDescription)"
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
            errorMessage = "测试模式下不会更改系统登录项。"
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
            errorMessage = "无法更改登录时启动：\(error.localizedDescription)\n请将 FocusDesk.app 放入“应用程序”后重试。"
        }
    }

    func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginStatus = "已开启，登录 macOS 后自动启动"
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginStatus = "等待系统批准，请在系统设置 → 通用 → 登录项中允许 FocusDesk"
        case .notRegistered:
            launchAtLogin = false
            launchAtLoginStatus = "未开启"
        case .notFound:
            launchAtLogin = false
            launchAtLoginStatus = "请先将 FocusDesk.app 放入“应用程序”"
        @unknown default:
            launchAtLogin = false
            launchAtLoginStatus = "无法读取登录项状态"
        }
    }

    func stop() {
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
        "计划与完成记录保存失败，本次修改未保存：\(error.localizedDescription)\n请检查存储空间和文件夹权限。"
    }

    private func beginClock() {
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
        observe(center, name: NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refresh()
            self?.refreshLoginStatus()
        }
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        observers.append((center, token))
    }
}

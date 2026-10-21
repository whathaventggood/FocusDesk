import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class PlanStore: ObservableObject {
    @Published private(set) var tasks: [PlanTask]
    @Published private(set) var snapshot: ScheduleSnapshot
    @Published private(set) var now: Date
    @Published private(set) var errorMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginStatus = "未开启"
    @Published private(set) var isFloatingVisible = true

    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }

    var onShowPlan: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleFloating: (() -> Void)?

    let defaults: UserDefaults
    let storageURL: URL
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var blockedSaveReason: String?
    private let allowsLoginItemChanges: Bool

    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard, allowsLoginItemChanges: Bool = true) {
        let date = Date()
        let initialTasks = DefaultPlan.tasks.sorted { $0.startMinutes < $1.startMinutes }
        self.defaults = defaults
        self.allowsLoginItemChanges = allowsLoginItemChanges
        let directory = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("FocusDesk", isDirectory: true)
        storageURL = directory.appendingPathComponent("plan.json")
        tasks = initialTasks
        now = date
        snapshot = ScheduleEngine.snapshot(tasks: initialTasks, at: date)
        alwaysOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
        loadTasks()
        refresh()
        refreshLoginStatus()
        startClock()
    }

    /// Updates from the wall clock, including after a wake or manual clock change.
    func refresh() {
        now = Date()
        snapshot = ScheduleEngine.snapshot(tasks: tasks, at: now)
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
        if let reason = blockedSaveReason {
            errorMessage = reason
            return reason
        }
        let sorted = candidate.sorted { $0.startMinutes < $1.startMinutes }
        do {
            try persist(sorted)
            tasks = sorted
            errorMessage = nil
            refresh()
            return nil
        } catch {
            let message = "计划保存失败：\(error.localizedDescription)\n请检查存储空间和文件夹权限。"
            errorMessage = message
            return message
        }
    }

    private func persist(_ plan: [PlanTask]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        try data.write(to: storageURL, options: .atomic)
    }

    private func loadTasks() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            do { try persist(tasks) }
            catch { errorMessage = "默认计划暂未保存：\(error.localizedDescription)" }
            return
        }
        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try JSONDecoder().decode([PlanTask].self, from: data)
            if let reason = PlanValidator.validate(loaded) {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            tasks = loaded.sorted { $0.startMinutes < $1.startMinutes }
        } catch {
            // Keep an exact backup before allowing a later edit to replace bad data.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = storageURL.deletingLastPathComponent().appendingPathComponent(
                "plan.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json"
            )
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
                errorMessage = "本地计划无法读取，已暂用默认计划。\n原文件已备份为 \(backup.lastPathComponent)。\n原因：\(error.localizedDescription)"
            } catch {
                let reason = "本地计划无法读取，且无法备份原文件。为保护原计划，暂时不能保存修改。\n请检查 \(storageURL.path) 的文件权限后重启应用。"
                blockedSaveReason = reason
                errorMessage = reason
            }
        }
    }

    private func startClock() {
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

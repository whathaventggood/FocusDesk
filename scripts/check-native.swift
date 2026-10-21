import AppKit
import Foundation

private final class SmokeDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "FocusDesk.NativeSmoke")! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum NativeSmoke {
    @MainActor
    static func main() {
        setbuf(stdout, nil)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/native-smoke", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }

        // Only this opt-in harness uses these overrides. No system login item is changed.
        setenv("FOCUSDESK_SMOKE_TEST", "1", 1)
        setenv("FOCUSDESK_DATA_DIRECTORY", output.appendingPathComponent("app-data").path, 1)
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do {
                print("Checking native launch callback; windows: \(application.windows.map(\.title))")
                try verifyPersistence(in: output)
                try verifyWindows(controller: controller, output: output)
                print("PASS: native window, persistence, and recovery checks")
                print("Preview PNGs: \(output.path)")
                application.terminate(nil)
            } catch {
                print("FAIL: \(error)")
                controller.store.stop()
                exit(1)
            }
        }
        withExtendedLifetime(controller) { application.run() }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SmokeFailure(description: message) }
    }

    @MainActor
    private static func verifyPersistence(in output: URL) throws {
        let directory = output.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plan.json")
        try Data("[]".utf8).write(to: url)
        let preferences = SmokeDefaults()
        let store = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false)
        defer { store.stop() }
        try require(store.tasks.isEmpty, "Empty JSON plan should remain empty")

        let first = PlanTask(startMinutes: 540, endMinutes: 600, title: "  任务一  ", details: " 测试内容 ")
        let second = PlanTask(startMinutes: 600, endMinutes: 660, title: "任务二", details: "相邻时间段")
        try require(store.saveTask(second) == nil, "Adding a task failed")
        try require(store.saveTask(first) == nil, "Adding an adjacent task failed")
        try require(store.tasks.map(\.startMinutes) == [540, 600], "Plan must remain sorted")
        try require(store.tasks.first?.title == "任务一", "Task title should trim surrounding whitespace")
        let beforeConflict = try Data(contentsOf: url)
        let conflict = PlanTask(startMinutes: 570, endMinutes: 630, title: "冲突任务", details: "")
        try require(store.saveTask(conflict) != nil, "Overlapping task should be rejected")
        try require(try Data(contentsOf: url) == beforeConflict, "Rejected edits must not change the JSON file")
        let invalid = PlanTask(startMinutes: 700, endMinutes: 690, title: "结束过早", details: "")
        try require(store.saveTask(invalid) != nil, "End-before-start should be rejected")
        try require(store.tasks.count == 2, "Rejected edits must not change the published plan")
        store.alwaysOnTop = false

        let reloaded = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false)
        defer { reloaded.stop() }
        try require(reloaded.tasks == store.tasks, "JSON plan did not survive reloading")
        try require(!reloaded.alwaysOnTop, "Preferences did not survive reloading")
        try require(reloaded.deleteTask(id: second.id) == nil, "Deleting a task failed")
        let persisted = try JSONDecoder().decode([PlanTask].self, from: Data(contentsOf: url))
        try require(persisted.count == 1 && persisted.first?.id == first.id, "Deleted task remained in JSON")

        let damagedDirectory = output.appendingPathComponent("corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        let damagedURL = damagedDirectory.appendingPathComponent("plan.json")
        let damaged = Data("{this is a broken plan".utf8)
        try damaged.write(to: damagedURL)
        let recovered = PlanStore(storageDirectory: damagedDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false)
        defer { recovered.stop() }
        try require(recovered.errorMessage != nil, "Damaged JSON should produce a visible warning")
        try require(recovered.tasks.count == DefaultPlan.tasks.count, "Damaged JSON should use the default plan")
        try require(try Data(contentsOf: damagedURL) == damaged, "Damaged original must remain unchanged until an edit")
        let backups = try FileManager.default.contentsOfDirectory(at: damagedDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("plan.corrupt-") }
        try require(backups.count == 1, "Damaged JSON was not backed up")
        try require(try Data(contentsOf: backups[0]) == damaged, "Backup must preserve the original bytes")
        try require(recovered.deleteTask(id: recovered.tasks[0].id) == nil, "Recovery should allow saving after a backup")
        _ = try JSONDecoder().decode([PlanTask].self, from: Data(contentsOf: damagedURL))
        print("PASS: save/reload, rejected edits, deletion, preferences, damaged-file backup")
    }

    @MainActor
    private static func verifyWindows(controller: AppController, output: URL) throws {
        let panels = NSApp.windows.compactMap { $0 as? NSPanel }.filter { $0.title == "FocusDesk 悬浮窗" }
        try require(panels.count == 1, "Expected exactly one desktop NSPanel")
        let panel = panels[0]
        try require(panel.isVisible, "Desktop panel should appear at startup")
        try require(!NSApp.isActive, "Showing the desktop panel at startup must not activate the app")
        try require(!panel.canBecomeKey && !panel.isKeyWindow, "Desktop panel must not take keyboard focus")
        try require(panel.styleMask.contains(.nonactivatingPanel), "Desktop panel must be nonactivating")
        try require(panel.collectionBehavior.contains(.canJoinAllSpaces), "Desktop panel should join all Spaces")
        try require(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Desktop panel should support full-screen apps")
        try require(!panel.hidesOnDeactivate && panel.isFloatingPanel, "Panel should remain visible across app switches")
        try require(panel.isMovableByWindowBackground, "Panel background should support dragging")
        try require(panel.contentView?.mouseDownCanMoveWindow == true, "Hosting view must permit native window dragging")
        try require(panel.level == .floating, "Always-on-top should be enabled by default")
        try writePreview(panel, to: output.appendingPathComponent("floating.png"))

        controller.store.alwaysOnTop = false
        try require(panel.level == .normal, "Always-on-top switch did not update the panel level")
        controller.store.alwaysOnTop = true
        controller.toggleFloating()
        try require(!panel.isVisible && !controller.store.isFloatingVisible, "Hiding the panel failed")
        controller.toggleFloating()
        try require(panel.isVisible && controller.store.isFloatingVisible, "Showing the panel failed")
        controller.showPlan()
        controller.showPlan()
        let plans = NSApp.windows.filter { $0.title == "今日计划 · FocusDesk" }
        try require(plans.count == 1, "Opening the plan twice should reuse the same window")
        let plan = plans[0]
        try require(plan.isVisible && plan.canBecomeKey, "Plan window should support native editing")
        try writePreview(plan, to: output.appendingPathComponent("plan.png"))
        plan.close()
        controller.showPlan()
        try require(NSApp.windows.filter { $0.title == "今日计划 · FocusDesk" }.count == 1, "Closing and reopening should reuse the plan window")

        controller.showSettings()
        controller.showSettings()
        let settings = NSApp.windows.filter { $0.title == "设置 · FocusDesk" }
        try require(settings.count == 1, "Opening settings twice should reuse the same window")
        try require((settings[0].contentView?.bounds.height ?? 0) >= 520, "Settings content is too short and may clip")
        try writePreview(settings[0], to: output.appendingPathComponent("settings.png"))
        controller.store.setLaunchAtLogin(true)
        try require(controller.store.errorMessage?.contains("测试模式") == true, "Smoke mode must block system login-item changes")
        print("PASS: nonactivating panel, Spaces, visibility, level changes, reusable plan/settings windows")
    }

    @MainActor
    private static func writePreview(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw SmokeFailure(description: "Window has no content") }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SmokeFailure(description: "Unable to create a window preview")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let captured = bitmap.cgImage,
              let context = CGContext(
                data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw SmokeFailure(description: "Unable to composite the window preview")
        }
        let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(rect)
        context.draw(captured, in: rect)
        guard let composited = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: composited).representation(using: .png, properties: [:]) else {
            throw SmokeFailure(description: "Unable to encode the window preview")
        }
        try data.write(to: url)
    }
}

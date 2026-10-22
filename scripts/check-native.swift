import AppKit
import Foundation

private final class SmokeDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "FocusDesk.NativeSmoke")! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum NativeSmoke {
    @MainActor private static var checkCount = 0

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
        setenv("FOCUSDESK_DATA_DIRECTORY", output.appendingPathComponent("app-data-\(UUID().uuidString)").path, 1)
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        // Start from the native run loop, allowing nested event pumping to deliver
        // main-queue hover deadlines while this synchronous harness is checking them.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                do {
                    print("Checking native launch callback; windows: \(application.windows.map(\.title))")
                    try verifyPersistence(in: output)
                    try verifyWindows(controller: controller, output: output)
                    print("PASS: \(checkCount) native window, hover, persistence, and recovery checks")
                    print("Preview PNGs: \(output.path)")
                    application.terminate(nil)
                } catch {
                    print("FAIL: \(error)")
                    controller.store.stop()
                    exit(1)
                }
            }
        }
        withExtendedLifetime(controller) { application.run() }
    }

    @MainActor
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SmokeFailure(description: message) }
        checkCount += 1
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
        let migrated = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: url))
        try require(migrated.tasks.isEmpty && migrated.history.count == 1, "Legacy task array should migrate with today's empty record")
        try require(store.compactSize == PlanStore.defaultCompactSize, "Compact square should default to 56 points")
        try require(!store.isExpanded, "Detail visibility should not be restored across launches")

        let first = PlanTask(startMinutes: 540, endMinutes: 600, title: "  任务一  ", details: " 测试内容 ")
        let second = PlanTask(startMinutes: 600, endMinutes: 660, title: "任务二", details: "相邻时间段")
        try require(store.saveTask(second) == nil, "Adding a task failed")
        try require(store.saveTask(first) == nil, "Adding an adjacent task failed")
        try require(store.tasks.map(\.startMinutes) == [540, 600], "Plan must remain sorted")
        try require(store.tasks.first?.title == "任务一", "Task title should trim surrounding whitespace")
        try require(store.todayProgress.totalCount == 2 && store.todayProgress.completedCount == 0, "Today's progress should track saved tasks")
        try require(store.toggleTaskCompletion(id: first.id) == nil, "Marking today's task complete failed")
        try require(store.isTaskCompleted(first.id) && store.todayProgress.completedCount == 1, "Completion did not update immediately")
        let beforeConflict = try Data(contentsOf: url)
        let conflict = PlanTask(startMinutes: 570, endMinutes: 630, title: "冲突任务", details: "")
        try require(store.saveTask(conflict) != nil, "Overlapping task should be rejected")
        try require(try Data(contentsOf: url) == beforeConflict, "Rejected edits must not change the JSON file")
        let invalid = PlanTask(startMinutes: 700, endMinutes: 690, title: "结束过早", details: "")
        try require(store.saveTask(invalid) != nil, "End-before-start should be rejected")
        try require(store.tasks.count == 2, "Rejected edits must not change the published plan")
        store.alwaysOnTop = false
        store.compactSize = 74
        store.setExpanded(true)

        let reloaded = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false)
        defer { reloaded.stop() }
        try require(reloaded.tasks == store.tasks, "JSON plan did not survive reloading")
        try require(reloaded.isTaskCompleted(first.id), "Completion did not survive reloading")
        try require(!reloaded.alwaysOnTop, "Preferences did not survive reloading")
        try require(reloaded.compactSize == 74, "Compact square size did not survive reloading")
        try require(!reloaded.isExpanded, "A reopened app should start with its detail panel hidden")
        reloaded.compactSize = 1
        try require(reloaded.compactSize == PlanStore.compactSizeRange.lowerBound, "Compact size should clamp to its minimum")
        reloaded.compactSize = 1000
        try require(reloaded.compactSize == PlanStore.compactSizeRange.upperBound, "Compact size should clamp to its maximum")
        reloaded.compactSize = .nan
        try require(reloaded.compactSize == PlanStore.defaultCompactSize, "NaN square sizes must recover to the default")
        reloaded.compactSize = .infinity
        try require(reloaded.compactSize == PlanStore.defaultCompactSize, "Infinite square sizes must recover to the default")
        try require(reloaded.deleteTask(id: second.id) == nil, "Deleting a task failed")
        let persisted = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: url))
        try require(persisted.tasks.count == 1 && persisted.tasks.first?.id == first.id, "Deleted task remained in JSON")
        try require(persisted.history.first?.completedCount == 1 && persisted.history.first?.totalCount == 1, "Completion should survive plan edits by task ID")

        let rolloverDirectory = output.appendingPathComponent("rollover-\(UUID().uuidString)", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var simulatedNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 59))!
        let rollover = PlanStore(
            storageDirectory: rolloverDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
            nowProvider: { simulatedNow }, calendarProvider: { calendar }, startClock: false
        )
        defer { rollover.stop() }
        let completedID = rollover.tasks[0].id
        try require(rollover.toggleTaskCompletion(id: completedID) == nil, "Completion before midnight failed")
        let yesterday = rollover.todayProgress
        simulatedNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 1))!
        rollover.refresh()
        try require(rollover.todayProgress.day != yesterday.day && rollover.todayProgress.completedCount == 0, "A new local day should reset completion")
        try require(rollover.history.first(where: { $0.day == yesterday.day })?.completedCount == 1, "Midnight rollover should preserve yesterday's result")
        let editedToday = PlanTask(startMinutes: 540, endMinutes: 600, title: "今日新增", details: "历史保持原样")
        let revised = try PlanEditing.replacingConflicts(with: editedToday, in: rollover.tasks)
        try require(rollover.replaceTasks(revised) == nil, "Confirmed conflict replacement should commit in one save")
        try require(rollover.tasks.contains(where: { $0.id == editedToday.id }), "The replacement task did not enter today's plan")
        try require(rollover.history.first(where: { $0.day == yesterday.day }) == yesterday, "Editing today's plan should not rewrite yesterday")
        let savedRevision = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: rollover.storageURL))
        try require(savedRevision.tasks == rollover.tasks && savedRevision.history == rollover.history, "Conflict replacement and progress must persist together")
        let rolloverReloaded = PlanStore(
            storageDirectory: rolloverDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
            nowProvider: { simulatedNow }, calendarProvider: { calendar }, startClock: false
        )
        defer { rolloverReloaded.stop() }
        try require(rolloverReloaded.history.first(where: { $0.day == yesterday.day })?.completedCount == 1, "Historical completion did not survive relaunch")

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
        try require(recovered.needsDataRecovery, "A damaged file must require explicit recovery")
        try require(recovered.deleteTask(id: recovered.tasks[0].id) != nil, "Damaged data should block ordinary edits")
        try require(try Data(contentsOf: damagedURL) == damaged, "Blocked edits must not replace the damaged original")
        try require(recovered.recoverWithDefaultPlan() == nil, "Explicit recovery should save a fresh default plan")
        try require(!recovered.needsDataRecovery, "Recovery should clear the blocked state")
        _ = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: damagedURL))
        print("PASS: migration, completion/reload, rollover history, rejected edits, compact size, explicit damaged-file recovery")
    }

    @MainActor
    private static func verifyWindows(controller: AppController, output: URL) throws {
        let panels = NSApp.windows.compactMap { $0 as? NSPanel }
        let compacts = panels.filter { $0.title == "FocusDesk 小方块" }
        let details = panels.filter { $0.title == "FocusDesk 悬浮窗" }
        try require(compacts.count == 1 && details.count == 1, "Expected one compact square and one detail NSPanel")
        let compact = compacts[0]
        let detail = details[0]
        try require(compact.isVisible && !detail.isVisible, "Startup should show only the compact square")
        try require(!controller.store.isExpanded && controller.store.isFloatingVisible, "Startup visibility state is incorrect")
        try require(approximately(compact.frame.width, 56) && approximately(compact.frame.height, 56), "Default square must measure 56 × 56 points")
        try require(!NSApp.isActive, "Showing the compact square at startup must not activate the app")
        for panel in [compact, detail] {
            try require(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow, "Desktop panels must not take keyboard focus")
            try require(panel.styleMask.contains(.nonactivatingPanel), "Desktop panels must be nonactivating")
            try require(panel.collectionBehavior.contains(.canJoinAllSpaces), "Desktop panels should join all Spaces")
            try require(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Desktop panels should support full-screen apps")
            try require(!panel.hidesOnDeactivate && panel.isFloatingPanel, "Desktop panels should remain available across app switches")
            try require(panel.level == .floating, "Always-on-top should be enabled by default")
            panel.contentView?.updateTrackingAreas()
            let tracksInBackground = panel.contentView?.trackingAreas.contains { area in
                area.options.contains(.activeAlways) && area.options.contains(.mouseEnteredAndExited)
                    && area.options.contains(.enabledDuringMouseDrag)
            } == true
            try require(tracksInBackground, "Hover tracking should continue while another app is active and during native dragging")
        }
        try require(compact.isMovableByWindowBackground, "The compact square background should support native dragging")
        try require(compact.contentView?.mouseDownCanMoveWindow == true, "Compact hosting view must permit native window dragging")
        try writePreview(compact, to: output.appendingPathComponent("compact.png"))

        controller.store.alwaysOnTop = false
        try require(compact.level == .normal && detail.level == .normal, "Always-on-top switch should update both panels")
        controller.store.alwaysOnTop = true
        try verifyResizing(controller: controller, compact: compact)
        try verifyHover(controller: controller, compact: compact, detail: detail)
        try verifyPlacement(controller: controller, compact: compact, detail: detail)
        controller.resizeCompact(to: CGFloat(PlanStore.defaultCompactSize))
        controller.setCompactHover(true)
        if let current = controller.store.snapshot.current {
            try require(controller.store.toggleTaskCompletion(id: current.id) == nil, "Completing the current task from the widget should save")
            try require(controller.store.isTaskCompleted(current.id), "Widget completion should update today's progress")
        }
        try writePreview(detail, to: output.appendingPathComponent("floating.png"))
        controller.collapseDetails()

        controller.setCompactHover(true)
        controller.setCompactHover(false)
        controller.toggleFloating()
        try require(!compact.isVisible && !detail.isVisible && !controller.store.isFloatingVisible, "Hiding the widget should hide both panels")
        controller.setCompactHover(true)
        pumpEvents(for: 0.4)
        try require(!detail.isVisible && !controller.store.isExpanded, "A hover event must not reopen a hidden widget")
        controller.toggleFloating()
        pumpEvents(for: 0.35)
        try require(compact.isVisible && !detail.isVisible && controller.store.isFloatingVisible, "Showing the widget should restore only its compact square")
        try require(!controller.store.isExpanded, "Showing the widget must reset any pending hover expansion")

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
        controller.showHistory()
        controller.showHistory()
        let history = NSApp.windows.filter { $0.title == "专注记录 · FocusDesk" }
        try require(history.count == 1, "Opening history twice should reuse the same window")
        try require(history[0].isVisible && history[0].canBecomeKey, "History should open as a readable native window")
        try writePreview(history[0], to: output.appendingPathComponent("history.png"))
        controller.store.setLaunchAtLogin(true)
        try require(controller.store.errorMessage?.contains("测试模式") == true, "Smoke mode must block system login-item changes")
        print("PASS: nonactivating compact/detail panels, hover transitions, resize, geometry, reusable plan/settings/history windows")
    }

    @MainActor
    private static func verifyResizing(controller: AppController, compact: NSPanel) throws {
        let visible = compact.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        compact.setFrameOrigin(NSPoint(x: visible.midX - 28, y: visible.maxY - 100))
        pumpEvents(for: 0.05)
        let oldTop = compact.frame.maxY
        controller.resizeCompact(to: 88)
        pumpEvents(for: 0.05)
        try require(approximately(compact.frame.width, 88) && approximately(compact.frame.height, 88), "Resizing should preserve a square aspect ratio; actual frame: \(compact.frame), size preference: \(controller.store.compactSize)")
        try require(approximately(compact.frame.maxY, oldTop), "Resizing should preserve the top edge away from screen bounds")
        try require(visible.contains(compact.frame), "The resized square must remain inside the usable screen")
        try require(controller.store.compactSize == 88, "Native resizing should update the stored size")

        controller.resizeCompact(to: 1)
        pumpEvents(for: 0.05)
        try require(approximately(compact.frame.width, 32) && approximately(compact.frame.height, 32), "Native resizing should enforce the 32-point minimum")
        controller.resizeCompact(to: 1000)
        pumpEvents(for: 0.05)
        try require(approximately(compact.frame.width, 112) && approximately(compact.frame.height, 112), "Native resizing should enforce the 112-point maximum")
        try require(visible.contains(compact.frame), "Maximum compact size must remain on screen")
        let reloaded = PlanStore(
            storageDirectory: controller.store.storageURL.deletingLastPathComponent(),
            defaults: controller.store.defaults, allowsLoginItemChanges: false
        )
        defer { reloaded.stop() }
        try require(reloaded.compactSize == 112, "Native compact size did not survive a preference reload")
        controller.resizeCompact(to: CGFloat(PlanStore.defaultCompactSize))
        pumpEvents(for: 0.05)
        try verifyResizeHandle(compact)
        controller.resizeCompact(to: CGFloat(PlanStore.defaultCompactSize))
        pumpEvents(for: 0.05)

        let destination = NSPoint(x: visible.midX, y: visible.midY)
        compact.setFrameOrigin(destination)
        pumpEvents(for: 0.05)
        let stored = controller.store.defaults.dictionary(forKey: "compactWindowPosition")
        try require(stored?["x"] as? Double == Double(destination.x) && stored?["y"] as? Double == Double(destination.y), "Native compact movement should persist its position")
        print("PASS: square resizing, limits, top-edge anchoring, bounds, persisted size and position")
    }

    @MainActor
    private static func verifyResizeHandle(_ compact: NSPanel) throws {
        guard let root = compact.contentView,
              let handle = descendant(of: root, whoseClassContains: "ResizeHandleView") else {
            throw SmokeFailure(description: "Compact square has no native resize handle")
        }
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + 20, y: start.y - 20)
        let top = compact.frame.maxY
        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: compact.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1
            ) else { throw SmokeFailure(description: "Unable to construct an isolated resize event") }
            return event
        }
        // Deliver only to the test view; the real system pointer never moves.
        handle.mouseDown(with: try event(.leftMouseDown, at: start))
        handle.mouseDragged(with: try event(.leftMouseDragged, at: end))
        pumpEvents(for: 0.05, mode: .eventTracking)
        try require(approximately(compact.frame.width, 76) && approximately(compact.frame.height, 76), "Dragging the native resize handle should resize 56 to 76 points before mouse-up in event-tracking mode")
        try require(approximately(compact.frame.maxY, top), "Native resize handle dragging should preserve the square's top edge")
        handle.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    @MainActor
    private static func descendant(of view: NSView, whoseClassContains name: String) -> NSView? {
        if String(describing: type(of: view)).contains(name) { return view }
        for child in view.subviews {
            if let match = descendant(of: child, whoseClassContains: name) { return match }
        }
        return nil
    }

    @MainActor
    private static func verifyHover(controller: AppController, compact: NSPanel, detail: NSPanel) throws {
        controller.setCompactHover(true)
        try require(detail.isVisible && controller.store.isExpanded && compact.isVisible, "Entering the compact square should expand task details")
        try require(!NSApp.isActive && !detail.isKeyWindow, "Hover expansion must not activate the app or steal focus")
        controller.setCompactHover(false)
        pumpEvents(for: 0.1)
        try require(detail.isVisible, "The short hide delay should permit moving into the detail panel")
        controller.setDetailHover(true)
        pumpEvents(for: 0.35)
        try require(detail.isVisible && controller.store.isExpanded, "Moving from square to detail should keep the detail panel open")
        controller.setDetailHover(false)
        pumpEvents(for: 0.4)
        try require(!detail.isVisible && !controller.store.isExpanded && compact.isVisible, "Leaving both panels should collapse details and preserve the square")

        controller.setCompactHover(true)
        controller.setCompactHover(false)
        pumpEvents(for: 0.1)
        controller.setCompactHover(true)
        pumpEvents(for: 0.4)
        try require(detail.isVisible && controller.store.isExpanded, "Quick reentry should cancel a pending collapse")
        controller.setCompactHover(false)
        pumpEvents(for: 0.4)
        try require(!detail.isVisible, "A subsequent complete exit should still collapse details")
        controller.setCompactHover(true)
        controller.collapseDetails()
        try require(!detail.isVisible && !controller.store.isExpanded, "Explicit collapse should hide the detail panel")
        print("PASS: enter, square-to-detail transfer, delayed exit, rapid reentry, explicit collapse")
    }

    @MainActor
    private static func verifyPlacement(controller: AppController, compact: NSPanel, detail: NSPanel) throws {
        let original = compact.frame.origin
        let visible = compact.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let side = compact.frame.width
        let corners = [
            NSPoint(x: visible.minX, y: visible.maxY - side),
            NSPoint(x: visible.maxX - side, y: visible.maxY - side),
            NSPoint(x: visible.minX, y: visible.minY),
            NSPoint(x: visible.maxX - side, y: visible.minY)
        ]
        for origin in corners {
            controller.collapseDetails()
            compact.setFrameOrigin(origin)
            pumpEvents(for: 0.05)
            controller.setCompactHover(true)
            try require(visible.contains(detail.frame), "Details must remain inside the usable screen near every corner")
            let intersection = compact.frame.intersection(detail.frame)
            try require(intersection.isNull || intersection.width * intersection.height < 1, "Details must not cover the compact square")
            try require(approximately(detail.frame.width, 360) && approximately(detail.frame.height, 400), "Detail layout should retain its readable 360 × 400-point size")
        }
        controller.collapseDetails()
        compact.setFrameOrigin(original)
        pumpEvents(for: 0.05)
        print("PASS: corner placement, visible screen bounds, unobstructed compact square")
    }

    private static func approximately(_ first: CGFloat, _ second: CGFloat) -> Bool {
        abs(first - second) < 0.5
    }

    @MainActor
    private static func pumpEvents(for interval: TimeInterval, mode: RunLoop.Mode = .default) {
        let deadline = Date(timeIntervalSinceNow: interval)
        while Date() < deadline {
            RunLoop.current.run(mode: mode, before: deadline)
        }
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

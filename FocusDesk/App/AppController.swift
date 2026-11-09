import AppKit
import Combine
import SwiftUI

/// The desktop panel never becomes the keyboard or main window.
private final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var hoverChanged: ((Bool) -> Void)?
    var allowsWindowDragging = false
    private var hoverTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { allowsWindowDragging }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    // Keep hover responsive while another application owns keyboard focus.
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

/// Used only for opt-in UI checks so app preferences stay entirely in memory.
private final class SessionDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: "FocusDesk.SmokeTest")! }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        values[defaultName] as? [String: Any]
    }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    // Wait until the launch delegate is installed before touching NSWorkspace/ServiceManagement.
    private(set) lazy var store: PlanStore = {
        let environment = ProcessInfo.processInfo.environment
        let overrideDirectory = environment["FOCUSDESK_DATA_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let storageDirectory = overrideDirectory ?? (isSmokeTest ? FileManager.default.temporaryDirectory.appendingPathComponent("FocusDesk-SmokeTest", isDirectory: true) : nil)
        return PlanStore(
            storageDirectory: storageDirectory,
            defaults: isSmokeTest ? SessionDefaults() : .standard,
            allowsLoginItemChanges: !isSmokeTest,
            useBackgroundActivityIO: !isSmokeTest
        )
    }()
    private var panel: NSPanel?
    private var compactPanel: NSPanel?
    private(set) var effectPanels: [NSPanel] = []
    private var effectGeneration = UUID()
    private var planWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var timersWindow: NSWindow?
    private var quoteWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var visibilityMenuItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()
    private let panelSize = FloatingView.panelSize
    private let panelPositionKey = "compactWindowPosition"
    private var compactHovered = false
    private var detailHovered = false
    private var pendingHide: DispatchWorkItem?
    private let isSmokeTest: Bool

    override init() {
        let environment = ProcessInfo.processInfo.environment
        isSmokeTest = environment["FOCUSDESK_SMOKE_TEST"] == "1"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onShowPlan = { [weak self] in self?.showPlan() }
        store.onShowSettings = { [weak self] in self?.showSettings() }
        store.onShowHistory = { [weak self] in self?.showHistory() }
        store.onShowTimers = { [weak self] in self?.showTimers() }
        store.onShowQuoteDetails = { [weak self] quote in self?.showQuoteDetails(quote) }
        store.onToggleFloating = { [weak self] in self?.toggleFloating() }
        createMainMenu()
        createStatusItem()
        createPanels()
        store.onStopEffect = { [weak self] in self?.stopCountdownEffect() }
        store.$effectsEnabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] enabled in
            if !enabled { self?.stopCountdownEffect() }
        }.store(in: &subscriptions)
        store.onPreviewEffect = { [weak self] in self?.playCountdownEffect(preview: true) }
        store.$countdownCompletionEventID.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] id in
            guard id != nil else { return }
            self?.playCountdownEffect()
        }.store(in: &subscriptions)

        store.$language.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.planWindow?.title = L("今日计划 · FocusDesk")
            self?.settingsWindow?.title = L("设置 · FocusDesk")
            self?.timersWindow?.title = L("事项计时 · FocusDesk")
            self?.historyWindow?.title = L("计划回顾 · FocusDesk")
            self?.createMainMenu()
            self?.statusItem?.menu = nil
            self?.createStatusItem()
        }.store(in: &subscriptions)

        store.$alwaysOnTop.removeDuplicates().sink { [weak self] enabled in
            self?.panel?.level = enabled ? .floating : .normal
            self?.compactPanel?.level = enabled ? .floating : .normal
        }.store(in: &subscriptions)
        store.$compactSize.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] side in
            self?.applyCompactSize(CGFloat(PlanStore.clampedCompactSize(side)))
        }.store(in: &subscriptions)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc func stopCountdownEffect() {
        effectGeneration = UUID()
        for window in effectPanels { window.orderOut(nil); window.contentView = nil; window.close() }
        effectPanels.removeAll()
    }

    func playCountdownEffect(preview: Bool = false) {
        stopCountdownEffect()
        guard store.effectsEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let compact = compactPanel, preview || compact.isVisible,
              let current = compact.screen ?? NSScreen.main else { return }
        let c = store.effectConfiguration.normalized
        let started = Date()
        for screen in c.allScreens ? NSScreen.screens : [current] {
            let frame = screen.frame
            let origin = CGPoint(x: min(frame.width, max(0, compact.frame.midX-frame.minX)),
                                 y: min(frame.height, max(0, frame.maxY-compact.frame.midY)))
            let window = desktopPanel(size: frame.size, title: L("FocusDesk 到时特效"))
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.animationBehavior = .none
            window.level = .statusBar
            window.contentView = NSHostingView(rootView: CountdownEffectView(
                theme: store.theme, effect: store.countdownEffect, configuration: c, origin: origin,
                radius: EffectGeometry.radius(size: frame.size, origin: origin, coverage: c.coverage), startedAt: started))
            window.setFrame(frame, display: false)
            window.orderFrontRegardless()
            effectPanels.append(window)
        }
        let generation = UUID(); effectGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + c.duration + 0.1) { [weak self] in
            guard let self, self.effectGeneration == generation else { return }
            self.stopCountdownEffect()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.needsActivityFlush else { return .terminateNow }
        Task { @MainActor in
            let saved = await store.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCountdownEffect()
        pendingHide?.cancel()
        pendingHide = nil
        savePanelPosition()
        store.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPlan()
        return true
    }

    private func desktopPanel(size: NSSize, title: String) -> NSPanel {
        let window = DesktopPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        window.title = title
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = store.alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.animationBehavior = .utilityWindow
        window.acceptsMouseMovedEvents = true
        return window
    }

    private func createPanels() {
        let details = desktopPanel(size: panelSize, title: L("FocusDesk 悬浮窗"))
        details.isMovable = false
        let detailHost = HoverHostingView(rootView: FloatingView(store: store))
        detailHost.sizingOptions = []
        detailHost.hoverChanged = { [weak self] inside in self?.setDetailHover(inside) }
        details.contentView = detailHost
        panel = details

        let side = CGFloat(store.compactSize)
        let compact = desktopPanel(size: NSSize(width: side, height: side), title: L("FocusDesk 小方块"))
        compact.isMovableByWindowBackground = true
        compact.delegate = self
        let compactHost = HoverHostingView(rootView: CompactView(
            store: store,
            onHover: { _ in },
            onResize: { [weak self] side in self?.resizeCompact(to: side) }
        ))
        compactHost.sizingOptions = []
        compactHost.allowsWindowDragging = true
        compactHost.hoverChanged = { [weak self] inside in self?.setCompactHover(inside) }
        compact.contentView = compactHost
        compactPanel = compact
        compact.setFrame(NSRect(origin: restoredPanelOrigin(), size: NSSize(width: side, height: side)), display: false)
        positionDetails()
        compact.orderFrontRegardless()
        store.setFloatingVisible(true)
        store.setExpanded(false)
    }

    func setCompactHover(_ inside: Bool) {
        guard compactHovered != inside else { return }
        compactHovered = inside
        if inside {
            expandDetails()
        } else {
            scheduleDetailsHide()
        }
    }

    func setDetailHover(_ inside: Bool) {
        guard detailHovered != inside else { return }
        detailHovered = inside
        if inside {
            pendingHide?.cancel()
            pendingHide = nil
        } else {
            scheduleDetailsHide()
        }
    }

    private func expandDetails() {
        guard store.isFloatingVisible, compactPanel?.isVisible == true else { return }
        pendingHide?.cancel()
        pendingHide = nil
        positionDetails()
        store.refresh()
        panel?.orderFrontRegardless()
        store.setExpanded(true)
    }

    func collapseDetails() {
        pendingHide?.cancel()
        pendingHide = nil
        compactHovered = false
        detailHovered = false
        panel?.orderOut(nil)
        store.setExpanded(false)
    }

    private func scheduleDetailsHide() {
        pendingHide?.cancel()
        pendingHide = nil
        guard !compactHovered, !detailHovered, store.isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.compactHovered, !self.detailHovered else { return }
            if !self.isSmokeTest {
                let mouse = NSEvent.mouseLocation
                let overCompact = self.compactPanel.map { $0.isVisible && $0.frame.contains(mouse) } ?? false
                let overDetails = self.panel.map { $0.isVisible && $0.frame.contains(mouse) } ?? false
                guard !overCompact, !overDetails else { return }
            }
            self.collapseDetails()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func resizeCompact(to side: CGFloat) {
        guard side.isFinite else { return }
        let bounds = PlanStore.compactSizeRange
        store.compactSize = min(max(Double(side), bounds.lowerBound), bounds.upperBound)
    }

    private func applyCompactSize(_ side: CGFloat) {
        guard let compactPanel else { return }
        let oldFrame = compactPanel.frame
        let size = NSSize(width: side, height: side)
        let origin = correctedOrigin(NSPoint(x: oldFrame.minX, y: oldFrame.maxY - side), size: size)
        compactPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        positionDetails()
        savePanelPosition()
    }

    @objc func showPlan() {
        collapseDetails()
        if planWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = L("今日计划 · FocusDesk")
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: PlanView(store: store))
            if isSmokeTest {
                window.center()
            } else {
                window.setFrameAutosaveName("FocusDesk.PlanWindow")
                if !window.setFrameUsingName("FocusDesk.PlanWindow") { window.center() }
            }
            planWindow = window
        }
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        planWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        collapseDetails()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = L("设置 · FocusDesk")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            let hosting = NSHostingView(rootView: SettingsView(store: store))
            window.contentView = hosting
            let ideal = hosting.fittingSize
            window.setContentSize(NSSize(width: 520, height: max(720, ideal.height)))
            window.center()
            settingsWindow = window
        }
        store.refreshLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showHistory() {
        collapseDetails()
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = L("计划回顾 · FocusDesk")
            window.minSize = NSSize(width: 680, height: 540)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: HistoryView(store: store))
            window.center()
            historyWindow = window
        }
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showTimers() {
        collapseDetails()
        if timersWindow == nil {
            let window = ActivityWorkspaceWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = L("事项计时 · FocusDesk")
            window.activityStore = store
            window.minSize = NSSize(width: 700, height: 560)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: ActivityTimersView(store: store))
            window.center()
            timersWindow = window
        }
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        timersWindow?.makeKeyAndOrderFront(nil)
    }

    func showQuoteDetails(_ quote: MotivationalQuote) {
        collapseDetails()
        if quoteWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.title = L("解释与出处 · FocusDesk")
            window.minSize = NSSize(width: 360, height: 300)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.center()
            quoteWindow = window
        }
        quoteWindow?.contentView = NSHostingView(rootView: QuoteDetailView(quote: quote))
        NSApp.activate(ignoringOtherApps: true)
        quoteWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleFloating() {
        guard let compactPanel else { return }
        collapseDetails()
        if compactPanel.isVisible {
            compactPanel.orderOut(nil)
            store.setFloatingVisible(false)
        } else {
            correctPanelPosition()
            compactPanel.orderFrontRegardless()
            store.setFloatingVisible(true)
            store.refresh()
        }
        updateVisibilityMenuItem()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) { updateVisibilityMenuItem() }

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === compactPanel else { return }
        positionDetails()
        savePanelPosition()
    }

    @objc private func screenConfigurationChanged() {
        stopCountdownEffect()
        correctPanelPosition()
    }

    private func savePanelPosition() {
        guard let compactPanel else { return }
        let origin = compactPanel.frame.origin
        store.defaults.set(["x": Double(origin.x), "y": Double(origin.y)], forKey: panelPositionKey)
    }

    private func restoredPanelOrigin() -> NSPoint {
        let side = CGFloat(store.compactSize)
        let size = NSSize(width: side, height: side)
        if let saved = store.defaults.dictionary(forKey: panelPositionKey),
           let x = saved["x"] as? Double, let y = saved["y"] as? Double,
           x.isFinite, y.isFinite {
            return correctedOrigin(NSPoint(x: x, y: y), size: size)
        }
        if let oldPosition = store.defaults.dictionary(forKey: "floatingWindowPosition"),
           let x = oldPosition["x"] as? Double, let y = oldPosition["y"] as? Double,
           x.isFinite, y.isFinite {
            return correctedOrigin(NSPoint(x: x + panelSize.width - side, y: y + panelSize.height - side), size: size)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - side - 20, y: visible.maxY - side - 20)
    }

    private func correctedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let proposed = NSRect(origin: origin, size: size)
        let screens = NSScreen.screens
        let best = screens.max { left, right in
            intersectionArea(proposed, left.visibleFrame) < intersectionArea(proposed, right.visibleFrame)
        }
        let visible = (best ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func correctPanelPosition() {
        guard let compactPanel else { return }
        compactPanel.setFrameOrigin(correctedOrigin(compactPanel.frame.origin, size: compactPanel.frame.size))
        positionDetails()
        savePanelPosition()
    }

    private func positionDetails() {
        guard let compactPanel, let panel else { return }
        let anchor = compactPanel.frame
        let screen = NSScreen.screens.max { left, right in
            intersectionArea(anchor, left.visibleFrame) < intersectionArea(anchor, right.visibleFrame)
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 8
        let right = anchor.maxX + gap
        let preferredX = right + panelSize.width <= visible.maxX ? right : anchor.minX - gap - panelSize.width
        let origin = NSPoint(
            x: min(max(preferredX, visible.minX), max(visible.minX, visible.maxX - panelSize.width)),
            y: min(max(anchor.maxY - panelSize.height, visible.minY), max(visible.minY, visible.maxY - panelSize.height))
        )
        panel.setFrameOrigin(origin)
    }

    private func createStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "FocusDesk")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = L("FocusDesk · 今日专注计划")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "FocusDesk", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        visibilityMenuItem = addMenuItem(L("隐藏小方块"), action: #selector(toggleFloating), to: menu)
        addMenuItem(L("今日计划…"), action: #selector(showPlan), to: menu)
        addMenuItem(L("计划回顾…"), action: #selector(showHistory), to: menu)
        addMenuItem(L("事项计时…"), action: #selector(showTimers), to: menu)
        addMenuItem(L("停止特效"), action: #selector(stopCountdownEffect), to: menu)
        addMenuItem(L("设置…"), action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addMenuItem(L("退出 FocusDesk"), action: #selector(quit), key: "q", to: menu)
        item.menu = menu
        statusItem = item
    }

    private func updateVisibilityMenuItem() {
        visibilityMenuItem?.title = compactPanel?.isVisible == true ? L("隐藏小方块") : L("显示小方块")
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func createMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "FocusDesk")
        addMenuItem(L("今日计划…"), action: #selector(showPlan), key: "1", to: appMenu)
        addMenuItem(L("计划回顾…"), action: #selector(showHistory), key: "2", to: appMenu)
        addMenuItem(L("事项计时…"), action: #selector(showTimers), key: "3", to: appMenu)
        addMenuItem(L("设置…"), action: #selector(showSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        addMenuItem(L("退出 FocusDesk"), action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard responder-chain actions keep native text editing shortcuts available.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("编辑"))
        for (title, action, key) in [
            (L("撤销"), #selector(ActivityWorkspaceWindow.undo(_:)), "z"),
            (L("重做"), #selector(ActivityWorkspaceWindow.redo(_:)), "Z"),
            (L("剪切"), #selector(NSText.cut(_:)), "x"),
            (L("复制"), #selector(NSText.copy(_:)), "c"),
            (L("粘贴"), #selector(NSText.paste(_:)), "v"),
            (L("全选"), #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
/// The native field editor receives text undo first. Workspace changes are
/// handled only when the responder chain reaches this window.
@MainActor
final class ActivityWorkspaceWindow: NSWindow {
    weak var activityStore: PlanStore?

    @objc func undo(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView {
            if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
            return
        }
        guard let activityStore, !activityStore.activityIsBusy else { return }
        Task { await activityStore.undoActivityChange() }
    }

    @objc func redo(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView {
            if editor.undoManager?.canRedo == true { editor.undoManager?.redo() }
            return
        }
        guard let activityStore, !activityStore.activityIsBusy else { return }
        Task { await activityStore.redoActivityChange() }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(ActivityWorkspaceWindow.undo(_:)) {
            if let editor = firstResponder as? NSTextView {
                menuItem.title = L("撤销")
                return editor.undoManager?.canUndo == true
            }
            menuItem.title = activityStore?.activityUndoTitle ?? L("撤销")
            return activityStore?.activityUndoTitle != nil && activityStore?.activityIsBusy == false
        }
        if menuItem.action == #selector(ActivityWorkspaceWindow.redo(_:)) {
            if let editor = firstResponder as? NSTextView {
                menuItem.title = L("重做")
                return editor.undoManager?.canRedo == true
            }
            menuItem.title = activityStore?.activityRedoTitle ?? L("重做")
            return activityStore?.activityRedoTitle != nil && activityStore?.activityIsBusy == false
        }
        return super.validateMenuItem(menuItem)
    }
}

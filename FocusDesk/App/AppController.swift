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
            allowsLoginItemChanges: !isSmokeTest
        )
    }()
    private var panel: NSPanel?
    private var compactPanel: NSPanel?
    private var planWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var visibilityMenuItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()
    private let panelSize = NSSize(width: 360, height: 400)
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
        store.onToggleFloating = { [weak self] in self?.toggleFloating() }
        createMainMenu()
        createStatusItem()
        createPanels()

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

    func applicationWillTerminate(_ notification: Notification) {
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
        let details = desktopPanel(size: panelSize, title: "FocusDesk 悬浮窗")
        details.isMovable = false
        let detailHost = HoverHostingView(rootView: FloatingView(store: store))
        detailHost.sizingOptions = []
        detailHost.hoverChanged = { [weak self] inside in self?.setDetailHover(inside) }
        details.contentView = detailHost
        panel = details

        let side = CGFloat(store.compactSize)
        let compact = desktopPanel(size: NSSize(width: side, height: side), title: "FocusDesk 小方块")
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
            window.title = "今日计划 · FocusDesk"
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
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "设置 · FocusDesk"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            let hosting = NSHostingView(rootView: SettingsView(store: store))
            window.contentView = hosting
            let ideal = hosting.fittingSize
            window.setContentSize(NSSize(width: 440, height: max(520, ideal.height)))
            window.center()
            settingsWindow = window
        }
        store.refreshLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "FocusDesk")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "FocusDesk · 今日专注计划"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "FocusDesk", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        visibilityMenuItem = addMenuItem("隐藏小方块", action: #selector(toggleFloating), to: menu)
        addMenuItem("今日计划…", action: #selector(showPlan), to: menu)
        addMenuItem("设置…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addMenuItem("退出 FocusDesk", action: #selector(quit), key: "q", to: menu)
        item.menu = menu
        statusItem = item
    }

    private func updateVisibilityMenuItem() {
        visibilityMenuItem?.title = compactPanel?.isVisible == true ? "隐藏小方块" : "显示小方块"
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
        addMenuItem("今日计划…", action: #selector(showPlan), key: "1", to: appMenu)
        addMenuItem("设置…", action: #selector(showSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        addMenuItem("退出 FocusDesk", action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard responder-chain actions keep native text editing shortcuts available.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("重做", Selector(("redo:")), "Z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

import AppKit
import Combine
import SwiftUI

/// The desktop panel never becomes the keyboard or main window.
private final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
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
    private var planWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var visibilityMenuItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()
    private let panelSize = NSSize(width: 360, height: 400)
    private let panelPositionKey = "floatingWindowPosition"
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
        createPanel()

        store.$alwaysOnTop.removeDuplicates().sink { [weak self] enabled in
            self?.panel?.level = enabled ? .floating : .normal
        }.store(in: &subscriptions)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePanelPosition()
        store.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPlan()
        return true
    }

    private func createPanel() {
        let floating = DesktopPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        floating.title = "FocusDesk 悬浮窗"
        floating.isFloatingPanel = true
        floating.hidesOnDeactivate = false
        floating.becomesKeyOnlyIfNeeded = true
        floating.isReleasedWhenClosed = false
        floating.isRestorable = false
        floating.level = store.alwaysOnTop ? .floating : .normal
        floating.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        floating.isMovableByWindowBackground = true
        floating.backgroundColor = .clear
        floating.isOpaque = false
        floating.hasShadow = true
        floating.animationBehavior = .utilityWindow
        floating.delegate = self
        floating.contentView = DraggableHostingView(rootView: FloatingView(store: store))
        panel = floating
        floating.setFrame(NSRect(origin: restoredPanelOrigin(), size: panelSize), display: false)
        floating.orderFrontRegardless()
        store.setFloatingVisible(true)
    }

    @objc func showPlan() {
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
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            store.setFloatingVisible(false)
        } else {
            correctPanelPosition()
            panel.orderFrontRegardless()
            store.setFloatingVisible(true)
            store.refresh()
        }
        updateVisibilityMenuItem()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) { updateVisibilityMenuItem() }

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === panel else { return }
        savePanelPosition()
    }

    @objc private func screenConfigurationChanged() {
        correctPanelPosition()
    }

    private func savePanelPosition() {
        guard let panel else { return }
        let origin = panel.frame.origin
        store.defaults.set(["x": Double(origin.x), "y": Double(origin.y)], forKey: panelPositionKey)
    }

    private func restoredPanelOrigin() -> NSPoint {
        if let saved = store.defaults.dictionary(forKey: panelPositionKey),
           let x = saved["x"] as? Double, let y = saved["y"] as? Double,
           x.isFinite, y.isFinite {
            return correctedOrigin(NSPoint(x: x, y: y))
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - panelSize.width - 20, y: visible.maxY - panelSize.height - 20)
    }

    private func correctedOrigin(_ origin: NSPoint) -> NSPoint {
        let proposed = NSRect(origin: origin, size: panelSize)
        let screens = NSScreen.screens
        let best = screens.max { left, right in
            intersectionArea(proposed, left.visibleFrame) < intersectionArea(proposed, right.visibleFrame)
        }
        let visible = (best ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - panelSize.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - panelSize.height))
        )
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func correctPanelPosition() {
        guard let panel else { return }
        panel.setFrameOrigin(correctedOrigin(panel.frame.origin))
        savePanelPosition()
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
        visibilityMenuItem = addMenuItem("隐藏悬浮窗", action: #selector(toggleFloating), to: menu)
        addMenuItem("今日计划…", action: #selector(showPlan), to: menu)
        addMenuItem("设置…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addMenuItem("退出 FocusDesk", action: #selector(quit), key: "q", to: menu)
        item.menu = menu
        statusItem = item
    }

    private func updateVisibilityMenuItem() {
        visibilityMenuItem?.title = panel?.isVisible == true ? "隐藏悬浮窗" : "显示悬浮窗"
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

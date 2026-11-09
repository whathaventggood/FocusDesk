import AppKit

@main
struct FocusDeskApp {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.environment["FOCUSDESK_SMOKE_TEST"] != "1",
           let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) {
            application.run()
        }
    }
}

import AppKit

@main
struct FocusDeskApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) {
            application.run()
        }
    }
}

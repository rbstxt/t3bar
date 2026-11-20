import AppKit

@main
@MainActor
enum T3BarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let prefs = Preferences()
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController(store: store, prefs: prefs)
        store.start()
        // Development aid: open the popover once launched, for screenshots.
        if ProcessInfo.processInfo.environment["T3BAR_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.status?.showPopover() }
        }
        if let path = ProcessInfo.processInfo.environment["T3BAR_DUMP_ITEM"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.status?.dumpButton(to: path) }
        }
    }
}

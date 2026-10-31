import AppKit

/// The app lives in the menu bar. It has no Dock icon and no main window.
@main
@MainActor
enum AppMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

enum AppIdentity {
    /// Read from the bundle, so the name lives in one place: `scripts/app.env`.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MediaShift"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var queue = JobQueue(settings: settings)
    private lazy var wheel = WheelController(queue: queue, settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private lazy var statusItem = StatusItemController(
        queue: queue,
        settings: settings,
        openSettings: { [weak self] in self?.settingsWindow.show() }
    )
    private lazy var dragMonitor = DragMonitor(settings: settings) { [weak self] urls, location in
        self?.wheel.show(for: urls, at: location)
    } onDragEnded: { [weak self] in
        self?.wheel.dragEnded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
        dragMonitor.start()
        #if DEBUG
        showPreviewIfRequested()
        #endif
    }

    #if DEBUG
    /// Opens a surface without a drag and saves a picture of it, for visual checks:
    /// `MEDIASHIFT_PREVIEW=wheel:/path/a.docx:2`, `popover` or `settings`, with `MEDIASHIFT_SNAPSHOT=/path/out.png`.
    private func showPreviewIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["MEDIASHIFT_PREVIEW"] else { return }
        let parts = request.split(separator: ":").map(String.init)
        var window: () -> NSWindow? = { nil }
        switch parts.first {
        case "wheel":
            guard parts.count > 1, let screen = NSScreen.main else { return }
            wheel.show(for: [URL(fileURLWithPath: parts[1])], at: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
            if parts.count > 2, let index = Int(parts[2]) { wheel.previewHighlight(index) }
            window = { [wheel] in wheel.previewWindow }
        case "popover":
            // Real jobs, so the list shows real states: `popover:/path/a.md:/path/broken.docx`.
            for path in parts.dropFirst() {
                queue.add([URL(fileURLWithPath: path)], action: .convert(.pdf))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [statusItem] in statusItem.previewPopover() }
            window = { [statusItem] in statusItem.previewPopoverWindow }
        case "settings":
            settingsWindow.show()
            window = { [settingsWindow] in settingsWindow.previewWindow }
        default:
            return
        }
        guard let output = environment["MEDIASHIFT_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if let window = window() { WindowSnapshot.save(window, to: URL(fileURLWithPath: output)) }
            NSApp.terminate(nil)
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        queue.cancelAll()
    }
}

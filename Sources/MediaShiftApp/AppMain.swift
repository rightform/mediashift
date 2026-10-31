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
        NSApp.mainMenu = keyboardMenu()
        queue.onBatchFinished = { [weak self] outputs, hadFailure in self?.batchFinished(outputs, hadFailure: hadFailure) }
        statusItem.install()
        dragMonitor.start()
        #if DEBUG
        showPreviewIfRequested()
        #endif
    }

    /// A menu bar app never shows a main menu, but its shortcuts still work through one. Without
    /// it, paste into a settings field and Command-W on the settings window would do nothing.
    private func keyboardMenu() -> NSMenu {
        let application = NSMenu()
        application.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        application.addItem(withTitle: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let menu = NSMenu()
        for submenu in [application, edit, window] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    /// Acts once for a whole batch, so twenty files do not open twenty Finder windows.
    private func batchFinished(_ outputs: [URL], hadFailure: Bool) {
        if settings.playsSound { NSSound(named: hadFailure ? "Basso" : "Glass")?.play() }
        guard !outputs.isEmpty else { return }
        switch settings.finishAction {
        case .nothing:
            break
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        case .open:
            if outputs.count > 5 {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            } else {
                outputs.forEach { NSWorkspace.shared.open($0) }
            }
        }
    }

    #if DEBUG
    /// Opens a surface without a drag and saves a picture of it, for visual checks:
    /// `MEDIASHIFT_PREVIEW=wheel:/path/a.docx:2`, `popover` or `settings:wheel`, with `MEDIASHIFT_SNAPSHOT=/path/out.png`.
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
        case "chooser":
            let urls = parts.dropFirst().map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [statusItem] in statusItem.previewChooser(for: urls) }
            window = { [statusItem] in statusItem.previewPopoverWindow }
        case "toast":
            // A real job, so a broken file shows a real message: `toast:/path/broken.docx`.
            wheel.perform(.convert(.pdf), on: parts.dropFirst().map { URL(fileURLWithPath: $0) })
            window = { [wheel] in wheel.previewToastWindow }
        case "settings":
            settingsWindow.show(page: parts.count > 1 ? SettingsPage(rawValue: parts[1]) : nil)
            window = { [settingsWindow] in settingsWindow.previewWindow }
            // Turns on the options that add rows, to see the window follow: `settings:output:grow`.
            if parts.count > 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [settings] in
                    settings.usesTargetSize = true
                    settings.usesCustomImageQuality = true
                }
            }
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

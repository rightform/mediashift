import AppKit

/// Watches for file drags anywhere on screen. Mouse events can be observed globally without
/// the Accessibility permission, and the drag pasteboard names the files being dragged.
@MainActor
final class DragMonitor {
    private let settings: AppSettings
    private let onGesture: ([URL], NSPoint) -> Void
    private let onDragEnded: () -> Void
    private var monitors: [Any] = []
    private let pasteboard: NSPasteboard
    private var seenChangeCount: Int
    private var gestureActive = false

    init(
        settings: AppSettings,
        pasteboard: NSPasteboard = NSPasteboard(name: .drag),
        onGesture: @escaping ([URL], NSPoint) -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.onGesture = onGesture
        self.onDragEnded = onDragEnded
        seenChangeCount = pasteboard.changeCount
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDrag(modifiers: NSEvent.modifierFlags, location: NSEvent.mouseLocation) }
        }) {
            monitors.append(drag)
        }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseUp() }
        }) {
            monitors.append(up)
        }
    }

    func handleDrag(modifiers: NSEvent.ModifierFlags, location: NSPoint) {
        guard settings.wheelEnabled, !gestureActive else { return }
        guard modifiers.contains(settings.modifier.flag) else { return }
        // The pasteboard changes when a new drag begins. Without this check,
        // a drag of anything else would reopen the wheel for the previous files.
        guard pasteboard.changeCount != seenChangeCount else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        seenChangeCount = pasteboard.changeCount
        gestureActive = true
        onGesture(urls, location)
    }

    func handleMouseUp() {
        seenChangeCount = pasteboard.changeCount
        guard gestureActive else { return }
        gestureActive = false
        onDragEnded()
    }
}

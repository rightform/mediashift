import AppKit
import CoreGraphics

/// What a poll reads from the system. A plain value, so tests can drive a gesture without a mouse.
struct DragInput {
    var isButtonDown: Bool
    var modifiers: NSEvent.ModifierFlags
    var location: NSPoint

    /// The state at this moment. A menu bar app receives no key events of its own, so this asks
    /// the login session rather than anything that depends on events reaching the app.
    static var current: DragInput {
        DragInput(
            isButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)),
            location: NSEvent.mouseLocation
        )
    }
}

/// Watches for file drags anywhere on screen. Mouse events can be observed globally without
/// the Accessibility permission, and the drag pasteboard names the files being dragged.
///
/// Events only say that a button went down. From then until it comes up the state is polled,
/// because a key pressed while the pointer rests produces no mouse event at all, and asking only
/// on movement made a quick press of the key a matter of luck.
@MainActor
final class DragMonitor {
    /// Fast enough to catch a quick tap of the key. Runs only while the button is held.
    private static let pollInterval: TimeInterval = 1.0 / 30

    private let settings: AppSettings
    private let onGesture: ([URL], NSPoint) -> Void
    private let onDragEnded: () -> Void
    private var monitors: [Any] = []
    private let pasteboard: NSPasteboard
    private var seenChangeCount: Int
    private var gestureActive = false
    private var timer: Timer?
    private var activity: (any NSObjectProtocol)?

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

    var isPolling: Bool {
        timer != nil
    }

    func start() {
        guard monitors.isEmpty else { return }
        // A press landing on one of the app's own windows reports no mouse down, but the drag that follows it does.
        let events: [NSEvent.EventTypeMask] = [.leftMouseDown, .leftMouseDragged]
        for event in events {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: event, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.startPolling() }
            }) {
                monitors.append(monitor)
            }
        }
    }

    func startPolling() {
        guard timer == nil else { return }
        // A menu bar app is a candidate for App Nap, which would stretch the timer past a quick tap.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInteractive, reason: "Following a drag")
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(.current) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll(.current)
    }

    func poll(_ input: DragInput) {
        guard input.isButtonDown else {
            buttonReleased()
            return
        }
        guard settings.wheelEnabled, !gestureActive else { return }
        guard input.modifiers.contains(settings.modifier.flag) else { return }
        // The pasteboard changes when a new drag begins. Without this check,
        // a drag of anything else would reopen the wheel for the previous files.
        guard pasteboard.changeCount != seenChangeCount else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        seenChangeCount = pasteboard.changeCount
        gestureActive = true
        onGesture(urls, input.location)
    }

    private func buttonReleased() {
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        seenChangeCount = pasteboard.changeCount
        guard gestureActive else { return }
        gestureActive = false
        onDragEnded()
    }
}

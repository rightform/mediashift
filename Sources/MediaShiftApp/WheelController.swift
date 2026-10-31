import AppKit
import ConversionKit
import SwiftUI

/// Shows the wheel during a drag and turns a drop on it into jobs.
@MainActor
final class WheelController {
    private let queue: JobQueue
    private let settings: AppSettings
    private var panel: NSPanel?
    private var model: WheelModel?
    private var toast: ToastController?

    init(queue: JobQueue, settings: AppSettings) {
        self.queue = queue
        self.settings = settings
    }

    /// `location` is in screen coordinates. The wheel opens centred there, moved only as far as
    /// needed to stay on screen, so the pointer always starts on the cancel hub.
    func show(for urls: [URL], at location: NSPoint) {
        close(animated: false)
        let actions = ConversionCatalog.actions(for: urls)
        let model = WheelModel(urls: urls, actions: actions)
        self.model = model

        let size = NSSize(width: model.diameter, height: model.diameter)
        var origin = NSPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let dropView = WheelDropView(model: model) { [weak self] urls, action in
            self?.perform(action, on: urls)
        }
        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        // The drop view sits on top: it does all the hit testing, the hosting view only draws.
        panel.contentView = dropView
        dropView.addSubview(hosting, positioned: .below, relativeTo: nil)
        panel.orderFrontRegardless()
        self.panel = panel

        DispatchQueue.main.async { model.isVisible = true }
    }

    #if DEBUG
    func previewHighlight(_ index: Int) {
        model?.highlighted = index
    }

    var previewWindow: NSWindow? {
        panel
    }
    #endif

    /// The mouse went up. A drop on a slice may still be on its way: the global mouse event and
    /// the drop arrive in no fixed order, and a closed panel could not receive the drop.
    /// So the panel stays for a moment, and a drop that does arrive closes it sooner.
    func dragEnded() {
        let ending = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, ending != nil, self.panel === ending else { return }
            self.close(animated: true)
        }
    }

    func perform(_ action: ConversionAction, on urls: [URL]) {
        let location = NSEvent.mouseLocation
        close(animated: true)
        let jobs = queue.add(urls, action: action)
        showToast(for: jobs, near: location)
    }

    private func showToast(for jobs: [ConversionJob], near location: NSPoint) {
        toast?.close()
        let toast = ToastController(jobs: jobs, location: location) { [weak self] in self?.toast = nil }
        toast.show()
        self.toast = toast
    }

    private func close(animated: Bool) {
        guard let panel else { return }
        self.panel = nil
        let model = self.model
        self.model = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.close()
            return
        }
        model?.isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { panel.close() }
    }
}

/// Receives the system drag and decides which slice the pointer is in.
final class WheelDropView: NSView {
    private let model: WheelModel
    private let onDrop: ([URL], ConversionAction) -> Void

    init(model: WheelModel, onDrop: @escaping ([URL], ConversionAction) -> Void) {
        self.model = model
        self.onDrop = onDrop
        super.init(frame: NSRect(x: 0, y: 0, width: model.diameter, height: model.diameter))
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setHighlight(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        slice(for: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let index = slice(for: sender) else { return false }
        onDrop(model.urls, model.actions[index])
        return true
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let index = slice(for: sender)
        setHighlight(index)
        return index == nil ? [] : .copy
    }

    private func slice(for sender: any NSDraggingInfo) -> Int? {
        let point = convert(sender.draggingLocation, from: nil)
        return model.index(atOffset: CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY))
    }

    private func setHighlight(_ index: Int?) {
        guard model.highlighted != index else { return }
        model.highlighted = index
        if index != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

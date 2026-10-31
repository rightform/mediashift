import AppKit
import ConversionKit
import Observation
import SwiftUI

/// The menu bar icon: shows progress, accepts drops and opens the list.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let queue: JobQueue
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let popoverModel = PopoverModel()
    private var statusItem: NSStatusItem?
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hosting = NSHostingController(
            rootView: PopoverView(
                queue: queue,
                settings: settings,
                model: popoverModel,
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSettings()
                },
                chooseFiles: { [weak self] in self?.chooseFiles() }
            ))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        return popover
    }()

    init(queue: JobQueue, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.queue = queue
        self.settings = settings
        self.openSettings = openSettings
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.image = StatusIcon.idle
        button.setAccessibilityLabel(AppIdentity.name)
        button.target = self
        button.action = #selector(togglePopover)

        // The button keeps its clicks. Drags go through its window, which forwards them here.
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
        observeQueue()
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        showChooser(for: urls)
        return true
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func chooseFiles() {
        popover.performClose(nil)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            showChooser(for: panel.urls)
        }
    }

    #if DEBUG
    func previewPopover() {
        openPopover()
    }

    func previewChooser(for urls: [URL]) {
        showChooser(for: urls)
    }

    var previewPopoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    var statusWindow: NSWindow? {
        statusItem?.button?.window
    }

    var pendingFiles: [URL] {
        popoverModel.pendingFiles
    }

    var isPopoverShown: Bool {
        popover.isShown
    }

    func uninstall() {
        popover.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
    #endif

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverModel.pendingFiles = []
            openPopover()
        }
    }

    private func showChooser(for urls: [URL]) {
        popoverModel.pendingFiles = urls
        openPopover()
    }

    private func openPopover() {
        guard let button = statusItem?.button else { return }
        queue.hasUnseenFailure = false
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Redraws the icon whenever anything it depends on changes.
    private func observeQueue() {
        withObservationTracking {
            updateIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeQueue() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        // Touches both, so that observation tracks them whichever branch runs.
        let failure = queue.hasUnseenFailure
        if let progress = queue.overallProgress {
            button.image = StatusIcon.progress(progress)
            button.setAccessibilityValue("Working, \(Int(progress * 100)) percent")
        } else if failure {
            button.image = StatusIcon.failure
            button.setAccessibilityValue("A conversion failed")
        } else {
            button.image = StatusIcon.idle
            button.setAccessibilityValue(nil)
        }
    }
}

/// Draws the icon as a template image, so the system handles light, dark and tinted menu bars.
enum StatusIcon {
    private static let size = NSSize(width: 18, height: 18)

    static let idle = draw { rect in
        // The wheel from the app's main gesture: a hub and a ring of slices.
        let center = NSPoint(x: rect.midX, y: rect.midY)
        NSBezierPath(ovalIn: rect.insetBy(dx: 6.75, dy: 6.75)).fill()
        for index in 0..<6 {
            let angle = CGFloat(index) / 6 * 2 * .pi
            let dot = NSPoint(x: center.x + sin(angle) * 6.6, y: center.y + cos(angle) * 6.6)
            NSBezierPath(ovalIn: NSRect(x: dot.x - 1.45, y: dot.y - 1.45, width: 2.9, height: 2.9)).fill()
        }
    }

    static let failure: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Failed") ?? idle
        image.isTemplate = true
        return image
    }()

    static func progress(_ value: Double) -> NSImage {
        draw { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            arc.appendArc(
                withCenter: center,
                radius: inset.width / 2,
                startAngle: 90,
                endAngle: 90 - CGFloat(max(value, 0.03)) * 360,
                clockwise: true
            )
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }
    }

    private static func draw(_ body: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            body(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

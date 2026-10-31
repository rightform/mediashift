import AppKit
import ConversionKit
import Foundation
import Testing

@testable import MediaShiftApp

@MainActor
private func model(actions count: Int) -> WheelModel {
    let all = Array(ConversionCatalog.actions(for: .jpeg).prefix(count))
    return WheelModel(urls: [URL(fileURLWithPath: "/a.jpg")], actions: all)
}

@MainActor
@Test func theHubIsACancelZone() {
    let wheel = model(actions: 8)
    #expect(wheel.index(atOffset: .zero) == nil)
    #expect(wheel.index(atOffset: CGPoint(x: 0, y: WheelModel.hubRadius - 1)) == nil)
    #expect(wheel.index(atOffset: CGPoint(x: 0, y: WheelModel.hubRadius + 1)) != nil)
}

@MainActor
@Test func slicesFollowDirectionClockwiseFromTheTop() {
    let wheel = model(actions: 4)
    // AppKit's y axis points up.
    #expect(wheel.index(atOffset: CGPoint(x: 0, y: 200)) == 0)
    #expect(wheel.index(atOffset: CGPoint(x: 200, y: 0)) == 1)
    #expect(wheel.index(atOffset: CGPoint(x: 0, y: -200)) == 2)
    #expect(wheel.index(atOffset: CGPoint(x: -200, y: 0)) == 3)
}

@MainActor
@Test func theFirstSliceWrapsAroundTheTop() {
    let wheel = model(actions: 8)
    #expect(wheel.index(atOffset: CGPoint(x: -20, y: 200)) == 0)
    #expect(wheel.index(atOffset: CGPoint(x: 20, y: 200)) == 0)
}

@MainActor
@Test func everyChipSitsInsideItsOwnSlice() {
    for count in 1...12 {
        let wheel = model(actions: count)
        for index in 0..<wheel.actions.count {
            let offset = wheel.offset(of: index)
            // Chip offsets are y-down, slices y-up.
            #expect(wheel.index(atOffset: CGPoint(x: offset.width, y: -offset.height)) == index, "\(count) actions, chip \(index)")
        }
    }
}

@MainActor
@Test func chipsNeverLeaveThePanelOrOverlapTheHub() {
    for count in 1...12 {
        let wheel = model(actions: count)
        let half = wheel.diameter / 2
        #expect(wheel.ringRadius - WheelModel.chipSize.width / 2 >= WheelModel.hubRadius, "\(count) actions")
        for index in 0..<wheel.actions.count {
            let offset = wheel.offset(of: index)
            #expect(abs(offset.width) + WheelModel.chipSize.width / 2 <= half)
            #expect(abs(offset.height) + WheelModel.chipSize.height / 2 <= half)
        }
    }
}

@MainActor
@Test func theHubNamesTheOutcomeBeforeTheDrop() {
    let wheel = WheelModel(urls: [URL(fileURLWithPath: "/a.docx")], actions: [.convert(.pdf), .compress])
    #expect(wheel.hubTitle == "a.docx")
    wheel.highlighted = 0
    #expect(wheel.hubTitle == "Convert to PDF")
}

// MARK: - Dragging

/// Stands in for the system's drag session, which only exists during a real mouse drag.
private final class FakeDrag: NSObject, NSDraggingInfo {
    var draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard

    @MainActor
    init(location: NSPoint, pasteboard: NSPasteboard = .withUniqueName()) {
        draggingLocation = location
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

@MainActor
@Test func droppingOnASliceStartsThatAction() {
    let files = [URL(fileURLWithPath: "/a.docx")]
    let wheel = WheelModel(urls: files, actions: [.convert(.pdf), .convert(.md), .compress, .stripMetadata])
    var dropped: ([URL], ConversionAction)?
    let view = WheelDropView(model: wheel) { dropped = ($0, $1) }
    let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)

    // Straight right is the second of four slices. Passing over it highlights without starting.
    let drag = FakeDrag(location: NSPoint(x: center.x + 120, y: center.y))
    #expect(view.draggingUpdated(drag) == .copy)
    #expect(wheel.highlighted == 1)
    #expect(dropped == nil)

    #expect(view.prepareForDragOperation(drag))
    #expect(view.performDragOperation(drag))
    #expect(dropped?.0 == files)
    #expect(dropped?.1 == .convert(.md))
}

@MainActor
@Test func releasingOnTheHubOrLeavingCancels() {
    let wheel = WheelModel(urls: [URL(fileURLWithPath: "/a.docx")], actions: [.convert(.pdf)])
    var didDrop = false
    let view = WheelDropView(model: wheel) { _, _ in didDrop = true }
    let hub = FakeDrag(location: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
    #expect(view.draggingUpdated(hub) == [])
    #expect(!view.prepareForDragOperation(hub))
    #expect(!view.performDragOperation(hub))
    #expect(!didDrop)

    wheel.highlighted = 0
    view.draggingExited(hub)
    #expect(wheel.highlighted == nil)
}

@MainActor
@Test func theGestureNeedsTheModifierAndNewFiles() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let settings = AppSettings()
    settings.wheelEnabled = true
    settings.modifier = .shift
    var shown: [[URL]] = []
    var ended = 0
    let monitor = DragMonitor(settings: settings, pasteboard: pasteboard) { urls, _ in shown.append(urls) } onDragEnded: { ended += 1 }

    func beginDrag(_ url: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    // A drag without the modifier opens nothing.
    beginDrag(URL(fileURLWithPath: "/a.docx"))
    monitor.handleDrag(modifiers: [], location: .zero)
    #expect(shown.isEmpty)

    // Pressing it during the same drag does, once, however many mouse events follow.
    monitor.handleDrag(modifiers: .shift, location: .zero)
    monitor.handleDrag(modifiers: .shift, location: .zero)
    #expect(shown.count == 1)
    monitor.handleMouseUp()
    #expect(ended == 1)

    // A later drag of something else must not reopen the wheel for the old files.
    monitor.handleDrag(modifiers: .shift, location: .zero)
    #expect(shown.count == 1)

    beginDrag(URL(fileURLWithPath: "/b.docx"))
    monitor.handleDrag(modifiers: .shift, location: .zero)
    #expect(shown.count == 2)
    #expect(shown[1].first?.lastPathComponent == "b.docx")
    monitor.handleMouseUp()

    // Dragging text instead of files is none of the app's business.
    pasteboard.clearContents()
    pasteboard.setString("hello", forType: .string)
    monitor.handleDrag(modifiers: .shift, location: .zero)
    #expect(shown.count == 2)
}

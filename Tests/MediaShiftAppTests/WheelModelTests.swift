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

/// Every set of actions the wheel can really show, one per format, plus a few by count.
@MainActor
private func everyRealWheel() -> [WheelModel] {
    let byFormat = FileFormat.allCases.map { format in
        WheelModel(urls: [URL(fileURLWithPath: "/a.\(format.fileExtension)")], actions: ConversionCatalog.actions(for: format))
    }
    return byFormat + (1...4).map { model(actions: $0) }
}

/// The shortest distance from the wheel's centre to a chip.
private func distanceToCentre(_ frame: CGRect) -> CGFloat {
    let x = max(frame.minX, min(0, frame.maxX))
    let y = max(frame.minY, min(0, frame.maxY))
    return hypot(x, y)
}

@MainActor
@Test func chipsNeverLeaveThePanelOrTouchTheHubOrEachOther() {
    for wheel in everyRealWheel() {
        let name = wheel.urls[0].pathExtension
        let half = wheel.diameter / 2
        let frames = wheel.actions.indices.map(wheel.chipFrame)
        for (index, frame) in frames.enumerated() {
            #expect(abs(frame.minX) <= half && abs(frame.maxX) <= half, "\(name) chip \(index)")
            #expect(abs(frame.minY) <= half && abs(frame.maxY) <= half, "\(name) chip \(index)")
            #expect(distanceToCentre(frame) > WheelModel.hubRadius, "\(name) chip \(index)")
            for other in frames[(index + 1)...] {
                #expect(!frame.intersects(other), "\(name) chip \(index)")
            }
        }
    }
}

@MainActor
@Test func neighbouringChipsKeepAGap() {
    for wheel in everyRealWheel() where wheel.actions.count > 1 {
        let frames = wheel.actions.indices.map(wheel.chipFrame)
        for index in frames.indices {
            let next = frames[(index + 1) % frames.count]
            // A highlighted chip grows a little, and must still not touch the next one.
            #expect(!frames[index].insetBy(dx: -4, dy: -4).intersects(next.insetBy(dx: -4, dy: -4)), "\(wheel.urls[0].pathExtension) chip \(index)")
        }
    }
}

@MainActor
@Test func everyLabelFitsItsChip() {
    let font = NSFont.systemFont(ofSize: WheelModel.chipFontSize, weight: .semibold)
    var actions = FileFormat.allCases.map(ConversionAction.convert)
    actions += [.compress, .stripMetadata]
    for action in actions {
        let text = (action.chipLabel as NSString).size(withAttributes: [.font: font]).width
        let symbol: CGFloat = action.symbolName == nil ? 0 : 19
        #expect(text + symbol + 16 <= WheelModel.chipWidth(for: action), "\(action.chipLabel)")
    }
}

@MainActor
@Test func aPointerOnAChipMeansThatChip() {
    for wheel in everyRealWheel() {
        for index in wheel.actions.indices {
            let frame = wheel.chipFrame(of: index)
            // Chip frames are y-down, the question is asked y-up. Corners are where a wide chip leaves its slice.
            for corner in [CGPoint(x: frame.minX + 1, y: frame.minY + 1), CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)] {
                guard hypot(corner.x, corner.y) > WheelModel.hubRadius else { continue }
                #expect(wheel.index(atOffset: CGPoint(x: corner.x, y: -corner.y)) == index, "\(wheel.urls[0].pathExtension) chip \(index)")
            }
        }
    }
}

/// Lines of a string wrapped to the hub's text width.
@MainActor
private func lineCount(_ text: String, font: NSFont) -> Int {
    let box = (text as NSString).boundingRect(
        with: NSSize(width: WheelModel.hubTextWidth, height: 1000),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font]
    )
    return Int((box.height / (font.ascender - font.descender + font.leading)).rounded())
}

@MainActor
@Test func theHubsTextStaysInsideItsCircle() {
    let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let subtitleFont = NSFont.systemFont(ofSize: 11)

    var wheels = everyRealWheel()
    wheels.append(WheelModel(urls: [URL(fileURLWithPath: "/a.zip")], actions: []))
    wheels.append(WheelModel(urls: (1...128).map { URL(fileURLWithPath: "/\($0).zip") }, actions: []))
    wheels.append(WheelModel(urls: (1...128).map { URL(fileURLWithPath: "/\($0).jpg") }, actions: [.convert(.png)]))

    for wheel in wheels {
        for highlight in [nil] + wheel.actions.indices.map(Optional.some) {
            wheel.highlighted = highlight
            // The subtitle is the bottom line, kept to one so it cannot run past the curve.
            #expect(lineCount(wheel.hubSubtitle, font: subtitleFont) == 1, "\(wheel.hubSubtitle)")
            if highlight != nil {
                #expect(lineCount(wheel.hubTitle, font: titleFont) <= 2, "\(wheel.hubTitle)")
            }
        }
    }

    // Icon, two lines of title, one of subtitle, and the gaps between them: the corners of that
    // block have to be inside the circle.
    let height = 32 + 2 + 2 * ceil(titleFont.ascender - titleFont.descender) + 2 + ceil(subtitleFont.ascender - subtitleFont.descender)
    #expect(hypot(WheelModel.hubTextWidth / 2, height / 2) < WheelModel.hubRadius)
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

/// A monitor with a private pasteboard and a record of what it did.
@MainActor
private final class GestureRig {
    let pasteboard = NSPasteboard.withUniqueName()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "MediaShiftTests-\(UUID().uuidString)")!)
    var shown: [[URL]] = []
    var locations: [NSPoint] = []
    var ended = 0
    private(set) lazy var monitor = DragMonitor(settings: settings, pasteboard: pasteboard) { [unowned self] urls, location in
        shown.append(urls)
        locations.append(location)
    } onDragEnded: { [unowned self] in
        ended += 1
    }

    /// Made now, like in the app: it starts counting drags from the moment it exists.
    init() {
        _ = monitor
    }

    func beginDrag(_ url: URL = URL(fileURLWithPath: "/a.docx")) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    /// One look at the system's state. Nothing here needs the pointer to have moved.
    func held(_ modifiers: NSEvent.ModifierFlags = [], at location: NSPoint = .zero) {
        monitor.poll(DragInput(isButtonDown: true, modifiers: modifiers, location: location))
    }

    func released() {
        monitor.poll(DragInput(isButtonDown: false, modifiers: [], location: .zero))
    }
}

@MainActor
@Test func theGestureNeedsTheModifierAndNewFiles() {
    let rig = GestureRig()
    defer { rig.pasteboard.releaseGlobally() }

    // A drag without the modifier opens nothing.
    rig.beginDrag()
    rig.held()
    #expect(rig.shown.isEmpty)

    // Pressing it during the same drag does, once, however long it is held.
    rig.held(.shift)
    rig.held(.shift)
    #expect(rig.shown.count == 1)
    rig.released()
    #expect(rig.ended == 1)

    // A later drag of something else must not reopen the wheel for the old files.
    rig.held(.shift)
    #expect(rig.shown.count == 1)

    rig.beginDrag(URL(fileURLWithPath: "/b.docx"))
    rig.held(.shift)
    #expect(rig.shown.count == 2)
    #expect(rig.shown[1].first?.lastPathComponent == "b.docx")
    rig.released()

    // Dragging text instead of files is none of the app's business.
    rig.pasteboard.clearContents()
    rig.pasteboard.setString("hello", forType: .string)
    rig.held(.shift)
    #expect(rig.shown.count == 2)
}

@MainActor
@Test func theKeyWorksWhileThePointerRests() {
    let rig = GestureRig()
    defer { rig.pasteboard.releaseGlobally() }
    let still = NSPoint(x: 300, y: 200)

    rig.beginDrag()
    rig.held(at: still)
    rig.held(at: still)
    #expect(rig.shown.isEmpty)

    // The bug this guards against: a key press alone produces no mouse event.
    rig.held(.shift, at: still)
    #expect(rig.shown.count == 1)
    #expect(rig.locations == [still])
}

@MainActor
@Test func aQuickTapIsEnoughAndTheWheelStaysUntilRelease() {
    let rig = GestureRig()
    defer { rig.pasteboard.releaseGlobally() }

    rig.beginDrag()
    rig.held(.shift)
    #expect(rig.shown.count == 1)

    // The key is up again, and the file is still in hand.
    rig.held()
    rig.held()
    #expect(rig.ended == 0)

    rig.released()
    #expect(rig.ended == 1)
}

@MainActor
@Test func theKeyBeforeThePressWorksToo() {
    let rig = GestureRig()
    defer { rig.pasteboard.releaseGlobally() }

    // Held from the start, before anything has been picked up.
    rig.held(.shift)
    #expect(rig.shown.isEmpty)
    rig.beginDrag()
    rig.held(.shift)
    #expect(rig.shown.count == 1)
}

@MainActor
@Test func otherModifiersAloneDoNotCount() {
    let rig = GestureRig()
    defer { rig.pasteboard.releaseGlobally() }
    rig.settings.modifier = .command

    rig.beginDrag()
    rig.held(.shift)
    #expect(rig.shown.isEmpty)
    rig.held([.command, .shift])
    #expect(rig.shown.count == 1)
}

@MainActor
@Test func theWheelCanBeSwitchedOff() {
    let rig = GestureRig()
    defer { rig.pasteboard.releaseGlobally() }
    rig.settings.wheelEnabled = false

    rig.beginDrag()
    rig.held(.shift)
    #expect(rig.shown.isEmpty)
}

@MainActor
@Test func pollingEndsAsSoonAsNoButtonIsHeld() {
    let rig = GestureRig()
    defer { rig.pasteboard.releaseGlobally() }

    // No button is down while tests run, so the first look stops it again.
    rig.monitor.startPolling()
    #expect(!rig.monitor.isPolling)
}

// MARK: - The menu bar icon

/// Goes through the real status item's window, so AppKit's forwarding to the delegate is part of
/// the test. Only the system's delivery of a real mouse drag to that window is not.
private typealias DragQuery = @convention(c) (AnyObject, Selector, AnyObject) -> UInt
private typealias DragCommand = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

@MainActor
private func dragOperation(onto window: NSWindow, _ drag: FakeDrag) -> NSDragOperation {
    let selector = #selector(NSDraggingDestination.draggingEntered(_:))
    return NSDragOperation(rawValue: unsafeBitCast(window.method(for: selector), to: DragQuery.self)(window, selector, drag))
}

@MainActor
private func perform(_ selector: Selector, on window: NSWindow, _ drag: FakeDrag) -> Bool {
    unsafeBitCast(window.method(for: selector), to: DragCommand.self)(window, selector, drag)
}

/// A real icon in the menu bar. Set up as the app is, because a process with the default
/// activation policy may not show the popover at all.
@MainActor
private func installedIcon() -> StatusItemController {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let settings = AppSettings(defaults: UserDefaults(suiteName: "MediaShiftTests-\(UUID().uuidString)")!)
    let controller = StatusItemController(queue: JobQueue(settings: settings), settings: settings, openSettings: {})
    controller.install()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return controller
}

@MainActor
@Test func aDropOnTheMenuBarIconOffersWhatToDoWithTheFiles() throws {
    let controller = installedIcon()
    defer { controller.uninstall() }

    let window = try #require(controller.statusWindow)
    #expect(window.delegate === controller)
    let entered = #selector(NSDraggingDestination.draggingEntered(_:))
    let dropped = #selector(NSDraggingDestination.performDragOperation(_:))
    #expect(window.responds(to: entered))
    #expect(window.responds(to: dropped))

    let files = [URL(fileURLWithPath: "/tmp/a.docx"), URL(fileURLWithPath: "/tmp/b.jpg")]
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects(files as [NSURL])
    let drag = FakeDrag(location: .zero, pasteboard: pasteboard)

    #expect(dragOperation(onto: window, drag) == .copy)
    #expect(controller.pendingFiles.isEmpty)
    #expect(perform(dropped, on: window, drag))
    #expect(controller.pendingFiles == files)
    #expect(controller.isPopoverShown)

    // The app that started the drag is still in front, and the list has to stay open anyway.
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    #expect(controller.isPopoverShown)
}

@MainActor
@Test func theMenuBarIconIgnoresDragsWithoutFiles() throws {
    let controller = installedIcon()
    defer { controller.uninstall() }

    let window = try #require(controller.statusWindow)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("hello", forType: .string)
    let drag = FakeDrag(location: .zero, pasteboard: pasteboard)

    #expect(dragOperation(onto: window, drag) == [])
    #expect(!perform(#selector(NSDraggingDestination.performDragOperation(_:)), on: window, drag))
    #expect(controller.pendingFiles.isEmpty)
    #expect(!controller.isPopoverShown)
}

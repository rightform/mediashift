import AppKit
import ConversionKit
import Observation

/// The ring's geometry and state. Targets are whole slices of the circle rather than the chips
/// drawn on them, so aiming is forgiving: direction decides, not precision.
@MainActor
@Observable
final class WheelModel {
    let urls: [URL]
    let actions: [ConversionAction]
    var highlighted: Int?
    var isVisible = false

    /// Releasing inside this radius cancels, and it is where the drag starts.
    static let hubRadius: CGFloat = 62
    static let chipSize = CGSize(width: 76, height: 42)

    init(urls: [URL], actions: [ConversionAction]) {
        self.urls = urls
        self.actions = actions
    }

    /// Grows with the number of targets so chips never touch.
    var ringRadius: CGFloat {
        let minimum = CGFloat(actions.count) * (Self.chipSize.width + 8) / (2 * .pi)
        return max(minimum, Self.hubRadius + Self.chipSize.width / 2 + 18)
    }

    /// The panel's side, with room around the outermost chips for their shadow and hover growth.
    var diameter: CGFloat {
        (ringRadius + Self.chipSize.width / 2 + 28) * 2
    }

    /// Angle of a slice in radians, clockwise from 12 o'clock.
    func angle(of index: Int) -> CGFloat {
        CGFloat(index) / CGFloat(max(actions.count, 1)) * 2 * .pi
    }

    /// Offset of a chip from the centre, in SwiftUI's y-down coordinates.
    func offset(of index: Int) -> CGSize {
        let angle = angle(of: index)
        return CGSize(width: sin(angle) * ringRadius, height: -cos(angle) * ringRadius)
    }

    /// The slice under a point given relative to the centre, in AppKit's y-up coordinates.
    func index(atOffset point: CGPoint) -> Int? {
        guard !actions.isEmpty, hypot(point.x, point.y) > Self.hubRadius else { return nil }
        var angle = atan2(point.x, point.y)
        if angle < 0 { angle += 2 * .pi }
        let slice = 2 * .pi / CGFloat(actions.count)
        return Int((angle + slice / 2) / slice) % actions.count
    }

    /// What the hub says. Names the outcome before the person commits to it.
    var hubTitle: String {
        if let highlighted { return actions[highlighted].title }
        if urls.count == 1 { return urls[0].lastPathComponent }
        return "\(urls.count) files"
    }

    var hubSubtitle: String {
        if highlighted != nil { return urls.count == 1 ? "Release to start" : "Release to start all \(urls.count)" }
        return actions.isEmpty ? "Nothing common to all of these" : "Release here to cancel"
    }
}

extension ConversionAction {
    /// The chip's text. Formats are recognizable by name, so only tools get a symbol.
    var chipLabel: String {
        switch self {
        case .convert(let format): format == .md ? "MD" : format.label
        case .compress: "Compress"
        case .stripMetadata: "Clean"
        }
    }

    var symbolName: String? {
        switch self {
        case .convert: nil
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .stripMetadata: "eye.slash"
        }
    }
}

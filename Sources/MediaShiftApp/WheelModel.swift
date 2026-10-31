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
    static let hubRadius: CGFloat = 76
    /// The hub's text stays within this width, which fits the circle at the height the text sits.
    static let hubTextWidth: CGFloat = 116
    static let chipHeight: CGFloat = 40
    static let chipFontSize: CGFloat = 13
    private static let minimumChipWidth: CGFloat = 64
    private static let chipPadding: CGFloat = 14
    /// A tool's symbol and the space after it.
    private static let symbolWidth: CGFloat = 20
    /// Enough that a highlighted chip, which grows a little, still clears its neighbours.
    private static let chipGap: CGFloat = 12
    /// Room around the outermost chips for their growth when highlighted.
    private static let panelMargin: CGFloat = 20

    /// One per action, each as wide as its own text needs.
    let chipWidths: [CGFloat]
    let ringRadius: CGFloat

    init(urls: [URL], actions: [ConversionAction]) {
        self.urls = urls
        self.actions = actions
        chipWidths = actions.map(Self.chipWidth)
        ringRadius = Self.ringRadius(for: chipWidths)
    }

    /// Measured, so no label can be cut off or stick out of its chip.
    static func chipWidth(for action: ConversionAction) -> CGFloat {
        let font = NSFont.systemFont(ofSize: chipFontSize, weight: .semibold)
        let text = (action.chipLabel as NSString).size(withAttributes: [.font: font]).width
        let symbol = action.symbolName == nil ? 0 : symbolWidth
        return max(minimumChipWidth, (text + symbol + chipPadding * 2).rounded(.up))
    }

    /// The smallest ring on which every chip clears the hub and both of its neighbours.
    private static func ringRadius(for widths: [CGFloat]) -> CGFloat {
        let widest = widths.max() ?? minimumChipWidth
        var radius = hubRadius + widest / 2 + chipGap
        while !chipsFit(widths, on: radius) {
            radius += 2
        }
        return radius
    }

    private static func chipsFit(_ widths: [CGFloat], on radius: CGFloat) -> Bool {
        guard widths.count > 1 else { return true }
        let frames = widths.indices.map { frame(ofChip: $0, widths: widths, radius: radius) }
        return frames.indices.allSatisfy { index in
            let next = frames[(index + 1) % frames.count]
            return !frames[index].insetBy(dx: -chipGap / 2, dy: -chipGap / 2).intersects(next.insetBy(dx: -chipGap / 2, dy: -chipGap / 2))
        }
    }

    private static func frame(ofChip index: Int, widths: [CGFloat], radius: CGFloat) -> CGRect {
        let center = center(ofChip: index, count: widths.count, radius: radius)
        return CGRect(x: center.x - widths[index] / 2, y: center.y - chipHeight / 2, width: widths[index], height: chipHeight)
    }

    /// On whole points, so labels are drawn sharp rather than between pixels.
    private static func center(ofChip index: Int, count: Int, radius: CGFloat) -> CGPoint {
        let angle = CGFloat(index) / CGFloat(max(count, 1)) * 2 * .pi
        return CGPoint(x: (sin(angle) * radius).rounded(), y: (-cos(angle) * radius).rounded())
    }

    /// A chip's place relative to the centre, in SwiftUI's y-down coordinates.
    func chipFrame(of index: Int) -> CGRect {
        Self.frame(ofChip: index, widths: chipWidths, radius: ringRadius)
    }

    /// The panel's side.
    var diameter: CGFloat {
        (ringRadius + (chipWidths.max() ?? Self.minimumChipWidth) / 2 + Self.panelMargin) * 2
    }

    /// Offset of a chip from the centre, in SwiftUI's y-down coordinates.
    func offset(of index: Int) -> CGSize {
        let center = Self.center(ofChip: index, count: actions.count, radius: ringRadius)
        return CGSize(width: center.x, height: center.y)
    }

    /// The slice under a point given relative to the centre, in AppKit's y-up coordinates.
    /// A pointer on a chip always means that chip, even where a wide one reaches past its slice.
    func index(atOffset point: CGPoint) -> Int? {
        guard !actions.isEmpty, hypot(point.x, point.y) > Self.hubRadius else { return nil }
        let flipped = CGPoint(x: point.x, y: -point.y)
        if let chip = actions.indices.first(where: { chipFrame(of: $0).contains(flipped) }) {
            return chip
        }
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
        if highlighted != nil { return urls.count == 1 ? "Release to start" : "Release for all \(urls.count)" }
        if actions.isEmpty { return urls.count == 1 ? "No options for this" : "No shared options" }
        return "Release to cancel"
    }
}

extension ConversionAction {
    /// The chip's text. Formats are recognizable by name, so only tools get a symbol.
    var chipLabel: String {
        switch self {
        case .convert(let format): format.label
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

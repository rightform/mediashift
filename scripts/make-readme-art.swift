// Draws the README's artwork in the style of rightform.pl, for GitHub's light and dark themes.
// GitHub shows these as plain images with no web fonts, so all text becomes outlines.
// The logo inside the hero is the official file, already in the output folder.
// The README picks between the two themes with #gh-light-mode-only and #gh-dark-mode-only, because
// a <picture> follows the system, which can differ from the theme chosen on GitHub. GitHub hides
// such an image through the address of the link around it, so an image that links somewhere else
// cannot switch. That is why the buttons come in one version that reads on both themes.
// usage: swift scripts/make-readme-art.swift path/to/instrument-sans.woff2 docs/brand
import CoreText
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift scripts/make-readme-art.swift path/to/instrument-sans.woff2 docs/brand")
    exit(1)
}
let fontData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let fontDescriptor = CTFontManagerCreateFontDescriptorFromData(fontData as CFData) else {
    print("error: could not read the font")
    exit(1)
}

/// The site's and the brand book's colors, one set per GitHub theme.
struct Theme {
    let name: String
    let ink: String
    let muted: String
    let line: String
    let surface: String
    let stage: String
    let mark: String
    let accent: String
    let button: String
    let buttonText: String
    let chip: String
    let chipLine: String
    let chipText: String
    let logo: String
}

let themes = [
    Theme(
        name: "light", ink: "#1f1d1a", muted: "#6b655c", line: "#e2dcd2", surface: "#ffffff", stage: "#faf7f2",
        mark: "#f3dfd3", accent: "#b4552f", button: "#953f1f", buttonText: "#ffffff",
        chip: "#1f1d1a", chipLine: "#1f1d1a", chipText: "#f2eee7", logo: "rightform-logo.png"
    ),
    Theme(
        name: "dark", ink: "#f2eee7", muted: "#a69e92", line: "#332f29", surface: "#1f1d1a", stage: "#171512",
        mark: "#5a3322", accent: "#d8673a", button: "#d8673a", buttonText: "#171512",
        chip: "#2c2823", chipLine: "#4a443b", chipText: "#f2eee7", logo: "rightform-logo-dark.png"
    ),
]

// MARK: - Text as outlines

func font(_ size: CGFloat, _ weight: CGFloat) -> CTFont {
    let weightAxis = 0x7767_6874 // 'wght'
    let attributes = [kCTFontVariationAttribute: [weightAxis: weight]] as CFDictionary
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(fontDescriptor, attributes)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

func num(_ value: CGFloat) -> String {
    let text = String(format: "%.2f", value)
    return text.hasSuffix(".00") ? String(text.dropLast(3)) : text
}

func makeLine(_ text: String, _ font: CTFont, tracking: CGFloat) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking * CTFontGetSize(font),
    ]))
}

func measure(_ text: String, _ font: CTFont, tracking: CGFloat = 0) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(makeLine(text, font, tracking: tracking), nil, nil, nil))
}

func glyphPath(_ text: String, _ font: CTFont, x originX: CGFloat, y originY: CGFloat, tracking: CGFloat = 0) -> String {
    var path = ""
    for run in CTLineGetGlyphRuns(makeLine(text, font, tracking: tracking)) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName as String] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for (glyph, position) in zip(glyphs, positions) {
            guard let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
            // Font coordinates grow upwards, SVG's grow downwards.
            let px = { (point: CGPoint) in num(originX + position.x + point.x) }
            let py = { (point: CGPoint) in num(originY - position.y - point.y) }
            outline.applyWithBlock { element in
                let p = element.pointee.points
                switch element.pointee.type {
                case .moveToPoint: path += "M\(px(p[0])) \(py(p[0]))"
                case .addLineToPoint: path += "L\(px(p[0])) \(py(p[0]))"
                case .addQuadCurveToPoint: path += "Q\(px(p[0])) \(py(p[0])) \(px(p[1])) \(py(p[1]))"
                case .addCurveToPoint: path += "C\(px(p[0])) \(py(p[0])) \(px(p[1])) \(py(p[1])) \(px(p[2])) \(py(p[2]))"
                case .closeSubpath: path += "Z"
                @unknown default: break
                }
            }
        }
    }
    return path
}

enum Align { case left, center, right }

func text(_ string: String, size: CGFloat, weight: CGFloat, x: CGFloat, y: CGFloat, color: String, align: Align = .left, tracking: CGFloat = 0) -> String {
    let f = font(size, weight)
    let width = measure(string, f, tracking: tracking)
    let start = align == .left ? x : align == .center ? x - width / 2 : x - width
    return ##"<path d="\##(glyphPath(string, f, x: start, y: y, tracking: tracking))" fill="\##(color)"/>"##
}

/// A span of a line: regular or bold, optionally on the site's marker.
struct Span {
    let text: String
    var bold = false
    var marked = false
}

/// A line of mixed weight, the site's way of emphasizing. The marker is 0.42 em tall and sits
/// low on the letters, as `.mark` does in the site's stylesheet.
func spans(_ parts: [Span], size: CGFloat, x: CGFloat, y: CGFloat, theme: Theme, align: Align = .left, tracking: CGFloat = -0.02, regular: CGFloat = 400) -> String {
    let widths = parts.map { measure($0.text, font(size, $0.bold ? 700 : regular), tracking: tracking) }
    let total = widths.reduce(0, +)
    var cursor = align == .left ? x : align == .center ? x - total / 2 : x - total
    var marks = ""
    var letters = ""
    for (part, width) in zip(parts, widths) {
        if part.marked {
            marks += ##"<rect x="\##(num(cursor - size * 0.08))" y="\##(num(y - size * 0.2))" width="\##(num(width + size * 0.16))" height="\##(num(size * 0.42))" rx="2" fill="\##(theme.mark)"/>"##
        }
        letters += ##"<path d="\##(glyphPath(part.text, font(size, part.bold ? 700 : regular), x: cursor, y: y, tracking: tracking))" fill="\##(theme.ink)"/>"##
        cursor += width
    }
    return marks + letters
}

func wrap(_ string: String, _ f: CTFont, width: CGFloat) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in string.split(separator: " ") {
        let attempt = current.isEmpty ? String(word) : current + " " + word
        if measure(attempt, f) > width, !current.isEmpty {
            lines.append(current)
            current = String(word)
        } else {
            current = attempt
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// Anchored top left: a browser rounds an image's height, and would otherwise center the drawing
/// in the leftover width, which pushes headings out of line with the text below them.
func document(width: CGFloat, height: CGFloat, title: String, body: String) -> String {
    ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \##(num(width)) \##(num(height))" width="\##(num(width))" height="\##(num(height))" preserveAspectRatio="xMinYMin meet" role="img" aria-label="\##(title)"><title>\##(title)</title>\##(body)</svg>"## + "\n"
}

func write(_ name: String, _ content: String) throws {
    try content.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// MARK: - Shared pieces

/// The app icon from scripts/make-icon.swift, as shapes.
func appIcon(x: CGFloat, y: CGFloat, side: CGFloat) -> String {
    let scale = side / 824
    let cx = x + side / 2
    let cy = y + side / 2
    var shapes = ##"<rect x="\##(num(x))" y="\##(num(y))" width="\##(num(side))" height="\##(num(side))" rx="\##(num(185 * scale))" fill="#1f1d1a"/>"##
    for index in 0..<8 {
        let angle = CGFloat(index) / 8 * 2 * .pi
        let picked = index == 1
        shapes += ##"<circle cx="\##(num(cx + sin(angle) * 268 * scale))" cy="\##(num(cy - cos(angle) * 268 * scale))" r="\##(num((picked ? 64 : 52) * scale))" fill="\##(picked ? "#d8673a" : "#f2eee7")"/>"##
    }
    shapes += ##"<circle cx="\##(num(cx))" cy="\##(num(cy))" r="\##(num(92 * scale))" fill="#d8673a"/>"##
    return shapes
}

func arrow(x: CGFloat, y: CGFloat, size: CGFloat, color: String) -> String {
    let k = size / 18
    return ##"<path d="M\##(num(x)) \##(num(y))h\##(num(16 * k))M\##(num(x + 10 * k)) \##(num(y - 6 * k))l\##(num(6 * k)) \##(num(6 * k))l\##(num(-6 * k)) \##(num(6 * k))" fill="none" stroke="\##(color)" stroke-width="\##(num(2 * k))" stroke-linecap="round" stroke-linejoin="round"/>"##
}

// MARK: - Hero

func hero(_ theme: Theme) throws -> String {
    let width: CGFloat = 1000
    let height: CGFloat = 432
    var body = ##"<defs><radialGradient id="glow"><stop offset="0" stop-color="#d8673a" stop-opacity="0.15"/><stop offset="1" stop-color="#d8673a" stop-opacity="0"/></radialGradient></defs>"##
    body += ##"<ellipse cx="500" cy="250" rx="440" ry="190" fill="url(#glow)"/>"##

    // The row at the top, drawn like the floating pills of the site's navigation.
    let name = 20 as CGFloat
    let media = measure("Media", font(name, 400))
    let shift = measure("Shift", font(name, 700))
    body += ##"<rect x="1" y="1" width="\##(num(media + shift + 76))" height="54" rx="27" fill="\##(theme.surface)" stroke="\##(theme.line)" stroke-width="1.5"/>"##
    body += appIcon(x: 13, y: 12, side: 32)
    body += ##"<path d="\##(glyphPath("Media", font(name, 400), x: 55, y: 35))" fill="\##(theme.ink)"/><path d="\##(glyphPath("Shift", font(name, 700), x: 55 + media, y: 35))" fill="\##(theme.ink)"/>"##

    let logo = try Data(contentsOf: folder.appendingPathComponent(theme.logo)).base64EncodedString()
    let logoWidth: CGFloat = 150
    body += ##"<rect x="\##(num(width - logoWidth - 41))" y="1" width="\##(num(logoWidth + 40))" height="54" rx="27" fill="\##(theme.surface)" stroke="\##(theme.line)" stroke-width="1.5"/>"##
    body += ##"<image x="\##(num(width - logoWidth - 21))" y="\##(num(28 - logoWidth * 136 / 1200))" width="\##(num(logoWidth))" height="\##(num(logoWidth * 136 / 600))" href="data:image/png;base64,\##(logo)"/>"##

    body += spans([Span(text: "Convert files")], size: 72, x: 500, y: 174, theme: theme, align: .center)
    body += spans([Span(text: "with one "), Span(text: "gesture", bold: true, marked: true), Span(text: ".")], size: 72, x: 500, y: 254, theme: theme, align: .center)

    body += text("Hold Shift while dragging a file, and formats appear around the pointer.", size: 23, weight: 400, x: 500, y: 320, color: theme.muted, align: .center)
    body += text("Drop it on one. The result lands next to the original.", size: 23, weight: 400, x: 500, y: 354, color: theme.muted, align: .center)
    body += text("Free, offline, no account. No file ever leaves your Mac.", size: 16, weight: 500, x: 500, y: 410, color: theme.muted, align: .center)
    return document(width: width, height: height, title: "MediaShift by rightform. Convert files with one gesture.", body: body)
}

// MARK: - Buttons

/// Terracotta with white text: 4.9:1 for the text and against white, 3.8:1 against GitHub's dark page.
func button(label: String) -> String {
    let f = font(20, 600)
    let width = measure(label, f) + 60 + 30
    let body = ##"<rect width="\##(num(width))" height="56" rx="28" fill="#b4552f"/>"##
        + text(label, size: 20, weight: 600, x: 30, y: 35, color: "#ffffff")
        + arrow(x: width - 48, y: 28, size: 20, color: "#ffffff")
    return document(width: width, height: 56, title: label, body: body)
}

/// Bone with ink text, and a thin line that gives it an edge on a white page.
func secondaryButton(label: String) -> String {
    let f = font(20, 600)
    let width = measure(label, f) + 60 + 30
    let body = ##"<rect x="1" y="1" width="\##(num(width - 2))" height="54" rx="27" fill="#f2eee7" stroke="#d8d1c5" stroke-width="1.5"/>"##
        + text(label, size: 20, weight: 600, x: 30, y: 35, color: "#1f1d1a")
        + arrow(x: width - 48, y: 28, size: 20, color: "#1f1d1a")
    return document(width: width, height: 56, title: label, body: body)
}

// MARK: - Section headings

func heading(_ theme: Theme, eyebrow: String, parts: [Span], title: String) -> String {
    var body = ##"<circle cx="6" cy="20" r="6" fill="\##(theme.accent)"/>"##
    body += text(eyebrow, size: 16, weight: 600, x: 22, y: 26, color: theme.muted, tracking: 0.08)
    body += spans(parts, size: 46, x: 0, y: 88, theme: theme)
    return document(width: 1000, height: 112, title: title, body: body)
}

// MARK: - Feature cards

struct Feature {
    let number: String
    let title: String
    let detail: String
    let icon: (CGFloat, CGFloat, CGFloat) -> String
}

let bone = "#f2eee7"
let terra = "#d8673a"

let features = [
    Feature(number: "01 · CONVERT", title: "37 formats", detail: "Documents, spreadsheets, slides, images, video and audio. Office and iWork files do not even need Office or iWork.") { x, y, s in
        var shapes = ""
        for index in 0..<6 {
            let angle = CGFloat(index) / 6 * 2 * .pi
            shapes += ##"<circle cx="\##(num(x + s / 2 + sin(angle) * s * 0.31))" cy="\##(num(y + s / 2 - cos(angle) * s * 0.31))" r="\##(num(s * 0.058))" fill="\##(index == 1 ? terra : bone)"/>"##
        }
        return shapes + ##"<circle cx="\##(num(x + s / 2))" cy="\##(num(y + s / 2))" r="\##(num(s * 0.125))" fill="\##(terra)"/>"##
    },
    Feature(number: "02 · COMPRESS", title: "Smaller files", detail: "Images, audio, video and PDF. Choose a strength, or the size the file has to fit into. The original stays as it was.") { x, y, s in
        let k = s / 76
        let stroke = ##"fill="none" stroke-width="\##(num(4.5 * k))" stroke-linecap="round" stroke-linejoin="round""##
        let inward = ##"M\##(num(x + 20 * k)) \##(num(y + 20 * k))L\##(num(x + 33 * k)) \##(num(y + 33 * k))M\##(num(x + 33 * k)) \##(num(y + 21 * k))V\##(num(y + 33 * k))H\##(num(x + 21 * k))"##
        let outward = ##"M\##(num(x + 56 * k)) \##(num(y + 56 * k))L\##(num(x + 43 * k)) \##(num(y + 43 * k))M\##(num(x + 43 * k)) \##(num(y + 55 * k))V\##(num(y + 43 * k))H\##(num(x + 55 * k))"##
        return ##"<path d="\##(inward)" stroke="\##(bone)" \##(stroke)/><path d="\##(outward)" stroke="\##(terra)" \##(stroke)/>"##
    },
    Feature(number: "03 · CLEAN", title: "Nothing left behind", detail: "Removes GPS position, camera, author and dates from images, audio, video, PDF and Office files before you share them.") { x, y, s in
        let k = s / 76
        let eye = ##"M\##(num(x + 15 * k)) \##(num(y + 38 * k))C\##(num(x + 25 * k)) \##(num(y + 22 * k)) \##(num(x + 51 * k)) \##(num(y + 22 * k)) \##(num(x + 61 * k)) \##(num(y + 38 * k))C\##(num(x + 51 * k)) \##(num(y + 54 * k)) \##(num(x + 25 * k)) \##(num(y + 54 * k)) \##(num(x + 15 * k)) \##(num(y + 38 * k))Z"##
        return ##"<path d="\##(eye)" fill="none" stroke="\##(bone)" stroke-width="\##(num(4.5 * k))" stroke-linejoin="round"/><circle cx="\##(num(x + 38 * k))" cy="\##(num(y + 38 * k))" r="\##(num(6.5 * k))" fill="\##(bone)"/><path d="M\##(num(x + 22 * k)) \##(num(y + 56 * k))L\##(num(x + 54 * k)) \##(num(y + 20 * k))" stroke="#171512" stroke-width="\##(num(10 * k))" stroke-linecap="round"/><path d="M\##(num(x + 22 * k)) \##(num(y + 56 * k))L\##(num(x + 54 * k)) \##(num(y + 20 * k))" stroke="\##(terra)" stroke-width="\##(num(4.5 * k))" stroke-linecap="round"/>"##
    },
]

/// `unit` scales everything, so the one-column version stays readable when a phone shrinks it.
func cards(_ theme: Theme, width: CGFloat, columns: Int, unit u: CGFloat) -> String {
    let gap = 20 * u
    let cardWidth = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
    let padding = 28 * u
    let tile = 76 * u
    let lead = 27 * u
    let textFont = font(18 * u, 400)
    let wrapped = features.map { wrap($0.detail, textFont, width: cardWidth - padding * 2) }
    let cardHeight = padding * 2 + tile + 62 * u + 44 * u + CGFloat(wrapped.map(\.count).max() ?? 0) * lead

    var body = ""
    for (index, feature) in features.enumerated() {
        let x = CGFloat(index % columns) * (cardWidth + gap)
        let y = CGFloat(index / columns) * (cardHeight + gap)
        body += ##"<rect x="\##(num(x + 1))" y="\##(num(y + 1))" width="\##(num(cardWidth - 2))" height="\##(num(cardHeight - 2))" rx="\##(num(20 * u))" fill="\##(theme.surface)" stroke="\##(theme.line)" stroke-width="1.5"/>"##
        body += ##"<rect x="\##(num(x + padding))" y="\##(num(y + padding))" width="\##(num(tile))" height="\##(num(tile))" rx="\##(num(14 * u))" fill="#171512"/>"##
        body += feature.icon(x + padding, y + padding, tile)
        let top = y + padding + tile
        body += text(feature.number, size: 14 * u, weight: 600, x: x + padding, y: top + 38 * u, color: theme.muted, tracking: 0.08)
        body += spans([Span(text: feature.title, bold: true, marked: true)], size: 25 * u, x: x + padding, y: top + 74 * u, theme: theme, tracking: -0.01)
        for (row, line) in wrapped[index].enumerated() {
            body += text(line, size: 18 * u, weight: 400, x: x + padding, y: top + 108 * u + CGFloat(row) * lead, color: theme.muted)
        }
    }
    let rows = Int((Double(features.count) / Double(columns)).rounded(.up))
    let height = CGFloat(rows) * cardHeight + CGFloat(rows - 1) * gap
    return document(width: width, height: height, title: "Convert between 37 formats. Compress images, audio, video and PDF. Clean metadata before you share.", body: body)
}

// MARK: - The gesture, animated

/// The wheel's real geometry, from WheelModel, at 1.2 times its size so it reads in a README.
struct WheelChip {
    let label: String
    let width: CGFloat
    let x: CGFloat
    let y: CGFloat
}

let wheelScale: CGFloat = 1.2
let chipHeight = 40 * wheelScale
let hubRadius = 76 * wheelScale
let chipFont = font(13 * wheelScale, 600)

func wheelChips() -> [WheelChip] {
    // What the app really offers for a Word document, in its order.
    let labels = ["PDF", "Markdown", "HTML", "TXT", "RTF", "ODT", "EPUB", "Pages", "PPTX", "Clean"]
    let widths = labels.map { max(64 * wheelScale, (measure($0, chipFont) + 28 * wheelScale + ($0 == "Clean" ? 20 * wheelScale : 0)).rounded(.up)) }
    func place(_ index: Int, _ radius: CGFloat) -> CGPoint {
        let angle = CGFloat(index) / CGFloat(labels.count) * 2 * .pi
        return CGPoint(x: (sin(angle) * radius).rounded(), y: (-cos(angle) * radius).rounded())
    }
    func fits(_ radius: CGFloat) -> Bool {
        widths.indices.allSatisfy { index in
            let next = (index + 1) % widths.count
            let a = place(index, radius)
            let b = place(next, radius)
            let gap = 12 * wheelScale
            let apartX = abs(a.x - b.x) >= (widths[index] + widths[next]) / 2 + gap
            let apartY = abs(a.y - b.y) >= chipHeight + gap
            return apartX || apartY
        }
    }
    var radius = hubRadius + (widths.max() ?? 0) / 2 + 12 * wheelScale
    while !fits(radius) { radius += 2 }
    return labels.indices.map { index in
        let point = place(index, radius)
        return WheelChip(label: labels[index], width: widths[index], x: point.x, y: point.y)
    }
}

func fileIcon(x: CGFloat, y: CGFloat, tag: String, theme: Theme) -> String {
    let page = theme.name == "light" ? "#ffffff" : "#2a2622"
    return ##"<path d="M\##(num(x + 8)) \##(num(y))H\##(num(x + 40))L\##(num(x + 58)) \##(num(y + 18))V\##(num(y + 64))Q\##(num(x + 58)) \##(num(y + 72)) \##(num(x + 50)) \##(num(y + 72))H\##(num(x + 8))Q\##(num(x)) \##(num(y + 72)) \##(num(x)) \##(num(y + 64))V\##(num(y + 8))Q\##(num(x)) \##(num(y)) \##(num(x + 8)) \##(num(y))Z" fill="\##(page)" stroke="\##(theme.line)" stroke-width="1.5"/><path d="M\##(num(x + 40)) \##(num(y))V\##(num(y + 18))H\##(num(x + 58))" fill="none" stroke="\##(theme.line)" stroke-width="1.5"/>"##
        + text(tag, size: 12, weight: 700, x: x + 29, y: y + 52, color: theme.accent, align: .center, tracking: 0.04)
}

func demo(_ theme: Theme) -> String {
    let width: CGFloat = 1000
    let height: CGFloat = 620
    let center = CGPoint(x: 640, y: 310)
    let chips = wheelChips()
    // The pointer rests low in the hub and to the side of the chip, so it never covers their text.
    let resting = CGPoint(x: center.x + 26, y: center.y + 42)
    let target = CGPoint(x: center.x + chips[0].x + 24, y: center.y + chips[0].y + 8)
    let file = CGPoint(x: 96, y: 150)
    let startPointer = CGPoint(x: 330, y: 520)

    func at(_ point: CGPoint) -> String { "translate(\(num(point.x))px,\(num(point.y))px)" }

    var style = """
    .a{animation-duration:12s;animation-iteration-count:infinite;animation-timing-function:cubic-bezier(.22,1,.36,1)}
    .pointer{animation-name:pointer;transform:\(at(target))}
    .ghost{animation-name:ghost;transform:\(at(target));opacity:.92}
    .key{animation-name:key;opacity:0}
    .hub{animation-name:hub}
    .first{animation-name:first;opacity:0}
    .second{animation-name:second}
    .picked{animation-name:picked}
    .note{animation-name:note;opacity:0}
    .result{animation-name:result;opacity:0}
    @media (prefers-reduced-motion:reduce){.a{animation:none}}
    @keyframes pointer{0%{transform:\(at(startPointer));opacity:0}3%{opacity:1}8%,11%{transform:\(at(file))}23%,32%{transform:\(at(resting))}42%,52%{transform:\(at(target));opacity:1}88%{transform:\(at(target));opacity:1}94%,100%{transform:\(at(target));opacity:0}}
    @keyframes ghost{0%,10%{transform:\(at(file));opacity:0}11%{transform:\(at(file));opacity:.92}23%,32%{transform:\(at(resting));opacity:.92}42%,52%{transform:\(at(target));opacity:.92}55%,100%{transform:\(at(target));opacity:0}}
    @keyframes key{0%,22%{opacity:0}23%,29%{opacity:1}32%,100%{opacity:0}}
    @keyframes hub{0%,24%{opacity:0;transform:scale(.7)}28%,52%{opacity:1;transform:scale(1)}55%,100%{opacity:0;transform:scale(.94)}}
    @keyframes first{0%,27%{opacity:0}29%,40%{opacity:1}42%,100%{opacity:0}}
    @keyframes second{0%,40%{opacity:0}42%,52%{opacity:1}55%,100%{opacity:0}}
    @keyframes picked{0%,40%{opacity:0}42%,52%{opacity:1}55%,100%{opacity:0}}
    @keyframes note{0%,54%{opacity:0;transform:translateY(10px)}58%,88%{opacity:1;transform:translateY(0)}93%,100%{opacity:0}}
    @keyframes result{0%,56%{opacity:0}60%,89%{opacity:1}94%,100%{opacity:0}}
    """
    for index in chips.indices {
        let chip = chips[index]
        let place = "translate(\(num(chip.x))px,\(num(chip.y))px)"
        style += ".c\(index){animation-name:c\(index);transform:\(place)}"
        style += "@keyframes c\(index){0%,24%{opacity:0;transform:translate(0,0) scale(.5)}28%,52%{opacity:1;transform:\(place) scale(1)}55%,100%{opacity:0;transform:\(place) scale(.94)}}"
    }

    var body = "<style>\(style)</style>"
    body += ##"<rect x="1" y="1" width="\##(num(width - 2))" height="\##(num(height - 2))" rx="24" fill="\##(theme.stage)" stroke="\##(theme.line)" stroke-width="1.5"/>"##

    // A quiet Finder window, where the file starts and where the result lands.
    body += ##"<rect x="40" y="44" width="270" height="340" rx="14" fill="\##(theme.surface)" stroke="\##(theme.line)" stroke-width="1.5"/>"##
    for (index, x) in [60, 78, 96].enumerated() {
        body += ##"<circle cx="\##(x)" cy="68" r="5.5" fill="\##(theme.line)"/>"##
        _ = index
    }
    body += text("Documents", size: 15, weight: 600, x: 118, y: 73, color: theme.muted)
    body += ##"<path d="M41 92H309" stroke="\##(theme.line)" stroke-width="1.5"/>"##
    body += fileIcon(x: 67, y: 114, tag: "DOCX", theme: theme)
    body += text("report.docx", size: 14, weight: 500, x: 96, y: 208, color: theme.ink, align: .center)
    body += ##"<g class="a result">"## + fileIcon(x: 195, y: 114, tag: "PDF", theme: theme) + text("report.pdf", size: 14, weight: 700, x: 224, y: 208, color: theme.ink, align: .center) + "</g>"
    body += ##"<g opacity=".55">"## + fileIcon(x: 67, y: 238, tag: "JPG", theme: theme) + text("photo.jpg", size: 14, weight: 500, x: 96, y: 332, color: theme.muted, align: .center) + "</g>"

    // The key.
    let keyX: CGFloat = 115
    let keyY: CGFloat = 448
    let keyBase = ##"<rect x="\##(num(keyX))" y="\##(num(keyY))" width="120" height="62" rx="12" fill="\##(theme.surface)" stroke="\##(theme.line)" stroke-width="1.5"/>"##
    body += keyBase + text("Shift", size: 20, weight: 600, x: keyX + 60, y: keyY + 38, color: theme.ink, align: .center)
    body += ##"<g class="a key"><rect x="\##(num(keyX))" y="\##(num(keyY))" width="120" height="62" rx="12" fill="\##(theme.button)"/>"## + text("Shift", size: 20, weight: 600, x: keyX + 60, y: keyY + 38, color: theme.buttonText, align: .center) + "</g>"
    body += text("Tap it during the drag", size: 15, weight: 500, x: keyX + 60, y: keyY + 90, color: theme.muted, align: .center)

    // The wheel.
    body += ##"<g transform="translate(\##(num(center.x)) \##(num(center.y)))">"##
    body += ##"<g class="a hub"><circle r="\##(num(hubRadius))" fill="\##(theme.chip)" stroke="\##(theme.chipLine)" stroke-width="1.5"/>"##
    body += ##"<g class="a first">"## + text("report.docx", size: 16, weight: 600, x: 0, y: -2, color: theme.chipText, align: .center) + text("Release to cancel", size: 13.5, weight: 400, x: 0, y: 20, color: "#c9c2b6", align: .center) + "</g>"
    body += ##"<g class="a second">"## + text("Convert to PDF", size: 16, weight: 600, x: 0, y: -2, color: theme.chipText, align: .center) + text("Release to start", size: 13.5, weight: 400, x: 0, y: 20, color: "#c9c2b6", align: .center) + "</g></g>"
    for (index, chip) in chips.enumerated() {
        let rect = { (fill: String, line: String) in
            ##"<rect x="\##(num(-chip.width / 2))" y="\##(num(-chipHeight / 2))" width="\##(num(chip.width))" height="\##(num(chipHeight))" rx="\##(num(chipHeight / 2))" fill="\##(fill)" stroke="\##(line)" stroke-width="1.5"/>"##
        }
        body += ##"<g class="a c\##(index)">"## + rect(theme.chip, theme.chipLine)
        if index == 0 {
            body += ##"<g class="a picked">"## + rect("#b4552f", "#b4552f") + "</g>"
        }
        let labelWidth = measure(chip.label, chipFont)
        let symbol: CGFloat = chip.label == "Clean" ? 20 * wheelScale : 0
        if chip.label == "Clean" {
            let sx = -(labelWidth + symbol) / 2 + 8 * wheelScale
            body += ##"<path d="M\##(num(sx - 7)) 0C\##(num(sx - 3)) -6 \##(num(sx + 3)) -6 \##(num(sx + 7)) 0C\##(num(sx + 3)) 6 \##(num(sx - 3)) 6 \##(num(sx - 7)) 0ZM\##(num(sx - 6)) 7L\##(num(sx + 6)) -7" fill="none" stroke="\##(theme.chipText)" stroke-width="1.6" stroke-linecap="round"/>"##
        }
        body += ##"<path d="\##(glyphPath(chip.label, chipFont, x: -(labelWidth + symbol) / 2 + symbol, y: 5.5 * wheelScale))" fill="\##(theme.chipText)"/></g>"##
    }
    body += "</g>"

    // The note that says where the result went.
    let noteWidth: CGFloat = 330
    let noteX = center.x - noteWidth / 2
    body += ##"<g class="a note"><rect x="\##(num(noteX))" y="\##(num(center.y - 40))" width="\##(num(noteWidth))" height="80" rx="18" fill="\##(theme.chip)" stroke="\##(theme.chipLine)" stroke-width="1.5"/>"##
    body += ##"<circle cx="\##(num(noteX + 38))" cy="\##(num(center.y))" r="13" fill="#d8673a"/><path d="M\##(num(noteX + 32)) \##(num(center.y))l4.5 4.5l8 -9" fill="none" stroke="#171512" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>"##
    body += text("report.pdf", size: 18, weight: 600, x: noteX + 66, y: center.y - 3, color: theme.chipText)
    body += text("Click to show in Finder", size: 14.5, weight: 400, x: noteX + 66, y: center.y + 20, color: "#c9c2b6") + "</g>"

    // The dragged file and the pointer, on top of everything.
    body += ##"<g class="a ghost"><g transform="translate(14 18) scale(.6)">"## + fileIcon(x: 0, y: 0, tag: "DOCX", theme: theme) + "</g></g>"
    body += ##"<g class="a pointer"><path d="M0 0V24L6.2 18.2L10.4 28L15 26L10.8 16.4H19Z" fill="#111" stroke="#fff" stroke-width="1.8" stroke-linejoin="round"/></g>"##

    return document(width: width, height: height, title: "Animation: a file is dragged out of the Finder, tapping Shift opens a ring of formats around the pointer, the file is dropped on PDF, and report.pdf appears next to the original.", body: body)
}

// MARK: - Output

try write("button-install.svg", button(label: "How to install"))
try write("button-contact.svg", button(label: "hej@rightform.pl"))
try write("link-more.svg", secondaryButton(label: "See what it does"))

for theme in themes {
    try write("hero-\(theme.name).svg", try hero(theme))
    try write("demo-\(theme.name).svg", demo(theme))
    try write("cards-\(theme.name).svg", cards(theme, width: 1000, columns: 3, unit: 1))
    try write("cards-narrow-\(theme.name).svg", cards(theme, width: 600, columns: 1, unit: 1.5))
    try write("head-what-\(theme.name).svg", heading(theme, eyebrow: "WHAT IT DOES", parts: [Span(text: "One gesture. "), Span(text: "Three jobs", bold: true, marked: true), Span(text: ".")], title: "What it does: one gesture, three jobs."))
    try write("head-install-\(theme.name).svg", heading(theme, eyebrow: "INSTALL", parts: [Span(text: "Two ways to "), Span(text: "get started", bold: true, marked: true), Span(text: ".")], title: "Install: two ways to get started."))
    try write("head-use-\(theme.name).svg", heading(theme, eyebrow: "USING IT", parts: [Span(text: "It stays "), Span(text: "out of your way", bold: true, marked: true), Span(text: ".")], title: "Using it: it stays out of your way."))
    try write("head-made-\(theme.name).svg", heading(theme, eyebrow: "WHO MADE IT", parts: [Span(text: "Made by "), Span(text: "right"), Span(text: "form", bold: true), Span(text: ".")], title: "Made by rightform."))
}

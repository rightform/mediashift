import Foundation

/// The two facts a cell's style index stands for here: its number format and whether it is bold.
final class XLSXStyles {
    private var formatCodes: [Int: String] = [:]
    private var formatIDs: [Int] = []
    private var boldFlags: [Bool] = []
    private var cache: [Int: NumberFormat] = [:]

    init(part: Data?) throws {
        guard let part else { return }
        let root = try XMLTree.parse(part)
        for format in root.first("numFmts")?.all("numFmt") ?? [] {
            if let id = format.attribute("numFmtId").flatMap(Int.init), let code = format.attribute("formatCode") {
                formatCodes[id] = code
            }
        }
        let boldFonts = (root.first("fonts")?.all("font") ?? []).map { font -> Bool in
            guard let bold = font.first("b") else { return false }
            return bold.flag("val") ?? true
        }
        for format in root.first("cellXfs")?.all("xf") ?? [] {
            formatIDs.append(format.attribute("numFmtId").flatMap(Int.init) ?? 0)
            let font = format.attribute("fontId").flatMap(Int.init) ?? 0
            boldFlags.append(boldFonts.indices.contains(font) && boldFonts[font])
        }
    }

    func isBold(style: Int) -> Bool {
        boldFlags.indices.contains(style) && boldFlags[style]
    }

    func format(style: Int) -> NumberFormat {
        if let cached = cache[style] { return cached }
        let id = formatIDs.indices.contains(style) ? formatIDs[style] : 0
        let code = formatCodes[id] ?? NumberFormat.builtInCode(id: id) ?? "General"
        let format = NumberFormat(code: code)
        cache[style] = format
        return format
    }
}

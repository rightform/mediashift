import ConversionCore
import Foundation

public enum DOCXReader {
    public static func read(_ url: URL) throws -> RichDocument {
        let package = try ZipReader(url: url, formatName: "Word")
        guard let main = package.xml(at: "word/document.xml")?.rootElement(), let body = main.child("body") else {
            throw ConversionError("This Word file has no readable document.")
        }
        var parser = DOCXBodyParser(package: package)
        var document = RichDocument(blocks: parser.blocks(in: body))
        if let core = package.xml(at: "docProps/core.xml")?.rootElement() {
            document.title = core.child("title")?.stringValue?.trimmed.nilIfEmpty
            document.author = core.child("creator")?.stringValue?.trimmed.nilIfEmpty
        }
        return document
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct DOCXBodyParser {
    private let package: ZipReader
    private var headingLevels: [String: Int] = [:]
    private var relationships: [String: (target: String, external: Bool)] = [:]
    private var orderedLevels: [String: Set<Int>] = [:]

    init(package: ZipReader) {
        self.package = package
        loadStyles()
        loadRelationships()
        loadNumbering()
    }

    private struct ListParagraph {
        let numberingID: String
        let level: Int
        let blocks: [Block]
    }

    mutating func blocks(in container: XMLElement) -> [Block] {
        var result: [Block] = []
        var pendingList: [ListParagraph] = []

        func flushList(_ result: inout [Block], parser: DOCXBodyParser) {
            if !pendingList.isEmpty { result.append(parser.nestedList(pendingList[...], level: pendingList[0].level)) }
            pendingList = []
        }

        for element in container.childElements {
            switch element.plainName {
            case "p":
                let parsed = paragraph(element)
                if let list = parsed.list {
                    pendingList.append(ListParagraph(numberingID: list.id, level: list.level, blocks: parsed.blocks))
                } else {
                    flushList(&result, parser: self)
                    result += parsed.blocks
                }
            case "tbl":
                flushList(&result, parser: self)
                result.append(.table(table(element)))
            case "sdt":
                flushList(&result, parser: self)
                if let content = element.child("sdtContent") { result += blocks(in: content) }
            default:
                continue
            }
        }
        flushList(&result, parser: self)
        return result
    }

    /// Rebuilds nesting from Word's flat list of paragraphs with indent levels.
    private func nestedList(_ paragraphs: ArraySlice<ListParagraph>, level: Int) -> Block {
        var items: [[Block]] = []
        var index = paragraphs.startIndex
        while index < paragraphs.endIndex {
            let current = paragraphs[index]
            if current.level <= level || items.isEmpty {
                items.append(current.blocks)
                index += 1
            } else {
                var end = index
                while end < paragraphs.endIndex, paragraphs[end].level > level { end += 1 }
                items[items.count - 1].append(nestedList(paragraphs[index..<end], level: current.level))
                index = end
            }
        }
        let first = paragraphs[paragraphs.startIndex]
        return .list(ordered: orderedLevels[first.numberingID]?.contains(level) ?? false, items: items)
    }

    // MARK: - Paragraphs

    private func paragraph(_ element: XMLElement) -> (blocks: [Block], list: (id: String, level: Int)?) {
        let properties = element.child("pPr")
        let styleID = properties?.child("pStyle")?.value(of: "w:val")
        let alignment = properties?.child("jc")?.value(of: "w:val").flatMap(Self.alignment)
        var heading = styleID.flatMap { headingLevels[$0] }
        if let outline = properties?.child("outlineLvl")?.value(of: "w:val").flatMap({ Int($0) }), outline < 6 {
            heading = heading ?? outline + 1
        }

        var pageBreakBefore = properties?.child("pageBreakBefore") != nil
        var pageBreakAfter = false
        var content: [Inline] = []
        for (index, child) in element.childElements.enumerated() where child.plainName != "pPr" {
            content += inlines(from: child, base: TextStyle(), pageBreak: { pageBreakAtStart in
                if pageBreakAtStart && index <= 1 { pageBreakBefore = true } else { pageBreakAfter = true }
            })
        }
        content = Self.merge(content)

        var blocks: [Block] = []
        if pageBreakBefore { blocks.append(.pageBreak) }
        let isEmpty = content.allSatisfy { if case .text(let text, _) = $0 { text.trimmed.isEmpty } else { false } }
        if !isEmpty {
            if let heading {
                blocks.append(.heading(level: min(heading, 6), content: content, alignment: alignment))
            } else if content.count == 1, case .image(let image) = content[0] {
                blocks.append(.image(image))
            } else {
                blocks.append(.paragraph(content: content, alignment: alignment))
            }
        }
        if pageBreakAfter { blocks.append(.pageBreak) }

        if let numbering = properties?.child("numPr"), let id = numbering.child("numId")?.value(of: "w:val"), id != "0", heading == nil {
            let level = numbering.child("ilvl")?.value(of: "w:val").flatMap { Int($0) } ?? 0
            return (blocks, (id, level))
        }
        return (blocks, nil)
    }

    private func inlines(from element: XMLElement, base: TextStyle, pageBreak: (Bool) -> Void) -> [Inline] {
        switch element.plainName {
        case "r":
            let style = runStyle(element.child("rPr"), base: base)
            var result: [Inline] = []
            for piece in element.childElements {
                switch piece.plainName {
                case "t":
                    if let text = piece.stringValue, !text.isEmpty { result.append(.text(text, style)) }
                case "tab":
                    result.append(.text("\t", style))
                case "br":
                    if piece.value(of: "w:type") == "page" {
                        pageBreak(result.isEmpty)
                    } else {
                        result.append(.lineBreak)
                    }
                case "drawing", "pict":
                    if let image = image(in: piece) { result.append(.image(image)) }
                default:
                    continue
                }
            }
            return result
        case "hyperlink":
            var style = base
            if let id = element.value(of: "r:id"), let relationship = relationships[id], relationship.external {
                style.link = relationship.target
            }
            return element.childElements.flatMap { inlines(from: $0, base: style, pageBreak: pageBreak) }
        case "ins", "smartTag", "sdt", "sdtContent", "fldSimple", "customXml":
            return element.childElements.flatMap { inlines(from: $0, base: base, pageBreak: pageBreak) }
        default:
            return []
        }
    }

    private func runStyle(_ properties: XMLElement?, base: TextStyle) -> TextStyle {
        var style = base
        guard let properties else { return style }

        func isOn(_ name: String) -> Bool {
            guard let flag = properties.child(name) else { return false }
            let value = flag.value(of: "w:val")
            return value != "0" && value != "false" && value != "none"
        }

        if isOn("b") { style.bold = true }
        if isOn("i") { style.italic = true }
        if isOn("u") { style.underline = true }
        if isOn("strike") || isOn("dstrike") { style.strikethrough = true }
        switch properties.child("vertAlign")?.value(of: "w:val") {
        case "superscript": style.superscript = true
        case "subscript": style.subscript = true
        default: break
        }
        if let color = properties.child("color")?.value(of: "w:val"), color.count == 6, color.lowercased() != "auto" {
            style.color = "#" + color.uppercased()
        }
        if let size = properties.child("sz")?.value(of: "w:val").flatMap({ Double($0) }) { style.fontSize = size / 2 }
        if let font = properties.child("rFonts")?.value(of: "w:ascii") { style.fontFamily = font }
        if let shade = properties.child("shd")?.value(of: "w:fill"), shade.count == 6, shade.lowercased() != "auto" {
            style.highlight = "#" + shade.uppercased()
        } else if let highlight = properties.child("highlight")?.value(of: "w:val") {
            style.highlight = HTMLBlockParser.hexColor(highlight)
        }
        return style
    }

    private func image(in element: XMLElement) -> ImageAsset? {
        guard let blip = element.descendant("blip"), let id = blip.value(of: "r:embed"),
            let relationship = relationships[id], !relationship.external
        else { return nil }
        let path = ZipReader.resolve(relationship.target, from: "word/document.xml")
        guard let data = package.data(at: path), let mime = ImageSniffer.mimeType(of: data) else { return nil }
        var asset = ImageAsset(data: data, mimeType: mime, alt: element.descendant("docPr")?.value(of: "descr"))
        if let extent = element.descendant("extent"),
            let cx = extent.value(of: "cx").flatMap({ Double($0) }),
            let cy = extent.value(of: "cy").flatMap({ Double($0) })
        {
            asset.width = cx / 12700
            asset.height = cy / 12700
        }
        return asset
    }

    // MARK: - Tables

    private mutating func table(_ element: XMLElement) -> ConversionCore.Table {
        var rows: [[TableCell]] = []
        var hasHeader = false
        for (rowIndex, row) in element.children(named: "tr").enumerated() {
            if rowIndex == 0, row.child("trPr")?.child("tblHeader") != nil { hasHeader = true }
            var cells: [TableCell] = []
            for cell in row.children(named: "tc") {
                let properties = cell.child("tcPr")
                // A continued vertical merge is a placeholder for the cell above.
                if let merge = properties?.child("vMerge"), merge.value(of: "w:val") != "restart" {
                    continue
                }
                let rowSpan = Self.rowSpan(of: cell, row: rowIndex, in: element)
                cells.append(
                    TableCell(
                        blocks: blocks(in: cell),
                        columnSpan: properties?.child("gridSpan")?.value(of: "w:val").flatMap { Int($0) } ?? 1,
                        rowSpan: rowSpan
                    ))
            }
            rows.append(cells)
        }
        return ConversionCore.Table(rows: rows, hasHeaderRow: hasHeader)
    }

    private static func rowSpan(of cell: XMLElement, row: Int, in table: XMLElement) -> Int {
        guard cell.child("tcPr")?.child("vMerge") != nil, let parent = cell.parent as? XMLElement else { return 1 }
        let column = parent.children(named: "tc").firstIndex { $0 === cell } ?? 0
        let rows = table.children(named: "tr")
        var span = 1
        var next = row + 1
        while next < rows.count {
            let cells = rows[next].children(named: "tc")
            guard column < cells.count, let merge = cells[column].child("tcPr")?.child("vMerge"),
                merge.value(of: "w:val") != "restart"
            else { break }
            span += 1
            next += 1
        }
        return span
    }

    // MARK: - Package parts

    private mutating func loadStyles() {
        guard let styles = package.xml(at: "word/styles.xml")?.rootElement() else { return }
        for style in styles.children(named: "style") where style.value(of: "w:type") == "paragraph" {
            guard let id = style.value(of: "w:styleId") else { continue }
            let name = style.child("name")?.value(of: "w:val")?.lowercased() ?? ""
            if name == "title" {
                headingLevels[id] = 1
            } else if name.hasPrefix("heading"), let level = Int(name.drop { !$0.isNumber }) {
                headingLevels[id] = min(level, 6)
            } else if name.hasPrefix("nagłówek"), let level = Int(name.drop { !$0.isNumber }) {
                headingLevels[id] = min(level, 6)
            }
        }
    }

    private mutating func loadRelationships() {
        guard let root = package.xml(at: "word/_rels/document.xml.rels")?.rootElement() else { return }
        for relation in root.children(named: "Relationship") {
            if let id = relation.value(of: "Id"), let target = relation.value(of: "Target") {
                relationships[id] = (target, relation.value(of: "TargetMode") == "External")
            }
        }
    }

    private mutating func loadNumbering() {
        guard let root = package.xml(at: "word/numbering.xml")?.rootElement() else { return }
        var abstractOrdered: [String: Set<Int>] = [:]
        for abstract in root.children(named: "abstractNum") {
            guard let id = abstract.value(of: "w:abstractNumId") else { continue }
            var levels = Set<Int>()
            for level in abstract.children(named: "lvl") {
                if let index = level.value(of: "w:ilvl").flatMap({ Int($0) }),
                    let format = level.child("numFmt")?.value(of: "w:val"), format != "bullet", format != "none"
                {
                    levels.insert(index)
                }
            }
            abstractOrdered[id] = levels
        }
        for number in root.children(named: "num") {
            if let id = number.value(of: "w:numId"), let abstract = number.child("abstractNumId")?.value(of: "w:val") {
                orderedLevels[id] = abstractOrdered[abstract]
            }
        }
    }

    private static func alignment(_ value: String) -> TextAlignment? {
        switch value {
        case "center": .center
        case "right", "end": .right
        case "both", "distribute": .justified
        case "left", "start": .left
        default: nil
        }
    }

    private static func merge(_ inlines: [Inline]) -> [Inline] {
        var result: [Inline] = []
        for inline in inlines {
            if case .text(let text, let style) = inline, case .text(let previous, let previousStyle)? = result.last, previousStyle == style {
                result[result.count - 1] = .text(previous + text, style)
            } else {
                result.append(inline)
            }
        }
        return result
    }
}

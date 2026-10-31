import AppKit
import ConversionCore
import Foundation

/// RTF, legacy Word and OpenDocument, read through the system's text system.
public enum AttributedTextReader {
    public static func read(_ url: URL, format: FileFormat) throws -> RichDocument {
        let type: NSAttributedString.DocumentType
        switch format {
        case .rtf: type = .rtf
        case .doc: type = .docFormat
        case .odt: type = .openDocument
        default: throw ConversionError("This format cannot be read as text.")
        }
        do {
            let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            return convert(text)
        } catch {
            throw ConversionError("This \(format.label) file could not be read. It may be damaged.")
        }
    }

    public static func convert(_ text: NSAttributedString) -> RichDocument {
        let bodySize = dominantFontSize(in: text)
        let string = text.string as NSString
        var blocks: [Block] = []
        var pendingList: [(level: Int, ordered: Bool, content: [Inline])] = []
        var pendingTable: (table: NSTextTable, cells: [(block: NSTextTableBlock, content: [Inline])])?

        func flushList() {
            if !pendingList.isEmpty { blocks.append(nestedList(pendingList[...], level: pendingList[0].level)) }
            pendingList = []
        }

        func flushTable() {
            guard let current = pendingTable else { return }
            blocks.append(.table(table(from: current.cells)))
            pendingTable = nil
        }

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { return }
            let paragraph = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            var content = inlines(in: text, range: range, bodySize: bodySize)

            if let cell = paragraph?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                flushList()
                if let open = pendingTable, open.table !== cell.table { flushTable() }
                if pendingTable == nil { pendingTable = (cell.table, []) }
                pendingTable?.cells.append((cell, content))
                return
            }
            flushTable()

            if let lists = paragraph?.textLists, let list = lists.last {
                content = strippingMarker(from: content)
                let ordered = !list.markerFormat.rawValue.contains("disc") && !list.markerFormat.rawValue.contains("circle")
                    && !list.markerFormat.rawValue.contains("square") && !list.markerFormat.rawValue.contains("hyphen")
                    && !list.markerFormat.rawValue.contains("box") && !list.markerFormat.rawValue.contains("check")
                    && !list.markerFormat.rawValue.contains("diamond")
                pendingList.append((lists.count, ordered, content))
                return
            }
            flushList()

            let alignment = Self.alignment(paragraph?.alignment)
            if content.count == 1, case .image(let image) = content[0] {
                blocks.append(.image(image))
            } else if !content.isEmpty {
                if let level = headingLevel(text: text, range: range, bodySize: bodySize) {
                    blocks.append(.heading(level: level, content: removingSize(content), alignment: alignment))
                } else {
                    blocks.append(.paragraph(content: content, alignment: alignment))
                }
            }
        }
        flushList()
        flushTable()
        return RichDocument(blocks: blocks)
    }

    private static func nestedList(_ items: ArraySlice<(level: Int, ordered: Bool, content: [Inline])>, level: Int) -> Block {
        var result: [[Block]] = []
        var index = items.startIndex
        while index < items.endIndex {
            if items[index].level <= level || result.isEmpty {
                result.append([.paragraph(content: items[index].content)])
                index += 1
            } else {
                var end = index
                while end < items.endIndex, items[end].level > level { end += 1 }
                result[result.count - 1].append(nestedList(items[index..<end], level: items[index].level))
                index = end
            }
        }
        return .list(ordered: items[items.startIndex].ordered, items: result)
    }

    private static func table(from cells: [(block: NSTextTableBlock, content: [Inline])]) -> ConversionCore.Table {
        let rowCount = (cells.map { $0.block.startingRow }.max() ?? 0) + 1
        var rows = [[TableCell]](repeating: [], count: rowCount)
        for cell in cells.sorted(by: { ($0.block.startingRow, $0.block.startingColumn) < ($1.block.startingRow, $1.block.startingColumn) }) {
            rows[cell.block.startingRow].append(
                TableCell(
                    blocks: cell.content.isEmpty ? [] : [.paragraph(content: cell.content)],
                    columnSpan: cell.block.columnSpan,
                    rowSpan: cell.block.rowSpan
                ))
        }
        return ConversionCore.Table(rows: rows)
    }

    private static func inlines(in text: NSAttributedString, range: NSRange, bodySize: CGFloat) -> [Inline] {
        var result: [Inline] = []
        text.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let image = imageAsset(from: attachment) { result.append(.image(image)) }
                return
            }
            let raw = (text.string as NSString).substring(with: runRange)
            let piece = raw.replacingOccurrences(of: "\u{2028}", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let style = textStyle(attributes, bodySize: bodySize)
            for (index, line) in piece.components(separatedBy: "\n").enumerated() {
                if index > 0 { result.append(.lineBreak) }
                if !line.isEmpty { result.append(.text(line, style)) }
            }
        }
        return result
    }

    private static func textStyle(_ attributes: [NSAttributedString.Key: Any], bodySize: CGFloat) -> TextStyle {
        var style = TextStyle()
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            style.bold = traits.contains(.bold)
            style.italic = traits.contains(.italic)
            if abs(font.pointSize - bodySize) > 0.25 { style.fontSize = Double(font.pointSize) }
            if traits.contains(.monoSpace) { style.code = true }
        }
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 { style.underline = true }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { style.strikethrough = true }
        if let offset = attributes[.superscript] as? Int {
            if offset > 0 { style.superscript = true }
            if offset < 0 { style.subscript = true }
        }
        if let link = attributes[.link] {
            style.link = (link as? URL)?.absoluteString ?? (link as? String)
        }
        if let color = attributes[.foregroundColor] as? NSColor, let hex = hex(color), hex != "#000000" {
            style.color = hex
        }
        if let color = attributes[.backgroundColor] as? NSColor, let hex = hex(color), hex != "#FFFFFF" {
            style.highlight = hex
        }
        return style
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    private static func imageAsset(from attachment: NSTextAttachment) -> ImageAsset? {
        let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
        guard let data, let mime = ImageSniffer.mimeType(of: data) else { return nil }
        return ImageAsset(data: data, mimeType: mime)
    }

    /// The font size carrying the most characters is the body text.
    private static func dominantFontSize(in text: NSAttributedString) -> CGFloat {
        var totals: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            if let font = value as? NSFont { totals[font.pointSize, default: 0] += range.length }
        }
        return totals.max { $0.value < $1.value }?.key ?? 12
    }

    /// These formats rarely mark headings, so a short paragraph set in a clearly larger font is taken as one.
    private static func headingLevel(text: NSAttributedString, range: NSRange, bodySize: CGFloat) -> Int? {
        guard range.length < 200, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else {
            return nil
        }
        let ratio = font.pointSize / bodySize
        if ratio >= 1.7 { return 1 }
        if ratio >= 1.35 { return 2 }
        if ratio >= 1.12 { return 3 }
        return nil
    }

    private static func removingSize(_ inlines: [Inline]) -> [Inline] {
        inlines.map { inline in
            guard case .text(let text, var style) = inline else { return inline }
            style.fontSize = nil
            style.bold = false
            return .text(text, style)
        }
    }

    /// The text system stores list markers as literal text, such as a tab, a bullet and a tab.
    private static func strippingMarker(from inlines: [Inline]) -> [Inline] {
        guard case .text(let text, let style)? = inlines.first else { return inlines }
        var rest = Substring(text)
        if rest.hasPrefix("\t") { rest = rest.dropFirst() }
        if let tab = rest.firstIndex(of: "\t"), rest.distance(from: rest.startIndex, to: tab) <= 8 {
            rest = rest[rest.index(after: tab)...]
        } else {
            return inlines
        }
        return (rest.isEmpty ? [] : [.text(String(rest), style)]) + inlines.dropFirst()
    }

    private static func alignment(_ value: NSTextAlignment?) -> TextAlignment? {
        switch value {
        case .center: .center
        case .right: .right
        case .justified: .justified
        default: nil
        }
    }
}

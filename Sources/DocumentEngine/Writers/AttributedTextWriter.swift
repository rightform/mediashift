import AppKit
import ConversionCore
import Foundation

/// RTF and OpenDocument, written through the system's text system.
public enum AttributedTextWriter {
    public static func write(_ document: RichDocument, to url: URL, format: FileFormat) throws {
        let type: NSAttributedString.DocumentType
        switch format {
        case .rtf: type = .rtf
        case .odt: type = .openDocument
        default: throw ConversionError("This format cannot be written as text.")
        }
        let text = attributedString(from: document)
        let data = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: type]
        )
        try data.write(to: url, options: .atomic)
    }

    public static func attributedString(from document: RichDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in document.blocks {
            append(block, to: result, context: Context())
        }
        return result
    }

    private struct Context {
        var lists: [NSTextList] = []
        var cell: NSTextTableBlock?
        var indent: CGFloat = 0
    }

    private static let bodySize: CGFloat = 12

    private static func append(_ block: Block, to result: NSMutableAttributedString, context: Context) {
        switch block {
        case .heading(let level, let content, let alignment):
            let size = [22, 17, 14, 12, 12, 12][max(1, min(level, 6)) - 1]
            let text = inlineString(content, baseSize: CGFloat(size), baseBold: true)
            finishParagraph(text, to: result, alignment: alignment, spacing: 8, context: context)
        case .paragraph(let content, let alignment):
            finishParagraph(inlineString(content, baseSize: bodySize), to: result, alignment: alignment, spacing: 8, context: context)
        case .list(let ordered, let items):
            let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
            var nested = context
            nested.lists.append(list)
            nested.indent += 28
            for (index, item) in items.enumerated() {
                for (blockIndex, itemBlock) in item.enumerated() {
                    if blockIndex == 0, case .paragraph(let content, _) = itemBlock {
                        let marker = ordered ? "\(index + 1)." : "\u{2022}"
                        let text = NSMutableAttributedString(string: "\t\(marker)\t", attributes: [.font: NSFont.systemFont(ofSize: bodySize)])
                        text.append(inlineString(content, baseSize: bodySize))
                        finishParagraph(text, to: result, alignment: nil, spacing: 3, context: nested)
                    } else {
                        append(itemBlock, to: result, context: nested)
                    }
                }
            }
        case .table(let table):
            appendTable(table, to: result)
        case .image(let image):
            let attachment = NSTextAttachment()
            attachment.fileWrapper = {
                let wrapper = FileWrapper(regularFileWithContents: image.data)
                wrapper.preferredFilename = "image.\(image.fileExtension)"
                return wrapper
            }()
            finishParagraph(NSAttributedString(attachment: attachment), to: result, alignment: nil, spacing: 8, context: context)
        case .code(let code, _):
            let text = NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)])
            finishParagraph(text, to: result, alignment: nil, spacing: 8, context: context)
        case .quote(let blocks):
            var nested = context
            nested.indent += 24
            for inner in blocks { append(inner, to: result, context: nested) }
        case .rule:
            finishParagraph(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"), to: result, alignment: .center, spacing: 8, context: context)
        case .pageBreak:
            // A form feed is a page break in RTF readers. Elsewhere it is harmless.
            result.append(NSAttributedString(string: "\u{0C}"))
        }
    }

    private static func finishParagraph(
        _ text: NSAttributedString,
        to result: NSMutableAttributedString,
        alignment: TextAlignment?,
        spacing: CGFloat,
        context: Context
    ) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        if !context.lists.isEmpty {
            style.textLists = context.lists
            style.headIndent = context.indent
            style.firstLineHeadIndent = context.indent - 28
            style.tabStops = [
                NSTextTab(textAlignment: .natural, location: context.indent - 14),
                NSTextTab(textAlignment: .natural, location: context.indent),
            ]
        } else if context.indent > 0 {
            style.headIndent = context.indent
            style.firstLineHeadIndent = context.indent
        }
        if let cell = context.cell { style.textBlocks = [cell] }
        switch alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case .justified: style.alignment = .justified
        case .left, nil: break
        }
        let paragraph = NSMutableAttributedString(attributedString: text)
        paragraph.append(NSAttributedString(string: "\n"))
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        result.append(paragraph)
    }

    private static func appendTable(_ table: ConversionCore.Table, to result: NSMutableAttributedString) {
        let columns = table.rows.map { $0.reduce(0) { $0 + $1.columnSpan } }.max() ?? 0
        guard columns > 0 else { return }
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.setContentWidth(100, type: .percentageValueType)
        textTable.hidesEmptyCells = false

        for (rowIndex, row) in table.rows.enumerated() {
            var column = 0
            for cell in row {
                let block = NSTextTableBlock(
                    table: textTable,
                    startingRow: rowIndex,
                    rowSpan: cell.rowSpan,
                    startingColumn: column,
                    columnSpan: cell.columnSpan
                )
                block.setBorderColor(.separatorColor)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                let content: NSAttributedString
                if table.hasHeaderRow, rowIndex == 0 {
                    content = NSAttributedString(string: cell.plainText, attributes: [.font: NSFont.boldSystemFont(ofSize: bodySize)])
                } else {
                    var inlines: [Inline] = []
                    for inner in cell.blocks {
                        if !inlines.isEmpty { inlines.append(.lineBreak) }
                        if case .paragraph(let parts, _) = inner { inlines += parts } else { inlines.append(.text(inner.plainText)) }
                    }
                    content = inlineString(inlines, baseSize: bodySize)
                }
                var context = Context()
                context.cell = block
                finishParagraph(content, to: result, alignment: nil, spacing: 0, context: context)
                column += cell.columnSpan
            }
        }
    }

    private static func inlineString(_ inlines: [Inline], baseSize: CGFloat, baseBold: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines {
            switch inline {
            case .text(let text, let style):
                result.append(NSAttributedString(string: text, attributes: attributes(for: style, baseSize: baseSize, baseBold: baseBold)))
            case .lineBreak:
                result.append(NSAttributedString(string: "\u{2028}"))
            case .image(let image):
                let attachment = NSTextAttachment()
                let wrapper = FileWrapper(regularFileWithContents: image.data)
                wrapper.preferredFilename = "image.\(image.fileExtension)"
                attachment.fileWrapper = wrapper
                result.append(NSAttributedString(attachment: attachment))
            }
        }
        return result
    }

    private static func attributes(for style: TextStyle, baseSize: CGFloat, baseBold: Bool) -> [NSAttributedString.Key: Any] {
        let size = style.fontSize.map { CGFloat($0) } ?? baseSize
        var font: NSFont
        if let family = style.fontFamily, let named = NSFont(name: family, size: size) {
            font = named
        } else if style.code {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            font = NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
        }
        var traits = NSFontTraitMask()
        if style.bold || baseBold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }

        var result: [NSAttributedString.Key: Any] = [.font: font]
        if style.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.superscript { result[.superscript] = 1 }
        if style.subscript { result[.superscript] = -1 }
        if let color = style.color.flatMap(color(hex:)) { result[.foregroundColor] = color }
        if let color = style.highlight.flatMap(color(hex:)) { result[.backgroundColor] = color }
        if let link = style.link, let url = URL(string: link) { result[.link] = url }
        return result
    }

    private static func color(hex: String) -> NSColor? {
        guard hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255,
            alpha: 1
        )
    }
}

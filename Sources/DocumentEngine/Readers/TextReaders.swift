import ConversionCore
import Foundation
import Markdown

public enum PlainTextReader {
    public static func read(_ url: URL) throws -> RichDocument {
        parse(TextDecoding.decode(try Data(contentsOf: url)))
    }

    /// Blank lines separate paragraphs. Single line breaks inside a paragraph are kept.
    public static func parse(_ text: String) -> RichDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [Block] = []
        var lines: [Inline] = []

        func flush() {
            if !lines.isEmpty { blocks.append(.paragraph(content: lines)) }
            lines = []
        }

        for line in normalized.components(separatedBy: "\n") {
            if line.trimmed.isEmpty {
                flush()
            } else {
                if !lines.isEmpty { lines.append(.lineBreak) }
                lines.append(.text(line))
            }
        }
        flush()
        return RichDocument(blocks: blocks)
    }
}

public enum MarkdownReader {
    public static func read(_ url: URL) throws -> RichDocument {
        parse(TextDecoding.decode(try Data(contentsOf: url)), baseURL: url.deletingLastPathComponent())
    }

    public static func parse(_ text: String, baseURL: URL? = nil) -> RichDocument {
        // Smart punctuation would rewrite the author's quotes and dashes.
        let source = Document(parsing: text, options: [.disableSmartOpts])
        return RichDocument(blocks: source.children.flatMap { blocks(from: $0, baseURL: baseURL) })
    }

    private static func blocks(from markup: any Markup, baseURL: URL?) -> [Block] {
        switch markup {
        case let heading as Heading:
            return [.heading(level: heading.level, content: inlines(from: heading, style: TextStyle(), baseURL: baseURL))]
        case let paragraph as Paragraph:
            let content = inlines(from: paragraph, style: TextStyle(), baseURL: baseURL)
            if content.count == 1, case .image(let image) = content[0] { return [.image(image)] }
            return [.paragraph(content: content)]
        case let list as UnorderedList:
            return [.list(ordered: false, items: list.listItems.map { items(from: $0, baseURL: baseURL) })]
        case let list as OrderedList:
            return [.list(ordered: true, items: list.listItems.map { items(from: $0, baseURL: baseURL) })]
        case let code as CodeBlock:
            let trimmedCode = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            return [.code(trimmedCode, language: code.language)]
        case let quote as BlockQuote:
            return [.quote(quote.children.flatMap { blocks(from: $0, baseURL: baseURL) })]
        case is ThematicBreak:
            return [.rule]
        case let table as Markdown.Table:
            return [.table(tableBlock(from: table, baseURL: baseURL))]
        case let html as HTMLBlock:
            return HTMLReader.parse(html.rawHTML, baseURL: baseURL).blocks
        default:
            return []
        }
    }

    private static func items(from item: ListItem, baseURL: URL?) -> [Block] {
        item.children.flatMap { blocks(from: $0, baseURL: baseURL) }
    }

    private static func tableBlock(from table: Markdown.Table, baseURL: URL?) -> ConversionCore.Table {
        func cells(_ source: some Sequence<Markdown.Table.Cell>) -> [TableCell] {
            source.map { cell in
                TableCell(
                    blocks: [.paragraph(content: inlines(from: cell, style: TextStyle(), baseURL: baseURL))],
                    columnSpan: Int(cell.colspan),
                    rowSpan: Int(cell.rowspan)
                )
            }
        }
        var rows = [cells(table.head.cells)]
        rows += table.body.rows.map { cells($0.cells) }
        return ConversionCore.Table(rows: rows, hasHeaderRow: true)
    }

    private static func inlines(from parent: any Markup, style: TextStyle, baseURL: URL?) -> [Inline] {
        parent.children.flatMap { child -> [Inline] in
            var style = style
            switch child {
            case let text as Markdown.Text:
                return [.text(text.string, style)]
            case is SoftBreak:
                return [.text(" ", style)]
            case is LineBreak:
                return [.lineBreak]
            case is Emphasis:
                style.italic = true
            case is Strong:
                style.bold = true
            case is Strikethrough:
                style.strikethrough = true
            case let code as InlineCode:
                style.code = true
                return [.text(code.code, style)]
            case let link as Markdown.Link:
                style.link = link.destination
            case let image as Markdown.Image:
                let alt = image.plainText
                if let source = image.source, let asset = LocalImageLoader.load(source: source, relativeTo: baseURL, alt: alt) {
                    return [.image(asset)]
                }
                return alt.isEmpty ? [] : [.text(alt, style)]
            default:
                break
            }
            return inlines(from: child, style: style, baseURL: baseURL)
        }
    }
}

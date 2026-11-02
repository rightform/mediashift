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
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        let front = frontMatter(in: lines)
        if let front { lines.removeFirst(front.bodyStart) }
        let notes = Footnotes(takingDefinitionsFrom: &lines)
        let source = parsed(lines.joined(separator: "\n"))
        let blocks = source.children.flatMap { blocks(from: $0, lines: lines, baseURL: baseURL) }
        return RichDocument(
            title: front?.title,
            author: front?.author,
            blocks: notes.isEmpty ? blocks : notes.applied(to: blocks, baseURL: baseURL)
        )
    }

    private static func parsed(_ text: String) -> Document {
        // Smart punctuation would rewrite the author's quotes and dashes.
        Document(parsing: text, options: [.disableSmartOpts])
    }

    private static func blocks(from markup: any Markup, lines: [String], baseURL: URL?) -> [Block] {
        switch markup {
        case let heading as Heading:
            return [.heading(level: heading.level, content: inlines(from: heading, style: TextStyle(), baseURL: baseURL))]
        case let paragraph as Paragraph:
            if let repaired = repairedTable(in: paragraph, lines: lines, baseURL: baseURL) { return repaired }
            let content = inlines(from: paragraph, style: TextStyle(), baseURL: baseURL)
            if content.count == 1, case .image(let image) = content[0] { return [.image(image)] }
            return [.paragraph(content: content)]
        case let list as UnorderedList:
            return [.list(ordered: false, items: list.listItems.map { items(from: $0, lines: lines, baseURL: baseURL) })]
        case let list as OrderedList:
            return [.list(ordered: true, items: list.listItems.map { items(from: $0, lines: lines, baseURL: baseURL) })]
        case let code as CodeBlock:
            let trimmedCode = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            return [.code(trimmedCode, language: code.language)]
        case let quote as BlockQuote:
            return [.quote(quote.children.flatMap { blocks(from: $0, lines: lines, baseURL: baseURL) })]
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

    private static func items(from item: ListItem, lines: [String], baseURL: URL?) -> [Block] {
        var blocks = item.children.flatMap { blocks(from: $0, lines: lines, baseURL: baseURL) }
        // A task keeps its box as a character, which every format can show.
        if let checkbox = item.checkbox, case .paragraph(let content, let alignment)? = blocks.first {
            blocks[0] = .paragraph(content: [.text(checkbox == .checked ? "☑ " : "☐ ")] + content, alignment: alignment)
        }
        return blocks
    }

    private static func tableBlock(from table: Markdown.Table, baseURL: URL?) -> ConversionCore.Table {
        let alignments = table.columnAlignments
        func cells(_ source: some Sequence<Markdown.Table.Cell>) -> [TableCell] {
            // The parser also lists the positions a span covers, with a span of zero. The model leaves them out.
            source.enumerated().compactMap { column, cell in
                guard cell.colspan > 0, cell.rowspan > 0 else { return nil }
                let content = inlines(from: cell, style: TextStyle(), baseURL: baseURL)
                return TableCell(
                    blocks: [.paragraph(content: content, alignment: column < alignments.count ? alignment(alignments[column]) : nil)],
                    columnSpan: Int(cell.colspan),
                    rowSpan: Int(cell.rowspan)
                )
            }
        }
        var rows = [cells(table.head.cells)]
        rows += table.body.rows.map { cells($0.cells) }
        return ConversionCore.Table(rows: rows, hasHeaderRow: true)
    }

    /// Left is what a cell does anyway, so only a change from it is worth recording.
    private static func alignment(_ column: Markdown.Table.ColumnAlignment?) -> TextAlignment? {
        switch column {
        case .center: .center
        case .right: .right
        case .left, nil: nil
        }
    }

    // MARK: - Front matter

    private struct FrontMatter {
        var title: String?
        var author: String?
        /// The line the document's text starts on.
        var bodyStart: Int
    }

    /// The YAML block that Jekyll, Hugo, Obsidian and others put at the top of a file describes
    /// the document and is not part of its text. A rule and a heading that happen to look
    /// similar stay what they are: every line in the block has to read as YAML.
    private static func frontMatter(in lines: [String]) -> FrontMatter? {
        func isDelimiter(_ line: String, _ marks: String...) -> Bool {
            marks.contains(line.trimmingCharacters(in: .whitespaces))
        }
        guard let opening = lines.firstIndex(where: { !$0.trimmed.isEmpty }), isDelimiter(lines[opening], "---"),
            let closing = lines[(opening + 1)...].firstIndex(where: { isDelimiter($0, "---", "...") })
        else { return nil }
        let block = lines[(opening + 1)..<closing]
        guard block.allSatisfy(isYAMLLine), block.isEmpty || block.contains(where: { yamlKey(in: $0) != nil }) else { return nil }

        var front = FrontMatter(bodyStart: closing + 1)
        var authors: [String] = []
        var inAuthorList = false
        for line in block {
            if let key = yamlKey(in: line) {
                let value = line.drop { $0 != ":" }.dropFirst()
                let isAuthor = key == "author" || key == "authors"
                inAuthorList = isAuthor && value.trimmingCharacters(in: .whitespaces).isEmpty
                if key == "title" { front.title = yamlScalar(value) }
                if isAuthor { authors += yamlList(value) }
            } else if inAuthorList, line.hasPrefix(" ") || line.hasPrefix("-") {
                let item = String(line.drop { $0.isWhitespace || $0 == "-" })
                if !item.contains(":"), let author = yamlScalar(item) { authors.append(author) }
            }
        }
        front.author = authors.isEmpty ? nil : authors.joined(separator: ", ")
        return front
    }

    private static func isYAMLLine(_ line: String) -> Bool {
        line.trimmed.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("#") || line.hasPrefix("- ")
            || yamlKey(in: line) != nil
    }

    /// The lowercased key of a top-level `key: value` line.
    private static func yamlKey(in line: String) -> String? {
        guard let colon = line.firstIndex(of: ":"), line.first?.isLetter == true else { return nil }
        let after = line[line.index(after: colon)...]
        guard after.isEmpty || after.first?.isWhitespace == true else { return nil }
        let key = line[..<colon]
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " }) else { return nil }
        return key.lowercased()
    }

    /// A plain value without its quotes or trailing comment. Multi-line forms read as no value.
    private static func yamlScalar(_ raw: some StringProtocol) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            guard value.count >= 2, let end = value.dropFirst().firstIndex(of: quote) else { return nil }
            value = String(value[value.index(after: value.startIndex)..<end])
        } else if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">") ? nil : value
    }

    /// `A`, or `[A, B]`.
    private static func yamlList(_ raw: some StringProtocol) -> [String] {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return yamlScalar(value).map { [$0] } ?? [] }
        return value.dropFirst().dropLast().split(separator: ",").compactMap { yamlScalar($0) }
    }

    // MARK: - Tables the parser turns down

    /// One wrong divider row makes a whole table plain text under GitHub's rules: too few columns,
    /// long dashes, or no-break spaces from a paste. Nobody writes those rows meaning a paragraph,
    /// so such a table is parsed again with the divider it was after, and room for its widest row.
    private static func repairedTable(in paragraph: Paragraph, lines: [String], baseURL: URL?) -> [Block]? {
        guard let range = paragraph.range, range.upperBound.line <= lines.count else { return nil }
        var rows = lines[(range.lowerBound.line - 1)..<range.upperBound.line].map { line in
            String(line.drop { $0.isWhitespace || $0 == ">" })
        }
        guard rows.count >= 2 else { return nil }
        // The first line can start after a list marker.
        rows[0] = String(decoding: lines[range.lowerBound.line - 1].utf8.dropFirst(range.lowerBound.column - 1), as: UTF8.self)
        guard let divider = rows.indices.dropFirst().first(where: { isDivider(rows[$0]) && rows[$0 - 1].contains("|") }) else {
            return nil
        }

        let header = cells(of: rows[divider - 1])
        let written = cells(of: rows[divider])
        let columnCount = rows[(divider + 1)...].map { cells(of: $0).count }.reduce(header.count, max)
        let dividerCells = (0..<columnCount).map { column -> String in
            let cell = column < written.count ? written[column].trimmingCharacters(in: .whitespaces) : ""
            return (cell.hasPrefix(":") ? ":" : "") + "---" + (cell.hasSuffix(":") ? ":" : "")
        }
        let paddedHeader = header + Array(repeating: " ", count: columnCount - header.count)
        rows[divider - 1] = "|" + paddedHeader.joined(separator: "|") + "|"
        rows[divider] = "|" + dividerCells.joined(separator: "|") + "|"

        let document = parsed(rows.joined(separator: "\n"))
        guard document.children.contains(where: { $0 is Markdown.Table }) else { return nil }
        return document.children.flatMap { blocks(from: $0, lines: [], baseURL: baseURL) }
    }

    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}"]

    private static func isDivider(_ row: String) -> Bool {
        row.contains("|") && row.contains(where: dashes.contains)
            && row.allSatisfy { dashes.contains($0) || $0 == "|" || $0 == ":" || $0.isWhitespace }
    }

    /// A row's cells: between pipes, apart from an escaped pipe and the ones at its ends.
    private static func cells(of row: String) -> [String] {
        var body = Substring(row.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells = [""]
        var escaped = false
        for character in body {
            if character == "|", !escaped {
                cells.append("")
            } else {
                cells[cells.count - 1].append(character)
            }
            escaped = character == "\\" && !escaped
        }
        return cells
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
            case let html as InlineHTML:
                // The only way to break a line inside a table cell, and what MarkdownWriter writes there.
                let tag = html.rawHTML.lowercased().filter { !$0.isWhitespace }
                return tag == "<br>" || tag == "<br/>" ? [.lineBreak] : []
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

/// Footnotes as GitHub writes them: `[^label]` in the text and `[^label]: text` on a line of its
/// own. The parser does not know them, so the definitions come out of the text before parsing,
/// each mark becomes a superscript number, and the notes follow the text as a numbered list.
private struct Footnotes {
    private var definitions: [(label: String, text: String)] = []
    private var numbers: [String: Int] = [:]

    var isEmpty: Bool { definitions.isEmpty }

    /// Blanks each definition's lines, so line numbers stay true for the rest of the reader.
    init(takingDefinitionsFrom lines: inout [String]) {
        var fence: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
            } else if let match = line.wholeMatch(of: /\[\^([^\]\s]+)\]:[ \t]?(.*)/) {
                var text = String(match.output.2)
                lines[index] = ""
                // Lines indented under a definition continue it.
                while index + 1 < lines.count, lines[index + 1].hasPrefix("    ") || lines[index + 1].hasPrefix("\t") {
                    index += 1
                    text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    lines[index] = ""
                }
                if !definitions.contains(where: { $0.label == String(match.output.1) }) {
                    definitions.append((String(match.output.1), text))
                }
            }
            index += 1
        }
        guard !definitions.isEmpty else { return }
        // Numbered in the order the text first mentions them, as GitHub does. Notes the text
        // never mentions come last.
        let known = Set(definitions.map(\.label))
        for mark in lines.joined(separator: "\n").matches(of: /\[\^([^\]\s]+)\]/) {
            let label = String(mark.output.1)
            if known.contains(label), numbers[label] == nil { numbers[label] = numbers.count + 1 }
        }
        for definition in definitions where numbers[definition.label] == nil {
            numbers[definition.label] = numbers.count + 1
        }
        definitions.sort { numbers[$0.label, default: 0] < numbers[$1.label, default: 0] }
    }

    func applied(to blocks: [Block], baseURL: URL?) -> [Block] {
        let notes = definitions.map { definition -> [Block] in
            let parsed = MarkdownReader.parse(definition.text, baseURL: baseURL).blocks
            return parsed.isEmpty ? [.paragraph(content: [])] : parsed
        }
        return blocks.map(marked) + [.rule, .list(ordered: true, items: notes)]
    }

    private func marked(_ block: Block) -> Block {
        switch block {
        case .heading(let level, let content, let alignment):
            .heading(level: level, content: marked(content), alignment: alignment)
        case .paragraph(let content, let alignment):
            .paragraph(content: marked(content), alignment: alignment)
        case .list(let ordered, let items):
            .list(ordered: ordered, items: items.map { $0.map(marked) })
        case .quote(let blocks):
            .quote(blocks.map(marked))
        case .table(var table):
            .table({
                table.rows = table.rows.map { row in row.map { cell in
                    var cell = cell
                    cell.blocks = cell.blocks.map(marked)
                    return cell
                } }
                return table
            }())
        default:
            block
        }
    }

    /// The parser can split `[^1]` over several runs of text, so runs of one style join first.
    private func marked(_ inlines: [Inline]) -> [Inline] {
        var joined: [Inline] = []
        for inline in inlines {
            if case .text(let text, let style) = inline, case .text(let previous, let previousStyle)? = joined.last, previousStyle == style {
                joined[joined.count - 1] = .text(previous + text, style)
            } else {
                joined.append(inline)
            }
        }
        return joined.flatMap { inline -> [Inline] in
            guard case .text(let text, let style) = inline, !style.code, text.contains("[^") else { return [inline] }
            var result: [Inline] = []
            var plain = ""
            var rest = Substring(text)
            while let mark = rest.firstMatch(of: /\[\^([^\]\s]+)\]/) {
                plain += rest[..<mark.range.lowerBound]
                if let number = numbers[String(mark.output.1)] {
                    if !plain.isEmpty { result.append(.text(plain, style)) }
                    plain = ""
                    var superscript = style
                    superscript.superscript = true
                    result.append(.text(String(number), superscript))
                } else {
                    plain += rest[mark.range]
                }
                rest = rest[mark.range.upperBound...]
            }
            plain += rest
            if !plain.isEmpty { result.append(.text(plain, style)) }
            return result
        }
    }
}

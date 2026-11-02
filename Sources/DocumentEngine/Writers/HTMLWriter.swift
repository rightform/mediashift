import ConversionCore
import Foundation

public enum HTMLWriter {
    public static func write(_ document: RichDocument, to url: URL) throws {
        try Data(render(document).utf8).write(to: url, options: .atomic)
    }

    /// A complete standalone page. Images are embedded so the result is one portable file.
    public static func render(_ document: RichDocument, pageBreaksVisible: Bool = false) -> String {
        let body = HTMLBodyRenderer { image in
            "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
        }.render(document.blocks, pageBreaksVisible: pageBreaksVisible)
        let title = (document.inferredTitle ?? "Document").xmlEscaped
        let author = document.author.map { "<meta name=\"author\" content=\"\($0.xmlEscaped)\">\n" } ?? ""
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title)</title>
            \(author)<style>\(defaultStyleSheet)</style>
            </head>
            <body>
            \(body)
            </body>
            </html>

            """
    }

    static let defaultStyleSheet = """
        :root { color-scheme: light; }
        body { font: 11pt/1.5 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #1d1d1f; background: #fff; max-width: 46em; margin: 2em auto; padding: 0 1em; overflow-wrap: anywhere; }
        @media print { body { max-width: none; margin: 0; padding: 0; } }
        body > :first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .5em; break-after: avoid; }
        h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; } h4, h5, h6 { font-size: 11pt; }
        p { margin: 0 0 .8em; }
        img { max-width: 100%; height: auto; }
        .table-scroll { margin: 1.2em 0; }
        @media screen { .table-scroll { overflow-x: auto; } }
        table { border-collapse: collapse; width: 100%; font-size: .95em; line-height: 1.4; font-variant-numeric: tabular-nums; overflow-wrap: break-word; break-inside: avoid; }
        thead { display: table-header-group; }
        tr { break-inside: avoid; }
        th, td { border-bottom: 1px solid #e3e3e6; padding: .5em .7em; text-align: left; vertical-align: top; }
        td > p:last-child, th > p:last-child, li > p:last-child { margin-bottom: 0; }
        th { background: #f5f5f7; border-bottom-color: #c8c8cc; font-weight: 600; }
        table.dense { font-size: .85em; }
        table.dense th, table.dense td { padding: .4em .5em; }
        table.denser { font-size: .72em; }
        table.denser th, table.denser td { padding: .3em .35em; }
        table.fixed { table-layout: fixed; }
        table:not(.fixed) .nowrap { white-space: nowrap; }
        pre { background: #f5f5f7; padding: .8em 1em; white-space: pre-wrap; font: 9.5pt/1.45 ui-monospace, Menlo, monospace; }
        code { font: .92em ui-monospace, Menlo, monospace; }
        blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid #c8c8cc; color: #48484a; }
        hr { border: 0; border-top: 1px solid #c8c8cc; margin: 1.5em 0; }
        .page-break { break-after: page; height: 0; }
        caption { font-weight: 600; text-align: left; padding-bottom: .4em; }
        """
}

/// Turns blocks into HTML or, with `xhtml`, well-formed XHTML for EPUB.
struct HTMLBodyRenderer {
    var xhtml = false
    /// In a table, where a long word or address would otherwise set the width of its column.
    private var softBreaks = false
    let imageSource: (ImageAsset) -> String

    init(xhtml: Bool = false, imageSource: @escaping (ImageAsset) -> String) {
        self.xhtml = xhtml
        self.imageSource = imageSource
    }

    func render(_ blocks: [Block], pageBreaksVisible: Bool = false) -> String {
        blocks.map { render($0, pageBreaksVisible: pageBreaksVisible) }.joined(separator: "\n")
    }

    private func render(_ block: Block, pageBreaksVisible: Bool) -> String {
        switch block {
        case .heading(let level, let content, let alignment):
            let tag = "h\(max(1, min(level, 6)))"
            return "<\(tag)\(attribute(alignment))>\(render(content))</\(tag)>"
        case .paragraph(let content, let alignment):
            return "<p\(attribute(alignment))>\(render(content))</p>"
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            let body = items.map { item -> String in
                // A single paragraph renders without its <p> to keep lists tight.
                if case .paragraph(let content, _)? = item.first {
                    let rest = item.dropFirst().map { render($0, pageBreaksVisible: false) }.joined()
                    return "<li>\(render(content))\(rest)</li>"
                }
                return "<li>\(item.map { render($0, pageBreaksVisible: false) }.joined())</li>"
            }.joined(separator: "\n")
            return "<\(tag)>\n\(body)\n</\(tag)>"
        case .table(let table):
            return render(table)
        case .image(let image):
            return "<p>\(tag(for: image))</p>"
        case .code(let code, let language):
            let languageClass = language.map { " class=\"language-\($0.xmlEscaped)\"" } ?? ""
            return "<pre><code\(languageClass)>\(code.xmlEscaped)</code></pre>"
        case .quote(let blocks):
            return "<blockquote>\n\(render(blocks))\n</blockquote>"
        case .rule:
            return xhtml ? "<hr/>" : "<hr>"
        case .pageBreak:
            return pageBreaksVisible ? (xhtml ? "<hr/>" : "<hr>") : "<div class=\"page-break\"></div>"
        }
    }

    private func render(_ table: ConversionCore.Table) -> String {
        var cells = self
        cells.softBreaks = true
        let density = TableFit.density(of: table).map { " class=\"\($0)\"" } ?? ""
        var html = "<div class=\"table-scroll\">\n<table\(density)>\n"
        if let name = table.name { html += "<caption>\(name.xmlEscaped)</caption>\n" }
        // A header of its own is what print repeats at the top of each page.
        if table.hasHeaderRow, let header = table.rows.first {
            html += "<thead>\n\(cells.render(row: header, cellTag: "th"))</thead>\n"
        }
        let body = table.rows.dropFirst(table.hasHeaderRow ? 1 : 0)
        if !body.isEmpty {
            html += "<tbody>\n" + body.map { cells.render(row: $0, cellTag: "td") }.joined() + "</tbody>\n"
        }
        return html + "</table>\n</div>"
    }

    private func render(row: [TableCell], cellTag: String) -> String {
        var html = "<tr>"
        for cell in row {
            var attributes = ""
            if cell.columnSpan > 1 { attributes += " colspan=\"\(cell.columnSpan)\"" }
            if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
            let content: String
            if cell.blocks.count == 1, case .paragraph(let inlines, let alignment) = cell.blocks[0] {
                attributes += attribute(alignment)
                content = render(inlines)
            } else {
                content = render(cell.blocks)
            }
            html += "<\(cellTag)\(attributes)>\(content)</\(cellTag)>"
        }
        return html + "</tr>\n"
    }

    /// Escapes text for the page. In a table, long words also get places to wrap, and dates and figures none.
    private func escaped(_ text: String) -> String {
        guard softBreaks else { return text.xmlEscaped }
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            if TableFit.isFigure(word) { return "<span class=\"nowrap\">\(String(word).xmlEscaped)</span>" }
            return TableFit.segments(of: word).map(\.xmlEscaped).joined(separator: xhtml ? "<wbr/>" : "<wbr>")
        }.joined(separator: " ")
    }

    func render(_ inlines: [Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text, let style): decorate(escaped(text).replacingOccurrences(of: "\t", with: "&#160;&#160;&#160;&#160;"), style)
            case .lineBreak: xhtml ? "<br/>" : "<br>"
            case .image(let image): tag(for: image)
            }
        }.joined()
    }

    private func decorate(_ escaped: String, _ style: TextStyle) -> String {
        var html = escaped
        var css: [String] = []
        if let color = style.color { css.append("color:\(color)") }
        if let highlight = style.highlight { css.append("background-color:\(highlight)") }
        if let size = style.fontSize { css.append("font-size:\(size)pt") }
        if let family = style.fontFamily { css.append("font-family:'\(family.replacingOccurrences(of: "'", with: "").xmlEscaped)'") }
        if !css.isEmpty { html = "<span style=\"\(css.joined(separator: ";"))\">\(html)</span>" }
        if style.code { html = "<code>\(html)</code>" }
        if style.subscript { html = "<sub>\(html)</sub>" }
        if style.superscript { html = "<sup>\(html)</sup>" }
        if style.strikethrough { html = "<s>\(html)</s>" }
        if style.underline { html = "<u>\(html)</u>" }
        if style.italic { html = "<em>\(html)</em>" }
        if style.bold { html = "<strong>\(html)</strong>" }
        if let link = style.link, Self.isSafeLink(link) { html = "<a href=\"\(link.xmlEscaped)\">\(html)</a>" }
        return html
    }

    /// Links in converted files stay inert: no script or local file targets.
    private static func isSafeLink(_ link: String) -> Bool {
        let lowered = link.lowercased().trimmed
        return !lowered.hasPrefix("javascript:") && !lowered.hasPrefix("file:") && !lowered.hasPrefix("data:")
    }

    private func tag(for image: ImageAsset) -> String {
        var attributes = " src=\"\(imageSource(image))\" alt=\"\((image.alt ?? "").xmlEscaped)\""
        if let width = image.width { attributes += " width=\"\(Int(width / 0.75))\"" }
        return xhtml ? "<img\(attributes)/>" : "<img\(attributes)>"
    }

    private func attribute(_ alignment: TextAlignment?) -> String {
        switch alignment {
        case .center: " style=\"text-align:center\""
        case .right: " style=\"text-align:right\""
        case .justified: " style=\"text-align:justify\""
        case .left, nil: ""
        }
    }
}

/// Keeps a table inside its text column without squeezing columns down to single letters,
/// which is what automatic table layout does when any word may break at any character.
enum TableFit {
    /// Longer than the longest words in Polish or English, so ordinary words stay whole.
    private static let longestRun = 20

    /// A word in the pieces it may wrap between. As in typesetting, a line ends after a slash or
    /// a colon and starts with a dot or a query. Failing those, at every `longestRun` characters.
    static func segments(of word: some StringProtocol) -> [String] {
        guard word.count > longestRun else { return [String(word)] }
        var segments: [String] = []
        var current = ""
        for character in word {
            if ".?&=#_~%".contains(character), !current.isEmpty {
                segments.append(current)
                current = ""
            }
            current.append(character)
            if current.count == longestRun || "/\\-:,;@+|".contains(character) {
                segments.append(current)
                current = ""
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// A date, a time or an amount, which reads badly over two lines.
    static func isFigure(_ word: some StringProtocol) -> Bool {
        word.count <= longestRun && word.contains(where: \.isNumber) && word.contains { !$0.isNumber }
            && word.allSatisfy { $0.isNumber || "-./:,+%".contains($0) }
    }

    /// The style a table needs, from the narrowest its columns can get. The text column
    /// holds about 90 characters of table text, 100 in `dense` and 115 in `denser`.
    static func density(of table: ConversionCore.Table) -> String? {
        var narrowest: [Int] = []
        for row in table.rows {
            var column = 0
            for cell in row {
                let span = max(1, cell.columnSpan)
                if column + span > narrowest.count { narrowest += Array(repeating: 0, count: column + span - narrowest.count) }
                if span == 1 { narrowest[column] = max(narrowest[column], longestSegment(in: cell.plainText)) }
                column += span
            }
        }
        let characters = narrowest.reduce(0, +)
        if characters + narrowest.count * 3 <= 82 { return nil }
        if characters + narrowest.count * 2 <= 92 { return "dense" }
        if characters + narrowest.count * 2 <= 106 { return "denser" }
        return "denser fixed"
    }

    /// Column widths that share `total` the way a browser shares a page: each column gets room
    /// for its longest word, and what is left goes where the lines are longest. For formats
    /// that store the widths, as Word's grid does, where equal columns waste space on short
    /// text and squeeze long text into a tall, narrow column.
    static func columnWidths(of table: ConversionCore.Table, total: Int, characterWidth: Int) -> [Int] {
        let layout = TableLayout(table)
        guard layout.columnCount > 0 else { return [] }
        // In characters, with a margin on each side of the text.
        var longestLine = Array(repeating: 1, count: layout.columnCount)
        var longestWord = Array(repeating: 1, count: layout.columnCount)
        for row in layout.rows {
            for placed in row where placed.columnSpan == 1 {
                let text = placed.cell.plainText
                let line = text.split(separator: "\n").map(\.count).max() ?? 0
                longestLine[placed.column] = max(longestLine[placed.column], line)
                longestWord[placed.column] = max(longestWord[placed.column], longestSegment(in: text))
            }
        }
        let wants = longestLine.map { Double($0 + 2) }
        let needs = longestWord.map { Double($0 + 2) }
        let room = Double(total) / Double(characterWidth)
        let shares: [Double]
        if wants.reduce(0, +) <= room || wants.reduce(0, +) <= needs.reduce(0, +) {
            shares = wants
        } else if needs.reduce(0, +) >= room {
            shares = needs
        } else {
            let fraction = (room - needs.reduce(0, +)) / (wants.reduce(0, +) - needs.reduce(0, +))
            shares = zip(needs, wants).map { need, want in need + (want - need) * fraction }
        }
        let sum = shares.reduce(0, +)
        var widths = shares.map { Int((Double(total) * $0 / sum).rounded(.down)) }
        widths[widths.count - 1] += total - widths.reduce(0, +)
        return widths
    }

    private static func longestSegment(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .flatMap { segments(of: $0) }
            .map(\.count)
            .max() ?? 0
    }
}

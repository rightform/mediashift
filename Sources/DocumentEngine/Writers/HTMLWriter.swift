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
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .5em; break-after: avoid; }
        h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; } h4, h5, h6 { font-size: 11pt; }
        p { margin: 0 0 .8em; }
        img { max-width: 100%; height: auto; }
        table { border-collapse: collapse; margin: 1em 0; max-width: 100%; }
        th, td { border: 1px solid #c8c8cc; padding: .35em .6em; text-align: left; vertical-align: top; }
        td > p:last-child, th > p:last-child, li > p:last-child { margin-bottom: 0; }
        th { background: #f2f2f4; }
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
        var html = "<table>\n"
        if let name = table.name { html += "<caption>\(name.xmlEscaped)</caption>\n" }
        for (index, row) in table.rows.enumerated() {
            let cellTag = table.hasHeaderRow && index == 0 ? "th" : "td"
            html += "<tr>"
            for cell in row {
                var attributes = ""
                if cell.columnSpan > 1 { attributes += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
                let content: String
                if cell.blocks.count == 1, case .paragraph(let inlines, _) = cell.blocks[0] {
                    content = render(inlines)
                } else {
                    content = render(cell.blocks)
                }
                html += "<\(cellTag)\(attributes)>\(content)</\(cellTag)>"
            }
            html += "</tr>\n"
        }
        return html + "</table>"
    }

    func render(_ inlines: [Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text, let style): decorate(text.xmlEscaped.replacingOccurrences(of: "\t", with: "&#160;&#160;&#160;&#160;"), style)
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

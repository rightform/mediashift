import ConversionCore
import Foundation

public enum HTMLReader {
    public static func read(_ url: URL) throws -> RichDocument {
        let text = TextDecoding.decode(try Data(contentsOf: url))
        let document = parse(text, baseURL: url.deletingLastPathComponent())
        if document.blocks.isEmpty && !text.trimmed.isEmpty {
            throw ConversionError("No readable content was found in this HTML file.")
        }
        return document
    }

    /// Reads possibly malformed HTML through the system's tidy parser. External
    /// entities and remote resources are never loaded.
    public static func parse(_ html: String, baseURL: URL? = nil) -> RichDocument {
        guard
            let document = try? XMLDocument(
                xmlString: html,
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]
            ),
            let root = document.rootElement()
        else { return RichDocument() }

        let title = root.descendant("title")?.stringValue?.trimmed
        let author = (root.descendant("head")?.children(named: "meta") ?? [])
            .first { $0.value(of: "name")?.lowercased() == "author" }?
            .value(of: "content")
        let body = root.child("body") ?? root
        var parser = HTMLBlockParser(baseURL: baseURL)
        return RichDocument(title: title?.isEmpty == true ? nil : title, author: author, blocks: parser.blocks(in: body))
    }
}

struct HTMLBlockParser {
    let baseURL: URL?

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "div", "dl", "dd", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main",
        "nav", "ol", "p", "pre", "section", "table", "ul",
    ]
    private static let ignoredTags: Set<String> = ["script", "style", "head", "noscript", "template", "svg", "iframe", "object"]

    /// Walks a container, gathering loose inline content into paragraphs between block children.
    mutating func blocks(in element: XMLElement) -> [Block] {
        var result: [Block] = []
        var pending: [Inline] = []
        let alignment = Self.alignment(of: element)

        func flush(_ result: inout [Block]) {
            let content = Self.tidy(pending)
            if !content.isEmpty {
                if content.count == 1, case .image(let image) = content[0] {
                    result.append(.image(image))
                } else {
                    result.append(.paragraph(content: content, alignment: alignment))
                }
            }
            pending = []
        }

        for node in element.children ?? [] {
            if node.kind == .text {
                pending += [.text(node.stringValue?.whitespaceCollapsed ?? "")]
                continue
            }
            guard let child = node as? XMLElement else { continue }
            let name = child.plainName.lowercased()
            if Self.ignoredTags.contains(name) { continue }
            if Self.blockTags.contains(name) {
                flush(&result)
                result += blockElement(child, name: name)
            } else {
                pending += inlines(in: child, style: TextStyle(), asElement: true)
            }
        }
        flush(&result)
        return result
    }

    private mutating func blockElement(_ element: XMLElement, name: String) -> [Block] {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            let content = Self.tidy(inlines(in: element, style: TextStyle()))
            return content.isEmpty ? [] : [.heading(level: level, content: content, alignment: Self.alignment(of: element))]
        case "p":
            let content = Self.tidy(inlines(in: element, style: Self.style(of: element, base: TextStyle())))
            if content.isEmpty { return [] }
            if content.count == 1, case .image(let image) = content[0] { return [.image(image)] }
            return [.paragraph(content: content, alignment: Self.alignment(of: element))]
        case "ul", "ol":
            let items = element.children(named: "li").map { blocks(in: $0) }
            return items.isEmpty ? [] : [.list(ordered: name == "ol", items: items)]
        case "pre":
            return [.code(element.stringValue ?? "", language: nil)]
        case "blockquote":
            return [.quote(blocks(in: element))]
        case "hr":
            return [.rule]
        case "table":
            return table(element).map { [.table($0)] } ?? []
        default:
            if Self.style(of: element, base: TextStyle()) != TextStyle(),
                Self.hasOnlyInlineContent(element)
            {
                let content = Self.tidy(inlines(in: element, style: Self.style(of: element, base: TextStyle())))
                return content.isEmpty ? [] : [.paragraph(content: content, alignment: Self.alignment(of: element))]
            }
            return blocks(in: element)
        }
    }

    private static func hasOnlyInlineContent(_ element: XMLElement) -> Bool {
        element.childElements.allSatisfy { !blockTags.contains($0.plainName.lowercased()) }
    }

    private mutating func table(_ element: XMLElement) -> ConversionCore.Table? {
        var rows: [[TableCell]] = []
        var hasHeader = false

        func rowElements(_ parent: XMLElement) -> [XMLElement] {
            parent.childElements.flatMap { child -> [XMLElement] in
                switch child.plainName.lowercased() {
                case "tr": [child]
                case "thead", "tbody", "tfoot": rowElements(child)
                default: []
                }
            }
        }

        for row in rowElements(element) {
            let cells = row.childElements.filter { ["td", "th"].contains($0.plainName.lowercased()) }
            if rows.isEmpty, !cells.isEmpty, cells.allSatisfy({ $0.plainName.lowercased() == "th" }) {
                hasHeader = true
            }
            rows.append(
                cells.map { cell in
                    TableCell(
                        blocks: blocks(in: cell),
                        columnSpan: Int(cell.value(of: "colspan") ?? "") ?? 1,
                        rowSpan: Int(cell.value(of: "rowspan") ?? "") ?? 1
                    )
                })
        }
        return rows.isEmpty ? nil : ConversionCore.Table(rows: rows, hasHeaderRow: hasHeader)
    }

    private func inlines(in element: XMLElement, style: TextStyle, asElement: Bool = false) -> [Inline] {
        if asElement { return inline(element, style: style) }
        return (element.children ?? []).flatMap { node -> [Inline] in
            if node.kind == .text {
                let text = node.stringValue?.whitespaceCollapsed ?? ""
                return text.isEmpty ? [] : [.text(text, style)]
            }
            guard let child = node as? XMLElement else { return [] }
            return inline(child, style: style)
        }
    }

    private func inline(_ element: XMLElement, style base: TextStyle) -> [Inline] {
        let name = element.plainName.lowercased()
        if Self.ignoredTags.contains(name) { return [] }
        var style = Self.style(of: element, base: base)
        switch name {
        case "br":
            return [.lineBreak]
        case "img":
            let alt = element.value(of: "alt")
            guard let source = element.value(of: "src"),
                var asset = LocalImageLoader.load(source: source, relativeTo: baseURL, alt: alt)
            else {
                return alt.map { [.text($0, style)] } ?? []
            }
            asset.width = Self.pixels(element.value(of: "width"))
            asset.height = Self.pixels(element.value(of: "height"))
            return [.image(asset)]
        case "b", "strong": style.bold = true
        case "i", "em", "cite", "dfn": style.italic = true
        case "u", "ins": style.underline = true
        case "s", "strike", "del": style.strikethrough = true
        case "code", "kbd", "samp", "tt": style.code = true
        case "sup": style.superscript = true
        case "sub": style.subscript = true
        case "a":
            if let target = element.value(of: "href"), !target.isEmpty, !target.hasPrefix("#") { style.link = target }
        case "font":
            if let color = element.value(of: "color") { style.color = Self.hexColor(color) }
            if let face = element.value(of: "face") { style.fontFamily = face }
        default:
            break
        }
        return inlines(in: element, style: style)
    }

    // MARK: - Inline CSS

    private static func declarations(of element: XMLElement) -> [String: String] {
        guard let css = element.value(of: "style") else { return [:] }
        var result: [String: String] = [:]
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    private static func style(of element: XMLElement, base: TextStyle) -> TextStyle {
        var style = base
        let css = declarations(of: element)
        if let weight = css["font-weight"]?.lowercased() {
            style.bold = weight.contains("bold") || (Int(weight) ?? 400) >= 600
        }
        if let fontStyle = css["font-style"]?.lowercased() { style.italic = fontStyle.contains("italic") }
        if let decoration = (css["text-decoration"] ?? css["text-decoration-line"])?.lowercased() {
            if decoration.contains("underline") { style.underline = true }
            if decoration.contains("line-through") { style.strikethrough = true }
        }
        if let color = css["color"].flatMap(hexColor) { style.color = color }
        if let highlight = css["background-color"].flatMap(hexColor) { style.highlight = highlight }
        if let size = css["font-size"].flatMap(points) { style.fontSize = size }
        if let family = css["font-family"] {
            style.fontFamily = family.split(separator: ",").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return style
    }

    private static func alignment(of element: XMLElement) -> TextAlignment? {
        let value = (declarations(of: element)["text-align"] ?? element.value(of: "align"))?.lowercased()
        switch value {
        case "center": return .center
        case "right": return .right
        case "justify": return .justified
        case "left": return .left
        default: return element.plainName.lowercased() == "center" ? .center : nil
        }
    }

    private static func points(_ css: String) -> Double? {
        let value = css.lowercased()
        if value.hasSuffix("pt") { return Double(value.dropLast(2)) }
        if value.hasSuffix("px") { return Double(value.dropLast(2)).map { $0 * 0.75 } }
        return nil
    }

    private static func pixels(_ value: String?) -> Double? {
        guard let value, !value.hasSuffix("%") else { return nil }
        return Double(value.replacingOccurrences(of: "px", with: "")).map { $0 * 0.75 }
    }

    /// Accepts `#abc`, `#aabbcc`, `rgb(1, 2, 3)` and a few common names.
    static func hexColor(_ css: String) -> String? {
        let value = css.trimmed.lowercased()
        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            if hex.count == 6 { return "#" + hex.uppercased() }
            if hex.count == 3 { return "#" + hex.map { "\($0)\($0)" }.joined().uppercased() }
            return nil
        }
        if value.hasPrefix("rgb") {
            let numbers = value.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 3 else { return nil }
            if numbers.count == 4, numbers[3] == 0 { return nil }
            return String(format: "#%02X%02X%02X", Int(numbers[0]), Int(numbers[1]), Int(numbers[2]))
        }
        let names = ["black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#008000", "blue": "#0000FF", "gray": "#808080", "grey": "#808080", "yellow": "#FFFF00", "orange": "#FFA500", "purple": "#800080"]
        return names[value]
    }

    /// Trims the whitespace HTML rendering would ignore: at paragraph edges and doubled between runs.
    static func tidy(_ inlines: [Inline]) -> [Inline] {
        var result: [Inline] = []
        for inline in inlines {
            guard case .text(var text, let style) = inline else {
                result.append(inline)
                continue
            }
            let atStart: Bool
            if let last = result.last {
                switch last {
                case .text(let previous, _): atStart = previous.hasSuffix(" ")
                case .lineBreak: atStart = true
                case .image: atStart = false
                }
            } else {
                atStart = true
            }
            if atStart, text.hasPrefix(" ") { text.removeFirst() }
            if text.isEmpty { continue }
            if case .text(let previous, let previousStyle)? = result.last, previousStyle == style {
                result[result.count - 1] = .text(previous + text, style)
            } else {
                result.append(.text(text, style))
            }
        }
        while case .text(let text, let style)? = result.last, text.hasSuffix(" ") {
            let stripped = String(text.dropLast())
            if stripped.isEmpty { result.removeLast() } else { result[result.count - 1] = .text(stripped, style) }
        }
        return result
    }
}

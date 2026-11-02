import ConversionCore
import Foundation

public enum PlainTextWriter {
    public static func write(_ document: RichDocument, to url: URL) throws {
        try Data(render(document).utf8).write(to: url, options: .atomic)
    }

    public static func render(_ document: RichDocument) -> String {
        var sections: [String] = []
        for block in document.blocks {
            let text = render(block, indent: "")
            if !text.isEmpty { sections.append(text) }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func render(_ block: Block, indent: String) -> String {
        switch block {
        case .heading(_, let content, _), .paragraph(let content, _):
            return indent + content.plainText
        case .list(let ordered, let items):
            return items.enumerated().map { index, item in
                let marker = ordered ? "\(index + 1). " : "- "
                let lines = item.map { render($0, indent: indent + String(repeating: " ", count: marker.count)) }
                let body = lines.joined(separator: "\n")
                let bare = body.dropFirst(indent.count + marker.count)
                return indent + marker + bare
            }.joined(separator: "\n")
        case .table(let table):
            // A merged cell keeps its text in its first column, so the columns below still line up.
            return TableLayout(table).textRows().map { row in indent + row.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
                .joined(separator: "\n")
        case .image(let image):
            return image.alt.map { indent + $0 } ?? ""
        case .code(let code, _):
            return code
        case .quote(let blocks):
            return blocks.map { render($0, indent: indent + "    ") }.joined(separator: "\n\n")
        case .rule, .pageBreak:
            return ""
        }
    }
}

public enum MarkdownWriter {
    public static func write(_ document: RichDocument, to url: URL) throws {
        // Images travel in a folder next to the file, the way Markdown editors expect.
        let imagesFolder = url.deletingPathExtension().lastPathComponent + "-images"
        var renderer = Renderer(imagesFolder: imagesFolder)
        let text = renderer.render(document)
        try Data(text.utf8).write(to: url, options: .atomic)
        if !renderer.images.isEmpty {
            let folder = url.deletingLastPathComponent().appendingPathComponent(imagesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, asset) in renderer.images {
                try asset.data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
        }
    }

    public static func render(_ document: RichDocument) -> String {
        var renderer = Renderer(imagesFolder: "images")
        return renderer.render(document)
    }

    private struct Renderer {
        let imagesFolder: String
        var images: [(String, ImageAsset)] = []

        mutating func render(_ document: RichDocument) -> String {
            var parts: [String] = []
            for block in document.blocks {
                let text = render(block)
                if !text.isEmpty { parts.append(text) }
            }
            return parts.joined(separator: "\n\n") + "\n"
        }

        mutating func render(_ block: Block) -> String {
            switch block {
            case .heading(let level, let content, _):
                return String(repeating: "#", count: max(1, min(level, 6))) + " " + render(content).replacingOccurrences(of: "\n", with: " ")
            case .paragraph(let content, _):
                return render(content)
            case .list(let ordered, let items):
                return items.enumerated().map { index, item in
                    let marker = ordered ? "\(index + 1). " : "- "
                    let padding = String(repeating: " ", count: marker.count)
                    let body = item.map { render($0) }.filter { !$0.isEmpty }
                    var lines: [String] = []
                    for (blockIndex, text) in body.enumerated() {
                        if blockIndex > 0, isBlockSpaced(item[min(blockIndex, item.count - 1)]) { lines.append("") }
                        lines += text.components(separatedBy: "\n")
                    }
                    if lines.isEmpty { return marker.trimmed }
                    return lines.enumerated().map { lineIndex, line in
                        lineIndex == 0 ? marker + line : (line.isEmpty ? "" : padding + line)
                    }.joined(separator: "\n")
                }.joined(separator: "\n")
            case .table(let table):
                return render(table)
            case .image(let image):
                return imageReference(image)
            case .code(let code, let language):
                return "```\(language ?? "")\n\(code)\n```"
            case .quote(let blocks):
                return blocks.map { render($0) }.joined(separator: "\n\n")
                    .components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            case .rule:
                return "---"
            case .pageBreak:
                return ""
            }
        }

        private func isBlockSpaced(_ block: Block) -> Bool {
            if case .list = block { return false }
            return true
        }

        private mutating func render(_ table: ConversionCore.Table) -> String {
            // Markdown has no merged cells, so a merged cell keeps its text in its first column
            // and leaves the others empty, in its own row and in the rows it spans.
            let layout = TableLayout(table)
            guard layout.columnCount > 0 else { return "" }
            var lines: [String] = []
            for (index, row) in layout.rows.enumerated() {
                var cells = Array(repeating: "", count: layout.columnCount)
                for placed in row {
                    cells[placed.column] = placed.cell.blocks.map { render($0) }.joined(separator: "<br>")
                        .replacingOccurrences(of: "  \n", with: "<br>")
                        .replacingOccurrences(of: "\n", with: "<br>")
                        .replacingOccurrences(of: "|", with: "\\|")
                }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if index == 0 {
                    lines.append("|" + Array(repeating: " --- ", count: layout.columnCount).joined(separator: "|") + "|")
                }
            }
            return lines.joined(separator: "\n")
        }

        private mutating func render(_ inlines: [Inline]) -> String {
            var result = ""
            for inline in inlines {
                switch inline {
                case .text(let text, let style):
                    result += decorate(text, style)
                case .lineBreak:
                    result += "  \n"
                case .image(let image):
                    result += imageReference(image)
                }
            }
            return result
        }

        private mutating func imageReference(_ image: ImageAsset) -> String {
            let name = "image-\(images.count + 1).\(image.fileExtension)"
            images.append((name, image))
            return "![\(image.alt ?? "")](\(imagesFolder)/\(name))"
        }

        private func decorate(_ text: String, _ style: TextStyle) -> String {
            if text.trimmed.isEmpty { return text }
            if style.code {
                let wrapped = "`\(text)`"
                return style.link.map { "[\(wrapped)](\($0))" } ?? wrapped
            }
            // Emphasis markers must touch the words, so surrounding spaces stay outside.
            let leading = text.prefix { $0.isWhitespace }
            let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
            let core = escape(text.trimmed)
            var body = core
            if style.strikethrough { body = "~~\(body)~~" }
            if style.italic { body = "*\(body)*" }
            if style.bold { body = "**\(body)**" }
            if let link = style.link { body = "[\(body)](\(link))" }
            return leading + body + trailing
        }

        private func escape(_ text: String) -> String {
            var result = ""
            for character in text {
                if "\\`*_[]<>".contains(character) { result.append("\\") }
                result.append(character)
            }
            return result
        }
    }
}

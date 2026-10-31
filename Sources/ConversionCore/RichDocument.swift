import Foundation

/// The hub of document conversion. Every reader produces a `RichDocument` and every
/// writer consumes one, so adding a format means writing one reader or one writer
/// instead of a converter for every other format.
public struct RichDocument: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var blocks: [Block]

    public init(title: String? = nil, author: String? = nil, blocks: [Block] = []) {
        self.title = title
        self.author = author
        self.blocks = blocks
    }
}

public enum TextAlignment: String, Sendable, Equatable {
    case left, center, right, justified
}

public indirect enum Block: Sendable, Equatable {
    case heading(level: Int, content: [Inline], alignment: TextAlignment? = nil)
    case paragraph(content: [Inline], alignment: TextAlignment? = nil)
    case list(ordered: Bool, items: [[Block]])
    case table(Table)
    case image(ImageAsset)
    case code(String, language: String? = nil)
    case quote([Block])
    case rule
    /// A hard boundary: a page in a document, a slide in a presentation, a sheet in a workbook.
    case pageBreak
}

public enum Inline: Sendable, Equatable {
    case text(String, TextStyle = TextStyle())
    case lineBreak
    case image(ImageAsset)
}

public struct TextStyle: Sendable, Equatable, Hashable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var code = false
    public var superscript = false
    public var `subscript` = false
    public var link: String?
    /// `#RRGGBB`
    public var color: String?
    /// `#RRGGBB`
    public var highlight: String?
    /// In points.
    public var fontSize: Double?
    public var fontFamily: String?

    public init(
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        code: Bool = false,
        superscript: Bool = false,
        subscript: Bool = false,
        link: String? = nil,
        color: String? = nil,
        highlight: String? = nil,
        fontSize: Double? = nil,
        fontFamily: String? = nil
    ) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.code = code
        self.superscript = superscript
        self.subscript = `subscript`
        self.link = link
        self.color = color
        self.highlight = highlight
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }
}

public struct Table: Sendable, Equatable {
    /// Sheet name, when the table comes from a workbook.
    public var name: String?
    /// As in HTML, a row lists only the cells that start in it. Positions covered by a
    /// span from a cell to the left or above are left out.
    public var rows: [[TableCell]]
    public var hasHeaderRow: Bool

    public init(name: String? = nil, rows: [[TableCell]], hasHeaderRow: Bool = false) {
        self.name = name
        self.rows = rows
        self.hasHeaderRow = hasHeaderRow
    }
}

public struct TableCell: Sendable, Equatable {
    public var blocks: [Block]
    public var columnSpan: Int
    public var rowSpan: Int

    public init(blocks: [Block], columnSpan: Int = 1, rowSpan: Int = 1) {
        self.blocks = blocks
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }

    /// A cell holding one plain paragraph.
    public init(text: String) {
        self.init(blocks: text.isEmpty ? [] : [.paragraph(content: [.text(text)])])
    }

    /// The cell's text without formatting.
    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }
}

public struct ImageAsset: Sendable, Equatable {
    public var data: Data
    /// For example `image/png`.
    public var mimeType: String
    public var alt: String?
    /// Intended display size in points, when the source states one.
    public var width: Double?
    public var height: Double?

    public init(data: Data, mimeType: String, alt: String? = nil, width: Double? = nil, height: Double? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.alt = alt
        self.width = width
        self.height = height
    }

    /// The extension for this image's MIME type, used when a format stores images as files.
    public var fileExtension: String {
        switch mimeType.lowercased() {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/svg+xml": "svg"
        case "image/webp": "webp"
        case "image/tiff": "tiff"
        case "image/bmp": "bmp"
        case "image/heic": "heic"
        default: "bin"
        }
    }
}

// MARK: - Plain text

extension Inline {
    public var plainText: String {
        switch self {
        case .text(let text, _): text
        case .lineBreak: "\n"
        case .image(let image): image.alt ?? ""
        }
    }
}

extension [Inline] {
    public var plainText: String {
        map(\.plainText).joined()
    }
}

extension Block {
    /// The block's text with all formatting removed.
    public var plainText: String {
        switch self {
        case .heading(_, let content, _), .paragraph(let content, _):
            content.plainText
        case .list(_, let items):
            items.map { $0.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .table(let table):
            table.rows.map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
        case .image(let image):
            image.alt ?? ""
        case .code(let code, _):
            code
        case .quote(let blocks):
            blocks.map(\.plainText).joined(separator: "\n")
        case .rule, .pageBreak:
            ""
        }
    }
}

extension RichDocument {
    public var plainText: String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The first heading, used as a title when the source has no metadata.
    public var inferredTitle: String? {
        if let title, !title.isEmpty { return title }
        for block in blocks {
            if case .heading(_, let content, _) = block {
                let text = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}

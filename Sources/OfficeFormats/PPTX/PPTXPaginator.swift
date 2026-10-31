import ConversionCore
import Foundation

/// A slide before it becomes XML.
struct PPTXSlide {
    enum Bullet: Equatable {
        case none, unordered, ordered
    }

    struct Paragraph {
        var content: [Inline]
        var level = 0
        var bullet = Bullet.none
        var alignment: TextAlignment?
        /// Applied under each run's own style, for headings, code and quotes.
        var baseStyle = TextStyle()
    }

    struct TableRow {
        enum Slot {
            case cell(TableCell, columnSpan: Int, rowSpan: Int)
            case empty
            /// Covered by a merge starting to the left and, or, above.
            case covered(fromLeft: Bool, fromAbove: Bool, columnSpan: Int)
        }

        var slots: [Slot]
        var height: Double
    }

    enum Item {
        case text([Paragraph], height: Double)
        case table(rows: [TableRow], columnWidths: [Double], hasHeaderRow: Bool)
        case image(ImageAsset, PreparedImage, width: Double, height: Double)
        case fullBleedImage(ImageAsset, PreparedImage)
    }

    var title: [Inline]?
    var items: [Item] = []
}

/// Flows a document's blocks over slides. Text is measured with a rough estimate, since real
/// font metrics depend on the viewer, and the text boxes also carry autofit as a safety net.
struct PPTXPaginator {
    /// Slide geometry in points, matching PowerPoint's own 16:9 default layout.
    enum Geometry {
        static let slideWidth = 960.0
        static let slideHeight = 540.0
        static let marginX = 66.0
        static let contentWidth = 828.0
        static let titleY = 28.75
        static let titleHeight = 104.4
        static let bodyY = 143.75
        static let bodyHeight = 342.6
        static let untitledBodyY = 28.75
        static let untitledBodyHeight = 457.6
        static let textInset = 14.4
        static let bodyFontSize = 20.0
        static let tableFontSize = 14.0
    }

    private let media: PPTXMedia
    private var slides: [PPTXSlide] = []
    private var current = PPTXSlide()
    private var used = 0.0
    /// Paragraphs waiting to become one text item.
    private var pendingText: [PPTXSlide.Paragraph] = []
    private var pendingHeight = 0.0
    private var hasOversizedTable = false

    static func slides(for document: RichDocument, media: PPTXMedia) throws -> [PPTXSlide] {
        var paginator = PPTXPaginator(media: media)
        for block in document.blocks { paginator.add(block) }
        paginator.finishSlide()
        if paginator.hasOversizedTable {
            throw ConversionError("This table is too large for a presentation.")
        }
        return paginator.slides.isEmpty ? [PPTXSlide()] : paginator.slides
    }

    private init(media: PPTXMedia) {
        self.media = media
    }

    private var capacity: Double {
        current.title == nil ? Geometry.untitledBodyHeight : Geometry.bodyHeight
    }

    private var remaining: Double {
        capacity - used
    }

    private var isCurrentEmpty: Bool {
        current.title == nil && current.items.isEmpty && pendingText.isEmpty
    }

    private mutating func finishSlide() {
        flushText()
        if !isCurrentEmpty { slides.append(current) }
        current = PPTXSlide()
        used = 0
    }

    /// Ends the slide and carries its title over.
    private mutating func continueOnNewSlide() {
        let title = current.title
        finishSlide()
        current.title = title
    }

    private mutating func flushText() {
        guard !pendingText.isEmpty else { return }
        current.items.append(.text(pendingText, height: pendingHeight))
        pendingText = []
        pendingHeight = 0
    }

    // MARK: Blocks

    private mutating func add(_ block: Block) {
        switch block {
        case .pageBreak:
            finishSlide()
        case .heading(let level, let content, let alignment):
            if level <= 2 {
                startSlide(title: content)
            } else {
                var paragraph = PPTXSlide.Paragraph(content: content, alignment: alignment)
                paragraph.baseStyle = TextStyle(bold: true, fontSize: 22)
                add(paragraph)
            }
        case .paragraph(let content, let alignment):
            addInlines(content, alignment: alignment, level: 0, bullet: .none, baseStyle: TextStyle())
        case .list(let ordered, let items):
            addList(ordered: ordered, items: items, level: 0)
        case .table(let table):
            add(table)
        case .image(let asset):
            add(asset)
        case .code(let code, _):
            for line in code.components(separatedBy: .newlines) {
                add(PPTXSlide.Paragraph(content: [.text(line)], baseStyle: TextStyle(fontSize: 14, fontFamily: "Menlo")))
            }
        case .quote(let blocks):
            addQuote(blocks)
        case .rule:
            break
        }
    }

    private mutating func startSlide(title: [Inline]) {
        // A heading right after a page break or at the very start owns the empty slide.
        if !isCurrentEmpty { finishSlide() }
        current.title = title
    }

    private mutating func addQuote(_ blocks: [Block]) {
        for block in blocks {
            switch block {
            case .paragraph(let content, let alignment):
                addInlines(content, alignment: alignment, level: 1, bullet: .none, baseStyle: TextStyle(italic: true))
            case .quote(let inner):
                addQuote(inner)
            default:
                add(block)
            }
        }
    }

    private mutating func addList(ordered: Bool, items: [[Block]], level: Int) {
        for item in items {
            var bulletUsed = false
            for block in item {
                switch block {
                case .paragraph(let content, let alignment):
                    addInlines(content, alignment: alignment, level: level, bullet: bulletUsed ? .none : (ordered ? .ordered : .unordered), baseStyle: TextStyle())
                    bulletUsed = true
                case .list(let innerOrdered, let inner):
                    addList(ordered: innerOrdered, items: inner, level: min(level + 1, 8))
                default:
                    add(block)
                }
            }
        }
    }

    /// Lifts inline images out of the text, since a slide cannot hold them in a line.
    private mutating func addInlines(_ content: [Inline], alignment: TextAlignment?, level: Int, bullet: PPTXSlide.Bullet, baseStyle: TextStyle) {
        var run: [Inline] = []
        var bullet = bullet
        func paragraph(_ inlines: [Inline]) -> PPTXSlide.Paragraph {
            PPTXSlide.Paragraph(content: inlines, level: level, bullet: bullet, alignment: alignment, baseStyle: baseStyle)
        }
        for inline in content {
            if case .image(let asset) = inline {
                if !run.isEmpty {
                    add(paragraph(run))
                    bullet = .none
                    run = []
                }
                add(asset)
            } else {
                run.append(inline)
            }
        }
        if !run.plainText.isEmpty { add(paragraph(run)) }
    }

    // MARK: Text

    private mutating func add(_ paragraph: PPTXSlide.Paragraph) {
        var rest = paragraph
        while true {
            let height = Self.height(of: rest)
            if height <= remaining {
                pendingText.append(rest)
                pendingHeight += height
                used += height
                return
            }
            // Keep a paragraph whole if a fresh slide can hold it. Otherwise fill this one.
            let freshCapacity = current.title == nil ? Geometry.untitledBodyHeight : Geometry.bodyHeight
            if height <= freshCapacity && !isBodyEmpty {
                continueOnNewSlide()
                continue
            }
            let fontSize = Self.fontSize(of: rest)
            let spareLines = Int((remaining - Self.spacing(fontSize)) / (fontSize * 1.2))
            guard spareLines >= 1,
                let (head, tail) = Self.split(rest, maxCharacters: spareLines * Self.charactersPerLine(for: rest))
            else {
                if isBodyEmpty {
                    // Nothing can make it fit, so take it as it is and let autofit shrink it.
                    pendingText.append(rest)
                    pendingHeight += height
                    used += height
                    return
                }
                continueOnNewSlide()
                continue
            }
            pendingText.append(head)
            let headHeight = Self.height(of: head)
            pendingHeight += headHeight
            used += headHeight
            continueOnNewSlide()
            rest = tail
        }
    }

    private var isBodyEmpty: Bool {
        current.items.isEmpty && pendingText.isEmpty
    }

    private static func fontSize(of paragraph: PPTXSlide.Paragraph) -> Double {
        paragraph.baseStyle.fontSize ?? max(12, Geometry.bodyFontSize - Double(paragraph.level) * 2)
    }

    private static func spacing(_ fontSize: Double) -> Double {
        fontSize * 0.5
    }

    private static func charactersPerLine(for paragraph: PPTXSlide.Paragraph) -> Int {
        let width = Geometry.contentWidth - Geometry.textInset - Double(paragraph.level + 1) * 27
        // 0.5 em is a fair average advance for proportional text; monospaced is wider.
        let advance = fontSize(of: paragraph) * (paragraph.baseStyle.fontFamily == nil ? 0.5 : 0.6)
        return max(10, Int(width / advance))
    }

    static func height(of paragraph: PPTXSlide.Paragraph) -> Double {
        let size = fontSize(of: paragraph)
        let perLine = charactersPerLine(for: paragraph)
        let lines = paragraph.content.plainText
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
        return Double(max(1, lines)) * size * 1.2 + spacing(size)
    }

    /// Splits runs at the last word boundary within the limit. Nil when the text is already short.
    private static func split(_ paragraph: PPTXSlide.Paragraph, maxCharacters: Int) -> (PPTXSlide.Paragraph, PPTXSlide.Paragraph)? {
        guard paragraph.content.plainText.count > maxCharacters, maxCharacters > 0 else { return nil }
        var head: [Inline] = []
        var tail: [Inline] = []
        var taken = 0
        var done = false
        for inline in paragraph.content {
            if done {
                tail.append(inline)
                continue
            }
            switch inline {
            case .text(let text, let style):
                if taken + text.count <= maxCharacters {
                    head.append(inline)
                    taken += text.count
                } else {
                    let room = maxCharacters - taken
                    let limit = text.index(text.startIndex, offsetBy: room)
                    let cut = text[..<limit].lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? (taken == 0 ? limit : text.startIndex)
                    let first = String(text[..<cut])
                    let second = String(text[cut...])
                    if !first.isEmpty { head.append(.text(first, style)) }
                    if !second.isEmpty { tail.append(.text(second, style)) }
                    done = true
                }
            case .lineBreak:
                head.append(inline)
                taken += 1
            case .image:
                break
            }
        }
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        var first = paragraph
        first.content = head
        var second = paragraph
        second.content = tail
        // The continuation reads as the same point, not a new bullet.
        second.bullet = .none
        return (first, second)
    }

    // MARK: Tables

    /// Thousands of slides of one table help nobody, and the grid below costs memory.
    private static let maxTableSlots = 1_000_000

    private mutating func add(_ table: Table) {
        let layout = TableLayout(table)
        guard layout.columnCount > 0, !layout.rows.isEmpty else { return }
        guard layout.columnCount * layout.rows.count <= Self.maxTableSlots else {
            hasOversizedTable = true
            return
        }
        flushText()
        let widths = Self.columnWidths(for: layout)

        var grid: [[PPTXSlide.TableRow.Slot]] = layout.rows.map { _ in
            Array(repeating: PPTXSlide.TableRow.Slot.empty, count: layout.columnCount)
        }
        for (rowIndex, row) in layout.rows.enumerated() {
            for placed in row {
                grid[rowIndex][placed.column] = .cell(placed.cell, columnSpan: placed.columnSpan, rowSpan: placed.rowSpan)
                for r in rowIndex..<(rowIndex + placed.rowSpan) {
                    for c in placed.column..<min(placed.column + placed.columnSpan, layout.columnCount) where r != rowIndex || c != placed.column {
                        grid[r][c] = .covered(fromLeft: c != placed.column, fromAbove: r != rowIndex, columnSpan: c == placed.column ? placed.columnSpan : 1)
                    }
                }
            }
        }
        let rows = grid.map { slots in
            PPTXSlide.TableRow(slots: slots, height: Self.rowHeight(slots, widths: widths))
        }

        let header = table.hasHeaderRow ? rows.first : nil
        var chunk: [PPTXSlide.TableRow] = []
        var chunkHeight = 0.0
        var index = 0
        while index < rows.count {
            let row = rows[index]
            if row.height <= remaining - chunkHeight || (chunk.isEmpty && isBodyEmpty) {
                chunk.append(row)
                chunkHeight += row.height
                index += 1
                continue
            }
            if !chunk.isEmpty {
                current.items.append(.table(rows: Self.clippingMerges(chunk), columnWidths: widths, hasHeaderRow: table.hasHeaderRow))
                used += chunkHeight
            }
            continueOnNewSlide()
            chunk = []
            chunkHeight = 0
            if let header, index > 0 {
                chunk.append(header)
                chunkHeight += header.height
            }
        }
        if !chunk.isEmpty {
            current.items.append(.table(rows: Self.clippingMerges(chunk), columnWidths: widths, hasHeaderRow: table.hasHeaderRow))
            used += chunkHeight + PPTXSlideBuilder.tableGap
        }
    }

    /// Makes a slice of a table self-contained where a merge crosses the cut.
    private static func clippingMerges(_ rows: [PPTXSlide.TableRow]) -> [PPTXSlide.TableRow] {
        var result = rows
        for (rowIndex, row) in rows.enumerated() {
            for (column, slot) in row.slots.enumerated() {
                switch slot {
                case .cell(let cell, let columnSpan, let rowSpan) where rowIndex + rowSpan > rows.count:
                    result[rowIndex].slots[column] = .cell(cell, columnSpan: columnSpan, rowSpan: rows.count - rowIndex)
                case .covered(_, true, _) where rowIndex == 0:
                    result[rowIndex].slots[column] = .empty
                default:
                    break
                }
            }
        }
        return result
    }

    private static func columnWidths(for layout: TableLayout) -> [Double] {
        var weights = Array(repeating: 1.0, count: layout.columnCount)
        for row in layout.rows.prefix(200) {
            for placed in row where placed.columnSpan == 1 {
                weights[placed.column] = max(weights[placed.column], min(40, Double(placed.cell.plainText.count)))
            }
        }
        let total = weights.reduce(0, +)
        // Nobody below a fair minimum, the rest shared by content length.
        let minimum = min(60, Geometry.contentWidth / Double(layout.columnCount))
        let spare = Geometry.contentWidth - minimum * Double(layout.columnCount)
        return weights.map { minimum + spare * $0 / total }
    }

    private static func rowHeight(_ slots: [PPTXSlide.TableRow.Slot], widths: [Double]) -> Double {
        var lines = 1
        for (column, slot) in slots.enumerated() {
            guard case .cell(let cell, let columnSpan, let rowSpan) = slot, rowSpan == 1 else { continue }
            let width = widths[column..<min(column + columnSpan, widths.count)].reduce(0, +) - 14.4
            let perLine = max(4, Int(width / (Geometry.tableFontSize * 0.5)))
            let cellLines = cell.plainText
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
            lines = max(lines, cellLines)
        }
        return Double(lines) * Geometry.tableFontSize * 1.2 + 10
    }

    // MARK: Images

    private mutating func add(_ asset: ImageAsset) {
        guard let image = media.prepare(asset) else {
            // An image no viewer could show still leaves its description.
            if let alt = asset.alt, !alt.isEmpty {
                add(PPTXSlide.Paragraph(content: [.text(alt)]))
            }
            return
        }
        flushText()
        let (naturalWidth, naturalHeight) = ImageSupport.naturalSize(of: asset, image)

        // Start a new slide unless the image can still be shown at a useful size here.
        let usefulHeight = min(naturalHeight, 140)
        if remaining < usefulHeight && !isBodyEmpty {
            continueOnNewSlide()
        }
        let scale = min(1, Geometry.contentWidth / naturalWidth, remaining / naturalHeight)
        let width = naturalWidth * scale
        let height = naturalHeight * scale
        current.items.append(.image(asset, image, width: width, height: height))
        used += height + 8
    }
}

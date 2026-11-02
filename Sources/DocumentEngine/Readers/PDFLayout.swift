import AppKit
import ConversionCore
import Foundation
import PDFKit

/// Rebuilds a page's structure from where its characters sit. The text of a PDF comes in
/// the order it was drawn, which PDFKit turns into a fair reading order for running text,
/// columns included, but not for tables: those it reads column by column, or each row as one
/// line. So tables are found from positions, and everything else keeps PDFKit's order, with
/// positions deciding where paragraphs end and where lists are.
struct PDFLayout {
    struct Run {
        var text: String
        var minX: CGFloat
        var maxX: CGFloat
        var size: CGFloat
        var bold: Bool
    }

    struct Line {
        var runs: [Run]
        var top: CGFloat
        var bottom: CGFloat

        var minX: CGFloat { runs[0].minX }
        var maxX: CGFloat { runs[runs.count - 1].maxX }
        var height: CGFloat { top - bottom }
        var size: CGFloat { runs.map(\.size).max() ?? 12 }
        var text: String { runs.map(\.text).joined(separator: " ") }
    }

    private struct Glyph {
        var text: String
        var box: CGRect
        var size: CGFloat
        var bold: Bool
    }

    /// Lines rebuilt from character positions, top to bottom. Tables are found in these.
    let lines: [Line]
    /// PDFKit's lines in its reading order, each visual line once.
    let flow: [Line]
    let tables: [(box: CGRect, table: Table)]

    init?(page: PDFPage) {
        let glyphs = Self.glyphs(in: page)
        guard !glyphs.isEmpty else { return nil }
        lines = Self.lines(from: glyphs)
        let pieces = Self.flow(of: page)
        flow = pieces.isEmpty ? lines : pieces
        tables = Self.tables(in: lines)
    }

    /// Text outside the tables.
    var textLines: [Line] {
        flow.filter { tableIndex(of: $0) == nil }
    }

    private func tableIndex(of line: Line) -> Int? {
        let middle = CGPoint(x: (line.minX + line.maxX) / 2, y: (line.top + line.bottom) / 2)
        return tables.firstIndex { $0.box.insetBy(dx: -2, dy: -2).contains(middle) }
    }

    /// Semibold counts: it is what web pages and slides use for headings.
    private static func isBold(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        if let weight = traits?[.weight] as? CGFloat, weight >= 0.23 { return true }
        let name = font.fontName.lowercased()
        return ["bold", "semibold", "demi", "heavy", "black"].contains { name.contains($0) }
    }

    // MARK: Characters to lines

    /// Each character as a selection of its own, which keeps its text and its box together.
    /// The page's `string` does not line up with `characterBounds(at:)`: it holds line breaks
    /// the character positions skip.
    private static func glyphs(in page: PDFPage) -> [Glyph] {
        let count = page.numberOfCharacters
        guard count > 0 else { return [] }
        var glyphs: [Glyph] = []
        glyphs.reserveCapacity(count)
        for index in 0..<count {
            guard let selection = page.selection(for: NSRange(location: index, length: 1)),
                let text = selection.string, !text.isEmpty, !text.allSatisfy(\.isWhitespace)
            else { continue }
            let box = selection.bounds(for: page)
            guard box.height > 0, box.width >= 0, box.minX.isFinite, box.minY.isFinite else { continue }
            // The position of a line break selects the character before it once more.
            if let last = glyphs.last, last.text == text, last.box == box { continue }
            let font = selection.attributedString.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
            glyphs.append(Glyph(
                text: text,
                box: box,
                size: font?.pointSize ?? box.height * 0.8,
                bold: font.map(Self.isBold) ?? false
            ))
        }
        return glyphs
    }

    /// Characters whose middles share a height make a line, read left to right. A gap of about
    /// a quarter of the font size is a space, a gap of half of it or more separates runs, such
    /// as the cells of a table row or two columns of text. Wide spaces in justified text make
    /// runs too, but those never line up from line to line, so they never make columns.
    private static func lines(from glyphs: [Glyph]) -> [Line] {
        let sorted = glyphs.sorted { $0.box.midY > $1.box.midY }
        var groups: [[Glyph]] = []
        var middle: CGFloat = 0
        var height: CGFloat = 0
        for glyph in sorted {
            if let last = groups.indices.last, abs(glyph.box.midY - middle) <= max(height, glyph.box.height) * 0.4 {
                groups[last].append(glyph)
            } else {
                groups.append([glyph])
                middle = glyph.box.midY
                height = glyph.box.height
            }
        }
        return groups.compactMap { group in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }
            var runs: [Run] = []
            var previous: Glyph?
            for glyph in ordered {
                defer { previous = glyph }
                guard let last = previous, !runs.isEmpty else {
                    runs.append(Run(text: glyph.text, minX: glyph.box.minX, maxX: glyph.box.maxX, size: glyph.size, bold: glyph.bold))
                    continue
                }
                let size = max(last.size, glyph.size)
                let gap = glyph.box.minX - last.box.maxX
                if gap > size * 0.5 {
                    runs.append(Run(text: glyph.text, minX: glyph.box.minX, maxX: glyph.box.maxX, size: glyph.size, bold: glyph.bold))
                    continue
                }
                var run = runs.removeLast()
                if gap > size * 0.15 { run.text += " " }
                run.text += glyph.text
                run.maxX = max(run.maxX, glyph.box.maxX)
                run.size = max(run.size, glyph.size)
                run.bold = run.bold && glyph.bold
                runs.append(run)
            }
            guard !runs.isEmpty else { return nil }
            // A list marker set apart from its text still belongs to it.
            if runs.count >= 2, runs[0].text.wholeMatch(of: marker) != nil {
                let first = runs.removeFirst()
                runs[0].text = first.text + " " + runs[0].text
                runs[0].minX = first.minX
            }
            return Line(
                runs: runs,
                top: group.map(\.box.maxY).max() ?? 0,
                bottom: group.map(\.box.minY).min() ?? 0
            )
        }
    }

    /// PDFKit's lines, with the pieces of one visual line joined, such as the text on either
    /// side of a picture or a list marker set apart from its item.
    private static func flow(of page: PDFPage) -> [Line] {
        let pieces = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
        var result: [Line] = []
        for piece in pieces {
            guard let raw = piece.string else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = piece.bounds(for: page)
            guard !text.isEmpty, box.height > 0, box.minX.isFinite, box.minY.isFinite else { continue }
            var size: CGFloat = 0
            var bold = true
            if let attributed = piece.attributedString {
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    guard let font = value as? NSFont,
                        !(attributed.string as NSString).substring(with: range).allSatisfy(\.isWhitespace)
                    else { return }
                    size = max(size, font.pointSize)
                    if !Self.isBold(font) { bold = false }
                }
            }
            if size == 0 {
                size = box.height * 0.8
                bold = false
            }
            let run = Run(text: text, minX: box.minX, maxX: box.maxX, size: size, bold: bold)
            if var last = result.last, box.minX >= last.maxX - 1,
                abs((last.top + last.bottom) / 2 - box.midY) < min(last.height, box.height) * 0.4
            {
                last.runs.append(run)
                last.top = max(last.top, box.maxY)
                last.bottom = min(last.bottom, box.minY)
                result[result.count - 1] = last
            } else {
                result.append(Line(runs: [run], top: box.maxY, bottom: box.minY))
            }
        }
        return result
    }

    // MARK: Lines to blocks

    /// The size most of the text outside tables has, across pages, so that a slide's title
    /// stands out even on a slide with little else. When there is little text and headings
    /// make up most of it, as above a big table, the smallest size is the body.
    static func bodySize(of layouts: [PDFLayout]) -> CGFloat {
        let text = layouts.flatMap(\.textLines)
        let lines = text.isEmpty ? layouts.flatMap(\.flow) : text
        var weights: [CGFloat: Int] = [:]
        for line in lines {
            for run in line.runs { weights[(run.size * 2).rounded() / 2, default: 0] += run.text.count }
        }
        let common = weights.max { $0.value < $1.value }?.key ?? 12
        let smallest = weights.keys.min() ?? common
        let characters = weights.values.reduce(0, +)
        return characters < 200 && common >= smallest * 1.3 ? smallest : common
    }

    func blocks(body: CGFloat) -> [Block] {
        // Where lines that start together end at most: the right edge of their column.
        let text = textLines
        let everywhere = Self.percentile(text.map(\.maxX), 0.9) ?? 0
        let rightEdge = { (line: Line) -> CGFloat in
            let alike = text.filter { abs($0.minX - line.minX) < 6 }
            return alike.count >= 3 ? Self.percentile(alike.map(\.maxX), 0.9) ?? everywhere : everywhere
        }

        var blocks: [Block] = []
        var pending: [Line] = []
        var placed: Set<Int> = []
        for line in flow {
            guard let index = tableIndex(of: line) else {
                pending.append(line)
                continue
            }
            blocks += Self.textBlocks(from: pending, body: body, rightEdge: rightEdge)
            pending = []
            if placed.insert(index).inserted { blocks.append(.table(tables[index].table)) }
        }
        blocks += Self.textBlocks(from: pending, body: body, rightEdge: rightEdge)
        for index in tables.indices where !placed.contains(index) {
            blocks.append(.table(tables[index].table))
        }
        return blocks
    }

    private static func tables(in lines: [Line]) -> [(box: CGRect, table: Table)] {
        var found: [(box: CGRect, table: Table)] = []
        var index = 0
        while index < lines.count {
            if lines[index].runs.count >= 2, let region = region(in: lines, startingAt: index) {
                found.append((region.box, region.table))
                index = region.end
            } else {
                index += 1
            }
        }
        return found
    }

    /// Lines with several runs whose runs line up, and the wrapped lines between them, form a
    /// table. Text set in columns lines up too, so a table needs three columns or short cells.
    private static func region(in lines: [Line], startingAt start: Int) -> (end: Int, box: CGRect, table: Table)? {
        var spans = Self.columns(of: [lines[start]])
        var rowLines = [lines[start]]
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            let gap = lines[end - 1].bottom - line.top
            if line.runs.count >= 2, gap < line.height * 2.5, Self.touches(line, spans) >= 2 {
                rowLines.append(line)
                spans = Self.columns(of: rowLines)
                end += 1
            } else if line.runs.count == 1, gap < line.height * 0.6,
                Self.inInnerColumn(line, spans) || continues(lines, after: end, spans: spans)
            {
                // A cell's text that wrapped onto a line of its own.
                end += 1
            } else {
                break
            }
        }
        guard lines[start..<end].filter({ $0.runs.count >= 2 }).count >= 2 else { return nil }
        // A line under the region that runs across its columns is text after it, not a cell.
        while end > start, lines[end - 1].runs.count == 1,
            spans.filter({ $0.overlaps(lines[end - 1].minX...lines[end - 1].maxX) }).count > 1
        {
            end -= 1
        }
        let members = Array(lines[start..<end])
        guard members.filter({ $0.runs.count >= 2 }).count >= 2 else { return nil }

        let columns = Self.columns(of: members)
        guard columns.count >= 2 else { return nil }

        // Rows: a wrapped line sits close under the one before, a new row further away.
        var rows: [[Line]] = []
        for (offset, line) in members.enumerated() {
            if offset > 0, members[offset - 1].bottom - line.top < line.height * 0.35 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        let runs = members.flatMap(\.runs)
        let medianLength = Self.percentile(runs.map { CGFloat($0.text.count) }, 0.5) ?? 0
        guard rows.count >= 2, columns.count >= 3 || medianLength <= 30 else { return nil }
        let cells = rows.map { row -> [String] in
            var texts = Array(repeating: "", count: columns.count)
            for line in row {
                for run in line.runs {
                    let column = Self.column(of: run, in: columns)
                    texts[column] = Self.joined(texts[column], run.text)
                }
            }
            return texts
        }
        let header = rows[0].allSatisfy { $0.runs.allSatisfy(\.bold) }
        let box = CGRect(
            x: members.map(\.minX).min() ?? 0,
            y: members.map(\.bottom).min() ?? 0,
            width: (members.map(\.maxX).max() ?? 0) - (members.map(\.minX).min() ?? 0),
            height: (members.map(\.top).max() ?? 0) - (members.map(\.bottom).min() ?? 0)
        )
        return (end, box, Table(rows: cells.map { $0.map { TableCell(text: $0) } }, hasHeaderRow: header))
    }

    /// Whether a line of the same columns follows soon, through gaps no wider than a table's.
    private static func continues(_ lines: [Line], after index: Int, spans: [ClosedRange<CGFloat>]) -> Bool {
        var next = index + 1
        while next < lines.count, next - index <= 10 {
            if lines[next - 1].bottom - lines[next].top > lines[next].height * 2.5 { return false }
            if lines[next].runs.count >= 2 { return Self.touches(lines[next], spans) >= 2 }
            next += 1
        }
        return false
    }

    /// How many of the columns a line has text in.
    private static func touches(_ line: Line, _ spans: [ClosedRange<CGFloat>]) -> Int {
        spans.filter { span in line.runs.contains { span.overlaps($0.minX...$0.maxX) } }.count
    }

    /// A line that keeps inside one column other than the first, as a wrapped cell does.
    /// Text at the left edge could as well be the paragraph after the table.
    private static func inInnerColumn(_ line: Line, _ spans: [ClosedRange<CGFloat>]) -> Bool {
        let run = line.runs[0]
        let hits = spans.indices.filter { spans[$0].overlaps(run.minX...run.maxX) }
        guard hits.count == 1, hits[0] > 0 else { return false }
        return run.minX >= spans[hits[0]].lowerBound - run.size && run.maxX <= spans[hits[0]].upperBound + run.size
    }

    /// Column spans: runs that overlap horizontally belong to one column.
    private static func columns(of lines: [Line]) -> [ClosedRange<CGFloat>] {
        var spans = lines.flatMap(\.runs).map { $0.minX...$0.maxX }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = []
        while !spans.isEmpty {
            let span = spans.removeFirst()
            if let last = merged.last, span.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func column(of run: Run, in columns: [ClosedRange<CGFloat>]) -> Int {
        let middle = (run.minX + run.maxX) / 2
        return columns.firstIndex { $0.contains(middle) }
            ?? columns.indices.min { abs(columns[$0].lowerBound - run.minX) < abs(columns[$1].lowerBound - run.minX) } ?? 0
    }

    /// Joins wrapped text, undoing a hyphen at the end of the first part.
    private static func joined(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if first.hasSuffix("-"), let next = second.first, next.isLowercase { return String(first.dropLast()) + second }
        return first + " " + second
    }

    // MARK: Paragraphs, headings and lists

    private static var marker: Regex<Substring> { /[•◦▪▫‣∙●○■□►▸–—\-\*]|\d{1,3}[.)]|[a-zA-Z][.)]/ }
    private static var bullet: Regex<(Substring, Substring)> { /^[•◦▪▫‣∙●○■□►▸–—\-\*]\s+(.+)$/ }
    private static var number: Regex<(Substring, Substring)> { /^(?:\d{1,3}|[a-zA-Z])[.)]\s+(.+)$/ }

    private struct Item {
        var level: CGFloat
        var ordered: Bool
        var marker: String
        var text: String
    }

    /// A line continues the one before when the next word would not have fitted there: then
    /// the line broke for room, not because its paragraph or item ended.
    static func textBlocks(from lines: [Line], body: CGFloat, rightEdge: (Line) -> CGFloat) -> [Block] {
        var blocks: [Block] = []
        var paragraph = ""
        var items: [Item] = []
        var addsToItem = false
        var previous: Line?

        func flushParagraph() {
            let text = paragraph.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(content: [.text(text)])) }
            paragraph = ""
        }
        func flushItems() {
            if !items.isEmpty { blocks += list(items) }
            items = []
        }

        for line in lines {
            defer { previous = line }
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let ratio = line.size / body
            if ratio >= 1.15, text.count < 160 {
                flushParagraph()
                flushItems()
                addsToItem = false
                // A heading that wraps continues on the next line in the same size.
                if case .heading(let level, let content, _)? = blocks.last, let previous,
                    abs(previous.size - line.size) < 0.5, previous.bottom - line.top < line.height * 0.6
                {
                    blocks[blocks.count - 1] = .heading(level: level, content: [.text(joined(content.plainText, text))])
                } else {
                    blocks.append(.heading(level: ratio >= 1.7 ? 1 : ratio >= 1.35 ? 2 : 3, content: [.text(text)]))
                }
                continue
            }
            if let match = text.wholeMatch(of: bullet) ?? text.wholeMatch(of: number) {
                flushParagraph()
                let ordered = text.wholeMatch(of: number) != nil
                // Numbers straight after bullets at the same indent start a list of their own.
                if let first = items.first, first.ordered != ordered, abs(line.minX - first.level) < 4 { flushItems() }
                let marker = String(text[..<match.output.1.startIndex]).trimmingCharacters(in: .whitespaces)
                items.append(Item(level: line.minX, ordered: ordered, marker: marker, text: String(match.output.1)))
                addsToItem = true
                continue
            }
            if let previous, follows(line, previous, rightEdge: rightEdge(previous)) {
                if addsToItem, !items.isEmpty {
                    items[items.count - 1].text = joined(items[items.count - 1].text, text)
                    continue
                }
                if !paragraph.isEmpty {
                    paragraph = joined(paragraph, text)
                    continue
                }
            }
            flushParagraph()
            flushItems()
            addsToItem = false
            paragraph = text
        }
        flushParagraph()
        flushItems()
        return blocks
    }

    private static func follows(_ line: Line, _ previous: Line, rightEdge: CGFloat) -> Bool {
        guard abs(previous.size - line.size) < 0.5, previous.bottom - line.top < line.size * 0.6,
            line.minX <= previous.minX + line.size * 2
        else { return false }
        let text = line.text
        let word = text.prefix { !$0.isWhitespace }.count
        let wordWidth = (line.maxX - line.minX) * CGFloat(word) / CGFloat(max(text.count, 1))
        return previous.maxX + wordWidth + line.size * 0.3 >= rightEdge
    }


    /// Bullets make a list, and so do numbers counting from one. Other numbers and letters stay
    /// written as they are, since a list would count from one again and the text may refer to
    /// "point 3" or "b)". Items further right than the first nest inside the item before them.
    private static func list(_ items: [Item]) -> [Block] {
        let counts = items.allSatisfy(\.ordered)
            && items.filter { abs($0.level - items[0].level) < 4 }.enumerated().allSatisfy { index, item in
                Int(item.marker.trimmingCharacters(in: CharacterSet(charactersIn: ".)"))) == index + 1
            }
        guard items.allSatisfy({ !$0.ordered }) || counts else {
            return items.map { .paragraph(content: [.text($0.marker + " " + $0.text)]) }
        }
        return [nested(items[...])]
    }

    private static func nested(_ items: ArraySlice<Item>) -> Block {
        let base = items.first!.level
        var result: [[Block]] = []
        var index = items.startIndex
        while index < items.endIndex {
            let item = items[index]
            if item.level > base + 4, !result.isEmpty {
                var end = index
                while end < items.endIndex, items[end].level > base + 4 { end += 1 }
                result[result.count - 1].append(nested(items[index..<end]))
                index = end
            } else {
                result.append([.paragraph(content: [.text(item.text)])])
                index += 1
            }
        }
        return .list(ordered: items.first!.ordered, items: result)
    }

    private static func percentile(_ values: [CGFloat], _ fraction: Double) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}

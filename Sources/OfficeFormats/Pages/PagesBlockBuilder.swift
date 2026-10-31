import ConversionCore
import Foundation

/// Turns text storages and what they point at into blocks.
struct PagesBlockBuilder {
    private enum Unit {
        static let newline: UInt16 = 0x0A
        static let tab: UInt16 = 0x09
        static let sectionBreak: UInt16 = 0x04
        static let pageBreak: UInt16 = 0x05
        static let formFeed: UInt16 = 0x0C
        static let columnBreak: UInt16 = 0x0E
        static let lineBreak: UInt16 = 0x2028
        static let paragraphSeparator: UInt16 = 0x2029
        static let attachment: UInt16 = 0xFFFC
    }

    /// Kinds of `TSWP.StorageArchive`.
    private enum StorageKind {
        static let body: UInt64 = 0
        static let textBox: UInt64 = 3
    }

    private let store: IWAObjectStore
    private let styles: PagesStyles
    private let images: PagesImages
    private let tables: IWATableReader

    init(store: IWAObjectStore, dataSource: PartSource) {
        self.store = store
        styles = PagesStyles(store: store)
        images = PagesImages(store: store, source: dataSource)
        tables = IWATableReader(store: store)
    }

    func documentBlocks() -> [Block] {
        var usedDrawables: Set<UInt64> = []
        var blocks = bodyStorage().map { blocksFrom($0, usedDrawables: &usedDrawables) } ?? []

        // A page layout document keeps its text in text boxes, with an empty body.
        if blocks.isEmpty {
            for (_, message) in store.all(ofType: IWAType.textStorage) {
                guard let storage = message.parsed(), storage.varint(1) == StorageKind.textBox else { continue }
                blocks += blocksFrom(storage, usedDrawables: &usedDrawables)
            }
        }

        // Floating objects are not anchored in the text, so they come after it. Only what the
        // document proper holds counts: the stylesheet and theme have images of their own.
        for (identifier, _) in store.all(ofType: IWAType.image) where !usedDrawables.contains(identifier) {
            if let image = images.asset(forDrawable: identifier) { blocks.append(.image(image)) }
        }
        for (identifier, _) in store.all(ofType: IWAType.tableInfo) where !usedDrawables.contains(identifier) {
            if let table = tables.table(forInfo: identifier) { blocks.append(.table(table)) }
        }
        return blocks
    }

    private func bodyStorage() -> ProtoMessage? {
        if let root = store.all(ofType: IWAType.documentRoot).first?.message.parsed(),
            let identifier = root.reference(4),
            let storage = store.parsed(identifier),
            store.object(identifier)?.type == IWAType.textStorage
        {
            return storage
        }
        return store.all(ofType: IWAType.textStorage)
            .compactMap { $0.message.parsed() }
            .filter { $0.varint(1) == StorageKind.body }
            .max { $0.strings(3).joined().utf8.count < $1.strings(3).joined().utf8.count }
    }

    // MARK: Paragraphs

    private struct Paragraph {
        var range: Range<Int>
        var pageBreakAfter: Bool
    }

    /// A text attribute table as sorted runs. An entry without an object repeats the previous
    /// value in paragraph tables, and clears it in the character table.
    private struct Runs {
        private var starts: [Int] = []
        private var values: [UInt64?] = []

        /// List levels: field 2 of each entry holds the level instead of a reference.
        init(levelEntries entries: [ProtoMessage]) {
            for entry in entries {
                guard let index = entry.int(1) else { continue }
                starts.append(index)
                values.append(entry.varint(2) ?? 0)
            }
        }

        init(entries: [ProtoMessage], inheritsWhenEmpty: Bool) {
            var last: UInt64?
            for entry in entries {
                guard let index = entry.int(1) else { continue }
                var value = entry.reference(2)
                if value == nil && inheritsWhenEmpty { value = last }
                last = value
                starts.append(index)
                values.append(value)
            }
        }

        func value(at index: Int) -> UInt64? {
            guard let position = lastPosition(atOrBefore: index) else { return nil }
            return values[position]
        }

        /// The index where the value at `index` stops holding.
        func end(after index: Int, limit: Int) -> Int {
            var position = (lastPosition(atOrBefore: index) ?? -1) + 1
            while position < starts.count, starts[position] <= index { position += 1 }
            return position < starts.count ? min(starts[position], limit) : limit
        }

        private func lastPosition(atOrBefore index: Int) -> Int? {
            var low = 0
            var high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= index { low = middle + 1 } else { high = middle }
            }
            return low > 0 ? low - 1 : nil
        }
    }

    private func blocksFrom(_ storage: ProtoMessage, usedDrawables: inout Set<UInt64>) -> [Block] {
        let units = Array(storage.strings(3).joined().utf16)
        guard !units.isEmpty else { return [] }

        let paragraphStyles = Runs(entries: storage.attributeEntries(5), inheritsWhenEmpty: true)
        let listStyles = Runs(entries: storage.attributeEntries(7), inheritsWhenEmpty: true)
        let characterStyles = Runs(entries: storage.attributeEntries(8), inheritsWhenEmpty: false)
        let attachments = Runs(entries: storage.attributeEntries(9), inheritsWhenEmpty: false)
        let levels = Runs(levelEntries: storage.attributeEntries(6))

        var blocks: [Block] = []
        var pendingList: [ListBuilder.Item] = []
        func flushList() {
            blocks += ListBuilder.lists(from: pendingList[...])
            pendingList = []
        }

        for paragraph in Self.paragraphs(in: units) {
            let styleID = paragraphStyles.value(at: paragraph.range.lowerBound)
            let level = Int(min(levels.value(at: paragraph.range.lowerBound) ?? 0, 8))
            let (content, objects) = inlines(
                units: units, range: paragraph.range, base: styles.variationStyle(ofParagraphStyle: styleID),
                characterStyles: characterStyles, attachments: attachments)

            if !content.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let alignment = styles.alignment(ofParagraphStyle: styleID)
                if let level = styles.headingLevel(ofParagraphStyle: styleID) {
                    flushList()
                    blocks.append(.heading(level: level, content: Self.plainHeading(content), alignment: alignment))
                } else if let kind = styles.listKind(style: listStyles.value(at: paragraph.range.lowerBound), level: level) {
                    pendingList.append(ListBuilder.Item(
                        level: level,
                        ordered: kind == .ordered,
                        content: .paragraph(content: content, alignment: alignment)))
                } else {
                    flushList()
                    blocks.append(.paragraph(content: content, alignment: alignment))
                }
            }

            // Objects anchored in a paragraph follow its text.
            for object in objects {
                let resolved = resolve(attachment: object, usedDrawables: &usedDrawables)
                if !resolved.isEmpty { flushList() }
                blocks += resolved
            }
            if paragraph.pageBreakAfter {
                flushList()
                if !blocks.isEmpty, blocks.last != .pageBreak { blocks.append(.pageBreak) }
            }
        }
        flushList()
        if blocks.last == .pageBreak { blocks.removeLast() }
        return blocks
    }

    private static func paragraphs(in units: [UInt16]) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var start = 0
        for (index, unit) in units.enumerated() {
            switch unit {
            case Unit.newline, Unit.paragraphSeparator, Unit.columnBreak:
                paragraphs.append(Paragraph(range: start..<index, pageBreakAfter: false))
                start = index + 1
            case Unit.pageBreak, Unit.sectionBreak, Unit.formFeed:
                paragraphs.append(Paragraph(range: start..<index, pageBreakAfter: true))
                start = index + 1
            default:
                break
            }
        }
        if start < units.count {
            paragraphs.append(Paragraph(range: start..<units.count, pageBreakAfter: false))
        }
        return paragraphs
    }

    private func inlines(
        units: [UInt16],
        range: Range<Int>,
        base: TextStyle,
        characterStyles: Runs,
        attachments: Runs
    ) -> (content: [Inline], attachments: [UInt64]) {
        var content: [Inline] = []
        var objects: [UInt64] = []
        var position = range.lowerBound

        func appendText(_ slice: ArraySlice<UInt16>, _ style: TextStyle) {
            var pieceStart = slice.startIndex
            func flush(_ end: Int) {
                guard end > pieceStart else { return }
                let text = String(decoding: slice[pieceStart..<end], as: UTF16.self)
                if case .text(let previous, let previousStyle)? = content.last, previousStyle == style {
                    content[content.count - 1] = .text(previous + text, style)
                } else {
                    content.append(.text(text, style))
                }
            }
            for index in slice.indices {
                let unit = slice[index]
                if unit == Unit.lineBreak {
                    flush(index)
                    content.append(.lineBreak)
                    pieceStart = index + 1
                } else if unit == Unit.attachment {
                    flush(index)
                    if let object = attachments.value(at: index) { objects.append(object) }
                    pieceStart = index + 1
                } else if unit < 0x20 && unit != Unit.tab {
                    flush(index)
                    pieceStart = index + 1
                }
            }
            flush(slice.endIndex)
        }

        while position < range.upperBound {
            let end = characterStyles.end(after: position, limit: range.upperBound)
            let style = styles.merged(characterStyle: characterStyles.value(at: position), over: base)
            appendText(units[position..<end], style)
            position = end
        }
        return (content, objects)
    }

    /// A heading's look comes from its style, so only links and such would be worth keeping.
    private static func plainHeading(_ content: [Inline]) -> [Inline] {
        content.map { inline in
            guard case .text(let text, var style) = inline else { return inline }
            style.bold = false
            return .text(text, style)
        }
    }

    // MARK: Attachments

    /// An attachment points, perhaps through a wrapper or two, at an image or a table.
    private func resolve(attachment: UInt64, usedDrawables: inout Set<UInt64>) -> [Block] {
        var queue = [(attachment, 0)]
        var visited: Set<UInt64> = []
        while !queue.isEmpty {
            let (identifier, depth) = queue.removeFirst()
            guard visited.insert(identifier).inserted, let message = store.object(identifier) else { continue }
            switch message.type {
            case IWAType.image:
                usedDrawables.insert(identifier)
                return images.asset(forDrawable: identifier).map { [.image($0)] } ?? []
            case IWAType.tableInfo:
                usedDrawables.insert(identifier)
                return tables.table(forInfo: identifier).map { [.table($0)] } ?? []
            default:
                if depth < 3 {
                    queue += message.objectReferences.map { ($0, depth + 1) }
                }
            }
        }
        return []
    }
}

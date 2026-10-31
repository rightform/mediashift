import ConversionCore

/// Turns a run of list paragraphs with levels, the way slides and iWork store lists, into
/// nested `.list` blocks.
enum ListBuilder {
    struct Item {
        var level: Int
        var ordered: Bool
        var content: Block
    }

    static func lists(from run: ArraySlice<Item>) -> [Block] {
        guard let base = run.map(\.level).min() else { return [] }
        var blocks: [Block] = []
        var items: [[Block]] = []
        var ordered = false
        var index = run.startIndex

        func flush() {
            if !items.isEmpty { blocks.append(.list(ordered: ordered, items: items)) }
            items = []
        }

        while index < run.endIndex {
            let current = run[index]
            if current.ordered != ordered { flush() }
            ordered = current.ordered
            var item = [current.content]
            var end = index + 1
            while end < run.endIndex, run[end].level > base { end += 1 }
            if end > index + 1 {
                item += lists(from: run[(index + 1)..<end])
            }
            items.append(item)
            index = end
        }
        flush()
        return blocks
    }
}

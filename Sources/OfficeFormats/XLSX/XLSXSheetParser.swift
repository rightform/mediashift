import ConversionCore
import Foundation

/// Streams a worksheet part. Sheets are the one place a workbook gets truly large, so this
/// keeps only cells, without an element tree.
final class XLSXSheetParser: NSObject, XMLParserDelegate {
    struct Cell {
        var column: Int
        var style: Int
        var type: String?
        var value: String
    }

    struct Row {
        var index: Int
        var cells: [Cell]
    }

    struct MergeRange {
        var top: Int
        var left: Int
        var bottom: Int
        var right: Int
    }

    struct Sheet {
        var rows: [Row] = []
        var merges: [MergeRange] = []
    }

    static func parse(_ data: Data) throws -> Sheet {
        try XMLTree.rejectDocumentType(in: data)
        let handler = XLSXSheetParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = handler
        guard parser.parse() else {
            throw ConversionError("This file is damaged.")
        }
        return handler.sheet
    }

    private var sheet = Sheet()
    private var currentRow: Row?
    private var nextRowIndex = 0
    private var nextColumn = 0
    private var currentCell: Cell?
    private var collectsText = false
    private var ignoredDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch Self.localName(elementName) {
        case "row":
            let index = attributes["r"].flatMap(Int.init).map { max(1, min($0, 1_048_576)) - 1 } ?? nextRowIndex
            currentRow = Row(index: index, cells: [])
            nextRowIndex = index + 1
            nextColumn = 0
        case "c":
            let reference = attributes["r"].flatMap(Self.cellReference)
            let column = reference?.column ?? nextColumn
            nextColumn = column + 1
            currentCell = Cell(
                column: column,
                style: attributes["s"].flatMap(Int.init) ?? 0,
                type: attributes["t"],
                value: ""
            )
        case "v":
            collectsText = currentCell != nil && ignoredDepth == 0
        case "t":
            // Inline strings live in `<is><t>` and in `<is><r><t>`.
            collectsText = currentCell?.type == "inlineStr" && ignoredDepth == 0
        case "rPh":
            ignoredDepth += 1
        case "mergeCell":
            if let range = attributes["ref"].flatMap(Self.mergeRange) {
                sheet.merges.append(range)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch Self.localName(elementName) {
        case "row":
            if let row = currentRow, !row.cells.isEmpty { sheet.rows.append(row) }
            currentRow = nil
        case "c":
            if let cell = currentCell { currentRow?.cells.append(cell) }
            currentCell = nil
        case "v", "t":
            collectsText = false
        case "rPh":
            ignoredDepth -= 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectsText { currentCell?.value += string }
    }

    private static func localName(_ name: String) -> Substring {
        name.split(separator: ":").last ?? Substring(name)
    }

    /// `AB12` to zero based row and column. Nil for anything outside Excel's grid.
    static func cellReference(_ reference: String) -> (row: Int, column: Int)? {
        var column = 0
        var row = 0
        var seenDigit = false
        for byte in reference.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z") where !seenDigit:
                column = column * 26 + Int(byte - UInt8(ascii: "A")) + 1
            case UInt8(ascii: "a")...UInt8(ascii: "z") where !seenDigit:
                column = column * 26 + Int(byte - UInt8(ascii: "a")) + 1
            case UInt8(ascii: "$"):
                continue
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                seenDigit = true
                row = row * 10 + Int(byte - UInt8(ascii: "0"))
            default:
                return nil
            }
            guard column <= 16384, row <= 1_048_576 else { return nil }
        }
        guard column > 0, row > 0 else { return nil }
        return (row - 1, column - 1)
    }

    private static func mergeRange(_ reference: String) -> MergeRange? {
        let ends = reference.split(separator: ":")
        guard ends.count == 2,
            let start = cellReference(String(ends[0])),
            let end = cellReference(String(ends[1]))
        else { return nil }
        return MergeRange(
            top: min(start.row, end.row),
            left: min(start.column, end.column),
            bottom: max(start.row, end.row),
            right: max(start.column, end.column)
        )
    }

    /// `0` to `A`, `26` to `AA`.
    static func columnName(_ column: Int) -> String {
        var number = column + 1
        var letters: [Character] = []
        while number > 0 {
            let remainder = (number - 1) % 26
            letters.append(Character(UnicodeScalar(UInt8(65 + remainder))))
            number = (number - 1) / 26
        }
        return String(letters.reversed())
    }
}

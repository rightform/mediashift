import ConversionCore
import Foundation

/// Reads a workbook into one table per visible sheet.
struct XLSXReader {
    /// A sheet's grid may not be larger than this, however few cells its file really holds.
    private static let maxGridSlots = 50_000_000
    /// Rows are padded to full width only below this size.
    private static let maxPaddedSlots = 10_000_000

    let package: ZipPackage

    func read() throws -> RichDocument {
        guard let workbookPath = try OPC.mainPart(ofType: "officeDocument", in: package) ?? fallbackWorkbookPath,
            let workbookData = try package.data(forPart: workbookPath)
        else {
            throw ConversionError("This file is not a valid XLSX file.")
        }
        let workbook = try XMLTree.parse(workbookData)
        guard workbook.localName == "workbook" else {
            throw ConversionError("This file is not a valid XLSX file.")
        }

        let relationships = try OPC.relationships(of: workbookPath, in: package)
        let date1904 = workbook.first("workbookPr")?.flag("date1904") ?? false
        let strings = try sharedStrings(relationships, from: workbookPath)
        let styles = try XLSXStyles(part: part(ofType: "styles", in: relationships, from: workbookPath))

        var blocks: [Block] = []
        for sheet in workbook.first("sheets")?.all("sheet") ?? [] {
            let state = sheet.attribute("state")
            guard state != "hidden", state != "veryHidden",
                let id = sheet.prefixedAttribute("id"),
                let relationship = relationships.first(where: { $0.id == id }),
                relationship.hasType("worksheet"),
                let path = OPC.resolve(relationship.target, from: workbookPath),
                let data = try package.data(forPart: path)
            else { continue }

            let parsed = try XLSXSheetParser.parse(data)
            let table = try makeTable(
                parsed, name: sheet.attribute("name"), strings: strings, styles: styles, date1904: date1904)
            if !blocks.isEmpty { blocks.append(.pageBreak) }
            blocks.append(.table(table))
        }

        let properties = OPC.coreProperties(in: package)
        return RichDocument(title: properties.title, author: properties.author, blocks: blocks)
    }

    private var fallbackWorkbookPath: String? {
        package.contains("xl/workbook.xml") ? "xl/workbook.xml" : nil
    }

    private func part(ofType type: String, in relationships: [OPC.Relationship], from source: String) throws -> Data? {
        guard let relationship = relationships.first(where: { $0.hasType(type) }),
            let path = OPC.resolve(relationship.target, from: source)
        else { return nil }
        return try package.data(forPart: path)
    }

    private func sharedStrings(_ relationships: [OPC.Relationship], from source: String) throws -> [String] {
        guard let data = try part(ofType: "sharedStrings", in: relationships, from: source) else { return [] }
        return try XMLTree.parse(data).all("si").map { item in
            // Plain `<t>`, or rich text runs. Phonetic guides in `<rPh>` are not displayed text.
            if item.first("r") != nil {
                return item.all("r").compactMap { $0.first("t")?.text }.joined()
            }
            return item.first("t")?.text ?? ""
        }
    }

    // MARK: Building the table

    private func makeTable(
        _ sheet: XLSXSheetParser.Sheet,
        name: String?,
        strings: [String],
        styles: XLSXStyles,
        date1904: Bool
    ) throws -> Table {
        // Values first, so empty styled cells cannot blow up the table's size.
        var rowsByIndex: [Int: [(column: Int, text: String, style: Int)]] = [:]
        var lastRow = -1
        var lastColumn = -1
        for row in sheet.rows {
            for cell in row.cells {
                let text = try displayedText(of: cell, strings: strings, styles: styles, date1904: date1904)
                guard !text.isEmpty else { continue }
                rowsByIndex[row.index, default: []].append((cell.column, text, cell.style))
                lastRow = max(lastRow, row.index)
                lastColumn = max(lastColumn, cell.column)
            }
        }

        // Merged ranges, clipped to the area with content.
        var origins: [Int: [Int: (columnSpan: Int, rowSpan: Int)]] = [:]
        var covered: [Int: [ClosedRange<Int>]] = [:]
        for range in sheet.merges where range.top <= lastRow && range.left <= lastColumn {
            let bottom = min(range.bottom, lastRow)
            let right = min(range.right, lastColumn)
            guard bottom > range.top || right > range.left else { continue }
            origins[range.top, default: [:]][range.left] = (right - range.left + 1, bottom - range.top + 1)
            for row in range.top...bottom {
                covered[row, default: []].append(range.left...right)
            }
        }

        guard lastRow >= 0 else { return Table(name: name, rows: []) }
        let height = lastRow + 1
        let width = lastColumn + 1
        let padded = width * height <= Self.maxPaddedSlots

        var slots = 0
        for row in 0..<height {
            slots += padded ? width : ((rowsByIndex[row]?.map(\.column).max() ?? -1) + 1)
            guard slots <= Self.maxGridSlots else {
                throw ConversionError("This sheet is too large to convert.")
            }
        }

        var rows: [[TableCell]] = []
        rows.reserveCapacity(height)
        for rowIndex in 0..<height {
            var values: [Int: String] = [:]
            var limit = padded ? width : 0
            for cell in rowsByIndex[rowIndex] ?? [] {
                values[cell.column] = cell.text
                limit = max(limit, cell.column + 1)
            }
            let coveredRanges = covered[rowIndex] ?? []
            let rowOrigins = origins[rowIndex] ?? [:]
            var cells: [TableCell] = []
            cells.reserveCapacity(limit)
            for column in 0..<limit {
                if let span = rowOrigins[column] {
                    cells.append(cell(text: values[column] ?? "", columnSpan: span.columnSpan, rowSpan: span.rowSpan))
                } else if !coveredRanges.contains(where: { $0.contains(column) }) {
                    cells.append(TableCell(text: values[column] ?? ""))
                }
            }
            rows.append(cells)
        }

        let firstRowCells = rowsByIndex[0] ?? []
        let hasHeader = !firstRowCells.isEmpty && firstRowCells.allSatisfy { styles.isBold(style: $0.style) }
        return Table(name: name, rows: rows, hasHeaderRow: hasHeader)
    }

    private func cell(text: String, columnSpan: Int, rowSpan: Int) -> TableCell {
        var cell = TableCell(text: text)
        cell.columnSpan = columnSpan
        cell.rowSpan = rowSpan
        return cell
    }

    private func displayedText(
        of cell: XLSXSheetParser.Cell,
        strings: [String],
        styles: XLSXStyles,
        date1904: Bool
    ) throws -> String {
        switch cell.type {
        case "s":
            guard let index = Int(cell.value), strings.indices.contains(index) else {
                if cell.value.isEmpty { return "" }
                throw ConversionError("This file is damaged.")
            }
            return styles.format(style: cell.style).string(forText: strings[index])
        case "inlineStr", "str":
            return styles.format(style: cell.style).string(forText: cell.value)
        case "b":
            return cell.value == "1" ? "TRUE" : (cell.value == "0" ? "FALSE" : cell.value)
        case "e", "d":
            return cell.value
        default:
            guard !cell.value.isEmpty else { return "" }
            let trimmed = cell.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Double(trimmed), number.isFinite else { return cell.value }
            return styles.format(style: cell.style).string(for: number, date1904: date1904)
        }
    }
}

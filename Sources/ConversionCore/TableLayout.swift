/// A table's cells placed on its grid. `Table.rows` lists only real cells, the way HTML does,
/// so a cell's column depends on the spans above and before it.
public struct TableLayout {
    public struct PlacedCell: Sendable {
        public var column: Int
        public var cell: TableCell
        public var columnSpan: Int
        public var rowSpan: Int
    }

    public private(set) var rows: [[PlacedCell]] = []
    public private(set) var columnCount = 0

    public init(_ table: Table) {
        rows.reserveCapacity(table.rows.count)
        // Columns blocked by a row span from above, by row index. Sparse, spans are rare.
        var blocked: [Int: Set<Int>] = [:]
        for (rowIndex, row) in table.rows.enumerated() {
            var placed: [PlacedCell] = []
            placed.reserveCapacity(row.count)
            let taken = blocked.removeValue(forKey: rowIndex) ?? []
            var column = 0
            for cell in row {
                while taken.contains(column) { column += 1 }
                let columnSpan = min(max(1, cell.columnSpan), 16_384)
                let rowSpan = min(max(1, cell.rowSpan), table.rows.count - rowIndex)
                placed.append(PlacedCell(column: column, cell: cell, columnSpan: columnSpan, rowSpan: rowSpan))
                if rowSpan > 1 {
                    for below in (rowIndex + 1)..<(rowIndex + rowSpan) {
                        blocked[below, default: []].formUnion(column..<(column + columnSpan))
                    }
                }
                column += columnSpan
            }
            columnCount = max(columnCount, column, (taken.max() ?? -1) + 1)
            rows.append(placed)
        }
    }

    /// The text of each row as a full width list of fields, with merged slots empty.
    public func textRows() -> [[String]] {
        rows.map { row in
            var fields = Array(repeating: "", count: (row.last.map { $0.column + $0.columnSpan }) ?? 0)
            for placed in row { fields[placed.column] = placed.cell.plainText }
            return fields
        }
    }
}

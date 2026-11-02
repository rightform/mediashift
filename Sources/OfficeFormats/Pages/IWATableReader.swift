import ConversionCore
import Foundation

/// Reads cell text out of `TST` table objects, shared by all of iWork. A table model holds a
/// data store of tiles of rows, whose cells are small binary records pointing into lists of
/// strings. Formatting is not applied: numbers show in General form and dates as ISO dates.
struct IWATableReader {
    /// Cell kinds in a cell record.
    private enum CellKind {
        static let number: UInt8 = 2
        static let text: UInt8 = 3
        static let date: UInt8 = 5
        static let boolean: UInt8 = 6
        static let duration: UInt8 = 7
        static let richText: UInt8 = 9
        static let currency: UInt8 = 10
    }

    private static let maxRows = 1 << 20
    private static let maxGridSlots = 10_000_000

    private let store: IWAObjectStore

    init(store: IWAObjectStore) {
        self.store = store
    }

    /// Nil when the structure is not what this reader knows, rather than a wrong table.
    func table(forInfo identifier: UInt64) -> Table? {
        guard let info = store.parsed(identifier), let modelID = info.reference(2) else { return nil }
        return table(forModel: modelID)
    }

    func table(forModel identifier: UInt64) -> Table? {
        guard let model = store.parsed(identifier),
            store.object(identifier)?.type == IWAType.tableModel,
            let rowCount = model.int(6),
            let columnCount = model.int(7),
            rowCount > 0, columnCount > 0, rowCount <= Self.maxRows, columnCount <= 1 << 16,
            let dataStore = model.message(4),
            let tiles = dataStore.message(3)
        else { return nil }

        let strings = dataStore.reference(4).map(stringList) ?? [:]
        let richText = dataStore.reference(17).map(richTextList) ?? [:]
        let tileSize = tiles.int(2) ?? 256
        guard tileSize > 0, tileSize <= Self.maxRows else { return nil }

        var rows: [Int: [Int: String]] = [:]
        for entry in tiles.messages(1) {
            guard let tileIndex = entry.int(1), tileIndex <= Self.maxRows,
                let tileID = entry.reference(2),
                store.object(tileID)?.type == IWAType.tableTile,
                let tile = store.parsed(tileID)
            else { continue }
            for rowInfo in tile.messages(5) {
                guard let rowIndex = rowInfo.int(1), rowIndex <= Self.maxRows,
                    let buffer = rowInfo.bytes(6), let offsets = rowInfo.bytes(7)
                else { continue }
                let wide = rowInfo.varint(8) == 1
                let row = tileIndex * tileSize + rowIndex
                guard row < rowCount else { continue }
                let cells = Self.cells(buffer: buffer, offsets: offsets, wideOffsets: wide, columnCount: columnCount)
                for (column, record) in cells {
                    if let text = Self.text(of: record, strings: strings, richText: richText), !text.isEmpty {
                        rows[row, default: [:]][column] = text
                    }
                }
            }
        }

        // Tables often carry unused rows and columns below and to the right of their content.
        guard let lastRow = rows.keys.max(),
            let lastColumn = rows.values.flatMap(\.keys).max()
        else { return Table(rows: []) }
        guard (lastRow + 1) * (lastColumn + 1) <= Self.maxGridSlots else { return nil }
        let grid = (0...lastRow).map { row in
            (0...lastColumn).map { column in TableCell(text: rows[row]?[column] ?? "") }
        }
        return Table(rows: grid, hasHeaderRow: (model.varint(9) ?? 0) > 0)
    }

    /// A row's offsets are 16 bit values, -1 for an empty cell, in units of 4 with wide offsets.
    private static func cells(buffer: Data, offsets: Data, wideOffsets: Bool, columnCount: Int) -> [(Int, Data)] {
        let bytes = [UInt8](offsets)
        var starts: [(column: Int, offset: Int)] = []
        var column = 0
        while column < columnCount, column * 2 + 1 < bytes.count {
            let raw = Int16(bitPattern: UInt16(bytes[column * 2]) | UInt16(bytes[column * 2 + 1]) << 8)
            if raw >= 0 { starts.append((column, Int(raw) * (wideOffsets ? 4 : 1))) }
            column += 1
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].offset : buffer.count
            guard start.offset < end, end <= buffer.count else { return nil }
            return (start.column, buffer.subdata(in: start.offset..<end))
        }
    }

    /// Record layout: version byte (5), kind byte, 8 bytes up to a 32 bit field mask at offset
    /// 8, then the present fields in mask order: decimal128, double, date, string id, rich text id.
    private static func text(of record: Data, strings: [UInt64: String], richText: [UInt64: String]) -> String? {
        let bytes = [UInt8](record)
        guard bytes.count >= 12, bytes[0] == 5 else { return nil }
        let kind = bytes[1]
        let mask = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
        var position = 12

        var decimal: Double?
        var double: Double?
        var seconds: Double?
        var stringID: UInt64?
        var richID: UInt64?

        func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard position + count <= bytes.count else { return nil }
            defer { position += count }
            return bytes[position..<(position + count)]
        }
        func littleEndian(_ slice: ArraySlice<UInt8>) -> UInt64 {
            slice.reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        if mask & 0x1 != 0 {
            guard let slice = take(16) else { return nil }
            decimal = decimal128(Array(slice))
        }
        if mask & 0x2 != 0 {
            guard let slice = take(8) else { return nil }
            double = Double(bitPattern: littleEndian(slice))
        }
        if mask & 0x4 != 0 {
            guard let slice = take(8) else { return nil }
            seconds = Double(bitPattern: littleEndian(slice))
        }
        if mask & 0x8 != 0 {
            guard let slice = take(4) else { return nil }
            stringID = littleEndian(slice)
        }
        if mask & 0x10 != 0 {
            guard let slice = take(4) else { return nil }
            richID = littleEndian(slice)
        }

        switch kind {
        case CellKind.text:
            return stringID.flatMap { strings[$0] }
        case CellKind.richText:
            return richID.flatMap { richText[$0] }
        case CellKind.number, CellKind.duration, CellKind.currency:
            return (decimal ?? double).map(NumberFormat.generalString)
        case CellKind.boolean:
            return (decimal ?? double).map { $0 != 0 ? "TRUE" : "FALSE" }
        case CellKind.date:
            return seconds.map(isoDate)
        default:
            return nil
        }
    }

    /// iWork's decimal128: little endian, sign in the top bit, 14 exponent bits, then the mantissa.
    private static func decimal128(_ bytes: [UInt8]) -> Double? {
        guard bytes.count == 16 else { return nil }
        let exponent = ((Int(bytes[15]) & 0x7F) << 7 | Int(bytes[14]) >> 1) - 0x1820
        var mantissa = Double(Int(bytes[14]) & 1)
        for index in stride(from: 13, through: 0, by: -1) {
            mantissa = mantissa * 256 + Double(bytes[index])
        }
        let value = mantissa * pow(10, Double(exponent))
        guard value.isFinite else { return nil }
        return bytes[15] & 0x80 != 0 ? -value : value
    }

    /// Seconds since 2001-01-01, written without a time zone since the cell has none.
    private static func isoDate(_ seconds: Double) -> String {
        let serial = seconds / 86400 + Double(NumberFormat.serial(year: 2001, month: 1, day: 1))
        let hasTime = seconds.truncatingRemainder(dividingBy: 86400) != 0
        return NumberFormat(code: hasTime ? "yyyy-mm-dd hh:mm:ss" : "yyyy-mm-dd").string(for: serial)
    }

    // MARK: Data lists

    /// `TST.TableDataList`: field 3 repeats { key 1, string 3 }.
    private func stringList(_ identifier: UInt64) -> [UInt64: String] {
        var result: [UInt64: String] = [:]
        for entry in store.parsed(identifier)?.messages(3) ?? [] {
            if let key = entry.varint(1), let text = entry.string(3) { result[key] = text }
        }
        return result
    }

    /// Rich text entries point through a payload object at a text storage.
    private func richTextList(_ identifier: UInt64) -> [UInt64: String] {
        var result: [UInt64: String] = [:]
        for entry in store.parsed(identifier)?.messages(3) ?? [] {
            guard let key = entry.varint(1) else { continue }
            let payload = entry.fields.lazy.compactMap { field -> UInt64? in
                guard case .bytes(let bytes) = field.value, let message = try? ProtoMessage(parsing: bytes),
                    let reference = message.varint(1), store.object(reference)?.type == IWAType.tableRichText
                else { return nil }
                return reference
            }.first
            guard let payload, let storageID = store.object(payload)?.objectReferences.first(where: { store.object($0)?.type == IWAType.textStorage }),
                let storage = store.parsed(storageID)
            else { continue }
            result[key] = storage.strings(3).joined().trimmingCharacters(in: .newlines)
        }
        return result
    }
}

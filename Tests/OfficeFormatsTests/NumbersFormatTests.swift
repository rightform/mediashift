import ConversionCore
import Foundation
import Testing

@testable import OfficeFormats

/// Numbers documents built object by object: a document with sheets, each sheet with a table.
@Suite struct NumbersFormatTests {
    private static func object(_ identifier: UInt64, type: UInt64, _ payload: ProtoMessage) -> IWAObject {
        let bytes = payload.serialized()
        let info = ProtoMessage(fields: [ProtoMessage.Field(1, varint: type), ProtoMessage.Field(3, varint: UInt64(bytes.count))])
        let header = ProtoMessage(fields: [ProtoMessage.Field(1, varint: identifier), ProtoMessage.Field(2, message: info)])
        return IWAObject(header: header, messages: [IWAObject.Message(info: info, payload: bytes)])
    }

    private static func reference(_ identifier: UInt64) -> ProtoMessage {
        ProtoMessage(fields: [ProtoMessage.Field(1, varint: identifier)])
    }

    /// One cell record: version 5, then the kind, a field mask at offset 8, then the value.
    private static func cell(kind: UInt8, string: UInt32? = nil, number: Double? = nil) -> [UInt8] {
        var record: [UInt8] = [5, kind, 0, 0, 0, 0, 0, 0]
        var mask: UInt32 = 0
        var tail: [UInt8] = []
        if let number {
            mask |= 0x2
            tail += withUnsafeBytes(of: number.bitPattern.littleEndian, Array.init)
        }
        if let string {
            mask |= 0x8
            tail += withUnsafeBytes(of: string.littleEndian, Array.init)
        }
        record += withUnsafeBytes(of: mask.littleEndian, Array.init)
        return record + tail
    }

    /// A table whose cells are given row by row. `nil` is an empty cell.
    private static func table(
        first: UInt64, name: String, rows: [[[UInt8]?]], strings: [UInt32: String]
    ) -> (info: UInt64, objects: [IWAObject]) {
        let info = first, model = first + 1, tile = first + 2, list = first + 3
        let columns = rows.map(\.count).max() ?? 0
        let rowInfos = rows.enumerated().map { index, cells -> ProtoMessage in
            var buffer: [UInt8] = []
            var offsets: [UInt8] = []
            for cell in cells {
                let offset: Int16 = cell == nil ? -1 : Int16(buffer.count)
                offsets += withUnsafeBytes(of: offset.littleEndian, Array.init)
                buffer += cell ?? []
            }
            return ProtoMessage(fields: [
                ProtoMessage.Field(1, varint: UInt64(index)),
                ProtoMessage.Field(6, .bytes(Data(buffer))),
                ProtoMessage.Field(7, .bytes(Data(offsets))),
            ])
        }
        let entries = strings.sorted { $0.key < $1.key }.map { key, text in
            ProtoMessage(fields: [ProtoMessage.Field(1, varint: UInt64(key)), ProtoMessage.Field(3, string: text)])
        }
        let tiles = ProtoMessage(fields: [
            ProtoMessage.Field(1, message: ProtoMessage(fields: [ProtoMessage.Field(1, varint: 0), ProtoMessage.Field(2, message: reference(tile))])),
            ProtoMessage.Field(2, varint: 256),
        ])
        let dataStore = ProtoMessage(fields: [ProtoMessage.Field(3, message: tiles), ProtoMessage.Field(4, message: reference(list))])
        return (info, [
            object(info, type: IWAType.tableInfo, ProtoMessage(fields: [ProtoMessage.Field(2, message: reference(model))])),
            object(model, type: IWAType.tableModel, ProtoMessage(fields: [
                ProtoMessage.Field(4, message: dataStore),
                ProtoMessage.Field(6, varint: UInt64(rows.count + 5)),
                ProtoMessage.Field(7, varint: UInt64(columns + 2)),
                ProtoMessage.Field(8, string: name),
                ProtoMessage.Field(9, varint: 1),
            ])),
            object(tile, type: IWAType.tableTile, ProtoMessage(fields: rowInfos.map { ProtoMessage.Field(5, message: $0) })),
            object(list, type: IWAType.tableDataList, ProtoMessage(fields: entries.map { ProtoMessage.Field(3, message: $0) })),
        ])
    }

    private static func document(sheets: [(name: String, table: (info: UInt64, objects: [IWAObject]))]) throws -> URL {
        var objects: [IWAObject] = []
        var sheetIDs: [UInt64] = []
        for (index, sheet) in sheets.enumerated() {
            let id = UInt64(100 + index)
            sheetIDs.append(id)
            objects.append(object(id, type: IWAType.numbersSheet, ProtoMessage(fields: [
                ProtoMessage.Field(1, string: sheet.name),
                ProtoMessage.Field(2, message: reference(sheet.table.info)),
            ])))
            objects += sheet.table.objects
        }
        let root = object(1, type: IWAType.numbersDocument, ProtoMessage(fields: sheetIDs.map { ProtoMessage.Field(1, message: reference($0)) }))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("fixture.numbers")
        try ZipWriter.write([ZipWriter.Part("Index/Document.iwa", IWAStream(objects: [root] + objects).compressed())], to: url, compression: .none)
        return url
    }

    @Test func readsEachSheetsTableRowByRow() throws {
        let costs = Self.table(first: 200, name: "Koszty", rows: [
            [Self.cell(kind: 3, string: 1), Self.cell(kind: 3, string: 2)],
            [Self.cell(kind: 3, string: 3), Self.cell(kind: 2, number: 1200.5)],
            [Self.cell(kind: 3, string: 4), Self.cell(kind: 10, number: 30)],
            [nil, nil],
        ], strings: [1: "Nazwa", 2: "Kwota", 3: "Łódź", 4: "Kraków"])
        let notes = Self.table(first: 300, name: "Uwagi", rows: [[Self.cell(kind: 3, string: 1)]], strings: [1: "Arkusz drugi"])
        let url = try Self.document(sheets: [("Finanse", costs), ("Drugi", notes)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let blocks = try NumbersFormat.read(url).blocks
        #expect(blocks.count == 4)
        #expect(blocks[0] == .heading(level: 1, content: [.text("Finanse")]))
        guard case .table(let table) = blocks[1], case .table(let second) = blocks[3] else {
            Issue.record("expected two tables, got \(blocks)")
            return
        }
        // A sheet's only table goes by the sheet's name, which the heading carries.
        #expect(table.name == nil)
        #expect(table.hasHeaderRow)
        // Rows in order, a currency amount included, and the unused rows and columns gone.
        #expect(table.rows.map { $0.map(\.plainText) } == [["Nazwa", "Kwota"], ["Łódź", "1200.5"], ["Kraków", "30"]])
        #expect(blocks[2] == .heading(level: 1, content: [.text("Drugi")]))
        #expect(second.rows.map { $0.map(\.plainText) } == [["Arkusz drugi"]])
    }

    @Test func sheetsBecomeWorkbookSheetsAndCSVRows() throws {
        let costs = Self.table(first: 200, name: "Tabela 1", rows: [
            [Self.cell(kind: 3, string: 1), Self.cell(kind: 3, string: 2)],
            [Self.cell(kind: 3, string: 3), Self.cell(kind: 2, number: 1200.5)],
        ], strings: [1: "Nazwa", 2: "Kwota", 3: "Łódź, centrum"])
        let notes = Self.table(first: 300, name: "Tabela 1", rows: [[Self.cell(kind: 3, string: 1)]], strings: [1: "Uwaga"])
        let url = try Self.document(sheets: [("Finanse", costs), ("Drugi", notes)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try NumbersFormat.read(url)

        let workbook = url.deletingLastPathComponent().appendingPathComponent("out.xlsx")
        try XLSXFormat.write(document, to: workbook)
        let tables = try XLSXFormat.read(workbook).blocks.compactMap { block -> Table? in
            if case .table(let table) = block { return table }
            return nil
        }
        // One sheet per Numbers sheet, by its name, and no extra sheet for the headings.
        #expect(tables.map(\.name) == ["Finanse", "Drugi"])
        #expect(tables.first?.rows.map { $0.map(\.plainText) } == [["Nazwa", "Kwota"], ["Łódź, centrum", "1200.5"]])

        let csv = url.deletingLastPathComponent().appendingPathComponent("out.csv")
        try CSVFormat.write(document, to: csv)
        let text = try String(contentsOf: csv, encoding: .utf8)
        #expect(text.contains("Nazwa,Kwota\r\n\"Łódź, centrum\",1200.5"))
        #expect(text.contains("Uwaga"))
    }

    @Test func aDocumentWithoutTablesReadsAsEmpty() throws {
        let url = try Self.document(sheets: [])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try NumbersFormat.read(url).blocks.isEmpty)
    }
}

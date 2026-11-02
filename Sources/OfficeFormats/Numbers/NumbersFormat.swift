import ConversionCore
import Foundation

/// Apple Numbers documents, read without Numbers: the tables of each sheet, in order.
public enum NumbersFormat {
    /// A heading per sheet and its tables. Text boxes, charts and formatting are left out, and
    /// values show the way `IWATableReader` writes them. An empty result means the document
    /// holds no table this reader could read.
    public static func read(_ url: URL) throws -> RichDocument {
        let package = try IWAPackage.open(url, formatName: "Numbers")
        if package.source.contains(".iwph") || package.index.contains(".iwph") {
            throw ConversionError("This Numbers document is password protected.")
        }
        var store = IWAObjectStore()
        for name in package.index.partNames where name.hasPrefix("Index/") && name.hasSuffix(".iwa") {
            guard let data = try package.index.data(forPart: name), let stream = try? IWAStream(compressed: data) else { continue }
            store.add(stream.objects)
        }
        let reader = IWATableReader(store: store)

        // The document lists its sheets in field 1, each sheet its name in field 1 and the
        // objects on it in field 2.
        let sheets = store.all(ofType: IWAType.numbersDocument).first.flatMap { store.parsed($0.identifier) }?
            .messages(1).compactMap { $0.varint(1) } ?? []
        var blocks: [Block] = []
        var seen: Set<UInt64> = []
        for sheetID in sheets {
            guard store.object(sheetID)?.type == IWAType.numbersSheet, let sheet = store.parsed(sheetID) else { continue }
            let tables = sheet.messages(2).compactMap { $0.varint(1) }
                .filter { store.object($0)?.type == IWAType.tableInfo }
                .compactMap { info -> Table? in
                    seen.insert(info)
                    return named(reader.table(forInfo: info), model: store.parsed(info)?.reference(2), store: store)
                }
                .filter { !$0.rows.isEmpty }
            guard !tables.isEmpty else { continue }
            blocks.append(.heading(level: 1, content: [.text(sheet.string(1) ?? "Sheet")]))
            // A sheet's only table goes by the sheet's name, which the heading carries. Tables
            // that share a sheet keep their own names.
            blocks += tables.map { table in
                var table = table
                if tables.count == 1 { table.name = nil }
                return .table(table)
            }
        }
        // A document whose sheets this reader cannot follow still has its tables.
        for (info, _) in store.all(ofType: IWAType.tableInfo) where !seen.contains(info) {
            if let table = named(reader.table(forInfo: info), model: store.parsed(info)?.reference(2), store: store), !table.rows.isEmpty {
                blocks.append(.table(table))
            }
        }
        return RichDocument(blocks: blocks)
    }

    /// A table model keeps its name in field 8.
    private static func named(_ table: Table?, model: UInt64?, store: IWAObjectStore) -> Table? {
        guard var table else { return nil }
        table.name = model.flatMap { store.parsed($0)?.string(8) }
        return table
    }
}

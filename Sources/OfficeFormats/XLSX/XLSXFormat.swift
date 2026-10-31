import ConversionCore
import Foundation

/// Excel workbooks.
public enum XLSXFormat {
    /// One `.table` per visible sheet (Table.name = sheet name), `.pageBreak` between them. Shared and inline strings, displayed values for number formats incl. dates and percentages, merged cells as spans, hasHeaderRow when first row is styled bold.
    public static func read(_ url: URL) throws -> RichDocument {
        try XLSXReader(package: ZipPackage(url: url, formatName: "XLSX")).read()
    }

    /// Every table becomes a sheet. Numeric-looking cells written as numbers, header row bold and frozen, sensible column widths. Text blocks outside tables go to a sheet of one column.
    public static func write(_ document: RichDocument, to url: URL) throws {
        try ZipWriter.write(XLSXWriter(document).parts(), to: url)
    }
}

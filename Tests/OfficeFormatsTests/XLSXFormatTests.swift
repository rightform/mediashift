import ConversionCore
import Foundation
import Testing
@testable import OfficeFormats

@Suite("XLSX")
struct XLSXFormatTests {
    private func tables(_ document: RichDocument) -> [Table] {
        document.blocks.compactMap { block in
            if case .table(let table) = block { return table }
            return nil
        }
    }

    private func texts(_ table: Table) -> [[String]] {
        table.rows.map { $0.map(\.plainText) }
    }

    private func table(_ rows: [[String]], name: String? = nil, header: Bool = false) -> Table {
        Table(name: name, rows: rows.map { $0.map(TableCell.init(text:)) }, hasHeaderRow: header)
    }

    // MARK: Round trips

    @Test func roundTripsSheetsTextAndNumbers() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        let first = table(
            [
                ["Imię", "Kwota", "Udział", "Data", "Kod"],
                ["Zażółć gęślą jaźń", "1234.5", "12.50%", "2024-03-15", "007"],
                ["😀 emoji", "-0.25", "5%", "2024-12-31 18:30", "+48 500"],
                ["a & b < c > \"d\"", "1,234,567.89", "", "", "12345678901234567890"],
                ["  spacje  ", "12.50", "", "", "1234567890123456"],
            ], name: "Dane", header: true)
        let second = table([["x", "1"], ["y", "2"]], name: "Drugi")
        let source = RichDocument(title: "Tytuł", author: "Autor", blocks: [.table(first), .pageBreak, .table(second)])
        try XLSXFormat.write(source, to: url)

        let result = try XLSXFormat.read(url)
        #expect(result.title == "Tytuł")
        #expect(result.author == "Autor")
        let sheets = tables(result)
        #expect(sheets.map(\.name) == ["Dane", "Drugi"])
        #expect(texts(sheets[0]) == texts(first))
        #expect(texts(sheets[1]) == texts(second))
        #expect(sheets[0].hasHeaderRow)
        #expect(!sheets[1].hasHeaderRow)
        // A hard boundary between sheets and none after the last.
        #expect(result.blocks.count == 3)
        #expect(result.blocks[1] == .pageBreak)
    }

    @Test func storesNumbersAsNumbersAndIdsAsText() {
        #expect(XLSXCellValue(text: "1234.5") == .number(raw: "1234.5", formatCode: nil))
        #expect(XLSXCellValue(text: "-7") == .number(raw: "-7", formatCode: nil))
        #expect(XLSXCellValue(text: "12.50") == .number(raw: "12.50", formatCode: "0.00"))
        #expect(XLSXCellValue(text: "1,234.50") == .number(raw: "1234.50", formatCode: "#,##0.00"))
        #expect(XLSXCellValue(text: "50%") == .number(raw: "0.5", formatCode: "0%"))
        #expect(XLSXCellValue(text: "123456789012345") == .number(raw: "123456789012345", formatCode: nil))
        for text in ["007", "+48", "1e5", "1.2.3", ".5", "5.", "-", "", "1234567890123456", "12345678901234567890", "abc", "12 500", "1,5", "-0"] {
            #expect(XLSXCellValue(text: text) == .text, "\(text) should stay text")
        }
    }

    @Test func writesDatesAsRealDates() throws {
        guard case .number(let raw, let code) = XLSXCellValue(text: "2023-03-15") else {
            Issue.record("expected a date cell")
            return
        }
        #expect(raw == "45000")
        #expect(code == "yyyy-mm-dd")
        for text in ["2023-13-01", "2023-02-30", "1899-01-01", "2023-1-1"] {
            #expect(XLSXCellValue(text: text) == .text, "\(text) should stay text")
        }
    }

    @Test func keepsNumberCellsTypedInTheFile() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        try XLSXFormat.write(RichDocument(blocks: [.table(table([["1", "abc"]]))]), to: url)
        let package = try ZipPackage(url: url, formatName: "XLSX")
        let sheet = String(decoding: try #require(try package.data(forPart: "xl/worksheets/sheet1.xml")), as: UTF8.self)
        #expect(sheet.contains("<c r=\"A1\"><v>1</v></c>"))
        #expect(sheet.contains("<c r=\"B1\" t=\"s\"><v>0</v></c>"))
    }

    @Test func freezesAndBoldsTheHeaderRow() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        try XLSXFormat.write(RichDocument(blocks: [.table(table([["a", "b"], ["1", "2"]], header: true))]), to: url)
        let package = try ZipPackage(url: url, formatName: "XLSX")
        let sheet = String(decoding: try #require(try package.data(forPart: "xl/worksheets/sheet1.xml")), as: UTF8.self)
        #expect(sheet.contains("state=\"frozen\""))
        #expect(sheet.contains("ySplit=\"1\""))
        #expect(sheet.contains("<col "))
        let styles = String(decoding: try #require(try package.data(forPart: "xl/styles.xml")), as: UTF8.self)
        #expect(styles.contains("<b/>"))
    }

    @Test func roundTripsMergedCells() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        var wide = TableCell(text: "wide")
        wide.columnSpan = 2
        var tall = TableCell(text: "tall")
        tall.rowSpan = 2
        let source = Table(rows: [
            [wide, TableCell(text: "c")],
            [tall, TableCell(text: "x"), TableCell(text: "y")],
            [TableCell(text: "p"), TableCell(text: "q")],
        ])
        try XLSXFormat.write(RichDocument(blocks: [.table(source)]), to: url)
        let result = try #require(tables(try XLSXFormat.read(url)).first)
        #expect(result.rows[0].map(\.plainText) == ["wide", "c"])
        #expect(result.rows[0][0].columnSpan == 2)
        #expect(result.rows[1][0].rowSpan == 2)
        #expect(result.rows[2].map(\.plainText) == ["p", "q"])
    }

    @Test func emptySheetAndEmptyDocument() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        try XLSXFormat.write(RichDocument(blocks: [.table(Table(name: "Pusty", rows: []))]), to: url)
        let sheets = tables(try XLSXFormat.read(url))
        #expect(sheets.count == 1)
        #expect(sheets[0].name == "Pusty")
        #expect(sheets[0].rows.isEmpty)

        let empty = folder.file("empty.xlsx")
        try XLSXFormat.write(RichDocument(), to: empty)
        let package = try ZipPackage(url: empty, formatName: "XLSX")
        try package.expectConsistentPackage()
        #expect(tables(try XLSXFormat.read(empty)).count == 1)
    }

    @Test func textBlocksGoToASingleColumnSheet() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        let document = RichDocument(blocks: [
            .heading(level: 1, content: [.text("Nagłówek")]),
            .paragraph(content: [.text("Akapit")]),
            .list(ordered: false, items: [[.paragraph(content: [.text("punkt")])]]),
            .table(table([["1"]], name: "Liczby")),
        ])
        try XLSXFormat.write(document, to: url)
        let sheets = tables(try XLSXFormat.read(url))
        #expect(sheets.map(\.name) == ["Liczby", "Text"])
        #expect(texts(sheets[1]) == [["Nagłówek"], ["Akapit"], ["punkt"]])
    }

    @Test func cleansSheetNames() {
        let names = XLSXWriter.uniqueSheetNames(["a/b*c", "Dane", "dane", nil, "'q'", "History", String(repeating: "x", count: 40), ""])
        #expect(names[0] == "abc")
        #expect(names[1] == "Dane")
        #expect(names[2] == "dane (2)")
        #expect(names[3] == "Sheet4")
        #expect(names[4] == "q")
        #expect(names[5] == "History (2)")
        #expect(names[6].count == 31)
        #expect(names[7] == "Sheet8")
    }

    @Test func clampsOversizedCellsAndRejectsOversizedTables() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        let long = String(repeating: "x", count: 40_000)
        try XLSXFormat.write(RichDocument(blocks: [.table(table([[long]]))]), to: url)
        let cell = try #require(tables(try XLSXFormat.read(url)).first?.rows.first?.first)
        #expect(cell.plainText.count == 32_767)

        let tooWide = Table(rows: [Array(repeating: TableCell(text: "x"), count: 16_385)])
        #expect(throws: ConversionError.self) {
            try XLSXFormat.write(RichDocument(blocks: [.table(tooWide)]), to: url)
        }
    }

    @Test func removesCharactersXMLForbids() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        try XLSXFormat.write(RichDocument(blocks: [.table(table([["a\u{01}b\u{0B}c"]]))]), to: url)
        #expect(texts(try #require(tables(try XLSXFormat.read(url)).first)) == [["abc"]])
    }

    // MARK: Reading what Excel writes

    private func workbookParts(sheet: String, styles: String? = nil, strings: String? = nil, workbook: String? = nil) -> [String: String] {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var parts: [String: String] = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
            "_rels/.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="/xl/workbook.xml"/></Relationships>
                """,
            "xl/workbook.xml": workbook ?? """
                <workbook xmlns="\(main)" xmlns:r="\(rel)"><sheets>\
                <sheet name="Arkusz" sheetId="1" r:id="rId1"/></sheets></workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId3" Type="\(rel)/styles" Target="styles.xml"/>\
                <Relationship Id="rId4" Type="\(rel)/sharedStrings" Target="sharedStrings.xml"/></Relationships>
                """,
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(main)\">\(sheet)</worksheet>",
        ]
        if let styles { parts["xl/styles.xml"] = "<styleSheet xmlns=\"\(main)\">\(styles)</styleSheet>" }
        if let strings { parts["xl/sharedStrings.xml"] = "<sst xmlns=\"\(main)\">\(strings)</sst>" }
        return parts
    }

    private func readFixture(_ parts: [String: String]) throws -> RichDocument {
        let folder = try TemporaryFolder()
        let url = folder.file("fixture.xlsx")
        try makeZip(at: url, parts: parts)
        return try XLSXFormat.read(url)
    }

    @Test func readsSharedInlineAndRichStrings() throws {
        let document = try readFixture(workbookParts(
            sheet: """
                <sheetData><row r="1">\
                <c r="A1" t="s"><v>0</v></c>\
                <c r="B1" t="s"><v>1</v></c>\
                <c r="C1" t="inlineStr"><is><t>wstawiony</t></is></c>\
                <c r="D1" t="inlineStr"><is><r><t>bogaty </t></r><r><t>tekst</t></r></is></c>\
                <c r="E1" t="b"><v>1</v></c>\
                <c r="F1" t="e"><v>#N/A</v></c>\
                <c r="G1" t="str"><f>A1</f><v>wynik</v></c>\
                </row></sheetData>
                """,
            strings: """
                <si><t>zwykły</t></si>\
                <si><r><rPr><b/></rPr><t>Bo</t></r><r><t>ld</t></r><rPh sb="0" eb="1"><t>ignored</t></rPh></si>
                """))
        let sheet = try #require(tables(document).first)
        #expect(sheet.name == "Arkusz")
        #expect(texts(sheet) == [["zwykły", "Bold", "wstawiony", "bogaty tekst", "TRUE", "#N/A", "wynik"]])
    }

    @Test func showsDisplayedValues() throws {
        let document = try readFixture(workbookParts(
            sheet: """
                <sheetData><row r="1">\
                <c r="A1" s="1"><v>45000</v></c>\
                <c r="B1" s="2"><v>0.125</v></c>\
                <c r="C1" s="3"><v>45000</v></c>\
                <c r="D1" s="4"><v>1234.5</v></c>\
                <c r="E1"><v>12345678901234</v></c>\
                <c r="F1"><v>1.5E+300</v></c>\
                <c r="G1"><v>0.30000000000000004</v></c>\
                </row></sheetData>
                """,
            styles: """
                <numFmts count="2"><numFmt numFmtId="164" formatCode="dd\\.mm\\.yyyy"/>\
                <numFmt numFmtId="165" formatCode="#,##0.00\\ &quot;zł&quot;"/></numFmts>\
                <cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="10"/>\
                <xf numFmtId="164"/><xf numFmtId="165"/></cellXfs>
                """))
        let sheet = try #require(tables(document).first)
        #expect(texts(sheet) == [["2023-03-15", "12.50%", "15.03.2023", "1,234.50 zł", "12345678901234", "1.5E+300", "0.3"]])
    }

    @Test func understands1904Dates() throws {
        let document = try readFixture(workbookParts(
            sheet: "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>0</v></c></row></sheetData>",
            styles: "<cellXfs count=\"2\"><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/></cellXfs>",
            workbook: """
                <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
                <workbookPr date1904="1"/><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
                """))
        #expect(texts(try #require(tables(document).first)) == [["1904-01-01"]])
    }

    @Test func skipsHiddenSheetsAndSeparatesVisibleOnes() throws {
        let document = try readFixture(workbookParts(
            sheet: "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>",
            workbook: """
                <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
                <sheets><sheet name="Widoczny" sheetId="1" r:id="rId1"/>\
                <sheet name="Ukryty" sheetId="2" state="hidden" r:id="rId2"/>\
                <sheet name="Bardzo ukryty" sheetId="3" state="veryHidden" r:id="rId2"/>\
                <sheet name="Drugi" sheetId="4" r:id="rId2"/></sheets></workbook>
                """))
        #expect(tables(document).map(\.name) == ["Widoczny", "Drugi"])
        #expect(document.blocks.count == 3)
    }

    @Test func fillsGapsAndUnderstandsMissingReferences() throws {
        let document = try readFixture(workbookParts(sheet: """
            <sheetData><row r="2"><c r="C2"><v>1</v></c></row>\
            <row><c><v>2</v></c><c><v>3</v></c></row></sheetData>
            """))
        #expect(texts(try #require(tables(document).first)) == [["", "", ""], ["", "", "1"], ["2", "3", ""]])
    }

    @Test func boldFirstRowMeansHeader() throws {
        let styles = """
            <fonts count="3"><font/><font><b/></font><font><b val="0"/></font></fonts>\
            <cellXfs count="3"><xf numFmtId="0" fontId="0"/><xf numFmtId="0" fontId="1"/><xf numFmtId="0" fontId="2"/></cellXfs>
            """
        func header(_ cells: String) throws -> Bool {
            let document = try readFixture(workbookParts(sheet: "<sheetData><row r=\"1\">\(cells)</row></sheetData>", styles: styles))
            return try #require(tables(document).first).hasHeaderRow
        }
        #expect(try header("<c r=\"A1\" s=\"1\"><v>1</v></c><c r=\"B1\" s=\"1\"><v>2</v></c>"))
        #expect(try !header("<c r=\"A1\" s=\"1\"><v>1</v></c><c r=\"B1\" s=\"0\"><v>2</v></c>"))
        #expect(try !header("<c r=\"A1\" s=\"2\"><v>1</v></c>"))
    }

    // MARK: Hostile input

    @Test func malformedFilesThrow() throws {
        let folder = try TemporaryFolder()
        let garbage = folder.file("garbage.xlsx")
        try Data("this is not a zip".utf8).write(to: garbage)
        #expect(throws: ConversionError.self) { try XLSXFormat.read(garbage) }

        let empty = folder.file("empty.xlsx")
        try Data().write(to: empty)
        #expect(throws: ConversionError.self) { try XLSXFormat.read(empty) }

        let noWorkbook = folder.file("no-workbook.xlsx")
        try makeZip(at: noWorkbook, parts: ["hello.txt": "hello"])
        #expect(throws: ConversionError.self) { try XLSXFormat.read(noWorkbook) }

        #expect(throws: ConversionError.self) {
            try readFixture(workbookParts(sheet: "<sheetData><row><c>"))
        }
        // A shared string index past the end of the table.
        #expect(throws: ConversionError.self) {
            try readFixture(workbookParts(sheet: "<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>99</v></c></row></sheetData>"))
        }
    }

    @Test func truncatedArchiveThrows() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        try XLSXFormat.write(RichDocument(blocks: [.table(table([["a"]]))]), to: url)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count / 2).write(to: url)
        #expect(throws: ConversionError.self) { try XLSXFormat.read(url) }
    }

    @Test func refusesDocumentTypeDeclarations() {
        #expect(throws: ConversionError.self) {
            try readFixture(workbookParts(sheet: "<sheetData/>").merging(
                ["xl/workbook.xml": "<!DOCTYPE lolz [<!ENTITY lol \"lol\">]><workbook/>"], uniquingKeysWith: { $1 }))
        }
    }

    @Test func aFarAwayCellDoesNotExplodeTheGrid() throws {
        let document = try readFixture(workbookParts(
            sheet: "<sheetData><row r=\"1048576\"><c r=\"XFD1048576\"><v>1</v></c></row></sheetData>"))
        let sheet = try #require(tables(document).first)
        #expect(sheet.rows.count == 1_048_576)
        #expect(sheet.rows.last?.count == 16_384)
        #expect(sheet.rows.first?.isEmpty == true)
    }

    // MARK: The only independent reader on this machine

    @Test func quickLookReadsWrittenWorkbook() async throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        let source = table([["Imię", "Kwota"], ["Zażółć gęślą jaźń", "1234.5"], ["😀 emoji", "2024-03-15"]], name: "Dane", header: true)
        try XLSXFormat.write(RichDocument(blocks: [.table(source), .table(table([["Drugi arkusz"]], name: "Inny"))]), to: url)

        let package = try ZipPackage(url: url, formatName: "XLSX")
        try package.expectWellFormedXML()
        try package.expectConsistentPackage()

        let text = try await quickLookText(of: url)
        #expect(text.contains("Zażółć gęślą jaźń"))
        #expect(text.contains("😀 emoji"))
        // Quick Look formats numbers for the system locale, which also shows the cell is a number.
        #expect(text.contains("1234.5") || text.contains("1234,5"))
        #expect(text.contains("Drugi arkusz"))
        #expect(text.contains("2024-03-15"))
    }
}

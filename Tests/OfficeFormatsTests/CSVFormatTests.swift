import ConversionCore
import Foundation
import Testing
@testable import OfficeFormats

@Suite("CSV")
struct CSVFormatTests {
    private func rows(_ document: RichDocument) -> [[String]] {
        guard case .table(let table)? = document.blocks.first else { return [] }
        return table.rows.map { $0.map(\.plainText) }
    }

    private func read(_ bytes: [UInt8], delimiter: Character? = nil) throws -> RichDocument {
        let folder = try TemporaryFolder()
        let url = folder.file("input.csv")
        try Data(bytes).write(to: url)
        return try CSVFormat.read(url, delimiter: delimiter)
    }

    private func read(_ text: String, delimiter: Character? = nil) throws -> RichDocument {
        try read(Array(text.utf8), delimiter: delimiter)
    }

    @Test func roundTripsDiacriticsEmojiCommasQuotesAndNewlines() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("data.csv")
        let source = [
            ["Imię", "Opis, krótki", "Uwagi"],
            ["Zażółć gęślą jaźń", "powiedział \"tak\"", "😀 emoji"],
            ["druga\nlinia", "", "1,5"],
        ]
        let table = Table(rows: source.map { $0.map(TableCell.init(text:)) })
        try CSVFormat.write(RichDocument(blocks: [.table(table)]), to: url)
        #expect(rows(try CSVFormat.read(url)) == source)
    }

    @Test func writesRFC4180Quoting() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("data.csv")
        let table = Table(rows: [["a,b", "c\"d", "e"].map(TableCell.init(text:))])
        try CSVFormat.write(RichDocument(blocks: [.table(table)]), to: url)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: data.dropFirst(3), as: UTF8.self) == "\"a,b\",\"c\"\"d\",e\r\n")
    }

    @Test(arguments: [
        ("a,b,c\n1,2,3\n", ","),
        ("a;b;c\n1;2;3\n", ";"),
        ("a\tb\tc\n1\t2\t3\n", "\t"),
        ("cena;ilość\n1,50;2\n3,75;4\n", ";"),
        ("name,note\nx,\"one;two;three\"\ny,\"four;five\"\n", ","),
    ] as [(String, Character)])
    func detectsDelimiter(text: String, expected: Character) {
        #expect(CSVFormat.detectDelimiter(in: text) == expected)
    }

    @Test func singleColumnFallsBackToComma() {
        #expect(CSVFormat.detectDelimiter(in: "one\ntwo\nthree\n") == ",")
    }

    @Test func explicitDelimiterWins() throws {
        #expect(rows(try read("a|b\nc|d\n", delimiter: "|")) == [["a", "b"], ["c", "d"]])
    }

    @Test func decodesEncodings() throws {
        let polish = "Zażółć,gęślą\n"
        // UTF-8 without a BOM.
        #expect(rows(try read(polish)) == [["Zażółć", "gęślą"]])
        // UTF-8 with a BOM, which must not end up in the first cell.
        #expect(rows(try read([0xEF, 0xBB, 0xBF] + Array(polish.utf8))) == [["Zażółć", "gęślą"]])
        // Windows-1250.
        let cp1250 = try #require(polish.data(using: .windowsCP1250))
        #expect(rows(try read(Array(cp1250))) == [["Zażółć", "gęślą"]])
        // UTF-16 with a BOM, what Excel calls Unicode text.
        let utf16 = try #require(polish.data(using: .utf16))
        #expect(rows(try read(Array(utf16))) == [["Zażółć", "gęślą"]])
    }

    @Test func latin1IsTheLastResort() throws {
        // 0xE9 is é in Latin-1 and in Windows-1250, so check the byte Windows-1250 leaves undefined.
        let text = try CSVFormat.decode(Data([0x61, 0x81, 0x62]))
        #expect(text.first == "a" && text.last == "b")
    }

    @Test func handlesLineEndingsAndUnevenRows() throws {
        #expect(rows(try read("a,b\r\nc\rd,e,f\n")) == [["a", "b", ""], ["c", "", ""], ["d", "e", "f"]])
    }

    @Test func keepsQuotedNewlinesAndDropsTrailingBlankLines() throws {
        #expect(rows(try read("\"x\ny\",z\n\n\n")) == [["x\ny", "z"]])
    }

    @Test func unterminatedQuoteDoesNotHang() throws {
        #expect(rows(try read("a,\"b\nc")) == [["a", "b\nc"]])
    }

    @Test func emptyFileHasNoBlocks() throws {
        #expect(try read("").blocks.isEmpty)
    }

    @Test func binaryDataThrows() {
        #expect(throws: ConversionError.self) {
            try read([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])
        }
    }

    @Test func missingFileThrows() {
        #expect(throws: ConversionError.self) {
            try CSVFormat.read(URL(fileURLWithPath: "/nonexistent/file.csv"))
        }
    }

    @Test func detectsHeaderRow() throws {
        guard case .table(let withHeader)? = try read("name,age\nAda,36\n").blocks.first,
            case .table(let withoutHeader)? = try read("1,2\n3,4\n").blocks.first
        else {
            Issue.record("expected tables")
            return
        }
        #expect(withHeader.hasHeaderRow)
        #expect(!withoutHeader.hasHeaderRow)
    }

    @Test func writesAllTablesSeparatedByAnEmptyLine() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("data.csv")
        let first = Table(rows: [["a"].map(TableCell.init(text:))])
        let second = Table(rows: [["b"].map(TableCell.init(text:))])
        let document = RichDocument(blocks: [.paragraph(content: [.text("ignored")]), .table(first), .pageBreak, .table(second)])
        try CSVFormat.write(document, to: url)
        let text = String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self)
        #expect(text == "a\r\n\r\nb\r\n")
    }

    @Test func withoutTablesWritesOneRowPerTextBlock() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("data.csv")
        let document = RichDocument(blocks: [
            .heading(level: 1, content: [.text("Tytuł")]),
            .pageBreak,
            .paragraph(content: [.text("Akapit, z przecinkiem")]),
        ])
        try CSVFormat.write(document, to: url)
        #expect(rows(try CSVFormat.read(url)) == [["Tytuł"], ["Akapit, z przecinkiem"]])
    }

    @Test func mergedCellsKeepTheirGridPositions() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("data.csv")
        var merged = TableCell(text: "wide")
        merged.columnSpan = 2
        var tall = TableCell(text: "tall")
        tall.rowSpan = 2
        let table = Table(rows: [
            [merged, TableCell(text: "c")],
            [tall, TableCell(text: "x"), TableCell(text: "y")],
            [TableCell(text: "p"), TableCell(text: "q")],
        ])
        try CSVFormat.write(RichDocument(blocks: [.table(table)]), to: url)
        #expect(rows(try CSVFormat.read(url)) == [["wide", "", "c"], ["tall", "x", "y"], ["", "p", "q"]])
    }
}

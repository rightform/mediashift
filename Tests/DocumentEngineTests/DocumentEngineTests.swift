import AppKit
import ConversionCore
import Foundation
import PDFKit
import Testing

@testable import DocumentEngine

/// One document that exercises every block type, with characters that break naive encoders.
private let sample = RichDocument(
    title: "Zażółć gęślą jaźń",
    author: "Test Author",
    blocks: [
        .heading(level: 1, content: [.text("Zażółć gęślą jaźń")]),
        .paragraph(content: [
            .text("Plain, "),
            .text("bold", TextStyle(bold: true)),
            .text(" and "),
            .text("italic", TextStyle(italic: true)),
            .text(" with <tags> & \"quotes\" 🙂"),
        ]),
        .heading(level: 2, content: [.text("Second level")]),
        .list(ordered: false, items: [
            [.paragraph(content: [.text("First bullet")])],
            [
                .paragraph(content: [.text("Second bullet")]),
                .list(ordered: true, items: [[.paragraph(content: [.text("Nested number")])]]),
            ],
        ]),
        .table(ConversionCore.Table(
            rows: [
                [TableCell(text: "Name"), TableCell(text: "Value")],
                [TableCell(text: "Łódź"), TableCell(text: "42")],
            ],
            hasHeaderRow: true
        )),
        .code("let x = 1 < 2", language: "swift"),
        .quote([.paragraph(content: [.text("A quoted line")])]),
        .paragraph(content: [.text("A link", TextStyle(link: "https://example.com/?a=1&b=2"))]),
    ]
)

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func pngImage() -> ImageAsset {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return ImageAsset(data: bitmap.representation(using: .png, properties: [:])!, mimeType: "image/png", alt: "Dot")
}

/// Checks that a reader found everything in `sample`, whatever the format did to its styling.
private func expectSampleText(in document: RichDocument, sourceLocation: SourceLocation = #_sourceLocation) {
    let text = document.plainText
    for expected in ["Zażółć gęślą jaźń", "bold", "<tags> & \"quotes\" 🙂", "Second level", "First bullet", "Nested number", "Łódź", "42", "let x = 1 < 2", "A quoted line"] {
        #expect(text.contains(expected), "missing \(expected)", sourceLocation: sourceLocation)
    }
}

private func firstHeadingLevel(_ document: RichDocument) -> Int? {
    for block in document.blocks {
        if case .heading(let level, _, _) = block { return level }
    }
    return nil
}

private func containsTable(_ blocks: [Block]) -> ConversionCore.Table? {
    for block in blocks {
        if case .table(let table) = block { return table }
    }
    return nil
}

private func containsList(_ blocks: [Block]) -> Bool {
    blocks.contains { if case .list = $0 { true } else { false } }
}

// MARK: - Plain text and Markdown

@Test func plainTextKeepsParagraphsAndLineBreaks() {
    let document = PlainTextReader.parse("One\nstill one\n\nTwo\r\n\r\nThree")
    #expect(document.blocks.count == 3)
    #expect(document.blocks[0].plainText == "One\nstill one")
}

@Test func textDecodingHandlesLegacyEncodings() {
    let polish = "Zażółć"
    #expect(TextDecoding.decode(polish.data(using: .windowsCP1250)!) == polish)
    #expect(TextDecoding.decode(polish.data(using: .utf16)!) == polish)
    #expect(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data(polish.utf8)) == polish)
}

@Test func markdownRoundTripKeepsStructure() throws {
    let rendered = MarkdownWriter.render(sample)
    let parsed = MarkdownReader.parse(rendered)
    expectSampleText(in: parsed)
    #expect(firstHeadingLevel(parsed) == 1)
    #expect(containsList(parsed.blocks))
    #expect(containsTable(parsed.blocks)?.hasHeaderRow == true)
    #expect(rendered.contains("**bold**"))
    #expect(rendered.contains("*italic*"))
    #expect(rendered.contains("[A link](https://example.com/?a=1&b=2)"))
}

@Test func markdownWriterStoresImagesInAFolder() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("doc.md")
    try MarkdownWriter.write(RichDocument(blocks: [.image(pngImage())]), to: url)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("doc-images/image-1.png").path))
    let reread = try MarkdownReader.read(url)
    guard case .image(let image)? = reread.blocks.first else {
        Issue.record("the image did not come back")
        return
    }
    #expect(image.mimeType == "image/png")
}

@Test func markdownNeverFetchesRemoteImages() {
    let document = MarkdownReader.parse("![Alt text](https://example.com/a.png)")
    #expect(document.plainText == "Alt text")
}

// MARK: - Markdown front matter

@Test(arguments: [
    "---\ntitle: Raport\nauthor: Ala Kot\n---\n\nTreść",
    "---\ntitle: \"Raport\"\nauthor: 'Ala Kot'\n---\nTreść",
    "---\nTitle: Raport # do zmiany\nAuthor: Ala Kot\n---\nTreść",
    "---\r\ntitle: Raport\r\nauthor: Ala Kot\r\n---\r\n\r\nTreść",
    "---\ntitle: Raport\nauthor: Ala Kot\n...\nTreść",
    "\n\n---  \ntitle: Raport\nauthor: Ala Kot\n---  \nTreść",
    "---\ntitle: Raport\nauthors:\n  - Ala Kot\n---\nTreść",
    "---\ntitle: Raport\nauthor: [Ala Kot]\n---\nTreść",
])
func markdownFrontMatterBecomesDocumentData(source: String) {
    let document = MarkdownReader.parse(source)
    #expect(document.title == "Raport")
    #expect(document.author == "Ala Kot")
    #expect(document.plainText == "Treść")
}

@Test func markdownFrontMatterCanHoldMoreThanItUses() {
    let source = """
        ---
        # Tokens for the design
        name: Projekt
        tags: [a, b]
        colors:
          primary: "#b4552f"
          nested:
            - one
            - two
        authors:
          - Ala Kot
          - Ola Pies
        description: |
          Tekst na kilka
          linii.
        ---

        # Nagłówek

        Treść
        """
    let document = MarkdownReader.parse(source)
    #expect(document.title == nil)
    #expect(document.author == "Ala Kot, Ola Pies")
    #expect(document.inferredTitle == "Nagłówek")
    #expect(document.plainText == "Nagłówek\n\nTreść")
}

@Test func markdownFrontMatterCanBeEmpty() {
    let document = MarkdownReader.parse("---\n---\nTreść")
    #expect(document.blocks == [.paragraph(content: [.text("Treść")])])
}

@Test func markdownTableAfterFrontMatterIsStillRepaired() throws {
    let document = MarkdownReader.parse("---\ntitle: Raport\n---\n\nWstęp\n\n| A | B |\n|---|\n| 1 | 2 |")
    #expect(document.blocks.first?.plainText == "Wstęp")
    #expect(try texts(#require(containsTable(document.blocks))) == [["A", "B"], ["1", "2"]])
}

@Test func htmlShowsFrontMatterOnlyAsPageData() {
    let rendered = HTMLWriter.render(MarkdownReader.parse("---\ntitle: Raport roczny\nauthor: Ala Kot\n---\n\nTreść"))
    #expect(rendered.contains("<title>Raport roczny</title>"))
    #expect(rendered.contains("<meta name=\"author\" content=\"Ala Kot\">"))
    #expect(!rendered.contains("<hr>"))
    #expect(!rendered.contains("title:"))
}

@Test(arguments: [
    "---\nNagłówek\n---\nTreść",
    "---\n\nTreść między liniami\n\n---\n",
    "---\ntitle: Bez zamknięcia\n\nTreść",
    "Treść\n\n---\ntitle: W środku\n---\n",
    "----\ntitle: Za długa linia\n----\nTreść",
    "---\nhttps://example.com\n---\nTreść",
    "---\n\n---\nTreść",
])
func markdownRulesAreNotMistakenForFrontMatter(source: String) {
    let document = MarkdownReader.parse(source)
    #expect(document.title == nil)
    #expect(document.blocks.contains { if case .rule = $0 { true } else if case .heading = $0 { true } else { false } })
}

// MARK: - Markdown tables

private func texts(_ table: ConversionCore.Table) -> [[String]] {
    table.rows.map { $0.map(\.plainText) }
}

@Test(arguments: [
    "| A | B | C |\n|---|---|\n| 1 | 2 | 3 |",
    "| A | B | C |\n|---|---|---|---|\n| 1 | 2 | 3 |",
    "| A | B | C |\n| — | — | — |\n| 1 | 2 | 3 |",
    "| A | B | C |\n|–––|–––|–––|\n| 1 | 2 | 3 |",
    "| A | B | C |\n|\u{A0}---\u{A0}|\u{A0}---\u{A0}|\u{A0}---\u{A0}|\n| 1 | 2 | 3 |",
    "| A | B | C |\n| - - - | - - - | - - - |\n| 1 | 2 | 3 |",
    "| A | B | C |\r\n|---|---|\r\n| 1 | 2 | 3 |\r\n",
    "A | B | C\n---|---\n1 | 2 | 3",
])
func markdownTableWithAWrongDividerIsStillATable(source: String) throws {
    let table = try #require(containsTable(MarkdownReader.parse(source).blocks))
    #expect(texts(table) == [["A", "B", "C"], ["1", "2", "3"]])
    #expect(table.hasHeaderRow)
}

@Test func markdownTableRepairKeepsWhatIsAroundIt() throws {
    let intro = MarkdownReader.parse("Wstęp:\n| A | B |\n|---|\n| 1 | 2 |")
    #expect(intro.blocks.first?.plainText == "Wstęp:")
    #expect(try texts(#require(containsTable(intro.blocks))) == [["A", "B"], ["1", "2"]])

    // A row wider than the header keeps all its cells.
    let wide = try #require(containsTable(MarkdownReader.parse("| A | B |\n|---|---|---|\n| 1 | 2 | 3 |").blocks))
    #expect(texts(wide) == [["A", "B", ""], ["1", "2", "3"]])

    let escaped = try #require(containsTable(MarkdownReader.parse("| A \\| B | C |\n|---|\n| **1** | 2 |").blocks))
    #expect(texts(escaped) == [["A | B", "C"], ["1", "2"]])

    let aligned = try #require(containsTable(MarkdownReader.parse("| A | B |\n|--:|\n| 1 | 2 |").blocks))
    guard case .paragraph(_, .right)? = aligned.rows[1][0].blocks.first else {
        Issue.record("the alignment was lost")
        return
    }

    guard case .quote(let quoted)? = MarkdownReader.parse("> | A | B |\n> |---|\n> | 1 | 2 |").blocks.first else {
        Issue.record("the quote was lost")
        return
    }
    #expect(containsTable(quoted) != nil)

    guard case .list(_, let items)? = MarkdownReader.parse("1. | A | B |\n   |---|\n   | 1 | 2 |").blocks.first else {
        Issue.record("the list was lost")
        return
    }
    #expect(try texts(#require(containsTable(items[0]))) == [["A", "B"], ["1", "2"]])
}

@Test(arguments: [
    "Cena | wartość to zapis\nz kreską w środku",
    "| A | B |\n| 1 | 2 |",
    "Tytuł\n---",
    "- jeden | dwa\n- trzy",
])
func markdownTextWithPipesIsNotMistakenForATable(source: String) {
    #expect(containsTable(MarkdownReader.parse(source).blocks) == nil)
}

@Test func markdownCodeWithATableInsideStaysCode() {
    let code = "| A | B |\n|---|\n| 1 | 2 |"
    #expect(MarkdownReader.parse("```\n\(code)\n```").blocks == [.code(code, language: nil)])
}

@Test func markdownTableKeepsColumnAlignment() throws {
    let table = try #require(containsTable(MarkdownReader.parse("| L | C | R | N |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |").blocks))
    func alignment(_ cell: TableCell) -> TextAlignment? {
        if case .paragraph(_, let alignment)? = cell.blocks.first { return alignment }
        return nil
    }
    #expect(table.rows[1].map(alignment) == [nil, .center, .right, nil])

    let html = HTMLWriter.render(RichDocument(blocks: [.table(table)]))
    #expect(html.contains("<th style=\"text-align:center\">C</th>"))
    #expect(html.contains("<td style=\"text-align:right\">3</td>"))
    #expect(html.contains("<td>4</td>"))
}

@Test func markdownTableLeavesOutPositionsUnderASpan() throws {
    let table = try #require(containsTable(MarkdownReader.parse("| A | B | C |\n|---|---|---|\n| 1 || 3 |\n| x | y | z |\n| ^ | q | r |").blocks))
    #expect(texts(table) == [["A", "B", "C"], ["1", "3"], ["x", "y", "z"], ["q", "r"]])
    #expect(table.rows[1][0].columnSpan == 2)
    #expect(table.rows[2][0].rowSpan == 2)
    #expect(table.rows[3].allSatisfy { $0.columnSpan == 1 && $0.rowSpan == 1 })
}

@Test(arguments: ["<br>", "<br/>", "<br />", "<BR>"])
func markdownTableKeepsLineBreaksInCells(tag: String) throws {
    let table = try #require(containsTable(MarkdownReader.parse("| A |\n|---|\n| 1\(tag)2 |").blocks))
    #expect(table.rows[1][0].plainText == "1\n2")
}

@Test func markdownTableLineBreaksSurviveARoundTrip() throws {
    let cell = TableCell(blocks: [.paragraph(content: [.text("1"), .lineBreak, .text("2")])])
    let document = RichDocument(blocks: [.table(ConversionCore.Table(rows: [[TableCell(text: "A")], [cell]], hasHeaderRow: true))])
    let table = try #require(containsTable(MarkdownReader.parse(MarkdownWriter.render(document)).blocks))
    #expect(table.rows[1][0].plainText == "1\n2")
}

// MARK: - Tables in HTML

private func tableDocument(rows: [[String]], hasHeaderRow: Bool = true) -> RichDocument {
    RichDocument(blocks: [.table(ConversionCore.Table(rows: rows.map { $0.map { TableCell(text: $0) } }, hasHeaderRow: hasHeaderRow))])
}

@Test func htmlTableHasAHeaderSectionOnlyWhenItHasAHeader() {
    let headed = HTMLWriter.render(tableDocument(rows: [["A"], ["1"]]))
    #expect(headed.contains("<thead>\n<tr><th>A</th></tr>\n</thead>"))
    #expect(headed.contains("<tbody>\n<tr><td>1</td></tr>\n</tbody>"))

    let plain = HTMLWriter.render(tableDocument(rows: [["A"], ["1"]], hasHeaderRow: false))
    #expect(!plain.contains("<thead>"))
    #expect(plain.contains("<tbody>\n<tr><td>A</td></tr>\n<tr><td>1</td></tr>\n</tbody>"))

    let headerOnly = HTMLWriter.render(tableDocument(rows: [["A"]]))
    #expect(!headerOnly.contains("<tbody>"))
}

@Test func tableWordsWrapOnlyWhereItReadsWell() {
    #expect(TableFit.segments(of: "Odpowiedzialność") == ["Odpowiedzialność"])
    #expect(TableFit.segments(of: "Sources/DocumentEngine/HTMLWriter.swift") == ["Sources/", "DocumentEngine/", "HTMLWriter", ".swift"])
    #expect(TableFit.segments(of: String(repeating: "x", count: 45)).map(\.count) == [20, 20, 5])

    #expect(TableFit.isFigure("2026-11-02"))
    #expect(TableFit.isFigure("12:30"))
    #expect(TableFit.isFigure("1200,50"))
    #expect(!TableFit.isFigure("1200"))
    #expect(!TableFit.isFigure("v1-beta"))
    #expect(!TableFit.isFigure("--"))
}

@Test func longWordsInATableGetPlacesToWrapAndLoseNoText() throws {
    let address = "https://example.com/a/very/long/path/to/file.html?a=1&b=2"
    let rendered = HTMLWriter.render(tableDocument(rows: [["Adres", "Data"], [address, "2026-11-02"]]))
    #expect(rendered.contains("<wbr>"))
    #expect(rendered.contains("<span class=\"nowrap\">2026-11-02</span>"))
    #expect(rendered.contains("&amp;"))

    let table = try #require(containsTable(HTMLReader.parse(rendered).blocks))
    #expect(texts(table) == [["Adres", "Data"], [address, "2026-11-02"]])

    // Outside a table the text wraps by itself.
    let paragraph = HTMLWriter.render(RichDocument(blocks: [.paragraph(content: [.text(address)])]))
    #expect(!paragraph.contains("<wbr>"))
}

@Test func tableMarkupIsWellFormedForEPUB() throws {
    let document = tableDocument(rows: [["Adres", "Data"], ["https://example.com/a/very/long/path/to/file.html", "2026-11-02"]])
    let body = HTMLBodyRenderer(xhtml: true) { _ in "" }.render(document.blocks)
    #expect(body.contains("<wbr/>"))
    _ = try XMLDocument(xmlString: "<body>\(body)</body>", options: [])
}

@Test func tableDensityFollowsWhatTheColumnsNeed() {
    func density(columns: Int, word: String) -> String? {
        TableFit.density(of: ConversionCore.Table(rows: [Array(repeating: TableCell(text: word), count: columns)]))
    }
    #expect(density(columns: 3, word: "Krótki") == nil)
    #expect(density(columns: 7, word: "Dziennik") == nil)
    #expect(density(columns: 8, word: "Dziennik") == "dense")
    #expect(density(columns: 10, word: "Dziennik") == "denser")
    #expect(density(columns: 12, word: "Dziennik") == "denser fixed")
    #expect(density(columns: 24, word: "Odpowiedzialność") == "denser fixed")
}

// MARK: - Tables on PDF pages

@MainActor
private func pageTexts(of document: RichDocument) async throws -> [String] {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("out.pdf")
    try await WebPDFRenderer.render(html: HTMLWriter.render(document), to: url)
    let pdf = try #require(PDFDocument(url: url))
    return (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
}

private func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
}

@MainActor
@Test func longTableRepeatsItsHeaderOnEveryPage() async throws {
    let rows = [["Nazwisko", "Cena"]] + (1...90).map { ["Pozycja\($0)", "\($0) zł"] }
    let pages = try await pageTexts(of: tableDocument(rows: rows))
    #expect(pages.count >= 3)
    #expect(pages.allSatisfy { words($0).contains("Nazwisko") })
    // Every row appears once, in order.
    let found = pages.flatMap { words($0).filter { $0.hasPrefix("Pozycja") } }
    #expect(found == (1...90).map { "Pozycja\($0)" })
}

@MainActor
@Test func tallRowsAreNotCutByAPage() async throws {
    let filler = String(repeating: "tekst który zawija się na wiele linii w tej komórce ", count: 6)
    let rows = [["A", "B"]] + (1...40).map { ["Pierwszy\($0)", "\(filler) Ostatni\($0)"] }
    let pages = try await pageTexts(of: tableDocument(rows: rows))
    #expect(pages.count >= 2)
    for row in 1...40 {
        let page = pages.firstIndex { words($0).contains("Pierwszy\(row)") }
        #expect(page != nil)
        #expect(page == pages.firstIndex { words($0).contains("Ostatni\(row)") }, "row \(row)")
    }
}

@MainActor
@Test func aTableThatFitsOnAPageIsNotSplit() async throws {
    // Whatever the text above it leaves, at several lengths.
    let paragraph = Block.paragraph(content: [.text(String(repeating: "Zwykły tekst nad tabelą. ", count: 20))])
    let table = ConversionCore.Table(
        rows: [[TableCell(text: "A")]] + (1...14).map { [TableCell(text: "Wiersz\($0)")] },
        hasHeaderRow: true
    )
    for count in stride(from: 3, through: 12, by: 3) {
        let blocks = Array(repeating: paragraph, count: count) + [.table(table), .paragraph(content: [.text("Koniec")])]
        let pages = try await pageTexts(of: RichDocument(blocks: blocks))
        let holding = pages.filter { page in words(page).contains { $0.hasPrefix("Wiersz") } }
        #expect(holding.count == 1, "\(count) paragraphs")
    }
}

@MainActor
@Test func aHeadingStaysWithItsTable() async throws {
    let paragraph = Block.paragraph(content: [.text(String(repeating: "Zwykły tekst nad tabelą. ", count: 20))])
    let long = ConversionCore.Table(rows: [[TableCell(text: "A")]] + (1...60).map { [TableCell(text: "Wiersz\($0)")] }, hasHeaderRow: true)
    let short = ConversionCore.Table(rows: [[TableCell(text: "A")]] + (1...8).map { [TableCell(text: "Wiersz\($0)")] }, hasHeaderRow: true)
    for table in [long, short] {
        for count in 4...18 {
            let blocks = Array(repeating: paragraph, count: count) + [.heading(level: 2, content: [.text("Nagłówektabeli")]), .table(table)]
            let pages = try await pageTexts(of: RichDocument(blocks: blocks))
            let heading = pages.firstIndex { words($0).contains("Nagłówektabeli") }
            #expect(heading != nil)
            #expect(heading == pages.firstIndex { words($0).contains("Wiersz1") }, "\(count) paragraphs")
        }
    }
}

@MainActor
@Test func wideTableKeepsShortWordsWhole() async throws {
    let long = String(repeating: "Zdanie opisujące, co dokładnie się zmieniło. ", count: 3)
    let rows = [["Lp.", "Nazwa", "Opis", "Plik", "Adres", "Stan", "Data"]] + (1...3).map { row in
        ["\(row)", "Dziennik", long, "Sources/DocumentEngine/Writers/HTMLWriter.swift", "https://github.com/rightform/mediashift/blob/main/README.md#section", "gotowe", "2026-11-02"]
    }
    let pages = try await pageTexts(of: tableDocument(rows: rows))
    let found = pages.flatMap(words)
    for word in ["Nazwa", "Dziennik", "gotowe", "2026-11-02"] {
        #expect(found.contains(word), "\(word) was broken up")
    }
}

// MARK: - HTML

@Test func htmlRoundTripKeepsStructureAndEscaping() {
    let rendered = HTMLWriter.render(sample)
    #expect(rendered.contains("&lt;tags&gt;"))
    let parsed = HTMLReader.parse(rendered)
    expectSampleText(in: parsed)
    #expect(parsed.title == "Zażółć gęślą jaźń")
    #expect(parsed.author == "Test Author")
    #expect(firstHeadingLevel(parsed) == 1)
    #expect(containsTable(parsed.blocks)?.hasHeaderRow == true)
}

@Test func htmlReaderSurvivesMalformedInput() {
    let parsed = HTMLReader.parse("<p>Open <b>bold<p>Next<table><tr><td>Cell")
    #expect(parsed.plainText.contains("Open"))
    #expect(parsed.plainText.contains("Cell"))
}

@Test func htmlReaderIgnoresScriptsAndReadsInlineStyles() {
    let parsed = HTMLReader.parse(#"<script>evil()</script><p><span style="color:#ff0000;font-weight:bold">Red</span></p>"#)
    #expect(!parsed.plainText.contains("evil"))
    guard case .paragraph(let content, _)? = parsed.blocks.first, case .text(_, let style)? = content.first else {
        Issue.record("no paragraph")
        return
    }
    #expect(style.color == "#FF0000")
    #expect(style.bold)
}

@Test func htmlWriterDropsScriptLinks() {
    let document = RichDocument(blocks: [.paragraph(content: [.text("Click", TextStyle(link: "javascript:alert(1)"))])])
    #expect(!HTMLWriter.render(document).contains("javascript:"))
}

// MARK: - Word

@Test func docxRoundTripKeepsStructureAndStyles() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("sample.docx")
    try DOCXWriter.write(sample, to: url)

    let parsed = try DOCXReader.read(url)
    expectSampleText(in: parsed)
    #expect(parsed.title == "Zażółć gęślą jaźń")
    #expect(parsed.author == "Test Author")
    #expect(firstHeadingLevel(parsed) == 1)
    #expect(containsList(parsed.blocks))
    let table = try #require(containsTable(parsed.blocks))
    #expect(table.hasHeaderRow)
    #expect(table.rows[1][0].plainText == "Łódź")

    let hasBold = parsed.blocks.contains { block in
        if case .paragraph(let content, _) = block {
            return content.contains { if case .text("bold", let style) = $0 { style.bold } else { false } }
        }
        return false
    }
    #expect(hasBold)
}

@Test func docxIsReadableBySystemWordImporter() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("sample.docx")
    try DOCXWriter.write(sample, to: url)
    // The system's importer is an independent reader of the file.
    let text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
    #expect(text.string.contains("Zażółć gęślą jaźń"))
    #expect(text.string.contains("Łódź"))
}

@Test func docxKeepsImagesAndMergedCells() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("images.docx")
    let document = RichDocument(blocks: [
        .image(pngImage()),
        .table(ConversionCore.Table(rows: [
            [TableCell(blocks: [.paragraph(content: [.text("Tall")])], rowSpan: 2), TableCell(text: "A")],
            [TableCell(text: "B")],
        ])),
    ])
    try DOCXWriter.write(document, to: url)
    let parsed = try DOCXReader.read(url)
    #expect(parsed.blocks.contains { if case .image(let image) = $0 { image.mimeType == "image/png" } else { false } })
    let table = try #require(containsTable(parsed.blocks))
    #expect(table.rows[0][0].rowSpan == 2)
    #expect(table.rows[1].count == 1)
}

@Test func damagedDocxThrowsInsteadOfCrashing() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("bad.docx")
    try Data("not a zip".utf8).write(to: url)
    #expect(throws: ConversionError.self) { try DOCXReader.read(url) }
}

// MARK: - RTF and OpenDocument

@Test(arguments: [FileFormat.rtf, FileFormat.odt])
func attributedFormatsRoundTrip(format: FileFormat) throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("sample.\(format.fileExtension)")
    try AttributedTextWriter.write(sample, to: url, format: format)
    let parsed = try AttributedTextReader.read(url, format: format)
    let text = parsed.plainText
    for expected in ["Zażółć gęślą jaźń", "bold", "Second level", "First bullet", "Nested number", "Łódź", "A quoted line"] {
        #expect(text.contains(expected), "missing \(expected)")
    }
    #expect(firstHeadingLevel(parsed) != nil)
}

@Test func rtfKeepsBoldAndItalic() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("sample.rtf")
    try AttributedTextWriter.write(sample, to: url, format: .rtf)
    let parsed = try AttributedTextReader.read(url, format: .rtf)
    var sawBold = false
    var sawItalic = false
    for block in parsed.blocks {
        guard case .paragraph(let content, _) = block else { continue }
        for inline in content {
            if case .text(let text, let style) = inline {
                if text.contains("bold"), style.bold { sawBold = true }
                if text.contains("italic"), style.italic { sawItalic = true }
            }
        }
    }
    #expect(sawBold)
    #expect(sawItalic)
}

// MARK: - EPUB

@Test func epubRoundTripKeepsChaptersAndImages() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("book.epub")
    let document = RichDocument(
        title: "Książka",
        author: "Autor",
        blocks: sample.blocks + [.heading(level: 1, content: [.text("Chapter two")]), .image(pngImage())]
    )
    try EPUBWriter.write(document, to: url)

    let package = try ZipReader(url: url, formatName: "EPUB")
    #expect(package.paths.first == "mimetype")
    #expect(package.paths.contains("OEBPS/chapter-2.xhtml"))

    let parsed = try EPUBReader.read(url)
    expectSampleText(in: parsed)
    #expect(parsed.title == "Książka")
    #expect(parsed.author == "Autor")
    #expect(parsed.blocks.contains { if case .pageBreak = $0 { true } else { false } })
    #expect(parsed.blocks.contains { block in
        if case .image = block { return true }
        if case .paragraph(let content, _) = block {
            return content.contains { if case .image = $0 { true } else { false } }
        }
        return false
    })
}

@Test func epubChaptersAreWellFormedXML() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("book.epub")
    try EPUBWriter.write(sample, to: url)
    let package = try ZipReader(url: url, formatName: "EPUB")
    for path in package.paths where path.hasSuffix(".xhtml") || path.hasSuffix(".opf") || path.hasSuffix(".ncx") {
        let data = try #require(package.data(at: path))
        #expect(throws: Never.self) { _ = try XMLDocument(data: data, options: []) }
    }
}

// MARK: - PDF

@MainActor
@Test func htmlBecomesAPaginatedA4PDF() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("out.pdf")
    let long = (1...200).map { Block.paragraph(content: [.text("Line \($0) of Zażółć gęślą jaźń")]) }
    try await WebPDFRenderer.render(html: HTMLWriter.render(RichDocument(blocks: long)), to: url)

    let pdf = try #require(PDFDocument(url: url))
    #expect(pdf.pageCount > 2)
    let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(bounds.width - 595) < 2)
    #expect(abs(bounds.height - 842) < 2)
    #expect(pdf.string?.contains("Line 200") == true)
    #expect(pdf.string?.contains("Zażółć") == true)
}

@MainActor
@Test func pdfTextIsReadBackAsParagraphs() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("out.pdf")
    try await WebPDFRenderer.render(html: HTMLWriter.render(sample), to: url)
    let parsed = try await PDFTextReader.read(url)
    #expect(parsed.plainText.contains("Second level"))
    #expect(parsed.plainText.contains("Łódź"))
    #expect(firstHeadingLevel(parsed) != nil)
}

@MainActor
@Test func pdfPagesRenderToImagesAndMetadataCanBeRemoved() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.pdf")
    let signed = RichDocument(blocks: [.paragraph(content: [.text("Visible text")])])
    try await WebPDFRenderer.render(html: HTMLWriter.render(signed), to: source)

    // Stamp metadata into the file, as a word processor would.
    let stamped = folder.appendingPathComponent("stamped.pdf")
    let pdf = try #require(PDFDocument(url: source))
    pdf.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Secret Author", PDFDocumentAttribute.titleAttribute: "Secret Title"]
    #expect(pdf.write(to: stamped))
    #expect(PDFDocument(url: stamped)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Secret Author")

    let clean = folder.appendingPathComponent("clean.pdf")
    try PDFTools.stripMetadata(stamped, to: clean)
    let cleaned = try #require(PDFDocument(url: clean))
    #expect((cleaned.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? "").isEmpty)
    #expect(cleaned.string?.contains("Visible text") == true)
    #expect(try Data(contentsOf: clean).range(of: Data("Secret".utf8)) == nil)

    let images = try PDFTools.renderPages(of: clean, into: folder, baseName: "page", format: .png)
    #expect(images.count == 1)
    #expect(NSImage(contentsOf: images[0]) != nil)
}

@Test func compressionNeverGrowsAFile() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("small.pdf")
    let page = PDFDocument()
    page.insert(PDFPage(), at: 0)
    #expect(page.write(to: source))
    let output = folder.appendingPathComponent("out.pdf")
    try PDFTools.compress(source, to: output, level: .strong)
    let before = try #require(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let after = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(after <= before)
}

// MARK: - Office metadata

@Test func officeMetadataIsRemovedAndContentStays() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.docx")
    try DOCXWriter.write(sample, to: source)
    let output = folder.appendingPathComponent("clean.docx")
    try OOXMLMetadata.strip(source, to: output)

    let parsed = try DOCXReader.read(output)
    #expect(parsed.author == nil)
    #expect(parsed.title == nil)
    expectSampleText(in: parsed)
    let core = try ZipReader(url: output, formatName: "Word").data(at: "docProps/core.xml")
    #expect(core.flatMap { String(data: $0, encoding: .utf8) }?.contains("Test Author") == false)
}

// MARK: - Fixes from the conversion audit

@Test func docxKeepsAListThatFollowsAnotherApart() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("lists.docx")
    try DOCXWriter.write(RichDocument(blocks: [
        .list(ordered: false, items: [[.paragraph(content: [.text("Punkt")])]]),
        .list(ordered: true, items: [[.paragraph(content: [.text("Numer jeden")])], [.paragraph(content: [.text("Numer dwa")])]]),
    ]), to: url)

    let blocks = try DOCXReader.read(url).blocks
    guard blocks.count == 2, case .list(false, let bullets) = blocks[0], case .list(true, let numbers) = blocks[1] else {
        Issue.record("expected a bullet list and a numbered list, got \(blocks)")
        return
    }
    #expect(bullets.count == 1)
    #expect(numbers.count == 2)
}

@Test func docxQuoteStyleBecomesAQuote() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("quote.docx")
    try DOCXWriter.write(RichDocument(blocks: [
        .quote([.paragraph(content: [.text("Pierwsza linia")]), .paragraph(content: [.text("Druga linia")])]),
        .paragraph(content: [.text("Po cytacie")]),
    ]), to: url)

    let blocks = try DOCXReader.read(url).blocks
    #expect(blocks.count == 2)
    guard case .quote(let quoted)? = blocks.first else {
        Issue.record("the quote was lost")
        return
    }
    #expect(quoted.map(\.plainText) == ["Pierwsza linia", "Druga linia"])
}

@Test func docxColumnsFollowTheirText() throws {
    let long = String(repeating: "Zdanie opisujące, co dokładnie się zmieniło. ", count: 4)
    let table = ConversionCore.Table(rows: [
        [TableCell(text: "Lp."), TableCell(text: "Opis"), TableCell(text: "Data")],
        [TableCell(text: "1"), TableCell(text: long), TableCell(text: "2026-11-02")],
    ], hasHeaderRow: true)
    let widths = TableFit.columnWidths(of: table, total: 9026, characterWidth: 110)
    #expect(widths.reduce(0, +) == 9026)
    #expect(widths[1] > widths[0] * 3)
    // The date keeps room for itself on one line.
    #expect(widths[2] >= 12 * 110)

    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("table.docx")
    try DOCXWriter.write(RichDocument(blocks: [.table(table)]), to: url)
    let xml = try String(decoding: #require(ZipReader(url: url, formatName: "Word").data(at: "word/document.xml")), as: UTF8.self)
    #expect(xml.contains("<w:gridCol w:w=\"\(widths[1])\"/>"))
}

@Test func tableWidthsShareTheRoomWhenEverythingFits() {
    let table = ConversionCore.Table(rows: [[TableCell(text: "A"), TableCell(text: "Dłuższy tekst")]])
    let widths = TableFit.columnWidths(of: table, total: 1000, characterWidth: 10)
    #expect(widths.reduce(0, +) == 1000)
    #expect(widths[1] > widths[0])
}

@Test func mergedRowsKeepColumnsInPlaceInTextFormats() {
    let table = ConversionCore.Table(rows: [
        [TableCell(text: "A"), TableCell(text: "B"), TableCell(text: "C")],
        [TableCell(blocks: [.paragraph(content: [.text("Pion")])], rowSpan: 2), TableCell(text: "5 zł"), TableCell(text: "x")],
        [TableCell(text: "6 zł"), TableCell(text: "y")],
    ], hasHeaderRow: true)
    let document = RichDocument(blocks: [.table(table)])

    let markdown = MarkdownWriter.render(document)
    #expect(markdown.contains("|  | 6 zł | y |"))
    let reread = try? #require(containsTable(MarkdownReader.parse(markdown).blocks))
    #expect(reread.map(texts) == [["A", "B", "C"], ["Pion", "5 zł", "x"], ["", "6 zł", "y"]])

    #expect(PlainTextWriter.render(document).contains("\n\t6 zł\ty"))
}

@Test func markdownTasksKeepTheirBoxes() {
    let document = MarkdownReader.parse("- [x] Zrobione\n- [ ] Do zrobienia\n- Zwykły punkt")
    guard case .list(_, let items)? = document.blocks.first else {
        Issue.record("the list was lost")
        return
    }
    #expect(items.map { $0.first?.plainText } == ["☑ Zrobione", "☐ Do zrobienia", "Zwykły punkt"])
}

@Test func markdownFootnotesBecomeNumberedNotes() throws {
    let source = """
        Pierwszy[^b] i drugi[^a] przypis, a [^brak] zostaje.

        [^a]: Treść **a**.
        [^b]: Treść b,
            ciąg dalszy.
        """
    let document = MarkdownReader.parse(source)
    guard case .paragraph(let content, _)? = document.blocks.first else {
        Issue.record("the paragraph was lost")
        return
    }
    #expect(content.contains(.text("1", TextStyle(superscript: true))))
    #expect(content.contains(.text("2", TextStyle(superscript: true))))
    #expect(content.plainText == "Pierwszy1 i drugi2 przypis, a [^brak] zostaje.")
    guard case .list(true, let notes)? = document.blocks.last else {
        Issue.record("the notes are missing")
        return
    }
    // Numbered in the order the text mentions them.
    #expect(notes.map { $0.map(\.plainText).joined() } == ["Treść b, ciąg dalszy.", "Treść a."])
    #expect(!document.plainText.contains("[^a]:"))
}

@Test func markdownFootnoteLookalikesInCodeStayCode() {
    let source = "```\n[^1]: nie przypis\n```\n\nTekst `[^1]`.\n\n[^1]: Przypis."
    let document = MarkdownReader.parse(source)
    #expect(document.blocks.first == .code("[^1]: nie przypis", language: nil))
    #expect(document.blocks[1].plainText == "Tekst [^1].")
}

@MainActor
@Test func aTrailingEmptyPageIsDropped() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ending = folder.appendingPathComponent("ending.pdf")
    try await WebPDFRenderer.render(html: HTMLWriter.render(RichDocument(blocks: [.paragraph(content: [.text("Tekst")]), .pageBreak])), to: ending)
    #expect(PDFDocument(url: ending)?.pageCount == 1)

    // A last page with only a picture is not empty.
    let picture = folder.appendingPathComponent("picture.pdf")
    let image = ImageAsset(data: try #require(NSBitmapImageRep(cgImage: redSquare()).representation(using: .png, properties: [:])), mimeType: "image/png")
    try await WebPDFRenderer.render(html: HTMLWriter.render(RichDocument(blocks: [.paragraph(content: [.text("Tekst")]), .pageBreak, .image(image)])), to: picture)
    #expect(PDFDocument(url: picture)?.pageCount == 2)
}

private func redSquare() -> CGImage {
    let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    return context.makeImage()!
}

/// The shape of the HTML that macOS's preview gives for a PowerPoint file.
@MainActor
@Test func slidesPrintOnePerPageInTheirOwnShape() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let html = folder.appendingPathComponent("Preview.html")
    let slide = { (text: String) in
        "<div class=\"slide\" style=\"top:0; left:0;\"><div style=\"position:absolute; top:85; left:95; width:1730; height:112;\"><p style=\"font-size:116\">\(text)</p></div></div>"
    }
    try Data("""
        <html><head><meta charset="utf-8"><style type="text/css">div.slide { position:relative; } div.slide, div.loading-slide { overflow:hidden; page-break-inside: avoid; margin-top: 5px; } @media screen { body { background: #ACB2BB; } }</style><style type="text/css">div.slide, div.loading-slide { width: 1920; height: 1080;}</style></head>
        <body>\(slide("Pierwszy slajd szeroki na całą szerokość ekranu"))\(slide("Drugi"))\(slide("Trzeci"))</body></html>
        """.utf8).write(to: html)
    let output = folder.appendingPathComponent("slides.pdf")

    try await WebPDFRenderer.render(slides: html, slideSize: CGSize(width: 1920, height: 1080), to: output)

    let pdf = try #require(PDFDocument(url: output))
    #expect(pdf.pageCount == 3)
    let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(box.width / box.height - 16.0 / 9.0) < 0.01)
    // The long title wraps inside its box, and every word of it is on the page.
    let first = words(pdf.page(at: 0)?.string ?? "")
    #expect(first == ["Pierwszy", "slajd", "szeroki", "na", "całą", "szerokość", "ekranu"])
    #expect(pdf.page(at: 2)?.string?.contains("Trzeci") == true)
}

@Test func docxGivesAWideTableSmallerText() throws {
    let wide = ConversionCore.Table(rows: [Array(repeating: TableCell(text: "Dziennik"), count: 10)])
    let narrow = ConversionCore.Table(rows: [[TableCell(text: "A"), TableCell(text: "B")]])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("tables.docx")
    try DOCXWriter.write(RichDocument(blocks: [.table(wide), .table(narrow)]), to: url)

    let package = try ZipReader(url: url, formatName: "Word")
    let xml = String(decoding: try #require(package.data(at: "word/document.xml")), as: UTF8.self)
    let styles = String(decoding: try #require(package.data(at: "word/styles.xml")), as: UTF8.self)
    #expect(xml.contains("<w:tblStyle w:val=\"TableGridDenser\"/>"))
    #expect(xml.contains("<w:tblStyle w:val=\"TableGrid\"/>"))
    #expect(styles.contains("w:styleId=\"TableGridDenser\""))
}

// MARK: - Reading structure back from PDF

@MainActor
private func readBack(html: String) async throws -> RichDocument {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("page.pdf")
    try await WebPDFRenderer.render(html: html, to: url)
    return try await PDFTextReader.read(url, recognizesScans: false)
}

@MainActor
private func readBack(_ document: RichDocument) async throws -> RichDocument {
    try await readBack(html: HTMLWriter.render(document))
}

@MainActor
@Test func pdfTablesComeBackAsTables() async throws {
    let source = ConversionCore.Table(rows: [
        ["Nazwa", "Cena", "Opis"],
        ["Łódź", "1200,50 zł", "Środek"],
        ["Kraków", "30 zł", "Zdanie dłuższe niż jedna linia w tej kolumnie, które się zawija w komórce tabeli."],
    ].map { $0.map(TableCell.init(text:)) }, hasHeaderRow: true)
    let document = try await readBack(RichDocument(blocks: [
        .paragraph(content: [.text("Przed tabelą.")]), .table(source), .paragraph(content: [.text("Po tabeli.")]),
    ]))
    let table = try #require(containsTable(document.blocks))
    #expect(texts(table) == texts(source))
    #expect(document.blocks.first?.plainText == "Przed tabelą.")
    #expect(document.blocks.last?.plainText == "Po tabeli.")
}

@MainActor
@Test func pdfListsAndParagraphsKeepTheirShape() async throws {
    let long = String(repeating: "Zdanie, które wypełnia linię i przechodzi do następnej. ", count: 6)
    let document = try await readBack(RichDocument(blocks: [
        .paragraph(content: [.text(long + "Koniec pierwszego.")]),
        .paragraph(content: [.text("Drugi akapit.")]),
        .list(ordered: true, items: [[.paragraph(content: [.text("Pierwszy punkt")])], [.paragraph(content: [.text("Drugi punkt")])]]),
    ]))
    #expect(document.blocks.count == 3)
    #expect(document.blocks[0].plainText.hasSuffix("Koniec pierwszego."))
    #expect(document.blocks[1].plainText == "Drugi akapit.")
    guard case .list(true, let items) = document.blocks[2] else {
        Issue.record("the list was lost: \(document.blocks)")
        return
    }
    #expect(items.map { $0.map(\.plainText).joined() } == ["Pierwszy punkt", "Drugi punkt"])
}

@MainActor
@Test func pdfKeepsNumbersThatDoNotCountFromOne() async throws {
    let document = try await readBack(RichDocument(blocks: [
        .paragraph(content: [.text("3. Trzeci punkt umowy.")]),
        .paragraph(content: [.text("4. Czwarty punkt umowy.")]),
        .paragraph(content: [.text("b) Litera zostaje.")]),
    ]))
    #expect(document.blocks.map(\.plainText) == ["3. Trzeci punkt umowy.", "4. Czwarty punkt umowy.", "b) Litera zostaje."])
}

@MainActor
@Test func pdfColumnsOfTextReadInOrder() async throws {
    let paragraphs = (1...6).map { "<p>Akapit \($0). Tekst ciągły, który płynie z jednej linii do następnej i z jednej kolumny do drugiej, jak w gazecie. Koniec \($0).</p>" }
    let document = try await readBack(html: "<html><body style='font: 11pt Helvetica'><div style='column-count: 2; column-gap: 24pt'>\(paragraphs.joined())</div></body></html>")
    let found = document.blocks.map(\.plainText).filter { $0.hasPrefix("Akapit") }
    #expect(found.count == 6)
    #expect(found.map { String($0.prefix(9)) } == (1...6).map { "Akapit \($0)." })
    #expect(found.allSatisfy { $0.hasSuffix("Koniec \($0.dropFirst(7).prefix(1)).") })
}

@MainActor
@Test func pdfTextThatRunsOnToTheNextPageStaysOneParagraph() async throws {
    let text = (1...900).map { _ in "słowo" }.joined(separator: " ")
    let document = try await readBack(RichDocument(blocks: [.paragraph(content: [.text(text + " koniec.")])]))
    let paragraphs = document.blocks.filter { if case .paragraph = $0 { true } else { false } }
    #expect(paragraphs.count == 1)
    #expect(words(paragraphs.first?.plainText ?? "").count == 901)
}

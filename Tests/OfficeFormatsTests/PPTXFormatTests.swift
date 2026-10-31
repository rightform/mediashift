import ConversionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OfficeFormats

/// A real PNG of the given size in pixels.
func makePNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

@Suite("PPTX")
struct PPTXFormatTests {
    private func slides(_ document: RichDocument) -> [[Block]] {
        var result: [[Block]] = [[]]
        for block in document.blocks {
            if block == .pageBreak {
                result.append([])
            } else {
                result[result.count - 1].append(block)
            }
        }
        return result
    }

    private func paragraph(_ text: String) -> Block {
        .paragraph(content: [.text(text)])
    }

    private func heading(_ text: String, level: Int = 1) -> Block {
        .heading(level: level, content: [.text(text)])
    }

    private func roundTrip(_ document: RichDocument) throws -> RichDocument {
        let folder = try TemporaryFolder()
        let url = folder.file("deck.pptx")
        try PPTXFormat.write(document, to: url)
        let package = try ZipPackage(url: url, formatName: "PPTX")
        try package.expectWellFormedXML()
        try package.expectConsistentPackage()
        return try PPTXFormat.read(url)
    }

    // MARK: Round trips

    @Test func roundTripsTitlesParagraphsAndMetadata() throws {
        let result = try roundTrip(RichDocument(title: "Prezentacja", author: "Autor", blocks: [
            heading("Pierwszy slajd: zażółć 😀"),
            paragraph("Zażółć gęślą jaźń & <znaki>"),
            heading("Drugi slajd", level: 2),
            paragraph("Treść"),
            .pageBreak,
            paragraph("Slajd bez tytułu"),
        ]))
        #expect(result.title == "Prezentacja")
        #expect(result.author == "Autor")
        let deck = slides(result)
        #expect(deck.count == 3)
        #expect(deck[0] == [heading("Pierwszy slajd: zażółć 😀"), paragraph("Zażółć gęślą jaźń & <znaki>")])
        #expect(deck[1] == [heading("Drugi slajd"), paragraph("Treść")])
        #expect(deck[2] == [paragraph("Slajd bez tytułu")])
    }

    @Test func aHeadingAfterAPageBreakDoesNotMakeAnEmptySlide() throws {
        let deck = slides(try roundTrip(RichDocument(blocks: [
            .pageBreak, heading("A"), .pageBreak, .pageBreak, heading("B"), heading("C"),
        ])))
        #expect(deck == [[heading("A")], [heading("B")], [heading("C")]])
    }

    @Test func roundTripsNestedLists() throws {
        let list = Block.list(ordered: false, items: [
            [paragraph("jeden"), .list(ordered: true, items: [[paragraph("a")], [paragraph("b")]])],
            [paragraph("dwa")],
        ])
        #expect(slides(try roundTrip(RichDocument(blocks: [list]))) == [[list]])
    }

    @Test func roundTripsInlineStyles() throws {
        var bold = TextStyle(bold: true)
        bold.color = "#FF0000"
        let content: [Inline] = [
            .text("zwykły "),
            .text("gruby", bold),
            .text(" "),
            .text("kursywa", TextStyle(italic: true)),
            .text(" "),
            .text("link", TextStyle(link: "https://example.com/?a=1&b=2")),
            .text(" "),
            .text("podkreślony", TextStyle(underline: true)),
            .lineBreak,
            .text("przekreślony", TextStyle(strikethrough: true)),
            .text(" "),
            .text("mały", TextStyle(fontSize: 12, fontFamily: "Menlo")),
            .text(" "),
            .text("x", TextStyle(superscript: true)),
        ]
        let block = Block.paragraph(content: content, alignment: .center)
        #expect(slides(try roundTrip(RichDocument(blocks: [block]))) == [[block]])
    }

    @Test func roundTripsTablesWithMerges() throws {
        var wide = TableCell(text: "szeroka")
        wide.columnSpan = 2
        var tall = TableCell(text: "wysoka")
        tall.rowSpan = 2
        let source = Table(rows: [
            [wide, TableCell(text: "c")],
            [tall, TableCell(text: "ż"), TableCell(text: "😀")],
            [TableCell(text: "p"), TableCell(text: "")],
        ], hasHeaderRow: true)
        let result = slides(try roundTrip(RichDocument(blocks: [.table(source)])))
        guard case .table(let table)? = result.first?.first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.hasHeaderRow)
        #expect(table.rows.map { $0.map(\.plainText) } == [["szeroka", "c"], ["wysoka", "ż", "😀"], ["p", ""]])
        #expect(table.rows[0][0].columnSpan == 2)
        #expect(table.rows[1][0].rowSpan == 2)
    }

    @Test func roundTripsImages() throws {
        let png = try makePNG(width: 40, height: 20)
        let image = ImageAsset(data: png, mimeType: "image/png", alt: "Opis", width: 100, height: 50)
        let result = slides(try roundTrip(RichDocument(blocks: [heading("Obraz"), .image(image), paragraph("po")])))
        guard case .image(let read)? = result.first?[1] else {
            Issue.record("expected an image")
            return
        }
        #expect(read.data == png)
        #expect(read.mimeType == "image/png")
        #expect(read.alt == "Opis")
        #expect(read.width == 100)
        #expect(read.height == 50)
    }

    @Test func storesARepeatedImageOnce() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("deck.pptx")
        let image = ImageAsset(data: try makePNG(width: 8, height: 8), mimeType: "image/png")
        try PPTXFormat.write(RichDocument(blocks: [.image(image), .pageBreak, .image(image)]), to: url)
        let package = try ZipPackage(url: url, formatName: "PPTX")
        #expect(package.partNames.filter { $0.hasPrefix("ppt/media/") }.count == 1)
    }

    @Test func unreadableImagesFallBackToTheirDescription() throws {
        let junk = ImageAsset(data: Data("not an image".utf8), mimeType: "image/png", alt: "Opis")
        #expect(slides(try roundTrip(RichDocument(blocks: [.image(junk)]))) == [[paragraph("Opis")]])
    }

    @Test func inlineImagesLeaveTheText() throws {
        let image = ImageAsset(data: try makePNG(width: 8, height: 8), mimeType: "image/png")
        let result = slides(try roundTrip(RichDocument(blocks: [
            .paragraph(content: [.text("przed"), .image(image), .text("po")])
        ])))
        #expect(result[0].count == 3)
        #expect(result[0][0] == paragraph("przed"))
        #expect(result[0][2] == paragraph("po"))
    }

    // MARK: Overflow

    @Test func splitsOverflowingTextOntoContinuationSlides() throws {
        let sentence = "Zażółć gęślą jaźń i jeszcze trochę tekstu, który musi się gdzieś zmieścić. "
        let long = String(repeating: sentence, count: 120)
        let result = slides(try roundTrip(RichDocument(blocks: [heading("Długi"), paragraph(long)])))
        #expect(result.count > 2)
        var text = ""
        for slide in result {
            #expect(slide.first == heading("Długi"), "continuation slides keep the title")
            text += slide.dropFirst().map(\.plainText).joined()
        }
        #expect(text == long)
    }

    @Test func movesParagraphsThatDoNotFitWhole() throws {
        let many = (1...40).map { paragraph("Akapit numer \($0)") }
        let result = slides(try roundTrip(RichDocument(blocks: [heading("Lista")] + many)))
        #expect(result.count > 1)
        #expect(result.flatMap { $0.dropFirst() } == many)
    }

    @Test func splitsLongTablesAndRepeatsTheHeader() throws {
        var rows = [["Nagłówek", "Wartość"].map(TableCell.init(text:))]
        rows += (1...60).map { ["Wiersz \($0)", "\($0)"].map(TableCell.init(text:)) }
        let result = slides(try roundTrip(RichDocument(blocks: [.table(Table(rows: rows, hasHeaderRow: true))])))
        #expect(result.count > 1)
        var seen: [String] = []
        for slide in result {
            guard case .table(let table)? = slide.first else {
                Issue.record("expected a table")
                return
            }
            #expect(table.rows.first?.first?.plainText == "Nagłówek")
            seen += table.rows.dropFirst().compactMap { $0.first?.plainText }
        }
        #expect(seen == (1...60).map { "Wiersz \($0)" })
    }

    @Test func emptyDocumentStillHasASlide() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("deck.pptx")
        try PPTXFormat.write(RichDocument(), to: url)
        let package = try ZipPackage(url: url, formatName: "PPTX")
        #expect(package.contains("ppt/slides/slide1.xml"))
        #expect(try PPTXFormat.read(url).blocks.isEmpty)
    }

    // MARK: Image decks

    @Test func writeSlidesFollowsTheFirstImage() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("pages.pptx")
        let portrait = ImageAsset(data: try makePNG(width: 300, height: 400), mimeType: "image/png")
        let wide = ImageAsset(data: try makePNG(width: 400, height: 100), mimeType: "image/png")
        try PPTXFormat.writeSlides(images: [portrait, wide], to: url)

        let package = try ZipPackage(url: url, formatName: "PPTX")
        try package.expectWellFormedXML()
        try package.expectConsistentPackage()
        let presentation = try XMLTree.parse(#require(try package.data(forPart: "ppt/presentation.xml")))
        let size = try #require(presentation.first("sldSz"))
        let width = try #require(size.attribute("cx").flatMap(Double.init))
        let height = try #require(size.attribute("cy").flatMap(Double.init))
        #expect(abs(width / height - 0.75) < 0.001)

        let result = slides(try PPTXFormat.read(url))
        #expect(result.count == 2)
        guard case .image(let first)? = result[0].first, case .image(let second)? = result[1].first else {
            Issue.record("expected images")
            return
        }
        // The first fills the slide exactly, the second fits inside it without cropping.
        #expect(abs((first.width ?? 0) * 12700 - width) < 2)
        #expect(abs((first.height ?? 0) * 12700 - height) < 2)
        #expect(abs((second.width ?? 0) * 12700 - width) < 2)
        #expect((second.height ?? 0) * 12700 < height)
    }

    @Test func writeSlidesConvertsUnsupportedFormats() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("pages.pptx")
        // Declared as WebP but holding PNG data: ImageIO decides what it really is.
        let image = ImageAsset(data: try makePNG(width: 10, height: 10), mimeType: "image/webp")
        try PPTXFormat.writeSlides(images: [image], to: url)
        let package = try ZipPackage(url: url, formatName: "PPTX")
        #expect(package.contains("ppt/media/image1.png"))
    }

    @Test func writeSlidesRejectsBadInput() throws {
        let folder = try TemporaryFolder()
        #expect(throws: ConversionError.self) {
            try PPTXFormat.writeSlides(images: [], to: folder.file("a.pptx"))
        }
        #expect(throws: ConversionError.self) {
            try PPTXFormat.writeSlides(images: [ImageAsset(data: Data("nope".utf8), mimeType: "image/png")], to: folder.file("b.pptx"))
        }
    }

    // MARK: Reading what PowerPoint writes

    private func presentationParts(slide: String, layout: String? = nil, master: String? = nil) -> [String: String] {
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(rel)\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        var parts: [String: String] = [
            "_rels/.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>",
            "ppt/presentation.xml": "<p:presentation \(ns)><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/><p:sldId id=\"257\" r:id=\"rId1\"/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"rId2\" Type=\"\(rel)/slide\" Target=\"slides/slide2.xml\"/></Relationships>",
            "ppt/slides/slide1.xml": "<p:sld \(ns)><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Second in the list, shown last</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>",
            "ppt/slides/slide2.xml": "<p:sld \(ns)><p:cSld><p:spTree>\(slide)</p:spTree></p:cSld></p:sld>",
        ]
        if let layout {
            parts["ppt/slides/_rels/slide2.xml.rels"] = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>"
            parts["ppt/slideLayouts/slideLayout1.xml"] = "<p:sldLayout \(ns)><p:cSld><p:spTree>\(layout)</p:spTree></p:cSld></p:sldLayout>"
            if let master {
                parts["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"
                parts["ppt/slideMasters/slideMaster1.xml"] = "<p:sldMaster \(ns)>\(master)</p:sldMaster>"
            }
        }
        return parts
    }

    private func readFixture(_ parts: [String: String]) throws -> RichDocument {
        let folder = try TemporaryFolder()
        let url = folder.file("fixture.pptx")
        try makeZip(at: url, parts: parts)
        return try PPTXFormat.read(url)
    }

    private func shape(ph: String, _ body: String) -> String {
        "<p:sp><p:nvSpPr><p:nvPr>\(ph)</p:nvPr></p:nvSpPr><p:txBody>\(body)</p:txBody></p:sp>"
    }

    @Test func followsPresentationOrderAndSkipsFooters() throws {
        let result = slides(try readFixture(presentationParts(slide:
            shape(ph: "<p:ph type=\"ftr\"/>", "<a:p><a:r><a:t>stopka</a:t></a:r></a:p>")
            + shape(ph: "<p:ph type=\"sldNum\"/>", "<a:p><a:fld><a:t>1</a:t></a:fld></a:p>")
            + shape(ph: "<p:ph type=\"body\" idx=\"1\"/>", "<a:p><a:pPr><a:buNone/></a:pPr><a:r><a:t>treść</a:t></a:r></a:p>")
            + shape(ph: "<p:ph type=\"ctrTitle\"/>", "<a:p><a:r><a:t>Tytuł</a:t></a:r></a:p>")
        )))
        #expect(result.count == 2)
        #expect(result[0] == [heading("Tytuł"), paragraph("treść")])
        #expect(result[1] == [heading("Second in the list, shown last")])
    }

    @Test func inheritsBulletsFromTheMaster() throws {
        let master = "<p:txStyles><p:bodyStyle><a:lvl1pPr><a:buChar char=\"x\"/></a:lvl1pPr><a:lvl2pPr><a:buAutoNum type=\"arabicPeriod\"/></a:lvl2pPr></p:bodyStyle></p:txStyles>"
        let parts = presentationParts(
            slide: shape(ph: "<p:ph idx=\"1\"/>", "<a:p><a:r><a:t>a</a:t></a:r></a:p><a:p><a:pPr lvl=\"1\"/><a:r><a:t>b</a:t></a:r></a:p>"),
            layout: shape(ph: "<p:ph idx=\"1\"/>", "<a:lstStyle/>"),
            master: master)
        let result = slides(try readFixture(parts))
        #expect(result[0] == [.list(ordered: false, items: [[paragraph("a"), .list(ordered: true, items: [[paragraph("b")]])]])])
    }

    @Test func layoutCanTurnBulletsOff() throws {
        let master = "<p:txStyles><p:bodyStyle><a:lvl1pPr><a:buChar char=\"x\"/></a:lvl1pPr></p:bodyStyle></p:txStyles>"
        let parts = presentationParts(
            slide: shape(ph: "<p:ph idx=\"1\"/>", "<a:p><a:r><a:t>a</a:t></a:r></a:p>"),
            layout: shape(ph: "<p:ph idx=\"1\"/>", "<a:lstStyle><a:lvl1pPr><a:buNone/></a:lvl1pPr></a:lstStyle>"),
            master: master)
        #expect(slides(try readFixture(parts))[0] == [paragraph("a")])
    }

    @Test func plainTextBoxesHaveNoBulletsUnlessTheyAskForThem() throws {
        let box = "<p:sp><p:nvSpPr><p:nvPr/></p:nvSpPr><p:txBody><a:p><a:r><a:t>a</a:t></a:r></a:p><a:p><a:pPr><a:buChar char=\"-\"/></a:pPr><a:r><a:t>b</a:t></a:r></a:p></p:txBody></p:sp>"
        #expect(slides(try readFixture(presentationParts(slide: box)))[0] == [
            paragraph("a"), .list(ordered: false, items: [[paragraph("b")]]),
        ])
    }

    @Test func readsGroupsAndSkipsLayoutText() throws {
        let parts = presentationParts(
            slide: "<p:grpSp>" + shape(ph: "", "<a:p><a:r><a:t>w grupie</a:t></a:r></a:p>") + "</p:grpSp>",
            layout: shape(ph: "<p:ph type=\"title\"/>", "<a:p><a:r><a:t>Click to edit</a:t></a:r></a:p>"))
        #expect(slides(try readFixture(parts))[0] == [paragraph("w grupie")])
    }

    // MARK: Hostile input

    @Test func malformedFilesThrow() throws {
        let folder = try TemporaryFolder()
        let garbage = folder.file("garbage.pptx")
        try Data("not a zip at all".utf8).write(to: garbage)
        #expect(throws: ConversionError.self) { try PPTXFormat.read(garbage) }

        let noPresentation = folder.file("none.pptx")
        try makeZip(at: noPresentation, parts: ["a.txt": "a"])
        #expect(throws: ConversionError.self) { try PPTXFormat.read(noPresentation) }

        #expect(throws: ConversionError.self) {
            try readFixture(presentationParts(slide: "<p:sp>"))
        }
    }

    @Test func relationshipCannotLeaveThePackage() {
        #expect(OPC.resolve("../../../etc/passwd", from: "ppt/slides/slide1.xml") == nil)
        #expect(OPC.resolve("../media/a.png", from: "ppt/slides/slide1.xml") == "ppt/media/a.png")
        #expect(OPC.resolve("/ppt/media/a%20b.png", from: "ppt/slides/slide1.xml") == "ppt/media/a b.png")
    }

    // MARK: The only independent reader on this machine

    @Test func quickLookReadsWrittenDeck() async throws {
        let folder = try TemporaryFolder()
        let url = folder.file("deck.pptx")
        let table = Table(rows: [["Imię", "Kwota"].map(TableCell.init(text:)), ["Zażółć", "1234"].map(TableCell.init(text:))], hasHeaderRow: true)
        try PPTXFormat.write(RichDocument(blocks: [
            heading("Pierwszy tytuł"),
            paragraph("Zażółć gęślą jaźń"),
            .list(ordered: false, items: [[paragraph("punkt jeden")], [paragraph("punkt dwa")]]),
            .pageBreak,
            heading("Drugi tytuł"),
            .table(table),
            .image(ImageAsset(data: try makePNG(width: 200, height: 100), mimeType: "image/png")),
        ]), to: url)
        let text = try await quickLookText(of: url)
        for expected in ["Pierwszy tytuł", "Zażółć gęślą jaźń", "punkt dwa", "Drugi tytuł", "Kwota", "1234"] {
            #expect(text.contains(expected), "\(expected) missing from: \(text)")
        }
    }

    @Test func quickLookReadsImageDeck() async throws {
        let folder = try TemporaryFolder()
        let url = folder.file("pages.pptx")
        let image = ImageAsset(data: try makePNG(width: 300, height: 400), mimeType: "image/png")
        try PPTXFormat.writeSlides(images: [image, image], to: url)
        let (rendering, output) = try await SystemPreview.render(url)
        defer { try? FileManager.default.removeItem(at: output) }
        switch rendering {
        case .pdf(let pdf):
            #expect(FileManager.default.fileExists(atPath: pdf.path))
        case .html(let index):
            #expect(FileManager.default.fileExists(atPath: index.path))
        }
    }
}

import ConversionCore
import Foundation
import PDFKit
import Testing
@testable import OfficeFormats

@Suite("System preview")
struct SystemPreviewTests {
    /// A dump folder as `qlmanage` would leave it.
    private func dump(_ files: [String: Data]) throws -> TemporaryFolder {
        let folder = try TemporaryFolder()
        let preview = folder.url.appendingPathComponent("file.xlsx.qlpreview")
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: preview.appendingPathComponent(name))
        }
        return folder
    }

    /// A one page PDF showing `text`.
    private func onePagePDF(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text))
        context.textPosition = CGPoint(x: 10, y: 50)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test func aPresentationIsReadAsSlides() throws {
        let html = """
            <html><head><style type="text/css">div.slide, div.loading-slide { width: 1920; height: 1080;}</style></head>
            <body><div class="slide" style="top:0; left:0;"><p>Slajd</p></div></body></html>
            """
        let folder = try dump(["Preview.html": Data(html.utf8)])
        guard case .slides(_, let size) = try SystemPreview.rendering(in: folder.url) else {
            Issue.record("expected slides")
            return
        }
        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(SystemPreview.slideSize(in: "<body><p>div.slide, div.loading-slide { width: 10; height: 10;}</p></body>") == nil)
    }

    @Test func prefersASinglePDF() throws {
        let folder = try dump([
            "Preview.html": Data("<html><body><img src=\"Attachment1.pdf\"></body></html>".utf8),
            "Attachment1.pdf": onePagePDF("one"),
        ])
        guard case .pdf(let url) = try SystemPreview.rendering(in: folder.url) else {
            Issue.record("expected a PDF")
            return
        }
        #expect(url.lastPathComponent == "Attachment1.pdf")
    }

    @Test func joinsPagesInTheOrderOfTheHTMLNotTheAttachmentNumbers() throws {
        let folder = try dump([
            "Preview.html": Data("<img src=\"Attachment3.pdf\"><img src=\"Attachment1.pdf\"><img src=\"Attachment2.pdf\">".utf8),
            "Attachment1.pdf": onePagePDF("second"),
            "Attachment2.pdf": onePagePDF("third"),
            "Attachment3.pdf": onePagePDF("first"),
        ])
        guard case .pdf(let url) = try SystemPreview.rendering(in: folder.url),
            let document = PDFDocument(url: url)
        else {
            Issue.record("expected a PDF")
            return
        }
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.string?.contains("first") == true)
        #expect(document.page(at: 1)?.string?.contains("second") == true)
        #expect(document.page(at: 2)?.string?.contains("third") == true)
    }

    @Test func followsSheetPagesToTheirPDFs() throws {
        // Numbers: tabs select HTML pages, each wrapping one PDF.
        let folder = try dump([
            "Preview.html": Data("SelectSheet(0, 'Attachment5.html'); SelectSheet(1, 'Attachment2.html');".utf8),
            "Attachment5.html": Data("<img src=\"Attachment9.pdf\">".utf8),
            "Attachment2.html": Data("<img src=\"Attachment1.pdf\">".utf8),
            "Attachment9.pdf": onePagePDF("first"),
            "Attachment1.pdf": onePagePDF("second"),
        ])
        guard case .pdf(let url) = try SystemPreview.rendering(in: folder.url),
            let document = PDFDocument(url: url)
        else {
            Issue.record("expected a PDF")
            return
        }
        #expect(document.page(at: 0)?.string?.contains("first") == true)
        #expect(document.page(at: 1)?.string?.contains("second") == true)
    }

    @Test func stacksWorkbookTabsIntoOnePage() throws {
        let folder = try dump([
            "Preview.html": Data("""
                <body><iframe src="Attachment1.html"></iframe><div class="TabView"><div class="TabViewItem"><div class="TabHeader">Pierwszy</div><a href="Attachment1.html"></a></div>\
                <div class="TabViewItem"><div class="TabHeader">Drugi</div><a href="Attachment2.html"></a></div></div></body>
                """.utf8),
            "Attachment1.html": Data("<html><head><link href=\"a.css\"><style>.s0 {color:red}</style></head><body><table><tr><td class=\"s0\">jeden</td></tr></table></body></html>".utf8),
            "Attachment2.html": Data("<html><head><link href=\"a.css\"><style>.s0 {color:blue}</style></head><body><table><tr><td class=\"s0\">dwa</td></tr></table></body></html>".utf8),
        ])
        guard case .html(let index) = try SystemPreview.rendering(in: folder.url) else {
            Issue.record("expected HTML")
            return
        }
        #expect(index.lastPathComponent == "Document.html")
        let html = try String(contentsOf: index, encoding: .utf8)
        for expected in ["Pierwszy", "Drugi", "jeden", "dwa", "@scope (#sheet0)", "@scope (#sheet1)", "color:red", "color:blue"] {
            #expect(html.contains(expected))
        }
        #expect(html.components(separatedBy: "<link").count == 2, "one shared stylesheet link")
    }

    @Test func aPDFEmbeddedAsAPictureDoesNotReplaceTheDocument() throws {
        // A sheet with a logo: real HTML that happens to show a PDF.
        let folder = try dump([
            "Preview.html": Data("<html><body><table><tr><td>tekst</td></tr></table><img src=\"Attachment2.pdf\"></body></html>".utf8),
            "Attachment2.pdf": onePagePDF("logo"),
        ])
        guard case .html(let index) = try SystemPreview.rendering(in: folder.url) else {
            Issue.record("expected HTML")
            return
        }
        #expect(index.lastPathComponent == "Preview.html")
    }

    @Test func aPictureAloneIsStillSomethingToShow() throws {
        let folder = try dump(["Preview.html": Data("<html><body><img src=\"Attachment1.png\"></body></html>".utf8)])
        guard case .html = try SystemPreview.rendering(in: folder.url) else {
            Issue.record("expected HTML")
            return
        }
    }

    @Test func plainHTMLIsUsedAsIs() throws {
        let folder = try dump(["Preview.html": Data("<html><body><p>tekst</p></body></html>".utf8)])
        guard case .html(let index) = try SystemPreview.rendering(in: folder.url) else {
            Issue.record("expected HTML")
            return
        }
        #expect(index.lastPathComponent == "Preview.html")
    }

    @Test func unusableOutputThrows() throws {
        let empty = try TemporaryFolder()
        #expect(throws: ConversionError.self) { try SystemPreview.rendering(in: empty.url) }
        let blank = try dump(["Preview.html": Data("<html><body>  </body></html>".utf8)])
        #expect(throws: ConversionError.self) { try SystemPreview.rendering(in: blank.url) }
    }

    @Test func missingFileThrows() async {
        await #expect(throws: ConversionError.self) {
            try await SystemPreview.render(URL(fileURLWithPath: "/nonexistent/file.xlsx"))
        }
    }

    @Test func timeoutThrowsAndCleansUp() async throws {
        let folder = try TemporaryFolder()
        let url = folder.file("book.xlsx")
        try XLSXFormat.write(RichDocument(blocks: [.table(Table(rows: [[TableCell(text: "a")]]))]), to: url)
        await #expect(throws: ConversionError("macOS took too long to preview this file.")) {
            try await SystemPreview.render(url, timeout: 0.001)
        }
    }

    @Test func aStuckPreviewGetsASecondChance() async throws {
        var attempts = 0
        let result: String = try await SystemPreview.withSecondChance {
            attempts += 1
            throw SystemPreview.tookTooLong
        } second: {
            attempts += 1
            return "rendered"
        }
        #expect(result == "rendered")
        #expect(attempts == 2)
    }

    @Test func aSecondChanceIsOnlyForTakingTooLong() async {
        var attempts = 0
        await #expect(throws: ConversionError("macOS could not preview this file.")) {
            try await SystemPreview.withSecondChance {
                attempts += 1
                throw ConversionError("macOS could not preview this file.")
            } second: {
                attempts += 1
            }
        }
        #expect(attempts == 1)
    }

    @Test func tookTooLongTwiceIsReported() async {
        await #expect(throws: SystemPreview.tookTooLong) {
            try await SystemPreview.withSecondChance {
                throw SystemPreview.tookTooLong
            } second: {
                throw SystemPreview.tookTooLong
            }
        }
    }

    @Test func rendersAWordDocumentAsHTML() async throws {
        let folder = try TemporaryFolder()
        let url = folder.file("note.docx")
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        try makeZip(at: url, parts: [
            "[Content_Types].xml": """
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
                """,
            "_rels/.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relationships)/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            "word/document.xml": "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>Zażółć gęślą jaźń</w:t></w:r></w:p></w:body></w:document>",
        ])
        let (rendering, output) = try await SystemPreview.render(url)
        defer { try? FileManager.default.removeItem(at: output) }
        guard case .html(let index) = rendering else {
            Issue.record("expected HTML")
            return
        }
        #expect(try htmlText(at: index).contains("Zażółć gęślą jaźń"))
    }

    @Test func rendersARealWorkbookAndTheCallerOwnsTheFolder() async throws {
        let source = try TemporaryFolder()
        let url = source.file("book.xlsx")
        try XLSXFormat.write(RichDocument(blocks: [.table(Table(rows: [[TableCell(text: "Zażółć")]]))]), to: url)
        let (rendering, folder) = try await SystemPreview.render(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard case .html(let index) = rendering else {
            Issue.record("expected HTML")
            return
        }
        #expect(index.path.hasPrefix(folder.path))
        #expect(try htmlText(at: index).contains("Zażółć"))
    }
}

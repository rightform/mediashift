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

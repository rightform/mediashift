import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import ConversionKit
@testable import DocumentEngine
@testable import MediaEngine

private let document = RichDocument(
    title: "Zażółć gęślą jaźń",
    blocks: [
        .heading(level: 1, content: [.text("Zażółć gęślą jaźń")]),
        .paragraph(content: [.text("Body text with "), .text("bold", TextStyle(bold: true)), .text(".")]),
        .list(ordered: false, items: [[.paragraph(content: [.text("First item")])]]),
        .table(ConversionCore.Table(
            rows: [[TableCell(text: "Name"), TableCell(text: "Value")], [TableCell(text: "Łódź"), TableCell(text: "42")]],
            hasHeaderRow: true
        )),
    ]
)

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func size(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
}

private func writeImage(to url: URL, type: UTType = .png) throws {
    let context = try #require(CGContext(
        data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

// MARK: - Catalog

@Test func everyActionNamesWhatHappens() {
    #expect(ConversionAction.convert(.pdf).title == "Convert to PDF")
    #expect(ConversionAction.compress.title == "Compress")
}

@Test func noFormatConvertsToItself() {
    for format in FileFormat.allCases {
        #expect(!ConversionCatalog.targets(for: format).contains(format), "\(format)")
    }
}

@Test func theMainFormatsAreOffered() {
    let documents = ConversionCatalog.targets(for: .docx)
    for expected: FileFormat in [.pdf, .md, .html, .txt, .rtf, .odt, .epub, .pages, .pptx] {
        #expect(documents.contains(expected))
    }
    #expect(ConversionCatalog.targets(for: .pptx).contains(.pdf))
    #expect(ConversionCatalog.targets(for: .xlsx).contains(.csv))
    #expect(ConversionCatalog.targets(for: .csv).contains(.xlsx))
    #expect(ConversionCatalog.targets(for: .pdf).contains(.pptx))
    #expect(ConversionCatalog.targets(for: .jpeg).contains(.webp))
    #expect(ConversionCatalog.targets(for: .mp4).contains(.webm))
    #expect(ConversionCatalog.targets(for: .wav).contains(.mp3))
}

@Test func mixedDropsOfferWhatTheyHaveInCommon() {
    let mixed = [URL(fileURLWithPath: "/a.jpg"), URL(fileURLWithPath: "/b.png")]
    let actions = ConversionCatalog.actions(for: mixed)
    // Both can become WebP, and a target one of them already is still counts.
    #expect(actions.contains(.convert(.webp)))
    #expect(actions.contains(.convert(.png)))
    #expect(actions.contains(.convert(.jpeg)))
    #expect(ConversionCatalog.applicableInputs(mixed, for: .convert(.png)).map(\.lastPathComponent) == ["a.jpg"])

    let unrelated = [URL(fileURLWithPath: "/a.jpg"), URL(fileURLWithPath: "/b.mp3")]
    #expect(ConversionCatalog.actions(for: unrelated).allSatisfy { action in
        if case .convert = action { false } else { true }
    })
    #expect(ConversionCatalog.actions(for: [URL(fileURLWithPath: "/a.jpg"), URL(fileURLWithPath: "/b.exe")]).isEmpty)
}

@Test func unsupportedFilesAreRefusedWithAClearMessage() async throws {
    await #expect(throws: ConversionError.self) {
        try await Converter.run(.convert(.pdf), on: URL(fileURLWithPath: "/tmp/file.exe"))
    }
    await #expect(throws: ConversionError.self) {
        try await Converter.run(.convert(.mp4), on: URL(fileURLWithPath: "/tmp/file.docx"))
    }
}

// MARK: - End to end

/// Every document format a person can start from, into every target the catalog promises.
@MainActor
@Test func everyDocumentRouteProducesAFile() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    var sources: [URL] = []
    for format: FileFormat in [.txt, .md, .html, .rtf, .docx, .odt, .epub, .pages, .xlsx, .csv, .tsv, .pptx] {
        let url = folder.appendingPathComponent("source-\(format.rawValue).\(format.fileExtension)")
        try Converter.writeDocument(document, to: url, format: format)
        sources.append(url)
    }
    let pdf = folder.appendingPathComponent("source-pdf.pdf")
    try await WebPDFRenderer.render(html: HTMLWriter.render(document), to: pdf)
    sources.append(pdf)

    let output = folder.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let options = ConversionOptions(outputDirectory: output)

    var routes = 0
    for source in sources {
        let format = try #require(FileFormat(url: source))
        for target in ConversionCatalog.targets(for: format) {
            do {
                let result = try await Converter.run(.convert(target), on: source, options: options)
                #expect(FileManager.default.fileExists(atPath: result.output.path), "\(format) to \(target)")
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: result.output.path, isDirectory: &isFolder)
                if !isFolder.boolValue { #expect(size(result.output) > 0, "\(format) to \(target)") }
                routes += 1
            } catch {
                Issue.record("\(format) to \(target): \(error.localizedDescription)")
            }
        }
    }
    #expect(routes > 80)
    print("document routes checked: \(routes)")
}

/// The text must survive the trip, not only a file appear.
@MainActor
@Test(arguments: [FileFormat.docx, .odt, .rtf, .html, .md, .epub, .pages, .xlsx, .pptx])
func textSurvivesConversionToPDF(source format: FileFormat) async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.\(format.fileExtension)")
    try Converter.writeDocument(document, to: source, format: format)
    let result = try await Converter.run(.convert(.pdf), on: source)
    let text = try #require(PDFDocument(url: result.output)).string ?? ""
    #expect(text.contains("Łódź"), "\(format)")
}

@Test func imagesConvertAndCompress() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("photo.png")
    try writeImage(to: source)
    for target in ConversionCatalog.targets(for: .png) where target != .txt && (target != .webp || FFmpegLocator.find() != nil) {
        let result = try await Converter.run(.convert(target), on: source)
        #expect(size(result.output) > 0, "\(target)")
    }
    let compressed = try await Converter.run(.compress, on: source)
    #expect(compressed.output.lastPathComponent == "photo-compressed.png")
    let clean = try await Converter.run(.stripMetadata, on: source)
    #expect(clean.output.lastPathComponent == "photo-clean.png")
}

@Test func originalsAreNeverTouched() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("note.md")
    try Data("# Title\n\nBody".utf8).write(to: source)
    let before = try Data(contentsOf: source)
    let first = try await Converter.run(.convert(.html), on: source)
    let second = try await Converter.run(.convert(.html), on: source)
    #expect(first.output.lastPathComponent == "note.html")
    #expect(second.output.lastPathComponent == "note-2.html")
    #expect(try Data(contentsOf: source) == before)
}

@Test func aFailedConversionLeavesNothingBehind() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("broken.docx")
    try Data("this is not a word file".utf8).write(to: source)
    await #expect(throws: (any Error).self) {
        try await Converter.run(.convert(.md), on: source)
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "broken.docx" }
    #expect(leftovers.isEmpty)
}

// MARK: - Settings reach the result

@Test func aSuffixReachesEveryKindOfName() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let note = folder.appendingPathComponent("note.md")
    try Data("# Title\n\nText.".utf8).write(to: note)
    let photo = folder.appendingPathComponent("photo.png")
    try writeImage(to: photo)

    let options = ConversionOptions(convertedSuffix: "web", compressedSuffix: "small", cleanedSuffix: "private")

    let converted = try await Converter.run(.convert(.html), on: note, options: options)
    #expect(converted.output.lastPathComponent == "note-web.html")
    let compressed = try await Converter.run(.compress, on: photo, options: options)
    #expect(compressed.output.lastPathComponent == "photo-small.png")
    let cleaned = try await Converter.run(.stripMetadata, on: photo, options: options)
    #expect(cleaned.output.lastPathComponent == "photo-private.png")
}

@Test func imageSizeAndQualityReachTheFile() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    // Noise, because a flat colour compresses to nearly nothing at any quality.
    let side = 256
    let context = try #require(CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    var state: UInt64 = 88172645463325252
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    for offset in 0..<context.bytesPerRow * side {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        bytes[offset] = offset % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state)
    }
    let photo = folder.appendingPathComponent("noise.png")
    let destination = try #require(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    let low = try await Converter.run(.convert(.jpeg), on: photo, options: ConversionOptions(convertedSuffix: "low", imageQuality: 0.3))
    let high = try await Converter.run(.convert(.jpeg), on: photo, options: ConversionOptions(convertedSuffix: "high", imageQuality: 1))
    #expect(size(high.output) > size(low.output) * 2)

    let small = try await Converter.run(.convert(.jpeg), on: photo, options: ConversionOptions(convertedSuffix: "small", imageMaxPixelSize: 100))
    let source = try #require(CGImageSourceCreateWithURL(small.output as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 100)
}

@Test @MainActor func paperSizeReachesThePDF() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let note = folder.appendingPathComponent("note.md")
    try Data("# Title\n\nText.".utf8).write(to: note)

    let a4 = try await Converter.run(.convert(.pdf), on: note, options: ConversionOptions(convertedSuffix: "a4"))
    let letter = try await Converter.run(.convert(.pdf), on: note, options: ConversionOptions(convertedSuffix: "letter", paperSize: .letter))

    let a4Box = try #require(PDFDocument(url: a4.output)?.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(a4Box.width - 595) < 2 && abs(a4Box.height - 842) < 2)
    let letterBox = try #require(PDFDocument(url: letter.output)?.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(letterBox.width - 612) < 2 && abs(letterBox.height - 792) < 2)
}

@Test @MainActor func pageResolutionReachesTheImages() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let note = folder.appendingPathComponent("note.md")
    try Data("# Title\n\nText.".utf8).write(to: note)
    let pdf = try await Converter.run(.convert(.pdf), on: note).output

    let low = try await Converter.run(.convert(.png), on: pdf, options: ConversionOptions(convertedSuffix: "low", pageImageDPI: 72))
    let high = try await Converter.run(.convert(.png), on: pdf, options: ConversionOptions(convertedSuffix: "high", pageImageDPI: 300))

    func width(_ url: URL) throws -> Int {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    }
    // A4 is 8.27 inches wide.
    #expect(abs(try width(low.output) - 595) < 3)
    #expect(abs(try width(high.output) - 2480) < 6)
}

@Test @MainActor func removingMetadataReachesDocumentsAndTheirPDFs() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("signed.docx")
    try DOCXWriter.write(RichDocument(title: "Secret Title", author: "Secret Author", blocks: [.paragraph(content: [.text("Body")])]), to: source)

    let keptDoc = try await Converter.run(.convert(.html), on: source, options: ConversionOptions(convertedSuffix: "kept"))
    #expect(try String(contentsOf: keptDoc.output, encoding: .utf8).contains("Secret Author"))

    let clean = ConversionOptions(removesMetadata: true, convertedSuffix: "clean")
    let cleanDoc = try await Converter.run(.convert(.html), on: source, options: clean)
    let html = try String(contentsOf: cleanDoc.output, encoding: .utf8)
    #expect(!html.contains("Secret Author"))
    #expect(!html.contains("Secret Title"))

    let cleanPDF = try await Converter.run(.convert(.pdf), on: source, options: clean)
    let attributes = try #require(PDFDocument(url: cleanPDF.output)).documentAttributes ?? [:]
    for key in [PDFDocumentAttribute.authorAttribute, .titleAttribute] {
        #expect(((attributes[key] as? String) ?? "").isEmpty)
    }
    #expect(try Data(contentsOf: cleanPDF.output).range(of: Data("Secret".utf8)) == nil)
}

@Test @MainActor func scansCanBeSkipped() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let photo = folder.appendingPathComponent("page.png")
    try writeImage(to: photo)
    // An image-only PDF, like a scan, with no text layer to read.
    let scan = try await Converter.run(.convert(.pdf), on: photo).output

    await #expect(throws: ConversionError("No text was found in this PDF.")) {
        try await Converter.run(.convert(.txt), on: scan, options: ConversionOptions(recognizesScans: false))
    }
}

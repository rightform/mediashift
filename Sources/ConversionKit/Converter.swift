import ConversionCore
import DocumentEngine
import Foundation
import ImageIO
import MediaEngine
import OfficeFormats

public struct ConversionOptions: Sendable {
    public var compressionLevel: CompressionLevel
    /// Upper limit for a compressed file. Nil means the level decides.
    public var targetBytes: Int64?
    /// Removes metadata during conversion, where the target format would otherwise keep it.
    public var removesMetadata: Bool
    /// Where results go. Nil means next to the original.
    public var outputDirectory: URL?
    /// Added to the name of a converted file, as in `report-suffix.pdf`. Nil adds nothing.
    public var convertedSuffix: String?
    public var compressedSuffix: String
    public var cleanedSuffix: String
    /// 0 to 1, for formats with a quality dial. Nil lets each format use its own good default.
    public var imageQuality: Double?
    /// The longest edge of a converted image in pixels. Nil keeps the size.
    public var imageMaxPixelSize: Int?
    public var media: MediaOptions
    /// The page used when a document is laid out here. Office and iWork files keep their own.
    public var paperSize: PaperSize
    /// The resolution of pages turned into images.
    public var pageImageDPI: Double
    /// Reads scanned PDF pages with on-device text recognition.
    public var recognizesScans: Bool

    public init(
        compressionLevel: CompressionLevel = .balanced,
        targetBytes: Int64? = nil,
        removesMetadata: Bool = false,
        outputDirectory: URL? = nil,
        convertedSuffix: String? = nil,
        compressedSuffix: String = "compressed",
        cleanedSuffix: String = "clean",
        imageQuality: Double? = nil,
        imageMaxPixelSize: Int? = nil,
        media: MediaOptions = MediaOptions(),
        paperSize: PaperSize = .a4,
        pageImageDPI: Double = 200,
        recognizesScans: Bool = true
    ) {
        self.compressionLevel = compressionLevel
        self.targetBytes = targetBytes
        self.removesMetadata = removesMetadata
        self.outputDirectory = outputDirectory
        self.convertedSuffix = convertedSuffix
        self.compressedSuffix = compressedSuffix
        self.cleanedSuffix = cleanedSuffix
        self.imageQuality = imageQuality
        self.imageMaxPixelSize = imageMaxPixelSize
        self.media = media
        self.paperSize = paperSize
        self.pageImageDPI = pageImageDPI
        self.recognizesScans = recognizesScans
    }
}

public struct ConversionResult: Sendable {
    /// What to show in Finder: one file, or a folder when a result is several files.
    public let output: URL
    /// Something the person should know, such as a file that could not be made smaller.
    public let note: String?

    public init(output: URL, note: String? = nil) {
        self.output = output
        self.note = note
    }
}

/// The single entry point for all conversion. Picks the engine and never touches the original.
public enum Converter {
    public static func run(
        _ action: ConversionAction,
        on input: URL,
        options: ConversionOptions = ConversionOptions(),
        progress: ProgressHandler? = nil
    ) async throws -> ConversionResult {
        guard let format = FileFormat(url: input) else {
            throw ConversionError("\(input.pathExtension.uppercased()) files are not supported.")
        }
        guard ConversionCatalog.actions(for: format).contains(action) else {
            throw ConversionError("\(action.title) is not available for \(format.label) files.")
        }
        switch action {
        case .convert(let target):
            return try await convert(input, from: format, to: target, options: options, progress: progress)
        case .compress:
            return try await compress(input, format: format, options: options, progress: progress)
        case .stripMetadata:
            return try await stripMetadata(input, format: format, options: options, progress: progress)
        }
    }

    // MARK: - Convert

    private static func convert(
        _ input: URL,
        from source: FileFormat,
        to target: FileFormat,
        options: ConversionOptions,
        progress: ProgressHandler?
    ) async throws -> ConversionResult {
        let output = OutputNaming.outputURL(for: input, format: target, suffix: options.convertedSuffix, directory: options.outputDirectory)

        // Removes the partial file when any step below fails or the job is cancelled.
        func producing(_ work: () async throws -> Void) async throws -> ConversionResult {
            do {
                try await work()
                progress?(1)
                return ConversionResult(output: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }

        switch source.kind {
        case .video, .audio:
            var media = options.media
            media.removesMetadata = options.removesMetadata
            return try await producing { [media] in
                try await MediaConverter.convert(input, to: output, format: target, options: media, progress: progress)
            }
        case .image:
            return try await producing {
                switch target {
                case .pdf:
                    try await ImageConverter.makePDF(from: [input], to: output)
                case .pptx:
                    try PPTXFormat.writeSlides(images: [try imageAsset(from: input)], to: output)
                case .txt:
                    try await recognizeText(in: input, to: output)
                default:
                    let imageOptions = ImageOptions(
                        quality: options.imageQuality,
                        maxPixelSize: options.imageMaxPixelSize,
                        keepsMetadata: !options.removesMetadata
                    )
                    try await ImageConverter.convert(input, to: output, format: target, options: imageOptions)
                }
            }
        case .document, .spreadsheet, .presentation:
            break
        }

        switch target {
        case .pdf:
            return try await producing {
                try await makePDF(from: input, format: source, to: output, options: options)
                if options.removesMetadata { try stripPDF(output) }
            }
        case .png, .jpeg:
            return try await pageImages(from: input, format: source, target: target, options: options, progress: progress)
        case .pptx where source == .pdf:
            return try await producing {
                try PPTXFormat.writeSlides(images: try PDFTools.pageImages(of: input, dpi: options.pageImageDPI), to: output)
            }
        default:
            return try await producing {
                let document = try await readDocument(input, format: source, options: options, progress: progress)
                try writeDocument(document, to: output, format: target)
            }
        }
    }

    /// Takes the descriptive fields off a PDF that has just been written.
    private static func stripPDF(_ url: URL) throws {
        let stripped = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stripped) }
        try PDFTools.stripMetadata(url, to: stripped)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: stripped)
    }

    // MARK: - Compress and metadata

    private static func compress(
        _ input: URL,
        format: FileFormat,
        options: ConversionOptions,
        progress: ProgressHandler?
    ) async throws -> ConversionResult {
        let output = OutputNaming.copyURL(for: input, suffix: options.compressedSuffix, directory: options.outputDirectory)
        let keptOriginalNote = "This file could not be made smaller, so the copy is identical."
        do {
            switch format.kind {
            case .image:
                let smaller = try await ImageConverter.compress(input, to: output, level: options.compressionLevel, targetBytes: options.targetBytes)
                progress?(1)
                return ConversionResult(output: output, note: smaller ? nil : keptOriginalNote)
            case .video, .audio:
                try await MediaConverter.compress(input, to: output, level: options.compressionLevel, targetBytes: options.targetBytes, options: options.media, progress: progress)
                progress?(1)
                return ConversionResult(output: output)
            default:
                let smaller = try PDFTools.compress(input, to: output, level: options.compressionLevel)
                progress?(1)
                return ConversionResult(output: output, note: smaller ? nil : keptOriginalNote)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func stripMetadata(
        _ input: URL,
        format: FileFormat,
        options: ConversionOptions,
        progress: ProgressHandler?
    ) async throws -> ConversionResult {
        let output = OutputNaming.copyURL(for: input, suffix: options.cleanedSuffix, directory: options.outputDirectory)
        do {
            switch format.kind {
            case .image:
                try await ImageConverter.stripMetadata(input, to: output)
            case .video, .audio:
                try await MediaConverter.stripMetadata(input, to: output, progress: progress)
            default:
                if format == .pdf {
                    try PDFTools.stripMetadata(input, to: output)
                } else {
                    try OOXMLMetadata.strip(input, to: output)
                }
            }
            progress?(1)
            return ConversionResult(output: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: - Documents

    /// Everything a document can become goes through `RichDocument`.
    static func readDocument(
        _ url: URL,
        format: FileFormat,
        options: ConversionOptions = ConversionOptions(),
        progress: ProgressHandler? = nil
    ) async throws -> RichDocument {
        var document = try await readSource(url, format: format, options: options, progress: progress)
        if options.removesMetadata {
            document.title = nil
            document.author = nil
        }
        return document
    }

    private static func readSource(
        _ url: URL,
        format: FileFormat,
        options: ConversionOptions,
        progress: ProgressHandler?
    ) async throws -> RichDocument {
        switch format {
        case .txt: return try PlainTextReader.read(url)
        case .md: return try MarkdownReader.read(url)
        case .html: return try HTMLReader.read(url)
        case .docx: return try DOCXReader.read(url)
        case .rtf, .doc, .odt: return try AttributedTextReader.read(url, format: format)
        case .epub: return try EPUBReader.read(url)
        case .pdf: return try await PDFTextReader.read(url, recognizesScans: options.recognizesScans, progress: progress)
        case .xlsx: return try XLSXFormat.read(url)
        case .csv: return try CSVFormat.read(url)
        case .tsv: return try CSVFormat.read(url, delimiter: "\t")
        case .pptx: return try PPTXFormat.read(url)
        case .pages: return try PagesFormat.read(url)
        case .numbers, .key:
            // No public parser for these. The system renders them, and the text is read from that.
            let (rendering, folder) = try await SystemPreview.render(url)
            defer { try? FileManager.default.removeItem(at: folder) }
            let pdf = try await pdf(from: rendering, in: folder, paper: options.paperSize)
            return try await PDFTextReader.read(pdf, recognizesScans: options.recognizesScans, progress: progress)
        default:
            throw ConversionError("\(format.label) files cannot be read as documents.")
        }
    }

    static func writeDocument(_ document: RichDocument, to url: URL, format: FileFormat) throws {
        switch format {
        case .txt: try PlainTextWriter.write(document, to: url)
        case .md: try MarkdownWriter.write(document, to: url)
        case .html: try HTMLWriter.write(document, to: url)
        case .docx: try DOCXWriter.write(document, to: url)
        case .rtf, .odt: try AttributedTextWriter.write(document, to: url, format: format)
        case .epub: try EPUBWriter.write(document, to: url)
        case .xlsx: try XLSXFormat.write(document, to: url)
        case .csv: try CSVFormat.write(document, to: url)
        case .tsv: try CSVFormat.write(document, to: url, delimiter: "\t")
        case .pptx: try PPTXFormat.write(document, to: url)
        case .pages: try PagesFormat.write(document, to: url)
        default: throw ConversionError("\(format.label) files cannot be written from a document.")
        }
    }

    /// Office and iWork files look best through the system's own renderer, which knows their
    /// fonts and layout. The shared document model is the fallback when it declines a file.
    private static func makePDF(from input: URL, format: FileFormat, to output: URL, options: ConversionOptions) async throws {
        if [.docx, .doc, .xlsx, .pptx, .pages, .numbers, .key].contains(format) {
            do {
                let (rendering, folder) = try await SystemPreview.render(input)
                defer { try? FileManager.default.removeItem(at: folder) }
                let pdf = try await pdf(from: rendering, in: folder, paper: options.paperSize)
                try FileManager.default.copyItem(at: pdf, to: output)
                return
            } catch let error as CancellationError {
                throw error
            } catch {
                if format == .numbers || format == .key { throw error }
            }
        }
        let document = try await readDocument(input, format: format, options: options)
        try await WebPDFRenderer.render(html: HTMLWriter.render(document), paper: options.paperSize, to: output)
    }

    private static func pdf(from rendering: SystemPreview.Rendering, in folder: URL, paper: PaperSize) async throws -> URL {
        switch rendering {
        case .pdf(let url):
            return url
        case .html(let index):
            let url = folder.appendingPathComponent("rendered.pdf")
            try await WebPDFRenderer.render(file: index, paper: paper, to: url)
            return url
        }
    }

    /// Pages as images: one file for a single page, otherwise a folder.
    private static func pageImages(
        from input: URL,
        format source: FileFormat,
        target: FileFormat,
        options: ConversionOptions,
        progress: ProgressHandler?
    ) async throws -> ConversionResult {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        var pdf = input
        if source != .pdf {
            pdf = scratch.appendingPathComponent("source.pdf")
            try await makePDF(from: input, format: source, to: pdf, options: options)
        }

        let base = input.deletingPathExtension().lastPathComponent
        if try PDFTools.pageCount(of: pdf) == 1 {
            let output = OutputNaming.outputURL(for: input, format: target, suffix: options.convertedSuffix, directory: options.outputDirectory)
            let rendered = try PDFTools.renderPages(of: pdf, into: scratch, baseName: "page", format: target, dpi: options.pageImageDPI)
            guard let page = rendered.first else { throw ConversionError("This document has no pages.") }
            try manager.moveItem(at: page, to: output)
            progress?(1)
            return ConversionResult(output: output)
        }
        let folder = OutputNaming.outputFolder(for: input, suffix: options.convertedSuffix, directory: options.outputDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try PDFTools.renderPages(of: pdf, into: folder, baseName: base, format: target, dpi: options.pageImageDPI, progress: progress)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        return ConversionResult(output: folder)
    }

    // MARK: - Images

    private static func imageAsset(from url: URL) throws -> ImageAsset {
        let data = try Data(contentsOf: url)
        let mime: String
        switch FileFormat(url: url) {
        case .png: mime = "image/png"
        case .jpeg: mime = "image/jpeg"
        case .gif: mime = "image/gif"
        default:
            // Slides hold only the formats Office can draw, so anything else travels as PNG.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ConversionError("This image could not be read.") }
            let converted = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(converted, "public.png" as CFString, 1, nil) else {
                throw ConversionError("This image could not be read.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError("This image could not be read.") }
            return ImageAsset(data: converted as Data, mimeType: "image/png")
        }
        return ImageAsset(data: data, mimeType: mime)
    }

    private static func recognizeText(in url: URL, to output: URL) async throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ConversionError("This image could not be read.") }
        let lines = try await OnDeviceOCR.recognize(image)
        if lines.isEmpty { throw ConversionError("No text was found in this image.") }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: output, options: .atomic)
    }
}

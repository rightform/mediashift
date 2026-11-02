import AppKit
import ConversionCore
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum PDFTools {
    /// Renders each page to an image file named after the output. Returns the files written, in page order.
    @discardableResult
    public static func renderPages(
        of input: URL,
        into folder: URL,
        baseName: String,
        format: FileFormat,
        dpi: Double = 200,
        progress: ProgressHandler? = nil
    ) throws -> [URL] {
        let pdf = try open(input)
        guard format == .png || format == .jpeg else {
            throw ConversionError("Pages can only be exported as PNG or JPEG.")
        }
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        let digits = String(pdf.pageCount).count
        var results: [URL] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index), let image = render(page, dpi: dpi) else { continue }
            let number = String(format: "%0\(digits)d", index + 1)
            let name = pdf.pageCount == 1 ? baseName : "\(baseName)-\(number)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
                throw ConversionError("The image could not be written.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError("The image could not be written.")
            }
            results.append(url)
            progress?(Double(index + 1) / Double(pdf.pageCount))
        }
        return results
    }

    /// Renders every page into memory, for formats that embed the pictures themselves.
    public static func pageImages(of input: URL, dpi: Double = 200) throws -> [ImageAsset] {
        let pdf = try open(input)
        var images: [ImageAsset] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index), let image = render(page, dpi: dpi) else { continue }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            let bounds = page.bounds(for: .cropBox)
            images.append(ImageAsset(data: data as Data, mimeType: "image/jpeg", width: bounds.width, height: bounds.height))
        }
        return images
    }

    public static func pageCount(of input: URL) throws -> Int {
        try open(input).pageCount
    }

    /// Re-saves with images recompressed. Keeps the original when that would not make it smaller.
    /// Returns false when the source was kept.
    @discardableResult
    public static func compress(_ input: URL, to output: URL, level: CompressionLevel) throws -> Bool {
        let pdf = try open(input)
        var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if level != .light { options[.optimizeImagesForScreenOption] = true }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard pdf.write(to: temporary, withOptions: options) else {
            throw ConversionError("This PDF could not be compressed.")
        }
        let before = fileSize(input)
        let after = fileSize(temporary)
        if after > 0, after < before {
            try FileManager.default.moveItem(at: temporary, to: output)
            return true
        }
        try FileManager.default.copyItem(at: input, to: output)
        return false
    }

    /// Redraws every page into a new document, which leaves no info dictionary or XMP
    /// packet behind. Links and form fields do not survive; the visible page does.
    public static func stripMetadata(_ input: URL, to output: URL) throws {
        guard let source = CGPDFDocument(input as CFURL) else {
            throw ConversionError("This PDF could not be opened. It may be damaged.")
        }
        if source.isEncrypted, !source.isUnlocked {
            throw ConversionError("This PDF is password protected.")
        }
        let info: [CFString: Any] = [kCGPDFContextCreator: "", kCGPDFContextAuthor: "", kCGPDFContextTitle: ""]
        guard let context = CGContext(output as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ConversionError("The PDF could not be written.")
        }
        for number in 1...max(1, source.numberOfPages) {
            guard let page = source.page(at: number) else { continue }
            var box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            if rotated { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
            context.beginPage(mediaBox: &box)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.endPage()
        }
        context.closePDF()
    }

    /// Drops empty pages from the end. The first page always stays.
    static func removeTrailingBlankPages(of url: URL) throws {
        guard let document = PDFDocument(url: url), document.pageCount > 1 else { return }
        var removed = false
        while document.pageCount > 1, let last = document.page(at: document.pageCount - 1), isBlank(last) {
            document.removePage(at: document.pageCount - 1)
            removed = true
        }
        if removed, !document.write(to: url) {
            throw ConversionError("The PDF could not be created.")
        }
    }

    /// No text, and nothing drawn: every pixel of a small rendering is white.
    static func isBlank(_ page: PDFPage) -> Bool {
        guard (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let image = render(page, dpi: 18),
            let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return false }
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            for offset in stride(from: start, to: start + image.width * 4, by: 4)
            where bytes[offset] < 250 || bytes[offset + 1] < 250 || bytes[offset + 2] < 250 {
                return false
            }
        }
        return true
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw ConversionError("This PDF could not be opened. It may be damaged.")
        }
        if pdf.isLocked {
            throw ConversionError("This PDF is password protected.")
        }
        return pdf
    }

    private static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        var scale = dpi / 72
        // Very large pages would otherwise need gigabytes of memory.
        scale = min(scale, 12000 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }
}

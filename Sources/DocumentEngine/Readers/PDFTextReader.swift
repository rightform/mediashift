import ConversionCore
import Foundation
import PDFKit
import Vision

public enum PDFTextReader {
    /// Reads text pages directly and falls back to on-device OCR for scanned pages.
    public static func read(_ url: URL, progress: ProgressHandler? = nil) async throws -> RichDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw ConversionError("This PDF could not be opened. It may be damaged.")
        }
        if pdf.isLocked {
            throw ConversionError("This PDF is password protected.")
        }
        var document = RichDocument()
        let attributes = pdf.documentAttributes
        document.title = (attributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmed.nilIfEmpty
        document.author = (attributes?[PDFDocumentAttribute.authorAttribute] as? String)?.trimmed.nilIfEmpty

        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            var blocks = blocks(from: page)
            if blocks.isEmpty, let lines = try? await recognizeText(on: page), !lines.isEmpty {
                blocks = paragraphs(from: lines.map { Line(text: $0, fontSize: 12) }, bodySize: 12)
            }
            if !blocks.isEmpty {
                if !document.blocks.isEmpty { document.blocks.append(.pageBreak) }
                document.blocks += blocks
            }
            progress?(Double(index + 1) / Double(pdf.pageCount))
        }
        if document.blocks.isEmpty {
            throw ConversionError("No text was found in this PDF.")
        }
        return document
    }

    private struct Line {
        let text: String
        let fontSize: CGFloat
    }

    private static func blocks(from page: PDFPage) -> [Block] {
        guard let text = page.attributedString, text.length > 0 else {
            return page.string.map { paragraphs(from: $0.components(separatedBy: .newlines).map { Line(text: $0, fontSize: 12) }, bodySize: 12) } ?? []
        }
        var lines: [Line] = []
        var sizes: [CGFloat: Int] = [:]
        (text.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: .byLines
        ) { line, range, _, _ in
            guard let line, range.length > 0 else {
                lines.append(Line(text: "", fontSize: 0))
                return
            }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let size = font?.pointSize ?? 12
            sizes[size, default: 0] += range.length
            lines.append(Line(text: line, fontSize: size))
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        return paragraphs(from: lines, bodySize: body)
    }

    /// PDF stores lines, not paragraphs. Joins lines back together and undoes end-of-line hyphenation.
    private static func paragraphs(from lines: [Line], bodySize: CGFloat) -> [Block] {
        var blocks: [Block] = []
        var current = ""

        func flush() {
            let text = current.trimmed
            if !text.isEmpty { blocks.append(.paragraph(content: [.text(text)])) }
            current = ""
        }

        for line in lines {
            let text = line.text.trimmed
            if text.isEmpty {
                flush()
                continue
            }
            let ratio = line.fontSize / bodySize
            if ratio >= 1.15, text.count < 160 {
                flush()
                blocks.append(.heading(level: ratio >= 1.7 ? 1 : ratio >= 1.35 ? 2 : 3, content: [.text(text)]))
                continue
            }
            if current.isEmpty {
                current = text
            } else if current.hasSuffix("-"), let first = text.first, first.isLowercase {
                current.removeLast()
                current += text
            } else if let last = current.last, ".!?:".contains(last), let first = text.first, first.isUppercase {
                flush()
                current = text
            } else {
                current += " " + text
            }
        }
        flush()
        return blocks
    }

    private static func recognizeText(on page: PDFPage) async throws -> [String] {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(3000 / max(bounds.width, bounds.height), 3)
        let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return try await OnDeviceOCR.recognize(image)
    }
}

/// Text recognition that runs entirely on this Mac.
public enum OnDeviceOCR {
    public static func recognize(_ image: CGImage) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }
}

import ConversionCore
import Foundation
import PDFKit
import Testing
@testable import OfficeFormats

/// A temporary folder removed when the test ends.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("OfficeFormatsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

extension ZipPackage {
    /// Every part parses as XML, the way a strict Office reader would require.
    func expectWellFormedXML() throws {
        for name in partNames where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            let data = try #require(try data(forPart: name))
            _ = try XMLTree.parse(data)
        }
    }

    /// Every part has a content type and every internal relationship has a target.
    func expectConsistentPackage() throws {
        let types = try XMLTree.parse(#require(try data(forPart: "[Content_Types].xml")))
        let defaults = Set(types.all("Default").compactMap { $0.attribute("Extension")?.lowercased() })
        let overrides = Set(types.all("Override").compactMap { $0.attribute("PartName") })
        for name in partNames where name != "[Content_Types].xml" {
            let suffix = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
            #expect(defaults.contains(suffix) || overrides.contains("/" + name), "no content type for \(name)")
        }
        for override in overrides {
            #expect(partNames.contains(String(override.dropFirst())), "content type for missing part \(override)")
        }
        for name in partNames where name.hasSuffix(".rels") {
            let source = Self.sourcePart(ofRelationships: name)
            for relationship in try OPC.relationships(of: source, in: self) where !relationship.isExternal {
                let target = OPC.resolve(relationship.target, from: source)
                #expect(target.map(partNames.contains) == true, "\(name) points at missing \(relationship.target)")
            }
        }
    }

    private static func sourcePart(ofRelationships name: String) -> String? {
        if name == "_rels/.rels" { return nil }
        let path = name.replacingOccurrences(of: "_rels/", with: "")
        return String(path.dropLast(".rels".count))
    }
}

/// What Quick Look, the only independent reader on this machine, gets out of a file.
func quickLookText(of url: URL) async throws -> String {
    let (rendering, folder) = try await SystemPreview.render(url)
    defer { try? FileManager.default.removeItem(at: folder) }
    switch rendering {
    case .pdf(let pdf):
        return pdfText(pdf)
    case .html(let index):
        return try htmlText(at: index)
    }
}

func pdfText(_ url: URL) -> String {
    guard let document = PDFDocument(url: url) else { return "" }
    return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
}

/// HTML with entities decoded, so assertions can use the text as a person would read it.
func htmlText(at url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
    ]
    if let string = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
        return string.string
    }
    return String(decoding: data, as: UTF8.self)
}

/// Builds a ZIP from named parts, for fixtures written by hand.
func makeZip(at url: URL, parts: [String: String]) throws {
    try ZipWriter.write(parts.map { ZipWriter.Part($0.key, $0.value) }, to: url)
}

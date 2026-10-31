import ConversionCore
import Foundation

public enum EPUBReader {
    public static func read(_ url: URL) throws -> RichDocument {
        let package = try ZipReader(url: url, formatName: "EPUB")
        guard let container = package.xml(at: "META-INF/container.xml")?.rootElement(),
            let opfPath = container.descendant("rootfile")?.value(of: "full-path"),
            let opf = package.xml(at: opfPath)?.rootElement(),
            let manifest = opf.child("manifest"),
            let spine = opf.child("spine")
        else {
            throw ConversionError("This EPUB file has no readable table of contents.")
        }

        var items: [String: String] = [:]
        for item in manifest.children(named: "item") {
            if let id = item.value(of: "id"), let href = item.value(of: "href") { items[id] = href }
        }

        // Chapters and the images they use are unpacked to a temporary folder
        // so relative image paths resolve the same way they do inside the book.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for path in package.paths where isSafe(path) && isImage(path) {
            let target = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? package.data(at: path)?.write(to: target)
        }

        var document = RichDocument()
        let metadata = opf.child("metadata")
        document.title = metadata?.child("title")?.stringValue?.trimmed.nilIfEmpty
        document.author = metadata?.child("creator")?.stringValue?.trimmed.nilIfEmpty

        for reference in spine.children(named: "itemref") {
            guard let id = reference.value(of: "idref"), let href = items[id] else { continue }
            let path = ZipReader.resolve(href.removingPercentEncoding ?? href, from: opfPath)
            guard isSafe(path), let data = package.data(at: path) else { continue }
            let base = folder.appendingPathComponent(path).deletingLastPathComponent()
            let chapter = HTMLReader.parse(TextDecoding.decode(data), baseURL: base)
            if chapter.blocks.isEmpty { continue }
            if !document.blocks.isEmpty { document.blocks.append(.pageBreak) }
            document.blocks += chapter.blocks
        }
        if document.blocks.isEmpty {
            throw ConversionError("This EPUB file has no readable chapters.")
        }
        return document
    }

    private static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Rejects entries that would escape the extraction folder.
    private static func isSafe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

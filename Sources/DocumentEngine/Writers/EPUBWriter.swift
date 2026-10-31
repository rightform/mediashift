import ConversionCore
import Foundation

/// Writes EPUB 3 with an EPUB 2 table of contents, for older readers.
public enum EPUBWriter {
    public static func write(_ document: RichDocument, to url: URL) throws {
        let title = document.inferredTitle ?? url.deletingPathExtension().lastPathComponent
        let chapters = split(document.blocks)
        var images: [(name: String, asset: ImageAsset)] = []
        let renderer = HTMLBodyRenderer(xhtml: true) { asset in
            let name = "image-\(images.count + 1).\(asset.fileExtension)"
            images.append((name, asset))
            return "images/\(name)"
        }

        let zip = try ZipWriter(url: url)
        // The specification requires this entry first and uncompressed.
        try zip.add("mimetype", data: Data("application/epub+zip".utf8), compressed: false)
        try zip.add("META-INF/container.xml", text: containerXML)
        try zip.add("OEBPS/style.css", text: HTMLWriter.defaultStyleSheet)

        var titles: [String] = []
        for (index, chapter) in chapters.enumerated() {
            let chapterTitle = chapter.title ?? (chapters.count == 1 ? title : "Chapter \(index + 1)")
            titles.append(chapterTitle)
            try zip.add("OEBPS/chapter-\(index + 1).xhtml", text: chapterXHTML(title: chapterTitle, body: renderer.render(chapter.blocks)))
        }
        for image in images {
            try zip.add("OEBPS/images/\(image.name)", data: image.asset.data, compressed: false)
        }
        try zip.add("OEBPS/nav.xhtml", text: navigation(titles: titles))
        try zip.add("OEBPS/toc.ncx", text: ncx(title: title, titles: titles))
        try zip.add("OEBPS/content.opf", text: packageDocument(title: title, author: document.author, chapterCount: chapters.count, images: images))
        try zip.finish()
    }

    private struct Chapter {
        var title: String?
        var blocks: [Block]
    }

    /// Starts a new chapter at each top-level heading and at each page break.
    private static func split(_ blocks: [Block]) -> [Chapter] {
        var chapters: [Chapter] = []
        var current = Chapter(blocks: [])
        for block in blocks {
            switch block {
            case .pageBreak:
                if !current.blocks.isEmpty { chapters.append(current) }
                current = Chapter(blocks: [])
            case .heading(let level, let content, _) where level == 1:
                if !current.blocks.isEmpty { chapters.append(current) }
                current = Chapter(title: content.plainText.trimmed.nilIfEmpty, blocks: [block])
            case .heading(_, let content, _) where current.title == nil:
                current.title = content.plainText.trimmed.nilIfEmpty
                current.blocks.append(block)
            default:
                current.blocks.append(block)
            }
        }
        if !current.blocks.isEmpty || chapters.isEmpty { chapters.append(current) }
        return chapters
    }

    private static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """

    private static func chapterXHTML(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(title.xmlEscaped)</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func navigation(titles: [String]) -> String {
        let items = titles.enumerated().map { "<li><a href=\"chapter-\($0.offset + 1).xhtml\">\($0.element.xmlEscaped)</a></li>" }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Contents</title></head>
            <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(items)</ol></nav></body>
            </html>
            """
    }

    private static func ncx(title: String, titles: [String]) -> String {
        let points = titles.enumerated().map { index, item in
            "<navPoint id=\"np-\(index + 1)\" playOrder=\"\(index + 1)\"><navLabel><text>\(item.xmlEscaped)</text></navLabel><content src=\"chapter-\(index + 1).xhtml\"/></navPoint>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:depth" content="1"/></head><docTitle><text>\(title.xmlEscaped)</text></docTitle><navMap>\(points)</navMap></ncx>
            """
    }

    private static func packageDocument(title: String, author: String?, chapterCount: Int, images: [(name: String, asset: ImageAsset)]) -> String {
        let creator = author.map { "<dc:creator>\($0.xmlEscaped)</dc:creator>" } ?? ""
        let modified = ISO8601DateFormatter().string(from: Date())
        var manifest = """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="css" href="style.css" media-type="text/css"/>
            """
        var spine = ""
        for index in 1...max(1, chapterCount) {
            manifest += "<item id=\"chapter-\(index)\" href=\"chapter-\(index).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"chapter-\(index)\"/>"
        }
        for (index, image) in images.enumerated() {
            manifest += "<item id=\"image-\(index + 1)\" href=\"images/\(image.name)\" media-type=\"\(image.asset.mimeType)\"/>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier><dc:title>\(title.xmlEscaped)</dc:title><dc:language>en</dc:language>\(creator)<meta property="dcterms:modified">\(modified)</meta></metadata><manifest>\(manifest)</manifest><spine toc="ncx">\(spine)</spine></package>
            """
    }
}

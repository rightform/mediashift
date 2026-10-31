import ConversionCore
import Foundation

/// Reads a modern Pages document: objects from `Index/*.iwa`, text from the `TSWP.StorageArchive`
/// the document root names as its body.
struct PagesReader {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func read() throws -> RichDocument {
        let package = try openPackage()
        let names = package.index.partNames.filter { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }
        if package.source.contains(".iwph") || package.index.contains(".iwph") {
            throw ConversionError("This Pages document is password protected.")
        }
        guard !names.isEmpty else {
            throw ConversionError("This file is not a Pages document this app can read.")
        }

        var store = IWAObjectStore()
        var salvaged: [Data] = []
        var everyStreamWasIntact = true
        // Document.iwa first, because salvaged text should start with the body.
        let ordered = names.filter { $0 == "Index/Document.iwa" } + names.filter { $0 != "Index/Document.iwa" }
        for name in ordered {
            guard let data = try package.index.data(forPart: name) else { continue }
            if let stream = try? IWAStream(compressed: data) {
                store.add(stream.objects)
            } else {
                everyStreamWasIntact = false
                let partial = IWAStream.salvage(data)
                store.add(partial.objects)
                salvaged.append(partial.raw)
            }
        }

        let builder = PagesBlockBuilder(store: store, dataSource: package.source)
        let blocks = builder.documentBlocks()
        if !blocks.isEmpty || everyStreamWasIntact && !store.objects.isEmpty {
            return RichDocument(blocks: blocks)
        }

        let text = Self.recoverText(from: salvaged)
        guard !text.isEmpty else {
            throw ConversionError("This Pages document is damaged and no text could be recovered.")
        }
        return RichDocument(blocks: text.map { .paragraph(content: [.text($0)]) })
    }

    // MARK: Packages

    /// A `.pages` is a ZIP, or a folder holding `Index/` or `Index.zip`.
    private func openPackage() throws -> (source: PartSource, index: PartSource) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ConversionError("The file could not be found.")
        }
        guard isDirectory.boolValue else {
            let zip = try ZipPackage(url: url, formatName: "Pages")
            return (zip, zip)
        }
        let folder = try DirectoryPackage(url: url)
        if folder.contains("Index.zip") {
            let index = try ZipPackage(url: url.appendingPathComponent("Index.zip"), formatName: "Pages")
            return (folder, index)
        }
        return (folder, folder)
    }

    // MARK: Last resort

    /// Picks readable runs out of whatever could be decompressed.
    private static func recoverText(from streams: [Data]) -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        for stream in streams {
            let decoded = String(decoding: stream, as: UTF8.self)
            let runs = decoded.split { character in
                character == "\u{FFFD}" || character.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" && $0 != "\n" }
            }
            for run in runs where run.count >= 8 && run.contains(" ") {
                for line in run.split(separator: "\n") {
                    let text = String(line).trimmingCharacters(in: .whitespaces)
                    if text.count >= 2, seen.insert(text).inserted { lines.append(text) }
                }
            }
        }
        return lines
    }
}

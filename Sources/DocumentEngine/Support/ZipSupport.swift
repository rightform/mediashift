import ConversionCore
import Foundation
import ZIPFoundation

/// Read access to a ZIP-based document, with limits that stop decompression bombs.
struct ZipReader {
    private let archive: Archive
    private static let maxEntrySize: Int64 = 1_000_000_000

    init(url: URL, formatName: String) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ConversionError("This \(formatName) file could not be opened. It may be damaged.")
        }
    }

    var paths: [String] {
        archive.map(\.path)
    }

    func data(at path: String) -> Data? {
        guard let entry = archive[path], entry.type == .file, Int64(entry.uncompressedSize) <= Self.maxEntrySize else {
            return nil
        }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry, skipCRC32: true) { result.append($0) }
        } catch {
            return nil
        }
        return result
    }

    func xml(at path: String) -> XMLDocument? {
        guard let data = data(at: path) else { return nil }
        return try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace])
    }

    /// Resolves a package-relative target such as `../media/a.png` against the part that names it.
    static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = part.split(separator: "/").dropLast().map(String.init)
        for piece in target.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(piece))
            }
        }
        return components.joined(separator: "/")
    }
}

/// Writes a ZIP package to a temporary name and moves it into place only when complete.
final class ZipWriter {
    private let archive: Archive
    private let temporaryURL: URL
    private let finalURL: URL

    init(url: URL) throws {
        finalURL = url
        temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        archive = try Archive(url: temporaryURL, accessMode: .create)
    }

    func add(_ path: String, data: Data, compressed: Bool = true) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressed ? .deflate : .none
        ) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    func add(_ path: String, text: String) throws {
        try add(path, data: Data(text.utf8))
    }

    func finish() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: finalURL.path) {
            _ = try manager.replaceItemAt(finalURL, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: finalURL)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}

extension XMLNode {
    /// Child elements in document order.
    var childElements: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }
}

extension XMLElement {
    /// Element name without namespace prefix.
    var plainName: String {
        localName ?? name ?? ""
    }

    func child(_ name: String) -> XMLElement? {
        childElements.first { $0.plainName == name }
    }

    func children(named name: String) -> [XMLElement] {
        childElements.filter { $0.plainName == name }
    }

    /// Attribute by prefixed name, or by local name when the file uses another prefix.
    func value(of name: String) -> String? {
        if let direct = attribute(forName: name)?.stringValue { return direct }
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return (attributes ?? []).first { ($0.localName ?? $0.name) == local }?.stringValue
    }

    /// First descendant with this name, depth first.
    func descendant(_ name: String) -> XMLElement? {
        for element in childElements {
            if element.plainName == name { return element }
            if let found = element.descendant(name) { return found }
        }
        return nil
    }
}

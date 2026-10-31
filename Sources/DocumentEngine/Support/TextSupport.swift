import ConversionCore
import Foundation

enum TextDecoding {
    /// Decodes text files of unknown origin: byte order marks, then strict UTF-8,
    /// then the legacy encodings most likely on a Polish or Western European machine.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data, encoding: .utf16LittleEndian) {
            return String(text.drop { $0 == "\u{FEFF}" })
        }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16BigEndian) {
            return String(text.drop { $0 == "\u{FEFF}" })
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1250) { return text }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }
}

extension String {
    /// Escapes text for use in XML and HTML, in content and in quoted attributes.
    var xmlEscaped: String {
        var result = ""
        result.reserveCapacity(utf8.count)
        for scalar in unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            // Control characters are illegal in XML 1.0 and make Word refuse the file.
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20: break
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses runs of whitespace into one space, as HTML rendering does.
    var whitespaceCollapsed: String {
        var result = ""
        var lastWasSpace = false
        for character in self {
            if character.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }
}

enum ImageSniffer {
    /// Identifies an image by its first bytes. Attachments rarely state their type reliably.
    static func mimeType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if bytes.starts(with: [0x42, 0x4D]) { return "image/bmp" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return "image/heic" }
        if let head = String(data: data.prefix(256), encoding: .utf8), head.contains("<svg") { return "image/svg+xml" }
        return nil
    }
}

enum LocalImageLoader {
    /// Loads an image a document refers to by relative path. Never touches the network,
    /// which is a promise of the app, and refuses anything that is not an image.
    static func load(source: String, relativeTo base: URL?, alt: String?) -> ImageAsset? {
        if source.hasPrefix("data:") { return decodeDataURI(source, alt: alt) }
        guard let base, !source.contains("://") else { return nil }
        let path = source.removingPercentEncoding ?? source
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard let data = try? Data(contentsOf: url), data.count < 100_000_000,
            let mime = ImageSniffer.mimeType(of: data)
        else { return nil }
        return ImageAsset(data: data, mimeType: mime, alt: alt)
    }

    private static func decodeDataURI(_ uri: String, alt: String?) -> ImageAsset? {
        guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64") else { return nil }
        guard let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters),
            let mime = ImageSniffer.mimeType(of: data)
        else { return nil }
        return ImageAsset(data: data, mimeType: mime, alt: alt)
    }
}

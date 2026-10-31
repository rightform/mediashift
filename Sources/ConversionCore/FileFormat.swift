import Foundation

/// The broad family a format belongs to. Decides which engine handles a file.
public enum FileKind: String, Sendable, CaseIterable {
    case document, spreadsheet, presentation, image, video, audio
}

/// Every format the app understands, as input, output or both.
public enum FileFormat: String, Sendable, CaseIterable, Codable, Hashable {
    // Text documents
    case txt, md, rtf, html, docx, doc, odt, epub, pages, pdf
    // Spreadsheets and presentations
    case xlsx, numbers, csv, tsv, pptx, key
    // Images
    case jpeg, png, heic, webp, avif, tiff, gif, bmp
    // Video
    case mp4, mov, m4v, mkv, webm, avi
    // Audio
    case mp3, m4a, wav, flac, ogg, opus, aiff

    public var kind: FileKind {
        switch self {
        case .txt, .md, .rtf, .html, .docx, .doc, .odt, .epub, .pages, .pdf: .document
        case .xlsx, .numbers, .csv, .tsv: .spreadsheet
        case .pptx, .key: .presentation
        case .jpeg, .png, .heic, .webp, .avif, .tiff, .gif, .bmp: .image
        case .mp4, .mov, .m4v, .mkv, .webm, .avi: .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff: .audio
        }
    }

    /// The extension written to disk.
    public var fileExtension: String {
        self == .jpeg ? "jpg" : rawValue
    }

    /// The short label shown on the wheel.
    public var label: String {
        switch self {
        case .md: "Markdown"
        case .pages: "Pages"
        case .numbers: "Numbers"
        case .key: "Keynote"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .webm: "WebM"
        case .opus: "Opus"
        case .tiff: "TIFF"
        default: rawValue.uppercased()
        }
    }

    /// Recognizes a file by its extension. Case insensitive, knows common aliases.
    public init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
    }

    public init?(fileExtension raw: String) {
        let ext = raw.lowercased()
        let aliases: [String: FileFormat] = [
            "markdown": .md, "mdown": .md, "text": .txt, "htm": .html, "xhtml": .html,
            "jpg": .jpeg, "jpe": .jpeg, "tif": .tiff, "heif": .heic, "aif": .aiff, "oga": .ogg,
            "mpeg4": .mp4, "aac": .m4a,
        ]
        if let alias = aliases[ext] {
            self = alias
        } else if let format = FileFormat(rawValue: ext) {
            self = format
        } else {
            return nil
        }
    }
}

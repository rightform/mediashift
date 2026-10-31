import ConversionCore
import Foundation

/// What can be done to a file.
public enum ConversionAction: Hashable, Sendable {
    case convert(FileFormat)
    case compress
    case stripMetadata

    /// Says what will happen, for the wheel and the job list.
    public var title: String {
        switch self {
        case .convert(let format): "Convert to \(format.label)"
        case .compress: "Compress"
        case .stripMetadata: "Remove Metadata"
        }
    }
}

/// Which actions each format offers, most useful first. The wheel shows these in order.
public enum ConversionCatalog {
    private static let imageTargets: [FileFormat] = [.jpeg, .png, .heic, .webp, .avif, .pdf, .tiff, .gif, .bmp]
    private static let videoTargets: [FileFormat] = [.mp4, .mov, .webm, .mkv, .m4v, .gif, .mp3, .m4a]
    private static let audioTargets: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff]
    private static let textTargets: [FileFormat] = [.pdf, .docx, .md, .html, .txt, .rtf, .odt, .epub, .pages, .pptx]
    private static let pageImageTargets: [FileFormat] = [.pdf, .png, .jpeg]

    public static func targets(for format: FileFormat) -> [FileFormat] {
        let all: [FileFormat]
        switch format {
        case .txt, .md, .html, .rtf, .docx, .doc, .odt, .epub, .pages:
            all = textTargets
        case .pdf:
            all = [.png, .jpeg, .docx, .txt, .md, .html, .pptx, .pages]
        case .pptx:
            all = pageImageTargets + [.docx, .md, .txt, .html, .pages]
        case .key:
            all = pageImageTargets + [.txt, .md, .docx]
        case .xlsx:
            all = [.pdf, .csv, .tsv, .html, .md, .txt, .docx]
        case .numbers:
            all = pageImageTargets + [.txt]
        case .csv, .tsv:
            all = [.xlsx, .pdf, .csv, .tsv, .html, .md, .docx]
        case .jpeg, .png, .heic, .webp, .avif, .tiff, .gif, .bmp:
            all = imageTargets + [.pptx, .txt]
        case .mp4, .mov, .m4v, .mkv, .webm, .avi:
            all = videoTargets
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff:
            all = audioTargets
        }
        return all.filter { $0 != format }
    }

    public static func canCompress(_ format: FileFormat) -> Bool {
        switch format.kind {
        case .image, .video, .audio: true
        default: format == .pdf
        }
    }

    public static func canStripMetadata(_ format: FileFormat) -> Bool {
        switch format.kind {
        case .image, .video, .audio: true
        default: [.pdf, .docx, .xlsx, .pptx].contains(format)
        }
    }

    public static func actions(for format: FileFormat) -> [ConversionAction] {
        var actions = targets(for: format).map(ConversionAction.convert)
        if canCompress(format) { actions.append(.compress) }
        if canStripMetadata(format) { actions.append(.stripMetadata) }
        return actions
    }

    /// What a whole drop has in common, in the order of its most frequent format. A file already
    /// in the target format doesn't rule that target out: it simply has nothing to do.
    /// Any file of an unknown type means nothing can be offered for the drop as a whole.
    public static func actions(for inputs: [URL]) -> [ConversionAction] {
        var counts: [FileFormat: Int] = [:]
        for input in inputs {
            guard let format = FileFormat(url: input) else { return [] }
            counts[format, default: 0] += 1
        }
        let formats = counts.keys.sorted { (counts[$0] ?? 0, $1.rawValue) > (counts[$1] ?? 0, $0.rawValue) }
        guard let first = formats.first else { return [] }

        var candidates = actions(for: first)
        for format in formats.dropFirst() {
            for action in actions(for: format) where !candidates.contains(action) {
                candidates.append(action)
            }
        }
        return candidates.filter { action in
            formats.allSatisfy { format in
                if case .convert(let target) = action, target == format { return true }
                return actions(for: format).contains(action)
            }
        }
    }

    /// The files in a drop that this action would change.
    public static func applicableInputs(_ inputs: [URL], for action: ConversionAction) -> [URL] {
        inputs.filter { input in
            guard let format = FileFormat(url: input) else { return false }
            return actions(for: format).contains(action)
        }
    }
}

import ConversionCore
import ImageIO
import UniformTypeIdentifiers

extension FileFormat {
    /// The type ImageIO knows this format by.
    var imageType: UTType? {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .gif: .gif
        case .tiff: .tiff
        case .heic: .heic
        case .bmp: .bmp
        case .webp: .webP
        case .avif: UTType("public.avif")
        default: nil
        }
    }

    /// ImageIO reads WebP but cannot write it. That one goes through ffmpeg.
    var imageIOCanWrite: Bool {
        kind == .image && self != .webp
    }

    var supportsAlpha: Bool {
        self != .jpeg && self != .bmp
    }

    /// Formats where an EXIF orientation tag is honoured by viewers.
    var storesOrientation: Bool {
        [.jpeg, .heic, .tiff, .avif].contains(self)
    }

    var isLossy: Bool {
        [.jpeg, .heic, .avif, .webp].contains(self)
    }

    var defaultQuality: Double? {
        switch self {
        case .jpeg: 0.85
        case .heic: 0.8
        case .avif: 0.7
        case .webp: 0.8
        default: nil
        }
    }

    /// Recognizes the type identifier ImageIO reports for a file.
    init?(imageTypeIdentifier identifier: String) {
        switch identifier {
        case "public.jpeg": self = .jpeg
        case "public.png": self = .png
        case "com.compuserve.gif": self = .gif
        case "public.tiff": self = .tiff
        case "public.heic", "public.heif": self = .heic
        case "public.avif": self = .avif
        case "com.microsoft.bmp": self = .bmp
        case "org.webmproject.webp": self = .webp
        default: return nil
        }
    }
}

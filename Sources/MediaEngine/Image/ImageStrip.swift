import ConversionCore
import Foundation
import ImageIO

/// Removes every trace of who took a picture, with what, and where.
enum ImageStrip {
    static func stripped(_ url: URL) throws -> Data {
        let source = try ImageSource(url: url)

        // WebP keeps its metadata in separate chunks, which can be cut out without touching the pixels.
        if source.format == .webp {
            return try WebPContainer.removingMetadata(from: Data(contentsOf: url))
        }
        guard let format = source.format, format.imageIOCanWrite else {
            throw ConversionError("Metadata cannot be removed from this kind of image.")
        }

        // The lossless route cannot rotate pixels, so it only serves upright, single picture files.
        if source.count == 1, source.orientation(at: 0) == .up,
           let copy = losslessCopy(of: source), ImageMetadata.isClean(copy) {
            return copy
        }

        let options = ImageOptions(quality: quality(for: format), maxPixelSize: nil, keepsMetadata: false)
        let data = try ImageConversion.encode(source, as: format, options: options)
        guard ImageMetadata.isClean(data) else {
            throw ConversionError("Some metadata could not be removed from this image.")
        }
        return data
    }

    /// Rewrites the file with empty metadata and no recompression.
    private static func losslessCopy(of source: ImageSource) -> Data? {
        guard let type = CGImageSourceGetType(source.source) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }

        var options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
        ]
        for key in ImageMetadata.sensitiveDictionaries {
            options[key] = kCFNull as Any
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source.source, options as CFDictionary, &error) else {
            return nil
        }
        return data as Data
    }

    /// High enough that a second encode is not visible.
    private static func quality(for format: FileFormat) -> Double? {
        switch format {
        case .jpeg: 0.95
        case .heic, .avif: 0.9
        default: nil
        }
    }
}

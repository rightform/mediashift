import ConversionCore
import CoreGraphics
import Foundation
import ImageIO

/// Settings for turning one image into another format.
public struct ImageOptions: Sendable {
    /// 0 to 1. Nil uses the format's default. Ignored by lossless formats.
    public var quality: Double?
    /// The longest edge in pixels. Nil keeps the size. Images are never enlarged.
    public var maxPixelSize: Int?
    /// Keeps EXIF, GPS, IPTC and XMP where the new format has room for them.
    public var keepsMetadata: Bool

    public init(quality: Double? = nil, maxPixelSize: Int? = nil, keepsMetadata: Bool = true) {
        self.quality = quality
        self.maxPixelSize = maxPixelSize
        self.keepsMetadata = keepsMetadata
    }
}

/// The ImageIO half of conversion: everything except writing WebP.
enum ImageConversion {
    static func encode(_ source: ImageSource, as format: FileFormat, options: ImageOptions) throws -> Data {
        let index = source.primaryIndex
        let size = source.pixelSize(at: index)
        let longest = max(size.width, size.height)
        let resizeTo = options.maxPixelSize.flatMap { $0 > 0 && $0 < longest ? $0 : nil }
        let orientation = source.orientation(at: index)
        let quality = options.quality.map { min(max($0, 0), 1) } ?? format.defaultQuality

        let animated = format == .gif && source.isAnimated
        let multiPage = format == .tiff && source.format == .tiff && source.count > 1
        let flatten = source.hasAlpha(at: index) && !format.supportsAlpha

        // A file that already stores its orientation can keep the tag. Anything else gets upright pixels.
        let bake = orientation != .up && (resizeTo != nil || !options.keepsMetadata || !format.storesOrientation)

        let canCopyAsIs = !bake && resizeTo == nil && !flatten && options.keepsMetadata && !animated && !multiPage
        if canCopyAsIs {
            return try ImageWriter.encodeFromSource(source, index: index, as: format, quality: quality)
        }

        let indices = (animated || multiPage) ? Array(0 ..< source.count) : [index]
        var frames: [ImageWriter.Frame] = []
        for frameIndex in indices {
            try Task.checkCancellation()
            var image = try ImageRenderer.render(
                source, index: frameIndex, applyingOrientation: bake, maxPixelSize: resizeTo
            )
            if flatten, ImageRenderer.hasAlpha(image) {
                image = ImageRenderer.flattenedOnWhite(image)
            }
            var frame = ImageWriter.Frame(image: image)
            if options.keepsMetadata {
                frame.properties = ImageMetadata.carried(from: source.properties(at: frameIndex), orientationBaked: bake)
                frame.metadata = ImageMetadata.xmp(of: source.source, at: frameIndex, orientationBaked: bake)
            }
            frame.delay = animated ? source.delay(at: frameIndex) : nil
            frames.append(frame)
        }
        return try ImageWriter.encode(frames, as: format, quality: quality)
    }
}

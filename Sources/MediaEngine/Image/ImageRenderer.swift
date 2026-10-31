import ConversionCore
import CoreGraphics
import Foundation
import ImageIO

/// Decoding and the pixel level fixes that conversion needs.
enum ImageRenderer {
    /// One image from the file as pixels. With `applyingOrientation` the result is upright and
    /// carries no orientation tag. A `maxPixelSize` below the image's own size scales it down.
    static func render(
        _ source: ImageSource,
        index: Int,
        applyingOrientation: Bool,
        maxPixelSize: Int?
    ) throws -> CGImage {
        let size = source.pixelSize(at: index)
        if applyingOrientation || maxPixelSize != nil {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: applyingOrientation,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? max(size.width, size.height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source.source, index, options as CFDictionary) {
                return image
            }
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source.source, index, options) else {
            throw ConversionError("This image could not be decoded.")
        }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Draws the image on white, for formats that cannot hold transparency.
    static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        redrawn(image, colorSpace: workingSpace(for: image), alpha: .noneSkipLast, background: true) ?? image
    }

    /// The same picture in sRGB, for encoders that write no color profile.
    static func inSRGB(_ image: CGImage) -> CGImage {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        if image.colorSpace?.name == srgb.name, image.bitsPerComponent == 8, image.bitsPerPixel == 32 {
            return image
        }
        let alpha: CGImageAlphaInfo = hasAlpha(image) ? .premultipliedLast : .noneSkipLast
        return redrawn(image, colorSpace: srgb, alpha: alpha, background: false) ?? image
    }

    /// A smaller copy, scaled by `factor` on both sides.
    static func scaled(_ image: CGImage, by factor: Double) -> CGImage {
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        let alpha: CGImageAlphaInfo = hasAlpha(image) ? .premultipliedLast : .noneSkipLast
        return redrawn(
            image, colorSpace: workingSpace(for: image), alpha: alpha, background: false, size: (width, height)
        ) ?? image
    }

    /// Keeps the image's own RGB space, so wide gamut pictures stay wide gamut.
    private static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, !space.isExtendedRange {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func redrawn(
        _ image: CGImage,
        colorSpace: CGColorSpace,
        alpha: CGImageAlphaInfo,
        background: Bool,
        size: (Int, Int)? = nil
    ) -> CGImage? {
        let width = size?.0 ?? image.width
        let height = size?.1 ?? image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: alpha.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if background {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}

private extension CGColorSpace {
    /// Extended range and HDR spaces cannot back an 8 bit bitmap.
    var isExtendedRange: Bool {
        let label = (name as String?) ?? ""
        return ["Extended", "HDR", "PQ", "HLG"].contains { label.contains($0) }
    }
}

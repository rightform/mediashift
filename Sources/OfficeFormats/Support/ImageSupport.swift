import ConversionCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image checked by ImageIO, in a format the target package can embed.
struct PreparedImage {
    var data: Data
    var fileExtension: String
    var pixelWidth: Double
    var pixelHeight: Double
}

enum ImageSupport {
    /// The image ready to embed, re-encoded as PNG when its format is not one of `allowed`.
    /// Nil when ImageIO cannot make sense of the data.
    static func prepare(_ asset: ImageAsset, allowedExtensions allowed: Set<String>) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0
        else { return nil }

        let fileExtension = sourceExtension(of: source) ?? asset.fileExtension
        if allowed.contains(fileExtension) {
            return PreparedImage(data: asset.data, fileExtension: fileExtension, pixelWidth: width, pixelHeight: height)
        }
        guard let png = pngData(from: source) else { return nil }
        return PreparedImage(data: png, fileExtension: "png", pixelWidth: width, pixelHeight: height)
    }

    /// The size to show an image at: what the source states if that makes sense, else its pixels.
    static func naturalSize(of asset: ImageAsset, _ image: PreparedImage) -> (width: Double, height: Double) {
        if let width = asset.width, let height = asset.height, width.isFinite, height.isFinite, width > 0, height > 0 {
            return (width, height)
        }
        return (image.pixelWidth, image.pixelHeight)
    }

    private static func sourceExtension(of source: CGImageSource) -> String? {
        guard let identifier = CGImageSourceGetType(source) as String?,
            let type = UTType(identifier),
            let preferred = type.preferredFilenameExtension
        else { return nil }
        return preferred == "jpeg" ? "jpg" : preferred
    }

    private static func pngData(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The MIME type for a stored image's file name.
    static func mimeType(forPath path: String) -> String {
        switch path.split(separator: ".").last?.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg", "jpe": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "heic", "heif": "image/heic"
        case "pdf": "application/pdf"
        case "emf": "image/x-emf"
        case "wmf": "image/x-wmf"
        default: "application/octet-stream"
        }
    }
}

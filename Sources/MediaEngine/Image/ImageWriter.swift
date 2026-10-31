import ConversionCore
import CoreGraphics
import Foundation
import ImageIO

/// Encodes images with ImageIO into memory.
enum ImageWriter {
    struct Frame {
        var image: CGImage
        var properties: [CFString: Any] = [:]
        var metadata: CGImageMetadata?
        /// Seconds this frame stays up, for animations.
        var delay: Double?
    }

    /// Encodes one or more frames. Several frames make an animation for GIF and pages for TIFF.
    static func encode(
        _ frames: [Frame],
        as format: FileFormat,
        quality: Double? = nil,
        lzw: Bool = false
    ) throws -> Data {
        let destination = try makeDestination(format, count: frames.count)
        if format == .gif, frames.count > 1 {
            let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            CGImageDestinationSetProperties(destination.destination, loop as CFDictionary)
        }
        for frame in frames {
            var properties = frame.properties
            if format.isLossy, let quality {
                properties[kCGImageDestinationLossyCompressionQuality] = quality
            }
            if format == .gif, let delay = frame.delay {
                properties[kCGImagePropertyGIFDictionary] = [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            }
            if lzw, format == .tiff {
                var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
                tiff[kCGImagePropertyTIFFCompression] = 5
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if let metadata = frame.metadata {
                properties[kCGImageDestinationMetadata] = metadata
            }
            CGImageDestinationAddImage(destination.destination, frame.image, properties as CFDictionary)
        }
        return try finish(destination)
    }

    /// Copies a picture from a source file with all of its metadata, color profile and extras.
    static func encodeFromSource(
        _ source: ImageSource,
        index: Int,
        as format: FileFormat,
        quality: Double?
    ) throws -> Data {
        let destination = try makeDestination(format, count: 1)
        var options: [CFString: Any] = [:]
        if format.isLossy, let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImageFromSource(destination.destination, source.source, index, options as CFDictionary)
        return try finish(destination)
    }

    // MARK: Plumbing

    private struct Destination {
        let destination: CGImageDestination
        let data: NSMutableData
    }

    private static func makeDestination(_ format: FileFormat, count: Int) throws -> Destination {
        guard let type = format.imageType, format.imageIOCanWrite else {
            throw ConversionError("\(format.label) images cannot be written.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, count, nil) else {
            throw ConversionError("This Mac cannot write \(format.label) images.")
        }
        return Destination(destination: destination, data: data)
    }

    private static func finish(_ destination: Destination) throws -> Data {
        guard CGImageDestinationFinalize(destination.destination) else {
            throw ConversionError("The image could not be written.")
        }
        return destination.data as Data
    }
}

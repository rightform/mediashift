import ConversionCore
import Foundation
import ImageIO

/// An image file opened through ImageIO, with the few facts the converters ask for.
struct ImageSource {
    let source: CGImageSource
    let count: Int
    /// The format ImageIO detected, or nil for something exotic such as RAW.
    let format: FileFormat?

    init(url: URL) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw ConversionError("This file is not an image that can be read.")
        }
        self.source = source
        self.count = CGImageSourceGetCount(source)
        self.format = CGImageSourceGetType(source).flatMap { FileFormat(imageTypeIdentifier: $0 as String) }
    }

    /// The picture a viewer shows. For most files that is the first one.
    var primaryIndex: Int {
        min(max(CGImageSourceGetPrimaryImageIndex(source), 0), count - 1)
    }

    func properties(at index: Int) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
    }

    func pixelSize(at index: Int) -> (width: Int, height: Int) {
        let properties = properties(at: index)
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (width, height)
    }

    func orientation(at index: Int) -> CGImagePropertyOrientation {
        let raw = (properties(at: index)[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    func hasAlpha(at index: Int) -> Bool {
        (properties(at: index)[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    /// Dots per inch, when the file states one that makes sense.
    func dpi(at index: Int) -> Double? {
        let value = (properties(at: index)[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        return value.flatMap { (36 ... 1200).contains($0) ? $0 : nil }
    }

    /// How long a frame of an animation stays up, in seconds. Nil for a plain image.
    func delay(at index: Int) -> Double? {
        let properties = properties(at: index)
        let candidates: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictionary, unclamped, clamped) in candidates {
            guard let inner = properties[dictionary] as? [CFString: Any] else { continue }
            let value = (inner[unclamped] as? NSNumber) ?? (inner[clamped] as? NSNumber)
            if let seconds = value?.doubleValue {
                // Viewers treat a delay of zero as "too fast to mean it" and use a tenth of a second.
                return seconds < 0.011 ? 0.1 : seconds
            }
        }
        return nil
    }

    var isAnimated: Bool {
        count > 1 && delay(at: 0) != nil
    }
}

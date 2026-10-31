import Foundation
import ImageIO

/// Moves metadata between files and checks that none is left behind.
enum ImageMetadata {
    /// Every dictionary that can hold something about the camera, the place or the person.
    static var sensitiveDictionaries: [CFString] {
        [
            kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyPNGDictionary,
            kCGImageProperty8BIMDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyCIFFDictionary,
            kCGImagePropertyRawDictionary, kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
            kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerFujiDictionary,
            kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
            kCGImagePropertyMakerAppleDictionary,
        ]
    }

    /// The PNG text chunks that carry descriptions and authorship.
    private static var pngTextKeys: [CFString] {
        [
            kCGImagePropertyPNGTitle, kCGImagePropertyPNGAuthor, kCGImagePropertyPNGDescription,
            kCGImagePropertyPNGCopyright, kCGImagePropertyPNGCreationTime, kCGImagePropertyPNGSoftware,
            kCGImagePropertyPNGComment, kCGImagePropertyPNGSource, kCGImagePropertyPNGDisclaimer,
            kCGImagePropertyPNGWarning,
        ]
    }

    /// The properties worth writing into a new file. Sizes and color details are left out, since
    /// the encoder knows those better. When the pixels were rotated upright, the orientation resets.
    static func carried(from properties: [CFString: Any], orientationBaked: Bool) -> [CFString: Any] {
        var carried: [CFString: Any] = [:]
        let kept = sensitiveDictionaries.filter { $0 != kCGImagePropertyPNGDictionary }
        for key in kept {
            if let value = properties[key] as? [CFString: Any] {
                carried[key] = value
            }
        }
        if var png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            png = png.filter { pngTextKeys.contains($0.key) }
            if !png.isEmpty {
                carried[kCGImagePropertyPNGDictionary] = png
            }
        }
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] {
                carried[key] = value
            }
        }

        // The encoder writes these itself, and old values would be wrong after resizing.
        if var exif = carried[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            carried[kCGImagePropertyExifDictionary] = exif
        }
        if let orientation = properties[kCGImagePropertyOrientation] {
            carried[kCGImagePropertyOrientation] = orientationBaked ? 1 : orientation
        }
        if orientationBaked, var tiff = carried[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            carried[kCGImagePropertyTIFFDictionary] = tiff
        }
        return carried
    }

    /// The XMP packet of an image, with its orientation reset when the pixels were rotated upright.
    static func xmp(of source: CGImageSource, at index: Int, orientationBaked: Bool) -> CGImageMetadata? {
        guard let original = CGImageSourceCopyMetadataAtIndex(source, index, nil),
              let copy = CGImageMetadataCreateMutableCopy(original) else { return nil }
        if orientationBaked {
            CGImageMetadataSetValueWithPath(copy, nil, "tiff:Orientation" as CFString, 1 as CFNumber)
        }
        return copy
    }

    // MARK: Checking

    /// What the audit looks for. Anything listed here identifies a camera, a person or a place.
    private static var revealingTIFFKeys: [CFString] {
        [
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
            kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
            kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFHostComputer,
        ]
    }

    private static var revealingExifKeys: [CFString] {
        [
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
            kCGImagePropertyExifUserComment, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake,
            kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName,
            kCGImagePropertyExifMakerNote, kCGImagePropertyExifLensSerialNumber,
        ]
    }

    /// True when the image has no EXIF, GPS, IPTC, XMP or maker note content that says who or where.
    static func isClean(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return false
        }
        for index in 0 ..< CGImageSourceGetCount(source) {
            if !isClean(source, at: index) { return false }
        }
        return true
    }

    private static func isClean(_ source: CGImageSource, at index: Int) -> Bool {
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]

        let alwaysRevealing: [CFString] = [
            kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary,
            kCGImageProperty8BIMDictionary, kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
            kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerFujiDictionary,
            kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
            kCGImagePropertyMakerAppleDictionary, kCGImagePropertyCIFFDictionary, kCGImagePropertyDNGDictionary,
        ]
        if alwaysRevealing.contains(where: { properties[$0] != nil }) { return false }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           revealingTIFFKeys.contains(where: { tiff[$0] != nil }) { return false }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           revealingExifKeys.contains(where: { exif[$0] != nil }) { return false }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           pngTextKeys.contains(where: { png[$0] != nil }) { return false }

        if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            return tags.allSatisfy(isHarmless)
        }
        return true
    }

    /// ImageIO mirrors the structure of the file (size, tiles, color model) into XMP-like tags.
    /// Those say nothing about a person. Anything outside the TIFF and EXIF namespaces does.
    private static func isHarmless(_ tag: CGImageMetadataTag) -> Bool {
        let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
        let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
        guard prefix == "tiff" || prefix == "exif" else { return false }
        let revealing = [
            "Make", "Model", "Software", "DateTime", "Artist", "Copyright", "ImageDescription", "HostComputer",
            "DateTimeOriginal", "DateTimeDigitized", "UserComment", "LensModel", "LensMake", "BodySerialNumber",
            "CameraOwnerName", "MakerNote", "LensSerialNumber",
        ]
        return !name.hasPrefix("GPS") && !revealing.contains(name)
    }
}

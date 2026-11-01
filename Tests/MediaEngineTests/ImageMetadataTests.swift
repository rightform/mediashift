import ConversionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MediaEngine

@Suite struct ImageMetadataTests {
    /// Everything a camera and a phone might leave in a photo.
    static var revealingProperties: [CFString: Any] {
        [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "AcmeCam",
                kCGImagePropertyTIFFModel: "X100",
                kCGImagePropertyTIFFSoftware: "SecretSoft 1.0",
                kCGImagePropertyTIFFArtist: "Jane Secret",
                kCGImagePropertyTIFFOrientation: 6,
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                kCGImagePropertyExifUserComment: "private note",
                kCGImagePropertyExifLensModel: "AcmeLens 35",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 52.2297,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 21.0122,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: "Secret caption",
                kCGImagePropertyIPTCKeywords: ["secret"],
            ] as [CFString: Any],
        ]
    }

    static func revealingXMP() -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString, "SecretTool" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "SecretLabel" as CFString)
        return metadata
    }

    /// A photo with a rotated orientation and every kind of metadata, in the given format.
    private func makePhoto(_ format: FileFormat, in scratch: Scratch) async throws -> URL {
        let url = scratch.file("photo.\(format.fileExtension)")
        try await ImageFixture.write(
            ImageFixture.make(), as: format, to: url,
            properties: Self.revealingProperties, metadata: Self.revealingXMP(), quality: 1
        )
        return url
    }

    @Test("The fixture really carries metadata, so the checks below mean something")
    func fixtureIsRevealing() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let photo = try await makePhoto(.jpeg, in: scratch)

        let properties = ImageFixture.properties(of: photo)
        #expect(properties[kCGImagePropertyGPSDictionary] != nil)
        #expect(properties[kCGImagePropertyIPTCDictionary] != nil)
        #expect(!ImageMetadata.isClean(try Data(contentsOf: photo)))
    }

    @Test(arguments: [FileFormat.jpeg, .tiff, .heic, .png].filter(ImageSupport.canWrite))
    func stripRemovesEverythingAndKeepsThePictureUpright(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let photo = try await makePhoto(format, in: scratch)
        let before = ImageFixture.properties(of: photo)
        try #require(before[kCGImagePropertyGPSDictionary] != nil, "\(format.rawValue) fixture lost its GPS data")

        let output = scratch.file("clean.\(format.fileExtension)")
        try await ImageConverter.stripMetadata(photo, to: output)

        let after = ImageFixture.properties(of: output)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect(after[kCGImagePropertyIPTCDictionary] == nil)
        #expect(after[kCGImagePropertyExifAuxDictionary] == nil)
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(exif?[kCGImagePropertyExifLensModel] == nil)
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
        #expect(tiff?[kCGImagePropertyTIFFSoftware] == nil)
        #expect(tiff?[kCGImagePropertyTIFFArtist] == nil)
        #expect(ImageMetadata.isClean(try Data(contentsOf: output)))

        // No XMP survives either.
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        if let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let tags = CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag] {
            let names = tags.compactMap { CGImageMetadataTagCopyName($0) as String? }
            #expect(!names.contains("CreatorTool") && !names.contains("Label"), "XMP left: \(names)")
        }

        // The photo was stored sideways with orientation 6. It must now be upright without a tag.
        #expect((after[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let size = ImageFixture.size(of: output)
        #expect(size?.width == 64 && size?.height == 96)
        #expect(isNear(ImageFixture.pixel(of: output, x: 60, y: 4), 255, 255, 255, tolerance: 60))
    }

    @Test func stripLeavesNoSecretBytesBehind() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let photo = try await makePhoto(.jpeg, in: scratch)
        let output = scratch.file("clean.jpg")

        try await ImageConverter.stripMetadata(photo, to: output)

        let bytes = try Data(contentsOf: output)
        // ImageIO always writes a tiny Exif block with color space and size. It names nobody, so only
        // the revealing strings are searched for.
        for secret in ["Secret","AcmeCam", "AcmeLens", "private note", "http://ns.adobe.com"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "found \(secret)")
        }
    }

    @Test func stripDoesNotTouchUprightJPEGPixels() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let photo = scratch.file("upright.jpg")
        var properties = Self.revealingProperties
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "AcmeCam"] as [CFString: Any]
        try await ImageFixture.write(ImageFixture.make(), as: .jpeg, to: photo, properties: properties, quality: 0.9)
        let output = scratch.file("clean.jpg")

        try await ImageConverter.stripMetadata(photo, to: output)

        // Identical pixels prove nothing was encoded a second time.
        #expect(fileSize(output) < fileSize(photo))
        #expect(ImageFixture.size(of: output)?.width == 96)
        #expect(ImageMetadata.isClean(try Data(contentsOf: output)))
        let before = try #require(ImageFixture.pixels(of: photo))
        #expect(before == ImageFixture.pixels(of: output))
    }

    @Test(.enabled(if: ffmpegAvailable))
    func stripWorksOnWebP() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let plain = scratch.file("plain.webp")
        try await ImageFixture.write(ImageFixture.make(), as: .webp, to: plain)
        let photo = scratch.file("photo.webp")
        try Self.addMetadataChunks(to: plain, writing: photo)
        #expect(WebPContainer.hasMetadata(try Data(contentsOf: photo)))

        let output = scratch.file("clean.webp")
        try await ImageConverter.stripMetadata(photo, to: output)

        let bytes = try Data(contentsOf: output)
        #expect(!WebPContainer.hasMetadata(bytes))
        #expect(bytes.range(of: Data("SecretCamera".utf8)) == nil)
        #expect(ImageFixture.format(of: output) == .webp)
        #expect(ImageFixture.size(of: output)?.width == 96)
    }

    /// Builds a WebP with EXIF and XMP chunks by rewriting a plain one, since no encoder here writes them.
    static func addMetadataChunks(to plain: URL, writing output: URL) throws {
        let data = try Data(contentsOf: plain)
        func chunk(_ name: String, _ payload: String) -> Data {
            var body = Data(payload.utf8)
            var piece = Data(name.utf8)
            var size = UInt32(body.count).littleEndian
            piece.append(Data(bytes: &size, count: 4))
            if body.count % 2 == 1 { body.append(0) }
            piece.append(body)
            return piece
        }
        var rebuilt = Data("RIFF".utf8)
        rebuilt.append(contentsOf: [0, 0, 0, 0])
        rebuilt.append(Data("WEBP".utf8))
        // A simple lossy WebP starts with a "VP8 " chunk. Extended files start with VP8X.
        var body = data.subdata(in: 12 ..< data.count)
        if !body.starts(with: Data("VP8X".utf8)) {
            // Wrap in an extended header: 10 byte VP8X payload, flags for EXIF and XMP, canvas 96x64.
            var vp8x = Data("VP8X".utf8)
            vp8x.append(contentsOf: [10, 0, 0, 0, 0x0C, 0, 0, 0, 95, 0, 0, 63, 0, 0])
            body = vp8x + body
        } else {
            body[8] |= 0x0C
        }
        rebuilt.append(body)
        rebuilt.append(chunk("EXIF", "SecretCamera exif"))
        rebuilt.append(chunk("XMP ", "<x:xmpmeta>SecretCamera</x:xmpmeta>"))
        var size = UInt32(rebuilt.count - 8).littleEndian
        rebuilt.replaceSubrange(4 ..< 8, with: Data(bytes: &size, count: 4))
        try rebuilt.write(to: output)
    }

    @Test func webPContainerCutsOnlyMetadataChunks() throws {
        func chunk(_ name: String, _ payload: [UInt8]) -> [UInt8] {
            var bytes = Array(name.utf8)
            let size = UInt32(payload.count)
            bytes += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
            bytes += payload
            if payload.count % 2 == 1 { bytes.append(0) }
            return bytes
        }
        let vp8x = chunk("VP8X", [0x2C, 0, 0, 0, 9, 0, 0, 9, 0, 0])
        let pixels = chunk("VP8 ", [1, 2, 3])
        let exif = chunk("EXIF", [9, 9, 9, 9])
        let xmp = chunk("XMP ", [8, 8])
        let icc = chunk("ICCP", [7, 7])
        let body = Array("WEBP".utf8) + vp8x + icc + pixels + exif + xmp
        var size = UInt32(body.count)
        let file = Data(Array("RIFF".utf8) + withUnsafeBytes(of: &size) { Array($0) } + body)

        let cleaned = try WebPContainer.removingMetadata(from: file)

        #expect(!WebPContainer.hasMetadata(cleaned))
        let expected = Array("WEBP".utf8) + vp8x + icc + pixels
        #expect(cleaned.count == 8 + expected.count)
        #expect(cleaned[20] == 0x20, "EXIF and XMP flags should be cleared, ICC flag kept")
        let declared = (0 ..< 4).reduce(0) { $0 | Int(cleaned[4 + $1]) << (8 * $1) }
        #expect(declared == cleaned.count - 8)
    }

    @Test func webPContainerRejectsOtherFiles() {
        #expect(throws: ConversionError.self) {
            try WebPContainer.removingMetadata(from: Data("not a webp file at all".utf8))
        }
    }
}

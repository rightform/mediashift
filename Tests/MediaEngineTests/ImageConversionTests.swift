import ConversionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MediaEngine

/// One source format and one target format.
struct FormatPair: Sendable, CustomTestStringConvertible {
    var from: FileFormat
    var to: FileFormat

    var testDescription: String { "\(from.rawValue) to \(to.rawValue)" }

    static let imageIOFormats: [FileFormat] = [.jpeg, .png, .gif, .tiff, .heic, .avif, .bmp]

    /// Every ordered pair of formats ImageIO can both read and write.
    static let withoutWebP: [FormatPair] = imageIOFormats.flatMap { from in
        imageIOFormats.map { FormatPair(from: from, to: $0) }
    }

    /// Every pair that has WebP on either side, which goes through ffmpeg.
    static let withWebP: [FormatPair] =
        imageIOFormats.map { FormatPair(from: .webp, to: $0) }
            + imageIOFormats.map { FormatPair(from: $0, to: .webp) }
            + [FormatPair(from: .webp, to: .webp)]
}

@Suite struct ImageConversionTests {
    private func convertPair(_ pair: FormatPair) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("input.\(pair.from.fileExtension)")
        let output = scratch.file("output.\(pair.to.fileExtension)")
        try await ImageFixture.write(ImageFixture.make(), as: pair.from, to: input)

        try await ImageConverter.convert(input, to: output, format: pair.to)

        #expect(ImageFixture.format(of: output) == pair.to)
        let size = ImageFixture.size(of: output)
        #expect(size?.width == 96 && size?.height == 64)
        // Only the input and the result remain.
        #expect(scratch.contents.count == 2)
    }

    @Test("ImageIO formats convert into and out of each other", arguments: FormatPair.withoutWebP)
    func imageIOPairs(_ pair: FormatPair) async throws {
        try await convertPair(pair)
    }

    @Test("WebP converts into and out of every format", .enabled(if: ffmpegAvailable), arguments: FormatPair.withWebP)
    func webPPairs(_ pair: FormatPair) async throws {
        try await convertPair(pair)
    }

    // MARK: Orientation

    @Test func orientationIsKeptAsATagWhenMetadataIsKept() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("rotated.jpg")
        let output = scratch.file("copy.jpg")
        try await ImageFixture.write(ImageFixture.make(), as: .jpeg, to: input, properties: [kCGImagePropertyOrientation: 6])

        try await ImageConverter.convert(input, to: output, format: .jpeg)

        let properties = ImageFixture.properties(of: output)
        #expect((properties[kCGImagePropertyOrientation] as? Int) == 6)
        #expect(ImageFixture.size(of: output)?.width == 96)
    }

    @Test(arguments: [FileFormat.png, .gif, .bmp])
    func orientationIsAppliedForFormatsWithoutATag(format: FileFormat) async throws {
        try await checkOrientationIsApplied(format: format)
    }

    @Test(.enabled(if: ffmpegAvailable))
    func orientationIsAppliedForWebP() async throws {
        try await checkOrientationIsApplied(format: .webp)
    }

    private func checkOrientationIsApplied(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("rotated.jpg")
        let output = scratch.file("upright.\(format.fileExtension)")
        // Orientation 6 means the picture must be turned a quarter clockwise to look right.
        try await ImageFixture.write(ImageFixture.make(), as: .jpeg, to: input, properties: [kCGImagePropertyOrientation: 6], quality: 1)

        try await ImageConverter.convert(input, to: output, format: format)

        let size = ImageFixture.size(of: output)
        #expect(size?.width == 64 && size?.height == 96)
        // The white square was top left in the stored pixels, so it ends up top right.
        #expect(isNear(ImageFixture.pixel(of: output, x: 60, y: 4), 255, 255, 255, tolerance: 60))
        #expect(!isNear(ImageFixture.pixel(of: output, x: 4, y: 4), 255, 255, 255, tolerance: 60))
    }

    @Test func orientationIsAppliedWhenMetadataIsDropped() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("rotated.jpg")
        let output = scratch.file("upright.jpg")
        try await ImageFixture.write(ImageFixture.make(), as: .jpeg, to: input, properties: [kCGImagePropertyOrientation: 6], quality: 1)

        try await ImageConverter.convert(input, to: output, format: .jpeg, options: ImageOptions(keepsMetadata: false))

        let properties = ImageFixture.properties(of: output)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(ImageFixture.size(of: output)?.width == 64)
    }

    // MARK: Alpha, size, profile

    @Test(arguments: [FileFormat.jpeg, .bmp])
    func transparencyBecomesWhiteWhenTheTargetHasNone(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("alpha.png")
        let output = scratch.file("flat.\(format.fileExtension)")
        try await ImageFixture.write(ImageFixture.make(transparentLeftHalf: true), as: .png, to: input)

        try await ImageConverter.convert(input, to: output, format: format)

        // Left half was transparent, right half is blue.
        #expect(isNear(ImageFixture.pixel(of: output, x: 30, y: 40), 255, 255, 255, tolerance: 12))
        #expect(isNear(ImageFixture.pixel(of: output, x: 80, y: 40), 26, 26, 204))
    }

    @Test func transparencyIsKeptByFormatsThatHaveIt() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("alpha.png")
        let output = scratch.file("alpha.tiff")
        try await ImageFixture.write(ImageFixture.make(transparentLeftHalf: true), as: .png, to: input)

        try await ImageConverter.convert(input, to: output, format: .tiff)

        #expect(ImageFixture.pixel(of: output, x: 30, y: 40)?.a == 0)
    }

    @Test func maxPixelSizeShrinksTheLongestEdgeButNeverEnlarges() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("wide.png")
        try await ImageFixture.write(ImageFixture.make(width: 200, height: 100), as: .png, to: input)

        let smaller = scratch.file("smaller.jpg")
        try await ImageConverter.convert(input, to: smaller, format: .jpeg, options: ImageOptions(maxPixelSize: 100))
        #expect(ImageFixture.size(of: smaller)?.width == 100)
        #expect(ImageFixture.size(of: smaller)?.height == 50)

        let same = scratch.file("same.jpg")
        try await ImageConverter.convert(input, to: same, format: .jpeg, options: ImageOptions(maxPixelSize: 4000))
        #expect(ImageFixture.size(of: same)?.width == 200)
    }

    @Test func lowerQualityMakesASmallerJPEG() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("noise.png")
        try await ImageFixture.write(ImageFixture.make(width: 300, height: 200, noise: true), as: .png, to: input)
        let high = scratch.file("high.jpg")
        let low = scratch.file("low.jpg")

        try await ImageConverter.convert(input, to: high, format: .jpeg, options: ImageOptions(quality: 0.95))
        try await ImageConverter.convert(input, to: low, format: .jpeg, options: ImageOptions(quality: 0.2))

        #expect(fileSize(low) < fileSize(high))
    }

    @Test func colorProfileSurvivesConversion() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let input = scratch.file("p3.png")
        try await ImageFixture.write(ImageFixture.make(colorSpace: displayP3), as: .png, to: input)

        for format in [FileFormat.jpeg, .tiff, .heic] {
            let output = scratch.file("p3.\(format.fileExtension)")
            try await ImageConverter.convert(input, to: output, format: format)
            let profile = ImageFixture.properties(of: output)[kCGImagePropertyProfileName] as? String
            #expect(profile?.contains("P3") == true, "\(format.rawValue) lost the profile: \(profile ?? "none")")
        }
    }

    @Test func exifIsKeptWhenAskedAndGoneWhenNot() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("camera.jpg")
        let exif: [CFString: Any] = [kCGImagePropertyExifLensModel: "AcmeLens 35"]
        try await ImageFixture.write(ImageFixture.make(), as: .jpeg, to: input, properties: [kCGImagePropertyExifDictionary: exif])

        let kept = scratch.file("kept.heic")
        try await ImageConverter.convert(input, to: kept, format: .heic)
        let keptExif = ImageFixture.properties(of: kept)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(keptExif?[kCGImagePropertyExifLensModel] as? String == "AcmeLens 35")

        let dropped = scratch.file("dropped.heic")
        try await ImageConverter.convert(input, to: dropped, format: .heic, options: ImageOptions(keepsMetadata: false))
        let droppedExif = ImageFixture.properties(of: dropped)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(droppedExif?[kCGImagePropertyExifLensModel] == nil)
    }

    // MARK: Animation

    @Test func animatedGIFKeepsItsFramesAsGIF() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("anim.gif")
        let output = scratch.file("copy.gif")
        try await ImageFixture.writeAnimatedGIF(to: input, frames: 4)

        try await ImageConverter.convert(input, to: output, format: .gif)

        #expect(ImageFixture.frameCount(of: output) == 4)
    }

    // MARK: Safety

    @Test func outputCannotBeTheInput() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("same.png")
        try await ImageFixture.write(ImageFixture.make(), as: .png, to: input)
        let before = try Data(contentsOf: input)

        await #expect(throws: ConversionError.self) {
            try await ImageConverter.convert(input, to: input, format: .png)
        }
        // A different spelling of the same file is caught too.
        let shouting = scratch.file("SAME.png")
        await #expect(throws: ConversionError.self) {
            try await ImageConverter.convert(input, to: shouting, format: .png)
        }
        #expect(try Data(contentsOf: input) == before)
    }

    @Test func aFailedConversionLeavesNothingBehind() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("notes.png")
        try Data("this is text, not a picture".utf8).write(to: input)
        let output = scratch.file("out.jpg")

        await #expect(throws: ConversionError.self) {
            try await ImageConverter.convert(input, to: output, format: .jpeg)
        }
        #expect(scratch.contents == ["notes.png"])
    }

    @Test func nonImageTargetsAreRefused() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("a.png")
        try await ImageFixture.write(ImageFixture.make(), as: .png, to: input)

        await #expect(throws: ConversionError.self) {
            try await ImageConverter.convert(input, to: scratch.file("a.pdf"), format: .pdf)
        }
    }
}

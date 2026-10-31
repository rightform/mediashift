import ConversionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MediaEngine

@Suite struct ImageCompressionTests {
    /// A photo-like source: noisy, so it has plenty to squeeze.
    private func makeSource(_ format: FileFormat, in scratch: Scratch, width: Int = 320, height: Int = 240) async throws -> URL {
        let url = scratch.file("source.\(format.fileExtension)")
        try await ImageFixture.write(
            ImageFixture.make(width: width, height: height, noise: true), as: format, to: url, quality: 0.95
        )
        return url
    }

    @Test("Higher levels make smaller files", arguments: [FileFormat.jpeg, .heic])
    func levelsOrderBySize(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await makeSource(format, in: scratch)
        var sizes: [CompressionLevel: Int64] = [:]

        for level in CompressionLevel.allCases {
            let output = scratch.file("\(level.rawValue).\(format.fileExtension)")
            let shrunk = try await ImageConverter.compress(source, to: output, level: level)
            #expect(shrunk)
            sizes[level] = fileSize(output)
        }
        #expect(try #require(sizes[.strong]) < #require(sizes[.balanced]))
        #expect(try #require(sizes[.balanced]) < #require(sizes[.light]))
        #expect(try #require(sizes[.light]) < fileSize(source))
    }

    @Test(arguments: [FileFormat.jpeg, .heic, .avif, .tiff])
    func targetSizeIsMetFromBelow(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await makeSource(format, in: scratch)
        let target = fileSize(source) / 3
        let output = scratch.file("target.\(format.fileExtension)")

        let shrunk = try await ImageConverter.compress(source, to: output, level: .balanced, targetBytes: target)

        #expect(shrunk)
        #expect(fileSize(output) <= target)
        #expect(ImageFixture.format(of: output) == format)
    }

    @Test func targetSizeShrinksThePictureWhenQualityIsNotEnough() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await makeSource(.jpeg, in: scratch, width: 400, height: 300)
        let target: Int64 = 6_000
        let output = scratch.file("tiny.jpg")

        try await ImageConverter.compress(source, to: output, level: .strong, targetBytes: target)

        #expect(fileSize(output) <= target)
        #expect((ImageFixture.size(of: output)?.width ?? 400) < 400)
    }

    @Test func impossibleTargetsAreReportedPlainly() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await makeSource(.jpeg, in: scratch)
        let output = scratch.file("never.jpg")

        let error = await #expect(throws: ConversionError.self) {
            try await ImageConverter.compress(source, to: output, level: .strong, targetBytes: 40)
        }
        #expect(error?.message.contains("too small") == true)
        #expect(scratch.contents == [source.lastPathComponent])
    }

    @Test func nothingLargerThanTheSourceIsEverReturned() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A JPEG saved at very low quality is already tiny. Re-encoding it at 0.8 would make it bigger.
        let source = scratch.file("small.jpg")
        try await ImageFixture.write(ImageFixture.make(width: 300, height: 200, noise: true), as: .jpeg, to: source, quality: 0.02)
        let output = scratch.file("out.jpg")

        let shrunk = try await ImageConverter.compress(source, to: output, level: .light)

        #expect(!shrunk)
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
    }

    @Test func aTargetAboveTheSourceSizeCopiesTheSource() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try await makeSource(.jpeg, in: scratch)
        let output = scratch.file("copy.jpg")

        let shrunk = try await ImageConverter.compress(source, to: output, level: .strong, targetBytes: fileSize(source) + 10)

        #expect(!shrunk)
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
    }

    @Test func compressKeepsExifAndUprightness() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = scratch.file("photo.jpg")
        let exif: [CFString: Any] = [kCGImagePropertyExifLensModel: "AcmeLens 35"]
        try await ImageFixture.write(
            ImageFixture.make(width: 320, height: 240, noise: true), as: .jpeg, to: source,
            properties: [kCGImagePropertyOrientation: 6, kCGImagePropertyExifDictionary: exif], quality: 0.98
        )
        let output = scratch.file("out.jpg")

        try await ImageConverter.compress(source, to: output, level: .strong)

        let properties = ImageFixture.properties(of: output)
        let outExif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(outExif?[kCGImagePropertyExifLensModel] as? String == "AcmeLens 35")
        #expect(ImageFixture.size(of: output)?.width == 240)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test(.enabled(if: ffmpegAvailable))
    func webPCompressionUsesTheQualityDial() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = scratch.file("photo.webp")
        let png = scratch.file("noise.png")
        try await ImageFixture.write(ImageFixture.make(width: 320, height: 240, noise: true), as: .png, to: png)
        try makeFixture(["-i", png.path, "-c:v", "libwebp", "-quality", "95", source.path])

        let output = scratch.file("small.webp")
        let shrunk = try await ImageConverter.compress(source, to: output, level: .strong)
        #expect(shrunk)
        #expect(fileSize(output) < fileSize(source))

        let targeted = scratch.file("targeted.webp")
        let target = fileSize(source) / 3
        try await ImageConverter.compress(source, to: targeted, level: .balanced, targetBytes: target)
        #expect(fileSize(targeted) <= target)
        #expect(ImageFixture.format(of: targeted) == .webp)
    }

    @Test(.enabled(if: ffmpegAvailable), arguments: [CompressionLevel.balanced, .strong])
    func pngCompressionReducesColors(level: CompressionLevel) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A photo-like PNG with a color for nearly every pixel. A palette of 256 or fewer is a third of its size.
        let source = scratch.file("photo.png")
        try await ImageFixture.write(ImageFixture.make(width: 400, height: 300, noise: true), as: .png, to: source)

        let output = scratch.file("small.png")
        let shrunk = try await ImageConverter.compress(source, to: output, level: level)

        #expect(shrunk)
        #expect(fileSize(output) < fileSize(source))
        #expect(ImageFixture.format(of: output) == .png)
        #expect(ImageFixture.size(of: output)?.width == 400)
    }

    @Test(.enabled(if: ffmpegAvailable))
    func gifCompressionKeepsTheAnimation() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = scratch.file("anim.gif")
        try makeFixture(["-f", "lavfi", "-i", "testsrc2=size=240x180:rate=10:duration=2", source.path])

        let output = scratch.file("small.gif")
        let shrunk = try await ImageConverter.compress(source, to: output, level: .strong)

        #expect(shrunk)
        #expect(ImageFixture.frameCount(of: output) == ImageFixture.frameCount(of: source))
        #expect((ImageFixture.size(of: output)?.width ?? 240) < 240)

        let targeted = scratch.file("targeted.gif")
        let target = fileSize(source) / 2
        try await ImageConverter.compress(source, to: targeted, level: .light, targetBytes: target)
        #expect(fileSize(targeted) <= target)
    }
}

@Suite struct ImagePDFTests {
    @Test func onePagePerImageSizedToTheImage() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let first = scratch.file("a.png")
        let second = scratch.file("b.jpg")
        let third = scratch.file("c.jpg")
        try await ImageFixture.write(ImageFixture.make(width: 200, height: 100), as: .png, to: first)
        try await ImageFixture.write(ImageFixture.make(width: 90, height: 120), as: .jpeg, to: second)
        // Stored sideways, shown upright: 96 by 64 on disk, 64 by 96 on the page.
        try await ImageFixture.write(ImageFixture.make(), as: .jpeg, to: third, properties: [kCGImagePropertyOrientation: 6])
        let output = scratch.file("images.pdf")

        try await ImageConverter.makePDF(from: [first, second, third], to: output)

        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(document.numberOfPages == 3)
        let sizes = (1 ... 3).compactMap { document.page(at: $0)?.getBoxRect(.mediaBox).size }
        #expect(sizes.count == 3)
        #expect(sizes[0] == CGSize(width: 200, height: 100))
        #expect(sizes[1] == CGSize(width: 90, height: 120))
        #expect(sizes[2] == CGSize(width: 64, height: 96))
    }

    @Test func dpiSetsThePhysicalPageSize() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let scan = scratch.file("scan.jpg")
        try await ImageFixture.write(
            ImageFixture.make(width: 300, height: 600), as: .jpeg, to: scan,
            properties: [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300]
        )
        let output = scratch.file("scan.pdf")

        try await ImageConverter.makePDF(from: [scan], to: output)

        let document = try #require(CGPDFDocument(output as CFURL))
        let size = try #require(document.page(at: 1)?.getBoxRect(.mediaBox).size)
        #expect(abs(size.width - 72) < 1 && abs(size.height - 144) < 1)
    }

    @Test func nothingToDoAndUnreadableInputsAreErrors() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let output = scratch.file("none.pdf")
        await #expect(throws: ConversionError.self) {
            try await ImageConverter.makePDF(from: [], to: output)
        }

        let notAnImage = scratch.file("text.png")
        try Data("hello".utf8).write(to: notAnImage)
        await #expect(throws: ConversionError.self) {
            try await ImageConverter.makePDF(from: [notAnImage], to: output)
        }
        #expect(scratch.contents == ["text.png"])
    }
}

@Suite(.enabled(if: ffmpegAvailable)) struct WebPEncodingTests {
    @Test func stillImagesBecomeRealWebPFiles() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("photo.png")
        try await ImageFixture.write(ImageFixture.make(width: 160, height: 120), as: .png, to: input)
        let output = scratch.file("photo.webp")

        try await ImageConverter.convert(input, to: output, format: .webp)

        let bytes = try Data(contentsOf: output)
        #expect(bytes.prefix(4) == Data("RIFF".utf8))
        #expect(bytes.subdata(in: 8 ..< 12) == Data("WEBP".utf8))
        #expect(ImageFixture.format(of: output) == .webp)
        #expect(isNear(ImageFixture.pixel(of: output, x: 130, y: 100), 26, 26, 204))
    }

    @Test func qualityChangesTheSize() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("noise.png")
        try await ImageFixture.write(ImageFixture.make(width: 200, height: 150, noise: true), as: .png, to: input)
        let high = scratch.file("high.webp")
        let low = scratch.file("low.webp")

        try await ImageConverter.convert(input, to: high, format: .webp, options: ImageOptions(quality: 0.95))
        try await ImageConverter.convert(input, to: low, format: .webp, options: ImageOptions(quality: 0.1))

        #expect(fileSize(low) < fileSize(high))
    }

    @Test func transparencySurvivesTheTripleHop() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("alpha.png")
        try await ImageFixture.write(ImageFixture.make(transparentLeftHalf: true), as: .png, to: input)
        let output = scratch.file("alpha.webp")

        try await ImageConverter.convert(input, to: output, format: .webp)

        #expect(ImageFixture.pixel(of: output, x: 20, y: 40)?.a == 0)
        #expect(ImageFixture.pixel(of: output, x: 80, y: 40)?.a == 255)
    }

    @Test func animatedGIFKeepsItsAnimationAsWebP() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("anim.gif")
        try await ImageFixture.writeAnimatedGIF(to: input, frames: 4)
        let output = scratch.file("anim.webp")

        try await ImageConverter.convert(input, to: output, format: .webp)

        let bytes = try Data(contentsOf: output)
        var frames = 0
        var searchFrom = bytes.startIndex
        while let range = bytes.range(of: Data("ANMF".utf8), in: searchFrom ..< bytes.endIndex) {
            frames += 1
            searchFrom = range.upperBound
        }
        #expect(bytes.range(of: Data("ANIM".utf8)) != nil)
        #expect(frames == 4)
    }

    @Test func maxPixelSizeAppliesToWebPToo() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("wide.png")
        try await ImageFixture.write(ImageFixture.make(width: 300, height: 150), as: .png, to: input)
        let output = scratch.file("wide.webp")

        try await ImageConverter.convert(input, to: output, format: .webp, options: ImageOptions(maxPixelSize: 100))

        #expect(ImageFixture.size(of: output)?.width == 100)
        #expect(ImageFixture.size(of: output)?.height == 50)
    }
}

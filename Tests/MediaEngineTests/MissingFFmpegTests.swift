import ConversionCore
import Foundation
import Testing
@testable import MediaEngine

/// These only run on a machine without ffmpeg, which is exactly when they matter.
@Suite(.enabled(if: !ffmpegAvailable)) struct MissingFFmpegTests {
    @Test func mediaConversionExplainsWhatIsMissing() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try Data("not really a video".utf8).write(to: input)

        let error = await #expect(throws: ConversionError.self) {
            try await MediaConverter.convert(input, to: scratch.file("clip.mov"), format: .mov)
        }
        #expect(error?.message == "ffmpeg was not found. Run scripts/build-ffmpeg.sh to build it.")
        #expect(scratch.contents == ["clip.mp4"])
    }

    @Test func webPNeedsFFmpegButOtherImagesDoNot() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("photo.png")
        try await ImageFixture.write(ImageFixture.make(), as: .png, to: input)

        try await ImageConverter.convert(input, to: scratch.file("photo.jpg"), format: .jpeg)

        let error = await #expect(throws: ConversionError.self) {
            try await ImageConverter.convert(input, to: scratch.file("photo.webp"), format: .webp)
        }
        #expect(error?.message.contains("ffmpeg was not found") == true)
        #expect(scratch.contents == ["photo.jpg", "photo.png"])
    }
}

@Suite struct FFmpegLocatorTests {
    @Test func foundBinariesAreExecutableFiles() throws {
        guard let url = FFmpegLocator.find() else { return }
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(!url.hasDirectoryPath)
    }
}

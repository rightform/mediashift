import ConversionCore
import Foundation
import Testing
@testable import MediaEngine

@Suite(.enabled(if: ffmpegAvailable)) struct MediaCompressionTests {
    /// A video with a generous bitrate, so there is something to take away.
    private func makeSource(
        _ name: String = "source.mp4",
        in scratch: Scratch,
        size: String = "640x360",
        seconds: Int = 6,
        bitrate: String = "4M",
        audio: Bool = true
    ) throws -> URL {
        let url = scratch.file(name)
        let video = url.pathExtension == "webm"
            ? ["-c:v", "libvpx-vp9", "-b:v", bitrate, "-deadline", "realtime", "-cpu-used", "8"]
            : ["-c:v", "h264_videotoolbox", "-b:v", bitrate]
        let sound = url.pathExtension == "webm" ? ["-c:a", "libopus", "-b:a", "128k"] : ["-c:a", "aac", "-b:a", "128k"]
        var arguments = ["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=\(seconds)"]
        if audio {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"]
        }
        try makeFixture(arguments + video + (audio ? sound : ["-an"]) + ["-pix_fmt", "yuv420p", url.path])
        return url
    }

    // MARK: By level

    @Test func levelsShrinkVideoAndPreferHEVC() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeSource(in: scratch)
        var sizes: [CompressionLevel: Int64] = [:]

        for level in CompressionLevel.allCases {
            let output = scratch.file("\(level.rawValue).mp4")
            try await MediaConverter.compress(source, to: output, level: level)
            sizes[level] = fileSize(output)
            let info = try mediaInfo(output)
            #expect(info.mainVideo?.codec == "hevc")
            #expect(try runFFmpeg(["-i", output.path]).output.contains("hvc1"))
            #expect(info.audioStreams.first?.codec == "aac")
        }
        #expect(try #require(sizes[.strong]) < #require(sizes[.balanced]))
        #expect(try #require(sizes[.balanced]) < #require(sizes[.light]))
        #expect(try #require(sizes[.light]) < fileSize(source))
    }

    @Test func movAlsoGetsHEVCButWebMGetsVP9() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeSource(in: scratch, seconds: 3)

        let mov = scratch.file("out.mov")
        try await MediaConverter.compress(source, to: mov, level: .balanced)
        #expect(try mediaInfo(mov).mainVideo?.codec == "hevc")

        let webm = scratch.file("out.webm")
        try await MediaConverter.compress(source, to: webm, level: .balanced)
        let info = try mediaInfo(webm)
        #expect(info.mainVideo?.codec == "vp9")
        #expect(info.audioStreams.first?.codec == "opus")
        #expect(fileSize(webm) < fileSize(source))
    }

    @Test func aFileThatCannotGetSmallerIsKeptAsIs() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // Voice memo quality Opus at 8 kbit/s. The lowest rate this engine writes is 16, so a re-encode is bigger.
        let source = try makeAudio("memo.opus", in: scratch, seconds: 5, extra: ["-c:a", "libopus", "-b:a", "8k"])
        let output = scratch.file("kept.opus")

        try await MediaConverter.compress(source, to: output, level: .strong)

        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
        #expect(scratch.contents.count == 2)
    }

    // MARK: By size

    @Test func targetSizeLandsWithinTenPercentUnder() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeSource(in: scratch)
        let target = fileSize(source) * 2 / 5
        let output = scratch.file("target.mp4")

        try await MediaConverter.compress(source, to: output, level: .balanced, targetBytes: target)

        let size = fileSize(output)
        #expect(size <= target, "\(size) is over the target \(target)")
        #expect(Double(size) >= Double(target) * 0.9, "\(size) is more than 10 percent under \(target)")
        #expect(try mediaInfo(output).mainVideo?.codec == "hevc")
        #expect(scratch.contents.count == 2, "leftover files: \(scratch.contents)")
    }

    @Test func targetSizeWorksForWebMToo() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeSource("source.webm", in: scratch, seconds: 5, bitrate: "3M")
        let target = fileSize(source) / 2
        let output = scratch.file("target.webm")

        try await MediaConverter.compress(source, to: output, level: .balanced, targetBytes: target)

        let size = fileSize(output)
        #expect(size <= target, "\(size) is over the target \(target)")
        #expect(Double(size) >= Double(target) * 0.8, "\(size) is far under \(target)")
    }

    @Test func absurdlySmallTargetsAreRefusedWithAHint() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeSource(in: scratch, seconds: 3)

        let error = await #expect(throws: ConversionError.self) {
            try await MediaConverter.compress(source, to: scratch.file("tiny.mp4"), level: .strong, targetBytes: 3_000)
        }
        let message = try #require(error?.message)
        #expect(message.hasPrefix("The target size is too small for this video. Try at least"))
        #expect(scratch.contents == ["source.mp4"])
    }

    @Test func aTargetAboveTheSourceSizeKeepsTheSource() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeSource(in: scratch, seconds: 3)
        let output = scratch.file("same.mp4")

        try await MediaConverter.compress(source, to: output, level: .strong, targetBytes: fileSize(source) + 1000)

        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
    }

    @Test func targetProgressStaysInRangeAndEndsAtOne() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeSource(in: scratch, seconds: 4)
        let log = ProgressLog()

        try await MediaConverter.compress(
            source, to: scratch.file("p.mp4"), level: .balanced, targetBytes: fileSize(source) / 3, progress: log.handler
        )

        let values = log.values
        #expect(values.last == 1)
        #expect(values == values.sorted())
        #expect(values.allSatisfy { (0 ... 1).contains($0) })
    }

    // MARK: Audio

    private func makeAudio(_ name: String, in scratch: Scratch, seconds: Int = 20, extra: [String]) throws -> URL {
        let url = scratch.file(name)
        try makeFixture(
            ["-f", "lavfi", "-i", "anoisesrc=duration=\(seconds):color=pink:sample_rate=44100:amplitude=0.3", "-ac", "2"]
                + extra + [url.path]
        )
        return url
    }

    @Test func audioLevelsShrinkMP3() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeAudio("song.mp3", in: scratch, extra: ["-c:a", "libmp3lame", "-b:a", "320k"])
        var sizes: [CompressionLevel: Int64] = [:]

        for level in CompressionLevel.allCases {
            let output = scratch.file("\(level.rawValue).mp3")
            try await MediaConverter.compress(source, to: output, level: level)
            sizes[level] = fileSize(output)
        }
        #expect(try #require(sizes[.strong]) < #require(sizes[.balanced]))
        #expect(try #require(sizes[.balanced]) < #require(sizes[.light]))
        #expect(try #require(sizes[.light]) < fileSize(source))
    }

    @Test(arguments: [FileFormat.mp3, .m4a, .opus, .ogg])
    func audioTargetSizeIsMetFromBelow(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let encoder = ["mp3": "libmp3lame", "m4a": "aac", "opus": "libopus", "ogg": "libvorbis"][format.rawValue] ?? "aac"
        let source = try makeAudio("song.\(format.fileExtension)", in: scratch, extra: ["-c:a", encoder, "-b:a", "256k"])
        let target = fileSize(source) / 2
        let output = scratch.file("target.\(format.fileExtension)")

        try await MediaConverter.compress(source, to: output, level: .balanced, targetBytes: target)

        let size = fileSize(output)
        #expect(size <= target, "\(size) is over \(target)")
        #expect(Double(size) >= Double(target) * 0.85, "\(size) is far under \(target)")
    }

    @Test func losslessAudioCannotAimAtASize() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeAudio("song.wav", in: scratch, seconds: 3, extra: [])

        let error = await #expect(throws: ConversionError.self) {
            try await MediaConverter.compress(source, to: scratch.file("small.wav"), level: .strong, targetBytes: 10_000)
        }
        #expect(error?.message.contains("lossless") == true)
    }

    @Test func highResolutionWavDropsToSixteenBits() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = try makeAudio("studio.wav", in: scratch, seconds: 4, extra: ["-c:a", "pcm_s24le"])
        let output = scratch.file("small.wav")

        try await MediaConverter.compress(source, to: output, level: .light)

        #expect(fileSize(output) < fileSize(source))
        #expect(try mediaInfo(output).audioStreams.first?.codec == "pcm_s16le")
    }
}

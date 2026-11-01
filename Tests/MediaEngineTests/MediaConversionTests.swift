import ConversionCore
import Foundation
import ImageIO
import Testing
@testable import MediaEngine

/// Collects progress reports from any thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var handler: ProgressHandler {
        { [self] value in lock.withLock { recorded.append(value) } }
    }

    var values: [Double] {
        lock.withLock { recorded }
    }
}

/// True when the movie header comes before the media data, so playback can start before the download ends.
func hasFastStart(_ url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var offset: UInt64 = 0
    while let header = try handle.read(upToCount: 8), header.count == 8 {
        let type = String(decoding: header[4 ..< 8], as: UTF8.self)
        if type == "moov" { return true }
        if type == "mdat" { return false }
        var size = header[0 ..< 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        if size == 1, let extended = try handle.read(upToCount: 8), extended.count == 8 {
            size = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            offset += 8
        }
        guard size >= 8 else { return false }
        offset += size
        try handle.seek(toOffset: offset)
    }
    return false
}

struct VideoPair: Sendable, CustomTestStringConvertible {
    var from: FileFormat
    var to: FileFormat

    var testDescription: String { "\(from.rawValue) to \(to.rawValue)" }

    static let containers: [FileFormat] = [.mp4, .mov, .m4v, .mkv, .webm, .avi]
    static let all: [VideoPair] = containers.flatMap { from in containers.map { VideoPair(from: from, to: $0) } }
}

@Suite(.enabled(if: ffmpegAvailable)) struct MediaConversionTests {
    // MARK: Video containers

    @Test("Every video container converts into every other", .enabled(if: videoEncoderAvailable), arguments: VideoPair.all)
    func containerMatrix(_ pair: VideoPair) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("input.\(pair.from.fileExtension)")
        let output = scratch.file("output.\(pair.to.fileExtension)")
        try VideoFixture.make(at: input, seconds: 2)

        try await MediaConverter.convert(input, to: output, format: pair.to)

        let info = try mediaInfo(output)
        let rules = try #require(ContainerRules.of(pair.to))
        let video = try #require(info.mainVideo)
        let audio = try #require(info.audioStreams.first)
        #expect(rules.acceptsVideo(video.codec), "\(video.codec) does not belong in \(pair.to.rawValue)")
        #expect(rules.acceptsAudio(audio.codec), "\(audio.codec) does not belong in \(pair.to.rawValue)")
        #expect(video.width == 320 && video.height == 240)
        #expect(abs((info.duration ?? 0) - 2) < 0.5)
        #expect(scratch.contents.count == 2)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func mp4ToMovCopiesTheStreamsAndStartsFast() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        let output = scratch.file("clip.mov")
        try VideoFixture.make(at: input)

        try await MediaConverter.convert(input, to: output, format: .mov)

        #expect(try streamHash(input, map: "0:v:0") == streamHash(output, map: "0:v:0"))
        #expect(try streamHash(input, map: "0:a:0") == streamHash(output, map: "0:a:0"))
        #expect(try hasFastStart(output))
        let log = try runFFmpeg(["-i", output.path]).output
        #expect(log.contains("Input #0, mov,mp4"))
    }

    @Test(.enabled(if: videoEncoderAvailable)) func mp4ToMkvCopiesTheStreams() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        let output = scratch.file("clip.mkv")
        try VideoFixture.make(at: input)

        try await MediaConverter.convert(input, to: output, format: .mkv)

        #expect(try streamHash(input, map: "0:v:0") == streamHash(output, map: "0:v:0"))
        #expect(try streamHash(input, map: "0:a:0") == streamHash(output, map: "0:a:0"))
        #expect(try runFFmpeg(["-i", output.path]).output.contains("Input #0, matroska,webm"))
    }

    @Test(.enabled(if: videoEncoderAvailable)) func mp4ToWebMBecomesVP9AndOpus() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        let output = scratch.file("clip.webm")
        try VideoFixture.make(at: input)

        try await MediaConverter.convert(input, to: output, format: .webm)

        let info = try mediaInfo(output)
        #expect(info.mainVideo?.codec == "vp9")
        #expect(info.audioStreams.first?.codec == "opus")
        #expect(info.audioStreams.first?.sampleRate == 48000)
        #expect(abs((info.duration ?? 0) - 3) < 0.5)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func hevcKeepsTheAppleTagInMP4() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mkv")
        let output = scratch.file("clip.mp4")
        try VideoFixture.make(at: input, videoCodec: "hevc_videotoolbox")

        try await MediaConverter.convert(input, to: output, format: .mp4)

        #expect(try mediaInfo(output).mainVideo?.codec == "hevc")
        #expect(try runFFmpeg(["-i", output.path]).output.contains("hvc1"))
        #expect(try streamHash(input, map: "0:v:0") == streamHash(output, map: "0:v:0"))
    }

    @Test(.enabled(if: videoEncoderAvailable)) func oddSizesDoNotBreakH264() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("odd.webm")
        let output = scratch.file("odd.mp4")
        // The test pattern rounds to even sizes by itself. Cropping with exact=1 forces odd ones.
        try makeFixture([
            "-f", "lavfi", "-i", "testsrc2=size=322x242:rate=25:duration=2", "-vf", "crop=321:241:0:0:exact=1",
            "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-deadline", "realtime", "-cpu-used", "8", input.path,
        ])
        #expect(try mediaInfo(input).mainVideo?.width == 321)

        try await MediaConverter.convert(input, to: output, format: .mp4)

        let video = try #require(mediaInfo(output).mainVideo)
        #expect(video.codec == "h264")
        #expect(video.width == 320 && video.height == 240)
        #expect(video.pixelFormat == "yuv420p")
    }

    @Test(.enabled(if: videoEncoderAvailable)) func wideCompatibilityPixelFormatForTenBitSources() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("tenbit.mkv")
        let output = scratch.file("tenbit.mp4")
        try makeFixture([
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2", "-an",
            "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p10le", "-deadline", "realtime", "-cpu-used", "8", input.path,
        ])

        try await MediaConverter.convert(input, to: output, format: .mp4)

        #expect(try mediaInfo(output).mainVideo?.pixelFormat == "yuv420p")
    }

    // MARK: Subtitles

    private func makeSubtitledMP4(in scratch: Scratch) throws -> URL {
        let plain = scratch.file("plain.mp4")
        try VideoFixture.make(at: plain, seconds: 3)
        let subtitles = scratch.file("lines.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,500\nHello\n\n2\n00:00:01,500 --> 00:00:03,000\nWorld\n".utf8).write(to: subtitles)
        let input = scratch.file("subtitled.mp4")
        try makeFixture([
            "-i", plain.path, "-i", subtitles.path, "-map", "0", "-map", "1", "-c", "copy", "-c:s", "mov_text", input.path,
        ])
        #expect(try mediaInfo(input).subtitleStreams.count == 1)
        return input
    }

    @Test(.enabled(if: videoEncoderAvailable), arguments: [FileFormat.mkv, .mov, .webm])
    func subtitlesAreKeptWhereTheContainerAllowsThem(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = try makeSubtitledMP4(in: scratch)
        let output = scratch.file("out.\(format.fileExtension)")

        try await MediaConverter.convert(input, to: output, format: format)

        #expect(try mediaInfo(output).subtitleStreams.count == 1)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func subtitlesNeverStopAConversion() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = try makeSubtitledMP4(in: scratch)
        let output = scratch.file("out.avi")

        try await MediaConverter.convert(input, to: output, format: .avi)

        let info = try mediaInfo(output)
        #expect(info.subtitleStreams.isEmpty)
        #expect(info.mainVideo != nil)
    }

    // MARK: GIF

    @Test(.enabled(if: videoEncoderAvailable)) func videoToGifIsAtMost720WideAt15FramesAPlace() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("wide.mp4")
        let output = scratch.file("wide.gif")
        try VideoFixture.make(at: input, size: "1000x500", seconds: 2, audio: false)

        try await MediaConverter.convert(input, to: output, format: .gif)

        #expect(ImageFixture.format(of: output) == .gif)
        #expect(ImageFixture.size(of: output)?.width == 720)
        #expect(ImageFixture.size(of: output)?.height == 360)
        // Two seconds at 15 frames a second.
        #expect((29 ... 31).contains(ImageFixture.frameCount(of: output)))
    }

    @Test(.enabled(if: videoEncoderAvailable)) func smallVideosAreNotEnlargedForGif() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("small.mp4")
        let output = scratch.file("small.gif")
        try VideoFixture.make(at: input, size: "320x240", seconds: 1, audio: false)

        try await MediaConverter.convert(input, to: output, format: .gif)

        #expect(ImageFixture.size(of: output)?.width == 320)
    }

    // MARK: Audio

    @Test("Video to audio extracts the sound", .enabled(if: videoEncoderAvailable), arguments: [
        (FileFormat.mp3, "mp3"), (.m4a, "aac"), (.ogg, "vorbis"), (.opus, "opus"), (.flac, "flac"), (.wav, "pcm_s16le"), (.aiff, "pcm_s16be"),
    ])
    func extractsAudio(format: FileFormat, codec: String) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        let output = scratch.file("sound.\(format.fileExtension)")
        try VideoFixture.make(at: input)

        try await MediaConverter.convert(input, to: output, format: format)

        let info = try mediaInfo(output)
        #expect(info.mainVideo == nil)
        #expect(info.audioStreams.first?.codec == codec)
        #expect(abs((info.duration ?? 0) - 3) < 0.5)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func extractingAACIsALosslessCopy() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        let output = scratch.file("sound.m4a")
        try VideoFixture.make(at: input)

        try await MediaConverter.convert(input, to: output, format: .m4a)

        #expect(try streamHash(input, map: "0:a:0") == streamHash(output, map: "0:a:0"))
    }

    @Test(arguments: [FileFormat.mp3, .m4a, .ogg, .opus, .flac, .aiff])
    func audioToAudio(format: FileFormat) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("tone.wav")
        let output = scratch.file("tone.\(format.fileExtension)")
        try makeFixture(["-f", "lavfi", "-i", "sine=frequency=440:duration=3:sample_rate=44100", "-ac", "2", input.path])

        try await MediaConverter.convert(input, to: output, format: format)

        let audio = try #require(mediaInfo(output).audioStreams.first)
        #expect(audio.channels == 2)
        if format == .opus {
            #expect(audio.sampleRate == 48000)
        }
    }

    @Test func opusResamplesLowRatesProperly() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("phone.wav")
        let output = scratch.file("phone.opus")
        try makeFixture(["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=22050", "-ac", "1", input.path])

        try await MediaConverter.convert(input, to: output, format: .opus)

        let audio = try #require(mediaInfo(output).audioStreams.first)
        #expect(audio.codec == "opus")
        #expect(audio.sampleRate == 48000)
        #expect(abs((try mediaInfo(output).duration ?? 0) - 2) < 0.3)
    }

    @Test func highResolutionAudioFitsMP3() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("studio.flac")
        let output = scratch.file("studio.mp3")
        try makeFixture(["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=96000", "-ac", "2", "-sample_fmt", "s32", input.path])

        try await MediaConverter.convert(input, to: output, format: .mp3)

        #expect(try mediaInfo(output).audioStreams.first?.sampleRate == 48000)
    }

    @Test func coverArtTravelsToMP3() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let cover = scratch.file("cover.jpg")
        try await ImageFixture.write(ImageFixture.make(width: 200, height: 200), as: .jpeg, to: cover)
        let input = scratch.file("album.mp3")
        try makeFixture([
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-i", cover.path, "-map", "0", "-map", "1",
            "-c:a", "libmp3lame", "-c:v", "copy", "-id3v2_version", "3", "-disposition:v:0", "attached_pic", input.path,
        ])
        let output = scratch.file("album.m4a")

        try await MediaConverter.convert(input, to: output, format: .m4a)

        #expect(try mediaInfo(output).attachedPicture != nil)
    }

    // MARK: Errors

    @Test(.enabled(if: videoEncoderAvailable)) func aVideoWithoutSoundCannotBecomeAnAudioFile() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("silent.mp4")
        let output = scratch.file("silent.mp3")
        try VideoFixture.make(at: input, audio: false)

        let error = await #expect(throws: ConversionError.self) {
            try await MediaConverter.convert(input, to: output, format: .mp3)
        }
        #expect(error?.message == "This file has no audio.")
        #expect(scratch.contents == ["silent.mp4"])
    }

    @Test func outputCannotBeTheInput() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input)
        let before = try Data(contentsOf: input)

        await #expect(throws: ConversionError.self) {
            try await MediaConverter.convert(input, to: input, format: .mp4)
        }
        await #expect(throws: ConversionError.self) {
            try await MediaConverter.stripMetadata(input, to: input)
        }
        await #expect(throws: ConversionError.self) {
            try await MediaConverter.compress(input, to: input, level: .strong)
        }
        #expect(try Data(contentsOf: input) == before)
    }

    @Test func missingAndBrokenInputsGetShortMessages() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let missing = await #expect(throws: ConversionError.self) {
            try await MediaConverter.convert(scratch.file("nope.mp4"), to: scratch.file("out.mov"), format: .mov)
        }
        #expect(missing?.message == "The input file could not be found.")

        let broken = scratch.file("broken.mp4")
        try Data("this is not a video".utf8).write(to: broken)
        let error = await #expect(throws: ConversionError.self) {
            try await MediaConverter.convert(broken, to: scratch.file("out.mov"), format: .mov)
        }
        let message = try #require(error?.message)
        #expect(message.hasPrefix("This file could not be read"))
        #expect(!message.contains("!") && !message.contains("\u{2014}") && !message.contains("\u{2013}"))
        #expect(scratch.contents == ["broken.mp4"])
    }

    @Test(.enabled(if: videoEncoderAvailable)) func audioFormatsAreRefusedAsVideoTargetsWithoutFuss() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input)

        await #expect(throws: ConversionError.self) {
            try await MediaConverter.convert(input, to: scratch.file("out.pdf"), format: .pdf)
        }
        #expect(scratch.contents == ["clip.mp4"])
    }

    // MARK: Progress

    @Test(.enabled(if: videoEncoderAvailable)) func progressClimbsAndEndsAtOne() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        let output = scratch.file("clip.webm")
        try VideoFixture.make(at: input, size: "640x360", seconds: 6)
        let log = ProgressLog()

        try await MediaConverter.convert(input, to: output, format: .webm, progress: log.handler)

        let values = log.values
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0 ... 1).contains($0) })
        #expect(values == values.sorted(), "progress went backwards: \(values)")
        #expect(values.count >= 3, "expected several reports, got \(values)")
        // Only the very last report may be 1.
        #expect(values.dropLast().allSatisfy { $0 < 1 })
    }

    @Test func progressEndsAtOneForACopyToo() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input)
        let log = ProgressLog()

        try await MediaConverter.convert(input, to: scratch.file("clip.mov"), format: .mov, progress: log.handler)

        #expect(log.values.last == 1)
    }

    @Test func progressDoesNotReachOneWhenTheConversionFails() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("silent.mp4")
        try VideoFixture.make(at: input, audio: false)
        let log = ProgressLog()

        await #expect(throws: ConversionError.self) {
            try await MediaConverter.convert(input, to: scratch.file("x.mp3"), format: .mp3, progress: log.handler)
        }
        #expect(!log.values.contains(1))
    }

    // MARK: Metadata

    @Test(.enabled(if: videoEncoderAvailable)) func stripRemovesTagsWithoutReencoding() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("home.mp4")
        let output = scratch.file("clean.mp4")
        try VideoFixture.make(at: input, extra: [
            "-metadata", "title=SecretTitle", "-metadata", "comment=SecretComment",
            "-metadata:s:v:0", "title=SecretVideo", "-metadata:s:a:0", "language=pol",
        ])
        let before = try Data(contentsOf: input)
        #expect(before.range(of: Data("SecretTitle".utf8)) != nil, "the fixture should carry the tag")

        try await MediaConverter.stripMetadata(input, to: output)

        let after = try Data(contentsOf: output)
        for secret in ["SecretTitle", "SecretComment", "SecretVideo", "Lavf"] {
            #expect(after.range(of: Data(secret.utf8)) == nil, "found \(secret)")
        }
        #expect(try streamHash(input, map: "0:v:0") == streamHash(output, map: "0:v:0"))
        #expect(try streamHash(input, map: "0:a:0") == streamHash(output, map: "0:a:0"))
        #expect(try hasFastStart(output))
    }

    @Test func stripWorksOnAudioFiles() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("song.mp3")
        let output = scratch.file("clean.mp3")
        try makeFixture([
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "libmp3lame",
            "-metadata", "artist=SecretArtist", "-metadata", "title=SecretSong", input.path,
        ])

        try await MediaConverter.stripMetadata(input, to: output)

        let after = try Data(contentsOf: output)
        #expect(after.range(of: Data("Secret".utf8)) == nil)
        #expect(try streamHash(input, map: "0:a:0") == streamHash(output, map: "0:a:0"))
    }

    @Test(.enabled(if: videoEncoderAvailable)) func stripKeepsSubtitlesAndSecondaryStreams() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = try makeSubtitledMP4(in: scratch)
        let output = scratch.file("clean.mp4")

        try await MediaConverter.stripMetadata(input, to: output)

        #expect(try mediaInfo(output).subtitleStreams.count == 1)
    }
}

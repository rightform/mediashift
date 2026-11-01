import ConversionCore
import Foundation
import Testing
@testable import MediaEngine

private let capabilities = MediaCapabilities(encoders: [
    "h264_videotoolbox", "hevc_videotoolbox", "libvpx-vp9", "aac_at", "aac", "libopus", "libmp3lame",
    "libvorbis", "flac", "mpeg4",
])

private func info(
    video: String? = "h264",
    audio: String? = "aac",
    width: Int = 1920,
    height: Int = 1080,
    audioBitrate: Int? = 128_000
) -> MediaInfo {
    var streams: [MediaInfo.Stream] = []
    if let video {
        streams.append(MediaInfo.Stream(
            index: 0, kind: .video, codec: video, width: width, height: height, frameRate: 30,
            bitrate: 4_000_000, pixelFormat: "yuv420p"
        ))
    }
    if let audio {
        streams.append(MediaInfo.Stream(
            index: streams.count, kind: .audio, codec: audio, bitrate: audioBitrate, sampleRate: 44100, channels: 2
        ))
    }
    return MediaInfo(duration: 10, bitrate: 4_200_000, streams: streams)
}

private func text(_ info: MediaInfo, to format: FileFormat, _ options: MediaOptions = MediaOptions()) throws -> String {
    let lists = try MediaPlan.convert(info, to: format, capabilities: capabilities, options: options)
    return try #require(lists.first).joined(separator: " ")
}

@Suite struct MediaOptionPlanTests {
    @Test func theDefaultsChangeNothing() throws {
        let plain = try MediaPlan.convert(info(), to: .mov, capabilities: capabilities)
        let explicit = try MediaPlan.convert(info(), to: .mov, capabilities: capabilities, options: MediaOptions())
        #expect(plain == explicit)
        #expect(try text(info(), to: .mov).contains("-c:v:0 copy"))
    }

    // MARK: Codec

    @Test func aNamedCodecIsWhatComesOut() throws {
        let hevc = MediaOptions(videoCodec: .hevc)
        #expect(try text(info(), to: .mp4, hevc).contains("-c:v:0 hevc_videotoolbox"))
        #expect(try text(info(video: "hevc"), to: .mov, hevc).contains("-c:v:0 copy"))

        let h264 = MediaOptions(videoCodec: .h264)
        #expect(try text(info(video: "hevc"), to: .mp4, h264).contains("-c:v:0 h264_videotoolbox"))
        #expect(try text(info(), to: .mkv, h264).contains("-c:v:0 copy"))
    }

    @Test(arguments: [(FileFormat.webm, "libvpx-vp9"), (.m4v, "h264_videotoolbox")])
    func containersWithoutAChoiceKeepTheirCodec(format: FileFormat, encoder: String) throws {
        let lists = try MediaPlan.convert(info(video: "mpeg4"), to: format, capabilities: capabilities, options: MediaOptions(videoCodec: .hevc))
        #expect(try #require(lists.last).joined(separator: " ").contains("-c:v:0 \(encoder)"))
    }

    @Test func compressionFollowsANamedCodec() throws {
        let compression = VideoPlan.Compression(level: .balanced, videoBitrate: nil, audioBitrate: 128_000)
        let automatic = try VideoPlan(info: info(), format: .mp4, capabilities: capabilities, compression: compression)
        #expect(automatic.targetFamily == .hevc)
        let h264 = try VideoPlan(info: info(), format: .mp4, capabilities: capabilities, compression: compression, options: MediaOptions(videoCodec: .h264))
        #expect(h264.targetFamily == .h264)
    }

    // MARK: Quality

    @Test(arguments: [(VideoQuality.smaller, "48"), (.standard, "62"), (.higher, "75")])
    func qualityMovesTheEncoderDial(quality: VideoQuality, value: String) throws {
        let options = MediaOptions(videoCodec: .h264, videoQuality: quality)
        #expect(try text(info(video: "hevc"), to: .mp4, options).contains("-q:v:0 \(value)"))
    }

    @Test func qualityMovesVP9Too() throws {
        let options = MediaOptions(videoQuality: .higher)
        #expect(try text(info(), to: .webm, options).contains("-crf 24"))
    }

    // MARK: Resolution

    @Test func aLimitForcesAResizeOfALargerVideo() throws {
        let plan = try text(info(), to: .mov, MediaOptions(maxVideoResolution: 720))
        #expect(plan.contains("-c:v:0 h264_videotoolbox"))
        #expect(plan.contains("scale='if(gte(iw,ih),-2,720)':'if(gte(iw,ih),720,-2)'"))
    }

    @Test func aLimitLeavesASmallerVideoAlone() throws {
        let plan = try text(info(width: 1280, height: 720), to: .mov, MediaOptions(maxVideoResolution: 720))
        #expect(plan.contains("-c:v:0 copy"))
        #expect(!plan.contains("scale="))
    }

    @Test func aLimitMeansTheShorterSide() throws {
        // Portrait 1080p is 1080p, whichever side happens to be the height.
        let fits = try text(info(width: 1080, height: 1920), to: .mov, MediaOptions(maxVideoResolution: 1080))
        #expect(fits.contains("-c:v:0 copy"))
        let over = try text(info(width: 1080, height: 1920), to: .mov, MediaOptions(maxVideoResolution: 720))
        #expect(over.contains("scale="))
    }

    // MARK: Audio

    @Test func anAudioBitrateIsUsed() throws {
        let plan = try text(info(video: nil, audio: "flac"), to: .mp3, MediaOptions(audioBitrate: 256_000))
        #expect(plan.contains("-b:a 256000"))
        #expect(!plan.contains("-q:a"))
    }

    @Test func anAudioStreamWithinTheBitrateIsStillCopied() throws {
        let plan = try text(info(video: nil, audio: "aac", audioBitrate: 128_000), to: .m4a, MediaOptions(audioBitrate: 192_000))
        #expect(plan.contains("-c:a copy"))
    }

    @Test func anAudioStreamOverTheBitrateIsReEncoded() throws {
        let plan = try text(info(video: nil, audio: "aac", audioBitrate: 320_000), to: .m4a, MediaOptions(audioBitrate: 128_000))
        #expect(plan.contains("-b:a 128000"))
        #expect(!plan.contains("-c:a copy"))
    }

    @Test(arguments: [FileFormat.flac, .wav, .aiff])
    func losslessFormatsIgnoreABitrate(format: FileFormat) throws {
        #expect(try !text(info(video: nil, audio: "mp3"), to: format, MediaOptions(audioBitrate: 128_000)).contains("-b:a"))
    }

    // MARK: GIF

    @Test func gifWidthAndRateAreUsed() throws {
        let plan = try text(info(), to: .gif, MediaOptions(gifWidth: 480, gifFrameRate: 10))
        #expect(plan.contains("fps=10,scale='min(480,iw)':-2"))
    }

    @Test func aGifNeverGainsFramesTheSourceDoesNotHave() throws {
        let plan = try text(info(), to: .gif, MediaOptions(gifFrameRate: 60))
        #expect(plan.contains("fps=30,"))
    }

    // MARK: Metadata

    @Test(arguments: [FileFormat.mp4, .webm, .mp3, .gif])
    func removingMetadataAppliesToEveryAttempt(format: FileFormat) throws {
        let lists = try MediaPlan.convert(info(), to: format, capabilities: capabilities, options: MediaOptions(removesMetadata: true))
        #expect(!lists.isEmpty)
        for list in lists {
            #expect(list.joined(separator: " ").contains("-map_metadata -1"))
            #expect(list.joined(separator: " ").contains("-map_chapters -1"))
        }
    }

    @Test func metadataStaysUnlessToldOtherwise() throws {
        #expect(try !text(info(), to: .mp4).contains("-map_metadata"))
    }
}

@Suite(.enabled(if: ffmpegAvailable)) struct MediaOptionEncodingTests {
    private func size(_ url: URL) throws -> (Int?, Int?) {
        let video = try #require(try mediaInfo(url).mainVideo)
        return (video.width, video.height)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func aLandscapeVideoShrinksToTheLimit() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("wide.mp4")
        try VideoFixture.make(at: input, size: "1280x720", seconds: 1)
        let output = scratch.file("out.mov")

        try await MediaConverter.convert(input, to: output, format: .mov, options: MediaOptions(maxVideoResolution: 480))

        let (width, height) = try size(output)
        #expect(height == 480)
        #expect(width == 854)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func aPortraitVideoShrinksByItsShorterSide() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("tall.mp4")
        try VideoFixture.make(at: input, size: "720x1280", seconds: 1)
        let output = scratch.file("out.mp4")

        try await MediaConverter.convert(input, to: output, format: .mp4, options: MediaOptions(maxVideoResolution: 480))

        let (width, height) = try size(output)
        #expect(width == 480)
        #expect(height == 854)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func aRotatedPhoneVideoShrinksTheSameWay() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = scratch.file("source.mp4")
        try VideoFixture.make(at: source, size: "1280x720", seconds: 1)
        // Stored wide with a flag saying "turn it", the way a phone records upright video.
        let input = scratch.file("rotated.mp4")
        try makeFixture(["-display_rotation", "90", "-i", source.path, "-c", "copy", input.path])
        let output = scratch.file("out.mp4")

        try await MediaConverter.convert(input, to: output, format: .mp4, options: MediaOptions(maxVideoResolution: 480))

        let (width, height) = try size(output)
        #expect(min(width ?? 0, height ?? 0) == 480)
        #expect(max(width ?? 0, height ?? 0) == 854)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func aSmallerVideoIsCopiedUntouched() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("small.mp4")
        try VideoFixture.make(at: input, size: "320x240", seconds: 1)
        let output = scratch.file("out.mov")

        try await MediaConverter.convert(input, to: output, format: .mov, options: MediaOptions(maxVideoResolution: 480))

        #expect(try streamHash(output, map: "0:v:0") == streamHash(input, map: "0:v:0"))
    }

    @Test(.enabled(if: videoEncoderAvailable)) func aNamedCodecReallyComesOut() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input, seconds: 1)
        let output = scratch.file("out.mov")

        try await MediaConverter.convert(input, to: output, format: .mov, options: MediaOptions(videoCodec: .hevc))

        #expect(try mediaInfo(output).mainVideo?.codec == "hevc")
    }

    @Test(.enabled(if: videoEncoderAvailable)) func higherQualityMakesALargerFile() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input, size: "640x360", seconds: 2)
        let small = scratch.file("small.mov")
        let large = scratch.file("large.mov")

        try await MediaConverter.convert(input, to: small, format: .mov, options: MediaOptions(videoCodec: .hevc, videoQuality: .smaller))
        try await MediaConverter.convert(input, to: large, format: .mov, options: MediaOptions(videoCodec: .hevc, videoQuality: .higher))

        #expect(fileSize(large) > fileSize(small))
    }

    @Test func aRequestedAudioBitrateIsWhatTheFileGets() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("tone.wav")
        try makeFixture(["-f", "lavfi", "-i", "sine=frequency=440:duration=3", input.path])
        let output = scratch.file("out.mp3")

        try await MediaConverter.convert(input, to: output, format: .mp3, options: MediaOptions(audioBitrate: 192_000))

        let bitrate = try #require(try mediaInfo(output).audioStreams.first?.bitrate)
        #expect(bitrate >= 170_000 && bitrate <= 210_000)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func convertingCanLeaveTagsBehind() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("tagged.mp4")
        try VideoFixture.make(at: input, seconds: 1, extra: ["-metadata", "title=Holiday", "-metadata", "artist=Someone"])
        let kept = scratch.file("kept.mov")
        let clean = scratch.file("clean.mov")

        try await MediaConverter.convert(input, to: kept, format: .mov)
        try await MediaConverter.convert(input, to: clean, format: .mov, options: MediaOptions(removesMetadata: true))

        #expect(try runFFmpeg(["-i", kept.path]).output.contains("Holiday"))
        let log = try runFFmpeg(["-i", clean.path]).output
        #expect(!log.contains("Holiday"))
        #expect(!log.contains("Someone"))
    }

    @Test(.enabled(if: videoEncoderAvailable)) func gifSettingsShowInTheFile() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input, size: "1280x720", seconds: 1)
        let output = scratch.file("out.gif")

        try await MediaConverter.convert(input, to: output, format: .gif, options: MediaOptions(gifWidth: 320, gifFrameRate: 10))

        #expect(ImageFixture.size(of: output)?.width == 320)
        // One second at ten frames a second, give or take the ends of the clip.
        let frames = ImageFixture.frameCount(of: output)
        #expect(frames >= 8 && frames <= 12)
    }

    @Test(.enabled(if: videoEncoderAvailable)) func compressionRespectsTheLimit() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input, size: "1280x720", seconds: 2)
        let output = scratch.file("out.mp4")

        try await MediaConverter.compress(input, to: output, level: .balanced, options: MediaOptions(maxVideoResolution: 480))

        let (_, height) = try size(output)
        #expect(height == 480)
    }
}

@Suite struct EncoderFailureMessageTests {
    @Test func aMissingEncoderSaysWhatToDo() {
        let log = """
        [h264_videotoolbox @ 0x7f8] Cannot create compression session: -12908
        [out#0/mp4 @ 0x7f9] Nothing was written into output file, because at least one of its streams received no packets.
        """
        let message = FFmpeg.failureMessage(from: log)
        #expect(message.contains("video encoder"))
        #expect(message.contains("WebM"))
        #expect(!message.contains("streams"))
    }

    @Test func anEncoderThatGivesNothingSaysTheSame() {
        let log = """
        [vost#0:0/h264_videotoolbox @ 0x7f8] Could not open encoder before EOF
        [out#0/mp4 @ 0x7f9] Nothing was written into output file, because at least one of its streams received no packets.
        """
        #expect(FFmpeg.failureMessage(from: log).contains("video encoder"))
    }

    @Test func noPacketsFromAnotherEncoderKeepsItsOwnReason() {
        let log = "[out#0/webm @ 0x7f9] Nothing was written into output file, because at least one of its streams received no packets."
        #expect(FFmpeg.failureMessage(from: log).hasPrefix("The conversion failed: Nothing was written"))
    }

    @Test func otherFailuresStillShowTheirReason() {
        #expect(FFmpeg.failureMessage(from: "Invalid data found when processing input") == "The conversion failed: Invalid data found when processing input")
    }
}

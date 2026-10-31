import ConversionCore
import Foundation
import Testing
@testable import MediaEngine

/// What ffmpeg prints for a typical phone video, and a few variations of it.
private enum Logs {
    static let mp4 = """
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
      Metadata:
        major_brand     : isom
        encoder         : Lavf62.12.103
      Duration: 00:00:05.02, start: 0.000000, bitrate: 1724 kb/s
      Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 640x360, 1592 kb/s, SAR 1:1 DAR 16:9, 25 fps, 25 tbr, 12800 tbn (default)
        Metadata:
          handler_name    : VideoHandler
      Stream #0:1[0x2](eng): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, mono, fltp, 128 kb/s (default)
      Stream #0:2[0x3](und): Subtitle: mov_text (tx3g / 0x67337874), 0 kb/s (default)
    At least one output file must be specified
    """

    static let flac = """
    Input #0, flac, from 'x.flac':
      Duration: 00:00:01.00, start: 0.000000, bitrate: 272 kb/s
      Stream #0:0: Audio: flac, 96000 Hz, 5.1(side), s32 (24 bit)
      Stream #0:1: Video: mjpeg (Progressive), yuvj420p(pc, bt470bg/unknown/unknown), 500x500 [SAR 1:1 DAR 1:1], 90k tbr, 90k tbn (attached pic)
    """
}

@Suite struct MediaInfoTests {
    @Test func readsDurationAndStreams() throws {
        let info = try #require(MediaInfo(parsing: Logs.mp4))

        #expect(info.duration == 5.02)
        #expect(info.bitrate == 1_724_000)
        #expect(info.streams.map(\.kind) == [.video, .audio, .subtitle])

        let video = try #require(info.mainVideo)
        #expect(video.codec == "h264")
        #expect(video.width == 640 && video.height == 360)
        #expect(video.frameRate == 25)
        #expect(video.bitrate == 1_592_000)
        #expect(video.pixelFormat == "yuv420p")

        let audio = try #require(info.audioStreams.first)
        #expect(audio.codec == "aac")
        #expect(audio.sampleRate == 44100)
        #expect(audio.channels == 1)
        #expect(audio.bitrate == 128_000)

        #expect(info.subtitleStreams.first?.codec == "mov_text")
    }

    @Test func tellsCoverArtFromVideoAndReadsBitDepth() throws {
        let info = try #require(MediaInfo(parsing: Logs.flac))

        #expect(info.mainVideo == nil)
        #expect(info.attachedPicture?.codec == "mjpeg")
        let audio = try #require(info.audioStreams.first)
        #expect(audio.channels == 6)
        #expect(audio.bitDepth == 24)
        #expect(audio.sampleRate == 96000)
    }

    @Test func aFileThatDidNotOpenGivesNothing() {
        #expect(MediaInfo(parsing: "x.mp4: Invalid data found when processing input") == nil)
    }

    @Test func splitsDetailsOnlyOutsideBrackets() {
        let parts = MediaInfo.splitTopLevel("h264 (High, x), yuv420p(tv, bt709), 640x360, 25 fps")
        #expect(parts == ["h264 (High, x)", "yuv420p(tv, bt709)", "640x360", "25 fps"])
    }
}

@Suite struct FFmpegTextTests {
    @Test func picksTheLastUsefulLineOfAFailure() {
        let log = """
        [vist#0:0/h264 @ 0x7f8] Decoding error
        [libopus @ 0x1234] Error while opening encoder - maybe incorrect parameters such as bit rate
        Conversion failed!
        """
        let message = FFmpeg.failureMessage(from: log)
        #expect(message == "The conversion failed: Error while opening encoder - maybe incorrect parameters such as bit rate")
    }

    @Test func messagesFollowTheHouseStyle() {
        let message = FFmpeg.failureMessage(from: "Something went wrong \u{2014} badly!\nConversion failed!")
        #expect(!message.contains("!"))
        #expect(!message.contains("\u{2014}") && !message.contains("\u{2013}"))
    }

    @Test func parsesTheEncoderList() {
        let listing = """
        Encoders:
         V..... = Video
         ------
         V....D libvpx-vp9           libvpx VP9 (codec vp9)
         V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
         A....D aac_at               aac (AudioToolbox) (codec aac)
         S..... mov_text             MOV text
        """
        let encoders = FFmpeg.parseEncoders(listing)
        #expect(encoders == ["libvpx-vp9", "h264_videotoolbox", "aac_at", "mov_text"])
    }
}

@Suite struct MediaPlanTests {
    private let capabilities = MediaCapabilities(encoders: [
        "h264_videotoolbox", "hevc_videotoolbox", "libvpx-vp9", "aac_at", "aac", "libopus", "libmp3lame",
        "libvorbis", "flac", "mpeg4",
    ])

    private func info(
        video: String? = "h264",
        audio: String? = "aac",
        width: Int = 640,
        height: Int = 360,
        subtitles: [String] = [],
        pixelFormat: String = "yuv420p"
    ) -> MediaInfo {
        var streams: [MediaInfo.Stream] = []
        if let video {
            streams.append(MediaInfo.Stream(
                index: 0, kind: .video, codec: video, width: width, height: height, frameRate: 25,
                bitrate: 4_000_000, pixelFormat: pixelFormat
            ))
        }
        if let audio {
            streams.append(MediaInfo.Stream(
                index: streams.count, kind: .audio, codec: audio, bitrate: 128_000, sampleRate: 44100, channels: 2
            ))
        }
        for codec in subtitles {
            streams.append(MediaInfo.Stream(index: streams.count, kind: .subtitle, codec: codec))
        }
        return MediaInfo(duration: 10, bitrate: 4_200_000, streams: streams)
    }

    private func first(_ info: MediaInfo, to format: FileFormat) throws -> [String] {
        try #require(MediaPlan.convert(info, to: format, capabilities: capabilities).first)
    }

    @Test func mp4ToMovCopiesBothStreams() throws {
        let arguments = try first(info(), to: .mov)
        #expect(arguments.joined(separator: " ").contains("-c:v:0 copy"))
        #expect(arguments.joined(separator: " ").contains("-c:a:0 copy"))
        #expect(arguments.contains("-movflags") && arguments.contains("+faststart"))
        #expect(arguments.contains("mov"))
    }

    @Test(arguments: [FileFormat.mp4, .m4v, .mov])
    func appleContainersGetFaststart(format: FileFormat) throws {
        #expect(try first(info(), to: format).contains("+faststart"))
    }

    @Test func matroskaTakesAnythingAsIs() throws {
        let arguments = try first(info(video: "vp9", audio: "opus"), to: .mkv).joined(separator: " ")
        #expect(arguments.contains("-c:v:0 copy"))
        #expect(arguments.contains("-c:a:0 copy"))
    }

    @Test func hevcInMP4GetsTheAppleTag() throws {
        let arguments = try first(info(video: "hevc"), to: .mp4).joined(separator: " ")
        #expect(arguments.contains("-c:v:0 copy -tag:v:0 hvc1"))
    }

    @Test func mp4ToWebMReencodesToVP9AndOpus() throws {
        let arguments = try first(info(), to: .webm).joined(separator: " ")
        #expect(arguments.contains("-c:v:0 libvpx-vp9"))
        #expect(arguments.contains("-c:a:0 libopus"))
        #expect(arguments.contains("-ar:a:0 48000"))
        #expect(arguments.contains("-f webm"))
    }

    @Test func codecsTheContainerRefusesAreReencodedToH264AndAAC() throws {
        let arguments = try first(info(video: "vp9", audio: "opus"), to: .mp4).joined(separator: " ")
        #expect(arguments.contains("-c:v:0 h264_videotoolbox"))
        #expect(arguments.contains("-pix_fmt yuv420p"))
        #expect(arguments.contains("-c:a:0 aac_at"))
    }

    @Test func oddSizesAreRoundedToEven() throws {
        let odd = try first(info(video: "vp9", width: 641, height: 361), to: .mp4).joined(separator: " ")
        #expect(odd.contains("scale=trunc(iw/2)*2:trunc(ih/2)*2"))
        let even = try first(info(video: "vp9"), to: .mp4).joined(separator: " ")
        #expect(!even.contains("scale="))
    }

    @Test func subtitlesAreMappedWhereTheContainerAllowsAndDroppedElsewhere() throws {
        let source = info(subtitles: ["mov_text", "hdmv_pgs_subtitle"])
        let mkv = try first(source, to: .mkv).joined(separator: " ")
        #expect(mkv.contains("-c:s:0 srt") && mkv.contains("-c:s:1 copy"))

        let mp4 = try first(source, to: .mp4).joined(separator: " ")
        #expect(mp4.contains("-c:s:0 copy"))
        #expect(!mp4.contains("-c:s:1"))

        let avi = try first(source, to: .avi).joined(separator: " ")
        #expect(!avi.contains("-c:s"))
    }

    @Test func aLaterAttemptGivesUpSubtitlesThenCopying() throws {
        let attempts = try MediaPlan.convert(info(subtitles: ["subrip"]), to: .mov, capabilities: capabilities)
        #expect(attempts.count == 3)
        #expect(attempts[0].joined(separator: " ").contains("-c:s:0 mov_text"))
        #expect(!attempts[1].joined(separator: " ").contains("-c:s"))
        #expect(attempts[1].joined(separator: " ").contains("-c:v:0 copy"))
        #expect(attempts[2].joined(separator: " ").contains("-c:v:0 h264_videotoolbox"))
    }

    @Test func gifUsesAPaletteAtFifteenFramesAndAtMost720Wide() throws {
        let arguments = try first(info(), to: .gif).joined(separator: " ")
        #expect(arguments.contains("fps=15"))
        #expect(arguments.contains("min(720,iw)"))
        #expect(arguments.contains("palettegen") && arguments.contains("paletteuse"))
        #expect(arguments.contains("-an"))
    }

    @Test func gifWithoutVideoIsAnError() {
        #expect(throws: ConversionError.self) {
            try MediaPlan.convert(info(video: nil), to: .gif, capabilities: capabilities)
        }
    }

    @Test func audioTargetsNeedAudio() {
        let error = #expect(throws: ConversionError.self) {
            try MediaPlan.convert(info(audio: nil), to: .mp3, capabilities: capabilities)
        }
        #expect(error?.message == "This file has no audio.")
    }

    @Test(arguments: [
        (FileFormat.mp3, "libmp3lame"), (.m4a, "aac_at"), (.ogg, "libvorbis"), (.opus, "libopus"),
        (.flac, "flac"), (.wav, "pcm_s16le"), (.aiff, "pcm_s16be"),
    ])
    func audioFormatsPickTheirCodec(format: FileFormat, codec: String) throws {
        let source = info(video: "h264", audio: "ac3")
        let arguments = try first(source, to: format).joined(separator: " ")
        #expect(arguments.contains("-c:a \(codec)"))
        #expect(arguments.contains("-vn"))
    }

    @Test func opusIsAlwaysFortyEightKilohertz() throws {
        #expect(try first(info(), to: .opus).joined(separator: " ").contains("-ar 48000"))
    }

    @Test func extractingAudioCopiesWhenTheCodecAlreadyFits() throws {
        let arguments = try first(info(audio: "aac"), to: .m4a).joined(separator: " ")
        #expect(arguments.contains("-c:a copy"))
    }

    @Test func stripCopiesEverythingAndDropsMetadata() {
        let attempts = MediaPlan.strip(info(), format: .mp4)
        let first = attempts[0].joined(separator: " ")
        #expect(first.contains("-map_metadata -1 -map_chapters -1 -c copy"))
        #expect(first.contains("-fflags +bitexact"))
        #expect(first.contains("-map 0 "))
        #expect(attempts.count == 3)
        #expect(!attempts[2].joined(separator: " ").contains("0:s?"))
    }

    // MARK: Budgets

    @Test func levelsMapToFallingBitrates() throws {
        let video = try #require(info().mainVideo)
        let light = MediaBudget.videoBitrate(for: video, level: .light, family: .hevc)
        let balanced = MediaBudget.videoBitrate(for: video, level: .balanced, family: .hevc)
        let strong = MediaBudget.videoBitrate(for: video, level: .strong, family: .hevc)
        #expect(light > balanced && balanced > strong)
        // Never more than the source already uses.
        #expect(light < 4_000_000)
    }

    @Test func aTargetSplitsIntoVideoAndAudio() throws {
        let source = info()
        let video = try #require(source.mainVideo)
        let split = try MediaBudget.split(info: source, video: video, targetBytes: 5_000_000)
        // 5 MB over 10 seconds is 4 Mbit/s before the safety margin.
        #expect(split.video + split.audioTotal < 4_000_000)
        #expect(split.video + split.audioTotal > 3_500_000)
        #expect(split.audioStereo >= 32_000 && split.audioStereo <= 128_000)
    }

    @Test func unrealisticTargetsSayHowBigTheyShouldBe() throws {
        let source = info()
        let video = try #require(source.mainVideo)
        let error = #expect(throws: ConversionError.self) {
            try MediaBudget.split(info: source, video: video, targetBytes: 2_000)
        }
        #expect(error?.message.hasPrefix("The target size is too small for this video. Try at least") == true)
    }
}

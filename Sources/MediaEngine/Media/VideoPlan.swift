import ConversionCore
import Foundation

enum VideoFamily: Sendable {
    case h264, hevc, vp9, mpeg4

    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .vp9: "VP9"
        case .mpeg4: "MPEG-4"
        }
    }

    /// Encoders in order of preference. VideoToolbox runs on the media engine of the chip.
    var encoders: [String] {
        switch self {
        case .h264: ["h264_videotoolbox", "libx264"]
        case .hevc: ["hevc_videotoolbox", "libx265"]
        case .vp9: ["libvpx-vp9"]
        case .mpeg4: ["mpeg4"]
        }
    }
}

/// How to write a video file: which streams to keep, copy or re-encode.
struct VideoPlan {
    /// Present when compressing. Plain conversion leaves it nil and copies whatever fits.
    struct Compression {
        var level: CompressionLevel
        /// Bits per second for video, or nil to choose from the level.
        var videoBitrate: Int?
        /// Bits per second a stereo audio stream gets.
        var audioBitrate: Int
    }

    var info: MediaInfo
    var format: FileFormat
    var rules: ContainerRules
    var capabilities: MediaCapabilities
    var compression: Compression?

    init(
        info: MediaInfo,
        format: FileFormat,
        capabilities: MediaCapabilities,
        compression: Compression? = nil
    ) throws {
        guard let rules = ContainerRules.of(format) else {
            throw ConversionError("\(format.label) is not a video format this app can write.")
        }
        self.info = info
        self.format = format
        self.rules = rules
        self.capabilities = capabilities
        self.compression = compression
    }

    /// The family a transcode goes to. Compression prefers HEVC where the container is happy with it.
    var targetFamily: VideoFamily {
        switch format {
        case .webm: .vp9
        case .avi: .mpeg4
        case .m4v: .h264
        default: compression == nil ? .h264 : .hevc
        }
    }

    /// Argument lists to try in order. Later ones give up something, subtitles first and then
    /// stream copying, so a conversion does not fail over a detail.
    func attempts() throws -> [[String]] {
        var combinations: [(copy: Bool, subtitles: Bool)] = [(true, true)]
        let keepsSubtitles = info.subtitleStreams.contains { rules.subtitleCodec(for: $0.codec) != nil }
        if keepsSubtitles {
            combinations.append((true, false))
        }
        if compression == nil {
            combinations.append((false, false))
        }
        var lists: [[String]] = []
        for combination in combinations {
            let list = try arguments(allowCopy: combination.copy, includeSubtitles: combination.subtitles)
            if !lists.contains(list) {
                lists.append(list)
            }
        }
        return lists
    }

    func arguments(allowCopy: Bool, includeSubtitles: Bool) throws -> [String] {
        var maps: [String] = []
        var codecs: [String] = []

        if let video = info.mainVideo {
            maps += ["-map", "0:\(video.index)"]
            codecs += try videoArguments(video, allowCopy: allowCopy)
        }
        for (offset, audio) in info.audioStreams.enumerated() {
            maps += ["-map", "0:\(audio.index)"]
            codecs += try audioArguments(audio, outputIndex: offset, allowCopy: allowCopy)
        }
        if includeSubtitles {
            var written = 0
            for subtitle in info.subtitleStreams {
                guard let codec = rules.subtitleCodec(for: subtitle.codec) else { continue }
                maps += ["-map", "0:\(subtitle.index)"]
                codecs += ["-c:s:\(written)", codec]
                written += 1
            }
        }
        guard !maps.isEmpty else {
            throw ConversionError("This file has no audio or video to convert.")
        }

        var tail = ["-max_muxing_queue_size", "1024", "-f", rules.muxer]
        if rules.faststart {
            tail += ["-movflags", "+faststart"]
        }
        return maps + codecs + tail
    }

    // MARK: Video

    private func videoArguments(_ video: MediaInfo.Stream, allowCopy: Bool) throws -> [String] {
        if allowCopy, compression == nil, rules.acceptsVideo(video.codec) {
            var copy = ["-c:v:0", "copy"]
            if video.codec == "hevc", rules.tagsHEVC {
                copy += ["-tag:v:0", "hvc1"]
            }
            return copy
        }

        let family = targetFamily
        guard let encoder = capabilities.first(of: family.encoders) else {
            throw ConversionError("This copy of ffmpeg cannot write \(family.label) video.")
        }
        var arguments = ["-c:v:0", encoder]
        arguments += rateArguments(for: family, encoder: encoder, video: video)

        let tenBit = (video.pixelFormat ?? "").contains("10") && family == .hevc
        arguments += ["-pix_fmt", tenBit ? "p010le" : "yuv420p"]
        if tenBit {
            arguments += ["-profile:v:0", "main10"]
        }
        if family == .hevc, rules.tagsHEVC {
            arguments += ["-tag:v:0", "hvc1"]
        }
        if encoder.hasSuffix("_videotoolbox") {
            arguments += ["-allow_sw", "1"]
        }
        // H.264 and friends cannot hold odd sizes, and a stray odd pixel should not stop a conversion.
        let isEven = (video.width ?? 1) % 2 == 0 && (video.height ?? 1) % 2 == 0
        if family != .vp9, !(video.width != nil && isEven) {
            arguments += ["-filter:v:0", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        }
        return arguments
    }

    private func rateArguments(for family: VideoFamily, encoder: String, video: MediaInfo.Stream) -> [String] {
        if let bitrate = compression.flatMap({ explicitVideoBitrate($0, family: family, video: video) }) {
            return ["-b:v:0", String(bitrate)] + (family == .vp9 ? vp9Speed : [])
        }
        switch family {
        case .h264:
            return ["-q:v:0", "62"]
        case .hevc:
            return ["-q:v:0", "56"]
        case .vp9:
            let crf = compression.map { Self.crf(for: $0.level) } ?? 31
            return ["-crf", String(crf), "-b:v:0", "0"] + vp9Speed
        case .mpeg4:
            return ["-q:v:0", "4"]
        }
    }

    /// The bitrate to ask for, if there is one. Plain VP9 compression uses constant quality instead.
    private func explicitVideoBitrate(
        _ compression: Compression,
        family: VideoFamily,
        video: MediaInfo.Stream
    ) -> Int? {
        if let bitrate = compression.videoBitrate {
            return bitrate
        }
        if family == .vp9 {
            return nil
        }
        return MediaBudget.videoBitrate(for: video, level: compression.level, family: family)
    }

    private var vp9Speed: [String] {
        ["-deadline", "good", "-cpu-used", "4", "-row-mt", "1"]
    }

    private static func crf(for level: CompressionLevel) -> Int {
        switch level {
        case .light: 28
        case .balanced: 33
        case .strong: 38
        }
    }

    // MARK: Audio

    private func audioArguments(_ audio: MediaInfo.Stream, outputIndex: Int, allowCopy: Bool) throws -> [String] {
        let spec = "a:\(outputIndex)"
        var rate: Int?
        if let compression {
            let scaled = MediaBudget.scaledAudioBitrate(compression.audioBitrate, channels: audio.channels)
            rate = scaled
            let fitsAlready = audio.bitrate.map { Double($0) <= Double(scaled) * 1.15 } ?? false
            if allowCopy, fitsAlready, rules.acceptsAudio(audio.codec) {
                return ["-c:\(spec)", "copy"]
            }
        } else if allowCopy, rules.acceptsAudio(audio.codec) {
            return ["-c:\(spec)", "copy"]
        }

        switch format {
        case .webm:
            guard capabilities.encoders.contains("libopus") else {
                throw ConversionError("This copy of ffmpeg cannot write Opus audio.")
            }
            return ["-c:\(spec)", "libopus", "-b:\(spec)", String(rate ?? 128_000), "-ar:\(spec)", "48000"]
        case .avi:
            guard capabilities.encoders.contains("libmp3lame") else {
                throw ConversionError("This copy of ffmpeg cannot write MP3 audio.")
            }
            return ["-c:\(spec)", "libmp3lame", "-b:\(spec)", String(rate ?? 192_000), "-ac:\(spec)", "2"]
        default:
            let encoder = capabilities.first(of: ["aac_at", "aac"]) ?? "aac"
            let fallback = Self.defaultAACBitrate(channels: audio.channels)
            return ["-c:\(spec)", encoder, "-b:\(spec)", String(rate ?? fallback)]
        }
    }

    static func defaultAACBitrate(channels: Int?) -> Int {
        MediaBudget.scaledAudioBitrate(160_000, channels: channels)
    }
}

import ConversionCore
import Foundation

/// How to write an audio file from the first audio stream of the source.
struct AudioPlan {
    enum Mode {
        /// Convert with a good default for the format.
        case convert
        /// Compress by level, or to a bitrate when one is given.
        case compress(CompressionLevel, bitrate: Int?)
    }

    var info: MediaInfo
    var format: FileFormat
    var capabilities: MediaCapabilities
    var mode: Mode
    var options = MediaOptions()

    private var lossless: Bool {
        [.wav, .aiff, .flac].contains(format)
    }

    /// Cover art goes first, and the plain version follows for containers that refuse it.
    func attempts() throws -> [[String]] {
        guard let audio = info.audioStreams.first else {
            throw ConversionError("This file has no audio.")
        }
        let base = try arguments(for: audio)
        if let cover = coverArt {
            return [try arguments(for: audio, cover: cover), base]
        }
        return [base]
    }

    private var coverArt: MediaInfo.Stream? {
        guard [.mp3, .m4a, .flac].contains(format),
              let picture = info.attachedPicture,
              ["mjpeg", "png"].contains(picture.codec) else { return nil }
        return picture
    }

    private func arguments(for audio: MediaInfo.Stream, cover: MediaInfo.Stream? = nil) throws -> [String] {
        guard let muxer = ContainerRules.muxer(for: format) else {
            throw ConversionError("\(format.label) is not an audio format this app can write.")
        }
        var arguments = ["-map", "0:\(audio.index)"]
        if let cover {
            arguments += ["-map", "0:\(cover.index)", "-c:v:0", "copy", "-disposition:v:0", "attached_pic"]
            if format == .mp3 {
                arguments += ["-id3v2_version", "3"]
            }
        } else {
            arguments += ["-vn"]
        }
        arguments += ["-sn", "-dn"]
        // Ogg keeps its tags on the audio stream, where formats such as MP3 never look.
        if case .convert = mode, info.container == "ogg", !options.removesMetadata {
            arguments += ["-map_metadata", "0:s:a:0"]
        }
        arguments += try codecArguments(for: audio)
        arguments += ["-f", muxer]
        if format == .m4a {
            arguments += ["-movflags", "+faststart"]
        }
        return arguments
    }

    // MARK: Codecs

    private func codecArguments(for audio: MediaInfo.Stream) throws -> [String] {
        if case .convert = mode, let copy = copyCodec, copy.contains(audio.codec), fitsRequestedBitrate(audio) {
            return ["-c:a", "copy"]
        }
        switch format {
        case .mp3:
            return try lossy("libmp3lame", audio: audio, quality: "2", defaultRate: nil, extra: mp3Limits(audio))
        case .m4a:
            let encoder = capabilities.first(of: ["aac_at", "aac"]) ?? "aac"
            return try lossy(encoder, audio: audio, quality: nil, defaultRate: 192_000, extra: Self.aacLimits(audio))
        case .ogg:
            return try lossy("libvorbis", audio: audio, quality: "5", defaultRate: nil, extra: [])
        case .opus:
            return try lossy("libopus", audio: audio, quality: nil, defaultRate: 128_000, extra: ["-ar", "48000", "-vbr", "on"])
        case .flac:
            return ["-c:a", "flac", "-compression_level", "12"] + (shrinksDepth(audio) ? ["-sample_fmt", "s16"] : [])
        case .wav:
            return pcm("le", audio: audio)
        case .aiff:
            return pcm("be", audio: audio)
        default:
            throw ConversionError("\(format.label) is not an audio format this app can write.")
        }
    }

    /// Codecs that can go into the format without re-encoding.
    private var copyCodec: Set<String>? {
        switch format {
        case .mp3: ["mp3"]
        case .m4a: ["aac", "alac"]
        case .ogg: ["vorbis"]
        case .opus: ["opus"]
        case .flac: ["flac"]
        case .wav: ["pcm_s16le", "pcm_s24le"]
        case .aiff: ["pcm_s16be", "pcm_s24be"]
        default: nil
        }
    }

    /// Copying a stream is the best outcome, unless it spends more than was asked for.
    private func fitsRequestedBitrate(_ audio: MediaInfo.Stream) -> Bool {
        guard let wanted = options.audioBitrate, !lossless else { return true }
        guard let source = audio.bitrate else { return false }
        return Double(source) <= Double(wanted) * 1.05
    }

    private func lossy(
        _ encoder: String,
        audio: MediaInfo.Stream,
        quality: String?,
        defaultRate: Int?,
        extra: [String]
    ) throws -> [String] {
        guard capabilities.encoders.contains(encoder) else {
            throw ConversionError("This copy of ffmpeg cannot write \(format.label) audio.")
        }
        var arguments = ["-c:a", encoder] + extra
        switch mode {
        case .convert:
            if let wanted = options.audioBitrate {
                arguments += ["-b:a", String(wanted)]
            } else if let quality {
                arguments += ["-q:a", quality]
            } else if let defaultRate {
                arguments += ["-b:a", String(MediaBudget.scaledAudioBitrate(defaultRate, channels: audio.channels))]
            }
        case let .compress(level, bitrate):
            if let bitrate {
                arguments += ["-b:a", String(bitrate)]
            } else if format == .ogg {
                arguments += ["-q:a", level == .light ? "5" : level == .balanced ? "3" : "1"]
            } else {
                arguments += ["-b:a", String(levelBitrate(level, audio: audio))]
            }
        }
        return arguments
    }

    /// A bitrate for the level, never above what the source already spends.
    private func levelBitrate(_ level: CompressionLevel, audio: MediaInfo.Stream) -> Int {
        let stereo: Int
        switch (format, level) {
        case (.opus, .light): stereo = 96_000
        case (.opus, .balanced): stereo = 64_000
        case (.opus, .strong): stereo = 48_000
        case (.mp3, .light): stereo = 192_000
        default: stereo = MediaBudget.audioBitrate(level)
        }
        var rate = MediaBudget.scaledAudioBitrate(stereo, channels: audio.channels)
        if let source = audio.bitrate {
            rate = min(rate, Int(Double(source) * 0.85))
        }
        return max(rate, format == .opus ? 16_000 : 32_000)
    }

    /// Apple's AAC encoder refuses rates above 48 kHz, such as 96 kHz studio recordings.
    static func aacLimits(_ audio: MediaInfo.Stream) -> [String] {
        (audio.sampleRate ?? 0) > 48_000 ? ["-ar", "48000"] : []
    }

    /// Opus is always 48 kHz, MP3 tops out at 48 kHz and two channels.
    private func mp3Limits(_ audio: MediaInfo.Stream) -> [String] {
        var limits: [String] = []
        if (audio.sampleRate ?? 0) > 48_000 { limits += ["-ar", "48000"] }
        if (audio.channels ?? 2) > 2 { limits += ["-ac", "2"] }
        return limits
    }

    // MARK: Uncompressed audio

    private func shrinksDepth(_ audio: MediaInfo.Stream) -> Bool {
        guard case let .compress(level, _) = mode, level != .light else { return false }
        return audio.hasHighBitDepth
    }

    private func pcm(_ endian: String, audio: MediaInfo.Stream) -> [String] {
        var deep = audio.hasHighBitDepth
        var arguments: [String] = []
        if case let .compress(level, _) = mode {
            deep = false
            switch level {
            case .light: break
            case .balanced: if (audio.sampleRate ?? 0) > 44_100 { arguments += ["-ar", "44100"] }
            case .strong: if (audio.sampleRate ?? 0) > 32_000 { arguments += ["-ar", "32000"] }
            }
        }
        return ["-c:a", deep ? "pcm_s24\(endian)" : "pcm_s16\(endian)"] + arguments
    }

    /// Lossless formats cannot aim at a size. Said plainly, so the caller can offer something else.
    static func requireLossy(_ format: FileFormat) throws {
        if [.wav, .aiff, .flac].contains(format) {
            throw ConversionError("\(format.label) is lossless, so it cannot be squeezed to a size. Convert it to MP3 or M4A first.")
        }
    }
}

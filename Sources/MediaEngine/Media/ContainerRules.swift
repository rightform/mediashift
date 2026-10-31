import ConversionCore

/// What each video container accepts as it is, and how it wants subtitles.
struct ContainerRules {
    enum Subtitles {
        case none, movText, webVTT, matroska
    }

    var muxer: String
    /// Source codecs that can be copied in untouched. Nil means every codec fits.
    var videoCodecs: Set<String>?
    var audioCodecs: Set<String>?
    var subtitles: Subtitles
    var faststart = false
    /// HEVC needs the `hvc1` tag to play in Apple software.
    var tagsHEVC = false

    func acceptsVideo(_ codec: String) -> Bool {
        videoCodecs?.contains(codec) ?? true
    }

    func acceptsAudio(_ codec: String) -> Bool {
        audioCodecs?.contains(codec) ?? true
    }

    /// The codec to write a subtitle stream with, "copy", or nil when this container cannot hold it.
    func subtitleCodec(for source: String) -> String? {
        let isText = Self.textSubtitles.contains(source)
        switch subtitles {
        case .none:
            return nil
        case .movText:
            return isText ? (source == "mov_text" ? "copy" : "mov_text") : nil
        case .webVTT:
            return isText ? (source == "webvtt" ? "copy" : "webvtt") : nil
        case .matroska:
            return source == "mov_text" ? "srt" : "copy"
        }
    }

    static let textSubtitles: Set<String> = [
        "subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "subviewer", "subviewer1",
        "microdvd", "jacosub", "sami", "realtext", "stl", "vplayer", "mpl2", "pjs", "ttml",
    ]

    static func of(_ format: FileFormat) -> ContainerRules? {
        let appleAudio: Set = ["aac", "mp3", "ac3", "eac3", "alac"]
        switch format {
        case .mp4, .m4v:
            return ContainerRules(
                muxer: "mp4", videoCodecs: ["h264", "hevc", "mpeg4"], audioCodecs: appleAudio,
                subtitles: .movText, faststart: true, tagsHEVC: true
            )
        case .mov:
            return ContainerRules(
                muxer: "mov", videoCodecs: ["h264", "hevc", "mpeg4", "prores", "mjpeg"],
                audioCodecs: appleAudio.union(["pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be"]),
                subtitles: .movText, faststart: true, tagsHEVC: true
            )
        case .mkv:
            return ContainerRules(muxer: "matroska", videoCodecs: nil, audioCodecs: nil, subtitles: .matroska)
        case .webm:
            return ContainerRules(
                muxer: "webm", videoCodecs: ["vp8", "vp9", "av1"], audioCodecs: ["opus", "vorbis"],
                subtitles: .webVTT
            )
        case .avi:
            return ContainerRules(
                muxer: "avi", videoCodecs: ["mpeg4", "mjpeg", "msmpeg4v3"],
                audioCodecs: ["mp3", "ac3", "pcm_s16le"], subtitles: .none
            )
        default:
            return nil
        }
    }

    /// The ffmpeg muxer for a format, chosen explicitly so a file name never decides it.
    static func muxer(for format: FileFormat) -> String? {
        switch format {
        case .mp3: "mp3"
        case .m4a: "ipod"
        case .wav: "wav"
        case .flac: "flac"
        case .ogg: "ogg"
        case .opus: "opus"
        case .aiff: "aiff"
        case .gif: "gif"
        default: of(format)?.muxer
        }
    }
}

import ConversionCore
import Foundation

/// Turns what a file holds and what is wanted into lists of ffmpeg arguments, best first.
/// Nothing here touches the disk, so the choices can be tested without ffmpeg.
enum MediaPlan {
    static func convert(
        _ info: MediaInfo,
        to format: FileFormat,
        capabilities: MediaCapabilities
    ) throws -> [[String]] {
        switch format.kind {
        case .video:
            return try VideoPlan(info: info, format: format, capabilities: capabilities).attempts()
        case .audio:
            return try AudioPlan(info: info, format: format, capabilities: capabilities, mode: .convert).attempts()
        case .image where format == .gif:
            return [try gif(info)]
        default:
            throw ConversionError("Converting video or audio to \(format.label) is not supported.")
        }
    }

    /// Fifteen frames a second, at most 720 pixels wide, with a palette made for this clip.
    static func gif(_ info: MediaInfo) throws -> [String] {
        guard let video = info.mainVideo else {
            throw ConversionError("This file has no video to turn into a GIF.")
        }
        let rate = min(15, video.frameRate ?? 15)
        let rateText = rate == rate.rounded() ? String(Int(rate)) : String(rate)
        let filter = "fps=\(rateText),scale='min(720,iw)':-2:flags=lanczos,split[a][b];"
            + "[a]palettegen=stats_mode=diff[p];"
            + "[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        return ["-map", "0:\(video.index)", "-an", "-sn", "-dn", "-vf", filter, "-loop", "0", "-f", "gif"]
    }

    /// Drops every tag without re-encoding. Later lists keep fewer streams, for containers that
    /// cannot carry data or attachment streams.
    static func strip(_ info: MediaInfo, format: FileFormat?) -> [[String]] {
        let base = [
            "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy",
            "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact",
        ]
        var tail: [String] = []
        if let format, let muxer = ContainerRules.muxer(for: format) {
            tail += ["-f", muxer]
        }
        if let format, ContainerRules.of(format)?.faststart == true || format == .m4a {
            tail += ["-movflags", "+faststart"]
        }
        let selections = [
            ["-map", "0"],
            ["-map", "0:v?", "-map", "0:a?", "-map", "0:s?"],
            ["-map", "0:v?", "-map", "0:a?"],
        ]
        return selections.map { $0 + base + tail }
    }
}

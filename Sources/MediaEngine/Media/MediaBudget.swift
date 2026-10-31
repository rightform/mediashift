import ConversionCore
import Foundation

/// Turns a compression level or a size target into bitrates.
enum MediaBudget {
    /// A few percent of a size target goes to container overhead and rate control drift.
    static let safetyMargin = 0.97

    // MARK: Levels

    static func audioBitrate(_ level: CompressionLevel) -> Int {
        switch level {
        case .light: 160_000
        case .balanced: 128_000
        case .strong: 96_000
        }
    }

    /// Bits per pixel per frame for HEVC. Older codecs need about half as much again.
    private static func bitsPerPixel(_ level: CompressionLevel) -> Double {
        switch level {
        case .light: 0.10
        case .balanced: 0.06
        case .strong: 0.035
        }
    }

    /// How much of the source's own video bitrate a level may keep.
    private static func shareOfSource(_ level: CompressionLevel) -> Double {
        switch level {
        case .light: 0.8
        case .balanced: 0.6
        case .strong: 0.4
        }
    }

    static func videoBitrate(
        for video: MediaInfo.Stream,
        level: CompressionLevel,
        family: VideoFamily
    ) -> Int {
        let wanted = pixelsPerSecond(video) * bitsPerPixel(level) * (family == .hevc ? 1 : 1.5)
        var bitrate = wanted
        if let source = video.bitrate {
            bitrate = min(wanted, Double(source) * shareOfSource(level))
        }
        return max(Int(bitrate), 100_000)
    }

    /// Audio bitrate for a stream, given what a stereo stream would get.
    static func scaledAudioBitrate(_ stereo: Int, channels: Int?) -> Int {
        switch channels ?? 2 {
        case ...1: stereo * 3 / 5
        case 2: stereo
        case let count: min(stereo * min(count, 8) / 2, 512_000)
        }
    }

    // MARK: Size targets

    struct Split: Equatable {
        /// Bits per second for the video stream.
        var video: Int
        /// What the audio streams use in total.
        var audioTotal: Int
        /// What a stereo stream gets, to hand to the audio plan.
        var audioStereo: Int
    }

    static func split(info: MediaInfo, video: MediaInfo.Stream, targetBytes: Int64) throws -> Split {
        let duration = try knownDuration(info)
        let perSecond = Double(targetBytes) * 8 * safetyMargin / duration

        var stereo = 0
        var audioTotal = 0
        if !info.audioStreams.isEmpty {
            stereo = min(max(Int(perSecond * 0.12), 32_000), 128_000)
            audioTotal = info.audioStreams.reduce(0) { $0 + scaledAudioBitrate(stereo, channels: $1.channels) }
        }
        let videoBitrate = Int(perSecond) - audioTotal
        let floor = max(30_000, Int(pixelsPerSecond(video) * 0.004))
        guard videoBitrate >= floor else {
            let smallest = Int64(Double(floor + audioTotal) * duration / 8 / safetyMargin)
            throw tooSmall("video", smallest: smallest)
        }
        return Split(video: videoBitrate, audioTotal: audioTotal, audioStereo: stereo)
    }

    /// Bits per second for an audio only file.
    static func audioOnlyBitrate(info: MediaInfo, targetBytes: Int64) throws -> Int {
        let duration = try knownDuration(info)
        let bitrate = Int(Double(targetBytes) * 8 * safetyMargin / duration)
        let floor = 16_000
        guard bitrate >= floor else {
            throw tooSmall("audio file", smallest: Int64(Double(floor) * duration / 8 / safetyMargin))
        }
        return bitrate
    }

    private static func knownDuration(_ info: MediaInfo) throws -> Double {
        guard let duration = info.duration, duration > 0 else {
            throw ConversionError("The length of this file is unknown, so a size target cannot be met.")
        }
        return duration
    }

    private static func pixelsPerSecond(_ video: MediaInfo.Stream) -> Double {
        let pixels = Double((video.width ?? 1920) * (video.height ?? 1080))
        return pixels * min(video.frameRate ?? 30, 60)
    }

    private static func tooSmall(_ noun: String, smallest: Int64) -> ConversionError {
        let size = ByteCountFormatter.string(fromByteCount: max(smallest, 1), countStyle: .file)
        return ConversionError("The target size is too small for this \(noun). Try at least \(size).")
    }
}

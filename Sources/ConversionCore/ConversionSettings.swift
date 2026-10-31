import Foundation

/// What a video is written with. Automatic copies whatever the target container accepts and
/// picks an encoder only when it has to, while a named codec is always what comes out.
public enum VideoCodecChoice: String, Sendable, CaseIterable {
    case automatic, h264, hevc
}

/// The trade between size and picture when a video has to be re-encoded.
public enum VideoQuality: String, Sendable, CaseIterable {
    case smaller, standard, higher
}

/// The page a document is laid out on when it becomes a PDF.
public enum PaperSize: String, Sendable, CaseIterable {
    case a4, letter

    /// Width and height in points.
    public var points: (width: Double, height: Double) {
        switch self {
        case .a4: (595.28, 841.89)
        case .letter: (612, 792)
        }
    }
}

/// Choices for writing audio and video. The defaults are what the app recommends.
public struct MediaOptions: Sendable, Equatable {
    public var videoCodec: VideoCodecChoice
    public var videoQuality: VideoQuality
    /// The shorter side of the picture in pixels, so 1080 means 1080p in either orientation.
    /// Nil keeps the size. Videos are never enlarged.
    public var maxVideoResolution: Int?
    /// Bits per second for MP3, M4A, Ogg and Opus files. Nil uses a good default for the format.
    public var audioBitrate: Int?
    /// The widest a GIF gets, in pixels.
    public var gifWidth: Int
    public var gifFrameRate: Int
    /// Leaves tags, chapters and encoder signatures out of a converted file.
    public var removesMetadata: Bool

    public init(
        videoCodec: VideoCodecChoice = .automatic,
        videoQuality: VideoQuality = .standard,
        maxVideoResolution: Int? = nil,
        audioBitrate: Int? = nil,
        gifWidth: Int = 720,
        gifFrameRate: Int = 15,
        removesMetadata: Bool = false
    ) {
        self.videoCodec = videoCodec
        self.videoQuality = videoQuality
        self.maxVideoResolution = maxVideoResolution
        self.audioBitrate = audioBitrate
        self.gifWidth = gifWidth
        self.gifFrameRate = gifFrameRate
        self.removesMetadata = removesMetadata
    }
}

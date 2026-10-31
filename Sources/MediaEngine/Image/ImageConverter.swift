import ConversionCore
import Foundation

/// Image conversion through ImageIO, with ffmpeg only for WebP.
public enum ImageConverter {
    /// Converts to `format`. Orientation is respected, transparency goes onto white for formats
    /// without it, and the color profile travels along.
    public static func convert(
        _ input: URL,
        to output: URL,
        format: FileFormat,
        options: ImageOptions = .init()
    ) async throws {
        guard format.kind == .image else {
            throw ConversionError("\(format.label) is not an image format.")
        }
        try prepare(input: input, output: output)
        try await StagedOutput.write(to: output, replacing: input) { staged in
            if format == .webp {
                try await writeWebP(input: input, to: staged, options: options)
            } else {
                let data = try await offloaded {
                    try ImageConversion.encode(ImageSource(url: input), as: format, options: options)
                }
                try data.write(to: staged)
            }
        }
    }

    /// Re-encodes in the same format. With `targetBytes`, searches quality (and then size) to land
    /// at or under it. Never returns something larger than the source: in that case the source is
    /// copied and the result is false.
    @discardableResult
    public static func compress(
        _ input: URL,
        to output: URL,
        level: CompressionLevel,
        targetBytes: Int64? = nil
    ) async throws -> Bool {
        if let targetBytes, targetBytes <= 0 {
            throw ConversionError("The target size must be more than zero.")
        }
        try prepare(input: input, output: output)
        let sourceSize = StagedOutput.fileSize(input)

        var compressed: Data?
        if targetBytes.map({ sourceSize > $0 }) ?? true {
            compressed = try await ImageCompression.compress(input, level: level, targetBytes: targetBytes)
        }
        if let compressed, Int64(compressed.count) < sourceSize {
            try await StagedOutput.write(compressed, to: output, replacing: input)
            return true
        }
        try await StagedOutput.copy(input, to: output)
        return false
    }

    /// Writes a copy with no EXIF, GPS, IPTC, XMP or maker notes. Pictures that relied on an
    /// orientation tag are rotated upright so they still look right.
    public static func stripMetadata(_ input: URL, to output: URL) async throws {
        try prepare(input: input, output: output)
        let data = try await offloaded { try ImageStrip.stripped(input) }
        try await StagedOutput.write(data, to: output, replacing: input)
    }

    /// One page per image, page size follows each image.
    public static func makePDF(from inputs: [URL], to output: URL) async throws {
        guard !inputs.isEmpty else {
            throw ConversionError("Choose at least one image.")
        }
        for input in inputs {
            try prepare(input: input, output: output)
        }
        let data = try await offloaded { try PDFMaker.make(from: inputs) }
        try await StagedOutput.write(data, to: output)
    }

    // MARK: Helpers

    private static func prepare(input: URL, output: URL) throws {
        try StagedOutput.requireDistinct(input: input, output: output)
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError("The input file could not be found.")
        }
    }

    private enum WebPJob {
        case animation(quality: Double)
        case still(png: Data, quality: Double)
    }

    private static func writeWebP(input: URL, to staged: URL, options: ImageOptions) async throws {
        let quality = options.quality ?? FileFormat.webp.defaultQuality ?? 0.8
        // Decoding is blocking work. Only the encoder run below is asynchronous.
        let job = try await offloaded { () -> WebPJob in
            let source = try ImageSource(url: input)
            if source.format == .gif, source.isAnimated {
                return .animation(quality: quality)
            }
            let index = source.primaryIndex
            let size = source.pixelSize(at: index)
            let longest = max(size.width, size.height)
            let resizeTo = options.maxPixelSize.flatMap { $0 > 0 && $0 < longest ? $0 : nil }
            let image = try ImageRenderer.render(
                source, index: index, applyingOrientation: source.orientation(at: index) != .up, maxPixelSize: resizeTo
            )
            return .still(png: try WebPEncoder.pngData(for: image), quality: quality)
        }

        let data = try await withTemporaryFolder { folder -> Data in
            let encoder = WebPEncoder(ffmpeg: try FFmpeg.locate(), workspace: folder)
            switch job {
            case let .animation(quality):
                return try await encoder.encodeAnimation(from: input, quality: quality, maxPixelSize: options.maxPixelSize)
            case let .still(png, quality):
                return try await encoder.encode(png: png, quality: quality)
            }
        }
        try data.write(to: staged)
    }
}

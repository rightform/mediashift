import ConversionCore
import CoreGraphics
import Foundation
import ImageIO

/// Same format, fewer bytes. Each format squeezes in the way that suits it:
/// a quality dial for JPEG, HEIC, AVIF and WebP, a smaller palette for PNG and GIF, LZW for TIFF.
enum ImageCompression {
    /// The compressed file, or nil when the format has no way to get smaller without a target.
    static func compress(_ url: URL, level: CompressionLevel, targetBytes: Int64?) async throws -> Data? {
        // GIF is squeezed by ffmpeg straight from the file. Everything else is decoded once.
        let (format, frames) = try await offloaded { () -> (FileFormat, [ImageWriter.Frame]) in
            let source = try ImageSource(url: url)
            guard let format = source.format ?? FileFormat(url: url), format.kind == .image else {
                throw ConversionError("This kind of image cannot be compressed.")
            }
            if format == .gif { return (format, []) }
            return (format, try Picture(source: source, format: format).loaded())
        }
        switch format {
        case .gif:
            return try await gif(url, level: level, targetBytes: targetBytes)
        case .jpeg, .heic, .avif, .webp:
            return try await lossy(frames, format: format, level: level, targetBytes: targetBytes)
        case .png:
            return try await png(frames, level: level, targetBytes: targetBytes)
        case .tiff:
            return try await tiff(frames, targetBytes: targetBytes)
        default:
            return try await bmp(frames, targetBytes: targetBytes)
        }
    }

    // MARK: Quality dial

    private static func lossy(
        _ frames: [ImageWriter.Frame],
        format: FileFormat,
        level: CompressionLevel,
        targetBytes: Int64?
    ) async throws -> Data {
        try await withTemporaryFolder { folder in
            let webp = format == .webp ? WebPEncoder(ffmpeg: try FFmpeg.locate(), workspace: folder) : nil
            let original = frames[0]
            var scaledCache: [Double: CGImage] = [1: original.image]

            func encode(quality: Double, scale: Double) async throws -> Data {
                if scaledCache[scale] == nil {
                    scaledCache[scale] = ImageRenderer.scaled(original.image, by: scale)
                }
                var frame = original
                frame.image = scaledCache[scale] ?? original.image
                if let webp {
                    return try await webp.encode(frame.image, quality: quality)
                }
                return try await offloaded { try ImageWriter.encode([frame], as: format, quality: quality) }
            }

            if let targetBytes {
                let range = qualityRange(format)
                return try await SizeSearch.lossy(
                    target: targetBytes, floor: range.lowerBound, ceiling: range.upperBound, encode: encode
                )
            }
            return try await encode(quality: quality(format, level), scale: 1)
        }
    }

    private static func quality(_ format: FileFormat, _ level: CompressionLevel) -> Double {
        switch (format, level) {
        case (.heic, .light): 0.7
        case (.heic, .balanced): 0.55
        case (.heic, .strong): 0.4
        case (.avif, .light): 0.6
        case (.avif, .balanced): 0.45
        case (.avif, .strong): 0.3
        case (_, .light): 0.8
        case (_, .balanced): 0.65
        case (_, .strong): 0.45
        }
    }

    /// The lowest quality worth keeping before the picture shrinks instead, and the highest tried.
    private static func qualityRange(_ format: FileFormat) -> ClosedRange<Double> {
        switch format {
        case .heic: 0.25 ... 0.9
        case .avif: 0.2 ... 0.85
        default: 0.35 ... 0.95
        }
    }

    // MARK: PNG

    private struct PNGStep {
        var colors: Int?
        var scale: Double
    }

    private static func png(_ frames: [ImageWriter.Frame], level: CompressionLevel, targetBytes: Int64?) async throws -> Data? {
        // Palettes need ffmpeg. Without it, PNG can only be rewritten losslessly.
        let ffmpeg = try? FFmpeg.locate()
        return try await withTemporaryFolder { folder in
            let frame = frames[0]
            var scaledCache: [Double: CGImage] = [1: frame.image]

            func encode(_ step: PNGStep) async throws -> Data {
                if scaledCache[step.scale] == nil {
                    scaledCache[step.scale] = ImageRenderer.scaled(frame.image, by: step.scale)
                }
                var scaled = frame
                scaled.image = scaledCache[step.scale] ?? frame.image
                guard let colors = step.colors, let ffmpeg else {
                    return try await offloaded { try ImageWriter.encode([scaled], as: .png) }
                }
                return try await palettePNG(scaled.image, colors: colors, ffmpeg: ffmpeg, folder: folder)
            }

            guard let targetBytes else {
                switch level {
                case .light: return try await encode(PNGStep(colors: nil, scale: 1))
                case .balanced: return try await encode(PNGStep(colors: 256, scale: 1))
                case .strong: return try await encode(PNGStep(colors: 64, scale: 1))
                }
            }
            var steps = [PNGStep(colors: nil, scale: 1)]
            if ffmpeg != nil {
                steps += [256, 128, 64, 32].map { PNGStep(colors: $0, scale: 1) }
            }
            steps += SizeSearch.scales.dropFirst().map { PNGStep(colors: ffmpeg == nil ? nil : 64, scale: $0) }
            return try await SizeSearch.ladder(target: targetBytes, steps: steps, encode: encode)
        }
    }

    private static func palettePNG(_ image: CGImage, colors: Int, ffmpeg: FFmpeg, folder: URL) async throws -> Data {
        let name = UUID().uuidString.prefix(8)
        let input = folder.appendingPathComponent("\(name)-in.png")
        let output = folder.appendingPathComponent("\(name)-out.png")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try await offloaded { try WebPEncoder.pngData(for: image) }.write(to: input)
        let filter = "split[a][b];[a]palettegen=max_colors=\(colors):reserve_transparent=1[p];"
            + "[b][p]paletteuse=dither=bayer:bayer_scale=3"
        try await ffmpeg.execute([
            "-y", "-i", input.path, "-vf", filter, "-frames:v", "1", "-c:v", "png",
            "-compression_level", "9", "-f", "image2", "-update", "1", output.path,
        ])
        return try Data(contentsOf: output)
    }

    // MARK: GIF

    private struct GIFStep {
        var colors: Int
        var scale: Double
    }

    private static func gif(_ url: URL, level: CompressionLevel, targetBytes: Int64?) async throws -> Data {
        let ffmpeg = try FFmpeg.locate()
        return try await withTemporaryFolder { folder in
            func encode(_ step: GIFStep) async throws -> Data {
                let output = folder.appendingPathComponent("\(UUID().uuidString.prefix(8)).gif")
                defer { try? FileManager.default.removeItem(at: output) }
                let resize = step.scale < 1
                    ? "scale=trunc(iw*\(String(format: "%.3f", step.scale))/2)*2:-2:flags=lanczos,"
                    : ""
                let filter = resize + "split[a][b];[a]palettegen=max_colors=\(step.colors):stats_mode=diff[p];"
                    + "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
                try await ffmpeg.execute([
                    "-y", "-i", url.path, "-vf", filter, "-loop", "0", "-f", "gif", output.path,
                ])
                return try Data(contentsOf: output)
            }

            guard let targetBytes else {
                switch level {
                case .light: return try await encode(GIFStep(colors: 256, scale: 1))
                case .balanced: return try await encode(GIFStep(colors: 128, scale: 0.9))
                case .strong: return try await encode(GIFStep(colors: 64, scale: 0.75))
                }
            }
            let steps = [
                GIFStep(colors: 256, scale: 1), GIFStep(colors: 128, scale: 1), GIFStep(colors: 96, scale: 0.9),
                GIFStep(colors: 64, scale: 0.8), GIFStep(colors: 64, scale: 0.65), GIFStep(colors: 48, scale: 0.5),
                GIFStep(colors: 32, scale: 0.4), GIFStep(colors: 32, scale: 0.3),
            ]
            return try await SizeSearch.ladder(target: targetBytes, steps: steps, encode: encode)
        }
    }

    // MARK: TIFF and BMP

    private static func tiff(_ frames: [ImageWriter.Frame], targetBytes: Int64?) async throws -> Data? {
        func encode(scale: Double) async throws -> Data {
            try await offloaded {
                let scaled = frames.map { frame -> ImageWriter.Frame in
                    var copy = frame
                    copy.image = scale < 1 ? ImageRenderer.scaled(frame.image, by: scale) : frame.image
                    return copy
                }
                return try ImageWriter.encode(scaled, as: .tiff, lzw: true)
            }
        }
        guard let targetBytes else { return try await encode(scale: 1) }
        return try await SizeSearch.ladder(target: targetBytes, steps: SizeSearch.scales, encode: { try await encode(scale: $0) })
    }

    /// BMP is stored raw, so only a smaller picture makes a smaller file.
    private static func bmp(_ frames: [ImageWriter.Frame], targetBytes: Int64?) async throws -> Data? {
        guard let targetBytes else { return nil }
        return try await SizeSearch.ladder(target: targetBytes, steps: SizeSearch.scales) { scale in
            var frame = frames[0]
            frame.image = scale < 1 ? ImageRenderer.scaled(frame.image, by: scale) : frame.image
            return try await offloaded { [frame] in try ImageWriter.encode([frame], as: .bmp) }
        }
    }

    // MARK: Decoding

    /// The pictures of a file as upright pixels with their metadata, ready to be encoded again.
    private struct Picture {
        let source: ImageSource
        let format: FileFormat

        func loaded() throws -> [ImageWriter.Frame] {
            let animated = format == .gif && source.isAnimated
            let multiPage = format == .tiff && source.count > 1
            let indices = (animated || multiPage) ? Array(0 ..< source.count) : [source.primaryIndex]
            return try indices.map { index in
                let upright = source.orientation(at: index) != .up
                let image = try ImageRenderer.render(source, index: index, applyingOrientation: upright, maxPixelSize: nil)
                var frame = ImageWriter.Frame(image: image)
                frame.properties = ImageMetadata.carried(from: source.properties(at: index), orientationBaked: true)
                frame.metadata = ImageMetadata.xmp(of: source.source, at: index, orientationBaked: true)
                return frame
            }
        }
    }
}

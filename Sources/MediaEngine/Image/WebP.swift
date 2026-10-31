import ConversionCore
import CoreGraphics
import Foundation

/// WebP is written by ffmpeg's libwebp, because ImageIO can read the format but not write it.
/// The encoder stores no EXIF and no color profile, so pictures are converted to sRGB first.
struct WebPEncoder {
    let ffmpeg: FFmpeg
    let workspace: URL

    /// A lossless PNG of the picture in sRGB, the hand over format between ImageIO and ffmpeg.
    static func pngData(for image: CGImage) throws -> Data {
        try ImageWriter.encode([ImageWriter.Frame(image: ImageRenderer.inSRGB(image))], as: .png)
    }

    /// Encodes a still image given as PNG data. Quality 1 means lossless.
    func encode(png data: Data, quality: Double) async throws -> Data {
        let name = UUID().uuidString.prefix(8)
        let png = workspace.appendingPathComponent("\(name).png")
        let output = workspace.appendingPathComponent("\(name).webp")
        defer {
            try? FileManager.default.removeItem(at: png)
            try? FileManager.default.removeItem(at: output)
        }
        try data.write(to: png)
        let arguments = ["-y", "-i", png.path, "-map_metadata", "-1", "-c:v", "libwebp"]
            + Self.qualityArguments(quality) + ["-f", "webp", output.path]
        try await ffmpeg.execute(arguments)
        return try Data(contentsOf: output)
    }

    /// Encodes a decoded image, converting it to sRGB first.
    func encode(_ image: CGImage, quality: Double) async throws -> Data {
        let data = try await offloaded { try Self.pngData(for: image) }
        return try await encode(png: data, quality: quality)
    }

    /// Encodes an animated GIF as an animated WebP, keeping timing and transparency.
    func encodeAnimation(from input: URL, quality: Double, maxPixelSize: Int?) async throws -> Data {
        let output = workspace.appendingPathComponent("\(UUID().uuidString.prefix(8)).webp")
        defer { try? FileManager.default.removeItem(at: output) }
        var arguments = ["-y", "-i", input.path, "-map_metadata", "-1"]
        if let maxPixelSize {
            let edge = "min(\(maxPixelSize),iw)"
            let other = "min(\(maxPixelSize),ih)"
            arguments += ["-vf", "scale=\(edge):\(other):force_original_aspect_ratio=decrease:flags=lanczos"]
        }
        arguments += ["-c:v", "libwebp_anim", "-loop", "0"] + Self.qualityArguments(quality)
        arguments += ["-f", "webp", output.path]
        try await ffmpeg.execute(arguments)
        return try Data(contentsOf: output)
    }

    private static func qualityArguments(_ quality: Double) -> [String] {
        let percent = Int((min(max(quality, 0), 1) * 100).rounded())
        if percent >= 100 {
            return ["-lossless", "1", "-compression_level", "6"]
        }
        return ["-quality", String(percent), "-compression_level", "6"]
    }
}

/// The few things done to WebP files directly, without decoding them.
enum WebPContainer {
    /// Removes the EXIF and XMP chunks and leaves every pixel as it was.
    static func removingMetadata(from data: Data) throws -> Data {
        let invalid = ConversionError("This WebP file is damaged.")
        guard data.count >= 12,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8 ..< 12) == Data("WEBP".utf8) else { throw invalid }

        var output = Data("RIFF".utf8)
        output.append(contentsOf: [0, 0, 0, 0])
        output.append(Data("WEBP".utf8))

        var offset = 12
        while offset + 8 <= data.count {
            let name = String(decoding: data.subdata(in: offset ..< offset + 4), as: UTF8.self)
            let size = (0 ..< 4).reduce(0) { $0 | Int(data[offset + 4 + $1]) << (8 * $1) }
            let end = offset + 8 + size + (size & 1)
            guard end <= data.count else { throw invalid }

            switch name {
            case "EXIF", "XMP ":
                break
            case "VP8X" where size >= 1:
                var chunk = data.subdata(in: offset ..< end)
                // Flag bits for "has EXIF" and "has XMP".
                chunk[8] &= ~(0x08 | 0x04)
                output.append(chunk)
            default:
                output.append(data.subdata(in: offset ..< end))
            }
            offset = end
        }

        let riffSize = UInt32(output.count - 8)
        for position in 0 ..< 4 {
            output[4 + position] = UInt8((riffSize >> (8 * UInt32(position))) & 0xFF)
        }
        return output
    }

    /// True when the file has EXIF or XMP chunks.
    static func hasMetadata(_ data: Data) -> Bool {
        var offset = 12
        while offset + 8 <= data.count {
            let name = String(decoding: data.subdata(in: offset ..< offset + 4), as: UTF8.self)
            if name == "EXIF" || name == "XMP " { return true }
            let size = (0 ..< 4).reduce(0) { $0 | Int(data[offset + 4 + $1]) << (8 * $1) }
            offset += 8 + size + (size & 1)
        }
        return false
    }
}

/// A scratch folder that disappears when the work is done, whatever the outcome.
func withTemporaryFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaEngine-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(folder)
}

import ConversionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MediaEngine

/// Tests that need ffmpeg use this and skip cleanly when no binary can be found.
let ffmpegAvailable = FFmpegLocator.find() != nil

/// Tests that need the Mac's video encoder use this. GitHub's Intel machines are virtual, with no
/// video hardware, so the encoder cannot start there. Every Apple Silicon Mac has one, so there
/// a failure stays a failure instead of quietly skipping the tests.
let videoEncoderAvailable: Bool = {
    #if arch(arm64)
    return ffmpegAvailable
    #else
    guard ffmpegAvailable else { return false }
    let probe = try? runFFmpeg([
        "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=5:duration=0.2",
        "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-f", "null", "-",
    ])
    return probe?.status == 0
    #endif
}()

/// A fresh folder for one test. Call `remove()` in a `defer`.
struct Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEngineTests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Names of the files in the folder, hidden ones included.
    var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

func fileSize(_ url: URL) -> Int64 {
    StagedOutput.fileSize(url)
}

// MARK: - Running ffmpeg to make fixtures

/// Runs ffmpeg synchronously and returns its exit status and combined output.
func runFFmpeg(_ arguments: [String]) throws -> (status: Int32, output: String) {
    guard let executable = FFmpegLocator.find() else {
        throw ConversionError("ffmpeg is not available")
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-hide_banner", "-nostdin"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Like `runFFmpeg`, but a failure is a test failure.
@discardableResult
func makeFixture(_ arguments: [String]) throws -> String {
    let result = try runFFmpeg(["-loglevel", "error", "-y"] + arguments)
    guard result.status == 0 else {
        throw ConversionError("Fixture could not be made: \(result.output)")
    }
    return result.output
}

func mediaInfo(_ url: URL) throws -> MediaInfo {
    let result = try runFFmpeg(["-i", url.path])
    guard let info = MediaInfo(parsing: result.output) else {
        throw ConversionError("Could not read \(url.lastPathComponent): \(result.output)")
    }
    return info
}

/// A hash of one stream's packets, equal for two files exactly when the stream was copied untouched.
func streamHash(_ url: URL, map: String) throws -> String {
    let result = try runFFmpeg(["-loglevel", "error", "-i", url.path, "-map", map, "-c", "copy", "-f", "md5", "-"])
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Video fixtures. Each is a few seconds of ffmpeg's test pattern, with a sine tone unless told otherwise.
enum VideoFixture {
    static func make(
        at url: URL,
        size: String = "320x240",
        seconds: Int = 3,
        audio: Bool = true,
        videoCodec: String? = nil,
        extra: [String] = []
    ) throws {
        let ext = url.pathExtension
        let defaults: [String: (video: [String], audio: [String])] = [
            "mp4": (["-c:v", "h264_videotoolbox", "-b:v", "1500k"], ["-c:a", "aac"]),
            "mov": (["-c:v", "h264_videotoolbox", "-b:v", "1500k"], ["-c:a", "aac"]),
            "m4v": (["-c:v", "h264_videotoolbox", "-b:v", "1500k"], ["-c:a", "aac"]),
            "mkv": (["-c:v", "h264_videotoolbox", "-b:v", "1500k"], ["-c:a", "aac"]),
            "webm": (["-c:v", "libvpx-vp9", "-b:v", "500k", "-deadline", "realtime", "-cpu-used", "8"], ["-c:a", "libopus"]),
            "avi": (["-c:v", "mpeg4", "-q:v", "4"], ["-c:a", "libmp3lame"]),
        ]
        let codecs = defaults[ext] ?? defaults["mp4"]!
        var arguments = ["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=\(seconds)"]
        if audio {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"]
        }
        arguments += videoCodec.map { ["-c:v", $0] } ?? codecs.video
        arguments += audio ? codecs.audio : ["-an"]
        arguments += ["-pix_fmt", "yuv420p"] + extra + [url.path]
        try makeFixture(arguments)
    }
}

// MARK: - Image fixtures

enum ImageFixture {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Left half red, right half blue, with a white square in the top left corner so any rotation shows.
    /// With `transparentLeftHalf` the red half has no alpha. With `noise` the pixels are random.
    static func make(
        width: Int = 96,
        height: Int = 64,
        transparentLeftHalf: Bool = false,
        noise: Bool = false,
        colorSpace: CGColorSpace = srgb
    ) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if noise {
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            for offset in 0 ..< context.bytesPerRow * height {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes[offset] = UInt8(truncatingIfNeeded: state >> 33)
            }
            for row in 0 ..< height {
                for column in 0 ..< width {
                    bytes[row * context.bytesPerRow + column * 4 + 3] = 255
                }
            }
            return context.makeImage()!
        }
        if !transparentLeftHalf {
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 16, width: 16, height: 16))
        return context.makeImage()!
    }

    /// Writes an image with ImageIO directly, so the fixtures do not depend on the code under test.
    static func write(
        _ image: CGImage,
        as format: FileFormat,
        to url: URL,
        properties: [CFString: Any] = [:],
        metadata: CGImageMetadata? = nil,
        quality: Double? = nil
    ) async throws {
        if format == .webp {
            let png = url.deletingPathExtension().appendingPathExtension("fixture.png")
            try await write(image, as: .png, to: png)
            defer { try? FileManager.default.removeItem(at: png) }
            try makeFixture(["-i", png.path, "-c:v", "libwebp", "-quality", "80", url.path])
            return
        }
        // Off the cooperative pool, for the same reason as in the library: HEIC and AVIF encoders wait on queues.
        try await offloaded {
            let type = format.imageType!
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            var all = properties
            if let quality { all[kCGImageDestinationLossyCompressionQuality] = quality }
            if let metadata { all[kCGImageDestinationMetadata] = metadata }
            CGImageDestinationAddImage(destination, image, all as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError("Fixture \(format.label) could not be written")
            }
        }
    }

    /// A GIF with several differently colored frames.
    static func writeAnimatedGIF(to url: URL, frames: Int = 3) async throws {
        try await offloaded {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
            let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            CGImageDestinationSetProperties(destination, loop as CFDictionary)
            for index in 0 ..< frames {
                let context = CGContext(
                    data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                let shade = CGFloat(index + 1) / CGFloat(frames)
                context.setFillColor(CGColor(red: shade, green: 0.2, blue: 1 - shade, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
                let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
                CGImageDestinationAddImage(destination, context.makeImage()!, frame as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw ConversionError("Fixture GIF could not be written") }
        }
    }

    static func properties(of url: URL, at index: Int = 0) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
    }

    static func size(of url: URL) -> (width: Int, height: Int)? {
        let properties = properties(of: url)
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func frameCount(of url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0
    }

    static func format(of url: URL) -> FileFormat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        return FileFormat(imageTypeIdentifier: type as String)
    }

    /// The color of one pixel, counted from the top left, as red, green, blue, alpha.
    static func pixel(of url: URL, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data, x < image.width, y < image.height else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }
}

/// Is `color` close to red, blue or white? Compression moves values a little.
func isNear(_ color: (r: Int, g: Int, b: Int, a: Int)?, _ red: Int, _ green: Int, _ blue: Int, tolerance: Int = 40) -> Bool {
    guard let color else { return false }
    return abs(color.r - red) <= tolerance && abs(color.g - green) <= tolerance && abs(color.b - blue) <= tolerance
}

extension ImageFixture {
    /// Every pixel of the first picture as RGBA bytes, for checking that nothing was re-encoded.
    static func pixels(of url: URL) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}

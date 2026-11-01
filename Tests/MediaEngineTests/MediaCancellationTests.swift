import ConversionCore
import Foundation
import Testing
@testable import MediaEngine

/// Is any process running whose command line mentions `marker`?
private func isRunning(mentioning marker: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", marker]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

@Suite(.enabled(if: ffmpegAvailable)) struct MediaCancellationTests {
    /// A source that takes several seconds to turn into VP9, so there is time to cancel.
    private func makeLongSource(in scratch: Scratch) throws -> URL {
        let url = scratch.file("long.mp4")
        try makeFixture([
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25:duration=30",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=30",
            "-c:v", "h264_videotoolbox", "-b:v", "6M", "-c:a", "aac", "-pix_fmt", "yuv420p", url.path,
        ])
        return url
    }

    @Test(.enabled(if: videoEncoderAvailable), .timeLimit(.minutes(2)))
    func cancellingStopsFFmpegAndRemovesTheOutput() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = try makeLongSource(in: scratch)
        let output = scratch.file("long.webm")
        let marker = scratch.url.lastPathComponent

        let task = Task {
            try await MediaConverter.convert(input, to: output, format: .webm)
        }
        // Wait until the encoder is really running, then pull the plug.
        var waited = 0
        while !isRunning(mentioning: marker + "/.") && waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        do {
            try await task.value
            Issue.record("The conversion finished instead of being cancelled")
        } catch is CancellationError {
            // Expected.
        }

        #expect(!isRunning(mentioning: marker + "/."), "ffmpeg is still running")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(scratch.contents == ["long.mp4"], "leftover files: \(scratch.contents)")
    }

    @Test(.enabled(if: videoEncoderAvailable), .timeLimit(.minutes(2)))
    func cancellingACompressionCleansUpEveryAttempt() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = try makeLongSource(in: scratch)
        let output = scratch.file("small.mp4")
        let size = fileSize(input)

        let task = Task {
            try await MediaConverter.compress(input, to: output, level: .strong, targetBytes: size / 4)
        }
        try await Task.sleep(for: .milliseconds(800))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!isRunning(mentioning: scratch.url.lastPathComponent + "/."))
        #expect(scratch.contents == ["long.mp4"], "leftover files: \(scratch.contents)")
    }

    @Test(.enabled(if: videoEncoderAvailable)) func cancellingBeforeStartingDoesNothing() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = scratch.file("clip.mp4")
        try VideoFixture.make(at: input)
        let output = scratch.file("clip.mov")

        let task = Task {
            try await Task.sleep(for: .seconds(5))
            try await MediaConverter.convert(input, to: output, format: .mov)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(scratch.contents == ["clip.mp4"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aTalkativeFFmpegNeverStallsOnAFullPipe() async throws {
        let ffmpeg = try FFmpeg.locate()
        // The showinfo filter logs every frame, several hundred kilobytes in all. A pipe holds 64.
        let output = try await ffmpeg.run([
            "-hide_banner", "-loglevel", "info", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=60",
            "-vf", "showinfo", "-f", "null", "-",
        ])
        #expect(output.status == 0)
        #expect(output.log.utf8.count > 100_000)
    }
}

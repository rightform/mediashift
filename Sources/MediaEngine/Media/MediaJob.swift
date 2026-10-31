import ConversionCore
import Foundation

/// Everything one audio or video conversion needs: the tool, what the input holds, and where to report.
struct MediaJob: Sendable {
    let ffmpeg: FFmpeg
    let input: URL
    let info: MediaInfo
    let capabilities: MediaCapabilities
    let progress: ProgressSink

    init(input: URL, output: URL, progress handler: ProgressHandler?) async throws {
        try StagedOutput.requireDistinct(input: input, output: output)
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError("The input file could not be found.")
        }
        let ffmpeg = try FFmpeg.locate()
        self.ffmpeg = ffmpeg
        self.input = input
        self.info = try await ffmpeg.probe(input)
        self.capabilities = try await ffmpeg.capabilities()
        self.progress = ProgressSink(handler)
    }

    /// Runs the first argument list ffmpeg accepts. Cancellation and missing tools end it at once;
    /// anything else moves on to the next, simpler list.
    func encode(_ lists: [[String]], to destination: URL, range: ClosedRange<Double> = 0 ... 1) async throws {
        let report = progress.scaled(to: range)
        let duration = info.duration
        var lastError: ConversionError?

        for arguments in lists {
            try Task.checkCancellation()
            do {
                let command = ["-y", "-i", input.path] + arguments + [destination.path]
                try await ffmpeg.execute(command) { seconds in
                    if let duration, duration > 0 {
                        report(seconds / duration)
                    }
                }
                return
            } catch let error as ConversionError {
                lastError = error
                try? FileManager.default.removeItem(at: destination)
            }
        }
        throw lastError ?? ConversionError("The conversion failed.")
    }
}

import ConversionCore
import Foundation

/// Audio and video through ffmpeg. One code path for every format, stream copy where it is safe.
public enum MediaConverter {
    /// Converts to `format`. Streams the target container already accepts are copied, not re-encoded.
    public static func convert(
        _ input: URL,
        to output: URL,
        format: FileFormat,
        progress: ProgressHandler? = nil
    ) async throws {
        let job = try await MediaJob(input: input, output: output, progress: progress)
        let lists = try MediaPlan.convert(job.info, to: format, capabilities: job.capabilities)
        try await StagedOutput.write(to: output, replacing: input) { staged in
            try await job.encode(lists, to: staged)
        }
        job.progress.finish()
    }

    /// Re-encodes to a smaller file in the container named by `output`, or the input's own.
    /// With `targetBytes` the result lands at or under that size. When nothing smaller than the
    /// source can be made, `output` becomes a copy of the source.
    public static func compress(
        _ input: URL,
        to output: URL,
        level: CompressionLevel,
        targetBytes: Int64? = nil,
        progress: ProgressHandler? = nil
    ) async throws {
        if let targetBytes, targetBytes <= 0 {
            throw ConversionError("The target size must be more than zero.")
        }
        let job = try await MediaJob(input: input, output: output, progress: progress)
        guard let format = FileFormat(url: output) ?? FileFormat(url: input),
              format.kind == .video || format.kind == .audio else {
            throw ConversionError("This kind of file cannot be compressed here.")
        }
        let sourceSize = StagedOutput.fileSize(input)
        let alreadyFits = targetBytes.map { sourceSize <= $0 } ?? false

        try await StagedOutput.write(to: output, replacing: input) { staged in
            var smaller = false
            if !alreadyFits {
                smaller = try await job.compress(
                    into: staged, format: format, level: level, targetBytes: targetBytes, sourceSize: sourceSize
                )
            }
            if !smaller {
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: input, to: staged)
            }
        }
        job.progress.finish()
    }

    /// Removes tags, chapters and encoder signatures without re-encoding anything.
    public static func stripMetadata(
        _ input: URL,
        to output: URL,
        progress: ProgressHandler? = nil
    ) async throws {
        let job = try await MediaJob(input: input, output: output, progress: progress)
        let format = FileFormat(url: output) ?? FileFormat(url: input)
        let lists = MediaPlan.strip(job.info, format: format)
        try await StagedOutput.write(to: output, replacing: input) { staged in
            try await job.encode(lists, to: staged)
        }
        job.progress.finish()
    }
}

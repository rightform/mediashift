import ConversionCore
import Foundation

extension MediaJob {
    /// Writes a smaller version into `staged`. Returns false when the result would not be smaller
    /// than the source, in which case the caller keeps the source.
    func compress(
        into staged: URL,
        format: FileFormat,
        level: CompressionLevel,
        targetBytes: Int64?,
        sourceSize: Int64,
        options: MediaOptions = MediaOptions()
    ) async throws -> Bool {
        if format.kind == .audio {
            try await compressAudio(into: staged, format: format, level: level, targetBytes: targetBytes)
        } else {
            try await compressVideo(into: staged, format: format, level: level, targetBytes: targetBytes, options: options)
        }
        return StagedOutput.fileSize(staged) < sourceSize
    }

    // MARK: Video

    private func compressVideo(
        into staged: URL,
        format: FileFormat,
        level: CompressionLevel,
        targetBytes: Int64?,
        options: MediaOptions
    ) async throws {
        guard let video = info.mainVideo else {
            throw ConversionError("This file has no video to compress.")
        }
        func plan(videoBitrate: Int?, audioBitrate: Int) throws -> VideoPlan {
            let compression = VideoPlan.Compression(level: level, videoBitrate: videoBitrate, audioBitrate: audioBitrate)
            return try VideoPlan(info: info, format: format, capabilities: capabilities, compression: compression, options: options)
        }

        guard let targetBytes else {
            let lists = try plan(videoBitrate: nil, audioBitrate: MediaBudget.audioBitrate(level)).attempts()
            try await encode(lists, to: staged)
            return
        }
        let split = try MediaBudget.split(info: info, video: video, targetBytes: targetBytes)
        try await search(
            target: targetBytes, initialBitrate: split.video, fixedBitrate: split.audioTotal,
            minimumBitrate: 30_000, into: staged
        ) { bitrate in
            try plan(videoBitrate: bitrate, audioBitrate: split.audioStereo).attempts()
        }
    }

    // MARK: Audio

    private func compressAudio(
        into staged: URL,
        format: FileFormat,
        level: CompressionLevel,
        targetBytes: Int64?
    ) async throws {
        func plan(bitrate: Int?) -> AudioPlan {
            AudioPlan(info: info, format: format, capabilities: capabilities, mode: .compress(level, bitrate: bitrate))
        }

        guard let targetBytes else {
            try await encode(plan(bitrate: nil).attempts(), to: staged)
            return
        }
        try AudioPlan.requireLossy(format)
        let initial = try MediaBudget.audioOnlyBitrate(info: info, targetBytes: targetBytes)
        try await search(
            target: targetBytes, initialBitrate: initial, fixedBitrate: 0,
            minimumBitrate: 16_000, into: staged
        ) { bitrate in
            try plan(bitrate: bitrate).attempts()
        }
    }

    // MARK: Landing on a size

    /// Encodes at a bitrate, measures, and corrects, up to three times. Keeps the largest result
    /// that fits under the target, aiming for 90 to 100 percent of it.
    private func search(
        target: Int64,
        initialBitrate: Int,
        fixedBitrate: Int,
        minimumBitrate: Int,
        into staged: URL,
        plans: (Int) throws -> [[String]]
    ) async throws {
        let duration = info.duration ?? 1
        let ranges: [ClosedRange<Double>] = [0 ... 0.6, 0.6 ... 0.85, 0.85 ... 1]
        let folder = staged.deletingLastPathComponent()
        let fileManager = FileManager.default
        var candidates: [URL] = []
        defer { candidates.forEach { try? fileManager.removeItem(at: $0) } }

        var bitrate = initialBitrate
        var best: (url: URL, size: Int64)?

        for (attempt, range) in ranges.enumerated() {
            let candidate = folder.appendingPathComponent(".try\(attempt)-\(staged.lastPathComponent)")
            candidates.append(candidate)
            try await encode(try plans(bitrate), to: candidate, range: range)

            let size = StagedOutput.fileSize(candidate)
            if size <= target, size > (best?.size ?? 0) {
                best = (candidate, size)
            }
            let landed = size <= target && Double(size) >= 0.9 * Double(target)
            if landed || attempt == ranges.count - 1 { break }

            // Rate control is only roughly accurate, so scale the variable part by how far off it was.
            let actual = Double(size) * 8 / duration - Double(fixedBitrate)
            let wanted = Double(target) * 8 * 0.95 / duration - Double(fixedBitrate)
            guard actual > 0, wanted >= Double(minimumBitrate) else { break }
            let next = Int(Double(bitrate) * min(max(wanted / actual, 0.3), 3))
            if next == bitrate { break }
            bitrate = next
        }

        guard let best else {
            throw ConversionError("This could not be made small enough. Try a larger target size.")
        }
        try? fileManager.removeItem(at: staged)
        try fileManager.moveItem(at: best.url, to: staged)
    }
}

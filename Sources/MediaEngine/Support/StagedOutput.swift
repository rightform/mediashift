import ConversionCore
import Foundation

/// Writes results next to their destination under a temporary name and renames on success,
/// so a failure or a cancellation never leaves a half written file behind.
enum StagedOutput {
    /// Runs `body` with a temporary URL. The file it writes there replaces `output` when `body` returns.
    static func write(
        to output: URL,
        replacing input: URL? = nil,
        _ body: (URL) async throws -> Void
    ) async throws {
        if let input {
            try requireDistinct(input: input, output: output)
        }
        let fileManager = FileManager.default
        let folder = output.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // Same extension at the end, so tools that guess the format from the name still work.
        let staged = folder.appendingPathComponent(".\(UUID().uuidString.prefix(8))-\(output.lastPathComponent)")
        do {
            try await body(staged)
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: staged.path) else {
                throw ConversionError("The conversion did not produce a file.")
            }
            if fileManager.fileExists(atPath: output.path) {
                _ = try fileManager.replaceItemAt(output, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: output)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    /// Writes the bytes of `data` as the result.
    static func write(_ data: Data, to output: URL, replacing input: URL? = nil) async throws {
        try await write(to: output, replacing: input) { staged in
            try data.write(to: staged)
        }
    }

    /// Makes the result an exact copy of the source.
    static func copy(_ input: URL, to output: URL) async throws {
        try await write(to: output, replacing: input) { staged in
            try FileManager.default.copyItem(at: input, to: staged)
        }
    }

    /// Throws when the output would overwrite the input, including through symlinks and case changes.
    static func requireDistinct(input: URL, output: URL) throws {
        if canonicalPath(input) == canonicalPath(output) {
            throw ConversionError("The output file must be different from the input file.")
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    private static func canonicalPath(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return folder.appendingPathComponent(url.lastPathComponent).standardizedFileURL.path.lowercased()
    }
}

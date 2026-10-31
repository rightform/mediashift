import Foundation

/// A failure worth showing to the user. The description is written for people, not logs.
public struct ConversionError: LocalizedError, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// How hard to compress. Maps to a quality value or bitrate in each engine.
public enum CompressionLevel: String, Sendable, CaseIterable, Codable {
    case light, balanced, strong
}

/// Reports progress from 0 to 1. Called from any thread.
public typealias ProgressHandler = @Sendable (Double) -> Void

/// Picks where a result goes without ever touching an existing file.
public enum OutputNaming {
    /// `report.docx` to `report.pdf`, or `report-2.pdf` if that name is taken.
    /// A result that keeps its format gets a suffix, so it can never replace its source.
    public static func outputURL(
        for input: URL,
        format: FileFormat,
        suffix: String? = nil,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        unusedURL(for: input, fileExtension: format.fileExtension, suffix: suffix, directory: directory, fileManager: fileManager)
    }

    /// A processed copy keeps its source's own spelling, so `a.JPG` becomes `a-clean.JPG`.
    public static func copyURL(
        for input: URL,
        suffix: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        unusedURL(for: input, fileExtension: input.pathExtension, suffix: suffix, directory: directory, fileManager: fileManager)
    }

    /// Turns what someone typed into a safe part of a file name. Nil when nothing usable is left.
    public static func cleanSuffix(_ raw: String) -> String? {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let kept = raw.unicodeScalars.filter { !unsafe.contains($0) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-.")))
        return text.isEmpty ? nil : String(text.prefix(40))
    }

    private static func unusedURL(
        for input: URL,
        fileExtension: String,
        suffix: String?,
        directory: URL?,
        fileManager: FileManager
    ) -> URL {
        let folder = directory ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + (suffix.map { "-\($0)" } ?? "")
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    /// A folder next to the input for results that are several files, such as one image per page.
    public static func outputFolder(
        for input: URL,
        suffix: String? = nil,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let folder = directory ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + (suffix.map { "-\($0)" } ?? "")
        var candidate = folder.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }
}

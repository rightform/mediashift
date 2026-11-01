import Foundation

/// Finds the ffmpeg binary the media and image engines shell out to.
public enum FFmpegLocator {
    /// Search order: the `FFMPEG_PATH` environment variable, `bin/ffmpeg` in the app bundle's
    /// resources, the same place seen from the command line tool inside the app,
    /// `vendor/ffmpeg/bin/ffmpeg` walking up from the executable and from the current directory,
    /// then Homebrew's place on Apple Silicon and on Intel.
    public static func find() -> URL? {
        var candidates: [URL] = []

        if let path = ProcessInfo.processInfo.environment["FFMPEG_PATH"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/ffmpeg"))
        }
        // Follows a symlink in the PATH back to the tool's real place in Contents/Helpers.
        if let tool = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(tool.deletingLastPathComponent().appendingPathComponent("../Resources/bin/ffmpeg").standardizedFileURL)
        }
        let starts = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        ]
        for start in starts.compactMap({ $0 }) {
            candidates.append(contentsOf: vendorCandidates(walkingUpFrom: start))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))

        return candidates.first(where: isRunnable)
    }

    private static func vendorCandidates(walkingUpFrom start: URL) -> [URL] {
        var found: [URL] = []
        var directory = start.standardizedFileURL
        while true {
            found.append(directory.appendingPathComponent("vendor/ffmpeg/bin/ffmpeg"))
            if directory.path == "/" || directory.path.isEmpty { break }
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
        return found
    }

    private static func isRunnable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }
}

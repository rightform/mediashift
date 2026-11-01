import ConversionCore
import Foundation

/// A located ffmpeg binary and the one way this module runs it.
struct FFmpeg: Sendable {
    let executable: URL

    static func locate() throws -> FFmpeg {
        guard let url = FFmpegLocator.find() else {
            throw ConversionError("ffmpeg was not found. Run scripts/build-ffmpeg.sh to build it.")
        }
        return FFmpeg(executable: url)
    }

    struct Output: Sendable {
        var status: Int32
        /// What ffmpeg wrote to standard error, which is where it explains itself.
        var log: String
        /// What it wrote to standard output. Only kept when asked for.
        var text: String = ""
    }

    /// Runs ffmpeg to the end. A cancelled task terminates the process and throws `CancellationError`.
    /// A non-zero exit is returned, not thrown, because probing deliberately ends that way.
    func run(
        _ arguments: [String],
        capturesOutput: Bool = false,
        onOutputTime: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Output {
        let process = RunningProcess()
        let output = try await withTaskCancellationHandler {
            try await process.run(
                executable: executable, arguments: arguments, capturesOutput: capturesOutput, onOutputTime: onOutputTime
            )
        } onCancel: {
            process.cancel()
        }
        if process.wasCancelled || Task.isCancelled {
            throw CancellationError()
        }
        return output
    }

    /// Runs a conversion. Throws a `ConversionError` carrying the last useful line of ffmpeg's complaint.
    /// `onOutputTime` receives how many seconds of output exist so far.
    func execute(_ arguments: [String], onOutputTime: (@Sendable (Double) -> Void)? = nil) async throws {
        let flags = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-progress", "pipe:1"]
        let output = try await run(flags + arguments, onOutputTime: onOutputTime)
        guard output.status == 0 else {
            throw ConversionError(Self.failureMessage(from: output.log))
        }
    }

    /// Reads stream and duration details by asking ffmpeg to open the file and stop.
    func probe(_ url: URL) async throws -> MediaInfo {
        let output = try await run(["-hide_banner", "-nostdin", "-i", url.path])
        guard let info = MediaInfo(parsing: output.log) else {
            let reason = Self.lastMeaningfulLine(of: output.log)
            throw ConversionError(reason.map { "This file could not be read: \($0)" } ?? "This file could not be read.")
        }
        return info
    }

    /// Which encoders this build has. Asked once per binary.
    func capabilities() async throws -> MediaCapabilities {
        if let known = Self.capabilityCache.value(for: executable.path) {
            return known
        }
        let output = try await run(["-hide_banner", "-encoders"], capturesOutput: true)
        let capabilities = MediaCapabilities(encoders: Self.parseEncoders(output.text))
        Self.capabilityCache.store(capabilities, for: executable.path)
        return capabilities
    }

    // MARK: Parsing ffmpeg's text

    static func parseEncoders(_ listing: String) -> Set<String> {
        var names = Set<String>()
        for line in listing.split(separator: "\n") {
            // " V....D libx264   description", six flag characters then the name.
            let characters = Array(line)
            guard characters.count > 8, characters[0] == " ", characters[7] == " ",
                  "VAS".contains(characters[1]) else { continue }
            let name = line.dropFirst(8).prefix { $0 != " " }
            if !name.isEmpty, name != "=" {
                names.insert(String(name))
            }
        }
        return names
    }

    static func failureMessage(from log: String) -> String {
        // The last line would only say that nothing came out. This says why, and what still works.
        if log.contains("Cannot create compression session") {
            return "This Mac could not start its video encoder. WebM does not need it, so try that instead."
        }
        guard let reason = lastMeaningfulLine(of: log) else { return "The conversion failed." }
        return "The conversion failed: \(reason)"
    }

    /// The last line of ffmpeg's log that says something, cleaned up for people.
    static func lastMeaningfulLine(of log: String) -> String? {
        let noise = ["Conversion failed", "frame=", "size=", "video:", "audio:", "Press ", "Input #", "Output #"]
        for raw in log.split(separator: "\n").reversed() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Drop the "[h264 @ 0x1234] " prefix that names an internal component.
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                line = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty || noise.contains(where: { line.hasPrefix($0) }) { continue }
            return plain(line)
        }
        return nil
    }

    /// Keeps messages in the house style: no exclamation marks, no long dashes.
    static func plain(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.count > 160 ? String(cleaned.prefix(160)) + "..." : cleaned
    }

    private static let capabilityCache = CapabilityCache()
}

/// The encoders a given ffmpeg build offers, so plans can pick the best one that exists.
struct MediaCapabilities: Sendable {
    var encoders: Set<String>

    func first(of names: [String]) -> String? {
        names.first(where: encoders.contains)
    }
}

private final class CapabilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: MediaCapabilities] = [:]

    func value(for key: String) -> MediaCapabilities? {
        lock.withLock { storage[key] }
    }

    func store(_ value: MediaCapabilities, for key: String) {
        lock.withLock { storage[key] = value }
    }
}

// MARK: - Process plumbing

/// One ffmpeg process. Both pipes are read the whole time it runs, so a chatty ffmpeg can
/// never fill a pipe and stall.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var started = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let pid: pid_t? = lock.withLock {
            cancelled = true
            return started && process.isRunning ? process.processIdentifier : nil
        }
        guard let pid else { return }
        kill(pid, SIGTERM)
        // ffmpeg normally stops at once. If it is stuck, make sure.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    func run(
        executable: URL,
        arguments: [String],
        capturesOutput: Bool,
        onOutputTime: (@Sendable (Double) -> Void)?
    ) async throws -> FFmpeg.Output {
        try await withCheckedThrowingContinuation { continuation in
            process.executableURL = executable
            process.arguments = arguments
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = standardOutput
            process.standardError = standardError

            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in group.leave() }

            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
            } catch {
                lock.unlock()
                continuation.resume(throwing: ConversionError("ffmpeg could not be started."))
                return
            }
            started = true
            lock.unlock()

            let progressLines = LineReader { line in
                guard let onOutputTime, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return }
                if let microseconds = Double(line.dropFirst("out_time_us=".count)), microseconds >= 0 {
                    onOutputTime(microseconds / 1_000_000)
                }
            }
            let log = TextTail()
            let text = TextTail()
            group.enter()
            Self.drain(standardOutput, onEnd: { group.leave() }) { data in
                if capturesOutput { text.append(data) }
                progressLines.feed(data)
            }
            group.enter()
            Self.drain(standardError, onEnd: { group.leave() }, onData: log.append)

            group.notify(queue: .global()) { [process] in
                let output = FFmpeg.Output(status: process.terminationStatus, log: log.text, text: text.text)
                continuation.resume(returning: output)
            }
        }
    }

    private static func drain(
        _ pipe: Pipe,
        onEnd: @escaping @Sendable () -> Void,
        onData: @escaping @Sendable (Data) -> Void
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                onEnd()
            } else {
                onData(data)
            }
        }
    }
}

/// Splits a byte stream into lines.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        var lines: [String] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex ... newline)
            }
        }
        lines.forEach(onLine)
    }
}

/// Keeps the end of a log, which is where the reason for a failure lives.
private final class TextTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 256 * 1024

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit {
                data.removeFirst(data.count - limit / 2)
            }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

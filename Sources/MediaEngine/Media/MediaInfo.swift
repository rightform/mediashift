import Foundation

/// What `ffmpeg -i` says about a file: how long it is and which streams it holds.
struct MediaInfo: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case video, audio, subtitle, data, attachment
    }

    struct Stream: Sendable, Equatable {
        var index: Int
        var kind: Kind
        var codec: String
        var width: Int?
        var height: Int?
        var frameRate: Double?
        /// Bits per second, when the file says.
        var bitrate: Int?
        var pixelFormat: String?
        var sampleRate: Int?
        var channels: Int?
        var bitDepth: Int?
        /// Cover art stored as a video stream.
        var isAttachedPicture = false
    }

    var duration: Double?
    var bitrate: Int?
    var streams: [Stream]

    var mainVideo: Stream? { streams.first { $0.kind == .video && !$0.isAttachedPicture } }
    var audioStreams: [Stream] { streams.filter { $0.kind == .audio } }
    var subtitleStreams: [Stream] { streams.filter { $0.kind == .subtitle } }
    var attachedPicture: Stream? { streams.first { $0.kind == .video && $0.isAttachedPicture } }

    init(duration: Double?, bitrate: Int?, streams: [Stream]) {
        self.duration = duration
        self.bitrate = bitrate
        self.streams = streams
    }

    /// Reads the log ffmpeg prints for `-i file`. Returns nil when the file did not open.
    init?(parsing log: String) {
        guard log.contains("Input #0") else { return nil }
        var streams: [Stream] = []
        var duration: Double?
        var bitrate: Int?
        var sawDuration = false

        for raw in log.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Duration: "), !sawDuration {
                sawDuration = true
                (duration, bitrate) = Self.parseDuration(line)
            } else if line.hasPrefix("Stream #0:"), let stream = Self.parseStream(line) {
                streams.append(stream)
            }
        }
        self.duration = duration
        self.bitrate = bitrate
        self.streams = streams
    }

    // MARK: Parsing

    private static func parseDuration(_ line: String) -> (Double?, Int?) {
        // "Duration: 00:00:05.02, start: 0.000000, bitrate: 1724 kb/s"
        let parts = splitTopLevel(String(line.dropFirst("Duration: ".count)))
        var seconds: Double?
        if let clock = parts.first {
            let fields = clock.split(separator: ":")
            if fields.count == 3, let h = Double(fields[0]), let m = Double(fields[1]), let s = Double(fields[2]) {
                seconds = h * 3600 + m * 60 + s
            }
        }
        var bitrate: Int?
        for part in parts where part.hasPrefix("bitrate: ") {
            bitrate = kilobits(part.dropFirst("bitrate: ".count))
        }
        return (seconds, bitrate)
    }

    private static func parseStream(_ line: String) -> Stream? {
        let kinds: [(String, Kind)] = [
            (": Video: ", .video), (": Audio: ", .audio), (": Subtitle: ", .subtitle),
            (": Data: ", .data), (": Attachment: ", .attachment),
        ]
        let header = line.dropFirst("Stream #0:".count)
        guard let index = Int(header.prefix(while: \.isNumber)) else { return nil }
        guard let (marker, kind) = kinds.first(where: { line.contains($0.0) }),
              let range = line.range(of: marker) else { return nil }

        let rest = String(line[range.upperBound...])
        let tokens = splitTopLevel(rest)
        guard let first = tokens.first else { return nil }

        var stream = Stream(index: index, kind: kind, codec: String(first.prefix { $0 != " " }))
        stream.isAttachedPicture = rest.contains("(attached pic)")

        for (position, token) in tokens.enumerated().dropFirst() {
            if let size = dimensions(token), stream.width == nil {
                stream.width = size.0
                stream.height = size.1
            } else if token.hasSuffix(" fps") {
                stream.frameRate = Double(token.dropLast(4))
            } else if token.contains(" kb/s") {
                // May be followed by a flag such as "(default)".
                stream.bitrate = kilobits(token)
            } else if token.hasSuffix(" Hz") {
                stream.sampleRate = Int(token.dropLast(3))
            } else if kind == .video, position == 1, stream.pixelFormat == nil {
                stream.pixelFormat = String(token.prefix { $0 != "(" })
            } else if kind == .audio {
                if let count = channelCount(token) {
                    stream.channels = count
                } else if let depth = bitDepth(token) {
                    stream.bitDepth = depth
                }
            }
        }
        return stream
    }

    private static func dimensions(_ token: String) -> (Int, Int)? {
        let head = token.prefix { $0 != " " }
        let sides = head.split(separator: "x")
        guard sides.count == 2, let width = Int(sides[0]), let height = Int(sides[1]) else { return nil }
        return (width, height)
    }

    private static func kilobits(_ text: some StringProtocol) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return Int(digits).map { $0 * 1000 }
    }

    private static func channelCount(_ token: String) -> Int? {
        switch token {
        case "mono": return 1
        case "stereo", "downmix": return 2
        case "quad": return 4
        case "hexagonal": return 6
        case "octagonal": return 8
        default: break
        }
        if token.hasSuffix(" channels") {
            return Int(token.dropLast(" channels".count))
        }
        // Layouts like "5.1" or "5.1(side)".
        let layout = token.prefix { $0.isNumber || $0 == "." }
        let sides = layout.split(separator: ".")
        if sides.count == 2, let main = Int(sides[0]), let low = Int(sides[1]), token.first?.isNumber == true {
            return main + low
        }
        return nil
    }

    private static func bitDepth(_ token: String) -> Int? {
        // "s32 (24 bit)", "s16", "s16p", "fltp", "dbl"
        if let open = token.range(of: "("), let close = token.range(of: " bit)") {
            return Int(token[open.upperBound ..< close.lowerBound])
        }
        let name = token.prefix { $0 != " " }
        if name.hasPrefix("flt") { return 32 }
        if name.hasPrefix("dbl") { return 64 }
        if name.hasPrefix("u8") { return 8 }
        if name.hasPrefix("s") {
            return Int(name.dropFirst().prefix { $0.isNumber })
        }
        return nil
    }

    /// Splits at ", " outside any brackets, which is how ffmpeg separates stream details.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var previousWasComma = false
        for character in text {
            if previousWasComma {
                previousWasComma = false
                if character == " " {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
                current.append(",")
            }
            switch character {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default: break
            }
            if character == ",", depth == 0 {
                previousWasComma = true
            } else {
                current.append(character)
            }
        }
        if previousWasComma { current.append(",") }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }
}

extension MediaInfo.Stream {
    /// True for lossless audio stored with more than 16 bits. Lossy codecs decode to floats, which says nothing.
    var hasHighBitDepth: Bool {
        let lossless = codec.hasPrefix("pcm_") || ["flac", "alac", "wavpack", "ape", "tta", "truehd", "mlp"].contains(codec)
        return lossless && (bitDepth ?? 16) > 16
    }
}

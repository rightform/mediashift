import ConversionCore
import Foundation

/// Raw Snappy, as used inside IWA files: no stream header and no checksums.
enum Snappy {
    private static let malformed = ConversionError("This file is damaged.")

    /// - Parameter limit: The largest output accepted, whatever size the data declares.
    static func decompress(_ input: Data, limit: Int) throws -> Data {
        try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data in
            var position = 0
            let length = try readLength(source, &position)
            guard length <= limit else { throw malformed }

            var output = Data(count: length)
            let written = try output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
                var cursor = 0
                while position < source.count {
                    let tag = source[position]
                    position += 1
                    let kind = tag & 0b11
                    if kind == 0 {
                        var size = Int(tag >> 2)
                        if size >= 60 {
                            let extraBytes = size - 59
                            guard position + extraBytes <= source.count else { throw malformed }
                            size = 0
                            for index in 0..<extraBytes {
                                size |= Int(source[position + index]) << (8 * index)
                            }
                            position += extraBytes
                        }
                        size += 1
                        guard position + size <= source.count, cursor + size <= length else { throw malformed }
                        destination[cursor..<(cursor + size)].copyBytes(from: source[position..<(position + size)])
                        position += size
                        cursor += size
                    } else {
                        var size: Int
                        var offset: Int
                        switch kind {
                        case 1:
                            guard position < source.count else { throw malformed }
                            size = Int((tag >> 2) & 0b111) + 4
                            offset = Int(tag >> 5) << 8 | Int(source[position])
                            position += 1
                        case 2:
                            guard position + 2 <= source.count else { throw malformed }
                            size = Int(tag >> 2) + 1
                            offset = Int(source[position]) | Int(source[position + 1]) << 8
                            position += 2
                        default:
                            guard position + 4 <= source.count else { throw malformed }
                            size = Int(tag >> 2) + 1
                            offset = 0
                            for index in 0..<4 {
                                offset |= Int(source[position + index]) << (8 * index)
                            }
                            position += 4
                        }
                        guard offset > 0, offset <= cursor, cursor + size <= length else { throw malformed }
                        // The ranges may overlap, which is how Snappy encodes runs.
                        while size > 0 {
                            destination[cursor] = destination[cursor - offset]
                            cursor += 1
                            size -= 1
                        }
                    }
                }
                return cursor
            }
            guard written == length else { throw malformed }
            return output
        }
    }

    /// A valid Snappy block made of one literal. It does not compress at all, which is fine
    /// for the small part of a document this code rewrites.
    static func compressAsLiteral(_ input: Data) -> Data {
        var output = Data()
        output.reserveCapacity(input.count + 12)
        var length = input.count
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length > 0 { byte |= 0x80 }
            output.append(byte)
        } while length > 0

        if !input.isEmpty {
            let size = input.count - 1
            if size < 60 {
                output.append(UInt8(size) << 2)
            } else {
                let extraBytes = size < 1 << 8 ? 1 : (size < 1 << 16 ? 2 : (size < 1 << 24 ? 3 : 4))
                output.append(UInt8(59 + extraBytes) << 2)
                for index in 0..<extraBytes {
                    output.append(UInt8((size >> (8 * index)) & 0xFF))
                }
            }
            output.append(input)
        }
        return output
    }

    private static func readLength(_ source: UnsafeRawBufferPointer, _ position: inout Int) throws -> Int {
        var value = 0
        var shift = 0
        while true {
            guard position < source.count, shift <= 28 else { throw malformed }
            let byte = source[position]
            position += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }
}

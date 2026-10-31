import ConversionCore
import Foundation

/// One object in an IWA file: its `ArchiveInfo` header and one or more typed payloads.
struct IWAObject {
    struct Message {
        /// The `MessageInfo`: type, version, payload length, references.
        var info: ProtoMessage
        var payload: Data

        var type: UInt64 {
            info.varint(1) ?? 0
        }

        var objectReferences: [UInt64] {
            info.varints(5)
        }

        var dataReferences: [UInt64] {
            info.varints(6)
        }

        func parsed() -> ProtoMessage? {
            try? ProtoMessage(parsing: payload)
        }

        /// Makes the references list contain `identifiers`, as iWork expects of a payload that points at them.
        mutating func addObjectReferences(_ identifiers: some Sequence<UInt64>) {
            var references = objectReferences
            var known = Set(references)
            for identifier in identifiers where known.insert(identifier).inserted {
                references.append(identifier)
            }
            info.set(ProtoMessage.Field(5, .bytes(ProtoMessage.packVarints(references))))
        }
    }

    /// `ArchiveInfo`, whose field 2 repeats the `MessageInfo` of each payload.
    var header: ProtoMessage
    var messages: [Message]

    var identifier: UInt64 {
        header.varint(1) ?? 0
    }
}

/// The contents of an `.iwa` file. On disk: chunks of a zero byte, a 3 byte little endian
/// length and raw Snappy data. Inside: repeated varint-prefixed `ArchiveInfo` headers, each
/// followed by its payloads.
struct IWAStream {
    /// The most data one stream may expand to.
    static let decompressedLimit = 1 << 30

    var objects: [IWAObject]

    init(compressed data: Data) throws {
        objects = try Self.parseObjects(try Self.decompress(data), tolerant: false)
    }

    init(objects: [IWAObject]) {
        self.objects = objects
    }

    /// Reads as much of a damaged stream as it can, for salvaging text.
    static func salvage(_ data: Data) -> (objects: [IWAObject], raw: Data) {
        let raw = (try? decompress(data, tolerant: true)) ?? Data()
        let objects = (try? parseObjects(raw, tolerant: true)) ?? []
        return (objects, raw)
    }

    func compressed() -> Data {
        Self.compress(serialized())
    }

    func serialized() -> Data {
        var output = Data()
        for object in objects {
            var header = ProtoMessage()
            var messages = object.messages.makeIterator()
            for field in object.header.fields {
                guard field.number == 2, var message = messages.next() else {
                    header.fields.append(field)
                    continue
                }
                message.info.set(ProtoMessage.Field(3, varint: UInt64(message.payload.count)))
                header.fields.append(ProtoMessage.Field(2, message: message.info))
            }
            let bytes = header.serialized()
            ProtoMessage.appendVarint(UInt64(bytes.count), to: &output)
            output.append(bytes)
            for message in object.messages { output.append(message.payload) }
        }
        return output
    }

    // MARK: Chunks

    static func decompress(_ data: Data, tolerant: Bool = false) throws -> Data {
        let malformed = ConversionError("This file is damaged.")
        var output = Data()
        var position = data.startIndex
        while position < data.endIndex {
            guard data.endIndex - position >= 4, data[position] == 0 else {
                if tolerant { return output }
                throw malformed
            }
            let length = Int(data[position + 1]) | Int(data[position + 2]) << 8 | Int(data[position + 3]) << 16
            position += 4
            guard data.endIndex - position >= length else {
                if tolerant { return output }
                throw malformed
            }
            do {
                let chunk = data.subdata(in: position..<(position + length))
                output.append(try Snappy.decompress(chunk, limit: decompressedLimit - output.count))
            } catch {
                if tolerant { return output }
                throw malformed
            }
            position += length
        }
        return output
    }

    /// iWork keeps chunks to 64 KB of uncompressed data.
    static func compress(_ data: Data) -> Data {
        var output = Data()
        var position = data.startIndex
        while position < data.endIndex {
            let end = min(position + 65_536, data.endIndex)
            let chunk = Snappy.compressAsLiteral(data.subdata(in: position..<end))
            output.append(0)
            output.append(UInt8(chunk.count & 0xFF))
            output.append(UInt8((chunk.count >> 8) & 0xFF))
            output.append(UInt8((chunk.count >> 16) & 0xFF))
            output.append(chunk)
            position = end
        }
        return output
    }

    private static func parseObjects(_ data: Data, tolerant: Bool) throws -> [IWAObject] {
        let malformed = ConversionError("This file is damaged.")
        var objects: [IWAObject] = []
        var position = 0
        let count = data.count
        do {
            while position < count {
                let headerLength = try data.withUnsafeBytes { try ProtoMessage.readVarint($0, &position) }
                guard headerLength <= UInt64(count - position) else { throw malformed }
                let headerEnd = position + Int(headerLength)
                let header = try ProtoMessage(parsing: data.subdata(in: position..<headerEnd))
                position = headerEnd

                var messages: [IWAObject.Message] = []
                for info in header.fields where info.number == 2 {
                    guard case .bytes(let bytes) = info.value else { throw malformed }
                    let messageInfo = try ProtoMessage(parsing: bytes)
                    guard let length = messageInfo.varint(3), length <= UInt64(count - position) else { throw malformed }
                    let end = position + Int(length)
                    messages.append(IWAObject.Message(info: messageInfo, payload: data.subdata(in: position..<end)))
                    position = end
                }
                objects.append(IWAObject(header: header, messages: messages))
            }
        } catch {
            if !tolerant { throw malformed }
        }
        return objects
    }
}

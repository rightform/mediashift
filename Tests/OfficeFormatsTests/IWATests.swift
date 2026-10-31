import ConversionCore
import Foundation
import Testing
@testable import OfficeFormats

@Suite("Snappy")
struct SnappyTests {
    private func decode(_ bytes: [UInt8], limit: Int = 1 << 20) throws -> [UInt8] {
        [UInt8](try Snappy.decompress(Data(bytes), limit: limit))
    }

    @Test func decodesLiterals() throws {
        #expect(try decode([3, 2 << 2, 97, 98, 99]) == Array("abc".utf8))
    }

    @Test func decodesLongLiteralLengths() throws {
        let body = [UInt8](repeating: 7, count: 300)
        // Tag 61 means the length minus one follows in two bytes.
        let encoded: [UInt8] = [0xAC, 0x02, 61 << 2, 0x2B, 0x01] + body
        #expect(try decode(encoded) == body)
    }

    @Test func decodesOverlappingCopies() throws {
        // "ab", then a one byte offset copy of 2 back with length 6: a run of "ab".
        let encoded: [UInt8] = [8, 1 << 2, 97, 98, 0b0000_1001, 2]
        #expect(try decode(encoded) == Array("abababab".utf8))
        // The same with two and four byte offsets.
        #expect(try decode([8, 1 << 2, 97, 98, (5 << 2) | 2, 2, 0]) == Array("abababab".utf8))
        #expect(try decode([8, 1 << 2, 97, 98, (5 << 2) | 3, 2, 0, 0, 0]) == Array("abababab".utf8))
    }

    @Test func literalEncoderIsReadable() throws {
        for size in [0, 1, 59, 60, 61, 255, 256, 257, 65_535, 65_536, 70_000] {
            let input = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            #expect(try Snappy.decompress(Snappy.compressAsLiteral(input), limit: 1 << 20) == input)
        }
    }

    @Test(arguments: [
        ("empty input", [UInt8]()),
        ("length with no end", [0x80, 0x80]),
        ("oversized length varint", [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]),
        ("missing literal bytes", [3, 2 << 2, 97]),
        ("literal past declared length", [1, 1 << 2, 97, 98]),
        ("copy before start", [3, 0, 97, 0b0000_0001, 9]),
        ("zero offset", [5, 0, 97, 0b0000_0001, 0]),
        ("copy past declared length", [2, 0, 97, 0b0001_0001, 1]),
        ("truncated copy tag", [3, 0, 97, 0b0000_0010]),
        ("shorter than declared", [9, 0, 97]),
        ("truncated long literal length", [3, 61 << 2, 0]),
    ] as [(String, [UInt8])])
    func malformedDataThrows(_ name: String, bytes: [UInt8]) {
        #expect(throws: ConversionError.self, "\(name)") {
            try decode(bytes)
        }
    }

    @Test func refusesToExpandBeyondTheLimit() {
        // Declares a gigabyte in six bytes.
        #expect(throws: ConversionError.self) {
            try decode([0x80, 0x80, 0x80, 0x80, 0x04, 0], limit: 1 << 20)
        }
    }
}

@Suite("Protobuf")
struct ProtobufTests {
    @Test func parsesAndSerializesBackToTheSameBytes() throws {
        var message = ProtoMessage()
        message.fields = [
            ProtoMessage.Field(1, varint: 300),
            ProtoMessage.Field(2, string: "Zażółć"),
            ProtoMessage.Field(3, .fixed32(7)),
            ProtoMessage.Field(4, .fixed64(9)),
            ProtoMessage.Field(5, message: ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1)])),
            ProtoMessage.Field(1, varint: 2),
        ]
        let parsed = try ProtoMessage(parsing: message.serialized())
        #expect(parsed == message)
        #expect(parsed.serialized() == message.serialized())
        #expect(parsed.varint(1) == 300)
        #expect(parsed.string(2) == "Zażółć")
        #expect(parsed.reference(5) == 1)
    }

    @Test func readsPackedAndRepeatedVarints() throws {
        let packed = ProtoMessage(fields: [ProtoMessage.Field(5, .bytes(ProtoMessage.packVarints([1, 300, 70000])))])
        #expect(packed.varints(5) == [1, 300, 70000])
        let repeated = ProtoMessage(fields: [ProtoMessage.Field(5, varint: 1), ProtoMessage.Field(5, varint: 2)])
        #expect(repeated.varints(5) == [1, 2])
    }

    @Test func setKeepsFieldOrder() {
        var message = ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1), ProtoMessage.Field(5, varint: 5)])
        message.set(ProtoMessage.Field(3, varint: 3))
        message.set(ProtoMessage.Field(5, varint: 6))
        #expect(message.fields.map(\.number) == [1, 3, 5])
        #expect(message.varint(5) == 6)
    }

    @Test(arguments: [
        ("truncated varint", [0x08, 0x80]),
        ("truncated length", [0x12]),
        ("length past the end", [0x12, 0x05, 0x61]),
        ("truncated fixed32", [0x0D, 0x01]),
        ("truncated fixed64", [0x09, 0x01]),
        ("group wire type", [0x0B]),
        ("field number zero", [0x00, 0x01]),
        ("varint of eleven bytes", [0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]),
    ] as [(String, [UInt8])])
    func malformedDataThrows(_ name: String, bytes: [UInt8]) {
        #expect(throws: ConversionError.self, "\(name)") {
            try ProtoMessage(parsing: Data(bytes))
        }
    }
}

@Suite("IWA streams")
struct IWAStreamTests {
    private func object(_ identifier: UInt64, type: UInt64, payload: Data) -> IWAObject {
        let info = ProtoMessage(fields: [
            ProtoMessage.Field(1, varint: type),
            ProtoMessage.Field(3, varint: UInt64(payload.count)),
        ])
        let header = ProtoMessage(fields: [
            ProtoMessage.Field(1, varint: identifier),
            ProtoMessage.Field(2, message: info),
        ])
        return IWAObject(header: header, messages: [IWAObject.Message(info: info, payload: payload)])
    }

    @Test func roundTripsObjects() throws {
        let stream = IWAStream(objects: [
            object(1, type: 100, payload: Data("hello".utf8)),
            object(2, type: 200, payload: Data()),
        ])
        let read = try IWAStream(compressed: stream.compressed())
        #expect(read.objects.map(\.identifier) == [1, 2])
        #expect(read.objects[0].messages[0].type == 100)
        #expect(read.objects[0].messages[0].payload == Data("hello".utf8))
    }

    @Test func updatesMessageLengths() throws {
        var stream = IWAStream(objects: [object(1, type: 100, payload: Data("short".utf8))])
        stream.objects[0].messages[0].payload = Data(repeating: 65, count: 1000)
        let read = try IWAStream(compressed: stream.compressed())
        #expect(read.objects[0].messages[0].payload.count == 1000)
        #expect(read.objects[0].messages[0].info.varint(3) == 1000)
    }

    @Test func splitsLargeStreamsIntoChunksOfAt64KB() throws {
        let payload = Data(repeating: 65, count: 200_000)
        let compressed = IWAStream(objects: [object(1, type: 100, payload: payload)]).compressed()
        // Walk the chunk headers: a zero byte and a 3 byte length.
        var position = 0
        var chunks = 0
        while position < compressed.count {
            #expect(compressed[position] == 0)
            let length = Int(compressed[position + 1]) | Int(compressed[position + 2]) << 8 | Int(compressed[position + 3]) << 16
            #expect(length < 65_536 + 16)
            position += 4 + length
            chunks += 1
        }
        #expect(chunks == 4)
        #expect(try IWAStream(compressed: compressed).objects[0].messages[0].payload == payload)
    }

    @Test(arguments: [
        ("wrong chunk type", [0x01, 0, 0, 0]),
        ("short chunk header", [0x00, 1]),
        ("chunk past the end", [0x00, 9, 0, 0, 1, 2]),
    ] as [(String, [UInt8])])
    func malformedFramingThrows(_ name: String, bytes: [UInt8]) {
        #expect(throws: ConversionError.self, "\(name)") {
            try IWAStream(compressed: Data(bytes))
        }
    }

    @Test func messageLengthPastTheEndThrows() throws {
        let info = ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1), ProtoMessage.Field(3, varint: 99)])
        let header = ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1), ProtoMessage.Field(2, message: info)]).serialized()
        var raw = Data()
        ProtoMessage.appendVarint(UInt64(header.count), to: &raw)
        raw.append(header)
        #expect(throws: ConversionError.self) {
            try IWAStream(compressed: IWAStream.compress(raw))
        }
    }

    @Test func salvageKeepsWhatCameBeforeTheDamage() {
        let intact = IWAStream(objects: [object(1, type: 100, payload: Data("kept".utf8))]).compressed()
        let damaged = intact + Data([0x00, 0xFF, 0xFF, 0x00, 1, 2, 3])
        let salvage = IWAStream.salvage(damaged)
        #expect(salvage.objects.map(\.identifier) == [1])
    }
}

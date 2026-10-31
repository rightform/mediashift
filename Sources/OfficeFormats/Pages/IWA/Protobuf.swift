import ConversionCore
import Foundation

/// A schemaless view of a protobuf message. The field order is kept, so an untouched message
/// serializes back to the same bytes.
struct ProtoMessage: Equatable {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    struct Field: Equatable {
        var number: Int
        var value: Value

        init(_ number: Int, _ value: Value) {
            self.number = number
            self.value = value
        }

        init(_ number: Int, varint: UInt64) {
            self.init(number, .varint(varint))
        }

        init(_ number: Int, message: ProtoMessage) {
            self.init(number, .bytes(message.serialized()))
        }

        init(_ number: Int, string: String) {
            self.init(number, .bytes(Data(string.utf8)))
        }
    }

    var fields: [Field]

    init(fields: [Field] = []) {
        self.fields = fields
    }

    init(parsing data: Data) throws {
        let malformed = ConversionError("This file is damaged.")
        fields = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Field] in
            var fields: [Field] = []
            var position = 0
            while position < bytes.count {
                let key = try Self.readVarint(bytes, &position)
                let number = Int(key >> 3)
                guard number > 0, number < 1 << 29 else { throw malformed }
                switch key & 7 {
                case 0:
                    fields.append(Field(number, .varint(try Self.readVarint(bytes, &position))))
                case 1:
                    guard position + 8 <= bytes.count else { throw malformed }
                    var value: UInt64 = 0
                    for index in 0..<8 { value |= UInt64(bytes[position + index]) << (8 * UInt64(index)) }
                    position += 8
                    fields.append(Field(number, .fixed64(value)))
                case 2:
                    let length = try Self.readVarint(bytes, &position)
                    guard length <= UInt64(bytes.count - position) else { throw malformed }
                    let end = position + Int(length)
                    fields.append(Field(number, .bytes(Data(bytes[position..<end]))))
                    position = end
                case 5:
                    guard position + 4 <= bytes.count else { throw malformed }
                    var value: UInt32 = 0
                    for index in 0..<4 { value |= UInt32(bytes[position + index]) << (8 * UInt32(index)) }
                    position += 4
                    fields.append(Field(number, .fixed32(value)))
                default:
                    throw malformed
                }
            }
            return fields
        }
    }

    func serialized() -> Data {
        var output = Data()
        for field in fields {
            switch field.value {
            case .varint(let value):
                Self.appendVarint(UInt64(field.number) << 3, to: &output)
                Self.appendVarint(value, to: &output)
            case .fixed64(let value):
                Self.appendVarint(UInt64(field.number) << 3 | 1, to: &output)
                withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
            case .bytes(let value):
                Self.appendVarint(UInt64(field.number) << 3 | 2, to: &output)
                Self.appendVarint(UInt64(value.count), to: &output)
                output.append(value)
            case .fixed32(let value):
                Self.appendVarint(UInt64(field.number) << 3 | 5, to: &output)
                withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
            }
        }
        return output
    }

    // MARK: Reading fields

    func varint(_ number: Int) -> UInt64? {
        for field in fields where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    /// A varint as an `Int`, clamped so a hostile value cannot trap the conversion.
    func int(_ number: Int) -> Int? {
        varint(number).map { Int(clamping: $0) }
    }

    func varints(_ number: Int) -> [UInt64] {
        fields.flatMap { field -> [UInt64] in
            guard field.number == number else { return [] }
            switch field.value {
            case .varint(let value): return [value]
            case .bytes(let packed): return Self.unpackVarints(packed)
            default: return []
            }
        }
    }

    func float(_ number: Int) -> Float? {
        for field in fields where field.number == number {
            if case .fixed32(let value) = field.value { return Float(bitPattern: value) }
        }
        return nil
    }

    func bytes(_ number: Int) -> Data? {
        for field in fields where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    func string(_ number: Int) -> String? {
        bytes(number).flatMap { String(data: $0, encoding: .utf8) }
    }

    func strings(_ number: Int) -> [String] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let value) = field.value else { return nil }
            return String(data: value, encoding: .utf8)
        }
    }

    func message(_ number: Int) -> ProtoMessage? {
        bytes(number).flatMap { try? ProtoMessage(parsing: $0) }
    }

    func messages(_ number: Int) -> [ProtoMessage] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let value) = field.value else { return nil }
            return try? ProtoMessage(parsing: value)
        }
    }

    // MARK: Changing fields

    mutating func removeAll(_ number: Int) {
        fields.removeAll { $0.number == number }
    }

    /// Replaces a field, or inserts it where ascending field order puts it.
    mutating func set(_ field: Field) {
        if let index = fields.firstIndex(where: { $0.number == field.number }) {
            fields[index] = field
            fields.removeAll { other in other.number == field.number && other != field }
        } else {
            let index = fields.firstIndex { $0.number > field.number } ?? fields.count
            fields.insert(field, at: index)
        }
    }

    // MARK: Wire format

    static func packVarints(_ values: [UInt64]) -> Data {
        var output = Data()
        for value in values { appendVarint(value, to: &output) }
        return output
    }

    private static func unpackVarints(_ data: Data) -> [UInt64] {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt64] in
            var values: [UInt64] = []
            var position = 0
            while position < bytes.count, let value = try? readVarint(bytes, &position) {
                values.append(value)
            }
            return values
        }
    }

    static func appendVarint(_ value: UInt64, to output: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            output.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        output.append(UInt8(remaining))
    }

    static func readVarint(_ bytes: UnsafeRawBufferPointer, _ position: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < bytes.count, shift < 64 else {
                throw ConversionError("This file is damaged.")
            }
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }
}

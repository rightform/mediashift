import ConversionCore
import Foundation

/// Message types the Pages code cares about. iWork's protobuf schema is not public, these and
/// the field numbers below come from reading real files.
enum IWAType {
    static let numbersDocument: UInt64 = 1
    static let numbersSheet: UInt64 = 2
    static let documentRoot: UInt64 = 10000
    static let textStorage: UInt64 = 2001
    static let characterStyle: UInt64 = 2021
    static let paragraphStyle: UInt64 = 2022
    static let listStyle: UInt64 = 2023
    static let image: UInt64 = 3005
    static let tableInfo: UInt64 = 6000
    static let tableModel: UInt64 = 6001
    static let tableTile: UInt64 = 6002
    static let tableDataList: UInt64 = 6005
    static let tableRichText: UInt64 = 6218
    static let packageMetadata: UInt64 = 11006
}

/// All objects of a document, across its IWA files, by identifier.
struct IWAObjectStore {
    private(set) var objects: [UInt64: IWAObject.Message] = [:]
    /// The identifiers in file order, which is what keeps salvaged text in sequence.
    private(set) var order: [UInt64] = []

    mutating func add(_ stream: [IWAObject]) {
        for object in stream {
            guard let first = object.messages.first else { continue }
            if objects.updateValue(first, forKey: object.identifier) == nil {
                order.append(object.identifier)
            }
        }
    }

    func object(_ identifier: UInt64) -> IWAObject.Message? {
        objects[identifier]
    }

    func parsed(_ identifier: UInt64) -> ProtoMessage? {
        objects[identifier]?.parsed()
    }

    func all(ofType type: UInt64) -> [(identifier: UInt64, message: IWAObject.Message)] {
        order.compactMap { identifier in
            guard let message = objects[identifier], message.type == type else { return nil }
            return (identifier, message)
        }
    }
}

extension ProtoMessage {
    /// The object a `TSP.Reference` field points at.
    func reference(_ number: Int) -> UInt64? {
        message(number)?.varint(1)
    }

    /// Run-length tables over the text, in `TSWP`'s attribute table shape: repeated entries
    /// of field 1, each with the character index in its own field 1.
    func attributeEntries(_ number: Int) -> [ProtoMessage] {
        message(number)?.messages(1) ?? []
    }
}

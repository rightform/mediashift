import ConversionCore
import Foundation

/// A small element tree over `XMLParser`. Lookups go by local name, since the prefix an
/// Office file picks for a namespace is its own choice.
final class XMLTree {
    let name: String
    let localName: String
    let attributes: [String: String]
    fileprivate(set) var children: [XMLTree] = []
    /// The text directly inside this element.
    fileprivate(set) var text = ""

    fileprivate init(name: String, attributes: [String: String]) {
        self.name = name
        self.localName = name.split(separator: ":").last.map(String.init) ?? name
        self.attributes = attributes
    }

    /// Parses a document. A document type declaration is refused: OOXML never needs one and it
    /// is the door to entity expansion attacks.
    static func parse(_ data: Data) throws -> XMLTree {
        try rejectDocumentType(in: data)
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw ConversionError("This file is damaged.")
        }
        return root
    }

    static func rejectDocumentType(in data: Data) throws {
        let encodings: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian]
        for encoding in encodings {
            if let marker = "<!DOCTYPE".data(using: encoding), data.range(of: marker) != nil {
                throw ConversionError("This file is damaged.")
            }
        }
    }

    func first(_ localName: String) -> XMLTree? {
        children.first { $0.localName == localName }
    }

    func all(_ localName: String) -> [XMLTree] {
        children.filter { $0.localName == localName }
    }

    /// Follows a chain of first children.
    func first(path: String...) -> XMLTree? {
        var node: XMLTree? = self
        for step in path { node = node?.first(step) }
        return node
    }

    /// Every element below this one with the given local name, in document order.
    func descendants(_ localName: String) -> [XMLTree] {
        var found: [XMLTree] = []
        for child in children {
            if child.localName == localName { found.append(child) }
            found += child.descendants(localName)
        }
        return found
    }

    /// An unprefixed attribute.
    func attribute(_ name: String) -> String? {
        attributes[name]
    }

    /// A namespaced attribute under any prefix, such as `r:id`, which must not be confused
    /// with a plain `id` on the same element.
    func prefixedAttribute(_ localName: String) -> String? {
        let suffix = ":" + localName
        return attributes.first { $0.key.hasSuffix(suffix) }?.value
    }

    /// An OOXML boolean attribute, which may be spelled `1`, `true`, `on`, `0`, `false`, `off`.
    func flag(_ name: String) -> Bool? {
        guard let value = attributes[name]?.lowercased() else { return nil }
        return value == "1" || value == "true" || value == "on"
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLTree?
    private var stack: [XMLTree] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLTree(name: elementName, attributes: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let finished = stack.removeLast()
        if stack.isEmpty { root = finished }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}

extension String {
    /// Escaped for XML text and attribute values, with the characters XML 1.0 forbids removed.
    var xmlEscaped: String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(utf8.count)
        for scalar in unicodeScalars {
            switch scalar {
            case "&": result.append(contentsOf: "&amp;".unicodeScalars)
            case "<": result.append(contentsOf: "&lt;".unicodeScalars)
            case ">": result.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": result.append(contentsOf: "&quot;".unicodeScalars)
            case "\r": result.append(contentsOf: "&#13;".unicodeScalars)
            case "\t", "\n": result.append(scalar)
            default:
                let value = scalar.value
                let isAllowed = value >= 0x20 && value != 0xFFFE && value != 0xFFFF
                if isAllowed { result.append(scalar) }
            }
        }
        return String(result)
    }
}

import ConversionCore
import Foundation

/// The Open Packaging Conventions: how the parts of an XLSX or PPTX find each other.
enum OPC {
    struct Relationship {
        var id: String
        var type: String
        var target: String
        var isExternal: Bool

        func hasType(_ suffix: String) -> Bool {
            // Strict OOXML files use a different host, the last path component is what counts.
            type.hasSuffix("/" + suffix)
        }
    }

    /// The relationships of a part, or of the package itself when `part` is nil.
    static func relationships(of part: String?, in package: PartSource) throws -> [Relationship] {
        guard let data = try package.data(forPart: relationshipsPath(of: part)) else { return [] }
        return try XMLTree.parse(data).all("Relationship").compactMap { node in
            guard let id = node.attribute("Id"), let type = node.attribute("Type"), let target = node.attribute("Target") else {
                return nil
            }
            return Relationship(id: id, type: type, target: target, isExternal: node.attribute("TargetMode") == "External")
        }
    }

    /// Resolves a relationship target against the part that holds it. Nil when it leaves the package.
    static func resolve(_ target: String, from part: String?) -> String? {
        let decoded = target.removingPercentEncoding ?? target
        var stack: [Substring] = []
        if !decoded.hasPrefix("/"), let part {
            stack = part.split(separator: "/").dropLast().map { $0 }
        }
        for component in decoded.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard stack.popLast() != nil else { return nil }
            default:
                stack.append(component)
            }
        }
        return stack.isEmpty ? nil : stack.joined(separator: "/")
    }

    /// The part the package's root relationship of the given type points to.
    static func mainPart(ofType type: String, in package: PartSource) throws -> String? {
        try relationships(of: nil, in: package)
            .first { $0.hasType(type) }
            .flatMap { resolve($0.target, from: nil) }
    }

    private static func relationshipsPath(of part: String?) -> String {
        guard let part else { return "_rels/.rels" }
        var components = part.split(separator: "/").map(String.init)
        let file = components.removeLast()
        return (components + ["_rels", file + ".rels"]).joined(separator: "/")
    }

    // MARK: Core properties

    /// The title and author stored in `docProps/core.xml`.
    static func coreProperties(in package: PartSource) -> (title: String?, author: String?) {
        let path = (try? mainPart(ofType: "core-properties", in: package)) ?? "docProps/core.xml"
        guard let data = try? package.data(forPart: path),
            let root = try? XMLTree.parse(data)
        else { return (nil, nil) }
        func value(_ name: String) -> String? {
            let text = root.first(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        return (value("title"), value("creator"))
    }

    static func corePropertiesXML(title: String?, author: String?) -> String {
        var fields = ""
        if let title { fields += "<dc:title>\(title.xmlEscaped)</dc:title>" }
        if let author { fields += "<dc:creator>\(author.xmlEscaped)</dc:creator>" }
        return xmlHeader + """
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(fields)</cp:coreProperties>
            """
    }

    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static let relationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A `.rels` document from `(id, type suffix under officeDocument, target)` triples.
    static func relationshipsXML(_ items: [(id: String, type: String, target: String, external: Bool)]) -> String {
        var xml = xmlHeader + "<Relationships xmlns=\"\(relationshipsNamespace)\">"
        for item in items {
            let mode = item.external ? " TargetMode=\"External\"" : ""
            xml += "<Relationship Id=\"\(item.id)\" Type=\"\(item.type.xmlEscaped)\" Target=\"\(item.target.xmlEscaped)\"\(mode)/>"
        }
        return xml + "</Relationships>"
    }
}

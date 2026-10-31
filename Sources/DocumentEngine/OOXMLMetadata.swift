import ConversionCore
import Foundation

/// Removes author, company, revision and timestamps from Word, Excel and PowerPoint files.
public enum OOXMLMetadata {
    public static func strip(_ input: URL, to output: URL) throws {
        let source = try ZipReader(url: input, formatName: "Office")
        guard source.paths.contains("[Content_Types].xml") else {
            throw ConversionError("This is not a valid Office file.")
        }
        let zip = try ZipWriter(url: output)
        for path in source.paths {
            guard let data = source.data(at: path) else { continue }
            switch path {
            case "docProps/core.xml":
                try zip.add(path, text: blankCore)
            case "docProps/app.xml":
                try zip.add(path, text: blankApp)
            case _ where path.hasPrefix("docProps/custom"):
                // Custom properties stay declared in the package, but with no values in them.
                try zip.add(path, text: blankCustom)
            case _ where path.hasPrefix("customXml/") || path.hasSuffix("/people.xml") || path.hasSuffix("/commentsExtended.xml"):
                try zip.add(path, data: scrubbed(data))
            default:
                try zip.add(path, data: data)
            }
        }
        try zip.finish()
    }

    /// Keeps the part well formed so package relationships stay valid, without any content.
    private static func scrubbed(_ data: Data) -> Data {
        guard let root = (try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever))?.rootElement() else {
            return data
        }
        root.setChildren(nil)
        return root.xmlString.data(using: .utf8) ?? data
    }

    private static let blankCore = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"></cp:coreProperties>
        """

    private static let blankApp = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"></Properties>
        """

    private static let blankCustom = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"></Properties>
        """
}

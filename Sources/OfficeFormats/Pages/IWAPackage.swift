import ConversionCore
import Foundation

/// Where an iWork document keeps its parts.
enum IWAPackage {
    /// A document is a ZIP, or a folder holding `Index/` or `Index.zip`.
    static func open(_ url: URL, formatName: String) throws -> (source: PartSource, index: PartSource) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ConversionError("The file could not be found.")
        }
        guard isDirectory.boolValue else {
            let zip = try ZipPackage(url: url, formatName: formatName)
            return (zip, zip)
        }
        let folder = try DirectoryPackage(url: url)
        if folder.contains("Index.zip") {
            let index = try ZipPackage(url: url.appendingPathComponent("Index.zip"), formatName: formatName)
            return (folder, index)
        }
        return (folder, folder)
    }
}

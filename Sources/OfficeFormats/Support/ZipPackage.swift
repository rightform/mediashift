import ConversionCore
import Foundation
import ZIPFoundation

/// Anything that hands out named parts: a ZIP file or a package folder.
protocol PartSource {
    /// Normalized, relative part names.
    var partNames: [String] { get }
    /// The part's bytes, or nil when there is no such part.
    func data(forPart name: String) throws -> Data?
}

extension PartSource {
    func contains(_ name: String) -> Bool {
        partNames.contains(name)
    }
}

/// Caps that stop a small hostile archive from exhausting memory.
struct ZipLimits: Sendable {
    var maxPartSize: Int64 = 1 << 30
    var maxTotalSize: Int64 = 3 << 30
    var maxEntryCount = 200_000
}

/// Read access to a ZIP. Entries with unsafe names are ignored and every read is capped by
/// `ZipLimits` while it inflates, because the sizes an archive declares can be forged.
final class ZipPackage: PartSource {
    private struct LimitExceeded: Error {}

    private let archive: Archive
    private let limits: ZipLimits
    private var entries: [String: Entry] = [:]
    /// OPC part names ignore case, and some generators do not spell them consistently.
    private var lowercasedNames: [String: String] = [:]
    private var bytesRead: Int64 = 0
    let partNames: [String]

    /// - Parameter formatName: How the error message names the expected format, such as `XLSX`.
    init(url: URL, formatName: String, limits: ZipLimits = ZipLimits()) throws {
        self.limits = limits
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw Self.openError(url: url, formatName: formatName)
        }

        var names: [String] = []
        var entries: [String: Entry] = [:]
        var lowercased: [String: String] = [:]
        for (index, entry) in archive.enumerated() {
            guard index < limits.maxEntryCount else {
                throw ConversionError("This file has too many parts to open safely.")
            }
            guard entry.type == .file, let name = Self.safeName(entry.path) else { continue }
            if entries.updateValue(entry, forKey: name) == nil {
                names.append(name)
                lowercased[name.lowercased()] = name
            }
        }
        guard !entries.isEmpty else {
            throw ConversionError("This file is not a valid \(formatName) file.")
        }
        self.entries = entries
        self.lowercasedNames = lowercased
        self.partNames = names
    }

    func data(forPart name: String) throws -> Data? {
        guard let entry = entries[name] ?? lowercasedNames[name.lowercased()].flatMap({ entries[$0] }) else { return nil }
        guard entry.uncompressedSize <= UInt64(limits.maxPartSize),
            bytesRead + Int64(clamping: entry.uncompressedSize) <= limits.maxTotalSize
        else {
            throw Self.tooLarge
        }

        var output = Data()
        output.reserveCapacity(Int(min(entry.uncompressedSize, 1 << 26)))
        do {
            _ = try archive.extract(entry) { chunk in
                output.append(chunk)
                guard Int64(output.count) <= self.limits.maxPartSize,
                    self.bytesRead + Int64(output.count) <= self.limits.maxTotalSize
                else {
                    throw LimitExceeded()
                }
            }
        } catch is LimitExceeded {
            throw Self.tooLarge
        } catch {
            throw ConversionError("This file is damaged.")
        }
        bytesRead += Int64(output.count)
        return output
    }

    /// Nil for names that could reach outside the package. Nothing here is ever extracted to
    /// disk, but a relationship target must not be able to name such an entry either.
    static func safeName(_ raw: String) -> String? {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        while name.hasPrefix("./") { name.removeFirst(2) }
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasSuffix("/"), !name.contains("\0") else { return nil }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains("") else { return nil }
        return name
    }

    private static let tooLarge = ConversionError("This file is too large to open safely.")

    private static func openError(url: URL, formatName: String) -> ConversionError {
        // Office wraps password protected files, and very old ones, in an OLE container.
        let oleSignature = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        if let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 8), head == oleSignature {
            return ConversionError("This file is password protected or uses an old format.")
        }
        return ConversionError("This file is not a valid \(formatName) file.")
    }
}

/// A package stored as a folder, the way Pages keeps some documents. Symbolic links are skipped.
final class DirectoryPackage: PartSource {
    private let root: URL
    private let limits: ZipLimits
    private var bytesRead: Int64 = 0
    let partNames: [String]

    init(url: URL, limits: ZipLimits = ZipLimits()) throws {
        root = url
        self.limits = limits
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: url.path) else {
            throw ConversionError("This folder could not be read.")
        }
        var names: [String] = []
        for case let name as String in enumerator {
            let path = url.appendingPathComponent(name).path
            // Does not follow links, unlike nearly everything else in FileManager.
            guard (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else { continue }
            names.append(name)
            guard names.count <= limits.maxEntryCount else {
                throw ConversionError("This file has too many parts to open safely.")
            }
        }
        partNames = names
    }

    func data(forPart name: String) throws -> Data? {
        guard partNames.contains(name) else { return nil }
        let url = root.appendingPathComponent(name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= limits.maxPartSize, bytesRead + Int64(size) <= limits.maxTotalSize else {
            throw ConversionError("This file is too large to open safely.")
        }
        do {
            let data = try Data(contentsOf: url)
            bytesRead += Int64(data.count)
            return data
        } catch {
            throw ConversionError("This file is damaged.")
        }
    }
}

/// Writes a new ZIP in one go. The file appears at its destination only once it is complete.
enum ZipWriter {
    struct Part {
        var name: String
        var data: Data

        init(_ name: String, _ data: Data) {
            self.name = name
            self.data = data
        }

        init(_ name: String, _ text: String) {
            self.init(name, Data(text.utf8))
        }
    }

    static func write(_ parts: [Part], to url: URL, compression: CompressionMethod = .deflate) throws {
        let fileManager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }

        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            for part in parts {
                let data = part.data
                try archive.addEntry(
                    with: part.name,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: compression,
                    provider: { position, size in
                        data.subdata(in: Int(position)..<(Int(position) + size))
                    }
                )
            }
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            throw ConversionError("The file could not be saved.")
        }
    }
}

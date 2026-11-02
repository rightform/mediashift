import ConversionCore
import Foundation

/// Generates a Pages document from the bundled blank template by patching its body text
/// storage. Only `Index/Document.iwa`, `Index/Metadata.iwa` and the identifiers under
/// `Metadata/` change; every other part of the template is copied as is.
///
/// What iWork's layout code needs, learned by testing against the Quick Look engine: the
/// paragraph style table must have an entry at every paragraph start (without one it falls
/// back to a plain text rendering of the whole document), and the character style table must
/// start at index 0. Indexes count UTF-16 code units.
struct PagesWriter {
    /// Characters with a meaning in iWork's text.
    private enum Marker {
        static let paragraph = "\n"
        static let line = "\u{2028}"
        static let page = "\u{05}"
    }

    private enum ParagraphKind: Equatable {
        case body
        case heading(Int)
    }

    private enum ListKind: Equatable {
        case bullet, numbered
    }

    private enum CharacterKind: Hashable {
        case bold, italic, underline, strikethrough
    }

    private struct Run {
        var text: String
        var kind: CharacterKind?
    }

    private struct Paragraph {
        var runs: [Run]
        var kind = ParagraphKind.body
        var list: ListKind?
        var level = 0
        var pageBreakAfter = false
    }

    private let document: RichDocument

    init(_ document: RichDocument) {
        self.document = document
    }

    func write(to url: URL) throws {
        // The finished app carries the template in its own Resources, where the command line
        // tool in Contents/Helpers looks too. A signed bundle cannot hold SwiftPM's resource
        // bundle where the generated accessor looks for it, and that accessor stops the program
        // when it finds nothing, so it comes last.
        let besideTool = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../Resources/BlankTemplate.pages").standardizedFileURL
        let bundled = Bundle.main.url(forResource: "BlankTemplate", withExtension: "pages")
            ?? besideTool.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let templateURL = bundled ?? Bundle.module.url(forResource: "BlankTemplate", withExtension: "pages", subdirectory: "Resources") else {
            throw ConversionError("The blank Pages template is missing from this app.")
        }
        let template = try ZipPackage(url: templateURL, formatName: "Pages")
        let identifiers = FreshIdentifiers()

        var parts: [ZipWriter.Part] = []
        for name in template.partNames {
            guard var data = try template.data(forPart: name) else { continue }
            switch name {
            case "Index/Document.iwa":
                data = try patchedDocument(data, stylesheet: template.data(forPart: "Index/DocumentStylesheet.iwa"))
            case "Index/Metadata.iwa":
                data = try patchedMetadata(data, identifiers: identifiers)
            case "Metadata/Properties.plist":
                data = try patchedProperties(data, identifiers: identifiers)
            case "Metadata/DocumentIdentifier":
                data = Data(identifiers.document.utf8)
            default:
                break
            }
            parts.append(ZipWriter.Part(name, data))
        }
        // iWork stores its parts uncompressed.
        try ZipWriter.write(parts, to: url, compression: .none)
    }

    // MARK: Flattening the document

    private func paragraphs() -> [Paragraph] {
        var result: [Paragraph] = []

        func add(_ inlines: [Inline], kind: ParagraphKind = .body, list: ListKind? = nil, level: Int = 0) {
            result.append(Paragraph(runs: Self.runs(from: inlines), kind: kind, list: list, level: level))
        }

        func addList(ordered: Bool, items: [[Block]], level: Int) {
            for item in items {
                var markerUsed = false
                for block in item {
                    switch block {
                    case .paragraph(let content, _) where !markerUsed:
                        add(content, list: ordered ? .numbered : .bullet, level: level)
                        markerUsed = true
                    case .list(let innerOrdered, let inner):
                        addList(ordered: innerOrdered, items: inner, level: min(level + 1, 8))
                    default:
                        addBlock(block)
                    }
                }
            }
        }

        func addBlock(_ block: Block) {
            switch block {
            case .heading(let level, let content, _):
                add(content, kind: .heading(level))
            case .paragraph(let content, _):
                add(content)
            case .list(let ordered, let items):
                addList(ordered: ordered, items: items, level: 0)
            case .table(let table):
                for row in TableLayout(table).textRows() {
                    let line = row.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
                    add([.text(line)])
                }
            case .image(let image):
                if let alt = image.alt, !alt.isEmpty { add([.text(alt)]) }
            case .code(let code, _):
                code.components(separatedBy: .newlines).forEach { add([.text($0)]) }
            case .quote(let blocks):
                blocks.forEach(addBlock)
            case .rule:
                break
            case .pageBreak:
                if !result.isEmpty { result[result.count - 1].pageBreakAfter = true }
            }
        }

        document.blocks.forEach(addBlock)
        return result
    }

    private static func runs(from inlines: [Inline]) -> [Run] {
        var runs: [Run] = []
        func append(_ text: String, _ kind: CharacterKind?) {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.kind == kind {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, kind: kind))
            }
        }
        for inline in inlines {
            switch inline {
            case .text(let text, let style):
                append(sanitized(text), characterKind(of: style))
            case .lineBreak:
                append(Marker.line, nil)
            case .image(let image):
                if let alt = image.alt { append(sanitized(alt), nil) }
            }
        }
        return runs
    }

    /// The template has one named style per effect, so of several effects bold wins.
    private static func characterKind(of style: TextStyle) -> CharacterKind? {
        if style.bold { return .bold }
        if style.italic { return .italic }
        if style.underline { return .underline }
        if style.strikethrough { return .strikethrough }
        return nil
    }

    /// Newlines become line breaks and the characters iWork gives a structural meaning, such as
    /// the attachment marker, are removed: unbacked by their tables they would break the layout.
    private static func sanitized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.utf8.count)
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar.value {
            case 0x0A:
                if !previousWasCR { scalars.append(contentsOf: Marker.line.unicodeScalars) }
            case 0x0D, 0x2028, 0x2029:
                scalars.append(contentsOf: Marker.line.unicodeScalars)
            case 0x09:
                scalars.append(scalar)
            case 0..<0x20, 0x7F, 0xFFFC, 0xFFFE, 0xFFFF, 0xE000...0xF8FF:
                break
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: Patching the body storage

    private func patchedDocument(_ data: Data, stylesheet: Data?) throws -> Data {
        guard let stylesheet else { throw Self.badTemplate }
        let styles = try TemplateStyles(stylesheet: stylesheet)
        var stream = try IWAStream(compressed: data)

        let paragraphs = paragraphs()
        var text = ""
        var length = 0
        var paragraphStyles: [(index: Int, object: UInt64?)] = []
        var listStyles: [(index: Int, object: UInt64?)] = []
        var levels: [(index: Int, level: Int)] = []
        var characterRuns: [(index: Int, object: UInt64?)] = [(0, nil)]
        var used: Set<UInt64> = []
        var previousStyle: UInt64?
        var previousList: UInt64?
        var previousLevel: Int?

        for (position, paragraph) in paragraphs.enumerated() {
            let style = try styles.paragraphStyle(for: paragraph.kind)
            paragraphStyles.append((length, style == previousStyle ? nil : style))
            previousStyle = style
            used.insert(style)

            let list = try styles.listStyle(for: paragraph.list)
            if list != previousList {
                listStyles.append((length, list))
                previousList = list
                used.insert(list)
            }
            if paragraph.level != previousLevel {
                levels.append((length, paragraph.level))
                previousLevel = paragraph.level
            }

            for run in paragraph.runs {
                let runLength = run.text.utf16.count
                if let kind = run.kind {
                    let object = try styles.characterStyle(for: kind)
                    used.insert(object)
                    characterRuns.append((length, object))
                    characterRuns.append((length + runLength, nil))
                }
                text += run.text
                length += runLength
            }

            if position < paragraphs.count - 1 {
                text += paragraph.pageBreakAfter ? Marker.page : Marker.paragraph
                length += 1
            }
        }

        guard let (objectIndex, messageIndex) = Self.bodyStorageLocation(in: stream) else { throw Self.badTemplate }
        var message = stream.objects[objectIndex].messages[messageIndex]
        var storage = try ProtoMessage(parsing: message.payload)
        if !text.isEmpty {
            storage.set(ProtoMessage.Field(3, string: text))
            storage.set(ProtoMessage.Field(5, message: Self.objectTable(paragraphStyles)))
            storage.set(ProtoMessage.Field(6, message: Self.levelTable(levels)))
            storage.set(ProtoMessage.Field(7, message: Self.objectTable(listStyles)))
            if characterRuns.count > 1 {
                storage.set(ProtoMessage.Field(8, message: Self.objectTable(Self.normalized(characterRuns))))
            }
        }
        message.payload = storage.serialized()
        message.addObjectReferences(used.sorted())
        stream.objects[objectIndex].messages[messageIndex] = message
        return stream.compressed()
    }

    private static let badTemplate = ConversionError("The blank Pages template is damaged.")

    /// The root object names its body in field 4.
    private static func bodyStorageLocation(in stream: IWAStream) -> (object: Int, message: Int)? {
        var bodyID: UInt64?
        for object in stream.objects {
            if let root = object.messages.first(where: { $0.type == IWAType.documentRoot })?.parsed() {
                bodyID = root.reference(4)
            }
        }
        guard let bodyID, let objectIndex = stream.objects.firstIndex(where: { $0.identifier == bodyID }),
            let messageIndex = stream.objects[objectIndex].messages.firstIndex(where: { $0.type == IWAType.textStorage })
        else { return nil }
        return (objectIndex, messageIndex)
    }

    /// Adjacent runs can share an index: the later entry is the one that counts.
    private static func normalized(_ runs: [(index: Int, object: UInt64?)]) -> [(index: Int, object: UInt64?)] {
        var result: [(index: Int, object: UInt64?)] = []
        for run in runs {
            if result.last?.index == run.index {
                result[result.count - 1] = run
            } else {
                result.append(run)
            }
        }
        return result
    }

    private static func objectTable(_ entries: [(index: Int, object: UInt64?)]) -> ProtoMessage {
        var table = ProtoMessage()
        for entry in entries {
            var attribute = ProtoMessage(fields: [ProtoMessage.Field(1, varint: UInt64(entry.index))])
            if let object = entry.object {
                let reference = ProtoMessage(fields: [ProtoMessage.Field(1, varint: object)])
                attribute.fields.append(ProtoMessage.Field(2, message: reference))
            }
            table.fields.append(ProtoMessage.Field(1, message: attribute))
        }
        return table
    }

    private static func levelTable(_ entries: [(index: Int, level: Int)]) -> ProtoMessage {
        var table = ProtoMessage()
        for entry in entries {
            let attribute = ProtoMessage(fields: [
                ProtoMessage.Field(1, varint: UInt64(entry.index)),
                ProtoMessage.Field(2, varint: UInt64(entry.level)),
                ProtoMessage.Field(3, varint: 0),
            ])
            table.fields.append(ProtoMessage.Field(1, message: attribute))
        }
        return table
    }

    // MARK: Identifiers

    /// Every generated document gets identifiers of its own, so two of them are never taken for
    /// versions of one document.
    private struct FreshIdentifiers {
        let document = UUID().uuidString
        let version = UUID().uuidString
        let `private` = UUID().uuidString
    }

    private func patchedMetadata(_ data: Data, identifiers: FreshIdentifiers) throws -> Data {
        var stream = try IWAStream(compressed: data)
        for objectIndex in stream.objects.indices {
            for messageIndex in stream.objects[objectIndex].messages.indices
            where stream.objects[objectIndex].messages[messageIndex].type == IWAType.packageMetadata {
                var metadata = try ProtoMessage(parsing: stream.objects[objectIndex].messages[messageIndex].payload)
                guard var revision = metadata.message(2) else { throw Self.badTemplate }
                revision.set(ProtoMessage.Field(2, string: identifiers.version))
                metadata.set(ProtoMessage.Field(2, message: revision))
                stream.objects[objectIndex].messages[messageIndex].payload = metadata.serialized()
            }
        }
        return stream.compressed()
    }

    private func patchedProperties(_ data: Data, identifiers: FreshIdentifiers) throws -> Data {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var properties = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw Self.badTemplate
        }
        properties["documentUUID"] = identifiers.document
        properties["shareUUID"] = identifiers.document
        properties["stableDocumentUUID"] = identifiers.document
        properties["versionUUID"] = identifiers.version
        properties["privateUUID"] = identifiers.private
        properties["revision"] = "0::\(identifiers.version)"
        return try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
    }

    // MARK: Template styles

    /// Finds the template's styles by what they are rather than by object number.
    private struct TemplateStyles {
        private var byKey: [String: UInt64] = [:]

        init(stylesheet: Data) throws {
            for object in try IWAStream(compressed: stylesheet).objects {
                guard let message = object.messages.first,
                    [IWAType.characterStyle, IWAType.paragraphStyle, IWAType.listStyle].contains(message.type),
                    let base = message.parsed()?.message(1)
                else { continue }
                if let identifier = base.string(2) { byKey[identifier] = object.identifier }
                if message.type == IWAType.characterStyle, let name = base.string(1) { byKey[name] = object.identifier }
            }
        }

        private func require(_ key: String) throws -> UInt64 {
            guard let object = byKey[key] else { throw PagesWriter.badTemplate }
            return object
        }

        func paragraphStyle(for kind: ParagraphKind) throws -> UInt64 {
            switch kind {
            case .body: try require("text-20-paragraphstyle-Body 1")
            case .heading(let level) where level <= 1: try require("text-11-paragraphstyle-Heading 1")
            case .heading(2): try require("text-12-paragraphstyle-Heading 2")
            case .heading: try require("text-13-paragraphstyle-Heading 3")
            }
        }

        func listStyle(for kind: ListKind?) throws -> UInt64 {
            switch kind {
            case nil: try require("text-0-liststyle-None")
            case .bullet: try require("text-1-liststyle-Bullet")
            case .numbered: try require("text-5-liststyle-Numbered")
            }
        }

        func characterStyle(for kind: CharacterKind) throws -> UInt64 {
            switch kind {
            case .bold: try require("Emphasis")
            case .italic: try require("Italic")
            case .underline: try require("Underline")
            case .strikethrough: try require("Strikethrough")
            }
        }
    }
}

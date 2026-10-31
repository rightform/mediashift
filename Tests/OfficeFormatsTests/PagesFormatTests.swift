import AppKit
import ConversionCore
import Foundation
import PDFKit
import Testing
@testable import OfficeFormats

private func paragraph(_ text: String) -> Block {
    .paragraph(content: [.text(text)])
}

@Suite("Pages writing")
struct PagesWriterTests {
    private func roundTrip(_ blocks: [Block]) throws -> [Block] {
        let folder = try TemporaryFolder()
        let url = folder.file("doc.pages")
        try PagesFormat.write(RichDocument(blocks: blocks), to: url)
        return try PagesFormat.read(url).blocks
    }

    @Test func roundTripsHeadingsAndParagraphs() throws {
        let blocks: [Block] = [
            .heading(level: 1, content: [.text("Tytuł")]),
            paragraph("Zażółć gęślą jaźń"),
            .heading(level: 2, content: [.text("Podtytuł")]),
            paragraph("😀 emoji, „cudzysłów” & <znaki>"),
            .heading(level: 3, content: [.text("Trzeci")]),
            paragraph("koniec"),
        ]
        #expect(try roundTrip(blocks) == blocks)
    }

    @Test func deeperHeadingsUseTheDeepestTemplateStyle() throws {
        #expect(try roundTrip([.heading(level: 5, content: [.text("x")])]) == [.heading(level: 3, content: [.text("x")])])
    }

    @Test func roundTripsNestedLists() throws {
        let blocks: [Block] = [
            paragraph("przed"),
            .list(ordered: false, items: [
                [paragraph("jeden"), .list(ordered: false, items: [[paragraph("pod")], [paragraph("pod dwa")]])],
                [paragraph("dwa")],
            ]),
            .list(ordered: true, items: [[paragraph("pierwszy")], [paragraph("drugi")]]),
            paragraph("po"),
        ]
        #expect(try roundTrip(blocks) == blocks)
    }

    @Test func roundTripsCharacterStylesWithUTF16Offsets() throws {
        // The emoji takes two UTF-16 units, which must not shift the runs after it.
        let blocks: [Block] = [
            paragraph("😀😀 wstęp"),
            .paragraph(content: [
                .text("😀 zwykły "),
                .text("gruby", TextStyle(bold: true)),
                .text(" "),
                .text("kursywa", TextStyle(italic: true)),
                .text(" 🇵🇱 "),
                .text("podkreślony", TextStyle(underline: true)),
                .text(" "),
                .text("przekreślony", TextStyle(strikethrough: true)),
            ]),
            .paragraph(content: [.text("Od początku akapitu", TextStyle(bold: true))]),
        ]
        #expect(try roundTrip(blocks) == blocks)
    }

    @Test func aPageBreakSurvives() throws {
        let blocks: [Block] = [paragraph("strona jeden"), .pageBreak, paragraph("strona dwa")]
        #expect(try roundTrip(blocks) == blocks)
    }

    @Test func strayPageBreaksAreDropped() throws {
        #expect(try roundTrip([.pageBreak, paragraph("a"), .pageBreak, .pageBreak]) == [paragraph("a")])
    }

    @Test func keepsLineBreaksInsideAParagraph() throws {
        let block = Block.paragraph(content: [.text("linia"), .lineBreak, .text("druga")])
        #expect(try roundTrip([block]) == [block])
        #expect(try roundTrip([paragraph("a\nb")]) == [.paragraph(content: [.text("a"), .lineBreak, .text("b")])])
    }

    @Test func flattensTablesAndImagesToText() throws {
        let table = Table(rows: [
            ["A1", "B1"].map(TableCell.init(text:)),
            ["A\n2", "B2"].map(TableCell.init(text:)),
        ])
        let image = ImageAsset(data: Data([1]), mimeType: "image/png", alt: "Opis obrazu")
        let nameless = ImageAsset(data: Data([1]), mimeType: "image/png")
        let result = try roundTrip([.table(table), .image(image), .image(nameless), .code("x = 1\ny = 2"), .quote([paragraph("cytat")]), .rule])
        #expect(result == [paragraph("A1\tB1"), paragraph("A 2\tB2"), paragraph("Opis obrazu"), paragraph("x = 1"), paragraph("y = 2"), paragraph("cytat")])
    }

    @Test func removesCharactersThatWouldBreakTheLayout() throws {
        let result = try roundTrip([paragraph("a\u{FFFC}b\u{05}c\u{04}d\u{01}e\u{E000}f")])
        #expect(result == [paragraph("abcdef")])
    }

    @Test func emptyDocument() throws {
        #expect(try roundTrip([]).isEmpty)
    }

    @Test func eachDocumentGetsItsOwnIdentity() throws {
        let folder = try TemporaryFolder()
        let first = folder.file("a.pages")
        let second = folder.file("b.pages")
        try PagesFormat.write(RichDocument(blocks: [paragraph("x")]), to: first)
        try PagesFormat.write(RichDocument(blocks: [paragraph("x")]), to: second)

        func identity(_ url: URL) throws -> (id: String, version: String, revision: String, document: String) {
            let package = try ZipPackage(url: url, formatName: "Pages")
            let plistData = try #require(try package.data(forPart: "Metadata/Properties.plist"))
            let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
            let id = String(decoding: try #require(try package.data(forPart: "Metadata/DocumentIdentifier")), as: UTF8.self)
            let metadata = try IWAStream(compressed: #require(try package.data(forPart: "Index/Metadata.iwa")))
            let parsed = metadata.objects.compactMap { $0.messages.first(where: { $0.type == IWAType.packageMetadata })?.parsed() }
            let package11006 = try #require(parsed.first)
            return (
                id,
                try #require(plist["versionUUID"] as? String),
                try #require(package11006.message(2)?.string(2)),
                try #require(plist["documentUUID"] as? String)
            )
        }
        let a = try identity(first)
        let b = try identity(second)
        #expect(a.id == a.document)
        #expect(a.version == a.revision, "the metadata revision must name the same version as the plist")
        #expect(a.id != b.id)
        #expect(a.version != b.version)
        #expect(!a.id.hasPrefix("00000000"))
    }

    @Test func storesPartsUncompressedLikePages() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("doc.pages")
        try PagesFormat.write(RichDocument(blocks: [paragraph(String(repeating: "powtórka ", count: 10000))]), to: url)
        let package = try ZipPackage(url: url, formatName: "Pages")
        let parts = try package.partNames.reduce(0) { $0 + (try package.data(forPart: $1)?.count ?? 0) }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > parts)
    }

    @Test func writesLargeDocuments() throws {
        // Past one chunk of 64 KB, with text spread over chunks.
        let blocks = (0..<3000).map { paragraph("Akapit numer \($0): zażółć gęślą jaźń 😀") }
        #expect(try roundTrip(blocks) == blocks)
    }
}

@Suite("Pages through Quick Look")
struct PagesQuickLookTests {
    /// Renders with the real iWork engine and returns each page's text with its font runs.
    private func render(_ blocks: [Block]) async throws -> (document: PDFDocument, cleanup: () -> Void) {
        let folder = try TemporaryFolder()
        let url = folder.file("doc.pages")
        try PagesFormat.write(RichDocument(blocks: blocks), to: url)
        let (rendering, output) = try await SystemPreview.render(url)
        guard case .pdf(let pdf) = rendering else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError("expected a PDF")
        }
        let document = try #require(PDFDocument(url: pdf))
        return (document, { try? FileManager.default.removeItem(at: output) })
    }

    private func text(_ document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    /// The font of the first run containing `needle`, across all pages.
    private func font(of needle: String, in document: PDFDocument) -> NSFont? {
        for index in 0..<document.pageCount {
            guard let attributed = document.page(at: index)?.attributedString else { continue }
            let range = (attributed.string as NSString).range(of: needle)
            if range.location != NSNotFound {
                return attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            }
        }
        return nil
    }

    @Test func containsTheWrittenParagraphs() async throws {
        let expected = ["Zażółć gęślą jaźń", "Drugi akapit, z przecinkiem", "Żółta łódź"]
        let (document, cleanup) = try await render(expected.map(paragraph))
        defer { cleanup() }
        let shown = text(document)
        for paragraph in expected {
            #expect(shown.contains(paragraph), "\(paragraph) missing from \(shown)")
        }
    }

    /// The layout engine falls back to unstyled 12 point text when it dislikes a storage. The
    /// template's real sizes showing up is the proof that it accepted this one.
    @Test func headingsAndCharacterStylesRenderThroughTheRealEngine() async throws {
        let (document, cleanup) = try await render([
            .heading(level: 1, content: [.text("Nagłówek pierwszy")]),
            paragraph("Treść akapitu"),
            .heading(level: 2, content: [.text("Nagłówek drugi")]),
            .paragraph(content: [.text("zwykły "), .text("pogrubiony", TextStyle(bold: true)), .text(" "), .text("kursywa", TextStyle(italic: true))]),
            .list(ordered: false, items: [[paragraph("punkt listy")]]),
            .list(ordered: true, items: [[paragraph("numer listy")]]),
        ])
        defer { cleanup() }

        let heading = try #require(font(of: "Nagłówek pierwszy", in: document))
        let body = try #require(font(of: "Treść akapitu", in: document))
        #expect(heading.pointSize > body.pointSize)
        #expect(heading.fontName.contains("Bold"))
        #expect(body.pointSize == 11)
        #expect(try #require(font(of: "Nagłówek drugi", in: document)).pointSize > body.pointSize)
        #expect(try #require(font(of: "pogrubiony", in: document)).fontName.contains("Bold"))
        #expect(try #require(font(of: "kursywa", in: document)).fontName.contains("Italic"))

        let shown = text(document)
        #expect(shown.contains("• punkt listy"))
        #expect(shown.contains("1. numer listy"))
    }

    @Test func pageBreaksStartNewPagesInTheRightOrder() async throws {
        let (document, cleanup) = try await render([
            .heading(level: 1, content: [.text("Strona pierwsza")]),
            .pageBreak,
            paragraph("Strona druga"),
            .pageBreak,
            paragraph("Strona trzecia"),
        ])
        defer { cleanup() }
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.string?.contains("Strona pierwsza") == true)
        #expect(document.page(at: 1)?.string?.contains("Strona druga") == true)
        #expect(document.page(at: 2)?.string?.contains("Strona trzecia") == true)
        #expect(try #require(font(of: "Strona pierwsza", in: document)).pointSize > 11, "page breaks must not trigger the plain fallback")
    }

    @Test func longTextFlowsOverPagesInOrder() async throws {
        // Over 64 KB in all, so the text spans several Snappy chunks.
        let blocks = (1...1200).map { paragraph("Akapit numer \($0) ze zdaniem, które zajmuje trochę miejsca na stronie.") }
        let (document, cleanup) = try await render(blocks)
        defer { cleanup() }
        #expect(document.pageCount > 3)
        let shown = text(document)
        var cursor = shown.startIndex
        for number in stride(from: 1, through: 1200, by: 97) {
            let found = shown.range(of: "Akapit numer \(number) ", range: cursor..<shown.endIndex)
            #expect(found != nil, "paragraph \(number) missing or out of order")
            cursor = found?.upperBound ?? cursor
        }
    }

    @Test func blankTemplateItselfRenders() async throws {
        let (document, cleanup) = try await render([])
        defer { cleanup() }
        #expect(document.pageCount == 1)
    }
}

@Suite("Blank template")
struct BlankTemplateTests {
    private func template() throws -> ZipPackage {
        let url = try #require(Bundle.module.url(forResource: "BlankTemplate", withExtension: "pages", subdirectory: "Resources"))
        return try ZipPackage(url: url, formatName: "Pages")
    }

    private func stream(_ name: String) throws -> IWAStream {
        try IWAStream(compressed: #require(try template().data(forPart: name)))
    }

    @Test func holdsNoPreviewsOrData() throws {
        let names = try template().partNames
        #expect(!names.contains { $0.contains("preview") })
        #expect(!names.contains { $0.hasPrefix("Data/") })
    }

    @Test func bodyIsEmpty() throws {
        let storages = try stream("Index/Document.iwa").objects.flatMap(\.messages).filter { $0.type == IWAType.textStorage }
        #expect(!storages.isEmpty)
        for storage in storages {
            #expect(try #require(storage.parsed()).strings(3).isEmpty)
        }
    }

    @Test func rootHoldsNoMachineDetails() throws {
        let messages = try stream("Index/Document.iwa").objects.flatMap(\.messages)
        let root = try #require(messages.first { $0.type == IWAType.documentRoot }?.parsed())
        // Field 43 is the last used printer.
        #expect(root.bytes(43) == nil)
        let document = try #require(root.message(15)?.message(1))
        #expect(document.string(4) == "en_US")
        // Field 21 is a save time.
        #expect(!document.fields.contains { $0.number == 21 })
    }

    @Test func identifiersArePlaceholders() throws {
        let plistData = try #require(try template().data(forPart: "Metadata/Properties.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        for key in ["documentUUID", "shareUUID", "stableDocumentUUID", "versionUUID", "privateUUID"] {
            #expect((plist[key] as? String)?.hasPrefix("00000000-0000-4000-8000-") == true, "\(key)")
        }
    }

    @Test func everyStreamParses() throws {
        let package = try template()
        for name in package.partNames where name.hasSuffix(".iwa") {
            _ = try IWAStream(compressed: #require(try package.data(forPart: name)))
        }
    }
}

// MARK: - Reading, from documents built object by object

/// Builds a Pages package from objects, for structures the writer does not produce.
private struct PagesFixture {
    var document: [IWAObject] = []
    var stylesheet: [IWAObject] = []
    var metadata: [IWAObject] = []
    var dataFiles: [String: Data] = [:]

    static func object(_ identifier: UInt64, type: UInt64, _ payload: ProtoMessage, references: [UInt64] = [], data: [UInt64] = []) -> IWAObject {
        let bytes = payload.serialized()
        var info = ProtoMessage(fields: [ProtoMessage.Field(1, varint: type), ProtoMessage.Field(3, varint: UInt64(bytes.count))])
        if !references.isEmpty { info.fields.append(ProtoMessage.Field(5, .bytes(ProtoMessage.packVarints(references)))) }
        if !data.isEmpty { info.fields.append(ProtoMessage.Field(6, .bytes(ProtoMessage.packVarints(data)))) }
        let header = ProtoMessage(fields: [ProtoMessage.Field(1, varint: identifier), ProtoMessage.Field(2, message: info)])
        return IWAObject(header: header, messages: [IWAObject.Message(info: info, payload: bytes)])
    }

    static func reference(_ identifier: UInt64) -> ProtoMessage {
        ProtoMessage(fields: [ProtoMessage.Field(1, varint: identifier)])
    }

    /// A text attribute table from `(character index, object)`.
    static func table(_ entries: [(Int, UInt64?)]) -> ProtoMessage {
        ProtoMessage(fields: entries.map { index, object in
            var entry = ProtoMessage(fields: [ProtoMessage.Field(1, varint: UInt64(index))])
            if let object { entry.fields.append(ProtoMessage.Field(2, message: reference(object))) }
            return ProtoMessage.Field(1, message: entry)
        })
    }

    static func storage(
        kind: UInt64 = 0,
        text: String,
        paragraphs: [(Int, UInt64?)] = [],
        lists: [(Int, UInt64?)] = [],
        levels: [(Int, Int)] = [],
        characters: [(Int, UInt64?)] = [],
        attachments: [(Int, UInt64?)] = []
    ) -> ProtoMessage {
        var storage = ProtoMessage(fields: [ProtoMessage.Field(1, varint: kind)])
        if !text.isEmpty { storage.fields.append(ProtoMessage.Field(3, string: text)) }
        if !paragraphs.isEmpty { storage.fields.append(ProtoMessage.Field(5, message: table(paragraphs))) }
        if !levels.isEmpty {
            let entries = levels.map { index, level in
                ProtoMessage.Field(1, message: ProtoMessage(fields: [
                    ProtoMessage.Field(1, varint: UInt64(index)), ProtoMessage.Field(2, varint: UInt64(level)),
                ]))
            }
            storage.fields.append(ProtoMessage.Field(6, message: ProtoMessage(fields: entries)))
        }
        if !lists.isEmpty { storage.fields.append(ProtoMessage.Field(7, message: table(lists))) }
        if !characters.isEmpty { storage.fields.append(ProtoMessage.Field(8, message: table(characters))) }
        if !attachments.isEmpty { storage.fields.append(ProtoMessage.Field(9, message: table(attachments))) }
        return storage
    }

    /// A style with its `TSS.StyleArchive`, plus extra fields.
    static func style(_ identifier: UInt64, type: UInt64, name: String? = nil, styleID: String? = nil, parent: UInt64? = nil, variation: Bool = false, _ extra: [ProtoMessage.Field] = []) -> IWAObject {
        var base = ProtoMessage()
        if let name { base.fields.append(ProtoMessage.Field(1, string: name)) }
        if let styleID { base.fields.append(ProtoMessage.Field(2, string: styleID)) }
        if let parent { base.fields.append(ProtoMessage.Field(3, message: reference(parent))) }
        if variation { base.fields.append(ProtoMessage.Field(4, varint: 1)) }
        return object(identifier, type: type, ProtoMessage(fields: [ProtoMessage.Field(1, message: base)] + extra))
    }

    /// The root object and a body storage, the minimum of a document.
    mutating func setBody(_ storage: ProtoMessage, references: [UInt64] = []) {
        let root = ProtoMessage(fields: [ProtoMessage.Field(4, message: Self.reference(2))])
        document.insert(Self.object(1, type: IWAType.documentRoot, root, references: [2]), at: 0)
        document.insert(Self.object(2, type: IWAType.textStorage, storage, references: references), at: 1)
    }

    var parts: [ZipWriter.Part] {
        var parts = [
            ZipWriter.Part("Index/Document.iwa", IWAStream(objects: document).compressed()),
            ZipWriter.Part("Index/DocumentStylesheet.iwa", IWAStream(objects: stylesheet).compressed()),
            ZipWriter.Part("Index/Metadata.iwa", IWAStream(objects: metadata).compressed()),
        ]
        for (name, data) in dataFiles { parts.append(ZipWriter.Part(name, data)) }
        return parts
    }

    func read() throws -> [Block] {
        let folder = try TemporaryFolder()
        let url = folder.file("fixture.pages")
        try ZipWriter.write(parts, to: url, compression: .none)
        return try PagesFormat.read(url).blocks
    }
}

@Suite("Pages reading")
struct PagesReaderTests {
    private let body: UInt64 = 100
    private let heading: UInt64 = 101

    @Test func stylesAreRecognizedByIdentifierInAnyLanguage() throws {
        var fixture = PagesFixture()
        fixture.stylesheet = [
            PagesFixture.style(100, type: IWAType.paragraphStyle, name: "Treść", styleID: "text-20-paragraphstyle-Body 1"),
            PagesFixture.style(101, type: IWAType.paragraphStyle, name: "Tytuł", styleID: "text-0-paragraphstyle-Title"),
            PagesFixture.style(102, type: IWAType.paragraphStyle, name: "Nagłówek 2", styleID: "text-12-paragraphstyle-Heading 2"),
            PagesFixture.style(103, type: IWAType.paragraphStyle, name: "Podtytuł", styleID: "text-6-paragraphstyle-Subtitle"),
            // A variation inherits what its parent is.
            PagesFixture.style(104, type: IWAType.paragraphStyle, parent: 102, variation: true),
        ]
        fixture.setBody(PagesFixture.storage(
            text: "Tytuł\nPodtytuł\nDwa\nWariant\nTreść",
            paragraphs: [(0, 101), (6, 103), (15, 102), (19, 104), (27, 100)]))
        #expect(try fixture.read() == [
            .heading(level: 1, content: [.text("Tytuł")]),
            .heading(level: 2, content: [.text("Podtytuł")]),
            .heading(level: 2, content: [.text("Dwa")]),
            .heading(level: 2, content: [.text("Wariant")]),
            paragraph("Treść"),
        ])
    }

    @Test func stylesWithoutIdentifiersGoByName() {
        #expect(PagesStyles.headingLevel(fromName: "Heading 3") == 3)
        #expect(PagesStyles.headingLevel(fromName: "Heading") == 1)
        #expect(PagesStyles.headingLevel(fromName: "heading 12") == 6)
        #expect(PagesStyles.headingLevel(fromName: "Title") == 1)
        #expect(PagesStyles.headingLevel(fromName: "Subtitle") == 2)
        #expect(PagesStyles.headingLevel(fromName: "Body") == nil)
        #expect(PagesStyles.headingLevel(fromName: "Table Title 1") == nil)
        #expect(PagesStyles.headingLevel(fromName: "Caption Title") == nil)
    }

    @Test func aParagraphTableEntryWithoutObjectRepeatsTheStyle() throws {
        var fixture = PagesFixture()
        fixture.stylesheet = [PagesFixture.style(101, type: IWAType.paragraphStyle, styleID: "text-11-paragraphstyle-Heading 1")]
        fixture.setBody(PagesFixture.storage(text: "A\nB", paragraphs: [(0, 101), (2, nil)]))
        #expect(try fixture.read() == [.heading(level: 1, content: [.text("A")]), .heading(level: 1, content: [.text("B")])])
    }

    @Test func aCharacterTableEntryWithoutObjectEndsTheStyle() throws {
        let bold = ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1)])
        var fixture = PagesFixture()
        fixture.stylesheet = [PagesFixture.style(110, type: IWAType.characterStyle, [ProtoMessage.Field(11, message: bold)])]
        fixture.setBody(PagesFixture.storage(text: "abcdef", characters: [(0, nil), (2, 110), (4, nil)]))
        #expect(try fixture.read() == [
            .paragraph(content: [.text("ab"), .text("cd", TextStyle(bold: true)), .text("ef")]),
        ])
    }

    @Test func readsCharacterStyleProperties() throws {
        let color = ProtoMessage(fields: [
            ProtoMessage.Field(1, varint: 1),
            ProtoMessage.Field(3, .fixed32(Float(1).bitPattern)),
            ProtoMessage.Field(4, .fixed32(Float(0.5).bitPattern)),
            ProtoMessage.Field(5, .fixed32(Float(0).bitPattern)),
        ])
        let parent = ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1), ProtoMessage.Field(2, varint: 1)])
        let child = ProtoMessage(fields: [
            // The variation turns bold back off and adds the rest.
            ProtoMessage.Field(1, varint: 0),
            ProtoMessage.Field(3, .fixed32(Float(14).bitPattern)),
            ProtoMessage.Field(5, string: "Menlo"),
            ProtoMessage.Field(7, message: color),
            ProtoMessage.Field(11, varint: 1),
            ProtoMessage.Field(12, varint: 1),
        ])
        var fixture = PagesFixture()
        fixture.stylesheet = [
            PagesFixture.style(110, type: IWAType.characterStyle, [ProtoMessage.Field(11, message: parent)]),
            PagesFixture.style(111, type: IWAType.characterStyle, parent: 110, variation: true, [ProtoMessage.Field(11, message: child)]),
        ]
        fixture.setBody(PagesFixture.storage(text: "x", characters: [(0, 111)]))
        let expected = TextStyle(italic: true, underline: true, strikethrough: true, color: "#FF8000", fontSize: 14, fontFamily: "Menlo")
        #expect(try fixture.read() == [.paragraph(content: [.text("x", expected)])])
    }

    @Test func aParagraphVariationCarriesItsChanges() throws {
        let bold = ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1)])
        let large = ProtoMessage(fields: [ProtoMessage.Field(3, .fixed32(Float(30).bitPattern))])
        var fixture = PagesFixture()
        fixture.stylesheet = [
            PagesFixture.style(100, type: IWAType.paragraphStyle, styleID: "text-20-paragraphstyle-Body 1", [ProtoMessage.Field(11, message: large)]),
            PagesFixture.style(105, type: IWAType.paragraphStyle, parent: 100, variation: true, [ProtoMessage.Field(11, message: bold)]),
        ]
        fixture.setBody(PagesFixture.storage(text: "zwykły\ngruby", paragraphs: [(0, 100), (7, 105)]))
        #expect(try fixture.read() == [
            paragraph("zwykły"),
            .paragraph(content: [.text("gruby", TextStyle(bold: true))]),
        ])
    }

    @Test func readsAlignment() throws {
        func style(_ identifier: UInt64, _ value: UInt64) -> IWAObject {
            PagesFixture.style(identifier, type: IWAType.paragraphStyle, name: "s\(identifier)", [
                ProtoMessage.Field(12, message: ProtoMessage(fields: [ProtoMessage.Field(1, varint: value)])),
            ])
        }
        var fixture = PagesFixture()
        fixture.stylesheet = [style(100, 0), style(101, 1), style(102, 2), style(103, 3), style(104, 4)]
        fixture.setBody(PagesFixture.storage(text: "a\nb\nc\nd\ne", paragraphs: [(0, 100), (2, 101), (4, 102), (6, 103), (8, 104)]))
        #expect(try fixture.read() == [
            paragraph("a"),
            .paragraph(content: [.text("b")], alignment: .right),
            .paragraph(content: [.text("c")], alignment: .center),
            .paragraph(content: [.text("d")], alignment: .justified),
            paragraph("e"),
        ])
    }

    private func listStyle(_ identifier: UInt64, labels: [UInt64]) -> IWAObject {
        PagesFixture.style(identifier, type: IWAType.listStyle, labels.map { ProtoMessage.Field(11, varint: $0) })
    }

    @Test func readsListsAndTheirLevels() throws {
        var fixture = PagesFixture()
        fixture.stylesheet = [
            listStyle(120, labels: [0, 0]),
            listStyle(121, labels: [2, 2]),
            listStyle(122, labels: [3, 3]),
        ]
        fixture.setBody(PagesFixture.storage(
            text: "a\nb\nc\nd\ne",
            lists: [(0, 120), (2, 121), (6, 122), (8, 120)],
            levels: [(0, 0), (4, 1), (6, 0)]))
        #expect(try fixture.read() == [
            paragraph("a"),
            .list(ordered: false, items: [[paragraph("b"), .list(ordered: false, items: [[paragraph("c")]])]]),
            .list(ordered: true, items: [[paragraph("d")]]),
            paragraph("e"),
        ])
    }

    @Test func breakCharactersEndParagraphs() throws {
        var fixture = PagesFixture()
        fixture.setBody(PagesFixture.storage(text: "a\u{05}b\u{04}c\u{0C}d\u{0E}e\u{2029}f\n\n\ng"))
        #expect(try fixture.read() == [
            paragraph("a"), .pageBreak, paragraph("b"), .pageBreak, paragraph("c"), .pageBreak,
            paragraph("d"), paragraph("e"), paragraph("f"), paragraph("g"),
        ])
    }

    @Test func textMayBeSplitOverSeveralStrings() throws {
        var storage = PagesFixture.storage(text: "pierwszy ")
        storage.fields.insert(ProtoMessage.Field(3, string: "drugi"), at: 2)
        var fixture = PagesFixture()
        fixture.setBody(storage)
        #expect(try fixture.read() == [paragraph("pierwszy drugi")])
    }

    @Test func offsetsCountUTF16Units() throws {
        let bold = ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1)])
        var fixture = PagesFixture()
        fixture.stylesheet = [PagesFixture.style(110, type: IWAType.characterStyle, [ProtoMessage.Field(11, message: bold)])]
        fixture.setBody(PagesFixture.storage(text: "😀ab", characters: [(0, nil), (2, 110)]))
        #expect(try fixture.read() == [.paragraph(content: [.text("😀"), .text("ab", TextStyle(bold: true))])])
    }

    @Test func hostileTablesDoNotCrash() throws {
        var fixture = PagesFixture()
        // Indexes out of order, past the end, and as large as a varint gets.
        let huge = ProtoMessage.Field(1, message: ProtoMessage(fields: [ProtoMessage.Field(1, varint: UInt64.max)]))
        var storage = PagesFixture.storage(text: "abc\ndef", paragraphs: [(5, 999), (0, nil), (99, 1)], characters: [(4, 999), (1, 998), (2, nil)])
        storage.fields.append(ProtoMessage.Field(6, message: ProtoMessage(fields: [huge])))
        fixture.setBody(storage)
        #expect(try fixture.read().map(\.plainText).joined(separator: "|") == "abc|def")
    }

    @Test func aStyleCycleDoesNotHang() throws {
        var fixture = PagesFixture()
        fixture.stylesheet = [
            PagesFixture.style(130, type: IWAType.paragraphStyle, parent: 131),
            PagesFixture.style(131, type: IWAType.paragraphStyle, parent: 130),
        ]
        fixture.setBody(PagesFixture.storage(text: "a", paragraphs: [(0, 130)]))
        #expect(try fixture.read() == [paragraph("a")])
    }

    // MARK: Images

    private func imageFixture(attached: Bool) throws -> PagesFixture {
        let png = try makePNG(width: 4, height: 4)
        var fixture = PagesFixture()
        // A thumbnail, the real image, and a theme image only the stylesheet uses.
        fixture.dataFiles = [
            "Data/photo-555.png": png,
            "Data/photo-small-556.png": Data(png.prefix(1)),
            "Data/theme-557.jpg": Data([1, 2, 3]),
        ]
        let dataInfo = { (identifier: UInt64, name: String) -> ProtoMessage.Field in
            ProtoMessage.Field(4, message: ProtoMessage(fields: [
                ProtoMessage.Field(1, varint: identifier),
                ProtoMessage.Field(3, string: "photo.png"),
                ProtoMessage.Field(4, string: name),
            ]))
        }
        fixture.metadata = [PagesFixture.object(9, type: IWAType.packageMetadata, ProtoMessage(fields: [
            dataInfo(555, "photo-555.png"), dataInfo(556, "photo-small-556.png"),
        ]))]
        fixture.document = [
            PagesFixture.object(200, type: 2003, ProtoMessage(), references: [201]),
            PagesFixture.object(201, type: IWAType.image, ProtoMessage(), data: [556, 555]),
        ]
        fixture.setBody(PagesFixture.storage(
            text: attached ? "przed\u{FFFC}po" : "tekst",
            attachments: attached ? [(0, nil), (5, 200), (6, nil)] : []))
        return fixture
    }

    @Test func anchoredImagesFollowTheirParagraph() throws {
        let blocks = try imageFixture(attached: true).read()
        #expect(blocks.count == 2)
        #expect(blocks[0] == paragraph("przedpo"))
        guard case .image(let image) = blocks[1] else {
            Issue.record("expected an image")
            return
        }
        #expect(image.data == (try makePNG(width: 4, height: 4)))
        #expect(image.mimeType == "image/png")
    }

    @Test func floatingImagesComeAfterTheText() throws {
        let blocks = try imageFixture(attached: false).read()
        #expect(blocks.count == 2)
        #expect(blocks[0] == paragraph("tekst"))
        if case .image = blocks[1] {} else { Issue.record("expected an image") }
    }

    @Test func aMissingImageFileIsNoProblem() throws {
        var fixture = try imageFixture(attached: true)
        fixture.dataFiles = [:]
        #expect(try fixture.read() == [paragraph("przedpo")])
    }

    // MARK: Tables

    /// A cell record: version, kind, a field mask at offset 8, then the fields.
    private func cell(kind: UInt8, mask: UInt32, fields: [UInt8] = []) -> [UInt8] {
        var bytes: [UInt8] = [5, kind, 0, 0, 0, 0, 0, 0]
        withUnsafeBytes(of: mask.littleEndian) { bytes += $0 }
        return bytes + fields
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// iWork's decimal128 for `mantissa * 10^exponent`.
    private func decimal(_ mantissa: UInt64, exponent: Int, negative: Bool = false) -> [UInt8] {
        var bytes = littleEndian(mantissa) + Array(repeating: 0, count: 8)
        let biased = exponent + 0x1820
        bytes[14] = UInt8((biased & 0x7F) << 1)
        bytes[15] = UInt8((biased >> 7) & 0x7F) | (negative ? 0x80 : 0)
        return bytes
    }

    private func tableFixture(rows: [[[UInt8]?]], strings: [UInt64: String], headerRows: UInt64 = 1, wideOffsets: Bool = false) -> PagesFixture {
        let columnCount = rows.map(\.count).max() ?? 0
        let rowInfos = rows.enumerated().map { rowIndex, cells -> ProtoMessage.Field in
            var buffer: [UInt8] = []
            var offsets: [UInt8] = []
            for column in 0..<columnCount {
                if column < cells.count, let cell = cells[column] {
                    let padded = cell + Array(repeating: 0, count: (4 - cell.count % 4) % 4)
                    offsets += littleEndian(Int16(wideOffsets ? buffer.count / 4 : buffer.count))
                    buffer += padded
                } else {
                    offsets += littleEndian(Int16(-1))
                }
            }
            return ProtoMessage.Field(5, message: ProtoMessage(fields: [
                ProtoMessage.Field(1, varint: UInt64(rowIndex)),
                ProtoMessage.Field(6, .bytes(Data(buffer))),
                ProtoMessage.Field(7, .bytes(Data(offsets))),
                ProtoMessage.Field(8, varint: wideOffsets ? 1 : 0),
            ]))
        }
        let stringEntries = strings.map { key, text in
            ProtoMessage.Field(3, message: ProtoMessage(fields: [ProtoMessage.Field(1, varint: key), ProtoMessage.Field(3, string: text)]))
        }
        let tiles = ProtoMessage(fields: [
            ProtoMessage.Field(1, message: ProtoMessage(fields: [
                ProtoMessage.Field(1, varint: 0), ProtoMessage.Field(2, message: PagesFixture.reference(303)),
            ])),
            ProtoMessage.Field(2, varint: 256),
        ])
        let dataStore = ProtoMessage(fields: [
            ProtoMessage.Field(3, message: tiles),
            ProtoMessage.Field(4, message: PagesFixture.reference(304)),
        ])
        let model = ProtoMessage(fields: [
            ProtoMessage.Field(4, message: dataStore),
            ProtoMessage.Field(6, varint: UInt64(rows.count + 3)),
            ProtoMessage.Field(7, varint: UInt64(columnCount + 2)),
            ProtoMessage.Field(9, varint: headerRows),
        ])
        var fixture = PagesFixture()
        fixture.document = [
            PagesFixture.object(300, type: 2003, ProtoMessage(), references: [301]),
            PagesFixture.object(301, type: IWAType.tableInfo, ProtoMessage(fields: [ProtoMessage.Field(2, message: PagesFixture.reference(302))]), references: [302]),
            PagesFixture.object(302, type: IWAType.tableModel, model),
            PagesFixture.object(303, type: IWAType.tableTile, ProtoMessage(fields: rowInfos)),
            PagesFixture.object(304, type: IWAType.tableDataList, ProtoMessage(fields: [ProtoMessage.Field(1, varint: 1)] + stringEntries)),
        ]
        fixture.setBody(PagesFixture.storage(text: "\u{FFFC}", attachments: [(0, 300), (1, nil)]))
        return fixture
    }

    @Test(arguments: [false, true])
    func readsTableCells(wideOffsets: Bool) throws {
        let fixture = tableFixture(
            rows: [
                [cell(kind: 3, mask: 0x8, fields: littleEndian(UInt32(7))), cell(kind: 3, mask: 0x8, fields: littleEndian(UInt32(8))), nil],
                [
                    cell(kind: 2, mask: 0x1, fields: decimal(123_456, exponent: -2)),
                    cell(kind: 2, mask: 0x1, fields: decimal(5, exponent: 0, negative: true)),
                    cell(kind: 2, mask: 0x2, fields: littleEndian((0.25).bitPattern)),
                ],
                [
                    cell(kind: 5, mask: 0x4, fields: littleEndian((86400.0).bitPattern)),
                    cell(kind: 6, mask: 0x2, fields: littleEndian((1.0).bitPattern)),
                    cell(kind: 0, mask: 0),
                ],
            ],
            strings: [7: "Imię", 8: "Zażółć 😀"],
            wideOffsets: wideOffsets)
        let blocks = try fixture.read()
        guard blocks.count == 1, case .table(let table) = blocks[0] else {
            Issue.record("expected one table, got \(blocks)")
            return
        }
        #expect(table.hasHeaderRow)
        #expect(table.rows.map { $0.map(\.plainText) } == [
            ["Imię", "Zażółć 😀", ""],
            ["1234.56", "-5", "0.25"],
            ["2001-01-02", "TRUE", ""],
        ])
    }

    @Test func aDamagedCellRecordIsSkipped() throws {
        let fixture = tableFixture(
            rows: [
                [cell(kind: 3, mask: 0x8, fields: littleEndian(UInt32(7))), [1, 2, 3, 4], cell(kind: 3, mask: 0x8)],
                [cell(kind: 3, mask: 0x8, fields: littleEndian(UInt32(99)))],
            ],
            strings: [7: "dobry"])
        guard case .table(let table)? = try fixture.read().first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows == [[TableCell(text: "dobry")]])
    }

    // MARK: Packages

    @Test func readsDirectoryPackages() throws {
        let folder = try TemporaryFolder()
        let package = folder.file("doc.pages")
        var fixture = PagesFixture()
        fixture.setBody(PagesFixture.storage(text: "z folderu"))
        for part in fixture.parts {
            let target = package.appendingPathComponent(part.name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try part.data.write(to: target)
        }
        #expect(try PagesFormat.read(package).blocks == [paragraph("z folderu")])
    }

    @Test func readsDirectoryPackagesWithAnIndexZip() throws {
        let folder = try TemporaryFolder()
        let package = folder.file("doc.pages")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Data"), withIntermediateDirectories: true)
        var fixture = try imageFixture(attached: true)
        try fixture.dataFiles.forEach { try $0.value.write(to: package.appendingPathComponent($0.key)) }
        fixture.dataFiles = [:]
        try ZipWriter.write(fixture.parts, to: package.appendingPathComponent("Index.zip"), compression: .none)

        let blocks = try PagesFormat.read(package).blocks
        #expect(blocks.count == 2)
        if case .image = blocks[1] {} else { Issue.record("the image lives beside Index.zip") }
    }

    @Test func aPageLayoutDocumentKeepsItsTextInTextBoxes() throws {
        var fixture = PagesFixture()
        fixture.document = [PagesFixture.object(400, type: IWAType.textStorage, PagesFixture.storage(kind: 3, text: "w ramce"))]
        fixture.setBody(PagesFixture.storage(text: ""))
        #expect(try fixture.read() == [paragraph("w ramce")])
    }

    @Test func worksWithoutARootObject() throws {
        var fixture = PagesFixture()
        fixture.document = [PagesFixture.object(400, type: IWAType.textStorage, PagesFixture.storage(text: "bez korzenia"))]
        #expect(try fixture.read() == [paragraph("bez korzenia")])
    }

    // MARK: Damage

    @Test func recoversTextFromADamagedStream() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("doc.pages")
        var fixture = PagesFixture()
        fixture.setBody(PagesFixture.storage(text: "Zdanie, które da się odzyskać z pliku."))
        var damaged = IWAStream(objects: fixture.document).serialized()
        // A message claiming more bytes than exist: the structure is lost, the text is not.
        damaged.insert(contentsOf: [0xFF, 0x7F], at: 0)
        try ZipWriter.write([ZipWriter.Part("Index/Document.iwa", IWAStream.compress(damaged))], to: url, compression: .none)
        let text = try PagesFormat.read(url).plainText
        #expect(text.contains("Zdanie, które da się odzyskać z pliku."))
    }

    @Test func keepsWhatPrecedesATruncation() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("doc.pages")
        var fixture = PagesFixture()
        fixture.setBody(PagesFixture.storage(text: "Początek dokumentu."))
        let intact = IWAStream(objects: fixture.document).compressed()
        try ZipWriter.write([ZipWriter.Part("Index/Document.iwa", intact + Data([0, 9, 9]))], to: url, compression: .none)
        #expect(try PagesFormat.read(url).plainText == "Początek dokumentu.")
    }

    @Test func throwsWhenNothingCanBeRead() throws {
        let folder = try TemporaryFolder()
        let garbage = folder.file("garbage.pages")
        try ZipWriter.write([ZipWriter.Part("Index/Document.iwa", Data(repeating: 0xAB, count: 512))], to: garbage, compression: .none)
        #expect(throws: ConversionError.self) { try PagesFormat.read(garbage) }

        let notZip = folder.file("notzip.pages")
        try Data("this is not a zip".utf8).write(to: notZip)
        #expect(throws: ConversionError.self) { try PagesFormat.read(notZip) }

        let noIndex = folder.file("noindex.pages")
        try ZipWriter.write([ZipWriter.Part("index.xml", "<old/>")], to: noIndex)
        #expect(throws: ConversionError.self) { try PagesFormat.read(noIndex) }

        let missing = folder.file("missing.pages")
        #expect(throws: ConversionError.self) { try PagesFormat.read(missing) }

        let emptyFolder = folder.file("empty.pages")
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        #expect(throws: ConversionError.self) { try PagesFormat.read(emptyFolder) }
    }

    @Test func explainsPasswordProtection() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("locked.pages")
        try ZipWriter.write([ZipWriter.Part(".iwph", "hint"), ZipWriter.Part("Index/Document.iwa", Data([1, 2, 3]))], to: url, compression: .none)
        #expect(throws: ConversionError("This Pages document is password protected.")) {
            try PagesFormat.read(url)
        }
    }

    @Test func randomBytesNeverCrash() throws {
        // A fixed generator, so a failure repeats.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
        var fixture = PagesFixture()
        fixture.stylesheet = [PagesFixture.style(100, type: IWAType.paragraphStyle, name: "Body")]
        fixture.setBody(PagesFixture.storage(text: "abc\ndef", paragraphs: [(0, 100), (4, nil)]))
        let intact = IWAStream(objects: fixture.document).serialized()

        let folder = try TemporaryFolder()
        let url = folder.file("fuzz.pages")
        for _ in 0..<300 {
            var damaged = intact
            for _ in 0..<(1 + Int(next() % 8)) {
                let position = Int(next()) * Int(next()) % damaged.count
                damaged[position] = next()
            }
            try ZipWriter.write([ZipWriter.Part("Index/Document.iwa", IWAStream.compress(damaged))], to: url, compression: .none)
            _ = try? PagesFormat.read(url)
        }
    }
}

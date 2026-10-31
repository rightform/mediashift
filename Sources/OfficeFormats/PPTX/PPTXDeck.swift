import ConversionCore
import Foundation

/// Images embedded in a deck, each distinct one stored once.
final class PPTXMedia {
    private var names: [Data: String] = [:]
    private(set) var parts: [ZipWriter.Part] = []
    private(set) var extensions: Set<String> = []

    func prepare(_ asset: ImageAsset) -> PreparedImage? {
        ImageSupport.prepare(asset, allowedExtensions: PPTXDeck.embeddableImages)
    }

    /// The part name of an image, relative to a slide.
    func store(_ image: PreparedImage) -> String {
        if let name = names[image.data] { return name }
        let file = "image\(parts.count + 1).\(image.fileExtension)"
        parts.append(ZipWriter.Part("ppt/media/\(file)", image.data))
        extensions.insert(image.fileExtension)
        let target = "../media/\(file)"
        names[image.data] = target
        return target
    }
}

/// Assembles the package around finished slides.
struct PPTXDeck {
    static let embeddableImages: Set<String> = ["png", "jpg", "gif", "tiff", "tif", "bmp"]

    /// Size in EMU, 12700 to the point.
    struct SlideSize {
        var width: Int
        var height: Int
    }

    static let widescreen = SlideSize(width: 12_192_000, height: 6_858_000)

    let media = PPTXMedia()
    private let title: String?
    private let author: String?
    private let slideSize: SlideSize
    private var slideParts: [(xml: String, relationships: String)] = []

    init(title: String?, author: String?, slideSize: SlideSize = PPTXDeck.widescreen) {
        self.title = title
        self.author = author
        self.slideSize = slideSize
    }

    /// The long side stays at the widescreen width. PowerPoint accepts 1 to 56 inches.
    static func slideSize(aspectWidth: Double, aspectHeight: Double) -> SlideSize {
        let longSide = Double(widescreen.width)
        let scale = longSide / max(aspectWidth, aspectHeight)
        func clamp(_ value: Double) -> Int { Int(min(51_206_400, max(914_400, value))) }
        return SlideSize(width: clamp(aspectWidth * scale), height: clamp(aspectHeight * scale))
    }

    mutating func add(_ slide: PPTXSlide) {
        var builder = PPTXSlideBuilder(media: media, slideSize: slideSize)
        let xml = builder.xml(for: slide)
        slideParts.append((xml, builder.relationshipsXML()))
    }

    func parts() -> [ZipWriter.Part] {
        var parts: [ZipWriter.Part] = [
            ZipWriter.Part("[Content_Types].xml", contentTypes()),
            ZipWriter.Part("_rels/.rels", packageRelationships),
            ZipWriter.Part("docProps/core.xml", OPC.corePropertiesXML(title: title, author: author)),
            ZipWriter.Part("ppt/presentation.xml", presentationXML()),
            ZipWriter.Part("ppt/_rels/presentation.xml.rels", presentationRelationships()),
            ZipWriter.Part("ppt/tableStyles.xml", PPTXBoilerplate.tableStyles),
            ZipWriter.Part("ppt/theme/theme1.xml", PPTXBoilerplate.theme),
            ZipWriter.Part("ppt/slideMasters/slideMaster1.xml", PPTXBoilerplate.master(slideSize)),
            ZipWriter.Part("ppt/slideMasters/_rels/slideMaster1.xml.rels", PPTXBoilerplate.masterRelationships),
            ZipWriter.Part("ppt/slideLayouts/slideLayout1.xml", PPTXBoilerplate.titleAndContentLayout),
            ZipWriter.Part("ppt/slideLayouts/_rels/slideLayout1.xml.rels", PPTXBoilerplate.layoutRelationships),
            ZipWriter.Part("ppt/slideLayouts/slideLayout2.xml", PPTXBoilerplate.blankLayout),
            ZipWriter.Part("ppt/slideLayouts/_rels/slideLayout2.xml.rels", PPTXBoilerplate.layoutRelationships),
        ]
        for (index, slide) in slideParts.enumerated() {
            parts.append(ZipWriter.Part("ppt/slides/slide\(index + 1).xml", slide.xml))
            parts.append(ZipWriter.Part("ppt/slides/_rels/slide\(index + 1).xml.rels", slide.relationships))
        }
        return parts + media.parts
    }

    private func presentationXML() -> String {
        var xml = OPC.xmlHeader
        xml += "<p:presentation xmlns:a=\"\(PPTXBoilerplate.drawingNamespace)\" xmlns:r=\"\(OPC.officeRelationships)\" xmlns:p=\"\(PPTXBoilerplate.presentationNamespace)\" saveSubsetFonts=\"1\">"
        xml += "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>"
        for index in slideParts.indices {
            xml += "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(index + 4)\"/>"
        }
        xml += "</p:sldIdLst><p:sldSz cx=\"\(slideSize.width)\" cy=\"\(slideSize.height)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
        return xml + "</p:presentation>"
    }

    private func presentationRelationships() -> String {
        var items: [(id: String, type: String, target: String, external: Bool)] = [
            ("rId1", "\(OPC.officeRelationships)/slideMaster", "slideMasters/slideMaster1.xml", false),
            ("rId2", "\(OPC.officeRelationships)/theme", "theme/theme1.xml", false),
            ("rId3", "\(OPC.officeRelationships)/tableStyles", "tableStyles.xml", false),
        ]
        for index in slideParts.indices {
            items.append(("rId\(index + 4)", "\(OPC.officeRelationships)/slide", "slides/slide\(index + 1).xml", false))
        }
        return OPC.relationshipsXML(items)
    }

    private var packageRelationships: String {
        OPC.relationshipsXML([
            ("rId1", "\(OPC.officeRelationships)/officeDocument", "ppt/presentation.xml", false),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml", false),
        ])
    }

    private func contentTypes() -> String {
        let main = "application/vnd.openxmlformats-officedocument.presentationml"
        var xml = OPC.xmlHeader
        xml += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        xml += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        xml += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for fileExtension in media.extensions.sorted() {
            xml += "<Default Extension=\"\(fileExtension)\" ContentType=\"\(ImageSupport.mimeType(forPath: "x.\(fileExtension)"))\"/>"
        }
        func override(_ part: String, _ type: String) {
            xml += "<Override PartName=\"/\(part)\" ContentType=\"\(type)\"/>"
        }
        override("ppt/presentation.xml", "\(main).presentation.main+xml")
        override("ppt/slideMasters/slideMaster1.xml", "\(main).slideMaster+xml")
        override("ppt/slideLayouts/slideLayout1.xml", "\(main).slideLayout+xml")
        override("ppt/slideLayouts/slideLayout2.xml", "\(main).slideLayout+xml")
        override("ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml")
        override("ppt/tableStyles.xml", "\(main).tableStyles+xml")
        override("docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml")
        for index in slideParts.indices {
            override("ppt/slides/slide\(index + 1).xml", "\(main).slide+xml")
        }
        return xml + "</Types>"
    }
}

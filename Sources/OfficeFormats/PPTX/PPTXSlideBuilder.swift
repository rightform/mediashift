import ConversionCore
import Foundation

/// Writes one slide's XML and collects the relationships it needs. Element order inside
/// `a:rPr`, `a:pPr` and `a:tc` is fixed by the schema, and PowerPoint repairs files that break it.
struct PPTXSlideBuilder {
    private typealias Geometry = PPTXPaginator.Geometry

    private let media: PPTXMedia
    private let slideSize: PPTXDeck.SlideSize
    private var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    private var nextShapeID = 2

    init(media: PPTXMedia, slideSize: PPTXDeck.SlideSize) {
        self.media = media
        self.slideSize = slideSize
    }

    func relationshipsXML() -> String {
        OPC.relationshipsXML(relationships)
    }

    private mutating func addRelationship(type: String, target: String, external: Bool = false) -> String {
        if let existing = relationships.first(where: { $0.target == target && $0.type == type }) { return existing.id }
        let id = "rId\(relationships.count + 1)"
        relationships.append((id, type, target, external))
        return id
    }

    private mutating func shapeID() -> Int {
        defer { nextShapeID += 1 }
        return nextShapeID
    }

    private func emu(_ points: Double) -> Int {
        guard points.isFinite else { return 0 }
        return Int((min(max(points, 0), 10_000) * 12700).rounded())
    }

    /// Space kept under a table, whose rows may render taller than estimated.
    static let tableGap = 14.0

    // MARK: Slide

    mutating func xml(for slide: PPTXSlide) -> String {
        let isFullBleed = slide.items.contains { if case .fullBleedImage = $0 { true } else { false } }
        let hasPlaceholders = slide.title != nil || slide.items.contains { if case .text = $0 { true } else { false } }
        let layout = isFullBleed || !hasPlaceholders ? "slideLayout2.xml" : "slideLayout1.xml"
        _ = addRelationship(type: "\(OPC.officeRelationships)/slideLayout", target: "../slideLayouts/\(layout)")

        var shapes = ""
        if let title = slide.title {
            shapes += titleXML(title)
        }
        var y = slide.title == nil ? Geometry.untitledBodyY : Geometry.bodyY
        var usedPlaceholder = false
        for item in slide.items {
            switch item {
            case .text(let paragraphs, let height):
                // The first text goes in the body placeholder, later ones in text boxes below it.
                shapes += textXML(paragraphs, y: y, height: height, isPlaceholder: !usedPlaceholder)
                usedPlaceholder = true
                y += height + 8
            case .table(let rows, let widths, let hasHeaderRow):
                shapes += tableXML(rows, widths: widths, hasHeaderRow: hasHeaderRow, y: y)
                y += rows.reduce(0) { $0 + $1.height } + Self.tableGap
            case .image(let asset, let image, let width, let height):
                let x = Geometry.marginX + (Geometry.contentWidth - width) / 2
                shapes += pictureXML(asset, image, x: emu(x), y: emu(y), width: emu(width), height: emu(height))
                y += height + 8
            case .fullBleedImage(let asset, let image):
                shapes += fullBleedXML(asset, image)
            }
        }

        return OPC.xmlHeader
            + "<p:sld xmlns:a=\"\(PPTXBoilerplate.drawingNamespace)\" xmlns:r=\"\(OPC.officeRelationships)\" xmlns:p=\"\(PPTXBoilerplate.presentationNamespace)\">"
            + "<p:cSld><p:spTree>\(PPTXBoilerplate.groupHeader)\(shapes)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }

    private mutating func titleXML(_ title: [Inline]) -> String {
        let id = shapeID()
        let text = runsXML(title.filter { if case .image = $0 { false } else { true } }, baseStyle: TextStyle())
        return """
            <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Title \(id - 1)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
            <p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/>\
            <p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p>\(text)</a:p></p:txBody></p:sp>
            """
    }

    private mutating func textXML(_ paragraphs: [PPTXSlide.Paragraph], y: Double, height: Double, isPlaceholder: Bool) -> String {
        let id = shapeID()
        let shapeHeight = max(height, 30)
        let frame = "<a:xfrm><a:off x=\"\(emu(Geometry.marginX))\" y=\"\(emu(y))\"/><a:ext cx=\"\(emu(Geometry.contentWidth))\" cy=\"\(emu(shapeHeight))\"/></a:xfrm>"
        var body = ""
        for paragraph in paragraphs { body += paragraphXML(paragraph) }

        if isPlaceholder {
            return """
                <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Content \(id - 1)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
                <p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr>\(frame)</p:spPr>\
                <p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/>\(body)</p:txBody></p:sp>
                """
        }
        return """
            <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Text \(id - 1)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
            <p:spPr>\(frame)<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\
            <p:txBody><a:bodyPr wrap="square" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(body)</p:txBody></p:sp>
            """
    }

    // MARK: Text

    private mutating func paragraphXML(_ paragraph: PPTXSlide.Paragraph) -> String {
        let indent = 342_900
        var attributes = ""
        if paragraph.level > 0 { attributes += " lvl=\"\(paragraph.level)\"" }
        switch paragraph.bullet {
        case .none:
            attributes += " marL=\"\(paragraph.level * indent)\" indent=\"0\""
        case .unordered, .ordered:
            attributes += " marL=\"\((paragraph.level + 1) * indent)\" indent=\"-\(indent)\""
        }
        if let alignment = paragraph.alignment {
            switch alignment {
            case .left: attributes += " algn=\"l\""
            case .center: attributes += " algn=\"ctr\""
            case .right: attributes += " algn=\"r\""
            case .justified: attributes += " algn=\"just\""
            }
        }
        let bullet: String
        switch paragraph.bullet {
        case .none: bullet = "<a:buNone/>"
        case .unordered: bullet = "<a:buFont typeface=\"Arial\"/><a:buChar char=\"&#8226;\"/>"
        case .ordered: bullet = "<a:buFont typeface=\"+mj-lt\"/><a:buAutoNum type=\"arabicPeriod\"/>"
        }
        return "<a:p><a:pPr\(attributes)>\(bullet)</a:pPr>\(runsXML(paragraph.content, baseStyle: paragraph.baseStyle))</a:p>"
    }

    private mutating func runsXML(_ inlines: [Inline], baseStyle: TextStyle) -> String {
        var xml = ""
        for inline in inlines {
            switch inline {
            case .text(let text, let style):
                let merged = Self.merge(style, over: baseStyle)
                let properties = runPropertiesXML(merged)
                let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                for (index, line) in lines.enumerated() {
                    if index > 0 { xml += "<a:br>\(properties)</a:br>" }
                    if !line.isEmpty { xml += "<a:r>\(properties)<a:t>\(String(line).xmlEscaped)</a:t></a:r>" }
                }
            case .lineBreak:
                xml += "<a:br/>"
            case .image:
                break
            }
        }
        return xml
    }

    private static func merge(_ style: TextStyle, over base: TextStyle) -> TextStyle {
        var merged = style
        merged.bold = style.bold || base.bold
        merged.italic = style.italic || base.italic
        merged.fontSize = style.fontSize ?? base.fontSize
        merged.fontFamily = style.fontFamily ?? base.fontFamily
        if style.code {
            merged.fontFamily = merged.fontFamily ?? "Menlo"
        }
        return merged
    }

    private mutating func runPropertiesXML(_ style: TextStyle) -> String {
        var attributes = " lang=\"en-US\" dirty=\"0\""
        if let size = style.fontSize, size >= 1, size <= 400 { attributes += " sz=\"\(Int((size * 100).rounded()))\"" }
        if style.bold { attributes += " b=\"1\"" }
        if style.italic { attributes += " i=\"1\"" }
        if style.underline { attributes += " u=\"sng\"" }
        if style.strikethrough { attributes += " strike=\"sngStrike\"" }
        if style.superscript { attributes += " baseline=\"30000\"" }
        if style.subscript { attributes += " baseline=\"-25000\"" }

        var children = ""
        if let color = Self.hex(style.color) { children += "<a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill>" }
        if let highlight = Self.hex(style.highlight) { children += "<a:highlight><a:srgbClr val=\"\(highlight)\"/></a:highlight>" }
        if let family = style.fontFamily {
            let face = family.xmlEscaped
            children += "<a:latin typeface=\"\(face)\"/><a:cs typeface=\"\(face)\"/>"
        }
        if let link = style.link {
            let id = addRelationship(type: "\(OPC.officeRelationships)/hyperlink", target: link, external: true)
            children += "<a:hlinkClick r:id=\"\(id)\"/>"
        }
        return children.isEmpty ? "<a:rPr\(attributes)/>" : "<a:rPr\(attributes)>\(children)</a:rPr>"
    }

    /// `#RRGGBB` to `RRGGBB`. Nil for anything else, which the schema would reject.
    private static func hex(_ color: String?) -> String? {
        guard let color, color.hasPrefix("#"), color.count == 7 else { return nil }
        let digits = color.dropFirst()
        return digits.allSatisfy(\.isHexDigit) ? digits.uppercased() : nil
    }

    // MARK: Tables

    private mutating func tableXML(_ rows: [PPTXSlide.TableRow], widths: [Double], hasHeaderRow: Bool, y: Double) -> String {
        let id = shapeID()
        let totalHeight = rows.reduce(0) { $0 + $1.height }
        var xml = """
            <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="\(id)" name="Table \(id - 1)"/>\
            <p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>\
            <p:xfrm><a:off x="\(emu(Geometry.marginX))" y="\(emu(y))"/><a:ext cx="\(emu(Geometry.contentWidth))" cy="\(emu(totalHeight))"/></p:xfrm>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>\
            <a:tblPr\(hasHeaderRow ? " firstRow=\"1\"" : "") bandRow="1"><a:tableStyleId>\(PPTXBoilerplate.tableStyleID)</a:tableStyleId></a:tblPr><a:tblGrid>
            """
        for width in widths { xml += "<a:gridCol w=\"\(emu(width))\"/>" }
        xml += "</a:tblGrid>"
        for row in rows {
            xml += "<a:tr h=\"\(emu(row.height))\">"
            for slot in row.slots { xml += cellXML(slot) }
            xml += "</a:tr>"
        }
        return xml + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    private mutating func cellXML(_ slot: PPTXSlide.TableRow.Slot) -> String {
        let empty = "<a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\" sz=\"1400\" dirty=\"0\"/></a:p></a:txBody><a:tcPr/>"
        switch slot {
        case .empty:
            return "<a:tc>\(empty)</a:tc>"
        case .covered(let fromLeft, let fromAbove, let columnSpan):
            var attributes = ""
            if fromAbove && !fromLeft && columnSpan > 1 { attributes += " gridSpan=\"\(columnSpan)\"" }
            if fromLeft { attributes += " hMerge=\"1\"" }
            if fromAbove { attributes += " vMerge=\"1\"" }
            return "<a:tc\(attributes)>\(empty)</a:tc>"
        case .cell(let cell, let columnSpan, let rowSpan):
            var attributes = ""
            if rowSpan > 1 { attributes += " rowSpan=\"\(rowSpan)\"" }
            if columnSpan > 1 { attributes += " gridSpan=\"\(columnSpan)\"" }
            let body = cellParagraphs(cell)
            return "<a:tc\(attributes)><a:txBody><a:bodyPr/><a:lstStyle/>\(body)</a:txBody><a:tcPr/></a:tc>"
        }
    }

    private mutating func cellParagraphs(_ cell: TableCell) -> String {
        var xml = ""
        func collect(_ blocks: [Block], level: Int, into paragraphs: inout [PPTXSlide.Paragraph]) {
            for block in blocks {
                switch block {
                case .paragraph(let content, let alignment), .heading(_, let content, let alignment):
                    paragraphs.append(PPTXSlide.Paragraph(content: content, level: level, alignment: alignment, baseStyle: TextStyle(fontSize: Geometry.tableFontSize)))
                case .list(let ordered, let items):
                    for item in items {
                        var nested: [PPTXSlide.Paragraph] = []
                        collect(item, level: level + 1, into: &nested)
                        if !nested.isEmpty { nested[0].bullet = ordered ? .ordered : .unordered }
                        paragraphs += nested
                    }
                default:
                    let text = block.plainText
                    if !text.isEmpty {
                        paragraphs.append(PPTXSlide.Paragraph(content: [.text(text)], level: level, baseStyle: TextStyle(fontSize: Geometry.tableFontSize)))
                    }
                }
            }
        }
        var paragraphs: [PPTXSlide.Paragraph] = []
        collect(cell.blocks, level: 0, into: &paragraphs)
        for paragraph in paragraphs { xml += paragraphXML(paragraph) }
        return xml.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\" sz=\"1400\" dirty=\"0\"/></a:p>" : xml
    }

    // MARK: Images

    private mutating func pictureXML(_ asset: ImageAsset, _ image: PreparedImage, x: Int, y: Int, width: Int, height: Int) -> String {
        let id = shapeID()
        let target = media.store(image)
        let relationship = addRelationship(type: "\(OPC.officeRelationships)/image", target: target)
        let description = asset.alt.map { " descr=\"\($0.xmlEscaped)\"" } ?? ""
        return """
            <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="Picture \(id - 1)"\(description)/>\
            <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
            """
    }

    /// Fills the slide. An image of another shape is fitted and centred, never cropped, since
    /// it may be a page of a PDF.
    private mutating func fullBleedXML(_ asset: ImageAsset, _ image: PreparedImage) -> String {
        let (naturalWidth, naturalHeight) = ImageSupport.naturalSize(of: asset, image)
        let scale = min(Double(slideSize.width) / naturalWidth, Double(slideSize.height) / naturalHeight)
        let width = Int((naturalWidth * scale).rounded())
        let height = Int((naturalHeight * scale).rounded())
        return pictureXML(
            asset, image,
            x: (slideSize.width - width) / 2,
            y: (slideSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}

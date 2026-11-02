import ConversionCore
import Foundation
import ImageIO

/// Writes real Word documents with named styles, so headings show up in Word's
/// navigation pane and the file can be restyled in one click.
public enum DOCXWriter {
    public static func write(_ document: RichDocument, to url: URL) throws {
        var body = BodyBuilder()
        let xml = body.render(document.blocks)

        let zip = try ZipWriter(url: url)
        try zip.add("[Content_Types].xml", text: contentTypes(images: body.images))
        try zip.add("_rels/.rels", text: rootRelationships)
        try zip.add("docProps/core.xml", text: coreProperties(document))
        try zip.add("word/document.xml", text: documentXML(xml))
        try zip.add("word/styles.xml", text: stylesXML)
        try zip.add("word/numbering.xml", text: numberingXML(listCount: body.listCount))
        try zip.add("word/_rels/document.xml.rels", text: documentRelationships(body))
        for image in body.images {
            try zip.add("word/media/\(image.name)", data: image.asset.data, compressed: false)
        }
        try zip.finish()
    }

    // MARK: - Body

    private struct BodyBuilder {
        struct StoredImage {
            let id: String
            let name: String
            let asset: ImageAsset
        }

        var images: [StoredImage] = []
        var links: [(id: String, target: String)] = []
        var listCount = 0
        private var nextDrawingID = 1

        mutating func render(_ blocks: [Block]) -> String {
            blocks.map { render($0) }.joined()
        }

        private mutating func render(_ block: Block) -> String {
            switch block {
            case .heading(let level, let content, let alignment):
                return paragraph(style: "Heading\(max(1, min(level, 6)))", alignment: alignment, runs: runs(content))
            case .paragraph(let content, let alignment):
                return paragraph(style: nil, alignment: alignment, runs: runs(content))
            case .list(let ordered, let items):
                listCount += 1
                // Odd numbering instances are bullets and even ones are numbers, see numberingXML.
                let numberingID = listCount * 2 - (ordered ? 0 : 1)
                return listXML(items, numberingID: numberingID, level: 0)
            case .table(let table):
                return tableXML(table)
            case .image(let image):
                return paragraph(style: nil, alignment: nil, runs: drawing(image))
            case .code(let code, _):
                return code.components(separatedBy: "\n").map {
                    paragraph(style: "Code", alignment: nil, runs: "<w:r><w:t xml:space=\"preserve\">\($0.xmlEscaped)</w:t></w:r>")
                }.joined()
            case .quote(let blocks):
                return blocks.map { block -> String in
                    if case .paragraph(let content, _) = block {
                        return paragraph(style: "Quote", alignment: nil, runs: runs(content))
                    }
                    return render(block)
                }.joined()
            case .rule:
                return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"C8C8CC\"/></w:pBdr></w:pPr></w:p>"
            case .pageBreak:
                return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        private func paragraph(style: String?, alignment: TextAlignment?, runs: String, extra: String = "") -> String {
            var properties = ""
            if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
            properties += extra
            if let alignment {
                let value = switch alignment {
                case .left: "left"
                case .center: "center"
                case .right: "right"
                case .justified: "both"
                }
                properties += "<w:jc w:val=\"\(value)\"/>"
            }
            let head = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
            return "<w:p>\(head)\(runs)</w:p>"
        }

        private mutating func listXML(_ items: [[Block]], numberingID: Int, level: Int) -> String {
            var xml = ""
            let numbering = "<w:numPr><w:ilvl w:val=\"\(min(level, 8))\"/><w:numId w:val=\"\(numberingID)\"/></w:numPr>"
            for item in items {
                var isFirst = true
                for block in item {
                    switch block {
                    case .paragraph(let content, _) where isFirst:
                        xml += paragraph(style: "ListParagraph", alignment: nil, runs: runs(content), extra: numbering)
                    case .list(let ordered, let nested):
                        listCount += 1
                        let id = listCount * 2 - (ordered ? 0 : 1)
                        xml += listXML(nested, numberingID: id, level: level + 1)
                    default:
                        xml += render(block)
                    }
                    isFirst = false
                }
            }
            return xml
        }

        private mutating func tableXML(_ table: ConversionCore.Table) -> String {
            // A table with many columns gets smaller text, as it does in HTML and PDF.
            let (style, characterWidth) = switch TableFit.density(of: table) {
            case nil: ("TableGrid", 110)
            case "dense": ("TableGridDense", 95)
            default: ("TableGridDenser", 80)
            }
            // The text width of an A4 page with 2.54 cm margins, and an average Calibri character, in twips.
            let widths = TableFit.columnWidths(of: table, total: 9026, characterWidth: characterWidth)
            guard !widths.isEmpty else { return "" }
            func width(from column: Int, span: Int) -> Int {
                widths[min(column, widths.count - 1)..<min(column + span, widths.count)].reduce(0, +)
            }
            var xml = """
                <w:tbl><w:tblPr><w:tblStyle w:val="\(style)"/><w:tblW w:w="5000" w:type="pct"/><w:tblLook w:val="04A0" w:firstRow="1"/></w:tblPr>
                """
            xml += "<w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
            // Word marks a vertical merge with a placeholder cell in every row it spans.
            var openMerges: [Int: (remaining: Int, span: Int)] = [:]
            for (index, row) in table.rows.enumerated() {
                xml += "<w:tr>"
                if index == 0, table.hasHeaderRow { xml += "<w:trPr><w:tblHeader/></w:trPr>" }
                var column = 0
                var cells = row[...]

                func emitOpenMerges(_ xml: inout String) {
                    while let merge = openMerges[column], merge.remaining > 0 {
                        xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width(from: column, span: merge.span))\" w:type=\"dxa\"/>"
                        if merge.span > 1 { xml += "<w:gridSpan w:val=\"\(merge.span)\"/>" }
                        xml += "<w:vMerge/></w:tcPr><w:p/></w:tc>"
                        openMerges[column] = merge.remaining > 1 ? (merge.remaining - 1, merge.span) : nil
                        column += merge.span
                    }
                }

                emitOpenMerges(&xml)
                while let cell = cells.popFirst() {
                    var properties = "<w:tcW w:w=\"\(width(from: column, span: cell.columnSpan))\" w:type=\"dxa\"/>"
                    if cell.columnSpan > 1 { properties += "<w:gridSpan w:val=\"\(cell.columnSpan)\"/>" }
                    if cell.rowSpan > 1 {
                        properties += "<w:vMerge w:val=\"restart\"/>"
                        openMerges[column] = (cell.rowSpan - 1, cell.columnSpan)
                    }
                    if index == 0, table.hasHeaderRow { properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F4\"/>" }
                    var content = cell.blocks.map { render($0) }.joined()
                    if !content.hasSuffix("</w:p>") { content += "<w:p/>" }
                    xml += "<w:tc><w:tcPr>\(properties)</w:tcPr>\(content)</w:tc>"
                    column += cell.columnSpan
                    emitOpenMerges(&xml)
                }
                xml += "</w:tr>"
            }
            return xml + "</w:tbl>"
        }

        private mutating func runs(_ inlines: [Inline]) -> String {
            inlines.map { inline -> String in
                switch inline {
                case .text(let text, let style):
                    return run(text, style)
                case .lineBreak:
                    return "<w:r><w:br/></w:r>"
                case .image(let image):
                    return drawing(image)
                }
            }.joined()
        }

        private mutating func run(_ text: String, _ style: TextStyle) -> String {
            var properties = ""
            if let family = style.fontFamily {
                let safe = family.xmlEscaped
                properties += "<w:rFonts w:ascii=\"\(safe)\" w:hAnsi=\"\(safe)\" w:cs=\"\(safe)\"/>"
            } else if style.code {
                properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>"
            }
            if style.bold { properties += "<w:b/>" }
            if style.italic { properties += "<w:i/>" }
            if style.strikethrough { properties += "<w:strike/>" }
            if let color = style.color { properties += "<w:color w:val=\"\(color.dropFirst())\"/>" }
            else if style.link != nil { properties += "<w:color w:val=\"0563C1\"/>" }
            if let size = style.fontSize { properties += "<w:sz w:val=\"\(Int(size * 2))\"/>" }
            if style.underline || style.link != nil { properties += "<w:u w:val=\"single\"/>" }
            if let highlight = style.highlight {
                properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(highlight.dropFirst())\"/>"
            }
            if style.superscript { properties += "<w:vertAlign w:val=\"superscript\"/>" }
            if style.subscript { properties += "<w:vertAlign w:val=\"subscript\"/>" }
            let head = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"

            // Word stores tabs as elements, not as characters in the text.
            let pieces = text.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\($0.xmlEscaped)</w:t>" }
            let xml = "<w:r>\(head)\(pieces.joined(separator: "<w:tab/>"))</w:r>"

            if let link = style.link {
                let id = "rIdLink\(links.count + 1)"
                links.append((id, link))
                return "<w:hyperlink r:id=\"\(id)\">\(xml)</w:hyperlink>"
            }
            return xml
        }

        private mutating func drawing(_ image: ImageAsset) -> String {
            let id = "rIdImage\(images.count + 1)"
            let name = "image\(images.count + 1).\(image.fileExtension)"
            images.append(StoredImage(id: id, name: name, asset: image))
            let drawingID = nextDrawingID
            nextDrawingID += 1

            // Falls back to the file's own pixel size, scaled to fit an A4 text column of 451 pt.
            var width = image.width ?? 0
            var height = image.height ?? 0
            if width <= 0 || height <= 0, let pixels = ImageMetrics.pixelSize(of: image.data) {
                width = pixels.width * 0.75
                height = pixels.height * 0.75
            }
            if width <= 0 || height <= 0 { (width, height) = (300, 200) }
            if width > 451 { (width, height) = (451, height * 451 / width) }
            let cx = Int(width * 12700)
            let cy = Int(height * 12700)
            let alt = (image.alt ?? "").xmlEscaped
            return """
                <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(drawingID)" name="Image \(drawingID)" descr="\(alt)"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
                """
        }
    }

    // MARK: - Package parts

    private static func documentXML(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1417" w:bottom="1417" w:left="1417" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
    }

    private static func contentTypes(images: [BodyBuilder.StoredImage]) -> String {
        var defaults = Set<String>()
        var entries = ""
        for image in images {
            let ext = image.asset.fileExtension
            if defaults.insert(ext).inserted {
                entries += "<Default Extension=\"\(ext)\" ContentType=\"\(image.asset.mimeType)\"/>"
            }
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\(entries)<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
            """
    }

    private static let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """

    private static func documentRelationships(_ body: BodyBuilder) -> String {
        var entries = """
            <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
            """
        for image in body.images {
            entries += "<Relationship Id=\"\(image.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(image.name)\"/>"
        }
        for link in body.links {
            entries += "<Relationship Id=\"\(link.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(link.target.xmlEscaped)\" TargetMode=\"External\"/>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(entries)</Relationships>
            """
    }

    private static func coreProperties(_ document: RichDocument) -> String {
        let title = document.title.map { "<dc:title>\($0.xmlEscaped)</dc:title>" } ?? ""
        let author = document.author.map { "<dc:creator>\($0.xmlEscaped)</dc:creator>" } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(title)\(author)</cp:coreProperties>
            """
    }

    /// Every list gets its own numbering instance, so a new numbered list starts at 1 again.
    private static func numberingXML(listCount: Int) -> String {
        func levels(ordered: Bool) -> String {
            (0..<9).map { level -> String in
                let indent = 720 * (level + 1)
                let format: String
                let text: String
                if ordered {
                    format = ["decimal", "lowerLetter", "lowerRoman"][level % 3]
                    text = "%\(level + 1)."
                } else {
                    format = "bullet"
                    text = ["\u{2022}", "\u{25E6}", "\u{25AA}"][level % 3]
                }
                return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        var instances = ""
        for index in 1...max(1, listCount) {
            instances += "<w:num w:numId=\"\(index * 2 - 1)\"><w:abstractNumId w:val=\"0\"/></w:num>"
            instances += "<w:num w:numId=\"\(index * 2)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(ordered: false))</w:abstractNum><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(ordered: true))</w:abstractNum>\(instances)</w:numbering>
            """
    }

    private static let stylesXML: String = {
        func heading(_ level: Int, size: Int) -> String {
            """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="\(level - 1)"/></w:pPr><w:rPr><w:b/><w:sz w:val="\(size)"/></w:rPr></w:style>
            """
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Calibri"/><w:sz w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\(heading(1, size: 40))\(heading(2, size: 32))\(heading(3, size: 26))\(heading(4, size: 24))\(heading(5, size: 22))\(heading(6, size: 22))<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="567"/></w:pPr><w:rPr><w:i/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="19"/></w:rPr></w:style><w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style><w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="C8C8CC"/><w:left w:val="single" w:sz="4" w:space="0" w:color="C8C8CC"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="C8C8CC"/><w:right w:val="single" w:sz="4" w:space="0" w:color="C8C8CC"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="C8C8CC"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="C8C8CC"/></w:tblBorders></w:tblPr></w:style><w:style w:type="table" w:styleId="TableGridDense"><w:name w:val="Table Grid Dense"/><w:basedOn w:val="TableGrid"/><w:rPr><w:sz w:val="19"/></w:rPr></w:style><w:style w:type="table" w:styleId="TableGridDenser"><w:name w:val="Table Grid Denser"/><w:basedOn w:val="TableGrid"/><w:rPr><w:sz w:val="16"/></w:rPr></w:style></w:styles>
            """
    }()
}

enum ImageMetrics {
    /// Reads an image's pixel size from its header without decoding it.
    static func pixelSize(of data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Double,
            let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return (width, height)
    }
}

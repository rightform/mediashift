import ConversionCore
import Foundation

/// Reads the slides of a presentation into blocks.
struct PPTXReader {
    let package: ZipPackage

    func read() throws -> RichDocument {
        let invalid = ConversionError("This file is not a valid PPTX file.")
        let fallback = package.contains("ppt/presentation.xml") ? "ppt/presentation.xml" : nil
        guard let path = try OPC.mainPart(ofType: "officeDocument", in: package) ?? fallback,
            let data = try package.data(forPart: path)
        else { throw invalid }
        let presentation = try XMLTree.parse(data)
        guard presentation.localName == "presentation" else { throw invalid }

        let relationships = try OPC.relationships(of: path, in: package)
        var blocks: [Block] = []
        var slideCount = 0
        for slide in presentation.first("sldIdLst")?.all("sldId") ?? [] {
            guard let id = slide.prefixedAttribute("id"),
                let relationship = relationships.first(where: { $0.id == id }),
                let slidePath = OPC.resolve(relationship.target, from: path),
                let slideData = try package.data(forPart: slidePath)
            else { continue }
            if slideCount > 0 { blocks.append(.pageBreak) }
            slideCount += 1
            blocks += try SlideReader(package: package, path: slidePath, root: XMLTree.parse(slideData)).blocks()
        }

        let properties = OPC.coreProperties(in: package)
        return RichDocument(title: properties.title, author: properties.author, blocks: blocks)
    }
}

/// One slide, with the layout and master it inherits bullet settings from.
private final class SlideReader {
    private enum Bullet {
        case none, unordered, ordered
    }

    private struct FlatParagraph {
        var level: Int
        var bullet: Bullet
        var content: [Inline]
        var alignment: TextAlignment?
    }

    private let package: ZipPackage
    private let path: String
    private let root: XMLTree
    private let relationships: [OPC.Relationship]
    private lazy var layoutPart = linkedPart(ofType: "slideLayout", from: path, relationships)
    private lazy var master: XMLTree? = {
        guard let layoutPath = layoutPart?.path, let rels = try? OPC.relationships(of: layoutPath, in: package) else {
            return nil
        }
        return linkedPart(ofType: "slideMaster", from: layoutPath, rels)?.tree
    }()

    init(package: ZipPackage, path: String, root: XMLTree) throws {
        self.package = package
        self.path = path
        self.root = root
        relationships = try OPC.relationships(of: path, in: package)
    }

    private func linkedPart(ofType type: String, from source: String, _ relationships: [OPC.Relationship]) -> (path: String, tree: XMLTree)? {
        guard let relationship = relationships.first(where: { $0.hasType(type) }),
            let path = OPC.resolve(relationship.target, from: source),
            let data = try? package.data(forPart: path),
            let tree = try? XMLTree.parse(data)
        else { return nil }
        return (path, tree)
    }

    /// The title first, then everything else in reading order.
    func blocks() throws -> [Block] {
        var title: Block?
        var body: [Block] = []
        if let tree = root.first(path: "cSld", "spTree") {
            try walk(tree, title: &title, body: &body)
        }
        return (title.map { [$0] } ?? []) + body
    }

    private func walk(_ tree: XMLTree, title: inout Block?, body: inout [Block]) throws {
        for child in tree.children {
            switch child.localName {
            case "sp":
                readShape(child, title: &title, body: &body)
            case "pic":
                if let image = try image(from: child) { body.append(.image(image)) }
            case "graphicFrame":
                for table in child.descendants("tbl") { body.append(.table(self.table(from: table))) }
            case "grpSp":
                try walk(child, title: &title, body: &body)
            case "AlternateContent":
                if let branch = child.first("Fallback") ?? child.first("Choice") {
                    try walk(branch, title: &title, body: &body)
                }
            default:
                break
            }
        }
    }

    // MARK: Text shapes

    private func readShape(_ shape: XMLTree, title: inout Block?, body: inout [Block]) {
        let placeholder = shape.first(path: "nvSpPr", "nvPr", "ph")
        let type = placeholder?.attribute("type")
        if let type, ["dt", "ftr", "sldNum", "hdr"].contains(type) { return }
        guard let textBody = shape.first("txBody") else { return }

        if type == "title" || type == "ctrTitle" {
            let lines = textBody.all("p").map(inlines(of:)).filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            var content: [Inline] = []
            for (index, line) in lines.enumerated() {
                if index > 0 { content.append(.lineBreak) }
                content += line
            }
            if title == nil {
                title = .heading(level: 1, content: content)
            } else {
                body.append(.paragraph(content: content))
            }
            return
        }

        let flat = textBody.all("p").compactMap { paragraph -> FlatParagraph? in
            let content = inlines(of: paragraph)
            guard !content.isEmpty else { return nil }
            let properties = paragraph.first("pPr")
            let level = Self.level(of: properties)
            let bullet = bullet(of: properties, level: level, shape: shape, placeholder: placeholder)
            return FlatParagraph(level: level, bullet: bullet, content: content, alignment: alignment(of: properties))
        }
        body += nest(flat)
    }

    private static func level(of properties: XMLTree?) -> Int {
        max(0, min(8, properties?.attribute("lvl").flatMap(Int.init) ?? 0))
    }

    private func alignment(of properties: XMLTree?) -> TextAlignment? {
        switch properties?.attribute("algn") {
        case "ctr": .center
        case "r": .right
        case "just", "justLow", "dist", "thaiDist": .justified
        default: nil
        }
    }

    private func bullet(of properties: XMLTree?, level: Int, shape: XMLTree, placeholder: XMLTree?) -> Bullet {
        if let properties, let explicit = declaredBullet(in: properties) { return explicit }
        return inheritedBullet(level: level, shape: shape, placeholder: placeholder)
    }

    private func declaredBullet(in properties: XMLTree) -> Bullet? {
        if properties.first("buNone") != nil { return Bullet.none }
        if properties.first("buAutoNum") != nil { return .ordered }
        if properties.first("buChar") != nil || properties.first("buBlip") != nil { return .unordered }
        return nil
    }

    /// Follows the chain of list styles a paragraph inherits from: the shape, the placeholder
    /// on the layout, the one on the master, then the master's body style.
    private func inheritedBullet(level: Int, shape: XMLTree, placeholder: XMLTree?) -> Bullet {
        let levelName = "lvl\(level + 1)pPr"
        if let style = shape.first(path: "txBody", "lstStyle", levelName), let bullet = declaredBullet(in: style) {
            return bullet
        }
        guard let placeholder else { return .none }
        let type = placeholder.attribute("type")
        if type == "subTitle" { return .none }

        for tree in [layoutPart?.tree, master].compactMap({ $0 }) {
            let match = tree.first(path: "cSld", "spTree")?.descendants("sp").first { candidate in
                guard let other = candidate.first(path: "nvSpPr", "nvPr", "ph") else { return false }
                if let index = placeholder.attribute("idx"), other.attribute("idx") == index { return true }
                return type != nil && other.attribute("type") == type
            }
            if let style = match?.first(path: "txBody", "lstStyle", levelName), let bullet = declaredBullet(in: style) {
                return bullet
            }
        }
        if let style = master?.first(path: "txStyles", "bodyStyle", levelName), let bullet = declaredBullet(in: style) {
            return bullet
        }
        return .none
    }

    private func inlines(of paragraph: XMLTree) -> [Inline] {
        var output: [Inline] = []
        func append(_ text: String, _ style: TextStyle) {
            guard !text.isEmpty else { return }
            if case .text(let previous, let previousStyle)? = output.last, previousStyle == style {
                output[output.count - 1] = .text(previous + text, style)
            } else {
                output.append(.text(text, style))
            }
        }
        for child in paragraph.children {
            switch child.localName {
            case "r", "fld":
                append(child.first("t")?.text ?? "", style(of: child.first("rPr")))
            case "br":
                output.append(.lineBreak)
            default:
                break
            }
        }
        return output
    }

    private func style(of properties: XMLTree?) -> TextStyle {
        var style = TextStyle()
        guard let properties else { return style }
        style.bold = properties.flag("b") ?? false
        style.italic = properties.flag("i") ?? false
        if let underline = properties.attribute("u"), underline != "none" { style.underline = true }
        if let strike = properties.attribute("strike"), strike != "noStrike" { style.strikethrough = true }
        if let baseline = properties.attribute("baseline").flatMap(Int.init) {
            style.superscript = baseline > 0
            style.subscript = baseline < 0
        }
        style.fontSize = properties.attribute("sz").flatMap(Double.init).map { $0 / 100 }
        style.color = hexColor(properties.first(path: "solidFill", "srgbClr"))
        style.highlight = hexColor(properties.first(path: "highlight", "srgbClr"))
        if let face = properties.first("latin")?.attribute("typeface"), !face.hasPrefix("+"), !face.isEmpty {
            style.fontFamily = face
        }
        if let id = properties.first("hlinkClick")?.prefixedAttribute("id"),
            let target = relationships.first(where: { $0.id == id && $0.isExternal })?.target
        {
            style.link = target
        }
        return style
    }

    private func hexColor(_ node: XMLTree?) -> String? {
        guard let value = node?.attribute("val"), value.count == 6 else { return nil }
        return "#" + value.uppercased()
    }

    /// Turns flat paragraphs with levels into paragraphs and nested lists.
    private func nest(_ flat: [FlatParagraph]) -> [Block] {
        var blocks: [Block] = []
        var index = 0
        while index < flat.count {
            if flat[index].bullet == .none {
                blocks.append(.paragraph(content: flat[index].content, alignment: flat[index].alignment))
                index += 1
            } else {
                var end = index
                while end < flat.count, flat[end].bullet != .none { end += 1 }
                let items = flat[index..<end].map { paragraph in
                    ListBuilder.Item(
                        level: paragraph.level,
                        ordered: paragraph.bullet == .ordered,
                        content: .paragraph(content: paragraph.content, alignment: paragraph.alignment)
                    )
                }
                blocks += ListBuilder.lists(from: items[...])
                index = end
            }
        }
        return blocks
    }

    // MARK: Tables and images

    private func table(from node: XMLTree) -> Table {
        let rowNodes = node.all("tr")
        let columnCount = max(1, node.first("tblGrid")?.all("gridCol").count ?? 1)
        let rows = rowNodes.map { row -> [TableCell] in
            row.all("tc").compactMap { cell -> TableCell? in
                if cell.flag("hMerge") == true || cell.flag("vMerge") == true { return nil }
                let flat = cell.first("txBody")?.all("p").compactMap { paragraph -> FlatParagraph? in
                    let content = inlines(of: paragraph)
                    guard !content.isEmpty else { return nil }
                    let properties = paragraph.first("pPr")
                    return FlatParagraph(
                        level: Self.level(of: properties),
                        bullet: properties.flatMap(declaredBullet(in:)) ?? .none,
                        content: content,
                        alignment: alignment(of: properties)
                    )
                }
                return TableCell(
                    blocks: nest(flat ?? []),
                    columnSpan: max(1, min(cell.attribute("gridSpan").flatMap(Int.init) ?? 1, columnCount)),
                    rowSpan: max(1, min(cell.attribute("rowSpan").flatMap(Int.init) ?? 1, rowNodes.count))
                )
            }
        }
        return Table(rows: rows, hasHeaderRow: node.first("tblPr")?.flag("firstRow") ?? false)
    }

    private func image(from picture: XMLTree) throws -> ImageAsset? {
        guard let id = picture.first(path: "blipFill", "blip")?.prefixedAttribute("embed"),
            let relationship = relationships.first(where: { $0.id == id && !$0.isExternal }),
            let target = OPC.resolve(relationship.target, from: path),
            let data = try package.data(forPart: target)
        else { return nil }
        let extent = picture.first(path: "spPr", "xfrm", "ext")
        func points(_ name: String) -> Double? {
            extent?.attribute(name).flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 / 12700 : nil }
        }
        let description = picture.first(path: "nvPicPr", "cNvPr")?.attribute("descr")
        return ImageAsset(
            data: data,
            mimeType: ImageSupport.mimeType(forPath: target),
            alt: description?.isEmpty == false ? description : nil,
            width: points("cx"),
            height: points("cy")
        )
    }
}

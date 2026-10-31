import ConversionCore
import Foundation

/// Builds the parts of a workbook.
struct XLSXWriter {
    private static let maxRows = 1_048_576
    private static let maxColumns = 16_384
    private static let maxCellLength = 32_767

    private let document: RichDocument

    init(_ document: RichDocument) {
        self.document = document
    }

    func parts() throws -> [ZipWriter.Part] {
        let plans = sheetPlans()
        let strings = SharedStrings()
        let styles = StyleRegistry()
        let names = Self.uniqueSheetNames(plans.map(\.name))

        var sheetParts: [ZipWriter.Part] = []
        for (index, plan) in plans.enumerated() {
            let xml = try sheetXML(plan, strings: strings, styles: styles)
            sheetParts.append(ZipWriter.Part("xl/worksheets/sheet\(index + 1).xml", xml))
        }

        let sheetCount = plans.count
        var parts: [ZipWriter.Part] = [
            ZipWriter.Part("[Content_Types].xml", contentTypes(sheetCount: sheetCount)),
            ZipWriter.Part("_rels/.rels", packageRelationships),
            ZipWriter.Part("docProps/core.xml", OPC.corePropertiesXML(title: document.title, author: document.author)),
            ZipWriter.Part("xl/workbook.xml", workbookXML(names: names)),
            ZipWriter.Part("xl/_rels/workbook.xml.rels", workbookRelationships(sheetCount: sheetCount)),
            ZipWriter.Part("xl/styles.xml", styles.xml()),
            ZipWriter.Part("xl/sharedStrings.xml", strings.xml()),
        ]
        parts += sheetParts
        return parts
    }

    // MARK: What goes on which sheet

    private struct SheetPlan {
        var name: String?
        var layout: TableLayout
        var hasHeaderRow: Bool
        var isText = false
        /// Rows of the text sheet that came from headings.
        var boldRows: Set<Int> = []
    }

    /// One plan per table, then the text blocks together. A workbook needs at least one sheet.
    private func sheetPlans() -> [SheetPlan] {
        var plans: [SheetPlan] = []
        var textRows: [[TableCell]] = []
        var boldRows: Set<Int> = []

        func collectText(_ block: Block) {
            switch block {
            case .table(let table):
                plans.append(SheetPlan(name: table.name, layout: TableLayout(table), hasHeaderRow: table.hasHeaderRow))
            case .heading(_, let content, _):
                let text = content.plainText
                if !text.isEmpty {
                    boldRows.insert(textRows.count)
                    textRows.append([TableCell(text: text)])
                }
            case .list(_, let items):
                items.forEach { $0.forEach(collectText) }
            case .quote(let blocks):
                blocks.forEach(collectText)
            case .code(let code, _):
                code.components(separatedBy: .newlines).forEach { textRows.append([TableCell(text: $0)]) }
            case .paragraph, .image:
                let text = block.plainText
                if !text.isEmpty { textRows.append([TableCell(text: text)]) }
            case .rule, .pageBreak:
                break
            }
        }
        document.blocks.forEach(collectText)

        if !textRows.isEmpty {
            var plan = SheetPlan(name: "Text", layout: TableLayout(Table(rows: textRows)), hasHeaderRow: false)
            plan.isText = true
            plan.boldRows = boldRows
            plans.append(plan)
        }
        if plans.isEmpty {
            plans.append(SheetPlan(name: nil, layout: TableLayout(Table(rows: [])), hasHeaderRow: false))
        }
        return plans
    }

    /// Excel's rules: at most 31 characters, none of `\ / ? * [ ] :`, no apostrophe at either
    /// end, unique ignoring case, and never "History".
    static func uniqueSheetNames(_ names: [String?]) -> [String] {
        var used: Set<String> = ["history"]
        return names.enumerated().map { index, raw in
            let forbidden = CharacterSet(charactersIn: "\\/?*[]:")
            var base = (raw ?? "").components(separatedBy: forbidden).joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: "'").union(.whitespacesAndNewlines))
            base = base.filter { !$0.isNewline }
            if base.isEmpty { base = "Sheet\(index + 1)" }
            base = truncated(base, utf16Length: 31)
            var candidate = base
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(counter))"
                candidate = truncated(base, utf16Length: 31 - suffix.utf16.count) + suffix
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    static func truncated(_ text: String, utf16Length: Int) -> String {
        guard text.utf16.count > utf16Length else { return text }
        var result = ""
        var length = 0
        for character in text {
            length += character.utf16.count
            guard length <= utf16Length else { break }
            result.append(character)
        }
        return result
    }

    // MARK: Sheets

    private func sheetXML(_ plan: SheetPlan, strings: SharedStrings, styles: StyleRegistry) throws -> String {
        let layout = plan.layout
        guard layout.rows.count <= Self.maxRows, layout.columnCount <= Self.maxColumns else {
            throw ConversionError("This table is too large for an XLSX sheet.")
        }

        var rows = ""
        var merges: [String] = []
        var widths = Array(repeating: 0, count: layout.columnCount)

        for (rowIndex, row) in layout.rows.enumerated() {
            guard !row.isEmpty else { continue }
            let rowNumber = rowIndex + 1
            let isBoldRow = (plan.hasHeaderRow && rowIndex == 0) || plan.boldRows.contains(rowIndex)
            rows += "<row r=\"\(rowNumber)\">"
            for placed in row {
                let reference = XLSXSheetParser.columnName(placed.column) + String(rowNumber)
                let text = placed.cell.plainText
                if placed.columnSpan == 1 {
                    widths[placed.column] = max(widths[placed.column], Self.displayWidth(of: text))
                }
                if placed.columnSpan > 1 || placed.rowSpan > 1 {
                    let end = XLSXSheetParser.columnName(placed.column + placed.columnSpan - 1) + String(rowIndex + placed.rowSpan)
                    merges.append("<mergeCell ref=\"\(reference):\(end)\"/>")
                }
                guard !text.isEmpty else { continue }
                rows += cellXML(text, reference: reference, bold: isBoldRow, wrap: plan.isText, strings: strings, styles: styles)
            }
            rows += "</row>"
        }

        var xml = OPC.xmlHeader
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if plan.hasHeaderRow && layout.rows.count > 1 {
            xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            xml += "<selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/></sheetView></sheetViews>"
        }
        xml += "<sheetFormatPr defaultRowHeight=\"15\"/>"
        if !widths.isEmpty {
            xml += "<cols>"
            for (index, width) in widths.enumerated() {
                let columnWidth = plan.isText ? 100 : min(60, max(8, width + 2))
                xml += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(columnWidth)\" customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }
        xml += "<sheetData>" + rows + "</sheetData>"
        if !merges.isEmpty {
            xml += "<mergeCells count=\"\(merges.count)\">" + merges.joined() + "</mergeCells>"
        }
        return xml + "</worksheet>"
    }

    private func cellXML(
        _ text: String,
        reference: String,
        bold: Bool,
        wrap: Bool,
        strings: SharedStrings,
        styles: StyleRegistry
    ) -> String {
        switch XLSXCellValue(text: text) {
        case .number(let raw, let formatCode):
            let style = styles.index(bold: bold, wrap: false, formatCode: formatCode)
            return "<c r=\"\(reference)\"\(style == 0 ? "" : " s=\"\(style)\"")><v>\(raw)</v></c>"
        case .text:
            let shown = Self.truncated(text, utf16Length: Self.maxCellLength)
            let style = styles.index(bold: bold, wrap: wrap || shown.contains(where: \.isNewline), formatCode: nil)
            return "<c r=\"\(reference)\"\(style == 0 ? "" : " s=\"\(style)\"") t=\"s\"><v>\(strings.index(of: shown))</v></c>"
        }
    }

    private static func displayWidth(of text: String) -> Int {
        text.split(whereSeparator: \.isNewline).map(\.count).max() ?? 0
    }

    // MARK: Workbook boilerplate

    private func workbookXML(names: [String]) -> String {
        var xml = OPC.xmlHeader
        xml += "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(OPC.officeRelationships)\">"
        xml += "<bookViews><workbookView/></bookViews><sheets>"
        for (index, name) in names.enumerated() {
            xml += "<sheet name=\"\(name.xmlEscaped)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }
        return xml + "</sheets></workbook>"
    }

    private func workbookRelationships(sheetCount: Int) -> String {
        var items: [(id: String, type: String, target: String, external: Bool)] = (1...sheetCount).map {
            ("rId\($0)", "\(OPC.officeRelationships)/worksheet", "worksheets/sheet\($0).xml", false)
        }
        items.append(("rId\(sheetCount + 1)", "\(OPC.officeRelationships)/styles", "styles.xml", false))
        items.append(("rId\(sheetCount + 2)", "\(OPC.officeRelationships)/sharedStrings", "sharedStrings.xml", false))
        return OPC.relationshipsXML(items)
    }

    private func contentTypes(sheetCount: Int) -> String {
        var xml = OPC.xmlHeader
        xml += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        xml += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        xml += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        xml += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for index in 1...sheetCount {
            xml += "<Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        xml += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        xml += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        xml += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        return xml + "</Types>"
    }

    private var packageRelationships: String {
        OPC.relationshipsXML([
            ("rId1", "\(OPC.officeRelationships)/officeDocument", "xl/workbook.xml", false),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml", false),
        ])
    }
}

private final class SharedStrings {
    private var indexes: [String: Int] = [:]
    private var ordered: [String] = []
    private var useCount = 0

    func index(of text: String) -> Int {
        useCount += 1
        if let index = indexes[text] { return index }
        let index = ordered.count
        indexes[text] = index
        ordered.append(text)
        return index
    }

    func xml() -> String {
        var xml = OPC.xmlHeader
        xml += "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(useCount)\" uniqueCount=\"\(ordered.count)\">"
        for text in ordered {
            let needsPreserve = text != text.trimmingCharacters(in: .whitespacesAndNewlines) || text.contains(where: \.isNewline)
            xml += needsPreserve ? "<si><t xml:space=\"preserve\">" : "<si><t>"
            xml += text.xmlEscaped + "</t></si>"
        }
        return xml + "</sst>"
    }
}

private final class StyleRegistry {
    private struct Key: Hashable {
        var bold: Bool
        var wrap: Bool
        var formatCode: String?
    }

    private static let builtInFormats = ["0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10]
    private var keys: [Key] = [Key(bold: false, wrap: false, formatCode: nil)]

    func index(bold: Bool, wrap: Bool, formatCode: String?) -> Int {
        let key = Key(bold: bold, wrap: wrap, formatCode: formatCode)
        if let index = keys.firstIndex(of: key) { return index }
        keys.append(key)
        return keys.count - 1
    }

    func xml() -> String {
        var customFormats: [String: Int] = [:]
        for key in keys {
            guard let code = key.formatCode, Self.builtInFormats[code] == nil, customFormats[code] == nil else { continue }
            customFormats[code] = 164 + customFormats.count
        }

        var xml = OPC.xmlHeader
        xml += "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if !customFormats.isEmpty {
            xml += "<numFmts count=\"\(customFormats.count)\">"
            for (code, id) in customFormats.sorted(by: { $0.value < $1.value }) {
                xml += "<numFmt numFmtId=\"\(id)\" formatCode=\"\(code.xmlEscaped)\"/>"
            }
            xml += "</numFmts>"
        }
        xml += "<fonts count=\"2\">"
        xml += "<font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        xml += "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        xml += "</fonts>"
        xml += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
        xml += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        xml += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        xml += "<cellXfs count=\"\(keys.count)\">"
        for key in keys {
            let formatID = key.formatCode.map { Self.builtInFormats[$0] ?? customFormats[$0] ?? 0 } ?? 0
            xml += "<xf numFmtId=\"\(formatID)\" fontId=\"\(key.bold ? 1 : 0)\" fillId=\"0\" borderId=\"0\" xfId=\"0\""
            if formatID != 0 { xml += " applyNumberFormat=\"1\"" }
            if key.bold { xml += " applyFont=\"1\"" }
            if key.wrap {
                xml += " applyAlignment=\"1\"><alignment wrapText=\"1\" vertical=\"top\"/></xf>"
            } else {
                xml += "/>"
            }
        }
        xml += "</cellXfs>"
        xml += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        return xml + "</styleSheet>"
    }
}

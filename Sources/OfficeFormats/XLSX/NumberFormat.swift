import Foundation

/// Turns a cell's stored number into the text Excel shows for it, from a format code such as
/// `#,##0.00;[Red](#,##0.00)` or `dd.mm.yyyy`. Output uses `.` and `,` as the en-US separators;
/// month and day names are English.
struct NumberFormat {
    private let sections: [NumberFormatSection]

    init(code: String) {
        let parsed = Self.splitSections(code).map(NumberFormatSection.init(code:))
        sections = parsed.isEmpty ? [NumberFormatSection(code: "General")] : parsed
    }

    static let general = NumberFormat(code: "General")

    /// True when the format shows the number as a date or time.
    var isDate: Bool {
        sections.first?.kind == .date
    }

    func string(for value: Double, date1904: Bool = false) -> String {
        let (section, usesOwnSign) = section(for: value)
        return section.render(value, usesOwnSign: usesOwnSign, date1904: date1904)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Text cells only change under a format with an `@` placeholder.
    func string(forText text: String) -> String {
        sections.last?.renderText(text) ?? text
    }

    private func section(for value: Double) -> (NumberFormatSection, usesOwnSign: Bool) {
        // Sections with explicit conditions go first come, first served.
        if sections.contains(where: { $0.condition != nil }) {
            for section in sections.dropLast() where section.condition?.matches(value) == true {
                return (section, false)
            }
            return (sections[sections.count - 1], false)
        }
        // A section holding text alone never applies to numbers.
        let numeric = sections.filter { $0.kind != .textOnly }
        switch numeric.count {
        case 0: return (NumberFormatSection(code: "General"), false)
        case 1: return (numeric[0], false)
        case 2: return value >= 0 ? (numeric[0], false) : (numeric[1], true)
        default:
            if value > 0 { return (numeric[0], false) }
            return value < 0 ? (numeric[1], true) : (numeric[2], false)
        }
    }

    // MARK: Plain numbers

    /// Excel's General format, keeping all 15 significant digits a cell can hold.
    static func generalString(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-9 {
            return scientificString(value)
        }
        return plainDecimal(value)?.description ?? "\(value)"
    }

    private static func scientificString(_ value: Double) -> String {
        let text = String(format: "%.14E", value)
        guard let split = text.firstIndex(of: "E") else { return text }
        var mantissa = String(text[..<split])
        while mantissa.hasSuffix("0") { mantissa.removeLast() }
        if mantissa.hasSuffix(".") { mantissa.removeLast() }
        let exponent = Int(text[text.index(after: split)...]) ?? 0
        return mantissa + "E" + (exponent < 0 ? "-" : "+") + String(format: "%02d", abs(exponent))
    }

    /// The value at the 15 significant digits Excel works with, free of binary noise such as
    /// 0.30000000000000004.
    static func plainDecimal(_ value: Double) -> Decimal? {
        Decimal(string: String(format: "%.15g", value))
    }

    // MARK: Parsing

    private static func splitSections(_ code: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in code {
            if escaped {
                escaped = false
            } else if character == "\\" && !inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes && character == "[" {
                inBrackets = true
            } else if !inQuotes && character == "]" {
                inBrackets = false
            } else if !inQuotes && !inBrackets && character == ";" {
                sections.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        sections.append(current)
        return sections
    }

    // MARK: Built-in formats

    /// The codes behind the ids Excel reserves. Those Excel adapts to the system locale become
    /// unambiguous ISO dates here.
    static func builtInCode(id: Int) -> String? {
        switch id {
        case 0: "General"
        case 1: "0"
        case 2: "0.00"
        case 3: "#,##0"
        case 4: "#,##0.00"
        case 5: "\"$\"#,##0_);(\"$\"#,##0)"
        case 6: "\"$\"#,##0_);[Red](\"$\"#,##0)"
        case 7: "\"$\"#,##0.00_);(\"$\"#,##0.00)"
        case 8: "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)"
        case 9: "0%"
        case 10: "0.00%"
        case 11: "0.00E+00"
        case 12: "# ?/?"
        case 13: "# ??/??"
        case 14, 27...31, 34...36, 50...58: "yyyy-mm-dd"
        case 15: "d-mmm-yy"
        case 16: "d-mmm"
        case 17: "mmm-yy"
        case 18: "h:mm AM/PM"
        case 19: "h:mm:ss AM/PM"
        case 20, 32: "h:mm"
        case 21, 33: "h:mm:ss"
        case 22: "yyyy-mm-dd hh:mm"
        case 37: "#,##0_);(#,##0)"
        case 38: "#,##0_);[Red](#,##0)"
        case 39: "#,##0.00_);(#,##0.00)"
        case 40: "#,##0.00_);[Red](#,##0.00)"
        case 41: "_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)"
        case 42: "_(\"$\"* #,##0_);_(\"$\"* (#,##0);_(\"$\"* \"-\"_);_(@_)"
        case 43: "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)"
        case 44: "_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)"
        case 45: "mm:ss"
        case 46: "[h]:mm:ss"
        case 47: "mm:ss.0"
        case 48: "##0.0E+0"
        case 49: "@"
        default: nil
        }
    }
}

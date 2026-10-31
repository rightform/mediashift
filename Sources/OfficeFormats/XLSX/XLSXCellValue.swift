import Foundation

/// How a text becomes a cell. A number is only written when the reader, or Excel, would show
/// it again exactly as it was: `007`, `+48 500` and 20 digit ids stay text.
enum XLSXCellValue: Equatable {
    case number(raw: String, formatCode: String?)
    case text

    init(text: String) {
        self = Self.isoDate(text) ?? Self.number(text) ?? .text
    }

    private static func number(_ text: String) -> XLSXCellValue? {
        var body = Substring(text)
        var percent = false
        if body.hasSuffix("%") {
            percent = true
            body.removeLast()
        }
        let isGrouped = body.contains(",")
        let plain = body.replacingOccurrences(of: ",", with: "")
        guard isPlainDecimal(plain), let digits = significantDigits(plain), digits <= 15 else { return nil }

        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        let decimals = parts.count > 1 ? parts[1].count : 0
        var code = isGrouped ? "#,##0" : "0"
        if decimals > 0 { code += "." + String(repeating: "0", count: decimals) }
        if percent { code += "%" }

        guard let parsed = Double(plain) else { return nil }
        let value = percent ? parsed / 100 : parsed
        // General shows a plain number as is, so it needs no format of its own.
        let trailingZero = decimals > 0 && plain.hasSuffix("0")
        let usesGeneral = !percent && !isGrouped && !trailingZero
        let formatCode = usesGeneral ? nil : code
        let format = formatCode.map { NumberFormat(code: $0) } ?? .general
        guard format.string(for: value) == text else { return nil }
        let raw = percent ? NumberFormat.generalString(value) : plain
        return .number(raw: raw, formatCode: formatCode)
    }

    private static func isPlainDecimal(_ text: String) -> Bool {
        var bytes = Substring(text).utf8
        if bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        guard let first = bytes.first, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return false }
        var seenPoint = false
        var digitsBeforePoint = 0
        var last = first
        for byte in bytes {
            if byte == UInt8(ascii: ".") {
                guard !seenPoint else { return false }
                seenPoint = true
            } else if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                if !seenPoint { digitsBeforePoint += 1 }
            } else {
                return false
            }
            last = byte
        }
        // No leading zeros, no bare trailing point.
        if first == UInt8(ascii: "0") && digitsBeforePoint > 1 { return false }
        return last != UInt8(ascii: ".")
    }

    private static func significantDigits(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? 1 : trimmed.count
    }

    /// `2024-03-15`, optionally with `HH:mm` or `HH:mm:ss`, becomes a real date cell.
    private static func isoDate(_ text: String) -> XLSXCellValue? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10 || bytes.count == 16 || bytes.count == 19 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes[4] == 45, bytes[7] == 45,
            let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            (1900...9999).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var fraction = 0.0
        var code = "yyyy-mm-dd"
        if bytes.count > 10 {
            guard bytes[10] == 32 || bytes[10] == 84, bytes[13] == 58,
                let hour = number(11..<13), let minute = number(14..<16), hour < 24, minute < 60
            else { return nil }
            var second = 0
            code += bytes[10] == 32 ? " hh:mm" : "\"T\"hh:mm"
            if bytes.count == 19 {
                guard bytes[16] == 58, let parsed = number(17..<19), parsed < 60 else { return nil }
                second = parsed
                code += ":ss"
            }
            fraction = Double(hour * 3600 + minute * 60 + second) / 86400
        }

        let serial = NumberFormat.serial(year: year, month: month, day: day)
        // Dates before March 1900 sit on the wrong side of Excel's phantom leap day.
        guard serial >= 61 else { return nil }
        let value = Double(serial) + fraction
        guard NumberFormat(code: code).string(for: value) == text else { return nil }
        return .number(raw: String(format: "%.10f", value).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression), formatCode: code)
    }
}

import ConversionCore
import Foundation

/// Comma, semicolon or tab separated text.
public enum CSVFormat {
    /// Auto-detects delimiter (, ; tab) and encoding (UTF-8 with or without BOM, else Windows-1250, then Latin-1) when delimiter is nil. RFC 4180 quoting.
    public static func read(_ url: URL, delimiter: Character? = nil) throws -> RichDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConversionError("The file could not be read.")
        }
        let text = try decode(data)
        let separator = delimiter ?? detectDelimiter(in: text)
        var records = parse(text, delimiter: separator)
        while let last = records.last, last.allSatisfy(\.isEmpty) { records.removeLast() }
        guard !records.isEmpty else { return RichDocument() }

        let width = records.map(\.count).max() ?? 0
        let rows = records.map { record in
            (record + Array(repeating: "", count: width - record.count)).map(TableCell.init(text:))
        }
        return RichDocument(blocks: [.table(Table(rows: rows, hasHeaderRow: looksLikeHeader(records)))])
    }

    /// All tables, separated by an empty line. With no tables: one row per text block.
    ///
    /// The file is UTF-8 with a BOM, which is what Excel needs to show diacritics correctly.
    public static func write(_ document: RichDocument, to url: URL, delimiter: Character = ",") throws {
        let tables = document.blocks.compactMap { block -> Table? in
            if case .table(let table) = block { return table }
            return nil
        }

        var sections: [[[String]]]
        if tables.isEmpty {
            sections = [document.blocks.compactMap { block in
                let text = block.plainText
                return text.isEmpty ? nil : [text]
            }]
        } else {
            sections = tables.map { TableLayout($0).textRows() }
        }
        sections.removeAll(where: \.isEmpty)

        let lines = sections.map { rows in
            rows.map { fields in
                fields.map { quote($0, delimiter: delimiter) }.joined(separator: String(delimiter))
            }.joined(separator: "\r\n")
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\r\n\r\n") + "\r\n"
        do {
            try (Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)).write(to: url, options: .atomic)
        } catch {
            throw ConversionError("The file could not be saved.")
        }
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else {
                throw ConversionError("This file could not be read as text.")
            }
            return text
        }
        guard !data.contains(0) else {
            throw ConversionError("This file could not be read as text.")
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if let text = String(data: bytes, encoding: .windowsCP1250) { return text }
        if let text = String(data: bytes, encoding: .isoLatin1) { return text }
        throw ConversionError("This file could not be read as text.")
    }

    // MARK: Parsing

    /// Picks the delimiter that splits the first records most evenly. On a tie, the rarer one
    /// in ordinary data wins: a comma may be a decimal separator, a tab almost never is data.
    static func detectDelimiter(in text: String) -> Character {
        let sample = String(text.prefix(64 * 1024))
        var best: (delimiter: Character, score: Double) = (",", 0)
        for candidate: Character in ["\t", ";", ","] {
            var records = parse(sample, delimiter: candidate)
            // The sample may end in the middle of a record.
            if text.utf8.count > sample.utf8.count, records.count > 1 { records.removeLast() }
            records.removeAll { $0.count == 1 && $0[0].isEmpty }
            guard !records.isEmpty else { continue }

            var frequency: [Int: Int] = [:]
            for record in records { frequency[record.count, default: 0] += 1 }
            guard let mode = frequency.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }), mode.key > 1 else { continue }
            let score = Double(mode.value) / Double(records.count)
            if score > best.score { best = (candidate, score) }
        }
        return best.delimiter
    }

    /// RFC 4180. Tolerates bare LF or CR line ends and an unterminated final quote.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        let separator = delimiter.unicodeScalars.first ?? ","
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending = iterator.next()

        func finishField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
        }
        func finishRecord() {
            finishField()
            records.append(record)
            record = []
        }

        while let scalar = pending {
            pending = iterator.next()
            if inQuotes {
                if scalar == "\"" {
                    if pending == "\"" {
                        field.append(scalar)
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else if scalar == "\"" && field.isEmpty {
                inQuotes = true
            } else if scalar == separator {
                finishField()
            } else if scalar == "\r" {
                if pending == "\n" { pending = iterator.next() }
                finishRecord()
            } else if scalar == "\n" {
                finishRecord()
            } else {
                field.append(scalar)
            }
        }
        if !field.isEmpty || !record.isEmpty { finishRecord() }
        return records
    }

    /// A first row of nothing but non-empty, non-numeric text above other rows is taken for a header.
    private static func looksLikeHeader(_ records: [[String]]) -> Bool {
        guard records.count > 1, let first = records.first else { return false }
        return first.allSatisfy { !$0.isEmpty && Double($0.trimmingCharacters(in: .whitespaces)) == nil }
    }

    // MARK: Writing

    static func quote(_ field: String, delimiter: Character) -> String {
        let needsQuotes = field.contains { $0 == delimiter || $0 == "\"" || $0.isNewline }
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

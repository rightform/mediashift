import ConversionCore
import Foundation

/// Paragraph, character and list styles. Each is a `TSS.StyleArchive` in field 1 (name 1,
/// identifier 2, parent 3, is variation 4), with its properties in further fields. Identifiers
/// do not depend on the document language, names do, so identifiers are asked first.
struct PagesStyles {
    enum ListKind {
        case ordered, unordered
    }

    private let store: IWAObjectStore

    init(store: IWAObjectStore) {
        self.store = store
    }

    private func chain(from style: UInt64?) -> [ProtoMessage] {
        var result: [ProtoMessage] = []
        var current = style
        var visited: Set<UInt64> = []
        while let identifier = current, visited.insert(identifier).inserted, result.count < 32,
            let message = store.parsed(identifier)
        {
            result.append(message)
            current = message.message(1)?.reference(3)
        }
        return result
    }

    func headingLevel(ofParagraphStyle style: UInt64?) -> Int? {
        for message in chain(from: style) {
            guard let base = message.message(1) else { continue }
            if let identifier = base.string(2), let range = identifier.range(of: "paragraphstyle-") {
                let suffix = String(identifier[range.upperBound...])
                return Self.headingLevel(fromName: suffix)
            }
            if let name = base.string(1), let level = Self.headingLevel(fromName: name) {
                return level
            }
        }
        return nil
    }

    static func headingLevel(fromName name: String) -> Int? {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered == "title" || lowered.hasPrefix("title ") { return 1 }
        if lowered == "subtitle" { return 2 }
        guard lowered.hasPrefix("heading") else { return nil }
        let rest = lowered.dropFirst("heading".count).trimmingCharacters(in: .whitespaces)
        if let level = Int(rest) { return max(1, min(6, level)) }
        return 1
    }

    func alignment(ofParagraphStyle style: UInt64?) -> TextAlignment? {
        for message in chain(from: style) {
            guard let value = message.message(12)?.varint(1) else { continue }
            // These follow CoreText's alignments.
            switch value {
            case 1: return .right
            case 2: return .center
            case 3: return .justified
            default: return nil
            }
        }
        return nil
    }

    /// What a paragraph's variation changes on top of its named style, such as a line made bold
    /// with Command-B. The named style's own look is not content.
    func variationStyle(ofParagraphStyle style: UInt64?) -> TextStyle {
        var result = TextStyle()
        var applied: Set<Int> = []
        for message in chain(from: style) {
            guard message.message(1)?.varint(4) == 1 else { break }
            Self.apply(message.message(11), to: &result, applied: &applied)
        }
        return result
    }

    func merged(characterStyle: UInt64?, over base: TextStyle) -> TextStyle {
        guard characterStyle != nil else { return base }
        var result = base
        var applied: Set<Int> = []
        for message in chain(from: characterStyle) {
            Self.apply(message.message(11), to: &result, applied: &applied)
        }
        return result
    }

    /// Applies character properties, skipping any that a more specific style already decided.
    /// Field numbers: bold 1, italic 2, size 3, font 5, colour 7, underline 11, strikethrough 12.
    private static func apply(_ properties: ProtoMessage?, to style: inout TextStyle, applied: inout Set<Int>) {
        guard let properties else { return }
        func decide(_ number: Int, _ action: () -> Void) {
            guard !applied.contains(number), properties.fields.contains(where: { $0.number == number }) else { return }
            applied.insert(number)
            action()
        }
        decide(1) { style.bold = properties.varint(1) == 1 }
        decide(2) { style.italic = properties.varint(2) == 1 }
        decide(3) { style.fontSize = properties.float(3).map(Double.init) }
        decide(5) { style.fontFamily = properties.string(5) }
        decide(7) { style.color = properties.message(7).flatMap(hexColor) }
        decide(11) { style.underline = (properties.varint(11) ?? 0) != 0 }
        decide(12) { style.strikethrough = (properties.varint(12) ?? 0) != 0 }
    }

    /// A `TSP.Color`, whose red, green and blue live in fields 3 to 5.
    private static func hexColor(_ color: ProtoMessage) -> String? {
        guard let red = color.float(3), let green = color.float(4), let blue = color.float(5) else { return nil }
        func byte(_ value: Float) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Field 11 of a list style holds one label type per level: 0 none, 1 image, 2 text, 3 number.
    func listKind(style: UInt64?, level: Int) -> ListKind? {
        guard let style, let message = store.parsed(style), store.object(style)?.type == IWAType.listStyle else { return nil }
        let labels = message.varints(11)
        guard let label = labels.indices.contains(level) ? labels[level] : labels.first else { return nil }
        switch label {
        case 1, 2: return .unordered
        case 3: return .ordered
        default: return nil
        }
    }
}

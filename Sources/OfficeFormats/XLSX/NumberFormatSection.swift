import Foundation

enum Token {
    case literal(String)
    case general
    case digit(Character)
    case decimalPoint
    case grouping
    case percent
    case exponent(showsPlus: Bool)
    case slash
    case text
    case date(DatePart, count: Int)
    case ampm(am: String, pm: String)
    case elapsed(DatePart, count: Int)
    case fractionOfSecond(digits: Int)
}

enum DatePart {
    case year, month, day, hour, minute, second
}

struct Condition {
    var comparison: String
    var limit: Double

    func matches(_ value: Double) -> Bool {
        switch comparison {
        case ">": value > limit
        case ">=": value >= limit
        case "<": value < limit
        case "<=": value <= limit
        case "<>": value != limit
        default: value == limit
        }
    }
}

/// One `;` separated part of a format code, tokenized once and rendered per value.
struct NumberFormatSection {
    enum Kind {
        case number, fraction, scientific, date, general, textOnly, literalOnly
    }

    private(set) var tokens: [Token]
    var condition: Condition?
    var kind: Kind
    /// Each trailing comma divides the number by a thousand.
    private var scale = 0
    private var percents = 0
    private var groupsThousands = false

    init(code: String) {
        var (tokens, condition) = Self.tokenize(code)
        var hasDigit = false, hasDate = false, hasGeneral = false, hasExponent = false, hasSlash = false, hasText = false
        for token in tokens {
            switch token {
            case .digit: hasDigit = true
            case .date, .elapsed, .ampm: hasDate = true
            case .general: hasGeneral = true
            case .exponent: hasExponent = true
            case .slash: hasSlash = true
            case .text: hasText = true
            default: break
            }
        }

        if hasDate {
            tokens = Self.resolveDateTokens(tokens)
            kind = .date
        } else if hasGeneral {
            kind = .general
        } else if hasExponent && hasDigit {
            kind = .scientific
        } else if hasSlash && hasDigit {
            kind = .fraction
        } else if hasDigit {
            kind = .number
        } else if hasText {
            kind = .textOnly
        } else {
            kind = .literalOnly
        }

        // Commas: between digit placeholders they group, after the last one they scale.
        var cleaned: [Token] = []
        for (index, token) in tokens.enumerated() {
            guard case .grouping = token else {
                if case .percent = token { percents += 1 }
                cleaned.append(token)
                continue
            }
            if kind != .number && kind != .scientific && kind != .fraction {
                cleaned.append(.literal(","))
            } else if index + 1 < tokens.count, case .digit = tokens[index + 1] {
                groupsThousands = true
            } else {
                scale += 1
            }
        }
        self.tokens = cleaned
        self.condition = condition
    }

    func render(_ value: Double, usesOwnSign: Bool, date1904: Bool) -> String {
        switch kind {
        case .general:
            let sign = value < 0 && usesOwnSign ? abs(value) : value
            return literals(replacingGeneralWith: NumberFormat.generalString(sign))
        case .date:
            return renderDate(value, date1904: date1904)
        case .number:
            return renderNumber(value, usesOwnSign: usesOwnSign)
        case .scientific:
            return renderScientific(value, usesOwnSign: usesOwnSign)
        case .fraction:
            return renderFraction(value, usesOwnSign: usesOwnSign)
        case .textOnly:
            return NumberFormat.generalString(value)
        case .literalOnly:
            return literals(replacingGeneralWith: "")
        }
    }

    /// Text under an `@` placeholder. Nil when this section does not show text.
    func renderText(_ text: String) -> String? {
        guard tokens.contains(where: { if case .text = $0 { true } else { false } }) else { return nil }
        return tokens.reduce(into: "") { output, token in
            switch token {
            case .literal(let literal): output += literal
            case .text: output += text
            default: break
            }
        }
    }

    private func literals(replacingGeneralWith general: String) -> String {
        tokens.reduce(into: "") { output, token in
            switch token {
            case .literal(let literal): output += literal
            case .general: output += general
            case .percent: output += "%"
            default: break
            }
        }
    }

    // MARK: Numbers

    private func scaled(_ value: Double) -> Decimal? {
        guard var decimal = NumberFormat.plainDecimal(abs(value)), !decimal.isNaN else { return nil }
        for _ in 0..<percents { decimal *= 100 }
        for _ in 0..<scale { decimal /= 1000 }
        return decimal.isNaN ? nil : decimal
    }

    private func renderNumber(_ value: Double, usesOwnSign: Bool) -> String {
        let pointIndex = tokens.firstIndex { if case .decimalPoint = $0 { true } else { false } }
        let integerTokens = pointIndex.map { Array(tokens[..<$0]) } ?? tokens
        let fractionTokens = pointIndex.map { Array(tokens[($0 + 1)...]) } ?? []
        let decimals = fractionTokens.reduce(0) { count, token in
            if case .digit = token { count + 1 } else { count }
        }

        guard let (integerDigits, fractionDigits) = roundedDigits(value, decimals: decimals) else {
            return NumberFormat.generalString(value)
        }
        let isZero = integerDigits.allSatisfy { $0 == "0" } && fractionDigits.allSatisfy { $0 == "0" }
        let sign = value < 0 && !usesOwnSign && !isZero ? "-" : ""
        let visibleInteger = integerDigits.allSatisfy { $0 == "0" } ? [] : integerDigits

        var output = sign + renderInteger(visibleInteger, tokens: integerTokens)
        if pointIndex != nil {
            output += "." + renderFractionDigits(fractionDigits, tokens: fractionTokens)
        }
        return output
    }

    /// Rounds half up on the decimal value, as Excel does, so 1.005 shows as 1.01 at two places.
    private func roundedDigits(_ value: Double, decimals: Int) -> (integer: [Character], fraction: [Character])? {
        guard var decimal = scaled(value) else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, decimals, .plain)
        let parts = rounded.description.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts.first.map(Array.init) ?? ["0"]
        var fraction = parts.count > 1 ? Array(parts[1]) : []
        fraction += Array(repeating: "0", count: max(0, decimals - fraction.count))
        return (integer, fraction)
    }

    /// Fills placeholders from the right, so literals inside a pattern such as
    /// `(###) ###-####` stay in place. Digits left over go in front of the first placeholder.
    private func renderInteger(_ digits: [Character], tokens: [Token]) -> String {
        let firstDigit = tokens.firstIndex { if case .digit = $0 { true } else { false } }
        var reversed: [Character] = []
        var remaining = digits[...]
        var emitted = 0

        func emit(_ character: Character) {
            if groupsThousands && emitted > 0 && emitted % 3 == 0 { reversed.append(",") }
            reversed.append(character)
            emitted += 1
        }

        for (index, token) in tokens.enumerated().reversed() {
            switch token {
            case .digit(let placeholder):
                if let digit = remaining.popLast() {
                    emit(digit)
                } else if placeholder == "0" {
                    emit("0")
                } else if placeholder == "?" {
                    reversed.append(" ")
                }
                if index == firstDigit {
                    while let digit = remaining.popLast() { emit(digit) }
                }
            case .literal(let literal):
                reversed.append(contentsOf: literal.reversed())
            case .percent:
                reversed.append("%")
            case .general, .text:
                break
            default:
                break
            }
        }
        return String(reversed.reversed())
    }

    private func renderFractionDigits(_ digits: [Character], tokens: [Token]) -> String {
        // A trailing zero disappears under `#` and turns into a space under `?`.
        let placeholders = tokens.compactMap { token -> Character? in
            if case .digit(let placeholder) = token { placeholder } else { nil }
        }
        var significant = placeholders.count
        while significant > 0, placeholders[significant - 1] != "0", digits[significant - 1] == "0" {
            significant -= 1
        }
        var output = ""
        var position = 0
        for token in tokens {
            switch token {
            case .digit(let placeholder):
                if position < significant {
                    output.append(digits[position])
                } else if placeholder == "?" {
                    output.append(" ")
                }
                position += 1
            case .literal(let literal):
                output += literal
            case .percent:
                output += "%"
            default:
                break
            }
        }
        return output
    }

    private func renderScientific(_ value: Double, usesOwnSign: Bool) -> String {
        let exponentIndex = tokens.firstIndex { if case .exponent = $0 { true } else { false } } ?? tokens.count
        let mantissaTokens = tokens[..<exponentIndex]
        let exponentTokens = tokens[min(exponentIndex + 1, tokens.count)...]
        var showsPlus = false
        if exponentIndex < tokens.count, case .exponent(let plus) = tokens[exponentIndex] { showsPlus = plus }

        let pointIndex = mantissaTokens.firstIndex { if case .decimalPoint = $0 { true } else { false } }
        var integerPlaces = 0
        var decimals = 0
        for (index, token) in mantissaTokens.enumerated() {
            guard case .digit = token else { continue }
            if let pointIndex, index > pointIndex { decimals += 1 } else { integerPlaces += 1 }
        }
        let exponentPlaces = exponentTokens.reduce(0) { count, token in
            if case .digit = token { count + 1 } else { count }
        }

        let magnitude = abs(value)
        var exponent = magnitude == 0 ? 0 : Int(floor(log10(magnitude)))
        // With several integer places Excel keeps the exponent a multiple of their number.
        if integerPlaces > 1 {
            exponent = Int(floor(Double(exponent) / Double(integerPlaces))) * integerPlaces
        }
        var mantissa = magnitude == 0 ? 0 : magnitude / pow(10, Double(exponent))
        var mantissaText = String(format: "%.\(decimals)f", mantissa)
        if let parsed = Double(mantissaText), parsed >= pow(10, Double(max(integerPlaces, 1))) {
            exponent += max(integerPlaces, 1)
            mantissa = magnitude / pow(10, Double(exponent))
            mantissaText = String(format: "%.\(decimals)f", mantissa)
        }
        let exponentDigits = pad(abs(exponent), max(exponentPlaces, 1))
        let exponentSign = exponent < 0 ? "-" : (showsPlus ? "+" : "")
        return (value < 0 && !usesOwnSign ? "-" : "") + mantissaText + "E" + exponentSign + exponentDigits
    }

    private func renderFraction(_ value: Double, usesOwnSign: Bool) -> String {
        // A fraction of a number this large would only be rounding noise.
        guard abs(value) < 1e15, let slash = tokens.firstIndex(where: { if case .slash = $0 { true } else { false } }) else {
            return NumberFormat.generalString(value)
        }
        // Denominator: a run of placeholders, or fixed digits kept as a literal, as in `# ?/8`.
        var denominatorPlaces = 0
        var fixedDenominator = ""
        for token in tokens[(slash + 1)...] {
            if case .digit(let placeholder) = token {
                denominatorPlaces += 1
                if placeholder.isNumber && placeholder != "0" { fixedDenominator.append(placeholder) }
            } else if case .literal(let literal) = token, Int(literal) != nil {
                fixedDenominator += literal
            }
        }
        // Numerator: the last run of placeholders before the slash. Anything earlier is the whole part.
        var position = slash
        while position > 0, case .digit = tokens[position - 1] { position -= 1 }
        let hasWholePart = tokens[..<position].contains { if case .digit = $0 { true } else { false } }

        let magnitude = abs(value)
        let whole = hasWholePart ? floor(magnitude) : 0
        let remainder = magnitude - whole
        var numerator: Int
        var denominator: Int
        if let fixed = Int(fixedDenominator), fixed > 0, fixed <= 1_000_000 {
            denominator = fixed
            numerator = Int((remainder * Double(fixed)).rounded())
        } else {
            let limit = Int(pow(10, Double(max(1, min(denominatorPlaces, 5))))) - 1
            (numerator, denominator) = Self.bestFraction(remainder, maxDenominator: limit)
        }
        var wholePart = Int(whole)
        if hasWholePart && numerator == denominator {
            wholePart += 1
            numerator = 0
        }

        var output = value < 0 && !usesOwnSign ? "-" : ""
        if hasWholePart && (wholePart != 0 || numerator == 0) {
            output += String(wholePart)
        }
        if numerator != 0 || !hasWholePart {
            if hasWholePart && wholePart != 0 { output += " " }
            output += "\(numerator)/\(denominator)"
        }
        return output
    }

    private static func bestFraction(_ value: Double, maxDenominator: Int) -> (Int, Int) {
        var (lowN, lowD, highN, highD) = (0, 1, 1, 0)
        var best = (Int(value.rounded()), 1)
        var bestError = abs(value - Double(best.0))
        while lowD + highD <= maxDenominator {
            let (n, d) = (lowN + highN, lowD + highD)
            let approximation = Double(n) / Double(d)
            let error = abs(value - approximation)
            if error < bestError {
                best = (n, d)
                bestError = error
            }
            if error < 1e-12 { break }
            if approximation < value { (lowN, lowD) = (n, d) } else { (highN, highD) = (n, d) }
        }
        return best
    }

    // MARK: Dates

    private func renderDate(_ value: Double, date1904: Bool) -> String {
        guard value >= 0, value < 3_000_000 else { return NumberFormat.generalString(value) }
        let fractionDigits = tokens.reduce(0) { current, token in
            if case .fractionOfSecond(let digits) = token { max(current, digits) } else { current }
        }
        // Round to the shown precision first, so 23:59:59.9 does not display as 23:59:60.
        let unit = pow(10, Double(fractionDigits))
        let totalSeconds = (value * 86400 * unit).rounded() / unit
        let wholeDays = floor(totalSeconds / 86400)
        let secondsOfDay = totalSeconds - wholeDays * 86400
        let date = CivilDate(serial: Int(wholeDays), date1904: date1904)
        let hour = Int(secondsOfDay / 3600)
        let minute = Int(secondsOfDay / 60) % 60
        let second = Int(secondsOfDay) % 60
        let subsecond = secondsOfDay - floor(secondsOfDay)
        let usesTwelveHours = tokens.contains { if case .ampm = $0 { true } else { false } }

        return tokens.reduce(into: "") { output, token in
            switch token {
            case .literal(let literal):
                output += literal
            case .date(let part, let count):
                switch part {
                case .year: output += count <= 2 ? pad(date.year % 100, 2) : pad(date.year, 4)
                case .month: output += monthText(date.month, count)
                case .day: output += dayText(date, count)
                case .hour:
                    let shown = usesTwelveHours ? (hour % 12 == 0 ? 12 : hour % 12) : hour
                    output += pad(shown, count)
                case .minute: output += pad(minute, count)
                case .second: output += pad(second, count)
                }
            case .elapsed(let part, let count):
                let elapsed: Double
                switch part {
                case .hour: elapsed = totalSeconds / 3600
                case .minute: elapsed = totalSeconds / 60
                default: elapsed = totalSeconds
                }
                output += pad(Int(elapsed), count)
            case .ampm(let am, let pm):
                output += hour < 12 ? am : pm
            case .fractionOfSecond(let digits):
                let scaled = Int((subsecond * pow(10, Double(digits))).rounded())
                output += "." + pad(scaled, digits)
            case .percent:
                output += "%"
            default:
                break
            }
        }
    }

    private func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private func monthText(_ month: Int, _ count: Int) -> String {
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let name = names[max(0, min(11, month - 1))]
        switch count {
        case 1, 2: return pad(month, count)
        case 3: return String(name.prefix(3))
        case 5: return String(name.prefix(1))
        default: return name
        }
    }

    private func dayText(_ date: CivilDate, _ count: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        switch count {
        case 1, 2: return pad(date.day, count)
        case 3: return String(names[date.weekday].prefix(3))
        default: return names[date.weekday]
        }
    }

    // MARK: Tokenizing

    private static func tokenize(_ code: String) -> (tokens: [Token], condition: Condition?) {
        let characters = Array(code)
        var tokens: [Token] = []
        var condition: Condition?
        var literal = ""
        var index = 0

        func flushLiteral() {
            if !literal.isEmpty {
                tokens.append(.literal(literal))
                literal = ""
            }
        }
        func matches(_ text: String, at start: Int) -> Bool {
            let wanted = Array(text.lowercased())
            guard start + wanted.count <= characters.count else { return false }
            return (0..<wanted.count).allSatisfy { characters[start + $0].lowercased().first == wanted[$0] }
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\"":
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    literal.append(characters[index])
                    index += 1
                }
                index += 1
            case "\\":
                if index + 1 < characters.count { literal.append(characters[index + 1]) }
                index += 2
            case "_":
                // Space as wide as the next character.
                literal.append(" ")
                index += 2
            case "*":
                // Fill character: meaningless without a column width.
                index += 2
            case "[":
                let end = characters[index...].firstIndex(of: "]") ?? characters.count
                let content = String(characters[min(index + 1, end)..<end])
                flushLiteral()
                readBracket(content, tokens: &tokens, condition: &condition, literal: &literal)
                index = end + 1
            case "0", "#", "?":
                flushLiteral()
                tokens.append(.digit(character))
                index += 1
            case ".":
                flushLiteral()
                tokens.append(.decimalPoint)
                index += 1
            case ",":
                flushLiteral()
                tokens.append(.grouping)
                index += 1
            case "%":
                flushLiteral()
                tokens.append(.percent)
                index += 1
            case "/":
                flushLiteral()
                tokens.append(.slash)
                index += 1
            case "@":
                flushLiteral()
                tokens.append(.text)
                index += 1
            default:
                if matches("general", at: index) {
                    flushLiteral()
                    tokens.append(.general)
                    index += 7
                } else if matches("am/pm", at: index) {
                    flushLiteral()
                    tokens.append(.ampm(am: "AM", pm: "PM"))
                    index += 5
                } else if matches("a/p", at: index) {
                    flushLiteral()
                    tokens.append(.ampm(am: "A", pm: "P"))
                    index += 3
                } else if (character == "E" || character == "e"), index + 1 < characters.count,
                    characters[index + 1] == "+" || characters[index + 1] == "-"
                {
                    flushLiteral()
                    tokens.append(.exponent(showsPlus: characters[index + 1] == "+"))
                    index += 2
                } else if let part = datePart(character) {
                    flushLiteral()
                    var count = 0
                    while index < characters.count, datePart(characters[index]) == part {
                        count += 1
                        index += 1
                    }
                    tokens.append(.date(part, count: count))
                } else {
                    literal.append(character)
                    index += 1
                }
            }
        }
        flushLiteral()
        return (tokens, condition)
    }

    private static func datePart(_ character: Character) -> DatePart? {
        switch character.lowercased() {
        case "y": .year
        case "m": .month
        case "d": .day
        case "h": .hour
        case "s": .second
        default: nil
        }
    }

    private static func readBracket(_ content: String, tokens: inout [Token], condition: inout Condition?, literal: inout String) {
        let lowered = content.lowercased()
        if let first = lowered.first, !lowered.isEmpty, lowered.allSatisfy({ $0 == first }), let part = datePart(first), part != .year, part != .day {
            tokens.append(.elapsed(part == .month ? .minute : part, count: lowered.count))
        } else if content.hasPrefix("$") {
            // `[$€-407]` shows the symbol; `[$-409]` only names a locale.
            let symbol = content.dropFirst().prefix { $0 != "-" }
            if !symbol.isEmpty { literal += symbol }
        } else if let comparison = ["<=", ">=", "<>", "<", ">", "="].first(where: { content.hasPrefix($0) }),
            let limit = Double(content.dropFirst(comparison.count))
        {
            condition = Condition(comparison: comparison, limit: limit)
        }
        // Anything else is a colour or a similar instruction with no effect on text.
    }

    /// Settles what a date section's ambiguous tokens mean: `m` is minutes next to hours or
    /// seconds, and `.0` after seconds is a fraction of a second.
    private static func resolveDateTokens(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0
        while index < tokens.count {
            switch tokens[index] {
            case .decimalPoint:
                var digits = 0
                var next = index + 1
                while next < tokens.count, case .digit = tokens[next] {
                    digits += 1
                    next += 1
                }
                if digits > 0 {
                    result.append(.fractionOfSecond(digits: min(digits, 9)))
                    index = next
                    continue
                }
                result.append(.literal("."))
            case .slash:
                result.append(.literal("/"))
            case .digit(let placeholder):
                result.append(.literal(String(placeholder)))
            case .grouping:
                result.append(.literal(","))
            default:
                result.append(tokens[index])
            }
            index += 1
        }

        var parts = result.enumerated().compactMap { offset, token -> (Int, DatePart, Int)? in
            switch token {
            case .date(let part, let count): (offset, part, count)
            case .elapsed(let part, let count): (offset, part, count)
            default: nil
            }
        }
        for position in parts.indices where parts[position].1 == .month {
            let previous = position > 0 ? parts[position - 1].1 : nil
            let next = position + 1 < parts.count ? parts[position + 1].1 : nil
            if previous == .hour || next == .second {
                parts[position].1 = .minute
                result[parts[position].0] = .date(.minute, count: parts[position].2)
            }
        }
        return result
    }
}

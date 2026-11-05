import Foundation

/// Renders English cardinal numbers and sterling amounts without asking a model
/// to calculate their value. The same representation is used by Cleanup's guard.
public enum DictatedNumberFormatter {
    private struct Token {
        let word: String
        let range: Range<String.Index>
    }

    private struct Number {
        var whole: UInt64
        var fraction: String?
        var negative = false
        var end: Int
        var worded: Bool

        var digits: String { (negative ? "-" : "") + String(whole) + (fraction.map { "." + $0 } ?? "") }
    }

    private static let small: [String: UInt64] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    private static let scales: [String: UInt64] = ["thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000]
    private static let pounds: Set<String> = ["pound", "pounds", "gbp"]
    private static let pence: Set<String> = ["pence", "penny", "pennies"]
    private static let limit: UInt64 = 999_999_999_999_999
    private static let tokenPattern = try! NSRegularExpression(pattern: #"[+-]?\d+(?:,\d{3})*(?:\.\d+)?|[\p{L}]+(?:['’][\p{L}]+)?|[£$€]"#)
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(?:\b[a-z][a-z0-9+.-]*://|www\.)\S+|\b[\w.+-]+@[\w.-]+\.\w+\b|(?:^|(?<=\s))(?:/|~/)\S+|\b[\w-]+(?:\.[\w-]+)*\.[a-z][a-z0-9_-]*\b"#,
        options: .caseInsensitive)

    public static func format(_ text: String) -> String {
        let links = linkPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        let tokens = tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Token? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Token(word: text[range].lowercased(), range: range)
        }
        var edits: [(Range<String.Index>, String)] = []
        var index = 0
        while index < tokens.count {
            let start = index
            let prefix = tokens[index].word == "£" || tokens[index].word == "gbp"
            let numberStart = prefix ? index + 1 : index
            guard numberStart < tokens.count, (!prefix || joined(tokens, start, numberStart, in: text, compact: true)),
                  !links.contains(where: { NSIntersectionRange($0, NSRange(tokens[start].range, in: text)).length > 0 }),
                  standalone(tokens[start], in: text), var number = parse(tokens, at: numberStart, in: text) else { index += 1; continue }
            var end = number.end
            let foreignPrefix = start > 0 && ["$", "€"].contains(tokens[start - 1].word)
                && joined(tokens, start - 1, start, in: text, compact: true)
            let hasPounds = end < tokens.count && pounds.contains(tokens[end].word)
                && joined(tokens, end - 1, end, in: text, compact: true)
            let hasPence = end < tokens.count && pence.contains(tokens[end].word)
                && joined(tokens, end - 1, end, in: text, compact: true)
            var replacement: String?
            if !foreignPrefix, prefix || (hasPounds && !isWeight(tokens, start: start, unit: end, in: text)) {
                if hasPounds { end += 1 }
                if end < tokens.count, tokens[end].word == "sterling", joined(tokens, end - 1, end, in: text) { end += 1 }
                // British speech commonly omits "pence": seventeen pounds fifty.
                let minorStart = end < tokens.count && tokens[end].word == "and" ? end + 1 : end
                if number.fraction == nil, minorStart < tokens.count, joined(tokens, end - 1, minorStart, in: text),
                   let minor = parse(tokens, at: minorStart, in: text), minor.fraction == nil, !minor.negative {
                    let explicit = minor.end < tokens.count && pence.contains(tokens[minor.end].word)
                        && joined(tokens, minor.end - 1, minor.end, in: text, compact: true)
                    if explicit || (minor.whole < 100 && minorStart == end && endsShorthand(tokens, end: minor.end, in: text)) {
                        let carry = minor.whole / 100
                        if number.whole <= limit - carry {
                            number.whole += carry
                            number.fraction = String(format: "%02llu", minor.whole % 100)
                            end = minor.end + (explicit ? 1 : 0)
                        }
                    }
                }
                replacement = sterling(number)
            } else if hasPence, !foreignPrefix, number.fraction == nil {
                let pennies = number.whole
                number.whole = pennies / 100
                number.fraction = String(format: "%02llu", pennies % 100)
                end += 1
                replacement = sterling(number)
            } else if number.worded, !isOrdinaryPhrase(tokens, start: start, number: number, in: text) {
                replacement = number.digits
            }
            if let replacement {
                edits.append((tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound, replacement))
                index = end
            } else { index = max(index + 1, number.end) }
        }
        var result = text
        for (range, replacement) in edits.reversed() { result.replaceSubrange(range, with: replacement) }
        return result
    }

    private static func parse(_ tokens: [Token], at start: Int, in text: String) -> Number? {
        var index = start
        let negative = ["minus", "negative"].contains(tokens[index].word)
        if negative {
            index += 1
            guard index < tokens.count, joined(tokens, index - 1, index, in: text) else { return nil }
        }
        guard var group = group(tokens, at: index, in: text) else { return nil }
        let sign = negative || group.negative
        var total: UInt64 = 0, previousScale = UInt64.max
        var end = group.end
        var worded = group.worded || negative
        while group.fraction == nil, end < tokens.count, let scale = scales[tokens[end].word], scale < previousScale,
              joined(tokens, end - 1, end, in: text) {
            guard group.whole <= (limit - total) / scale else { return nil }
            total += group.whole * scale
            previousScale = scale
            end += 1
            worded = true
            var next = end
            if next < tokens.count, tokens[next].word == "and", joined(tokens, next - 1, next, in: text) { next += 1 }
            guard next < tokens.count, joined(tokens, end - 1, next, in: text),
                  let following = self.group(tokens, at: next, in: text), !following.negative else {
                return Number(whole: total, negative: sign, end: end, worded: true)
            }
            group = following
            end = group.end
        }
        guard group.whole <= limit - total else { return nil }
        var result = Number(whole: total + group.whole, fraction: group.fraction,
                            negative: sign, end: end, worded: worded || group.worded)
        if result.fraction == nil, end < tokens.count, tokens[end].word == "point", joined(tokens, end - 1, end, in: text) {
            var digits = "", cursor = end + 1
            while cursor < tokens.count, joined(tokens, cursor - 1, cursor, in: text), digits.count < 12 {
                let word = tokens[cursor].word
                if let value = small[word], value < 10 { digits += String(value) }
                else if let value = small[word], value >= 10,
                        let part = self.group(tokens, at: cursor, in: text), part.whole < 100 {
                    digits += String(part.whole)
                    cursor = part.end
                    continue
                }
                else if word == "oh" { digits += "0" }
                else if word.allSatisfy(\.isNumber), !word.isEmpty { digits += word }
                else { break }
                cursor += 1
            }
            if !digits.isEmpty { result.fraction = digits; result.end = cursor; result.worded = true }
        }
        // Move the decimal point exactly for amounts such as "2.5 million".
        if let fraction = result.fraction, result.end < tokens.count, let scale = scales[tokens[result.end].word],
           joined(tokens, result.end - 1, result.end, in: text) {
            let places = String(scale).count - 1
            let digits = String(result.whole) + fraction
            let remaining = max(0, fraction.count - places)
            let wholeDigits = remaining > 0 ? String(digits.dropLast(remaining))
                : digits + String(repeating: "0", count: max(0, places - fraction.count))
            if let whole = UInt64(wholeDigits), whole <= limit {
                result.whole = whole
                result.fraction = remaining > 0 ? String(digits.suffix(remaining)) : nil
                result.end += 1
                result.worded = true
            }
        }
        return result
    }

    private static func group(_ tokens: [Token], at start: Int, in text: String) -> Number? {
        let word = tokens[start].word
        var number: Number
        if word == "a", start + 1 < tokens.count,
           ["hundred", "thousand", "million", "billion", "pound", "pounds", "penny"].contains(tokens[start + 1].word),
           joined(tokens, start, start + 1, in: text) {
            number = Number(whole: 1, end: start + 1, worded: true)
        } else if let value = small[word] {
            number = Number(whole: value, end: start + 1, worded: true)
            if value >= 20, start + 1 < tokens.count, let unit = small[tokens[start + 1].word], unit > 0, unit < 10,
               joined(tokens, start, start + 1, in: text) {
                number.whole += unit
                number.end += 1
            }
        } else {
            let cleaned = word.replacingOccurrences(of: ",", with: "")
            let negative = cleaned.hasPrefix("-")
            let unsigned = cleaned.hasPrefix("-") || cleaned.hasPrefix("+") ? String(cleaned.dropFirst()) : cleaned
            let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
            guard let first = parts.first, first.allSatisfy(\.isNumber), let value = UInt64(first), value <= limit,
                  parts.count <= 2 else { return nil }
            number = Number(whole: value, fraction: parts.count == 2 ? String(parts[1]) : nil,
                            negative: negative, end: start + 1, worded: false)
        }
        let end = number.end
        if number.fraction == nil, end < tokens.count, tokens[end].word == "hundred", joined(tokens, end - 1, end, in: text) {
            guard number.whole > 0, number.whole < 100 else { return nil }
            number.whole *= 100
            number.end += 1
            number.worded = true
            var rest = number.end
            if rest < tokens.count, tokens[rest].word == "and", joined(tokens, rest - 1, rest, in: text) { rest += 1 }
            if rest < tokens.count, joined(tokens, number.end - 1, rest, in: text),
               let tail = small[tokens[rest].word] ?? UInt64(tokens[rest].word), tail < 100 {
                number.whole += tail
                number.end = rest + 1
                if small[tokens[rest].word] != nil, tail >= 20, number.end < tokens.count, let unit = small[tokens[number.end].word], unit > 0, unit < 10,
                   joined(tokens, number.end - 1, number.end, in: text) {
                    number.whole += unit
                    number.end += 1
                }
            }
        }
        return number
    }

    private static func joined(_ tokens: [Token], _ left: Int, _ right: Int, in text: String, compact: Bool = false) -> Bool {
        guard left >= 0, right < tokens.count, right > left else { return false }
        for index in left..<right {
            let gap = text[tokens[index].range.upperBound..<tokens[index + 1].range.lowerBound]
            guard (compact || !gap.isEmpty), gap.allSatisfy({ ($0.isWhitespace && !$0.isNewline) || $0 == "-" }) else { return false }
        }
        return true
    }

    private static func standalone(_ token: Token, in text: String) -> Bool {
        if token.range.lowerBound > text.startIndex {
            let before = text[text.index(before: token.range.lowerBound)]
            if before.isLetter || before.isNumber || before == "_" { return false }
            if [".", ",", ":", "/"].contains(before), text.index(before: token.range.lowerBound) > text.startIndex {
                let previous = text[text.index(token.range.lowerBound, offsetBy: -2)]
                if previous.isNumber { return false }
            }
        }
        if token.range.upperBound < text.endIndex {
            let after = text[token.range.upperBound]
            if after == "_" { return false }
            let next = text.index(after: token.range.upperBound)
            if [".", ",", ":", "/"].contains(after), next < text.endIndex, text[next].isNumber { return false }
        }
        return true
    }

    private static func isWeight(_ tokens: [Token], start: Int, unit: Int, in text: String) -> Bool {
        let context = tokens[max(0, start - 4)..<start].map(\.word)
        if context.contains(where: { ["weigh", "weighs", "weighed", "weighing", "weight", "heavy", "lb", "lbs", "ounces"].contains($0) }) { return true }
        if unit + 1 < tokens.count, ["of", "weight"].contains(tokens[unit + 1].word) { return true }
        if unit + 2 < tokens.count, tokens[unit + 1].word == "per", ["square", "cubic"].contains(tokens[unit + 2].word) { return true }
        let gap = text[tokens[unit - 1].range.upperBound..<tokens[unit].range.lowerBound]
        if gap.contains("-"), unit + 1 < tokens.count {
            return !["fee", "charge", "deposit", "bill", "note", "coin", "refund", "fine", "budget", "payment", "price"].contains(tokens[unit + 1].word)
        }
        return false
    }

    private static func endsShorthand(_ tokens: [Token], end: Int, in text: String) -> Bool {
        guard end < tokens.count else { return true }
        let gap = text[tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound]
        return gap.contains(where: { ",.;!?".contains($0) }) || ["for", "each", "per", "please", "today"].contains(tokens[end].word)
    }

    private static func isOrdinaryPhrase(_ tokens: [Token], start: Int, number: Number, in text: String) -> Bool {
        let previous = start > 0 ? tokens[start - 1].word : ""
        let next = number.end < tokens.count ? tokens[number.end].word : ""
        if number.end == start + 1, tokens[start].word == "one" {
            if ["the", "no", "any", "every"].contains(previous) || ["of", "another", "who", "that"].contains(next) { return true }
            if number.end < tokens.count {
                let gap = text[tokens[start].range.upperBound..<tokens[number.end].range.lowerBound]
                if gap.contains("-"), ["off", "to", "on"].contains(next) { return true }
            }
            if next == "by", number.end + 1 < tokens.count, tokens[number.end + 1].word == "one" { return true }
            if previous == "by", start >= 2, tokens[start - 2].word == "one" { return true }
        }
        if ["thanks", "thank"].contains(previous) { return true }
        if text[tokens[start].range].first?.isUppercase == true, number.end < tokens.count,
           text[tokens[number.end].range].first?.isUppercase == true { return true }
        return false
    }

    private static func sterling(_ number: Number) -> String {
        let digits = Array(String(number.whole))
        let whole = digits.enumerated().map { index, digit in
            (index > 0 && (digits.count - index).isMultiple(of: 3) ? "," : "") + String(digit)
        }.joined()
        let fraction = number.fraction.map { $0.count < 2 ? $0 + "0" : $0 }
        return (number.negative ? "-" : "") + "£" + whole + (fraction.map { "." + $0 } ?? "")
    }
}

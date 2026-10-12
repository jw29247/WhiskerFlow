import Foundation

/// Applies a tone's capitalisation and end punctuation to text that has already
/// been cleaned up. Links, email addresses and paths are never re-cased or given
/// a period, so a pasted URL still opens.
public enum WritingToneRenderer {
    /// Casual drops the final period only from a message this short.
    public static let shortMessageWordLimit = 20

    public static func render(_ text: String, tone: WritingTone) -> String {
        switch tone.ruleBased {
        case .literal:
            return text
        case .veryCasual:
            return droppingTrailingPeriod(lowercased(text))
        case .casual:
            let written = capitalized(text)
            return isShortSingleSentence(written) ? droppingTrailingPeriod(written) : written
        default:
            return withTerminalPunctuation(capitalized(text))
        }
    }

    /// One line, at most `shortMessageWordLimit` words, and no sentence ends
    /// before the last word. "e.g." and a dotted domain don't end a sentence.
    public static func isShortSingleSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count <= shortMessageWordLimit else { return false }
        return !words.dropLast().contains { endsSentence($0) }
    }

    // MARK: - Tone steps

    private static func capitalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var atSentenceStart = true
        for run in runs(text) {
            guard !run.isSpace else {
                if run.text.contains(where: \.isNewline) { atSentenceStart = true }
                result += run.text
                continue
            }
            if atSentenceStart, !isLinkLike(run.text), !isMixedCase(run.text),
               let first = run.text.firstIndex(where: { $0.isLetter || $0.isNumber }), run.text[first].isLetter {
                result += run.text[..<first]
                result += run.text[first].uppercased()
                result += run.text[run.text.index(after: first)...]
            } else {
                result += run.text
            }
            atSentenceStart = endsSentence(run.text)
        }
        return result
    }

    private static func lowercased(_ text: String) -> String {
        runs(text).map { $0.isSpace || isLinkLike($0.text) || isMixedCase($0.text) ? String($0.text) : $0.text.lowercased() }
            .joined()
    }

    /// A question or exclamation keeps its mark; so do an ellipsis and an
    /// abbreviation, whose period is part of the word.
    private static func droppingTrailingPeriod(_ text: String) -> String {
        let trimmed = trimmingTrailingWhitespace(text)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return text }
        let lastWord = trimmed.split(whereSeparator: \.isWhitespace).last ?? ""
        guard !isAbbreviation(core(lastWord.dropLast())) else { return text }
        return String(trimmed.dropLast())
    }

    /// Adds a period after a final word, but not after a link (it would join
    /// the URL), a colon or comma the speaker chose, or a script whose sentences
    /// don't end with ".".
    private static func withTerminalPunctuation(_ text: String) -> String {
        let trimmed = trimmingTrailingWhitespace(text)
        guard let last = trimmed.last, last.isNumber || (last.isLetter && usesLatinPeriod(last)) else { return text }
        let lastWord = trimmed.split(whereSeparator: \.isWhitespace).last ?? ""
        guard !isLinkLike(lastWord) else { return text }
        return trimmed + "."
    }

    // MARK: - Words

    private struct Run { let text: Substring; let isSpace: Bool }

    private static func runs(_ text: String) -> [Run] {
        var result: [Run] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let isSpace = text[index].isWhitespace
            var end = index
            while end < text.endIndex, text[end].isWhitespace == isSpace { end = text.index(after: end) }
            result.append(Run(text: text[start..<end], isSpace: isSpace))
            start = end
            index = end
        }
        return result
    }

    private static let leadingWrappers = CharacterSet(charactersIn: "([{<\"'“‘«")
    private static let trailingWrappers = CharacterSet(charactersIn: ")]}>\"'”’»")
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?…)]}>\"'”’»")

    /// The word without surrounding quotes, brackets and trailing punctuation.
    private static func core(_ word: Substring) -> Substring {
        var result = word
        while let first = result.unicodeScalars.first, leadingWrappers.contains(first) { result = result.dropFirst() }
        while let last = result.unicodeScalars.last, trailingPunctuation.contains(last) { result = result.dropLast() }
        return result
    }

    private static func endsSentence(_ word: Substring) -> Bool {
        var closed = word
        while let last = closed.unicodeScalars.last, trailingWrappers.contains(last) { closed = closed.dropLast() }
        guard let last = closed.last, "!?…".contains(last) || last == "." else { return false }
        if last == "." { return !isAbbreviation(core(closed.dropLast())) }
        return true
    }

    private static let knownAbbreviations: Set<String> = ["etc", "inc", "ltd", "jr", "sr", "vs", "mr", "mrs", "ms", "dr"]

    /// "e.g", "p.m", "U.S" (single letters between dots) or a known short form.
    private static func isAbbreviation(_ word: Substring) -> Bool {
        let lower = word.lowercased()
        if knownAbbreviations.contains(lower) { return true }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { $0.count == 1 && $0.first!.isLetter }
    }

    private static let domainPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}(:[0-9]+)?(/\\S*)?$")

    /// URLs, bare domains, email addresses and file paths.
    static func isLinkLike(_ word: Substring) -> Bool {
        let candidate = core(word)
        guard !candidate.isEmpty else { return false }
        let lower = candidate.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || lower.hasPrefix("/") || lower.hasPrefix("~/") { return true }
        if let at = lower.firstIndex(of: "@"), lower[lower.index(after: at)...].contains(".") { return true }
        let text = String(candidate)
        return domainPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "iPhone", "WhiskerFlow" and "fetchUser" are names or identifiers (often a
    /// vocabulary replacement): re-casing them would misspell them. "API" and
    /// "Hello" are not mixed case.
    private static func isMixedCase(_ word: Substring) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.dropFirst().contains(where: \.isUppercase) && letters.contains(where: \.isLowercase)
    }

    /// Latin, Greek and Cyrillic end sentences with "."; CJK and others don't.
    private static func usesLatinPeriod(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { $0.value < 0x0530 } ?? false
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = Substring(text)
        while result.last?.isWhitespace == true { result = result.dropLast() }
        return String(result)
    }
}

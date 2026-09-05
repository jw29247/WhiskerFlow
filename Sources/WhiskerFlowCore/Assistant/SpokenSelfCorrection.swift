import Foundation

public enum SpokenSelfCorrection {
    /// Resolves one comma-delimited repair per sentence. Quoted dictation and
    /// sentences with negation, extra clauses, or unbounded repairs stay intact.
    public static func resolve(_ text: String) -> String {
        guard !text.contains(where: { "\"“”‘’".contains($0) }) else { return text }
        var result = ""
        var start = text.startIndex
        for index in text.indices where isSentenceBoundary(text, at: index) {
            let end = text.index(after: index)
            result += resolvePreservingWhitespace(String(text[start..<end]))
            start = end
        }
        result += resolvePreservingWhitespace(String(text[start...]))
        return result
    }

    private static func isSentenceBoundary(_ text: String, at index: String.Index) -> Bool {
        guard ".!?".contains(text[index]) else { return false }
        let next = text.index(after: index)
        guard next == text.endIndex || text[next].isWhitespace else { return false }
        guard text[index] == "." else { return true }

        // A decimal point is never followed by whitespace. Keep initials,
        // dotted abbreviations and common titles attached to their clause so
        // they cannot hide negation from the repair guard. Ellipses are ambiguous.
        let tokenStart = text[..<index].lastIndex(where: { $0.isWhitespace })
            .map { text.index(after: $0) } ?? text.startIndex
        let token = text[tokenStart..<index].lowercased()
        return !token.isEmpty && token.count > 1 && !token.contains(".")
            && !abbreviations.contains(token)
    }

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "rev", "hon",
        "vs", "etc", "eg", "ie", "approx", "dept", "inc", "ltd", "no", "fig"
    ]

    private static func resolvePreservingWhitespace(_ text: String) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else { return text }
        let end = text.index(after: last)
        return text[..<first] + resolveSentence(String(text[first..<end])) + text[end...]
    }

    private static func resolveSentence(_ text: String) -> String {
        if let scratched = resolveScratchThat(text) { return scratched }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = repair.firstMatch(in: text, range: range), match.numberOfRanges == 4,
              let prefixRange = Range(match.range(at: 1), in: text),
              let replacementRange = Range(match.range(at: 2), in: text),
              let punctuationRange = Range(match.range(at: 3), in: text)
        else { return text }

        let prefix = String(text[prefixRange])
        let replacement = String(text[replacementRange])
        guard !prefix.contains(","), !containsNegation(text) else { return text }
        return prefix + replacement + text[punctuationRange]
    }

    private static func resolveScratchThat(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = scratchThat.firstMatch(in: text, range: range), match.numberOfRanges == 3,
              let discardedRange = Range(match.range(at: 1), in: text),
              let replacementRange = Range(match.range(at: 2), in: text) else { return nil }
        let discarded = String(text[discardedRange])
        let replacement = String(text[replacementRange])
        guard !containsNegation(discarded), !containsNegation(replacement) else { return nil }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    private static func containsNegation(_ value: String) -> Bool {
        value.range(of: #"\b(?:not|never|no|don't|do not|isn't|wasn't|can't|cannot|won't)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let repair = try! NSRegularExpression(
        pattern: #"^(.*?\b)(?:[\p{L}\p{N}'-]+),\s*(?:sorry,\s*|I mean,?\s+)([\p{L}\p{N}'-]+)([.!?])$"#,
        options: [.caseInsensitive]
    )
    private static let scratchThat = try! NSRegularExpression(
        pattern: #"^([^.!?\r\n,]{1,200}),\s*scratch that,\s*([\p{L}\p{N}'-]+(?:\s+[\p{L}\p{N}'-]+){1,7}[.!?])$"#,
        options: [.caseInsensitive]
    )
}

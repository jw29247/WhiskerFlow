import Foundation

public enum SpokenSelfCorrection {
    /// Resolves only a single, comma-delimited spoken repair. Anything with
    /// negation, another comma, or an unbounded replacement is left untouched.
    public static func resolve(_ text: String) -> String {
        guard !text.contains(where: { "\"“”‘’".contains($0) }) else { return text }
        if let scratched = resolveScratchThat(text) { return scratched }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = repair.firstMatch(in: text, range: range), match.numberOfRanges == 4,
              let prefixRange = Range(match.range(at: 1), in: text),
              let replacementRange = Range(match.range(at: 2), in: text),
              let punctuationRange = Range(match.range(at: 3), in: text)
        else { return text }

        let prefix = String(text[prefixRange])
        let replacement = String(text[replacementRange])
        guard !containsNegation(prefix), !containsNegation(replacement) else { return text }
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
        pattern: #"^(.+?\b)(?:[\p{L}\p{N}'-]+),\s*(?:sorry,\s*|I mean\s+)([\p{L}\p{N}'-]+)([.!?])$"#,
        options: [.caseInsensitive]
    )
    private static let scratchThat = try! NSRegularExpression(
        pattern: #"^(.{1,200}?),\s*scratch that,\s*([\p{L}\p{N}'-]+(?:\s+[\p{L}\p{N}'-]+){1,7}[.!?])$"#,
        options: [.caseInsensitive]
    )
}

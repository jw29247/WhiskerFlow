import Foundation

public enum SpokenSelfCorrection {
    /// Resolves only a single, comma-delimited spoken repair. Anything with
    /// negation, another comma, or an unbounded replacement is left untouched.
    public static func resolve(_ text: String) -> String {
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

    private static func containsNegation(_ value: String) -> Bool {
        value.range(of: #"\b(?:not|never|no|don't|do not|isn't|wasn't|can't|cannot|won't)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let repair = try! NSRegularExpression(
        pattern: #"^(.+?\b)(?:[\p{L}\p{N}'-]+),\s*(?:sorry|I mean),\s*([\p{L}\p{N}'-]+)([.!?])$"#,
        options: [.caseInsensitive]
    )
}

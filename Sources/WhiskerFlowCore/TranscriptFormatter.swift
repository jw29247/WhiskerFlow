import Foundation

/// Opt-in tidy-up applied to a transcript after the vocabulary rules have run.
/// Every option defaults to off so dictation stays verbatim unless asked.
public struct FormattingOptions: Codable, Equatable, Sendable {
    public var spokenLineCommands: Bool
    public var capitalizeSentences: Bool
    public var removeFillerWords: Bool

    public init(
        spokenLineCommands: Bool = false,
        capitalizeSentences: Bool = false,
        removeFillerWords: Bool = false
    ) {
        self.spokenLineCommands = spokenLineCommands
        self.capitalizeSentences = capitalizeSentences
        self.removeFillerWords = removeFillerWords
    }

    private enum CodingKeys: String, CodingKey {
        case spokenLineCommands, capitalizeSentences, removeFillerWords
    }

    /// Tolerant decoding so a payload persisted before a later option existed
    /// still decodes instead of resetting every choice the user made.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spokenLineCommands = try container.decodeIfPresent(Bool.self, forKey: .spokenLineCommands) ?? false
        capitalizeSentences = try container.decodeIfPresent(Bool.self, forKey: .capitalizeSentences) ?? false
        removeFillerWords = try container.decodeIfPresent(Bool.self, forKey: .removeFillerWords) ?? false
    }

    var isActive: Bool {
        spokenLineCommands || capitalizeSentences || removeFillerWords
    }
}

public enum TranscriptFormatter {
    public static func format(_ text: String, options: FormattingOptions) -> String {
        guard options.isActive else { return text }

        var result = text
        if options.removeFillerWords { result = removingFillerWords(result) }
        if options.spokenLineCommands { result = applyingSpokenCommands(result) }
        if options.capitalizeSentences { result = capitalizingSentences(result) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A hyphen is a word boundary to `\b`, so plain boundaries would fire inside
    /// "uh-huh" and leave a stray hyphen behind. The filler has to be a word on
    /// its own, hyphens included.
    private static let fillerPattern = "(?<![\\w-])(?:um|uh|erm|uhm)(?![\\w-])"

    /// A filler that sits between two punctuation marks would otherwise leave the
    /// pair stranded ("Well, , this"), so when one precedes the filler its own
    /// trailing punctuation goes with it.
    private static func removingFillerWords(_ text: String) -> String {
        text
            .replacingPattern("(?<=[.!?,;:])[ \t]*" + fillerPattern + "[ \t]*[.,!?;:]", with: "")
            .replacingPattern(fillerPattern, with: "")
            .replacingPattern("[ \t]{2,}", with: " ")
            .replacingPattern("[ \t]+([,.!?;:])", with: "$1")
            .replacingPattern(",(?:[ \t]*,)+", with: ",")
            .replacingPattern(",+[ \t]*([.!?])", with: "$1")
            .replacingPattern("(^|\n)[ \t]*,[ \t]*", with: "$1")
    }

    /// A command swallows the punctuation and spacing the speaker left around it,
    /// so "hello. New Line. next" becomes "hello.\nnext" rather than keeping a
    /// stray period on its own line.
    private static func applyingSpokenCommands(_ text: String) -> String {
        text
            .replacingPattern("[ \t]*[,;:]?[ \t]*\\bnew[ \t]+paragraph\\b[ \t]*[.,!?;:]?[ \t]*", with: "\n\n")
            .replacingPattern("[ \t]*[,;:]?[ \t]*\\bnew[ \t]+line\\b[ \t]*[.,!?;:]?[ \t]*", with: "\n")
            .replacingPattern("[ \t]*\n[ \t]*", with: "\n")
            .replacingPattern("\n{3,}", with: "\n\n")
    }

    /// A terminator only ends a sentence when whitespace follows it and the word it
    /// closes doesn't read as an abbreviation. Without both tests, dictated domains
    /// ("example.com"), file names ("report.pdf") and abbreviations ("e.g.", "p.m.")
    /// get letters upper-cased mid-token.
    private static func capitalizingSentences(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var atSentenceStart = true
        var pendingTerminator = false
        var wordLetters = 0
        var wordTerminators = 0

        for character in text {
            if atSentenceStart, character.isLetter {
                result.append(contentsOf: character.uppercased())
                atSentenceStart = false
                pendingTerminator = false
                wordLetters = 1
                wordTerminators = 0
                continue
            }
            result.append(character)

            if character.isNewline {
                atSentenceStart = true
                pendingTerminator = false
                wordLetters = 0
                wordTerminators = 0
            } else if character.isWhitespace {
                if pendingTerminator,
                   !isAbbreviation(letters: wordLetters, terminators: wordTerminators) {
                    atSentenceStart = true
                }
                pendingTerminator = false
                wordLetters = 0
                wordTerminators = 0
            } else if sentenceTerminators.contains(character) {
                pendingTerminator = true
                wordTerminators += 1
            } else {
                pendingTerminator = false
                if character.isLetter { wordLetters += 1 }
                if character.isLetter || character.isNumber { atSentenceStart = false }
            }
        }

        return result
    }

    /// "e.g.", "p.m." and "U.S." carry an interior terminator; a lone initial
    /// ("a.") is one letter followed by one. Neither closes a sentence.
    private static func isAbbreviation(letters: Int, terminators: Int) -> Bool {
        terminators > 1 || letters == 1
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
}

private extension String {
    func replacingPattern(_ pattern: String, with replacement: String) -> String {
        replacingOccurrences(
            of: pattern,
            with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

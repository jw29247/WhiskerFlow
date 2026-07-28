import Foundation

/// A single find/replace rule applied to finished transcripts, e.g. "clawd" -> "Claude".
public struct VocabularyRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var find: String
    public var replaceWith: String
    public var caseSensitive: Bool
    public var wholeWord: Bool

    public init(
        id: UUID = UUID(),
        find: String,
        replaceWith: String,
        caseSensitive: Bool = false,
        wholeWord: Bool = true
    ) {
        self.id = id
        self.find = find
        self.replaceWith = replaceWith
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }

    private enum CodingKeys: String, CodingKey {
        case id, find, replaceWith, caseSensitive, wholeWord
    }

    /// Tolerant decoding so a hand-maintained shared glossary can be terse:
    /// only `find` and `replaceWith` are required; `id` and the flags default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        find = try container.decode(String.self, forKey: .find)
        replaceWith = try container.decode(String.self, forKey: .replaceWith)
        caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? true
    }

    /// The form a case-insensitive rule inserts when it fires on a capitalised
    /// match that opens a sentence ("Gonna go" -> "Going to go"), or nil when the
    /// replacement spells its own casing and must never be touched: a brand such
    /// as "eBay" or "iPhone" would otherwise be emitted as "EBay" / "IPhone".
    public static func sentenceStartVariant(of replacement: String) -> String? {
        guard let first = replacement.first, first.isLowercase else { return nil }
        let firstWord = replacement.prefix { !$0.isWhitespace }
        guard !firstWord.dropFirst().contains(where: \.isUppercase) else { return nil }
        return first.uppercased() + replacement.dropFirst()
    }

    /// Every distinct string this rule can insert into a transcript. Exposed so a
    /// glossary lint can reason about rules cascading into each other without
    /// re-deriving how a replacement is built.
    public var possibleReplacements: [String] {
        guard !caseSensitive, let variant = Self.sentenceStartVariant(of: replaceWith) else {
            return [replaceWith]
        }
        return [replaceWith, variant]
    }
}

public struct Vocabulary: Codable, Equatable, Sendable {
    public var rules: [VocabularyRule]

    public init(rules: [VocabularyRule] = []) {
        self.rules = rules
    }

    /// Apply every rule, in order, to `text`.
    public func apply(to text: String) -> String {
        CompiledVocabulary(self).apply(to: text)
    }

    /// Combine a shared (read-only, team-wide) vocabulary with the user's
    /// personal rules. Shared rules apply first; a personal rule whose `find`
    /// matches a shared rule's (case-insensitively) overrides it, and any other
    /// personal rules layer on top — so personal always wins on conflict.
    public static func effective(shared: Vocabulary, personal: Vocabulary) -> Vocabulary {
        let overridden = Set(
            personal.rules
                .map { $0.find.lowercased() }
                .filter { !$0.isEmpty }
        )
        let keptShared = shared.rules.filter { !overridden.contains($0.find.lowercased()) }
        return Vocabulary(rules: keptShared + personal.rules)
    }
}

/// A `Vocabulary` with every rule's regex compiled once up front. Live dictation
/// applies the vocabulary to each partial result (a few times a second), so the
/// compiled form is built once per session and reused.
public struct CompiledVocabulary: Sendable {
    private let rules: [CompiledRule]

    public init(_ vocabulary: Vocabulary) {
        rules = vocabulary.rules.compactMap(CompiledRule.init)
    }

    public func apply(to text: String) -> String {
        rules.reduce(text) { partial, rule in
            rule.apply(to: partial)
        }
    }
}

/// NSRegularExpression is immutable once built and safe to match from any
/// thread, but it is not annotated `Sendable`.
private final class RegexBox: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ regex: NSRegularExpression) {
        self.regex = regex
    }
}

private struct CompiledRule: Sendable {
    private let regex: RegexBox
    private let replaceWith: String
    private let caseSensitive: Bool

    init?(_ rule: VocabularyRule) {
        let find = rule.find
        guard !find.isEmpty else { return nil }

        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }

        let escaped = NSRegularExpression.escapedPattern(for: find)
        // A word boundary only exists next to a word character. Add it separately
        // at each eligible edge so terms such as "C++" and ".NET" still match.
        let pattern: String
        if rule.wholeWord {
            let leadingBoundary = find.range(of: "^\\w", options: .regularExpression) == nil ? "" : "\\b"
            let trailingBoundary = find.range(of: "\\w$", options: .regularExpression) == nil ? "" : "\\b"
            pattern = leadingBoundary + escaped + trailingBoundary
        } else {
            pattern = escaped
        }

        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        regex = RegexBox(compiled)
        replaceWith = rule.replaceWith
        caseSensitive = rule.caseSensitive
    }

    func apply(to text: String) -> String {
        let source = text as NSString
        var result = ""
        var copiedUpTo = 0
        var didMatch = false

        regex.regex.enumerateMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: source.length)
        ) { match, _, _ in
            guard let match else { return }
            didMatch = true
            let range = match.range
            result += source.substring(with: NSRange(location: copiedUpTo, length: range.location - copiedUpTo))
            result += replacement(
                forMatched: source.substring(with: range),
                atSentenceStart: Self.isSentenceStart(in: source, before: range.location)
            )
            copiedUpTo = range.location + range.length
        }

        guard didMatch else { return text }
        result += source.substring(from: copiedUpTo)
        return result
    }

    /// The replacement is inserted literally — never as a regex template — so a
    /// replacement containing "$1" or "\" survives verbatim. Case-insensitive
    /// rules get exactly one adjustment: a capitalised match that *opens a
    /// sentence* carries its capital into a lowercase-leading replacement, so
    /// "Gonna go" reads "Going to go". A mid-sentence match never gains a capital
    /// it didn't have ("The CX team" stays "the customer experience team"), and a
    /// replacement that spells its own casing is never rewritten.
    private func replacement(forMatched matched: String, atSentenceStart: Bool) -> String {
        guard atSentenceStart, !caseSensitive,
              let matchedFirst = matched.first, matchedFirst.isUppercase,
              let variant = VocabularyRule.sentenceStartVariant(of: replaceWith)
        else { return replaceWith }
        return variant
    }

    /// True when nothing but spaces separates `location` from the start of the text,
    /// a line break, or a sentence terminator. Scanned over UTF-16 units so a long
    /// transcript with many matches doesn't re-slice its prefix each time; a
    /// non-ASCII neighbour simply reads as "not a sentence start", which keeps the
    /// replacement verbatim.
    private static func isSentenceStart(in source: NSString, before location: Int) -> Bool {
        var index = location - 1
        while index >= 0 {
            let unit = source.character(at: index)
            if newlineUnits.contains(unit) { return true }
            guard spaceUnits.contains(unit) else {
                return sentenceTerminatorUnits.contains(unit)
            }
            index -= 1
        }
        return true
    }

    private static let spaceUnits: Set<unichar> = [32, 9] // space, tab
    private static let newlineUnits: Set<unichar> = [10, 13]
    private static let sentenceTerminatorUnits: Set<unichar> = [46, 33, 63] // . ! ?
}

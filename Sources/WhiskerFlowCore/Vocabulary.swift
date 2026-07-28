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
            result += replacement(forMatched: source.substring(with: range))
            copiedUpTo = range.location + range.length
        }

        guard didMatch else { return text }
        result += source.substring(from: copiedUpTo)
        return result
    }

    /// The replacement is inserted literally — never as a regex template — so a
    /// replacement containing "$1" or "\" survives verbatim. A case-insensitive
    /// rule that fired on a capitalised word (sentence start, say) keeps that
    /// capitalisation; brand-name replacements that already lead with an
    /// uppercase letter are left alone.
    private func replacement(forMatched matched: String) -> String {
        guard !caseSensitive,
              let matchedFirst = matched.first, matchedFirst.isUppercase,
              let replacementFirst = replaceWith.first, replacementFirst.isLowercase
        else { return replaceWith }
        return replacementFirst.uppercased() + replaceWith.dropFirst()
    }
}

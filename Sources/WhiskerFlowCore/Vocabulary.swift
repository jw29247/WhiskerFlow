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
        rules.reduce(text) { partial, rule in
            Vocabulary.apply(rule, to: partial)
        }
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

    static func apply(_ rule: VocabularyRule, to text: String) -> String {
        let find = rule.find
        guard !find.isEmpty else { return text }

        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }

        let escaped = NSRegularExpression.escapedPattern(for: find)
        // \b only works at word characters; for symbol-y terms fall back to a plain match.
        let pattern: String
        if rule.wholeWord, find.range(of: "^\\w", options: .regularExpression) != nil {
            pattern = "\\b\(escaped)\\b"
        } else {
            pattern = escaped
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: rule.replaceWith)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

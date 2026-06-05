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

import Foundation
import WhiskerFlowCore

public enum GlossaryLintFlag: Equatable, Hashable, Sendable {
    case commonWord(find: String)
    case commonPhrase(find: String)
    case cascadeHazard(find: String, replaceWith: String, matchedBy: String)

    /// A rule that rewrites everyday speech corrupts every dictation, not just the
    /// ones about a client, so these two are hard-dropped rather than reported.
    public var rewritesEverydaySpeech: Bool {
        switch self {
        case .commonWord, .commonPhrase: return true
        case .cascadeHazard: return false
        }
    }
}

/// Deterministic checks for a shared glossary: no spell-checker, no locale data,
/// so the same rule always produces the same flags on every machine.
public enum GlossaryLint {
    public static func flags(for rule: VocabularyRule) -> [GlossaryLintFlag] {
        let tokens = tokens(in: rule.find)
        guard !tokens.isEmpty else { return [] }
        guard tokens.allSatisfy(isCommonEnglish) else { return [] }
        return [tokens.count == 1 ? .commonWord(find: rule.find) : .commonPhrase(find: rule.find)]
    }

    public static func flags(for vocabulary: Vocabulary) -> [GlossaryLintFlag] {
        var result = vocabulary.rules.flatMap { flags(for: $0) }
        let patterns = vocabulary.rules.map(pattern(for:))
        for (index, rule) in vocabulary.rules.enumerated() where !rule.replaceWith.isEmpty {
            for later in (index + 1)..<vocabulary.rules.count {
                guard let regex = patterns[later], matches(regex, rule.replaceWith) else { continue }
                result.append(
                    .cascadeHazard(
                        find: rule.find,
                        replaceWith: rule.replaceWith,
                        matchedBy: vocabulary.rules[later].find
                    )
                )
            }
        }
        return result
    }

    private static func tokens(in find: String) -> [String] {
        find
            .split(whereSeparator: { $0.isWhitespace || separators.contains($0) })
            .map(String.init)
    }

    private static func isCommonEnglish(_ token: String) -> Bool {
        // Only edge punctuation is ignored: a token carrying a digit ("water 2",
        // "water2") is not everyday English even when the rest of the phrase is, so
        // it keeps the rule alive.
        let trimmed = token.trimmingCharacters(in: edgePunctuation)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isLetter) else { return false }
        return commonEnglishWords.contains(trimmed.lowercased())
    }

    /// Mirrors the pattern `CompiledVocabulary` builds, so a cascade flag means the
    /// later rule really would rewrite this rule's replacement at runtime.
    private static func pattern(for rule: VocabularyRule) -> NSRegularExpression? {
        let find = rule.find
        guard !find.isEmpty else { return nil }

        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }

        let escaped = NSRegularExpression.escapedPattern(for: find)
        let pattern: String
        if rule.wholeWord {
            let leadingBoundary = find.range(of: "^\\w", options: .regularExpression) == nil ? "" : "\\b"
            let trailingBoundary = find.range(of: "\\w$", options: .regularExpression) == nil ? "" : "\\b"
            pattern = leadingBoundary + escaped + trailingBoundary
        } else {
            pattern = escaped
        }

        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static let separators: Set<Character> = ["-", "\u{2013}", "\u{2014}", "/", "_"]

    private static let edgePunctuation = CharacterSet.punctuationCharacters
        .union(.symbols)
        .union(CharacterSet(charactersIn: "\"'"))

    private static let commonEnglishWords: Set<String> = [
        "a", "i", "the", "an", "and", "or", "but", "if", "then", "than", "that", "this", "these",
        "those", "there", "here", "when", "where", "while", "because", "before", "after",
        "be", "is", "am", "are", "was", "were", "been", "being", "have", "has", "had",
        "having", "do", "does", "did", "doing", "done", "will", "would", "can", "could",
        "shall", "should", "may", "might", "must", "need", "needs", "want", "wants",
        "wanted", "get", "gets", "give", "gives", "given", "go", "goes", "going", "gone",
        "went", "come", "comes", "coming", "came", "make", "makes", "made", "making",
        "take", "takes", "taken", "taking", "took", "see", "sees", "seen", "saw", "look",
        "looks", "looking", "looked", "know", "knows", "known", "knew", "think", "thinks",
        "thought", "say", "says", "said", "tell", "tells", "told", "ask", "asks", "asked",
        "work", "works", "working", "worked", "use", "uses", "used", "using", "find",
        "finds", "found", "help", "helps", "helped", "keep", "keeps", "kept", "put",
        "puts", "let", "lets", "run", "runs", "running", "ran", "call", "calls", "called",
        "try", "tries", "tried", "feel", "feels", "felt", "seem", "seems", "leave",
        "leaves", "move", "moves", "moved", "live", "lives", "living", "show", "shows",
        "showed", "play", "plays", "turn", "turns", "start", "starts", "started", "stop",
        "stops", "open", "opens", "close", "closes", "read", "reads", "write", "writes",
        "written", "send", "sends", "sent", "buy", "buys", "pay", "pays", "paid", "sell",
        "sells", "sold", "clean", "cleans", "cleaned", "cleaning", "wash", "washes",
        "book", "books", "booked", "booking", "stay", "stays", "stayed", "sleep",
        "sleeps", "eat", "eats", "drink", "drinks", "wait", "waits", "meet", "meets",
        "love", "loves", "like", "likes", "hope", "hopes", "please", "thanks", "thank",
        "hello", "sorry", "you", "he", "she", "it", "we", "they", "me", "him", "her",
        "us", "them", "my", "your", "his", "its", "our", "their", "mine", "yours",
        "myself", "yourself", "itself", "who", "whom", "whose", "what", "which", "how",
        "why", "in", "on", "at", "to", "for", "with", "without", "from", "by", "about",
        "into", "onto", "over", "under", "up", "down", "out", "off", "through", "between",
        "against", "again", "once", "just", "only", "very", "too", "so", "also", "not",
        "no", "yes", "all", "any", "some", "most", "more", "less", "much", "many", "few",
        "both", "each", "every", "other", "others", "another", "same", "such", "own",
        "new", "old", "good", "better", "best", "bad", "worse", "worst", "great", "nice",
        "fine", "big", "small", "large", "little", "long", "short", "high", "low", "fast",
        "slow", "easy", "hard", "right", "wrong", "true", "false", "free", "full",
        "empty", "early", "late", "next", "last", "first", "second", "third", "final",
        "ready", "sure", "real", "whole", "half", "perfect", "comfy", "cosy", "cozy",
        "clear", "quiet", "quick", "warm", "cool", "hot", "cold", "dry", "wet", "soft",
        "safe", "time", "times", "day", "days", "week", "weeks", "month", "months",
        "year", "years", "hour", "hours", "minute", "minutes", "morning", "evening",
        "night", "today", "tomorrow", "yesterday", "thing", "things", "way", "ways",
        "place", "places", "people", "person", "man", "men", "woman", "women", "child",
        "children", "family", "home", "house", "room", "rooms", "bed", "beds", "bedroom",
        "bathroom", "kitchen", "door", "window", "floor", "wall", "table", "chair",
        "car", "cars", "road", "city", "town", "country", "world", "water", "food",
        "coffee", "tea", "milk", "bread", "money", "price", "prices", "cost", "costs",
        "fee", "fees", "charge", "charges", "tax", "bill", "card", "cash", "number",
        "numbers", "name", "names", "email", "phone", "page", "site", "link", "wifi",
        "internet", "network", "signal", "data", "travel", "trip", "trips", "flight",
        "flights", "train", "bus", "hotel", "hotels", "guest", "guests", "host",
        "review", "reviews", "star", "stars", "service", "services", "product",
        "products", "order", "orders", "team", "teams", "company", "business", "client",
        "clients", "customer", "customers", "market", "brand", "brands", "sale",
        "sales", "deal", "deals", "offer", "offers", "job", "jobs", "life", "part",
        "parts", "side", "end", "top", "bottom", "front", "back", "middle", "group",
        "groups", "list", "lists", "note", "notes", "word", "words", "line", "lines",
        "point", "points", "area", "level", "kind", "sort", "type", "case", "fact",
        "idea", "ideas", "plan", "plans", "question", "questions", "answer", "problem",
        "problems", "reason", "result", "results", "change", "changes", "support",
        "care", "health", "body", "head", "hand", "hands", "eye", "eyes", "face",
        "foot", "feet", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "twenty", "thirty", "forty", "fifty",
        "hundred", "thousand", "million", "twice"
    ]
}

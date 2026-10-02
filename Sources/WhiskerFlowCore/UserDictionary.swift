import Foundation

/// What a dictionary entry teaches WhiskerFlow.
public enum DictionaryEntryKind: String, Codable, CaseIterable, Sendable {
    /// A term to spell and capitalise correctly (a name, product or jargon).
    /// It has no "heard" side: any casing of the term is rewritten to it, and
    /// recognisers that accept hints are told to expect it.
    case word
    /// Heard → written, applied after recognition.
    case replacement
}

/// How a personal entry got into the dictionary. Only `.learned` entries are
/// ever removed automatically, and only when unstarred and unused.
public enum DictionaryEntryOrigin: String, Codable, Sendable {
    case manual
    case learned
    case imported
    case migrated
}

/// Where an entry shown in the Dictionary comes from. Only personal entries are
/// editable; shared and client entries are read-only and labelled by source.
public enum DictionarySource: Equatable, Hashable, Sendable {
    case personal
    case shared
    case client(String)
}

public struct DictionaryEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Every side of an entry is capped: a dictionary term is a name or a short
    /// phrase, and a longer string is almost always a pasted sentence.
    public static let maximumLength = 60

    public var id: UUID
    public var kind: DictionaryEntryKind
    /// The misrecognised form. Empty for words.
    public var heard: String
    public var written: String
    /// Misspellings a word absorbed when it was learned from a spelling fix
    /// ("kubernetis" → "Kubernetes"). They keep post-recognition repair working
    /// without giving the word a "heard" field.
    public var variants: [String]
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var starred: Bool
    public var origin: DictionaryEntryOrigin
    public var addedAt: Date
    public var useCount: Int
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: DictionaryEntryKind,
        heard: String = "",
        written: String,
        variants: [String] = [],
        caseSensitive: Bool = false,
        wholeWord: Bool = true,
        starred: Bool = false,
        origin: DictionaryEntryOrigin = .manual,
        addedAt: Date = Date(),
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.heard = kind == .word ? "" : heard
        self.written = written
        self.variants = kind == .word ? variants : []
        self.caseSensitive = kind == .word ? false : caseSensitive
        self.wholeWord = kind == .word ? true : wholeWord
        self.starred = starred
        self.origin = origin
        self.addedAt = addedAt
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    public static func word(_ written: String, variants: [String] = [], origin: DictionaryEntryOrigin = .manual,
                            addedAt: Date = Date()) -> DictionaryEntry {
        DictionaryEntry(kind: .word, written: written, variants: variants, origin: origin, addedAt: addedAt)
    }

    public static func replacement(_ heard: String, _ written: String, caseSensitive: Bool = false,
                                   wholeWord: Bool = true, origin: DictionaryEntryOrigin = .manual,
                                   addedAt: Date = Date()) -> DictionaryEntry {
        DictionaryEntry(kind: .replacement, heard: heard, written: written, caseSensitive: caseSensitive,
                        wholeWord: wholeWord, origin: origin, addedAt: addedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, heard, written, variants, caseSensitive, wholeWord, starred, origin, addedAt, useCount, lastUsedAt
    }

    /// Tolerant decoding: a field added by a later build must not make an older
    /// dictionary unreadable, and a missing one takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            kind: try c.decodeIfPresent(DictionaryEntryKind.self, forKey: .kind) ?? .replacement,
            heard: try c.decodeIfPresent(String.self, forKey: .heard) ?? "",
            written: try c.decode(String.self, forKey: .written),
            variants: try c.decodeIfPresent([String].self, forKey: .variants) ?? [],
            caseSensitive: try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false,
            wholeWord: try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? true,
            starred: try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false,
            origin: try c.decodeIfPresent(DictionaryEntryOrigin.self, forKey: .origin) ?? .manual,
            addedAt: try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(),
            useCount: try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0,
            lastUsedAt: try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        )
    }

    /// The identity a learned correction is matched against.
    public var pair: DictionaryPair {
        DictionaryPair(heard: kind == .word ? written : heard, written: written)
    }

    /// The find/replace rules this entry contributes, in application order.
    /// A word becomes a case-insensitive whole-word rule onto itself, which
    /// fixes casing ("iphone" → "iPhone") and never changes the spelling of
    /// anything else, plus one rule per absorbed misspelling.
    public var rules: [VocabularyRule] {
        switch kind {
        case .replacement:
            guard !heard.isEmpty else { return [] }
            return [VocabularyRule(id: id, find: heard, replaceWith: written,
                                   caseSensitive: caseSensitive, wholeWord: wholeWord)]
        case .word:
            guard !written.isEmpty else { return [] }
            let spellings = variants
                .filter { !$0.isEmpty && $0.lowercased() != written.lowercased() }
                .map { VocabularyRule(find: $0, replaceWith: written) }
            return spellings + [VocabularyRule(id: id, find: written, replaceWith: written)]
        }
    }

    /// Why this entry can't be saved as typed, or nil when it can.
    public var validationProblem: DictionaryValidationProblem? {
        let trimmedWritten = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWritten.isEmpty { return .missingWritten }
        if kind == .replacement, heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingHeard }
        if ([written, heard] + variants).contains(where: { $0.count > Self.maximumLength }) { return .tooLong }
        return nil
    }

    /// The last time this entry did anything, for staleness.
    public var lastActivity: Date { lastUsedAt ?? addedAt }
}

public enum DictionaryValidationProblem: Equatable, Sendable {
    case missingWritten
    case missingHeard
    case tooLong

    public var message: String {
        switch self {
        case .missingWritten: return "Enter the word as it should be written."
        case .missingHeard: return "Enter what the recogniser hears."
        case .tooLong: return "Entries are limited to \(DictionaryEntry.maximumLength) characters."
        }
    }
}

/// A heard/written pair, the unit corrections are learned and rejected in.
/// `heard` compares case-insensitively; `written` is exact, because a casing
/// fix is the whole point of some pairs.
public struct DictionaryPair: Codable, Hashable, Sendable {
    public var heard: String
    public var written: String

    public init(heard: String, written: String) {
        self.heard = heard
        self.written = written
    }

    public var key: String { heard.lowercased() + "\u{1F}" + written }

    public static func == (lhs: DictionaryPair, rhs: DictionaryPair) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    /// Only the casing differs: the recogniser heard the right word.
    public var isCasingOnly: Bool { heard != written && heard.lowercased() == written.lowercased() }
}

/// An auto-added entry that went unused and was moved back to Suggestions.
public struct DemotedEntry: Codable, Equatable, Hashable, Sendable {
    public var entry: DictionaryEntry
    public var demotedAt: Date

    public init(entry: DictionaryEntry, demotedAt: Date) {
        self.entry = entry
        self.demotedAt = demotedAt
    }
}

public struct DictionaryUsageStat: Codable, Equatable, Hashable, Sendable {
    public var count: Int
    public var lastUsedAt: Date?

    public init(count: Int = 0, lastUsedAt: Date? = nil) {
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

/// The user's personal dictionary plus the learning bookkeeping that has to
/// survive relaunches. Shared and client entries are not stored here; only how
/// often they were used is.
public struct UserDictionary: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Bounds on the bookkeeping lists, so a long-lived install can't grow them without limit.
    public static let maximumRejected = 500
    public static let maximumDemoted = 200

    public var version: Int
    public var entries: [DictionaryEntry]
    public var demoted: [DemotedEntry]
    /// Pairs the user turned down (dismissed or undid). They are never
    /// suggested or auto-added again; the user can still add them by hand.
    public var rejected: [DictionaryPair]
    /// Usage of read-only (shared and client) entries, keyed by `DictionaryPair.key`.
    public var readOnlyUsage: [String: DictionaryUsageStat]

    public init(
        entries: [DictionaryEntry] = [],
        demoted: [DemotedEntry] = [],
        rejected: [DictionaryPair] = [],
        readOnlyUsage: [String: DictionaryUsageStat] = [:]
    ) {
        version = Self.currentVersion
        self.entries = entries
        self.demoted = demoted
        self.rejected = rejected
        self.readOnlyUsage = readOnlyUsage
    }

    private enum CodingKeys: String, CodingKey { case version, entries, demoted, rejected, readOnlyUsage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        entries = try c.decodeIfPresent([DictionaryEntry].self, forKey: .entries) ?? []
        demoted = try c.decodeIfPresent([DemotedEntry].self, forKey: .demoted) ?? []
        rejected = try c.decodeIfPresent([DictionaryPair].self, forKey: .rejected) ?? []
        readOnlyUsage = try c.decodeIfPresent([String: DictionaryUsageStat].self, forKey: .readOnlyUsage) ?? [:]
    }

    /// Carries the pre-Dictionary personal vocabulary over rule for rule. A rule
    /// that only fixes casing with the default flags is exactly what a word does,
    /// so it becomes one; everything else stays a replacement with its flags, its
    /// id and its text untouched, including anything over the new length limit.
    public static func migrating(from vocabulary: Vocabulary, at date: Date = Date()) -> UserDictionary {
        // The old editor saved a blank row as an empty rule; it rewrote nothing
        // and would show as an empty entry.
        UserDictionary(entries: vocabulary.rules.filter { !$0.find.isEmpty || !$0.replaceWith.isEmpty }.map { rule in
            let wordShaped = !rule.caseSensitive && rule.wholeWord && !rule.find.isEmpty
                && rule.find.lowercased() == rule.replaceWith.lowercased()
            return DictionaryEntry(
                id: rule.id,
                kind: wordShaped ? .word : .replacement,
                heard: rule.find,
                written: rule.replaceWith,
                caseSensitive: rule.caseSensitive,
                wholeWord: rule.wholeWord,
                origin: .migrated,
                addedAt: date
            )
        })
    }

    /// The personal layer as find/replace rules: replacements first, then
    /// words, so a replacement's output is cased by a word rather than the
    /// other way round.
    public var vocabulary: Vocabulary {
        let valid = entries.filter { $0.validationProblem == nil || $0.validationProblem == .tooLong }
        return Vocabulary(rules: valid.filter { $0.kind == .replacement }.flatMap(\.rules)
            + valid.filter { $0.kind == .word }.flatMap(\.rules))
    }

    public func isRejected(_ pair: DictionaryPair) -> Bool { rejected.contains(pair) }

    public mutating func reject(_ pair: DictionaryPair) {
        guard !rejected.contains(pair) else { return }
        rejected.append(pair)
        if rejected.count > Self.maximumRejected { rejected.removeFirst(rejected.count - Self.maximumRejected) }
    }

    /// The personal entry already covering `pair`, if any.
    public func entry(matching pair: DictionaryPair) -> DictionaryEntry? {
        entries.first { $0.pair == pair || ($0.kind == .word && $0.written == pair.written
            && $0.variants.contains { $0.lowercased() == pair.heard.lowercased() }) }
    }
}

/// Counts how often dictionary entries shaped a transcript. Runs once per
/// delivered dictation, never on live partials.
public enum DictionaryUsage {
    /// A replacement is used when its heard side appears in the recogniser's
    /// output. A word is used when it appears in the final text (whether the
    /// recogniser got it right or a rule fixed it), or when one of its absorbed
    /// misspellings appears in the recogniser's output.
    public static func counts(for entries: [DictionaryEntry], raw: String, final: String) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for entry in entries {
            let count: Int
            switch entry.kind {
            case .replacement:
                count = CompiledVocabulary(Vocabulary(rules: entry.rules)).matchCount(in: raw)
            case .word:
                let word = VocabularyRule(find: entry.written, replaceWith: entry.written)
                let spellings = entry.rules.filter { $0.id != entry.id }
                count = CompiledVocabulary(Vocabulary(rules: [word])).matchCount(in: final)
                    + CompiledVocabulary(Vocabulary(rules: spellings)).matchCount(in: raw)
            }
            if count > 0 { result[entry.id] = count }
        }
        return result
    }

    /// Usage for read-only rules, keyed by `DictionaryPair.key`.
    public static func counts(forReadOnly rules: [VocabularyRule], raw: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for rule in rules {
            let count = CompiledVocabulary(Vocabulary(rules: [rule])).matchCount(in: raw)
            if count > 0 {
                result[DictionaryPair(heard: rule.find, written: rule.replaceWith).key, default: 0] += count
            }
        }
        return result
    }

    public static func record(_ counts: [UUID: Int], readOnly: [String: Int] = [:],
                              in dictionary: inout UserDictionary, at date: Date) {
        for index in dictionary.entries.indices {
            guard let count = counts[dictionary.entries[index].id] else { continue }
            dictionary.entries[index].useCount += count
            dictionary.entries[index].lastUsedAt = date
        }
        for (key, count) in readOnly {
            var stat = dictionary.readOnlyUsage[key] ?? DictionaryUsageStat()
            stat.count += count
            stat.lastUsedAt = date
            dictionary.readOnlyUsage[key] = stat
        }
    }
}

/// The terms handed to a recogniser as hints: Words and the written side of
/// Replacements. Personal entries come first (starred, then most used), then
/// client and shared ones, deduplicated case-insensitively and capped so the
/// hint stays inside each engine's budget.
public enum DictionaryBiasing {
    public static func terms(personal: [DictionaryEntry], readOnly: [VocabularyRule] = [], limit: Int = 100) -> [String] {
        let ranked = personal
            .filter { $0.validationProblem == nil }
            .sorted { lhs, rhs in
                if lhs.starred != rhs.starred { return lhs.starred }
                if lhs.kind != rhs.kind { return lhs.kind == .word }
                return lhs.useCount > rhs.useCount
            }
            .map(\.written)
        var seen: Set<String> = []
        var result: [String] = []
        for term in ranked + readOnly.map(\.replaceWith) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= DictionaryEntry.maximumLength,
                  trimmed.contains(where: \.isLetter),
                  seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }
}

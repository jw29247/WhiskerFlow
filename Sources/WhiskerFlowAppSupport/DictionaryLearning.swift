import Foundation
import WhiskerFlowCore

/// One word pair seen when the user fixed a pasted or saved transcript.
public struct CorrectionObservation: Equatable, Sendable {
    public var pair: DictionaryPair
    /// One paste (or one History record). A pair counts once per session however
    /// many times it was edited back and forth inside it.
    public var sessionID: UUID
    public var application: String
    public var date: Date

    public init(pair: DictionaryPair, sessionID: UUID, application: String, date: Date) {
        self.pair = pair
        self.sessionID = sessionID
        self.application = application
        self.date = date
    }
}

/// A rule in the effective vocabulary, with where it came from.
public struct DictionaryRule: Equatable, Sendable {
    public var rule: VocabularyRule
    public var source: DictionarySource
    /// The personal entry the rule was compiled from, if any.
    public var entryID: UUID?

    public init(rule: VocabularyRule, source: DictionarySource, entryID: UUID? = nil) {
        self.rule = rule
        self.source = source
        self.entryID = entryID
    }

    public static func personal(_ dictionary: UserDictionary) -> [DictionaryRule] {
        let replacements = dictionary.entries.filter { $0.kind == .replacement }
        let words = dictionary.entries.filter { $0.kind == .word }
        return (replacements + words).flatMap { entry in
            entry.rules.map { DictionaryRule(rule: $0, source: .personal, entryID: entry.id) }
        }
    }
}

public enum DictionaryIssue: Equatable, Hashable, Sendable {
    case invalid(DictionaryValidationProblem)
    /// The side a rule keys on is made only of everyday English words, so it
    /// would fire in ordinary speech.
    case everydaySpeech(String)
    /// Another rule already rewrites the same heard text to something else.
    case conflict(heard: String, existingWritten: String, source: DictionarySource)
    /// Another rule already does exactly this.
    case duplicate(source: DictionarySource)
    /// This rule's output would be rewritten by another rule, or it would
    /// rewrite another rule's output.
    case chain(with: String, source: DictionarySource)
    /// The rule rewrites its own output, so applying the vocabulary twice
    /// (a retry, a History edit) would change the text again.
    case feedsItself

    public var message: String {
        switch self {
        case .invalid(let problem): return problem.message
        case .everydaySpeech(let text): return "“\(text)” is an everyday word, so this would change ordinary speech."
        case .conflict(let heard, let written, let source):
            return "\(source.label) already writes “\(heard)” as “\(written)”."
        case .duplicate(let source): return "\(source.label) already does this."
        case .chain(let other, let source): return "Feeds into “\(other)” from \(source.label.lowercased())."
        case .feedsItself: return "The written text would be rewritten again by this same rule."
        }
    }
}

extension DictionarySource {
    public var label: String {
        switch self {
        case .personal: return "Your dictionary"
        case .shared: return "The shared library"
        case .client(let name): return "Client \(name)"
        }
    }
}

/// Checks a personal entry against everything else that rewrites text. Uses
/// the real `CompiledVocabulary` for chains, so a flag means the rules really
/// would interact at runtime (including sentence-start capitalisation), and a
/// casing no-op is not mistaken for one.
public enum DictionaryLint {
    public static func issues(for entry: DictionaryEntry, against existing: [DictionaryRule]) -> [DictionaryIssue] {
        if let problem = entry.validationProblem, problem != .tooLong || entry.origin != .migrated {
            return [.invalid(problem)]
        }
        var issues: [DictionaryIssue] = []
        let keyedOn = entry.kind == .word ? [entry.written] + entry.variants : [entry.heard]
        if let everyday = keyedOn.first(where: GlossaryLint.isEverydaySpeech) {
            issues.append(.everydaySpeech(everyday))
        }

        let others = existing.filter { $0.entryID == nil || $0.entryID != entry.id }
        let ownRules = entry.rules
        let own = CompiledVocabulary(Vocabulary(rules: ownRules))
        for candidate in ownRules {
            if candidate.possibleReplacements.contains(where: { own.apply(to: $0) != $0 }) {
                issues.append(.feedsItself)
            }
            let candidateAlone = CompiledVocabulary(Vocabulary(rules: [candidate]))
            for other in others {
                if other.rule.find.lowercased() == candidate.find.lowercased() {
                    issues.append(other.rule.replaceWith == candidate.replaceWith
                        ? .duplicate(source: other.source)
                        : .conflict(heard: candidate.find, existingWritten: other.rule.replaceWith, source: other.source))
                    continue
                }
                let otherAlone = CompiledVocabulary(Vocabulary(rules: [other.rule]))
                let candidateChanged = candidate.possibleReplacements.contains { otherAlone.apply(to: $0) != $0 }
                let otherChanged = other.rule.possibleReplacements.contains { candidateAlone.apply(to: $0) != $0 }
                if candidateChanged || otherChanged {
                    issues.append(.chain(with: other.rule.find, source: other.source))
                }
            }
        }
        var seen: Set<DictionaryIssue> = []
        return issues.filter { seen.insert($0).inserted }
    }
}

public struct DictionarySuggestion: Identifiable, Equatable, Sendable {
    public var id: String { pair.key }
    public var pair: DictionaryPair
    /// What accepting it adds (or, for a known word, how that word changes).
    public var proposed: DictionaryEntry
    /// Distinct pastes or History records the pair was seen in.
    public var sightings: Int
    public var lastSeen: Date?
    public var applications: [String]
    /// Set when this was an auto-added entry moved back for going unused.
    public var demotedAt: Date?
    /// Why it wasn't (or won't be) added automatically.
    public var issues: [DictionaryIssue]
}

/// A change learning made to the dictionary, kept so it can be undone exactly.
public struct DictionaryChange: Equatable, Sendable {
    public var pair: DictionaryPair
    public var before: DictionaryEntry?
    public var after: DictionaryEntry
}

public enum DictionaryLearning {
    /// Distinct sightings before a pair is added without asking.
    public static let autoAddThreshold = 2
    /// Unstarred auto-added entries unused this long go back to Suggestions.
    public static let staleInterval: TimeInterval = 90 * 24 * 60 * 60

    public static func sightings(of pair: DictionaryPair, in observations: [CorrectionObservation]) -> Int {
        Set(observations.filter { $0.pair == pair }.map(\.sessionID)).count
    }

    /// A casing fix, or a small spelling fix of each word, becomes a Word
    /// (keeping the misspelling as a variant so it is still repaired); any other
    /// change is a Replacement.
    public static func proposedEntry(for pair: DictionaryPair, at date: Date = Date()) -> DictionaryEntry {
        if pair.isCasingOnly { return .word(pair.written, origin: .learned, addedAt: date) }
        if isSpellingFix(pair) { return .word(pair.written, variants: [pair.heard], origin: .learned, addedAt: date) }
        return .replacement(pair.heard, pair.written, origin: .learned, addedAt: date)
    }

    static func isSpellingFix(_ pair: DictionaryPair) -> Bool {
        let heard = pair.heard.lowercased().split(separator: " ")
        let written = pair.written.lowercased().split(separator: " ")
        guard !heard.isEmpty, heard.count == written.count, heard != written else { return false }
        return zip(heard, written).allSatisfy { lhs, rhs in
            lhs == rhs || editDistance(Array(lhs), Array(rhs)) <= max(1, rhs.count / 4)
        }
    }

    public struct Evaluation: Equatable, Sendable {
        public var pair: DictionaryPair
        public var proposed: DictionaryEntry
        /// The existing word `proposed` updates, when the pair is a new
        /// misspelling of a word already in the dictionary.
        public var updates: DictionaryEntry?
        public var sightings: Int
        public var issues: [DictionaryIssue]
        /// Already produced by the effective vocabulary; nothing to learn.
        public var isCovered: Bool
        public var isRejected: Bool
        public var isDemoted: Bool

        public var canAutoAdd: Bool {
            sightings >= DictionaryLearning.autoAddThreshold && issues.isEmpty
                && !isCovered && !isRejected && !isDemoted
        }
    }

    public static func evaluate(
        _ pair: DictionaryPair,
        observations: [CorrectionObservation],
        dictionary: UserDictionary,
        readOnly: [DictionaryRule],
        at date: Date = Date()
    ) -> Evaluation {
        let personal = DictionaryRule.personal(dictionary)
        // Personal wins over read-only; mirror `Vocabulary.effective` ordering.
        let effective = Vocabulary.effective(shared: Vocabulary(rules: readOnly.map(\.rule)),
                                             personal: Vocabulary(rules: personal.map(\.rule)))
        let isCovered = CompiledVocabulary(effective).apply(to: pair.heard) == pair.written
        var proposed = proposedEntry(for: pair, at: date)
        var updates: DictionaryEntry?
        if proposed.kind == .word, !proposed.variants.isEmpty,
           let existing = dictionary.entries.first(where: { $0.kind == .word && $0.written == pair.written }) {
            updates = existing
            proposed = existing
            proposed.variants.append(pair.heard)
        }
        return Evaluation(
            pair: pair,
            proposed: proposed,
            updates: updates,
            sightings: sightings(of: pair, in: observations),
            issues: DictionaryLint.issues(for: proposed, against: readOnly + personal),
            isCovered: isCovered,
            isRejected: dictionary.isRejected(pair),
            isDemoted: dictionary.demoted.contains { $0.entry.pair == pair }
        )
    }

    /// Adds every pair in `pairs` that has now been seen often enough and
    /// passes every check. Pairs are taken in order and each addition is
    /// visible to the next, so two new pairs can't be added in conflict.
    /// Only the pairs just observed are considered: history that predates the
    /// setting stays in Suggestions until it is seen again.
    public static func learn(
        from pairs: [DictionaryPair],
        observations: [CorrectionObservation],
        dictionary: inout UserDictionary,
        readOnly: [DictionaryRule],
        at date: Date = Date()
    ) -> [DictionaryChange] {
        var changes: [DictionaryChange] = []
        var considered: Set<DictionaryPair> = []
        for pair in pairs where considered.insert(pair).inserted {
            let evaluation = evaluate(pair, observations: observations, dictionary: dictionary,
                                      readOnly: readOnly, at: date)
            guard evaluation.canAutoAdd else { continue }
            if let before = evaluation.updates, let index = dictionary.entries.firstIndex(where: { $0.id == before.id }) {
                dictionary.entries[index] = evaluation.proposed
            } else {
                dictionary.entries.append(evaluation.proposed)
            }
            changes.append(DictionaryChange(pair: pair, before: evaluation.updates, after: evaluation.proposed))
        }
        return changes
    }

    /// Reverts a learned change and makes sure it is not learned again.
    public static func undo(_ change: DictionaryChange, in dictionary: inout UserDictionary) {
        if let before = change.before, let index = dictionary.entries.firstIndex(where: { $0.id == before.id }) {
            dictionary.entries[index] = before
        } else {
            dictionary.entries.removeAll { $0.id == change.after.id }
        }
        dictionary.reject(change.pair)
    }

    /// Pairs waiting for a decision: seen but not in the dictionary, plus
    /// auto-added entries that were demoted. Most recent first.
    public static func suggestions(
        observations: [CorrectionObservation],
        dictionary: UserDictionary,
        readOnly: [DictionaryRule]
    ) -> [DictionarySuggestion] {
        var byPair: [DictionaryPair: [CorrectionObservation]] = [:]
        var order: [DictionaryPair] = []
        for observation in observations {
            if byPair[observation.pair] == nil { order.append(observation.pair) }
            byPair[observation.pair, default: []].append(observation)
        }
        var result: [DictionarySuggestion] = []
        for pair in order where !dictionary.isRejected(pair) {
            guard !dictionary.demoted.contains(where: { $0.entry.pair == pair }) else { continue }
            let seen = byPair[pair] ?? []
            let evaluation = evaluate(pair, observations: seen, dictionary: dictionary, readOnly: readOnly)
            guard !evaluation.isCovered else { continue }
            result.append(DictionarySuggestion(
                pair: pair, proposed: evaluation.proposed, sightings: evaluation.sightings,
                lastSeen: seen.map(\.date).max(), applications: Array(Set(seen.map(\.application))).sorted(),
                demotedAt: nil, issues: evaluation.issues))
        }
        for demoted in dictionary.demoted where !dictionary.isRejected(demoted.entry.pair) {
            let seen = observations.filter { $0.pair == demoted.entry.pair }
            let others = DictionaryRule.personal(dictionary) + readOnly
            result.append(DictionarySuggestion(
                pair: demoted.entry.pair, proposed: demoted.entry, sightings: Set(seen.map(\.sessionID)).count,
                lastSeen: max(seen.map(\.date).max() ?? demoted.demotedAt, demoted.demotedAt),
                applications: Array(Set(seen.map(\.application))).sorted(),
                demotedAt: demoted.demotedAt, issues: DictionaryLint.issues(for: demoted.entry, against: others)))
        }
        return result.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    /// Moves unstarred, auto-added entries that have done nothing for
    /// `staleInterval` back to Suggestions. Hand-made, imported and migrated
    /// entries are never touched, and neither is anything starred.
    @discardableResult
    public static func demoteStale(_ dictionary: inout UserDictionary, at date: Date = Date()) -> [DictionaryEntry] {
        let cutoff = date.addingTimeInterval(-staleInterval)
        let stale = dictionary.entries.filter { $0.origin == .learned && !$0.starred && $0.lastActivity <= cutoff }
        guard !stale.isEmpty else { return [] }
        let staleIDs = Set(stale.map(\.id))
        dictionary.entries.removeAll { staleIDs.contains($0.id) }
        dictionary.demoted.append(contentsOf: stale.map { DemotedEntry(entry: $0, demotedAt: date) })
        if dictionary.demoted.count > UserDictionary.maximumDemoted {
            dictionary.demoted.removeFirst(dictionary.demoted.count - UserDictionary.maximumDemoted)
        }
        return stale
    }

    /// The user accepted a suggestion. It becomes a hand-made entry: the user
    /// chose it, so it is never demoted automatically.
    public static func accept(_ suggestion: DictionarySuggestion, in dictionary: inout UserDictionary,
                              at date: Date = Date()) -> DictionaryEntry {
        var entry = suggestion.proposed
        entry.origin = .manual
        if suggestion.demotedAt == nil, !dictionary.entries.contains(where: { $0.id == entry.id }) {
            entry.addedAt = date
        }
        dictionary.demoted.removeAll { $0.entry.pair == suggestion.pair }
        if let index = dictionary.entries.firstIndex(where: { $0.id == entry.id }) {
            dictionary.entries[index] = entry
        } else {
            dictionary.entries.append(entry)
        }
        return entry
    }

    public static func dismiss(_ suggestion: DictionarySuggestion, in dictionary: inout UserDictionary) {
        dictionary.demoted.removeAll { $0.entry.pair == suggestion.pair }
        dictionary.reject(suggestion.pair)
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

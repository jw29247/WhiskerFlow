import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

final class DictionaryLearningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seen(_ heard: String, _ written: String, times: Int, app: String = "Notes") -> [CorrectionObservation] {
        (0..<times).map { index in
            CorrectionObservation(pair: DictionaryPair(heard: heard, written: written), sessionID: UUID(),
                                  application: app, date: now.addingTimeInterval(Double(index)))
        }
    }

    private func learn(_ heard: String, _ written: String, times: Int,
                       into dictionary: inout UserDictionary, readOnly: [DictionaryRule] = []) -> [DictionaryChange] {
        DictionaryLearning.learn(from: [DictionaryPair(heard: heard, written: written)],
                                 observations: seen(heard, written, times: times),
                                 dictionary: &dictionary, readOnly: readOnly, at: now)
    }

    // MARK: Threshold and classification

    func testPairIsAddedOnlyOnceSeenInTwoSessions() {
        var dictionary = UserDictionary()
        XCTAssertTrue(learn("clawed", "Claude", times: 1, into: &dictionary).isEmpty)
        XCTAssertTrue(dictionary.entries.isEmpty)

        let changes = learn("clawed", "Claude", times: 2, into: &dictionary)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(dictionary.entries.map(\.kind), [.replacement])
        XCTAssertEqual(dictionary.entries[0].heard, "clawed")
        XCTAssertEqual(dictionary.entries[0].written, "Claude")
        XCTAssertEqual(dictionary.entries[0].origin, .learned)
    }

    func testTheSameSessionSeenTwiceCountsOnce() {
        let session = UUID()
        let pair = DictionaryPair(heard: "clawed", written: "Claude")
        let observations = [CorrectionObservation(pair: pair, sessionID: session, application: "A", date: now),
                            CorrectionObservation(pair: pair, sessionID: session, application: "A", date: now)]
        var dictionary = UserDictionary()
        XCTAssertTrue(DictionaryLearning.learn(from: [pair], observations: observations, dictionary: &dictionary,
                                               readOnly: []).isEmpty)
    }

    func testCasingAndSpellingFixesBecomeWords() {
        XCTAssertEqual(DictionaryLearning.proposedEntry(for: .init(heard: "figma", written: "Figma")).kind, .word)
        let spelling = DictionaryLearning.proposedEntry(for: .init(heard: "kubernetis", written: "Kubernetes"))
        XCTAssertEqual(spelling.kind, .word)
        XCTAssertEqual(spelling.written, "Kubernetes")
        XCTAssertEqual(spelling.variants, ["kubernetis"])
        XCTAssertEqual(DictionaryLearning.proposedEntry(for: .init(heard: "cooper net ease", written: "Kubernetes")).kind,
                       .replacement)
        XCTAssertEqual(DictionaryLearning.proposedEntry(for: .init(heard: "clawed", written: "Claude")).kind, .replacement)
    }

    func testNewMisspellingOfAKnownWordExtendsThatWord() {
        var dictionary = UserDictionary(entries: [.word("Kubernetes")])
        let changes = learn("kubernetis", "Kubernetes", times: 2, into: &dictionary)
        XCTAssertEqual(dictionary.entries.count, 1)
        XCTAssertEqual(dictionary.entries[0].variants, ["kubernetis"])
        XCTAssertEqual(changes.first?.before?.variants, [])
        DictionaryLearning.undo(changes[0], in: &dictionary)
        XCTAssertEqual(dictionary.entries[0].variants, [], "undo restores the word as it was")
    }

    // MARK: Lint rejections

    func testEverydayHeardSideIsNeverAutoAdded() {
        var dictionary = UserDictionary()
        XCTAssertTrue(learn("word", "Word", times: 5, into: &dictionary).isEmpty, "casing-only still counts")
        XCTAssertTrue(learn("going to", "gonna", times: 5, into: &dictionary).isEmpty)
        XCTAssertTrue(learn("tabe", "table", times: 5, into: &dictionary).isEmpty, "a spelling fix onto an everyday word")
        XCTAssertTrue(dictionary.entries.isEmpty)
        let evaluation = DictionaryLearning.evaluate(.init(heard: "going to", written: "gonna"),
                                                     observations: [], dictionary: dictionary, readOnly: [])
        XCTAssertEqual(evaluation.issues, [.everydaySpeech("going to")])
    }

    func testOverLongPairIsNeverAutoAdded() {
        var dictionary = UserDictionary()
        XCTAssertTrue(learn("zork", String(repeating: "Z", count: 61), times: 3, into: &dictionary).isEmpty)
    }

    // MARK: Conflicts and chains

    func testConflictWithSharedOrPersonalRuleBlocksAutoAdd() {
        let shared = [DictionaryRule(rule: VocabularyRule(find: "clawed", replaceWith: "Clawd"), source: .shared)]
        var dictionary = UserDictionary()
        XCTAssertTrue(learn("clawed", "Claude", times: 3, into: &dictionary, readOnly: shared).isEmpty)
        let evaluation = DictionaryLearning.evaluate(.init(heard: "clawed", written: "Claude"), observations: [],
                                                     dictionary: dictionary, readOnly: shared)
        XCTAssertEqual(evaluation.issues, [.conflict(heard: "clawed", existingWritten: "Clawd", source: .shared)])

        var personal = UserDictionary(entries: [.replacement("sio ban", "Siobhan")])
        XCTAssertTrue(learn("sio ban", "Shivaun", times: 3, into: &personal).isEmpty)
        XCTAssertEqual(personal.entries.count, 1)
    }

    func testRuleWhoseOutputAnotherRuleRewritesIsAChain() {
        // New "atlas app" -> "Atlas" would feed the client rule "atlas" -> "ATLAS".
        let client = [DictionaryRule(rule: VocabularyRule(find: "atlas", replaceWith: "ATLAS"), source: .client("Acme"))]
        var dictionary = UserDictionary()
        XCTAssertTrue(learn("at less app", "atlas app", times: 3, into: &dictionary, readOnly: client).isEmpty)
        let issues = DictionaryLint.issues(for: .replacement("at less app", "atlas app"), against: client)
        XCTAssertEqual(issues, [.chain(with: "atlas", source: .client("Acme"))])
    }

    func testRuleThatRewritesAnotherRulesOutputIsAChain() {
        // Existing "sequel" -> "SQL server"; new "sql" -> "Structured Query Language"
        // would rewrite that output.
        var dictionary = UserDictionary(entries: [.replacement("sequel", "SQL server")])
        XCTAssertTrue(learn("sql", "Structured Query Language", times: 3, into: &dictionary).isEmpty)
        let issues = DictionaryLint.issues(for: .replacement("sql", "Structured Query Language"),
                                           against: DictionaryRule.personal(dictionary))
        XCTAssertEqual(issues, [.chain(with: "sequel", source: .personal)])
    }

    func testSelfFeedingRuleIsRejected() {
        XCTAssertEqual(DictionaryLint.issues(for: .replacement("claude", "claude ai"), against: []), [.feedsItself])
    }

    func testCasingNoOpIsNotAChain() {
        // A shared rule producing "WhiskerFlow" and a word "WhiskerFlow" agree.
        let shared = [DictionaryRule(rule: VocabularyRule(find: "whisker flow", replaceWith: "WhiskerFlow"), source: .shared)]
        XCTAssertEqual(DictionaryLint.issues(for: .word("WhiskerFlow"), against: shared), [])
    }

    func testCandidatesInOneBatchCannotConflict() {
        var dictionary = UserDictionary()
        let observations = seen("zorp", "Zorpify", times: 2) + seen("zorp", "Zorplex", times: 2)
        let changes = DictionaryLearning.learn(
            from: [.init(heard: "zorp", written: "Zorpify"), .init(heard: "zorp", written: "Zorplex")],
            observations: observations, dictionary: &dictionary, readOnly: [], at: now)
        XCTAssertEqual(changes.map(\.after.written), ["Zorpify"])
    }

    func testCoveredRejectedAndDemotedPairsAreNotAdded() {
        var covered = UserDictionary(entries: [.word("Figma")])
        XCTAssertTrue(learn("figma", "Figma", times: 3, into: &covered).isEmpty)

        var dictionary = UserDictionary()
        let change = learn("clawed", "Claude", times: 2, into: &dictionary)[0]
        DictionaryLearning.undo(change, in: &dictionary)
        XCTAssertTrue(dictionary.entries.isEmpty)
        XCTAssertTrue(learn("clawed", "Claude", times: 4, into: &dictionary).isEmpty, "undo means never again")
    }

    // MARK: Demotion

    func testUnusedUnstarredLearnedEntriesAreDemotedAfterNinetyDays() {
        let old = now.addingTimeInterval(-DictionaryLearning.staleInterval - 1)
        var learned = DictionaryEntry.replacement("clawed", "Claude", origin: .learned, addedAt: old)
        var starred = DictionaryEntry.word("Figma", origin: .learned, addedAt: old)
        starred.starred = true
        var recentlyUsed = DictionaryEntry.word("Atlas", origin: .learned, addedAt: old)
        recentlyUsed.lastUsedAt = now.addingTimeInterval(-86_400)
        let manual = DictionaryEntry.word("Sketch", origin: .manual, addedAt: old)
        let fresh = DictionaryEntry.word("Linear", origin: .learned, addedAt: now.addingTimeInterval(-86_400))
        var dictionary = UserDictionary(entries: [learned, starred, recentlyUsed, manual, fresh])

        let demoted = DictionaryLearning.demoteStale(&dictionary, at: now)
        XCTAssertEqual(demoted.map(\.written), ["Claude"])
        XCTAssertEqual(dictionary.entries.map(\.written), ["Figma", "Atlas", "Sketch", "Linear"])
        XCTAssertEqual(dictionary.demoted.map(\.entry.written), ["Claude"])

        // It is back in Suggestions and is not immediately re-learned.
        let suggestions = DictionaryLearning.suggestions(observations: [], dictionary: dictionary, readOnly: [])
        XCTAssertEqual(suggestions.map(\.pair.written), ["Claude"])
        XCTAssertEqual(suggestions.first?.demotedAt, now)
        XCTAssertTrue(learn("clawed", "Claude", times: 5, into: &dictionary).isEmpty)

        // Accepting makes it a hand-made entry, which is never demoted again.
        learned = DictionaryLearning.accept(suggestions[0], in: &dictionary, at: now)
        XCTAssertEqual(learned.origin, .manual)
        XCTAssertTrue(dictionary.demoted.isEmpty)
        XCTAssertTrue(DictionaryLearning.demoteStale(&dictionary, at: now.addingTimeInterval(365 * 86_400))
            .allSatisfy { $0.written != "Claude" })
    }

    // MARK: Suggestions

    func testSuggestionsGroupSightingsAndExplainBlocks() {
        let observations = seen("clawed", "Claude", times: 1, app: "Slack") + seen("word", "Word", times: 3)
            + seen("figma", "Figma", times: 1)
        let dictionary = UserDictionary(entries: [.word("Figma")], rejected: [])
        let suggestions = DictionaryLearning.suggestions(observations: observations, dictionary: dictionary, readOnly: [])
        XCTAssertEqual(Set(suggestions.map(\.pair.written)), ["Claude", "Word"], "covered pairs are hidden")
        let word = suggestions.first { $0.pair.written == "Word" }
        XCTAssertEqual(word?.sightings, 3)
        XCTAssertEqual(word?.issues, [.everydaySpeech("Word")])
        XCTAssertEqual(suggestions.first { $0.pair.written == "Claude" }?.applications, ["Slack"])

        var dismissed = dictionary
        DictionaryLearning.dismiss(suggestions[0], in: &dismissed)
        XCTAssertEqual(DictionaryLearning.suggestions(observations: observations, dictionary: dismissed, readOnly: []).count, 1)
    }
}

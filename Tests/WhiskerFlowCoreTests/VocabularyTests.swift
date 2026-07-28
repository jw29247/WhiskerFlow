import XCTest
@testable import WhiskerFlowCore

final class VocabularyTests: XCTestCase {
    func testWholeWordCaseInsensitiveReplacement() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "clawd", replaceWith: "Claude")])
        XCTAssertEqual(vocab.apply(to: "I asked clawd and Clawd."), "I asked Claude and Claude.")
    }

    func testWholeWordDoesNotMatchInsideOtherWords() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "cat", replaceWith: "dog")])
        XCTAssertEqual(vocab.apply(to: "the category cat"), "the category dog")
    }

    func testWholeWordReplacementMatchesTermEndingInSymbols() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "C++", replaceWith: "C plus plus")])
        XCTAssertEqual(vocab.apply(to: "I use C++ daily"), "I use C plus plus daily")
    }

    func testCaseSensitiveRuleRespectsCase() {
        let vocab = Vocabulary(rules: [
            VocabularyRule(find: "Swift", replaceWith: "Swift🦅", caseSensitive: true)
        ])
        XCTAssertEqual(vocab.apply(to: "swift Swift"), "swift Swift🦅")
    }

    func testRulesApplyInOrder() {
        let vocab = Vocabulary(rules: [
            VocabularyRule(find: "a", replaceWith: "b", wholeWord: true),
            VocabularyRule(find: "b", replaceWith: "c", wholeWord: true)
        ])
        XCTAssertEqual(vocab.apply(to: "a b"), "c c")
    }

    func testReplacementTextIsTreatedLiterally() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "x", replaceWith: "$1&")])
        XCTAssertEqual(vocab.apply(to: "x"), "$1&")
    }

    // MARK: - Tolerant decoding (hand-authored shared glossary)

    func testDecodesTerseRuleWithoutIdOrFlags() throws {
        let json = #"{ "rules": [ { "find": "acme co", "replaceWith": "ACME Corporation" } ] }"#
        let vocab = try JSONDecoder().decode(Vocabulary.self, from: Data(json.utf8))
        XCTAssertEqual(vocab.rules.count, 1)
        let rule = try XCTUnwrap(vocab.rules.first)
        XCTAssertEqual(rule.find, "acme co")
        XCTAssertEqual(rule.replaceWith, "ACME Corporation")
        XCTAssertFalse(rule.caseSensitive)   // defaults
        XCTAssertTrue(rule.wholeWord)
        XCTAssertEqual(vocab.apply(to: "we met acme co today"), "we met ACME Corporation today")
    }

    func testDecodingFailsWhenRequiredFieldsMissing() {
        let json = #"{ "rules": [ { "replaceWith": "X" } ] }"#
        XCTAssertThrowsError(try JSONDecoder().decode(Vocabulary.self, from: Data(json.utf8)))
    }

    // MARK: - Shared + personal merge

    func testEffectiveAppliesSharedThenPersonal() {
        let shared = Vocabulary(rules: [VocabularyRule(find: "clawd", replaceWith: "Claude")])
        let personal = Vocabulary(rules: [VocabularyRule(find: "foo", replaceWith: "bar")])
        let effective = Vocabulary.effective(shared: shared, personal: personal)
        XCTAssertEqual(effective.apply(to: "clawd foo"), "Claude bar")
    }

    func testPersonalRuleOverridesSharedOnSameFind() {
        let shared = Vocabulary(rules: [VocabularyRule(find: "acme", replaceWith: "ACME Corp")])
        let personal = Vocabulary(rules: [VocabularyRule(find: "Acme", replaceWith: "Acme Inc")])
        let effective = Vocabulary.effective(shared: shared, personal: personal)
        // The shared "acme" rule is dropped (case-insensitive match), personal wins.
        XCTAssertEqual(effective.rules.count, 1)
        XCTAssertEqual(effective.apply(to: "acme"), "Acme Inc")
    }

    func testEffectiveIgnoresBlankPersonalFindsForOverride() {
        let shared = Vocabulary(rules: [VocabularyRule(find: "clawd", replaceWith: "Claude")])
        let personal = Vocabulary(rules: [VocabularyRule(find: "", replaceWith: "")])
        let effective = Vocabulary.effective(shared: shared, personal: personal)
        // A blank personal row must not wipe out shared rules.
        XCTAssertEqual(effective.apply(to: "clawd"), "Claude")
    }

    // MARK: - Case preservation

    func testCapitalisationIsPreservedAtSentenceStart() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "gonna", replaceWith: "going to")])
        XCTAssertEqual(vocab.apply(to: "Gonna go"), "Going to go")
    }

    func testMidSentenceMatchKeepsLowercaseReplacement() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "gonna", replaceWith: "going to")])
        XCTAssertEqual(vocab.apply(to: "I'm gonna go"), "I'm going to go")
    }

    func testMixedCaseOccurrencesAreAdjustedIndependently() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "gonna", replaceWith: "going to")])
        XCTAssertEqual(vocab.apply(to: "Gonna wait. gonna go."), "Going to wait. going to go.")
    }

    func testCaseSensitiveRuleIsNeverAdjusted() {
        let vocab = Vocabulary(rules: [
            VocabularyRule(find: "Gonna", replaceWith: "going to", caseSensitive: true)
        ])
        XCTAssertEqual(vocab.apply(to: "Gonna go"), "going to go")
    }

    func testUppercaseLedReplacementIsNeverAdjusted() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "clawd", replaceWith: "Claude")])
        XCTAssertEqual(vocab.apply(to: "clawd Clawd"), "Claude Claude")
    }

    func testMidSentenceCapitalisedMatchDoesNotGainACapital() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "cx", replaceWith: "customer experience")])
        XCTAssertEqual(vocab.apply(to: "The CX team shipped it"), "The customer experience team shipped it")
        XCTAssertEqual(vocab.apply(to: "CX is the team"), "Customer experience is the team")
    }

    func testReplacementThatSpellsItsOwnCasingIsNeverRewritten() {
        let brands = Vocabulary(rules: [
            VocabularyRule(find: "ebay", replaceWith: "eBay"),
            VocabularyRule(find: "iphone", replaceWith: "iPhone")
        ])
        // A brand rule that can never emit its own spelling is worse than no rule.
        XCTAssertEqual(brands.apply(to: "Ebay listings are up"), "eBay listings are up")
        XCTAssertEqual(brands.apply(to: "IPhone and Iphone"), "iPhone and iPhone")
    }

    func testSentenceStartIsRecognisedAfterEveryTerminator() {
        let vocab = Vocabulary(rules: [VocabularyRule(find: "gonna", replaceWith: "going to")])
        XCTAssertEqual(vocab.apply(to: "Wait! Gonna go"), "Wait! Going to go")
        XCTAssertEqual(vocab.apply(to: "Ready? Gonna go"), "Ready? Going to go")
        XCTAssertEqual(vocab.apply(to: "Ready,\nGonna go"), "Ready,\nGoing to go")
        XCTAssertEqual(vocab.apply(to: "Ready, Gonna go"), "Ready, going to go")
    }

    func testPossibleReplacementsReportsWhatARuleCanInsert() {
        XCTAssertEqual(
            VocabularyRule(find: "gonna", replaceWith: "going to").possibleReplacements,
            ["going to", "Going to"]
        )
        XCTAssertEqual(
            VocabularyRule(find: "ebay", replaceWith: "eBay").possibleReplacements,
            ["eBay"]
        )
        XCTAssertEqual(
            VocabularyRule(find: "gonna", replaceWith: "going to", caseSensitive: true)
                .possibleReplacements,
            ["going to"]
        )
    }

    // MARK: - CompiledVocabulary reuse

    func testCompiledVocabularyIsStableAcrossRepeatedApplication() {
        let compiled = CompiledVocabulary(Vocabulary(rules: [
            VocabularyRule(find: "clawd", replaceWith: "Claude"),
            VocabularyRule(find: "gonna", replaceWith: "going to"),
            VocabularyRule(find: "C++", replaceWith: "C plus plus"),
            VocabularyRule(find: "", replaceWith: "skipped")
        ]))
        for _ in 0..<100 {
            XCTAssertEqual(
                compiled.apply(to: "Gonna ask clawd about C++"),
                "Going to ask Claude about C plus plus"
            )
        }
    }

    func testCompiledVocabularyMatchesVocabularyApply() {
        let vocab = Vocabulary(rules: [
            VocabularyRule(find: "x", replaceWith: "$1&"),
            VocabularyRule(find: "cat", replaceWith: "dog")
        ])
        let compiled = CompiledVocabulary(vocab)
        XCTAssertEqual(compiled.apply(to: "x the category cat"), vocab.apply(to: "x the category cat"))
    }
}

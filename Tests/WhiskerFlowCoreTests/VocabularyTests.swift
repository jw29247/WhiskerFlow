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
}

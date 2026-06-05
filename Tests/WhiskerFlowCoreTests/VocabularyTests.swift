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
}

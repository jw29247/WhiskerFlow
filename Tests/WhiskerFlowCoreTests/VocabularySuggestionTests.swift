import XCTest
@testable import WhiskerFlowCore

final class VocabularySuggestionTests: XCTestCase {
    func testSingleWordCaseFixIsSuggested() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we onboarded velia as a client last week",
            edited: "we onboarded Velia as a client last week"
        )
        XCTAssertEqual(suggestions, [VocabularyCorrection(find: "velia", replaceWith: "Velia")])
    }

    func testSingleWordMisrecognitionIsSuggested() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we spoke with clawd about the roadmap this morning",
            edited: "we spoke with Claude about the roadmap this morning"
        )
        XCTAssertEqual(suggestions, [VocabularyCorrection(find: "clawd", replaceWith: "Claude")])
    }

    func testMultiWordPhraseReplacementIsSuggested() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped the terma velia update last week",
            edited: "we shipped the Terma Velia update last week"
        )
        XCTAssertEqual(
            suggestions,
            [VocabularyCorrection(find: "terma velia", replaceWith: "Terma Velia")]
        )
    }

    func testPunctuationAdjacentTokenIsSuggestedWithoutPunctuation() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "the invoice went to terma velia, then to legal for approval yesterday",
            edited: "the invoice went to Terma Velia, then to legal for approval yesterday"
        )
        XCTAssertEqual(
            suggestions,
            [VocabularyCorrection(find: "terma velia", replaceWith: "Terma Velia")]
        )
    }

    func testPunctuationOnlyEditSuggestsNothing() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped the update last week and told the client",
            edited: "we shipped the update last week, and told the client."
        )
        XCTAssertEqual(suggestions, [])
    }

    func testPureInsertionSuggestsNothing() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped the terma velia update last week",
            edited: "we shipped the terma velia update last week on time"
        )
        XCTAssertEqual(suggestions, [])
    }

    func testPureDeletionSuggestsNothing() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped the terma velia update last week",
            edited: "we shipped the terma velia update"
        )
        XCTAssertEqual(suggestions, [])
    }

    func testFullRewriteSuggestsNothing() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped the terma velia update last week",
            edited: "the client meeting has been moved to thursday morning"
        )
        XCTAssertEqual(suggestions, [])
    }

    func testDigitOnlyChangeSuggestsNothing() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped 15 units on friday to the warehouse in leeds",
            edited: "we shipped 50 units on friday to the warehouse in leeds"
        )
        XCTAssertEqual(suggestions, [])
    }

    func testEmptyInputSuggestsNothing() {
        XCTAssertEqual(VocabularyCorrectionDetector.corrections(original: "", edited: "hello"), [])
        XCTAssertEqual(VocabularyCorrectionDetector.corrections(original: "hello", edited: ""), [])
    }

    func testExistingRuleSuppressesDuplicateSuggestion() {
        let existing = Vocabulary(rules: [
            VocabularyRule(find: "terma velia", replaceWith: "Terma Velia")
        ])
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped the terma velia update last week",
            edited: "we shipped the Terma Velia update last week",
            existingRules: existing
        )
        XCTAssertEqual(suggestions, [])
    }

    func testExistingUnrelatedRuleDoesNotSuppressSuggestion() {
        let existing = Vocabulary(rules: [VocabularyRule(find: "clawd", replaceWith: "Claude")])
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "we shipped the terma velia update last week",
            edited: "we shipped the Terma Velia update last week",
            existingRules: existing
        )
        XCTAssertEqual(
            suggestions,
            [VocabularyCorrection(find: "terma velia", replaceWith: "Terma Velia")]
        )
    }

    func testSuggestionsAreCappedAtMaxSuggestions() {
        let original = "we asked clawd about velia and swyft and terma before the review meeting started on monday morning with the whole team"
        let edited = "we asked Claude about Velia and Swyft and Terma before the review meeting started on monday morning with the whole team"

        XCTAssertEqual(
            VocabularyCorrectionDetector.corrections(original: original, edited: edited),
            [
                VocabularyCorrection(find: "clawd", replaceWith: "Claude"),
                VocabularyCorrection(find: "velia", replaceWith: "Velia"),
                VocabularyCorrection(find: "swyft", replaceWith: "Swyft")
            ]
        )
        XCTAssertEqual(
            VocabularyCorrectionDetector.corrections(
                original: original,
                edited: edited,
                maxSuggestions: 1
            ),
            [VocabularyCorrection(find: "clawd", replaceWith: "Claude")]
        )
    }

    /// A one-word fix in a long transcript must not build an O(n*m) table: the shared
    /// head and tail are matched off first, so only the disagreement is aligned.
    func testCorrectionInALongTranscriptIsStillFoundQuickly() {
        let filler = Array(repeating: "the client asked for it that way", count: 400).joined(separator: " ")
        let started = Date()
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "\(filler) we spoke with clawd \(filler)",
            edited: "\(filler) we spoke with Claude \(filler)"
        )

        XCTAssertEqual(suggestions, [VocabularyCorrection(find: "clawd", replaceWith: "Claude")])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testWholesaleRewriteOfALongTranscriptSuggestsNothing() {
        let original = Array(repeating: "alpha bravo charlie delta", count: 400).joined(separator: " ")
        let edited = Array(repeating: "echo foxtrot golf hotel", count: 400).joined(separator: " ")
        let started = Date()

        XCTAssertEqual(VocabularyCorrectionDetector.corrections(original: original, edited: edited), [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testLongRunIsNotSuggested() {
        let suggestions = VocabularyCorrectionDetector.corrections(
            original: "the report says we should ship on friday because the client asked for it that way",
            edited: "the report says we must get it out by friday because the client asked for it that way"
        )
        XCTAssertEqual(suggestions, [])
    }
}

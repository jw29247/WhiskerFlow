import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

final class GlossaryLintTests: XCTestCase {
    private func flags(_ find: String, _ replaceWith: String = "Brand") -> [GlossaryLintFlag] {
        GlossaryLint.flags(for: VocabularyRule(find: find, replaceWith: replaceWith))
    }

    private func cascades(_ rules: [VocabularyRule]) -> [GlossaryLintFlag] {
        GlossaryLint.flags(for: Vocabulary(rules: rules)).filter { !$0.rewritesEverydaySpeech }
    }

    func testSingleCommonWordIsFlagged() {
        XCTAssertEqual(flags("cleans"), [.commonWord(find: "cleans")])
        XCTAssertEqual(flags("water"), [.commonWord(find: "water")])
        XCTAssertEqual(flags("Travel"), [.commonWord(find: "Travel")])
        XCTAssertEqual(flags("a"), [.commonWord(find: "a")])
    }

    func testInventedWordIsNotFlagged() {
        XCTAssertTrue(flags("cleens").isEmpty)
        XCTAssertTrue(flags("kleens").isEmpty)
        XCTAssertTrue(flags("comfybedss").isEmpty)
        XCTAssertTrue(flags("travlfi").isEmpty)
        XCTAssertTrue(flags("water2").isEmpty)
    }

    func testPhraseOfCommonWordsIsFlagged() {
        XCTAssertEqual(flags("be perfect"), [.commonPhrase(find: "be perfect")])
        XCTAssertEqual(flags("comfy beds"), [.commonPhrase(find: "comfy beds")])
        XCTAssertEqual(flags("travel fee"), [.commonPhrase(find: "travel fee")])
        XCTAssertEqual(flags("travel wifi"), [.commonPhrase(find: "travel wifi")])
        XCTAssertEqual(flags("water two"), [.commonPhrase(find: "water two")])
    }

    func testPhraseWithOneUncommonTokenIsNotFlagged() {
        XCTAssertTrue(flags("travel fi").isEmpty)
        XCTAssertTrue(flags("viva man").isEmpty)
        XCTAssertTrue(flags("manuka ora").isEmpty)
        XCTAssertTrue(flags("b perfect").isEmpty)
    }

    func testTokenWithDigitKeepsPhraseUnflagged() {
        XCTAssertTrue(flags("water 2").isEmpty)
    }

    func testEmptyFindIsNotFlagged() {
        XCTAssertTrue(flags("").isEmpty)
    }

    func testCascadeHazardIsFlagged() {
        XCTAssertEqual(
            cascades([
                VocabularyRule(find: "a", replaceWith: "b"),
                VocabularyRule(find: "b", replaceWith: "c")
            ]),
            [.cascadeHazard(find: "a", replaceWith: "b", matchedBy: "b")]
        )
    }

    func testCascadeHazardIgnoresEarlierRules() {
        XCTAssertTrue(
            cascades([
                VocabularyRule(find: "b", replaceWith: "c"),
                VocabularyRule(find: "a", replaceWith: "b")
            ]).isEmpty
        )
    }

    func testCascadeHazardRespectsWordBoundaries() {
        XCTAssertTrue(
            cascades([
                VocabularyRule(find: "comfybedss", replaceWith: "Comfybedss"),
                VocabularyRule(find: "comfybeds", replaceWith: "Comfybedss")
            ]).isEmpty
        )
    }

    func testCascadeHazardFollowsSubstringRuleWithoutWholeWord() {
        XCTAssertEqual(
            cascades([
                VocabularyRule(find: "otti", replaceWith: "Otty"),
                VocabularyRule(find: "tt", replaceWith: "TT", wholeWord: false)
            ]),
            [.cascadeHazard(find: "otti", replaceWith: "Otty", matchedBy: "tt")]
        )
    }

    func testCasingOnlyRuleOfCommonWordsIsNotDropped() {
        // "sleep number" -> "Sleep Number" cannot change what a transcript says, so
        // the sanitizer must not discard it on every installed machine.
        XCTAssertTrue(flags("sleep number", "Sleep Number").isEmpty)
        XCTAssertTrue(flags("one water", "One Water").isEmpty)
        XCTAssertEqual(flags("sleep number", "Bed Brand"), [.commonPhrase(find: "sleep number")])
    }

    /// The lint's job is to catch a cascade the runtime really performs, so it has to
    /// consider the capitalised replacement a case-insensitive rule emits at a
    /// sentence start — checking only the literal `replaceWith` misses it entirely.
    func testCascadeThroughACapitalisedReplacementIsFlagged() {
        let rules = [
            VocabularyRule(find: "gonna", replaceWith: "going to"),
            VocabularyRule(find: "Going to", replaceWith: "GOING TO", caseSensitive: true)
        ]

        XCTAssertEqual(
            cascades(rules),
            [.cascadeHazard(find: "gonna", replaceWith: "going to", matchedBy: "Going to")]
        )
        // And the runtime really does cascade, which is what makes the flag correct.
        XCTAssertEqual(Vocabulary(rules: rules).apply(to: "Gonna ship"), "GOING TO ship")
    }

    func testVocabularyFlagsIncludePerRuleFlags() {
        let vocabulary = Vocabulary(rules: [
            VocabularyRule(find: "cleens", replaceWith: "Cleens"),
            VocabularyRule(find: "cleans", replaceWith: "Cleens")
        ])
        XCTAssertEqual(GlossaryLint.flags(for: vocabulary), [.commonWord(find: "cleans")])
    }

    func testSanitizingDecodeDropsCommonWordRuleAndKeepsVariant() throws {
        let payload = try JSONEncoder().encode(Vocabulary(rules: [
            VocabularyRule(find: "cleens", replaceWith: "Cleens"),
            VocabularyRule(find: "cleans", replaceWith: "Cleens"),
            VocabularyRule(find: "travel fee", replaceWith: "Travlfi")
        ]))
        let report = try AgencyVocabularyPolicy.decodeReport(payload)
        XCTAssertEqual(report.droppedRuleCount, 2)
        XCTAssertEqual(report.vocabulary.rules.map(\.find), ["cleens"])
        XCTAssertEqual(try AgencyVocabularyPolicy.decode(payload).rules.map(\.find), ["cleens"])
    }
}

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
        XCTAssertEqual(flags("quick"), [.commonWord(find: "quick")])
        XCTAssertEqual(flags("coffee"), [.commonWord(find: "coffee")])
        XCTAssertEqual(flags("Hotel"), [.commonWord(find: "Hotel")])
        XCTAssertEqual(flags("a"), [.commonWord(find: "a")])
    }

    func testInventedWordIsNotFlagged() {
        XCTAssertTrue(flags("kwick").isEmpty)
        XCTAssertTrue(flags("qwick").isEmpty)
        XCTAssertTrue(flags("cosyroomss").isEmpty)
        XCTAssertTrue(flags("hotlfi").isEmpty)
        XCTAssertTrue(flags("coffee2").isEmpty)
    }

    func testPhraseOfCommonWordsIsFlagged() {
        XCTAssertEqual(flags("be ready"), [.commonPhrase(find: "be ready")])
        XCTAssertEqual(flags("cosy rooms"), [.commonPhrase(find: "cosy rooms")])
        XCTAssertEqual(flags("hotel fee"), [.commonPhrase(find: "hotel fee")])
        XCTAssertEqual(flags("hotel wifi"), [.commonPhrase(find: "hotel wifi")])
        XCTAssertEqual(flags("coffee two"), [.commonPhrase(find: "coffee two")])
    }

    func testPhraseWithOneUncommonTokenIsNotFlagged() {
        XCTAssertTrue(flags("hotel fi").isEmpty)
        XCTAssertTrue(flags("sola man").isEmpty)
        XCTAssertTrue(flags("lumara ova").isEmpty)
        XCTAssertTrue(flags("b ready").isEmpty)
    }

    func testTokenWithDigitKeepsPhraseUnflagged() {
        XCTAssertTrue(flags("coffee 2").isEmpty)
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
                VocabularyRule(find: "cosyroomss", replaceWith: "Cosyroomss"),
                VocabularyRule(find: "cosyrooms", replaceWith: "Cosyroomss")
            ]).isEmpty
        )
    }

    func testCascadeHazardFollowsSubstringRuleWithoutWholeWord() {
        XCTAssertEqual(
            cascades([
                VocabularyRule(find: "itti", replaceWith: "Itty"),
                VocabularyRule(find: "tt", replaceWith: "TT", wholeWord: false)
            ]),
            [.cascadeHazard(find: "itti", replaceWith: "Itty", matchedBy: "tt")]
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
            VocabularyRule(find: "kwick", replaceWith: "Kwick"),
            VocabularyRule(find: "quick", replaceWith: "Kwick")
        ])
        XCTAssertEqual(GlossaryLint.flags(for: vocabulary), [.commonWord(find: "quick")])
    }

    func testSanitizingDecodeDropsCommonWordRuleAndKeepsVariant() throws {
        let payload = try JSONEncoder().encode(Vocabulary(rules: [
            VocabularyRule(find: "kwick", replaceWith: "Kwick"),
            VocabularyRule(find: "quick", replaceWith: "Kwick"),
            VocabularyRule(find: "hotel fee", replaceWith: "Hotlfi")
        ]))
        let report = try AgencyVocabularyPolicy.decodeReport(payload)
        XCTAssertEqual(report.droppedRuleCount, 2)
        XCTAssertEqual(report.vocabulary.rules.map(\.find), ["kwick"])
        XCTAssertEqual(try AgencyVocabularyPolicy.decode(payload).rules.map(\.find), ["kwick"])
    }
}

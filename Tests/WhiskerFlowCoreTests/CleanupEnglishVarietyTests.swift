import Foundation
import XCTest
@testable import WhiskerFlowCore

final class CleanupEnglishVarietyTests: XCTestCase {
    func testDefaultFollowsTheMacsRegion() {
        for region in ["GB", "IE", "AU", "NZ", "IN", "ZA", "gb"] {
            XCTAssertEqual(CleanupEnglishVariety.default(forRegion: region), .british, region)
        }
        for region in ["US", "us", "PR"] {
            XCTAssertEqual(CleanupEnglishVariety.default(forRegion: region), .american, region)
        }
        // Anywhere else keeps the British spelling Cleanup has always used.
        for region in ["DE", "CA", "FR", "JP", "001"] {
            XCTAssertEqual(CleanupEnglishVariety.default(forRegion: region), .british, region)
        }
        XCTAssertEqual(CleanupEnglishVariety.default(forRegion: nil), .british)
    }

    /// One transcript per prompt branch: explicit repair, misheard opening, general.
    private let transcripts = [
        "I want to do that on Wednesday, no, Thursday at 8 p.m., no, 10 PM.",
        "And you set a reminder for tomorrow.",
        "Please organize the color samples for the center.",
        "This is fucking shit, and I'm not going to pretend it isn't.",
    ]

    func testBritishPromptIsTheDefault() {
        for transcript in transcripts {
            let prompt = TranscriptCleanup.prompt(for: transcript)
            XCTAssertEqual(prompt, TranscriptCleanup.prompt(for: transcript, variety: .british))
            XCTAssertEqual(prompt.components(separatedBy: "Use British English.").count, 2, transcript)
            XCTAssertFalse(prompt.contains("American"))
        }
    }

    func testAmericanPromptDiffersOnlyInTheVarietyWord() {
        for transcript in transcripts {
            let british = TranscriptCleanup.prompt(for: transcript, variety: .british)
            let american = TranscriptCleanup.prompt(for: transcript, variety: .american)
            XCTAssertEqual(american.components(separatedBy: "Use American English.").count, 2, transcript)
            XCTAssertFalse(american.contains("British"))
            XCTAssertEqual(american.replacingOccurrences(of: "Use American English.", with: "Use British English."), british)
            // "American" is one character longer than "British" and no extra words.
            XCTAssertEqual(american.count, british.count + 1)
        }
    }

    func testOtherLanguagesAreStillKeptForEitherVariety() {
        for variety in CleanupEnglishVariety.allCases {
            XCTAssertTrue(TranscriptCleanup.prompt(for: "Bitte sende die Datei morgen.", variety: variety)
                .contains("Keep other languages in their original language."))
        }
    }

    func testAcceptanceChecksAllowEitherSpellingAndStillProtectFacts() {
        XCTAssertEqual(TranscriptCleanup.accepted("Please organize the color samples for the center.",
                                                 original: "Please organise the colour samples for the centre."),
                       "Please organize the color samples for the center.")
        XCTAssertEqual(TranscriptCleanup.accepted("It is 1.05 meters.", original: "It is one point zero five meters."), "It is 1.05 meters.")
        // Spelling freedom never extends to names, numbers or amounts.
        XCTAssertNil(TranscriptCleanup.accepted("Send it to Sara.", original: "Send it to Sarah."))
        XCTAssertNil(TranscriptCleanup.accepted("We need 51 copies.", original: "We need fifty copies."))
        XCTAssertNil(TranscriptCleanup.accepted("Sam owes $17.50.", original: "Sam owes seventeen pounds fifty."))
    }

    private struct Fixture: Decodable {
        let id: String
        let input: String
        let expected: String
        let rules: [VocabularyRule]?
        let prompt: String?
        /// Decoded rules get fresh IDs, so compare what they do.
        var ruleContent: [String] { (rules ?? []).map { "\($0.find)→\($0.replaceWith) \($0.caseSensitive) \($0.wholeWord)" } }
        var content: [String] { [id, input, expected, prompt ?? ""] + ruleContent }
    }

    private func fixtures(_ name: String) throws -> [Fixture] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("script/\(name)")))
    }

    /// The American set is the British set with only the spelling cases changed.
    func testAmericanFixturesMirrorTheBritishFixtures() throws {
        let british = try fixtures("cleanup_fixtures.json")
        let american = try fixtures("cleanup_fixtures_american.json")
        XCTAssertEqual(british.count, american.count)
        var changed: [String] = []
        for (gb, us) in zip(british, american) {
            XCTAssertEqual(gb.ruleContent, us.ruleContent, gb.id)
            guard gb.content != us.content else { continue }
            changed.append(gb.id)
            XCTAssertNil(gb.prompt)
            XCTAssertNil(us.prompt)
        }
        XCTAssertEqual(changed, ["british-spelling", "asr-small-word", "spoken-decimal"])
        let spelling = try XCTUnwrap(american.first { $0.id == "american-spelling" })
        XCTAssertEqual(spelling.expected, "Please organize the color samples for the center.")
        XCTAssertTrue(british.contains { $0.expected == "Please organise the colour samples for the centre." })
    }

    /// Every expected answer that the checks accept for British is accepted for
    /// American too: the checks don't favour one variety.
    func testAcceptanceChecksTreatBothFixtureSetsAlike() throws {
        func acceptedIDs(_ set: [Fixture]) -> [String] {
            set.filter {
                let vocabulary = Vocabulary(rules: $0.rules ?? [])
                return $0.expected == $0.input || TranscriptCleanup.accepted($0.expected, original: $0.input, vocabulary: vocabulary) == $0.expected
            }.map { $0.id == "american-spelling" ? "british-spelling" : $0.id }
        }
        let british = try acceptedIDs(fixtures("cleanup_fixtures.json"))
        let american = try acceptedIDs(fixtures("cleanup_fixtures_american.json"))
        XCTAssertEqual(british, american)
        for id in ["british-spelling", "asr-small-word", "spoken-decimal"] {
            XCTAssertTrue(british.contains(id), id)
        }
    }
}

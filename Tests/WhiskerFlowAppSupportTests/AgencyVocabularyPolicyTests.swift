import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

/// The glossary's rules are maintained and validated in Atlas; these cover what
/// this app does with whatever it downloads. Fixtures use invented words only.
final class AgencyVocabularyPolicyTests: XCTestCase {
    private func payload(_ rules: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["rules": rules])
    }

    func testOversizedPayloadIsRejected() {
        XCTAssertThrowsError(
            try AgencyVocabularyPolicy.decode(Data(repeating: 0, count: 256 * 1024 + 1))
        ) { XCTAssertEqual($0 as? AgencyVocabularyError, .payloadTooLarge) }
    }

    func testMalformedPayloadIsRejected() throws {
        for data in [Data("not json".utf8), try JSONSerialization.data(withJSONObject: ["rules": "nope"]),
                     try payload([["find": "zorblat"]])] {
            XCTAssertThrowsError(try AgencyVocabularyPolicy.decodeReport(data)) {
                XCTAssertEqual($0 as? AgencyVocabularyError, .invalidPayload)
            }
        }
    }

    func testDecodesRulesWithDefaultsAndIgnoresUnknownFields() throws {
        let report = try AgencyVocabularyPolicy.decodeReport(try payload([
            ["find": "zorblat", "replaceWith": "Zorblat", "owner": "ops"],
            ["find": "Quindle", "replaceWith": "QUINDLE", "caseSensitive": true, "wholeWord": false]
        ]))

        XCTAssertEqual(report.droppedRuleCount, 0)
        let rules = report.vocabulary.rules
        XCTAssertEqual(rules.map(\.find), ["zorblat", "Quindle"])
        XCTAssertEqual(rules.map(\.replaceWith), ["Zorblat", "QUINDLE"])
        XCTAssertEqual(rules.map(\.caseSensitive), [false, true])
        XCTAssertEqual(rules.map(\.wholeWord), [true, false])
    }

    func testEmptyGlossaryDecodesToNoRules() throws {
        let report = try AgencyVocabularyPolicy.decodeReport(try payload([]))
        XCTAssertEqual(report, AgencyVocabularyDecodeReport(vocabulary: Vocabulary(rules: []), droppedRuleCount: 0))
    }

    func testRulesThatRewriteEverydaySpeechAreDroppedAndCounted() throws {
        let report = try AgencyVocabularyPolicy.decodeReport(try payload([
            ["find": "vexmoor", "replaceWith": "Vexmoor"],
            ["find": "water", "replaceWith": "Vexmoor"],
            ["find": "hot water", "replaceWith": "Frobnitz"],
            ["find": "frob nitz", "replaceWith": "Frobnitz"]
        ]))

        XCTAssertEqual(report.droppedRuleCount, 2)
        XCTAssertEqual(report.vocabulary.rules.map(\.find), ["vexmoor", "frob nitz"])
        // The convenience decode applies the same sanitising.
        XCTAssertEqual(try AgencyVocabularyPolicy.decode(try payload([
            ["find": "water", "replaceWith": "Vexmoor"]
        ])).rules, [])
    }

    func testCasingOnlyRulesOfEverydayWordsAreKept() throws {
        let report = try AgencyVocabularyPolicy.decodeReport(try payload([
            ["find": "green table", "replaceWith": "Green Table"]
        ]))
        XCTAssertEqual(report.droppedRuleCount, 0)
        XCTAssertEqual(report.vocabulary.rules.map(\.replaceWith), ["Green Table"])
    }
}

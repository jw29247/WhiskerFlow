import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

final class AgencyVocabularyPolicyTests: XCTestCase {
    private func data(_ replacement: String) -> Data {
        try! JSONEncoder().encode(Vocabulary(rules: [
            VocabularyRule(find: "heard", replaceWith: replacement)
        ]))
    }

    func testValidCacheTakesPrecedenceOverBundledSeed() throws {
        let vocabulary = try AgencyVocabularyPolicy.initialVocabulary(
            cache: data("cached"),
            seed: data("seed")
        )
        XCTAssertEqual(vocabulary.rules.first?.replaceWith, "cached")
    }

    func testInvalidCacheFallsBackToBundledSeed() throws {
        let vocabulary = try AgencyVocabularyPolicy.initialVocabulary(
            cache: Data("not-json".utf8),
            seed: data("seed")
        )
        XCTAssertEqual(vocabulary.rules.first?.replaceWith, "seed")
    }

    func testOversizedPayloadIsRejected() {
        XCTAssertThrowsError(
            try AgencyVocabularyPolicy.decode(Data(repeating: 0, count: 256 * 1024 + 1))
        )
    }
}

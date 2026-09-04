import XCTest
@testable import WhiskerFlowAppSupport

final class AgencyVocabularyPolicyTests: XCTestCase {
    func testOversizedPayloadIsRejected() {
        XCTAssertThrowsError(
            try AgencyVocabularyPolicy.decode(Data(repeating: 0, count: 256 * 1024 + 1))
        )
    }
}

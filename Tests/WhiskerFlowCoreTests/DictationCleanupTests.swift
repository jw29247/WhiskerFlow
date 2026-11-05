import XCTest
@testable import WhiskerFlowCore

final class DictationCleanupTests: XCTestCase {
    func testEmptyAndExcessiveInputsAreSkipped() {
        XCTAssertFalse(DictationCleanupRequest(text: " \n ").isEligible)
        XCTAssertFalse(DictationCleanupRequest(text: String(repeating: "あ", count: 2001)).isEligible)
        XCTAssertTrue(DictationCleanupRequest(text: "send the notes on Tuesday sorry Thursday").isEligible)
    }

    func testRejectsEmptyAndObviousModelArtifacts() {
        let request = DictationCleanupRequest(text: "send the notes")
        for output in ["", "   ", "```text\nsend the notes\n```", "<|channel>thought", "Here is the cleaned transcript: Send the notes.", String(repeating: "a", count: 513)] {
            XCTAssertNil(request.validated(output))
        }
        XCTAssertEqual(request.validated(" \nSend the notes.\n"), "Send the notes.")
    }

}

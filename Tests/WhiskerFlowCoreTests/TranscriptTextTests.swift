import XCTest
@testable import WhiskerFlowCore

final class TranscriptTextTests: XCTestCase {
    func testPlainTranscriptTextCollapsesLineBreaksAndSpacing() {
        let text = "Hello,\n\nworld.  This\tis\nWhiskerFlow."

        XCTAssertEqual(text.plainTranscriptText, "Hello, world. This is WhiskerFlow.")
    }
}

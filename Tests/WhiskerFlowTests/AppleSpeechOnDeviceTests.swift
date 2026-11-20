import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

final class AppleSpeechOnDeviceTests: XCTestCase {
    func testRecognitionProceedsWhenTheLanguageRunsOnThisMac() {
        XCTAssertNoThrow(try AppleSpeechEngine.requireOnDeviceRecognition(supported: true))
    }

    func testRecognitionIsRefusedRatherThanSentToApple() {
        XCTAssertThrowsError(try AppleSpeechEngine.requireOnDeviceRecognition(supported: false)) { error in
            XCTAssertEqual(error as? TranscriptionError, .onDeviceRecognitionUnavailable)
        }
    }
}

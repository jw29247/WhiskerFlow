import XCTest
@testable import WhiskerFlowAppSupport

final class CapturedAudioTests: XCTestCase {
    func testDefaultsToNoConversionFailures() {
        let captured = CapturedAudio(samples: [0.1, 0.2], stopReason: .userReleased)

        XCTAssertEqual(captured.conversionFailureCount, 0)
        XCTAssertFalse(captured.reportsUnusableInput)
    }

    func testEmptyCaptureWithFailuresReportsUnusableInput() {
        let captured = CapturedAudio(
            samples: [],
            stopReason: .userReleased,
            conversionFailureCount: 12
        )

        XCTAssertTrue(captured.reportsUnusableInput)
    }

    func testEmptyCaptureWithoutFailuresIsJustSilence() {
        let captured = CapturedAudio(samples: [], stopReason: .userReleased)

        XCTAssertFalse(captured.reportsUnusableInput)
    }

    func testPartialCaptureWithFailuresIsNotUnusable() {
        let captured = CapturedAudio(
            samples: [0.3],
            stopReason: .deviceDisconnected,
            conversionFailureCount: 4
        )

        XCTAssertFalse(captured.reportsUnusableInput)
    }
}

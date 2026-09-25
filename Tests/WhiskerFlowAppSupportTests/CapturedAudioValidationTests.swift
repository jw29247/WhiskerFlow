import XCTest
@testable import WhiskerFlowAppSupport

final class CapturedAudioValidationTests: XCTestCase {
    func testEmptyCaptureIsDiscarded() {
        XCTAssertEqual(
            CapturedAudioValidation.discardReason(totalSampleCount: 0, residentSamples: []),
            .empty
        )
    }

    func testAudibleCaptureShorterThanEngineMinimumIsDiscarded() {
        let samples = [Float](repeating: 0.1, count: CapturedAudioValidation.minimumSampleCount - 1)

        XCTAssertEqual(
            CapturedAudioValidation.discardReason(
                totalSampleCount: samples.count,
                residentSamples: samples
            ),
            .tooShort
        )
    }

    func testCompleteSilentCaptureIsDiscardedAsSilence() {
        let samples = [Float](repeating: 0.001, count: 12_800)

        XCTAssertEqual(
            CapturedAudioValidation.discardReason(
                totalSampleCount: samples.count,
                residentSamples: samples
            ),
            .silent
        )
    }

    func testLongCaptureWithOnlyResidentTailIsRetained() {
        let residentSamples = [Float](repeating: 0, count: 16_000)

        XCTAssertNil(
            CapturedAudioValidation.discardReason(
                totalSampleCount: 16_000 * 60,
                residentSamples: residentSamples
            )
        )
    }

    func testEmptyDeviceInterruptionIsDismissed() {
        XCTAssertTrue(
            CapturedAudioValidation.shouldDismissEmptyDeviceInterruption(
                stopReason: .deviceDisconnected,
                totalSampleCount: 0
            )
        )
    }

    func testEmptyUserReleaseWithConversionFailuresRemainsActionable() {
        XCTAssertFalse(
            CapturedAudioValidation.shouldDismissEmptyDeviceInterruption(
                stopReason: .userReleased,
                totalSampleCount: 0
            )
        )
    }
}

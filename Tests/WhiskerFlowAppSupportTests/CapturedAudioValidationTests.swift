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

    /// A soft speaker (about -42 dBFS RMS) is quieter than the old whole-second
    /// floor but is real speech; its audio must reach the recognizer.
    func testQuietSpeechIsRetained() {
        let samples = [Float](repeating: 0.008, count: 16_000)

        XCTAssertNil(
            CapturedAudioValidation.discardReason(totalSampleCount: samples.count, residentSamples: samples)
        )
    }

    /// A single short word must not be averaged away across a one-second block.
    func testBriefWordInsideSilentCaptureIsRetained() {
        var samples = [Float](repeating: 0.0005, count: 16_000 + 12_000)
        for index in 15_200..<16_800 { samples[index] = 0.02 }

        XCTAssertNil(
            CapturedAudioValidation.discardReason(totalSampleCount: samples.count, residentSamples: samples)
        )
    }

    /// Silence is only judged for short captures; a longer one keeps its audio
    /// and the recognizer decides.
    func testLongerCompleteCaptureIsNeverDiscardedAsSilent() {
        let samples = [Float](repeating: 0.0005, count: 16_000 * 5)

        XCTAssertNil(
            CapturedAudioValidation.discardReason(totalSampleCount: samples.count, residentSamples: samples)
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

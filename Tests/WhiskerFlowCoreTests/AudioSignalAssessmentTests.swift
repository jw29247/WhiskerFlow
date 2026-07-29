import XCTest
@testable import WhiskerFlowCore

final class AudioSignalAssessmentTests: XCTestCase {
    private let bufferInterval: TimeInterval = 0.1

    private func feed(
        _ assessor: inout AudioSignalAssessor,
        level: Float,
        peak: Float,
        seconds: TimeInterval,
        from start: TimeInterval = 0
    ) -> TimeInterval {
        var time = start
        let end = start + seconds
        while time < end {
            assessor.ingest(level: level, peak: peak, at: time)
            time += bufferInterval
        }
        return time
    }

    func testShortCaptureStaysUnknown() {
        var assessor = AudioSignalAssessor()
        _ = feed(&assessor, level: 0, peak: 0, seconds: 1)

        XCTAssertEqual(assessor.quality, .unknown)
    }

    func testSilenceReportsTooQuietAfterGrace() {
        var assessor = AudioSignalAssessor()
        _ = feed(&assessor, level: 0.01, peak: 0.02, seconds: 3)

        XCTAssertEqual(assessor.quality, .tooQuiet)
        XCTAssertTrue(assessor.quality.isWarning)
    }

    func testSpeechShapedSignalReportsOK() {
        var assessor = AudioSignalAssessor()
        var time: TimeInterval = 0
        while time < 3 {
            let level: Float = time.truncatingRemainder(dividingBy: 0.5) < 0.2 ? 0.05 : 0.6
            assessor.ingest(level: level, peak: level * 1.2, at: time)
            time += bufferInterval
        }

        XCTAssertEqual(assessor.quality, .ok)
        XCTAssertFalse(assessor.quality.isWarning)
    }

    func testSustainedClippingReportsClipping() {
        var assessor = AudioSignalAssessor()
        var time: TimeInterval = 0
        while time < 3 {
            let clipped = time.truncatingRemainder(dividingBy: 0.4) < 0.2
            assessor.ingest(level: 0.9, peak: clipped ? 1 : 0.7, at: time)
            time += bufferInterval
        }

        XCTAssertEqual(assessor.quality, .clipping)
    }

    func testIsolatedClippedBufferDoesNotTripWarning() {
        var assessor = AudioSignalAssessor()
        let time = feed(&assessor, level: 0.5, peak: 0.6, seconds: 3)
        assessor.ingest(level: 0.5, peak: 1, at: time)

        XCTAssertEqual(assessor.quality, .ok)
    }

    func testQuietRecoversToOKOnceSpeechArrives() {
        var assessor = AudioSignalAssessor()
        let quietEnd = feed(&assessor, level: 0.01, peak: 0.02, seconds: 3)
        XCTAssertEqual(assessor.quality, .tooQuiet)

        _ = feed(&assessor, level: 0.4, peak: 0.5, seconds: 1, from: quietEnd)

        XCTAssertEqual(assessor.quality, .ok)
    }

    func testClippingRecoversToOKOnceGainDrops() {
        var assessor = AudioSignalAssessor()
        let clippedEnd = feed(&assessor, level: 0.95, peak: 1, seconds: 3)
        XCTAssertEqual(assessor.quality, .clipping)

        _ = feed(&assessor, level: 0.5, peak: 0.6, seconds: 2.5, from: clippedEnd)

        XCTAssertEqual(assessor.quality, .ok)
    }

    func testLevelAtThresholdCountsAsOK() {
        var assessor = AudioSignalAssessor()
        _ = feed(&assessor, level: AudioSignalAssessor.quietLevelThreshold, peak: 0.2, seconds: 3)

        XCTAssertEqual(assessor.quality, .ok)
    }

    func testResetReturnsToUnknownAndRestartsGrace() {
        var assessor = AudioSignalAssessor()
        let end = feed(&assessor, level: 0.01, peak: 0.02, seconds: 3)
        assessor.reset()

        XCTAssertEqual(assessor.quality, .unknown)

        _ = feed(&assessor, level: 0.01, peak: 0.02, seconds: 1, from: end)

        XCTAssertEqual(assessor.quality, .unknown)
    }

    func testOnlyTrailingWindowDecidesTheVerdict() {
        var assessor = AudioSignalAssessor()
        let loudEnd = feed(&assessor, level: 0.8, peak: 0.85, seconds: 3)
        XCTAssertEqual(assessor.quality, .ok)

        _ = feed(&assessor, level: 0.01, peak: 0.02, seconds: 2.5, from: loudEnd)

        XCTAssertEqual(assessor.quality, .tooQuiet)
    }

    func testInjectedClockDrivesTheGracePeriod() {
        let clock = TestClock(seconds: 100)
        var assessor = AudioSignalAssessor(now: { clock.seconds })
        for _ in 0..<5 {
            assessor.ingest(level: 0.01, peak: 0.02)
            clock.seconds += 0.1
        }
        XCTAssertEqual(assessor.quality, .unknown)

        while clock.seconds < 103 {
            assessor.ingest(level: 0.01, peak: 0.02)
            clock.seconds += 0.1
        }

        XCTAssertEqual(assessor.quality, .tooQuiet)
    }
}

private final class TestClock: @unchecked Sendable {
    var seconds: TimeInterval

    init(seconds: TimeInterval) {
        self.seconds = seconds
    }
}

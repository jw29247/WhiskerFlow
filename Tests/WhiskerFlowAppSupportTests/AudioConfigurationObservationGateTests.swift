import XCTest
@testable import WhiskerFlowAppSupport

final class AudioConfigurationObservationGateTests: XCTestCase {
    func testStartupChangesAreIgnoredUntilCurrentGenerationIsArmed() {
        var gate = AudioConfigurationObservationGate()
        let generation = gate.captureStarted()

        XCTAssertFalse(gate.shouldHandleChange(for: generation))
        XCTAssertTrue(gate.arm(generation))
        XCTAssertTrue(gate.shouldHandleChange(for: generation))
    }

    func testStoppedCaptureRejectsDelayedArmAndStaleNotification() {
        var gate = AudioConfigurationObservationGate()
        let generation = gate.captureStarted()

        gate.captureStopped()

        XCTAssertFalse(gate.arm(generation))
        XCTAssertFalse(gate.shouldHandleChange(for: generation))
    }
}

final class CaptureInterruptionDetectorTests: XCTestCase {
    func testConfigurationChangeOnlyInterruptsAStoppedEngine() {
        XCTAssertFalse(CaptureInterruptionDetector.configurationChangeInterrupts(engineIsRunning: true))
        XCTAssertTrue(CaptureInterruptionDetector.configurationChangeInterrupts(engineIsRunning: false))
    }

    func testStoppedEngineIsAnInterruptionEvenBeforeTheFirstBuffer() {
        var detector = CaptureInterruptionDetector()
        XCTAssertTrue(detector.isInterrupted(deliveredBufferCount: 0, engineIsRunning: false, now: 0.5))
    }

    func testSlowFirstBufferIsNotAStall() {
        var detector = CaptureInterruptionDetector(stallInterval: 4)
        for tick in 1...40 {
            XCTAssertFalse(detector.isInterrupted(
                deliveredBufferCount: 0, engineIsRunning: true, now: Double(tick) * 0.5))
        }
        XCTAssertFalse(detector.isInterrupted(deliveredBufferCount: 1, engineIsRunning: true, now: 21))
    }

    func testBuffersThatStopWhileRunningAreAStall() {
        var detector = CaptureInterruptionDetector(stallInterval: 4)
        XCTAssertFalse(detector.isInterrupted(deliveredBufferCount: 5, engineIsRunning: true, now: 1))
        XCTAssertFalse(detector.isInterrupted(deliveredBufferCount: 5, engineIsRunning: true, now: 4.9))
        XCTAssertTrue(detector.isInterrupted(deliveredBufferCount: 5, engineIsRunning: true, now: 5))
    }

    func testProgressResetsTheStallClock() {
        var detector = CaptureInterruptionDetector(stallInterval: 4)
        XCTAssertFalse(detector.isInterrupted(deliveredBufferCount: 5, engineIsRunning: true, now: 1))
        // A main actor blocked for seconds still sees the tap's progress.
        XCTAssertFalse(detector.isInterrupted(deliveredBufferCount: 90, engineIsRunning: true, now: 8))
        XCTAssertFalse(detector.isInterrupted(deliveredBufferCount: 90, engineIsRunning: true, now: 11.5))
    }

    func testOnlyOneInterruptionIsReportedPerCapture() {
        var gate = AudioConfigurationObservationGate()
        let generation = gate.captureStarted()
        XCTAssertFalse(gate.claimInterruption(for: generation))
        XCTAssertTrue(gate.arm(generation))
        XCTAssertTrue(gate.claimInterruption(for: generation))
        XCTAssertFalse(gate.claimInterruption(for: generation))

        let next = gate.captureStarted()
        XCTAssertTrue(gate.arm(next))
        XCTAssertTrue(gate.claimInterruption(for: next))
    }
}

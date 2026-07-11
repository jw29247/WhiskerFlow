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

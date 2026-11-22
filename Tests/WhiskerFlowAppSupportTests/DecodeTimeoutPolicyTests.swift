import XCTest
@testable import WhiskerFlowAppSupport

final class DecodeTimeoutPolicyTests: XCTestCase {
    func testShortAudioUsesTheFloor() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 0, scale: 1), 30)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 1, scale: 1), 30)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 5, scale: 1), 30)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: -10, scale: 1), 30)
    }

    func testMidRangeScalesWithDuration() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 10, scale: 1), 45)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 30, scale: 1), 105)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 60, scale: 1), 195)
    }

    func testLongAudioIsClampedToTheCeiling() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 95, scale: 1), 300)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 600, scale: 1), 300)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 95, scale: 1), DecodeTimeoutPolicy.baseMaximumTimeout)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 95), DecodeTimeoutPolicy.maximumTimeout)
    }

    func testBoundaryDurationSitsJustUnderTheCeiling() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 94, scale: 1), 297)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 5.001, scale: 1), 30.003, accuracy: 0.0001)
    }

    /// Budgets are tuned on a 16 GB Apple Silicon Mac; a base 8 GB machine
    /// gets proportionally longer before a slow decode counts as wedged.
    func testSlowerHardwareGetsProportionallyLongerBudgets() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(DecodeTimeoutPolicy.hardwareScale(physicalMemoryBytes: 16 * gib), 1)
        XCTAssertEqual(DecodeTimeoutPolicy.hardwareScale(physicalMemoryBytes: 8 * gib), 2)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 30, scale: 2), 210)
        XCTAssertGreaterThanOrEqual(DecodeTimeoutPolicy.hardwareScale, 1)
    }

    /// A whole-file decode is never abandoned merely for being long.
    func testLongFormBudgetKeepsGrowingPastTheWindowCeiling() {
        XCTAssertEqual(DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: 5, scale: 1), 65)
        XCTAssertEqual(DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: 30, scale: 1), 105)
        XCTAssertEqual(DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: 600, scale: 1), 660)
        XCTAssertEqual(DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: 600, scale: 2), 1_320)
    }

    func testAppleSpeechBudgetFollowsRecordingLength() {
        XCTAssertEqual(DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: 10, scale: 1), 90)
        XCTAssertEqual(DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: 300, scale: 1), 630)
    }
}

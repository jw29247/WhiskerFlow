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

    func testLivePartialTimeoutIsShorterThanAnyFileDecodeBudget() {
        XCTAssertEqual(DecodeTimeoutPolicy.baseLivePartialTimeout, 20)
        XCTAssertEqual(
            DecodeTimeoutPolicy.livePartialTimeout,
            DecodeTimeoutPolicy.baseLivePartialTimeout * DecodeTimeoutPolicy.hardwareScale
        )
        XCTAssertLessThan(DecodeTimeoutPolicy.livePartialTimeout, DecodeTimeoutPolicy.timeout(forAudioSeconds: 0))
    }

    /// The live budget is what the live path actually uses, so it has to leave real
    /// headroom over the longest window that path can hand it — the file-decode
    /// budget for the same audio would exceed the finish watchdog.
    func testLiveBudgetClearsTheLongestLiveWindowByAMargin() {
        let longestWindow = LiveDecodeWindowPolicy.hardCapSeconds
        XCTAssertGreaterThan(DecodeTimeoutPolicy.livePartialTimeout, longestWindow)
        XCTAssertLessThan(
            DecodeTimeoutPolicy.livePartialTimeout,
            DecodeTimeoutPolicy.timeout(forAudioSeconds: longestWindow)
        )
    }

    /// A release awaits several live decodes one after another, and the finish
    /// watchdog is derived from this so a slow-but-healthy release is never reported
    /// as a timeout.
    func testFinishBudgetCoversEveryLiveDecodeAReleaseCanAwait() {
        XCTAssertEqual(
            DecodeTimeoutPolicy.liveFinishBudget,
            DecodeTimeoutPolicy.livePartialTimeout * Double(DecodeTimeoutPolicy.livePartialsPerRelease)
        )
        XCTAssertGreaterThanOrEqual(DecodeTimeoutPolicy.livePartialsPerRelease, 3)
    }

    /// Budgets are tuned on a 16 GB Apple Silicon Mac; a base 8 GB machine and
    /// Intel get proportionally longer before a slow decode counts as wedged.
    func testSlowerHardwareGetsProportionallyLongerBudgets() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(DecodeTimeoutPolicy.hardwareScale(physicalMemoryBytes: 16 * gib, isAppleSilicon: true), 1)
        XCTAssertEqual(DecodeTimeoutPolicy.hardwareScale(physicalMemoryBytes: 8 * gib, isAppleSilicon: true), 2)
        XCTAssertEqual(DecodeTimeoutPolicy.hardwareScale(physicalMemoryBytes: 32 * gib, isAppleSilicon: false), 3)
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

    func testAppleSpeechAndCLIBudgetsFollowRecordingLength() {
        XCTAssertEqual(DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: 10, scale: 1), 90)
        XCTAssertEqual(DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: 300, scale: 1), 630)
        XCTAssertEqual(DecodeTimeoutPolicy.cliTimeout(forAudioSeconds: 0, scale: 1), 300)
        XCTAssertEqual(DecodeTimeoutPolicy.cliTimeout(forAudioSeconds: 240, scale: 1), 1_500)
    }
}

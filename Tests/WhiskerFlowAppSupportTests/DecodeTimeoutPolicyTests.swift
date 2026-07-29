import XCTest
@testable import WhiskerFlowAppSupport

final class DecodeTimeoutPolicyTests: XCTestCase {
    func testShortAudioUsesTheFloor() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 0), 30)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 1), 30)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 5), 30)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: -10), 30)
    }

    func testMidRangeScalesWithDuration() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 10), 45)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 30), 105)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 60), 195)
    }

    func testLongAudioIsClampedToTheCeiling() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 95), 300)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 600), 300)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 95), DecodeTimeoutPolicy.maximumTimeout)
    }

    func testBoundaryDurationSitsJustUnderTheCeiling() {
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 94), 297)
        XCTAssertEqual(DecodeTimeoutPolicy.timeout(forAudioSeconds: 5.001), 30.003, accuracy: 0.0001)
    }

    func testLivePartialTimeoutIsShorterThanAnyFileDecodeBudget() {
        XCTAssertEqual(DecodeTimeoutPolicy.livePartialTimeout, 20)
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
}

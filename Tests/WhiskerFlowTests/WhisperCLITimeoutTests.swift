import XCTest
import WhiskerFlowAppSupport
@testable import WhiskerFlow

final class WhisperCLITimeoutTests: XCTestCase {
    /// The CLI runs on the CPU and may download its checkpoint first, so the
    /// process deadline grows with the recording instead of a flat 180 s.
    func testProcessDeadlineGrowsWithRecordingLength() {
        let short = WhisperCLIEngine.effectiveTimeout(floor: 180, audioSeconds: 5)
        let long = WhisperCLIEngine.effectiveTimeout(floor: 180, audioSeconds: 300)
        XCTAssertGreaterThanOrEqual(short, 180)
        XCTAssertGreaterThan(long, 5 * 300)
        XCTAssertEqual(long, DecodeTimeoutPolicy.cliTimeout(forAudioSeconds: 300))
        XCTAssertEqual(WhisperCLIEngine.effectiveTimeout(floor: 10_000, audioSeconds: 5), 10_000)
        XCTAssertEqual(
            WhisperCLIEngine.effectiveTimeout(floor: 180, audioSeconds: nil),
            DecodeTimeoutPolicy.cliTimeout(forAudioSeconds: 0)
        )
    }
}

import XCTest
@testable import WhiskerFlowCore

final class MeetingCoachMetricsTests: XCTestCase {
    func testWindowReportsOnlyTheObservedSpanAfterMidMeetingResume() {
        // Coaching resumed at minute 30: only five one-second samples exist.
        let inputs = (0..<5).map {
            MeetingActivityInput(elapsedSeconds: 1_800 + Double($0), durationSeconds: 1, ownMicActivity: true, systemActivity: false)
        }
        let result = MeetingCoachMetrics.accumulate(inputs: inputs)
        XCTAssertEqual(result.windowDurationSeconds, 5)
        XCTAssertEqual(result.ownMicActiveSeconds, 5)
    }

    func testWindowExcludesUnobservedGapsAndStaysBounded() {
        let result = MeetingCoachMetrics.accumulate(inputs: [
            .init(elapsedSeconds: 0, durationSeconds: 10, ownMicActivity: false, systemActivity: true),
            .init(elapsedSeconds: 40, durationSeconds: 10, ownMicActivity: true, systemActivity: false)
        ])
        XCTAssertEqual(result.windowDurationSeconds, 20)
        let full = MeetingCoachMetrics.accumulate(inputs: (0..<120).map {
            .init(elapsedSeconds: Double($0), durationSeconds: 1, ownMicActivity: false, systemActivity: false)
        })
        XCTAssertEqual(full.windowDurationSeconds, 60)
        XCTAssertEqual(MeetingCoachMetrics.accumulate(inputs: []).windowDurationSeconds, 0)
    }
}

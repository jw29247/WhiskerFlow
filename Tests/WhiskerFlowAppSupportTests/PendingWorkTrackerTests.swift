import XCTest
@testable import WhiskerFlowAppSupport

@MainActor
final class PendingWorkTrackerTests: XCTestCase {
    func testTrackerStartsIdle() async {
        let tracker = PendingWorkTracker()
        XCTAssertTrue(tracker.isIdle)
        let becameIdle = await tracker.waitUntilIdle(timeout: 0)
        XCTAssertTrue(becameIdle)
    }

    func testBeginMakesTrackerBusyUntilMatchingEnd() {
        let tracker = PendingWorkTracker()
        let token = tracker.begin()
        XCTAssertFalse(tracker.isIdle)
        tracker.end(token)
        XCTAssertTrue(tracker.isIdle)
    }

    func testTrackerStaysBusyUntilEveryTokenEnds() {
        let tracker = PendingWorkTracker()
        let first = tracker.begin()
        let second = tracker.begin()
        tracker.end(first)
        XCTAssertFalse(tracker.isIdle)
        tracker.end(second)
        XCTAssertTrue(tracker.isIdle)
    }

    func testWaitUntilIdleReturnsTrueWhenWorkEndsWhileWaiting() async {
        let tracker = PendingWorkTracker()
        let token = tracker.begin()
        Task { @MainActor in tracker.end(token) }
        let becameIdle = await tracker.waitUntilIdle(timeout: 2)
        XCTAssertTrue(becameIdle)
    }

    func testWaitUntilIdleTimesOutWhileWorkIsOutstanding() async {
        let tracker = PendingWorkTracker()
        _ = tracker.begin()
        let becameIdle = await tracker.waitUntilIdle(timeout: 0.1)
        XCTAssertFalse(becameIdle)
        XCTAssertFalse(tracker.isIdle)
    }
}

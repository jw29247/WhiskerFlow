import XCTest
@testable import WhiskerFlowAppSupport

final class MeetingRetryBackoffTests: XCTestCase {
    func testRepeatedFailureStopsMinuteByMinuteRetriesWithoutBlockingNewRecordings() {
        var retry = MeetingRetryBackoff()
        let failed = UUID(), fresh = UUID()
        var now: TimeInterval = 0
        for delay: TimeInterval in [60, 300, 900, 3600, 3600] {
            retry.failed(failed, now: now)
            XCTAssertFalse(retry.isReady(failed, now: now + delay - 1))
            XCTAssertTrue(retry.isReady(failed, now: now + delay))
            XCTAssertTrue(retry.isReady(fresh, now: now))
            now += delay
        }
        retry.succeeded(failed)
        XCTAssertTrue(retry.isReady(failed, now: now))
    }
    func testExplicitRetryResetsCooldown() {
        var retry = MeetingRetryBackoff()
        let id = UUID()
        retry.failed(id, now: 100)
        retry.reset()
        XCTAssertTrue(retry.isReady(id, now: 100))
    }
}

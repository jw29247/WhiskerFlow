import XCTest
@testable import WhiskerFlowAppSupport

final class TelemetryExportRetryPolicyTests: XCTestCase {
    func testPermanentClientErrorsAreDroppedButThrottlingRetries() {
        let policy = TelemetryExportRetryPolicy()
        for status in [400, 401, 403, 404, 413] {
            XCTAssertEqual(policy.decide(statusCode: status, bodyBytes: 10), .drop, "\(status)")
        }
        XCTAssertEqual(policy.decide(statusCode: 408, bodyBytes: 10), .retry)
        XCTAssertEqual(policy.decide(statusCode: 429, bodyBytes: 10), .retry)
        XCTAssertEqual(policy.decide(statusCode: 204, bodyBytes: 10), .delivered)
    }

    func testTransientFailuresRetryOnlyUpToTheBudget() {
        let policy = TelemetryExportRetryPolicy(maxConsecutiveFailures: 3, maxRetainedBodyBytes: 1_000)
        XCTAssertEqual(policy.decide(statusCode: nil, bodyBytes: 10), .retry)
        XCTAssertEqual(policy.decide(statusCode: 502, bodyBytes: 10), .retry)
        XCTAssertEqual(policy.decide(statusCode: nil, bodyBytes: 10), .retry)
        XCTAssertEqual(policy.decide(statusCode: nil, bodyBytes: 10), .drop, "the backlog must not grow forever")
        // The budget restarts after a drop, and a success clears it.
        XCTAssertEqual(policy.decide(statusCode: nil, bodyBytes: 10), .retry)
        XCTAssertEqual(policy.decide(statusCode: 200, bodyBytes: 10), .delivered)
        XCTAssertEqual(policy.decide(statusCode: nil, bodyBytes: 10), .retry)
    }

    func testOversizedBacklogIsDroppedInsteadOfRequeued() {
        let policy = TelemetryExportRetryPolicy(maxConsecutiveFailures: 10, maxRetainedBodyBytes: 1_000)
        XCTAssertEqual(policy.decide(statusCode: 503, bodyBytes: 1_001), .drop)
        XCTAssertEqual(policy.decide(statusCode: nil, bodyBytes: 1_000), .retry)
    }
}

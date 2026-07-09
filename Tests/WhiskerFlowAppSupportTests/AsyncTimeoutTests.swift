import XCTest
@testable import WhiskerFlowAppSupport

final class AsyncTimeoutTests: XCTestCase {
    func testReturnsOperationValueBeforeDeadline() async throws {
        let value = try await withTimeout(seconds: 1) { "done" }
        XCTAssertEqual(value, "done")
    }

    func testThrowsWhenDeadlineWins() async {
        do {
            _ = try await withTimeout(seconds: 0.01) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AsyncTimeoutError, .timedOut)
        }
    }
}

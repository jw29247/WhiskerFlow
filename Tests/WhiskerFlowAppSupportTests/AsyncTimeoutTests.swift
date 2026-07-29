import XCTest
@testable import WhiskerFlowAppSupport

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private struct TestFailure: Error, Equatable {}

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

    func testAbandoningDeadlineReturnsFastSuccess() async throws {
        let value = try await withAbandoningDeadline(seconds: 5) { "done" }
        XCTAssertEqual(value, "done")
    }

    func testAbandoningDeadlinePassesThroughFastFailure() async {
        do {
            _ = try await withAbandoningDeadline(seconds: 5) { throw TestFailure() }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? TestFailure, TestFailure())
        }
    }

    func testAbandoningDeadlineThrowsWhileNonCooperativeOperationStillRuns() async {
        let release = TestFlag()
        let completed = TestFlag()

        do {
            _ = try await withAbandoningDeadline(seconds: 0.05) {
                while !release.isSet {
                    await Task.yield()
                }
                completed.set()
                return "late"
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AsyncTimeoutError, .timedOut)
        }

        XCTAssertFalse(completed.isSet)
        release.set()
    }

    func testAbandoningDeadlineDoesNotResumeTwiceWhenAbandonedWorkFinishes() async {
        let release = TestFlag()

        do {
            _ = try await withAbandoningDeadline(seconds: 0.05) {
                while !release.isSet {
                    await Task.yield()
                }
                return "late"
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AsyncTimeoutError, .timedOut)
        }

        release.set()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

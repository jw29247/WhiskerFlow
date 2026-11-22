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
        let deadline = ManualDeadline()
        let caller = Task {
            try await withTimeout(seconds: 0.01, sleep: deadline.sleep) {
                // Cancelled by the timeout; it never runs out.
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "late"
            }
        }
        await deadline.untilRequested(1)
        XCTAssertEqual(deadline.requested, [10_000_000])
        deadline.fire()
        do {
            _ = try await caller.value
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

        let deadline = ManualDeadline()
        let caller = Task {
            try await withAbandoningDeadline(seconds: 0.05, sleep: deadline.sleep) {
                while !release.isSet {
                    await Task.yield()
                }
                completed.set()
                return "late"
            }
        }
        await deadline.untilRequested(1)
        deadline.fire()
        do {
            _ = try await caller.value
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AsyncTimeoutError, .timedOut)
        }

        XCTAssertFalse(completed.isSet)
        release.set()
    }

    func testAbandoningDeadlineDoesNotResumeTwiceWhenAbandonedWorkFinishes() async {
        let release = TestFlag()
        let finished = expectation(description: "abandoned work finished")
        let deadline = ManualDeadline()
        let caller = Task {
            try await withAbandoningDeadline(seconds: 0.05, sleep: deadline.sleep) {
                defer { finished.fulfill() }
                while !release.isSet {
                    await Task.yield()
                }
                return "late"
            }
        }
        await deadline.untilRequested(1)
        deadline.fire()
        do {
            _ = try await caller.value
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AsyncTimeoutError, .timedOut)
        }

        release.set()
        await fulfillment(of: [finished], timeout: 10)
        // The abandoned work resumes the wait a moment after it returns. A
        // second resume traps the process, so give it a short, bounded chance
        // to happen here rather than in a later test. This is the only real
        // wait left in this file.
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    /// A cancelled caller (quit drain, capture restart) must stop waiting at once
    /// instead of sitting out the whole deadline behind a non-cooperative decode.
    func testAbandoningDeadlineReturnsAsSoonAsTheCallerIsCancelled() async {
        let release = TestFlag()
        let running = expectation(description: "operation running")
        let caller = Task {
            // 30 s is only a ceiling: a passing run never reaches it.
            try await withAbandoningDeadline(seconds: 30) {
                running.fulfill()
                while !release.isSet { await Task.yield() }
                return "late"
            }
        }
        await fulfillment(of: [running], timeout: 10)
        let started = Date()
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        release.set()
    }

    func testAbandoningDeadlineInAlreadyCancelledTaskThrowsImmediately() async {
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withAbandoningDeadline(seconds: 30) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return "late"
            }
        }
        do {
            _ = try await caller.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAbandoningCancellationWaitsWithoutADeadlineButHonoursCancel() async throws {
        let value = try await withAbandoningCancellation {
            await Task.yield()
            return "done"
        }
        XCTAssertEqual(value, "done")

        let release = TestFlag()
        let running = expectation(description: "operation running")
        let caller = Task {
            try await withAbandoningCancellation {
                running.fulfill()
                while !release.isSet { await Task.yield() }
                return "late"
            }
        }
        await fulfillment(of: [running], timeout: 10)
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        release.set()
    }
}

import XCTest
import WhiskerFlowAppSupport
@testable import WhiskerFlow

/// Launch warm-ups for the dictation and meeting models used to race for the
/// gate, and the loser reported a false "could not load". Loads and file
/// decodes now wait their turn; live partials still fail fast.
final class ModelDecodeGateQueueTests: XCTestCase {
    func testQueuedLoadWaitsForTheRunningOneInsteadOfFailing() async throws {
        let gate = ModelDecodeGate()
        let order = GateOrder()
        let release = GateLatch()
        let first = Task {
            try await gate.runQueued(waitingUpTo: nil) {
                await order.append("first-start")
                await release.wait()
                await order.append("first-end")
            }
        }
        while await !(gate.isOccupied) { await Task.yield() }
        let second = Task {
            try await gate.runQueued(waitingUpTo: nil) { await order.append("second") }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        // A fail-fast caller cannot jump the queue while it is held.
        do {
            try await gate.runExclusive {}
            XCTFail("A fail-fast operation must not overlap the running load")
        } catch ModelDecodeGateError.occupied {}

        await release.open()
        try await first.value
        try await second.value
        let recorded = await order.values
        XCTAssertEqual(recorded, ["first-start", "first-end", "second"])
        let occupied = await gate.isOccupied
        XCTAssertFalse(occupied)
    }

    func testBoundedQueueWaitGivesUpWithOccupied() async throws {
        let gate = ModelDecodeGate()
        let release = GateLatch()
        let holder = Task { try await gate.runQueued(waitingUpTo: nil) { await release.wait() } }
        while await !(gate.isOccupied) { await Task.yield() }

        do {
            _ = try await gate.run(seconds: 1, waitingUpTo: 0.05) { "must not start" }
            XCTFail("The queued decode should give up after its wait")
        } catch ModelDecodeGateError.occupied {}

        await release.open()
        try await holder.value
        let value = try await gate.run(seconds: 1, waitingUpTo: 0.05) { "next" }
        XCTAssertEqual(value, "next")
    }

    /// Behind a timed-out (possibly wedged) prediction a bounded waiter fails
    /// at once so the caller can fall back, rather than sitting out its wait.
    func testBoundedWaiterFailsFastBehindAnAbandonedDecode() async throws {
        let gate = ModelDecodeGate()
        let release = GateLatch()
        do {
            _ = try await gate.run(seconds: 0.01) {
                await release.wait()
                return "late"
            }
            XCTFail("Expected timeout")
        } catch AsyncTimeoutError.timedOut {}
        let wedged = await gate.isHeldByAbandonedOperation
        XCTAssertTrue(wedged)

        let started = Date()
        do {
            _ = try await gate.run(seconds: 1, waitingUpTo: 30) { "must not start" }
            XCTFail("Expected occupied")
        } catch ModelDecodeGateError.occupied {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        await release.open()
        for _ in 0..<200 {
            if await !(gate.isOccupied) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let stillWedged = await gate.isHeldByAbandonedOperation
        XCTAssertFalse(stillWedged)
        let value = try await gate.run(seconds: 1, waitingUpTo: 1) { "next" }
        XCTAssertEqual(value, "next")
    }

    func testCancelledWaiterLeavesTheQueue() async throws {
        let gate = ModelDecodeGate()
        let release = GateLatch()
        let holder = Task { try await gate.runQueued(waitingUpTo: nil) { await release.wait() } }
        while await !(gate.isOccupied) { await Task.yield() }
        let waiter = Task { try await gate.runQueued(waitingUpTo: nil) { XCTFail("Cancelled waiter must not run") } }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        await release.open()
        try await holder.value
        try await gate.runExclusive {}
    }
}

private actor GateOrder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor GateLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

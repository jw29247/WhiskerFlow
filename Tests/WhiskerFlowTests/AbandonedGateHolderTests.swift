import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

/// A model load queued with no bound behind a wedged prediction used to wait
/// forever, and every later dictation joined that load until the app restarted.
final class AbandonedGateHolderTests: XCTestCase {
    func testUnboundedLoadFailsFastBehindAnAbandonedDecode() async throws {
        let deadline = ManualDeadline()
        let gate = ModelDecodeGate(sleep: deadline.sleep)
        let release = HolderLatch()
        let wedged = Task {
            try await gate.run(seconds: 0.01) {
                await release.wait()
                return "late"
            }
        }
        await deadline.untilRequested(1)
        deadline.fire()
        do {
            _ = try await wedged.value
            XCTFail("Expected timeout")
        } catch AsyncTimeoutError.timedOut {}

        do {
            try await gate.runQueued(waitingUpTo: nil) { XCTFail("Must not run beside the wedged decode") }
            XCTFail("Expected occupied")
        } catch ModelDecodeGateError.occupied {}

        await release.open()
        await gate.settling?.value
        try await gate.runQueued(waitingUpTo: nil) {}
    }

    /// Callers that queued before the holder was abandoned are released too.
    func testQueuedLoadIsReleasedWhenTheHolderIsAbandoned() async throws {
        let deadline = ManualDeadline()
        let gate = ModelDecodeGate(sleep: deadline.sleep)
        let release = HolderLatch()
        let holder = Task {
            // Long enough that the deadline's real-time backstop cannot end
            // it before the load below is queued; the test fires it.
            try await gate.run(seconds: 30) {
                await release.wait()
                return "late"
            }
        }
        while await !(gate.isOccupied) { await Task.yield() }
        let load = Task {
            try await gate.runQueued(waitingUpTo: nil) { XCTFail("Must not run beside the wedged decode") }
        }
        // The load is queued before the holder's deadline passes.
        let queued = await yieldUntil { await gate.queuedCount >= 1 }
        guard queued else { return XCTFail("The load never queued") }
        await deadline.untilRequested(1)
        deadline.fire()
        do {
            _ = try await holder.value
            XCTFail("Expected timeout")
        } catch AsyncTimeoutError.timedOut {}
        do {
            try await load.value
            XCTFail("Expected occupied")
        } catch ModelDecodeGateError.occupied {}
        await release.open()
    }

    /// Each engine path's own deadlines, summed with the Apple fallback, fit
    /// inside the app backstop, so the engine's bound (not the backstop) fires
    /// and the fallback still gets its turn.
    func testAppBackstopCoversEachEnginePathAndTheFallback() {
        let scale = DecodeTimeoutPolicy.hardwareScale
        for seconds in [0.0, 1, 5, 10, 30, 60, 95, 300, 600] {
            let apple = DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: seconds)
            let queue = DecodeTimeoutPolicy.gateQueueWait
            let parakeet = DecodeTimeoutPolicy.modelPreparationWait
                + 2 * (queue + DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: seconds))
            XCTAssertGreaterThanOrEqual(
                AppState.recognitionBackstopSeconds(forAudioSeconds: seconds, engine: .parakeetTDTv3, allowAppleFallback: true),
                parakeet + apple, "parakeet \(seconds)s")
            XCTAssertGreaterThanOrEqual(
                AppState.recognitionBackstopSeconds(forAudioSeconds: seconds, engine: .appleSpeech, allowAppleFallback: true),
                apple, "apple \(seconds)s")
        }
    }
}

private actor HolderLatch {
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

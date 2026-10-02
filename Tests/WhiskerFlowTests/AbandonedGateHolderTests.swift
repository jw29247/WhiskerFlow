import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

/// A model load queued with no bound behind a wedged prediction used to wait
/// forever, and every later dictation joined that load until the app restarted.
final class AbandonedGateHolderTests: XCTestCase {
    func testUnboundedLoadFailsFastBehindAnAbandonedDecode() async throws {
        let gate = ModelDecodeGate()
        let release = HolderLatch()
        do {
            _ = try await gate.run(seconds: 0.01) {
                await release.wait()
                return "late"
            }
            XCTFail("Expected timeout")
        } catch AsyncTimeoutError.timedOut {}

        do {
            try await gate.runQueued(waitingUpTo: nil) { XCTFail("Must not run beside the wedged decode") }
            XCTFail("Expected occupied")
        } catch ModelDecodeGateError.occupied {}

        await release.open()
        for _ in 0..<200 {
            if !(await gate.isOccupied) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await gate.runQueued(waitingUpTo: nil) {}
    }

    /// Callers that queued before the holder was abandoned are released too.
    func testQueuedLoadIsReleasedWhenTheHolderIsAbandoned() async throws {
        let gate = ModelDecodeGate()
        let release = HolderLatch()
        let holder = Task {
            try await gate.run(seconds: 0.2) {
                await release.wait()
                return "late"
            }
        }
        while !(await gate.isOccupied) { await Task.yield() }
        let load = Task {
            try await gate.runQueued(waitingUpTo: nil) { XCTFail("Must not run beside the wedged decode") }
        }
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

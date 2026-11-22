import FluidAudio
import WhiskerFlowCore
import XCTest
@testable import WhiskerFlow

final class ParakeetPreparationTests: XCTestCase {
    func testWarmupAndFirstDictationsShareOneLoad() async throws {
        try XCTSkipUnless(SystemInfo.isAppleSilicon)
        let probe = PreparationProbe()
        let engine = ParakeetTDTv3Engine(loadManager: { try await probe.load() })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try await engine.prepare() } }
            try await group.waitForAll()
        }
        try await engine.prepare()
        let loads = await probe.loads
        XCTAssertEqual(loads, 1)
    }

    func testFailedWarmupCanBeRetriedWithoutDuplicateLoads() async throws {
        try XCTSkipUnless(SystemInfo.isAppleSilicon)
        let probe = PreparationProbe(failFirst: true)
        let engine = ParakeetTDTv3Engine(loadManager: { try await probe.load() })
        do {
            try await engine.prepare()
            XCTFail("The first load should fail")
        } catch {}
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try await engine.prepare() } }
            try await group.waitForAll()
        }
        let loads = await probe.loads
        XCTAssertEqual(loads, 2)
    }

    /// A dictation during a first-run model download used to wait with no
    /// bound; it now gives up so the caller can fall back, and the load keeps
    /// going for the next attempt to join.
    func testDecodeStopsWaitingForASlowLoadAndLaterJoinsIt() async throws {
        try XCTSkipUnless(SystemInfo.isAppleSilicon)
        let load = LoadLatch()
        let probe = PreparationProbe(holdUntil: load)
        let deadline = ManualDeadline()
        let engine = ParakeetTDTv3Engine(preparationWait: 0.05, preparationSleep: deadline.sleep,
                                         loadManager: { try await probe.load() })
        let decode = Task { try await engine.transcribe(samples: [Float](repeating: 0, count: 1_600), language: "en") }
        // The load is still running when the decode's wait for it ends.
        await deadline.untilRequested(1)
        XCTAssertEqual(deadline.requested, [50_000_000])
        deadline.fire()
        do {
            _ = try await decode.value
            XCTFail("The decode should stop waiting for the load")
        } catch TranscriptionError.timedOut {}
        await load.open()
        try await engine.prepare()
        let loads = await probe.loads
        XCTAssertEqual(loads, 1)
    }
}

/// Holds a load until the test opens it.
private actor LoadLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor PreparationProbe {
    private(set) var loads = 0
    let failFirst: Bool
    let holdUntil: LoadLatch?
    init(failFirst: Bool = false, holdUntil: LoadLatch? = nil) {
        self.failFirst = failFirst
        self.holdUntil = holdUntil
    }
    func load() async throws -> AsrManager {
        loads += 1
        let attempt = loads
        if let holdUntil {
            await holdUntil.wait()
        } else {
            // Hold the preparation at an await so concurrent callers reach the
            // actual engine's reentrancy boundary, without loading Core ML in
            // CI. The callers' arrival cannot be observed from here, so this is
            // a real wait; the assertions hold whether or not they overlap.
            try await Task.sleep(for: .milliseconds(50))
        }
        if failFirst && attempt == 1 { throw ProbeError.failed }
        return AsrManager()
    }
    private enum ProbeError: Error { case failed }
}

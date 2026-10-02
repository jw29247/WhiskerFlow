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
        let probe = PreparationProbe(delayMilliseconds: 400)
        let engine = ParakeetTDTv3Engine(preparationWait: 0.05, loadManager: { try await probe.load() })
        let started = Date()
        do {
            _ = try await engine.transcribe(samples: [Float](repeating: 0, count: 1_600), language: "en")
            XCTFail("The decode should stop waiting for the load")
        } catch TranscriptionError.timedOut {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.35)
        try await engine.prepare()
        let loads = await probe.loads
        XCTAssertEqual(loads, 1)
    }
}

private actor PreparationProbe {
    private(set) var loads = 0
    let failFirst: Bool
    let delayMilliseconds: Int
    init(failFirst: Bool = false, delayMilliseconds: Int = 50) {
        self.failFirst = failFirst
        self.delayMilliseconds = delayMilliseconds
    }
    func load() async throws -> AsrManager {
        loads += 1
        let attempt = loads
        // Hold the preparation at an await so concurrent callers reach the
        // actual engine's reentrancy boundary, without loading Core ML in CI.
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        if failFirst && attempt == 1 { throw ProbeError.failed }
        return AsrManager()
    }
    private enum ProbeError: Error { case failed }
}

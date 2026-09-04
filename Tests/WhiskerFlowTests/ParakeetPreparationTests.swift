import FluidAudio
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
}

private actor PreparationProbe {
    private(set) var loads = 0
    let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func load() async throws -> AsrManager {
        loads += 1
        let attempt = loads
        // Hold the preparation at an await so concurrent callers reach the
        // actual engine's reentrancy boundary, without loading Core ML in CI.
        try await Task.sleep(for: .milliseconds(50))
        if failFirst && attempt == 1 { throw ProbeError.failed }
        return AsrManager()
    }
    private enum ProbeError: Error { case failed }
}

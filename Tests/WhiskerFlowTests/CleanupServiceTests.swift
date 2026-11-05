import XCTest
import WhiskerFlowCore
import WhiskerFlowCleanupSupport
@testable import WhiskerFlow

@MainActor
final class CleanupServiceTests: XCTestCase {
    func testWarningAllowsBoundedForegroundWorkButNeverIdleWarmingOrCriticalPressure() {
        let gib: UInt64 = 1_073_741_824
        let reserve: UInt64 = gib
        XCTAssertEqual(wf_cleanup_can_load(2 * gib, 3 * gib, 1, 0), 1)
        XCTAssertEqual(wf_cleanup_can_load(2 * gib, 3 * gib, 2, 0), 0)
        XCTAssertEqual(wf_cleanup_can_load(2 * gib, 3 * gib, 2, 1), 1)
        XCTAssertEqual(wf_cleanup_can_load(2 * gib, 2 * gib + reserve, 2, 1), 1)
        XCTAssertEqual(wf_cleanup_can_load(2 * gib, 2 * gib + reserve - 1, 2, 1), 0)
        XCTAssertEqual(wf_cleanup_can_load(2 * gib, 8 * gib, 4, 1), 0)
        XCTAssertEqual(wf_cleanup_can_load(UInt64.max, 3 * gib, 1, 1), 0)
    }

    func testDisabledCleanupReturnsOriginalWithoutLoadingAModel() async {
        let service = CleanupService()
        let input = "Um, don't change this yet."
        let result = await service.clean(input, model: .gemma4E2B)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.outcome, "skipped")
        XCTAssertFalse(service.needsShutdown)
        XCTAssertEqual(service.status, "Off")
    }

    func testOversizedTranscriptKeepsOriginalWithoutLoading() async {
        let service = CleanupService()
        service.configure(model: .gemma4E2B, enabled: true)
        let input = String(repeating: "A", count: TranscriptCleanup.maximumCharacters + 1)
        let result = await service.clean(input, model: .gemma4E2B)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.outcome, "too_long")
        XCTAssertFalse(service.needsShutdown)
    }

    func testUnexpectedWeightsFailIntegrityCheck() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("unexpected model data".utf8).write(to: file)
        XCTAssertThrowsError(try CleanupWorker.validate(file, model: .gemma4E2B))
    }
}

import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

@MainActor
final class CleanupServiceTests: XCTestCase {
    func testDisabledCleanupReturnsOriginalWithoutLoadingAModel() async {
        let service = CleanupService()
        let input = "Um, don't change this yet."
        let result = await service.clean(input, model: .gemma2)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.outcome, "skipped")
        XCTAssertFalse(service.needsShutdown)
        XCTAssertEqual(service.status, "Off")
    }

    func testOversizedTranscriptKeepsOriginalWithoutLoading() async {
        let service = CleanupService()
        service.configure(model: .gemma2, enabled: true)
        let input = String(repeating: "A", count: TranscriptCleanup.maximumCharacters + 1)
        let result = await service.clean(input, model: .gemma2)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.outcome, "skipped")
        XCTAssertFalse(service.needsShutdown)
    }

    func testUnexpectedWeightsFailIntegrityCheck() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("unexpected model data".utf8).write(to: file)
        XCTAssertThrowsError(try CleanupWorker.validate(file, model: .gemma2))
    }
}

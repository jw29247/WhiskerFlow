import XCTest
@testable import WhiskerFlow

/// Pins the exact words Cleanup shows today, so moving the state to enums
/// cannot change what the person reads.
@MainActor
final class CleanupStatusTextTests: XCTestCase {
    func testOutcomeSummariesAreUnchanged() {
        let expected: [String: String] = [
            "cleaned": "Cleaned up the transcript",
            "partial": "Cleaned up the transcript. Kept some wording to preserve your meaning.",
            "unchanged": "Checked the transcript. No changes needed.",
            "formatted": "Formatted numbers. Kept the rest of the recognised wording.",
            "rejected": "Kept the original because the proposed edit changed too much.",
            "cancelled": "Cleanup was interrupted. Kept the original.",
            "too_long": "Transcript exceeds the preview limit. Kept the original.",
            "unavailable": "Cleanup is paused or the model isn't ready. Kept the original.",
            "skipped": "Cleanup is off or busy. Kept the original.",
            "fallback": "Cleanup couldn't finish in time. Kept the original.",
            "failed": "Cleanup couldn't finish in time. Kept the original.",
        ]
        for (outcome, summary) in expected {
            XCTAssertEqual(CleanupResult(text: "", outcome: outcome).summary, summary, outcome)
        }
    }

    func testInitialAndConfiguredStatusWordsAreUnchanged() {
        let service = CleanupService()
        XCTAssertEqual(service.status, "Off")
        XCTAssertEqual(service.lastRun, "No transcript checked yet")
        service.configure(model: .gemma4E2B, enabled: true)
        XCTAssertTrue(["Ready on next dictation", "Download needed"].contains(service.status))
        service.configure(model: nil, enabled: false)
        XCTAssertEqual(service.status, "Off")
    }

    func testSkippedRunWordsAreUnchanged() async {
        let service = CleanupService()
        _ = await service.clean("Leave this alone", model: .gemma4E2B)
        XCTAssertEqual(service.lastRun, "Cleanup is off or busy. Kept the original.")
    }
}

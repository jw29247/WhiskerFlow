import Logging
@testable import WhiskerFlowAppSupport
import WhiskerFlowCore
import XCTest
@testable import WhiskerFlow

/// Pins the exact words Cleanup shows and the exact values it logs, so the
/// enums cannot change what the person reads or what old logs contain.
@MainActor
final class CleanupStatusTextTests: XCTestCase {
    /// Copied verbatim from the string-typed CleanupService before the enums.
    private let summaries: [CleanupOutcome: String] = [
        .cleaned: "Cleaned up the transcript",
        .partial: "Cleaned up the transcript. Kept some wording to preserve your meaning.",
        .unchanged: "Checked the transcript. No changes needed.",
        .formatted: "Formatted numbers. Kept the rest of the recognised wording.",
        .rejected: "Kept the original because the proposed edit changed too much.",
        .cancelled: "Cleanup was interrupted. Kept the original.",
        .tooLong: "Transcript exceeds the preview limit. Kept the original.",
        .unavailable: "Cleanup is paused or the model isn't ready. Kept the original.",
        .skipped: "Cleanup is off or busy. Kept the original.",
        .fallback: "Cleanup couldn't finish in time. Kept the original.",
        .approved: "Cleanup couldn't finish in time. Kept the original.",
        .failed: "Cleanup couldn't finish in time. Kept the original.",
    ]

    func testOutcomeSummariesAreUnchanged() {
        XCTAssertEqual(Set(summaries.keys), Set(CleanupOutcome.allCases))
        for (outcome, summary) in summaries {
            XCTAssertEqual(CleanupResult(text: "", outcome: outcome).summary, summary, "\(outcome)")
        }
        XCTAssertEqual(CleanupOutcome.noRunSummary, "No transcript checked yet")
    }

    func testOutcomeLogValuesAreUnchanged() {
        let expected: [CleanupOutcome: String] = [
            .cleaned: "cleaned", .partial: "partial", .unchanged: "unchanged", .formatted: "formatted",
            .rejected: "rejected", .cancelled: "cancelled", .tooLong: "too_long", .unavailable: "unavailable",
            .skipped: "skipped", .fallback: "fallback", .approved: "approved", .failed: "failed",
        ]
        XCTAssertEqual(Set(expected.keys), Set(CleanupOutcome.allCases))
        for (outcome, value) in expected {
            XCTAssertEqual(outcome.logValue, value)
        }
    }

    /// Every value that reaches the log (all but `formatted`, which is only
    /// ever shown) survives the local log's allow-list.
    func testLoggedOutcomesSurviveTheLocalLogAllowList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.Cleanup", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        let logged = CleanupOutcome.allCases.filter { $0 != .formatted }
        for outcome in logged {
            logger.info("Cleanup finished", metadata: ["event": "cleanup_finished", "cleanup_outcome": "\(outcome.logValue)"])
        }
        sink.flush()
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, logged.count)
        for (line, outcome) in zip(lines, logged) {
            XCTAssertTrue(line.contains("\"cleanup_outcome\":\"\(outcome.logValue)\""), "\(outcome)")
        }
    }

    func testStatusWordsAreUnchanged() {
        let model = "Gemma 4 E2B"
        let expected: [(CleanupStatus, String)] = [
            (.off, "Off"),
            (.readyOnNextDictation, "Ready on next dictation"),
            (.downloadNeeded, "Download needed"),
            (.warmingUp, "Warming up"),
            (.warmAndReady, "Warm and ready"),
            (.backgroundWarmingPaused, "Ready on next dictation. Background warming is paused."),
            (.modelCouldNotLoad, "Model couldn't load. Dictation still works."),
            (.cleaningUp, "Cleaning up"),
            (.pausedToSaveResources, "Paused to save resources"),
            (.usedOriginalTranscript, "Used original transcript"),
            (.downloading(model: model), "Downloading Gemma 4 E2B"),
            (.resumingDownload(model: model), "Resuming Gemma 4 E2B download"),
            (.restartingDownload(model: model), "Starting the Gemma 4 E2B download again"),
            (.checkingDownload, "Checking download"),
            (.downloaded, "Downloaded"),
            (.downloadCancelled, "Download cancelled"),
            (.downloadPaused, "Download paused"),
            (.downloadMismatch, "The download didn't match the expected file and was deleted. Try again."),
            (.downloadStoppedResumable, "Download stopped. Resume to carry on where it left off."),
            (.downloadFailed, "Download failed. Try again."),
            (.sleeping, "Sleeping to save memory"),
            (.pausedForMemory, "Paused while your Mac needs memory"),
        ]
        for (status, text) in expected {
            XCTAssertEqual(status.text, text)
        }
        XCTAssertEqual(CleanupModel.gemma4E2B.name, model)
    }

    func testInitialAndConfiguredStatusWordsAreUnchanged() {
        let service = CleanupService()
        XCTAssertEqual(service.status.text, "Off")
        XCTAssertEqual(service.lastRun, "No transcript checked yet")
        service.configure(model: .gemma4E2B, enabled: true)
        XCTAssertTrue(["Ready on next dictation", "Download needed"].contains(service.status.text))
        service.configure(model: nil, enabled: false)
        XCTAssertEqual(service.status.text, "Off")
    }

    func testSkippedRunWordsAreUnchanged() async {
        let service = CleanupService()
        _ = await service.clean("Leave this alone", model: .gemma4E2B)
        XCTAssertEqual(service.lastRun, "Cleanup is off or busy. Kept the original.")
    }
}

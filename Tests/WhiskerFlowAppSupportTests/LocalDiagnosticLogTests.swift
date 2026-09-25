import Foundation
import Logging
import XCTest
@testable import WhiskerFlowAppSupport

final class LocalDiagnosticLogTests: XCTestCase {
    func testLocalLogDropsContentAndUnknownMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root, maxBytes: 2048)
        var logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        logger.logLevel = .info
        logger.info("secret dictated text", metadata: ["event": "paste_returned", "elapsed_ms": "12", "transcript": "private text", "token": "private token"])
        sink.flush()
        let data = try Data(contentsOf: root.appendingPathComponent("diagnostics.jsonl"))
        let line = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(line.contains("paste_returned"))
        XCTAssertTrue(line.contains("elapsed_ms"))
        XCTAssertFalse(line.contains("secret"))
        XCTAssertFalse(line.contains("private"))
        XCTAssertFalse(line.contains("transcript"))
    }

    func testRotationBoundsRetainedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root, maxBytes: 512)
        var logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        logger.logLevel = .info
        for _ in 0..<40 { logger.info("", metadata: ["event": "paste_returned", "elapsed_ms": "12"]) }
        sink.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "diagnostics.1.jsonl" })
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 512) }
    }
    func testStageAndResourceDiagnosticsPreserveOnlyTypedFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        logger.info("private content", metadata: ["event": "stage_finished", "stage": "history_save", "elapsed_ms": "500", "worker_elapsed_ms": "2", "resume_delay_ms": "498", "transcript": "private"])
        logger.info("private content", metadata: ["event": "resource_snapshot", "load_1m": "8.2", "app_cpu_percent": "155", "swap_used_bytes": "123", "memory_pressure": "warning", "thermal_state": "serious", "rss_bytes": "NaN", "path": "/private"])
        sink.flush()
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        XCTAssertTrue(lines.contains("history_save"))
        XCTAssertTrue(lines.contains("worker_elapsed_ms"))
        XCTAssertTrue(lines.contains("resume_delay_ms"))
        XCTAssertTrue(lines.contains("swap_used_bytes"))
        XCTAssertTrue(lines.contains("warning"))
        XCTAssertFalse(lines.contains("private"))
        XCTAssertFalse(lines.contains("NaN"))
    }

    func testStackFailureKeepsOnlyCategoricalReason() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        logger.warning("private error", metadata: ["event": "stack_capture_failed", "capture_failure": "no_frames", "elapsed_ms": "2000"])
        logger.warning("private error", metadata: ["event": "stack_capture_failed", "capture_failure": "/private/path"])
        sink.flush()
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        XCTAssertTrue(lines.contains("no_frames"))
        XCTAssertFalse(lines.contains("private"))
    }

    func testCaptureDiscardedKeepsOnlyTypedRouteReason() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        logger.info("private audio", metadata: ["event": "capture_discarded", "reason": "device_interruption", "conversion_failures": "4", "path": "/private"])
        sink.flush()
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        XCTAssertTrue(lines.contains("device_interruption"))
        XCTAssertTrue(lines.contains("conversion_failures"))
        XCTAssertFalse(lines.contains("private"))
    }

    func testMeetingFailureKeepsWindowCoordinatesWithoutContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.MeetingProcessing", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        logger.warning("private speech", metadata: ["event": "meeting_window_empty", "track": "mixed", "window_start_ms": "30000", "window_end_ms": "60000", "text": "private"])
        logger.warning("private speech", metadata: ["event": "meeting_window_empty", "track": "private", "window_start_ms": "private"])
        sink.flush()
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        XCTAssertTrue(lines.contains("mixed"))
        XCTAssertTrue(lines.contains("30000"))
        XCTAssertTrue(lines.contains("60000"))
        XCTAssertFalse(lines.contains("private"))
    }

    func testMeetingSpeakerProbeKeepsOnlyTypedAvailabilityAndCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.MeetingProcessing", factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        logger.info("private names", metadata: [
            "event": "meeting_speaker_probe", "availability": "available",
            "speaker_count": "2", "visual_tile_count": "4", "visual_read_failed": "false",
            "display_name": "Private Person"
        ])
        sink.flush()
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        XCTAssertTrue(lines.contains("meeting_speaker_probe"))
        XCTAssertTrue(lines.contains("available"))
        XCTAssertTrue(lines.contains("speaker_count"))
        XCTAssertTrue(lines.contains("visual_tile_count"))
        XCTAssertFalse(lines.contains("Private Person"))
    }

}

import XCTest
import Logging
@testable import WhiskerFlowAppSupport

final class ObservabilitySmokeTests: XCTestCase {
    @MainActor
    func testPerformanceWatchdogAndLatencyReachConfiguredIntake() async throws {
        guard ProcessInfo.processInfo.environment["SUPERLOG_PERFORMANCE_SMOKE"] == "1" else {
            throw XCTSkip("Set SUPERLOG_PERFORMANCE_SMOKE=1 to exercise a synthetic main queue delay and live export.")
        }
        Observability.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        blockMainQueue()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
        logger.info("Synthetic operation latency verification", metadata: ["event": "stage_finished", "stage": "ui_update", "elapsed_ms": "2500", "telemetry.smoke": "true"])
        let statuses = await Task.detached { Observability.verify(timeout: 15) }.value
        for signal in TelemetrySignal.allCases {
            let status = try XCTUnwrap(statuses[signal])
            XCTAssertTrue((200..<300).contains(status), "\(signal.rawValue) export returned HTTP \(status)")
        }
        LocalDiagnosticLog.shared.flush()
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WhiskerFlow/diagnostics.jsonl")
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]) }
            .filter { $0["launch"] == DiagnosticIdentity.current.launchID }
        let stall = try XCTUnwrap(rows.last { $0["event"] == "main_thread_stalled" })
        let recovery = try XCTUnwrap(rows.last { $0["event"] == "main_thread_recovered" })
        let stallID = try XCTUnwrap(stall["stall_id"])
        XCTAssertNotNil(UUID(uuidString: stallID))
        XCTAssertEqual(stallID, recovery["stall_id"])
        XCTAssertEqual(stall["installation_id"], DiagnosticIdentity.current.installationID)
        XCTAssertNotNil(stall["app_active"])
        XCTAssertNotNil(stall["rss_bytes"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(Double(recovery["elapsed_ms"] ?? "")), 2000)
    }

    private func blockMainQueue() {
        Thread.sleep(forTimeInterval: 2.5)
    }

    func testAllSignalsReachConfiguredIntake() throws {
        guard ProcessInfo.processInfo.environment["SUPERLOG_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set SUPERLOG_LIVE_SMOKE=1 to send the live OTLP smoke.")
        }

        let statuses = Observability.verify(timeout: 15)

        for signal in TelemetrySignal.allCases {
            let status = try XCTUnwrap(statuses[signal], "No \(signal.rawValue) request observed")
            XCTAssertTrue(
                (200..<300).contains(status),
                "\(signal.rawValue) export returned HTTP \(status)"
            )
        }
    }
}

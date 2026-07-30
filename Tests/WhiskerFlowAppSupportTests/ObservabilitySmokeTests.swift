import XCTest
@testable import WhiskerFlowAppSupport

final class ObservabilitySmokeTests: XCTestCase {
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

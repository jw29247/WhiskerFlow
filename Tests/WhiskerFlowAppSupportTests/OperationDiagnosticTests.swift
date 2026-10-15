import XCTest
import Logging
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import WhiskerFlowAppSupport

final class OperationDiagnosticTests: XCTestCase {
    func testLifecycleLogExportsDurationAndSlowCountWithoutContentDimensions() throws {
        let exporter = PerformanceMetricExporter()
        let reader = PeriodicMetricReaderBuilder(exporter: exporter).setInterval(timeInterval: 3600).build()
        let provider = MeterProviderSdk.builder()
            .registerMetricReader(reader: reader)
            .registerView(selector: InstrumentSelector.builder().setInstrument(name: ".*").build(), view: View.builder().build())
            .build()
        defer { _ = provider.shutdown() }
        let meter = provider.get(name: "test.performance")
        let logger = Logging.Logger(label: "test.performance", factory: { _ in
            PerformanceLogHandler(duration: meter.histogramBuilder(name: "app.operation.duration").build(),
                                  slowOperations: meter.counterBuilder(name: "app.operation.slow").build())
        })
        logger.info("private transcript", metadata: ["event": "stage_finished", "stage": "history_save", "elapsed_ms": "1500", "session": "private session"])
        _ = provider.forceFlush()
        let metrics = exporter.snapshot()
        let histogram = try XCTUnwrap(metrics.first { $0.name == "app.operation.duration" })
        let duration = try XCTUnwrap(histogram.data.points.first as? HistogramPointData)
        XCTAssertEqual(duration.sum, 1.5)
        XCTAssertEqual(duration.count, 1)
        XCTAssertEqual(duration.attributes, ["operation": .string("history_save")])
        let counter = try XCTUnwrap(metrics.first { $0.name == "app.operation.slow" })
        let slow = try XCTUnwrap(counter.data.points.first as? LongPointData)
        XCTAssertEqual(slow.value, 1)
        XCTAssertEqual(slow.attributes, ["operation": .string("history_save")])
    }

    func testFinishAndHotkeyLatencyUseDifferentSlowThresholds() throws {
        let finish = try XCTUnwrap(OperationDiagnostic(event: "finish_returned", fields: ["elapsed_ms": "3000"]))
        XCTAssertEqual(finish.operation, "dictation.finish")
        XCTAssertEqual(finish.seconds, 3)
        XCTAssertTrue(finish.isSlow)
        let hotkey = try XCTUnwrap(OperationDiagnostic(event: "hotkey_transition", fields: ["elapsed_ms": "300"]))
        XCTAssertEqual(hotkey.operation, "hotkey.dispatch")
        XCTAssertTrue(hotkey.isSlow)
    }

    func testUnknownStagesAndInvalidDurationsAreDropped() {
        for value in ["NaN", "inf", "-10", "private text"] {
            XCTAssertNil(OperationDiagnostic(event: "finish_returned", fields: ["elapsed_ms": value]))
        }
        XCTAssertNil(OperationDiagnostic(event: "stage_finished", fields: ["stage": "private speech", "elapsed_ms": "10"]))
        XCTAssertNil(OperationDiagnostic(event: "unknown", fields: ["elapsed_ms": "10"]))
    }

    func testStageAndCaptureTimingsMapToBoundedOperations() throws {
        let stage = try XCTUnwrap(OperationDiagnostic(event: "stage_finished", fields: ["stage": "history_save", "elapsed_ms": "1500"]))
        XCTAssertEqual(stage.operation, "history_save")
        XCTAssertTrue(stage.isSlow)
        let capture = try XCTUnwrap(OperationDiagnostic(event: "capture_start_timing", fields: ["engine_start_ms": "25"]))
        XCTAssertEqual(capture.operation, "capture.start")
        XCTAssertEqual(capture.seconds, 0.025)
        XCTAssertFalse(capture.isSlow)
    }
}

private final class PerformanceMetricExporter: MetricExporter {
    private let lock = NSLock()
    private var metrics: [MetricData] = []

    func export(metrics: [MetricData]) -> ExportResult {
        lock.lock()
        self.metrics = metrics
        lock.unlock()
        return .success
    }

    func snapshot() -> [MetricData] {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }

    func flush() -> ExportResult { .success }
    func shutdown() -> ExportResult { .success }
    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .cumulative }
}

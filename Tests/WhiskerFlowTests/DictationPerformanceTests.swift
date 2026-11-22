import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

/// Opt-in real-audio benchmark. Inputs/outputs stay outside the source tree.
final class DictationPerformanceTests: XCTestCase {
    /// Idle decay: Core ML/Neural Engine state goes cold within about a minute,
    /// which is why dictation warms the model at key press. Takes ~5 minutes.
    func testDecodeLatencyAfterIdleWithAndWithoutWarmUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISKERFLOW_BENCHMARK_IDLE_AUDIO"] else {
            throw XCTSkip("Set WHISKERFLOW_BENCHMARK_IDLE_AUDIO to a local recording for idle-decay timings")
        }
        let engine = ParakeetTDTv3Engine()
        try await engine.prepare()
        func decode(_ label: String) async throws {
            let start = ContinuousClock.now
            _ = try await engine.transcribe(TranscriptionRequest(audioURL: URL(fileURLWithPath: path), language: "en"))
            print("IDLE \(label) \(start.duration(to: .now))")
        }
        try await decode("warm-reference")
        for gap in [5, 20, 60] {
            try await Task.sleep(for: .seconds(gap))
            try await decode("cold-after-\(gap)s")
        }
        try await Task.sleep(for: .seconds(60))
        await engine.warmUpInference()
        try await Task.sleep(for: .seconds(1.5))
        try await decode("warmed-at-press-after-60s")
    }
}

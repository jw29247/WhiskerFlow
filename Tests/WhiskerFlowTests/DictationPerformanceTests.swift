import XCTest
import FluidAudio
import WhiskerFlowCore
@testable import WhiskerFlow

/// Opt-in real-audio benchmark. Inputs/outputs stay outside the source tree.
final class DictationPerformanceTests: XCTestCase {
    func testFileAndCapturedSampleTranscriptionPerformance() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["WHISKERFLOW_BENCHMARK_MANIFEST"],
              let output = env["WHISKERFLOW_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Set WHISKERFLOW_BENCHMARK_MANIFEST and WHISKERFLOW_BENCHMARK_OUTPUT for real-audio timings")
        }
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as! [[String: Any]]
        let paths = Array(Set(records.compactMap { $0["audioFilePath"] as? String })).sorted()
        let service = TranscriptionService()
        let ready = await service.prepare(kind: .parakeetTDTv3, model: .medium, language: "en")
        XCTAssertTrue(ready)
        let converter = AudioConverter()
        var measurements: [[String: Any]] = []
        for path in paths {
            let samples = try converter.resampleAudioFile(URL(fileURLWithPath: path))
            var reference: String?
            for iteration in 0..<6 {
                // Alternate which runs first to reduce systematic thermal/cache bias.
                for mode in (iteration.isMultiple(of: 2) ? ["file", "capture"] : ["capture", "file"]) {
                    let start = ContinuousClock.now
                    let outcome = try await service.transcribe(
                        audioURL: URL(fileURLWithPath: path), kind: .parakeetTDTv3,
                        model: .medium, language: "en", initialPrompt: nil,
                        cliConfiguration: WhisperConfiguration(command: "", argumentsTemplate: ""),
                        allowAppleFallback: false,
                        capturedSamples: mode == "capture" ? samples : nil
                    )
                    let result = outcome.result
                    XCTAssertEqual(outcome.engine, .parakeetTDTv3)
                    let elapsed = start.duration(to: .now)
                    let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                    if reference == nil { reference = result.text }
                    XCTAssertEqual(result.text, reference, "Captured audio must preserve file-transcription output")
                    measurements.append(["file": URL(fileURLWithPath: path).lastPathComponent, "duration": result.duration ?? Double(samples.count) / 16_000, "mode": mode, "iteration": iteration, "ms": ms, "sameText": result.text == reference, "text": result.text])
                    try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
                    print("PERF \(mode) \(result.duration)s \(ms)ms equal=\(result.text == reference)")
                }
            }
        }
    }
}

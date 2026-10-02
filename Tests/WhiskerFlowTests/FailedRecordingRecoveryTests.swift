import XCTest
import Foundation
import AVFoundation
import WhiskerFlowCore
@testable import WhiskerFlow

final class FailedRecordingRecoveryTests: XCTestCase {
    func testSavedRecordingCanBeDecoded() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISKERFLOW_RECOVERY_AUDIO"] else {
            throw XCTSkip("Explicit local recovery fixture required")
        }
        let engine = ParakeetTDTv3Engine()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        let samples = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        let direct = try? await engine.transcribe(samples: samples, language: nil)
        let result = try await engine.transcribe(TranscriptionRequest(audioURL: URL(fileURLWithPath: path), language: nil))
        XCTAssertFalse(result.text.isEmpty)
        let reference = try XCTUnwrap(direct)
        XCTAssertGreaterThanOrEqual(result.text.count, Int(Double(reference.text.count) * 0.9))
        // Never print the recovered text or store it as telemetry.
    }
}

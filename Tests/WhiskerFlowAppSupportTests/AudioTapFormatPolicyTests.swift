import AVFoundation
import XCTest
@testable import WhiskerFlowAppSupport

final class AudioTapFormatPolicyTests: XCTestCase {
    func testExplicitDeviceCaptureUsesHardwareInputFormatInsteadOfStaleOutputFormat() throws {
        let hardwareInput = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ))
        let staleDefaultOutput = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 96_000,
            channels: 1,
            interleaved: false
        ))

        let selected = AudioTapFormatPolicy.captureFormat(
            hardwareInput: hardwareInput,
            nodeOutput: staleDefaultOutput
        )

        XCTAssertEqual(selected.sampleRate, 16_000)
        XCTAssertEqual(selected.channelCount, 2)
    }
}

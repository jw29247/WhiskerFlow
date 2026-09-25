@preconcurrency import AVFoundation
import XCTest
@testable import WhiskerFlow

final class AudioCaptureConversionTests: XCTestCase {
    /// A mic plugged into input 2 of an interface must not record silence.
    func testMultichannelInputKeepsAudioThatIsNotOnChannelZero() throws {
        let input = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AudioCaptureService.makeConverter(from: input, to: target))
        XCTAssertTrue(converter.downmix)

        let frames: AVAudioFrameCount = 4_800
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            channels[0][frame] = 0
            channels[1][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000)
        }

        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 2_000))
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        XCTAssertNotEqual(status, .error)
        XCTAssertNil(error)
        let converted = Array(UnsafeBufferPointer(
            start: try XCTUnwrap(output.floatChannelData)[0], count: Int(output.frameLength)))
        XCTAssertGreaterThan(converted.count, 0)
        XCTAssertGreaterThan(converted.map(abs).max() ?? 0, 0.1)
    }

    /// Interfaces and aggregates report discrete layouts, which the converter's
    /// downmix turns into silence; the tap's own mix must keep channel 2.
    func testDiscreteLayoutMixKeepsAudioOnAnyChannel() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let mono = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))

        let frames: AVAudioFrameCount = 4_800
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            for channel in 0..<4 { channels[channel][frame] = 0 }
            channels[2][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000)
        }

        let mixed = try AudioCaptureService.mixDown(buffer, to: mono)
        XCTAssertEqual(mixed.format.channelCount, 1)
        XCTAssertEqual(mixed.frameLength, frames)
        let samples = Array(UnsafeBufferPointer(
            start: try XCTUnwrap(mixed.floatChannelData)[0], count: Int(mixed.frameLength)))
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.5, accuracy: 0.001)
    }

    /// Channels that carry the same signal average to that signal's level,
    /// and idle channels do not dilute it.
    func testDiscreteLayoutMixAveragesOnlyActiveChannels() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 8))
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let mono = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))

        let frames: AVAudioFrameCount = 4_800
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            let tone = 0.3 * sin(Float(frame) * 2 * .pi * 440 / 48_000)
            for channel in 0..<8 { channels[channel][frame] = channel.isMultiple(of: 2) ? 0.0001 : 0 }
            channels[0][frame] = tone
            channels[1][frame] = tone
        }

        let mixed = try AudioCaptureService.mixDown(buffer, to: mono)
        let samples = Array(UnsafeBufferPointer(
            start: try XCTUnwrap(mixed.floatChannelData)[0], count: Int(mixed.frameLength)))
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.3, accuracy: 0.001)
    }

    func testMonoInputIsNotDownmixed() throws {
        let input = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        XCTAssertEqual(AudioCaptureService.makeConverter(from: input, to: target)?.downmix, false)
    }

    /// Resolving a specific device translates its UID directly; it must agree
    /// with the full catalog. Vacuous on a machine with no inputs.
    func testSpecificDeviceResolutionMatchesTheCatalog() {
        for device in CoreAudioDeviceCatalog.availableInputs() {
            XCTAssertEqual(CoreAudioDeviceCatalog.resolve(.device(uid: device.uid)), device)
        }
        XCTAssertNil(CoreAudioDeviceCatalog.resolve(.device(uid: "WhiskerFlow-missing-\(UUID().uuidString)")))
    }
}

@preconcurrency import AVFoundation
import WhiskerFlowAppSupport
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

    /// Feeds `seconds` of a 440 Hz tone on `toneChannel` (silence elsewhere)
    /// through the ring in callback-sized writes, as the HAL callback would.
    private func processTone(
        sampleRate: Double, channels: Int, toneChannel: Int, seconds: Double, callbackFrames: Int = 512
    ) throws -> (chunks: [Int], samples: [Float]) {
        let plan = try HALInputCapturePlan(sampleRate: sampleRate, channelCount: channels)
        let ring = PlanarAudioRingBuffer(channelCount: channels, capacityFrames: plan.ringCapacityFrames)
        let processor = try CaptureChunkProcessor(plan: plan, ring: ring, targetSampleRate: 16_000)
        let total = Int(sampleRate * seconds)
        var buffers = (0..<channels).map { _ in [Float](repeating: 0, count: callbackFrames) }
        var chunks: [Int] = []
        var samples: [Float] = []
        var written = 0
        while written < total {
            let frames = min(callbackFrames, total - written)
            for frame in 0..<frames {
                buffers[toneChannel][frame] = 0.5 * sin(Float(written + frame) * 2 * .pi * 440 / Float(sampleRate))
            }
            let pointers = buffers.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: callbackFrames) }
            defer { pointers.forEach { $0.deallocate() } }
            for (index, pointer) in pointers.enumerated() { pointer.update(from: buffers[index], count: frames) }
            XCTAssertTrue(ring.write(frames: frames) { UnsafePointer(pointers[$0]) })
            written += frames
            processor.drain(final: false) { result in
                if let converted = try? result.get() { chunks.append(converted.count); samples += converted }
            }
        }
        processor.drain(final: true) { result in
            if let converted = try? result.get() { chunks.append(converted.count); samples += converted }
        }
        return (chunks, samples)
    }

    /// The HAL path delivers ~100 ms chunks at 16 kHz mono from a 48 kHz
    /// stereo webcam whose mic is on channel 1, and from a 4-input interface
    /// whose mic is on input 3: neither records silence.
    func testHALChunksAreSixteenKilohertzMonoFromAnyChannel() throws {
        for (rate, channels, tone) in [(48_000.0, 2, 1), (44_100.0, 4, 2), (48_000.0, 1, 0)] {
            let result = try processTone(sampleRate: rate, channels: channels, toneChannel: tone, seconds: 1.05)
            XCTAssertEqual(Double(result.samples.count), 16_000 * 1.05, accuracy: 400, "\(rate) Hz × \(channels)")
            XCTAssertGreaterThan(result.chunks.count, 9)
            // The resampler emits in its own packet sizes, so "about 100 ms".
            XCTAssertTrue(result.chunks.dropLast().allSatisfy { (1_200...2_000).contains($0) }, "\(result.chunks)")
            XCTAssertGreaterThan(result.samples.map(abs).max() ?? 0, 0.4, "\(rate) Hz × \(channels)")
        }
    }

    func testSixteenKilohertzMonoDevicesPassStraightThrough() throws {
        let result = try processTone(sampleRate: 16_000, channels: 1, toneChannel: 0, seconds: 0.5, callbackFrames: 160)
        XCTAssertEqual(result.samples.count, 8_000)
        XCTAssertEqual(result.chunks, [1_600, 1_600, 1_600, 1_600, 1_600])
        XCTAssertEqual(result.samples[100], 0.5 * sin(100 * 2 * .pi * 440 / 16_000), accuracy: 1e-6)
    }

    /// Stopping drains the partial chunk too, so the spool gets every frame.
    func testFinalDrainDeliversThePartialChunk() throws {
        let result = try processTone(sampleRate: 16_000, channels: 1, toneChannel: 0, seconds: 0.25, callbackFrames: 100)
        XCTAssertEqual(result.chunks, [1_600, 1_600, 800])
    }

    func testDeviceFormatsPastTwoChannelsUseADiscreteLayout() throws {
        let plan = try HALInputCapturePlan(sampleRate: 48_000, channelCount: 8)
        let format = try XCTUnwrap(CaptureChunkProcessor.deviceFormat(for: plan))
        XCTAssertEqual(format.channelCount, 8)
        XCTAssertFalse(format.isInterleaved)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
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

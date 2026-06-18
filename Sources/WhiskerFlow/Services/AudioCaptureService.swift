import AVFoundation
import Foundation
import WhisperKit

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Microphone helpers shared across the app. Live capture itself now runs
/// through WhisperKit's `AudioProcessor` (see `LiveDictationSession`); this type
/// only handles permission, device enumeration, and persisting captured samples.
enum Microphone {
    /// Request microphone (TCC) access. The same grant covers both
    /// `AVCaptureDevice` and the `AVAudioEngine` input tap `AudioProcessor` uses.
    static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    /// Input devices as seen by CoreAudio (the same id space `AudioProcessor`
    /// uses). The id is the numeric `AudioDeviceID` rendered as a string.
    static func availableInputDevices() -> [AudioInputDevice] {
        AudioProcessor.getAudioDevices().map { AudioInputDevice(id: String($0.id), name: $0.name) }
    }

    /// Resolve a stored device id string back to a CoreAudio `DeviceID`,
    /// or `nil` to fall back to the system default input.
    static func deviceID(from stored: String) -> DeviceID? {
        guard !stored.isEmpty, let value = UInt32(stored) else { return nil }
        return value
    }
}

enum AudioFileWriter {
    /// Persist a 16 kHz mono float buffer to a 16-bit PCM WAV so the recording
    /// shows up in History and can be re-transcribed (retry / non-streaming
    /// engines). WAV is read natively by WhisperKit, Apple Speech, and ffmpeg.
    static func writeWAV(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(WhisperKit.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard
            !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Application Support folder where recordings live.
    static func makeRecordingURL() throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhiskerFlow/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(UUID().uuidString).wav")
    }
}

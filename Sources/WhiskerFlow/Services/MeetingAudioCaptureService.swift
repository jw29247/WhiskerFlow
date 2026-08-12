@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import WhiskerFlowAppSupport

enum MeetingAudioCaptureError: LocalizedError {
    case microphoneUnavailable
    case screenRecordingPermissionRequired
    case displayUnavailable
    case streamStartFailed(String)
    case sampleConversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "The microphone is unavailable."
        case .screenRecordingPermissionRequired: return "Screen Recording permission is required to capture Mac audio."
        case .displayUnavailable: return "No Mac display is available for system-audio capture."
        case .streamStartFailed(let message): return "Mac audio capture could not start: \(message)"
        case .sampleConversionFailed: return "Mac audio could not be normalized for recording."
        }
    }
}

/// Captures microphone and Mac output independently, then writes a mixed track
/// from aligned 16 kHz mono samples. ScreenCaptureKit is used only for its audio
/// output; no screen frames are retained or uploaded.
@MainActor
final class MeetingAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private let microphone: AudioCaptureService
    private let store: EncryptedMeetingChunkStore
    private let sessionID: UUID
    private let writer: MeetingPCMChunkWriter
    private let microphonePending = LockedAudioBuffer()
    private let systemPending = LockedAudioBuffer()
    private var stream: SCStream?
    private var isRunning = false
    private var systemSampleCount = 0

    var onFailure: ((Error) -> Void)?
    var onLevel: ((Float) -> Void)?

    init(
        microphone: AudioCaptureService? = nil,
        store: EncryptedMeetingChunkStore,
        sessionID: UUID
    ) {
        self.microphone = microphone ?? AudioCaptureService()
        self.store = store
        self.sessionID = sessionID
        self.writer = MeetingPCMChunkWriter(store: store, sessionID: sessionID)
        super.init()
    }

    func start(selection: AudioInputSelection) async throws {
        guard !isRunning else { return }
        microphone.onSamples = { [weak self] samples in
            guard let self else { return }
            do {
                _ = try writer.append(samples, track: .microphone)
                microphonePending.append(samples)
                try mixAvailable()
            } catch {
                onFailure?(error)
            }
        }
        microphone.onLevel = { [weak self] level, _ in self?.onLevel?(level) }
        try microphone.start(selection: selection)

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { throw MeetingAudioCaptureError.displayUnavailable }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = MeetingPCMChunkWriter.sampleRate
            configuration.channelCount = 1
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 2
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "agency.thatworks.WhiskerFlow.meeting-audio")
            )
            try await stream.startCapture()
            self.stream = stream
            isRunning = true
        } catch {
            microphone.cancel()
            microphone.onSamples = nil
            if let error = error as? MeetingAudioCaptureError { throw error }
            throw MeetingAudioCaptureError.streamStartFailed(error.localizedDescription)
        }
  }

  func stop() async throws -> [MeetingRecordingChunkDescriptor] {
    if let stream {
      try? await stream.stopCapture()
    }
        self.stream = nil
        isRunning = false
        _ = microphone.stop(reason: .userReleased)
        microphone.onSamples = nil
        try mixAvailable(flushRemainder: true)
        return try writer.finish()
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        isRunning = false
        microphone.cancel()
        microphone.onSamples = nil
    }

    func chunkCounts() -> [MeetingAudioTrack: Int] {
        writer.chunkCounts()
    }

    var sourceGapDetected: Bool {
        writer.sourceGapDetected || abs(microphonePending.count - systemPending.count) > MeetingPCMChunkWriter.sampleRate / 2
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, let samples = Self.samples(from: sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try writer.append(samples, track: .system, sourceStartMs: Int64(systemSampleCount / 16))
                systemSampleCount += samples.count
                systemPending.append(samples)
                try mixAvailable()
            } catch {
                onFailure?(error)
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isRunning = false
            onFailure?(error)
        }
    }

    private func mixAvailable(flushRemainder: Bool = false) throws {
        let available = min(microphonePending.count, systemPending.count)
        let count = flushRemainder ? available : (available / MeetingPCMChunkWriter.chunkSampleCount) * MeetingPCMChunkWriter.chunkSampleCount
        guard count > 0 else { return }
        let mic = microphonePending.drainPrefix(count)
        let system = systemPending.drainPrefix(count)
        let mixed = zip(mic, system).map { max(-1, min(1, ($0 + $1) * 0.5)) }
        _ = try writer.append(mixed, track: .mixed)
    }

    nonisolated private static func samples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        var requiredSize = 0
        var blockBuffer: CMBlockBuffer?
        let firstStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard firstStatus == noErr, requiredSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            raw.deallocate()
        }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let data = first.mData else { return nil }
        let channelCount = max(1, Int(first.mNumberChannels))
        let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let values = data.bindMemory(to: Float.self, capacity: sampleCount)
        if channelCount == 1 { return Array(UnsafeBufferPointer(start: values, count: sampleCount)) }
        return stride(from: 0, to: sampleCount, by: channelCount).map { frame in
            var total: Float = 0
            for channel in 0..<channelCount { total += values[frame + channel] }
            return total / Float(channelCount)
        }
    }
}

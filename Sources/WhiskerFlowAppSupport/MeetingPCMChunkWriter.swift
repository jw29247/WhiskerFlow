import Foundation

/// Converts normalized 16 kHz mono Float32 samples into encrypted, fixed-size
/// meeting chunks. The writer is deliberately independent of AVAudioEngine and
/// ScreenCaptureKit so crash/recovery behavior is testable without TCC access.
public final class MeetingPCMChunkWriter: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let chunkDurationMs: Int64 = 10_000
    public static let chunkSampleCount = sampleRate * 10

    private let store: EncryptedMeetingChunkStore
    private let sessionID: UUID
    private let lock = NSLock()
    private var buffers: [MeetingAudioTrack: [Float]] = [:]
    private var nextSequences: [MeetingAudioTrack: Int] = [:]
    private var hasSourceGap = false

    public init(store: EncryptedMeetingChunkStore, sessionID: UUID) {
        self.store = store
        self.sessionID = sessionID
    }

    public var sourceGapDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSourceGap
    }

    @discardableResult
    public func append(
        _ samples: [Float],
        track: MeetingAudioTrack,
        sourceStartMs: Int64? = nil
    ) throws -> [MeetingRecordingChunkDescriptor] {
        try withLock {
            guard !samples.isEmpty else { return [] }
            if let sourceStartMs,
               let expected = nextSequences[track].map({ Int64($0) * Self.chunkDurationMs }),
               abs(sourceStartMs - expected) > Self.chunkDurationMs {
                hasSourceGap = true
            }
            buffers[track, default: []].append(contentsOf: samples)
            return try flushReadyLocked(track: track)
        }
    }

    public func finish() throws -> [MeetingRecordingChunkDescriptor] {
        try withLock {
            var descriptors: [MeetingRecordingChunkDescriptor] = []
            for track in MeetingAudioTrack.allCases {
                guard let samples = buffers[track], !samples.isEmpty else { continue }
                descriptors.append(try writeLocked(track: track, samples: samples))
                buffers[track] = []
            }
            return descriptors
        }
    }

    public func chunkCounts() -> [MeetingAudioTrack: Int] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: MeetingAudioTrack.allCases.map { track in
            (track, (nextSequences[track] ?? 0) + ((buffers[track]?.isEmpty == false) ? 1 : 0))
        })
    }

    private func flushReadyLocked(track: MeetingAudioTrack) throws -> [MeetingRecordingChunkDescriptor] {
        var descriptors: [MeetingRecordingChunkDescriptor] = []
        while let samples = buffers[track], samples.count >= Self.chunkSampleCount {
            let chunkSamples = Array(samples.prefix(Self.chunkSampleCount))
            buffers[track] = Array(samples.dropFirst(Self.chunkSampleCount))
            descriptors.append(try writeLocked(track: track, samples: chunkSamples))
        }
        return descriptors
    }

    private func writeLocked(
        track: MeetingAudioTrack,
        samples: [Float]
    ) throws -> MeetingRecordingChunkDescriptor {
        let sequence = nextSequences[track] ?? 0
        let startMs = Int64(sequence) * Self.chunkDurationMs
        let endMs = startMs + max(1, Int64((Double(samples.count) / Double(Self.sampleRate) * 1_000).rounded()))
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let descriptor = try store.writeChunk(
            sessionID: sessionID,
            track: track,
            sequence: sequence,
            startMs: startMs,
            endMs: endMs,
            plaintext: data
        )
        nextSequences[track] = sequence + 1
        return descriptor
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

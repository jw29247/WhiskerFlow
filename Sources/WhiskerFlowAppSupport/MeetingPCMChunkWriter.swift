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
    /// After a failed write, wait for another chunk's worth of audio before
    /// retrying so a full disk is not re-encrypted on every audio callback.
    private var retryAtBufferedCount: [MeetingAudioTrack: Int] = [:]
    private var hasSourceGap = false
    /// Chunks retained in memory while writes fail. Beyond this the oldest
    /// chunk is dropped and its sequence skipped, so later audio keeps its
    /// true timeline and the recording is marked with a source gap.
    public static let maximumBufferedChunks = 6

    public init(store: EncryptedMeetingChunkStore, sessionID: UUID) {
        self.store = store
        self.sessionID = sessionID
    }

    public var sourceGapDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSourceGap
    }

    /// Marks audio that the capture pipeline knows is missing, for example a
    /// silence-padded microphone re-arm or ScreenCaptureKit restart.
    public func markSourceGap() {
        lock.lock()
        hasSourceGap = true
        lock.unlock()
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
            if let retryAt = retryAtBufferedCount[track], (buffers[track]?.count ?? 0) < retryAt {
                return []
            }
            return try flushReadyLocked(track: track)
        }
    }

    public func finish() throws -> [MeetingRecordingChunkDescriptor] {
        try withLock {
            var descriptors: [MeetingRecordingChunkDescriptor] = []
            var firstError: Error?
            // Attempt every track even if one fails, so one bad write does not
            // discard the other sources' final seconds.
            for track in MeetingAudioTrack.allCases {
                do {
                    descriptors.append(contentsOf: try flushReadyLocked(track: track))
                    guard let samples = buffers[track], !samples.isEmpty else { continue }
                    descriptors.append(try writeLocked(track: track, samples: samples))
                    buffers[track] = []
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError { throw firstError }
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
            do {
                descriptors.append(try writeLocked(track: track, samples: chunkSamples))
            } catch {
                // Keep the samples: the store may recover (for example after
                // space is freed). Only a sustained failure drops audio, and
                // then with its sequence skipped rather than reused.
                if samples.count >= Self.maximumBufferedChunks * Self.chunkSampleCount {
                    buffers[track]?.removeFirst(Self.chunkSampleCount)
                    nextSequences[track] = (nextSequences[track] ?? 0) + 1
                    hasSourceGap = true
                }
                retryAtBufferedCount[track] = (buffers[track]?.count ?? 0) + Self.chunkSampleCount
                throw error
            }
            // Drop the samples only after the chunk is durable.
            buffers[track]?.removeFirst(Self.chunkSampleCount)
            retryAtBufferedCount[track] = nil
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

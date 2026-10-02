import Foundation

/// Keeps only the live decoding tail resident while forwarding every sample to
/// durable capture storage. Positions are absolute within the complete capture.
public final class BoundedAudioCaptureBuffer: @unchecked Sendable {
    public typealias DurableAppend = @Sendable ([Float]) throws -> Void

    /// Guards the counters and resident tail that readers snapshot.
    private let lock = NSLock()
    /// Serialises durable writes so disk I/O never holds `lock`.
    private let writeLock = NSLock()
    private let maximumResidentSamples: Int
    private let durableAppend: DurableAppend
    /// Live tail is `residentStorage[residentHead...]`. Dropping old samples
    /// only advances the head; storage is compacted once the dead prefix is
    /// large, so trimming a 30 s tail is not a full memmove on every buffer.
    private var residentStorage: [Float] = []
    private var residentHead = 0
    private var storedSampleCount = 0
    private var appendError: Error?

    public init(maximumResidentSamples: Int, durableAppend: @escaping DurableAppend) {
        self.maximumResidentSamples = max(1, maximumResidentSamples)
        self.durableAppend = durableAppend
    }

    @discardableResult
    public func append(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard failure == nil else { return false }
        do {
            try durableAppend(samples)
        } catch {
            lock.withLock { appendError = error }
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        storedSampleCount += samples.count
        residentStorage.append(contentsOf: samples)
        let residentCount = residentStorage.count - residentHead
        if residentCount > maximumResidentSamples {
            residentHead += residentCount - maximumResidentSamples
        }
        if residentHead >= max(1, maximumResidentSamples / 2) {
            residentStorage.removeFirst(residentHead)
            residentHead = 0
        }
        return true
    }

    public var totalSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSampleCount
    }

    public var residentSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return residentStorage.count - residentHead
    }

    public var residentStartSample: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSampleCount - (residentStorage.count - residentHead)
    }

    /// Returns nil when the requested position has already been spooled out of
    /// memory. The caller must then use bounded reads from the durable recording.
    public func residentSuffix(fromAbsoluteSample index: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let residentCount = residentStorage.count - residentHead
        let start = storedSampleCount - residentCount
        guard index >= start else { return nil }
        let local = max(0, min(index - start, residentCount))
        return Array(residentStorage[(residentHead + local)...])
    }

    public var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return appendError
    }
}

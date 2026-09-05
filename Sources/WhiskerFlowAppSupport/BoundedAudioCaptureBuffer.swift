import Foundation

/// Keeps only the live decoding tail resident while forwarding every sample to
/// durable capture storage. Positions are absolute within the complete capture.
public final class BoundedAudioCaptureBuffer: @unchecked Sendable {
    public typealias DurableAppend = @Sendable ([Float]) throws -> Void

    private let lock = NSLock()
    private let maximumResidentSamples: Int
    private let durableAppend: DurableAppend
    private var resident: [Float] = []
    private var storedSampleCount = 0
    private var appendError: Error?

    public init(maximumResidentSamples: Int, durableAppend: @escaping DurableAppend) {
        self.maximumResidentSamples = max(1, maximumResidentSamples)
        self.durableAppend = durableAppend
    }

    @discardableResult
    public func append(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard appendError == nil else { return false }
        do {
            try durableAppend(samples)
            storedSampleCount += samples.count
            resident.append(contentsOf: samples)
            if resident.count > maximumResidentSamples {
                resident.removeFirst(resident.count - maximumResidentSamples)
            }
            return true
        } catch {
            appendError = error
            return false
        }
    }

    public var totalSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSampleCount
    }

    public var residentSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resident.count
    }

    public var residentStartSample: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSampleCount - resident.count
    }

    /// Returns nil when the requested position has already been spooled out of
    /// memory. The caller must then use bounded reads from the durable recording.
    public func residentSuffix(fromAbsoluteSample index: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let start = storedSampleCount - resident.count
        guard index >= start else { return nil }
        let local = max(0, min(index - start, resident.count))
        return Array(resident[local...])
    }

    public var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return appendError
    }
}

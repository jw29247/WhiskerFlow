import Foundation

public final class LockedAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    public init() {}

    public func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// The samples from `index` onwards. `index` is clamped, so a caller holding
    /// a stale offset gets the whole buffer or an empty tail rather than a trap.
    public func suffix(from index: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples[max(0, min(index, samples.count))...])
    }

    public func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}

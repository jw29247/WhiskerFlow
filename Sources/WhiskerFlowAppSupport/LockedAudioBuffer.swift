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

    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    public func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}

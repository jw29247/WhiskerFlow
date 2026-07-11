public struct AudioConfigurationObservationGate: Sendable {
    private var generation: UInt64 = 0
    private var armedGeneration: UInt64?

    public init() {}

    public mutating func captureStarted() -> UInt64 {
        generation &+= 1
        armedGeneration = nil
        return generation
    }

    public mutating func arm(_ candidate: UInt64) -> Bool {
        guard candidate == generation else { return false }
        armedGeneration = candidate
        return true
    }

    public func shouldHandleChange(for candidate: UInt64) -> Bool {
        armedGeneration == candidate
    }

    public mutating func captureStopped() {
        generation &+= 1
        armedGeneration = nil
    }
}

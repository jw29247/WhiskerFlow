import Foundation

public struct AudioConfigurationObservationGate: Sendable {
    private var generation: UInt64 = 0
    private var armedGeneration: UInt64?
    private var reportedGeneration: UInt64?

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

    /// A configuration notification and the capture watchdog can both notice
    /// the same stop; only the first may end the capture.
    public mutating func claimInterruption(for candidate: UInt64) -> Bool {
        guard armedGeneration == candidate, reportedGeneration != candidate else { return false }
        reportedGeneration = candidate
        return true
    }

    public mutating func captureStopped() {
        generation &+= 1
        armedGeneration = nil
    }
}

/// Catches a running capture that lost its microphone without a device
/// change being seen (`CaptureDeviceExpectation` covers those): a capture
/// unit that stopped, or buffers that stop arriving while the unit claims to
/// run — some Bluetooth routes vanish without stopping anything.
public struct CaptureInterruptionDetector: Sendable {
    /// Generous enough that no scheduling hiccup on a slow Mac trips it;
    /// buffers normally arrive about ten times a second.
    public static let defaultStallInterval: TimeInterval = 4

    public let stallInterval: TimeInterval
    private var lastBufferCount = 0
    private var lastProgressAt: TimeInterval?

    public init(stallInterval: TimeInterval = Self.defaultStallInterval) {
        self.stallInterval = stallInterval
    }

    /// Before the first buffer nothing counts as a stall: Bluetooth inputs
    /// can take seconds to deliver one, and callers check for that themselves.
    public mutating func isInterrupted(
        deliveredBufferCount: Int,
        engineIsRunning: Bool,
        now: TimeInterval
    ) -> Bool {
        guard engineIsRunning else { return true }
        if deliveredBufferCount != lastBufferCount {
            lastBufferCount = deliveredBufferCount
            lastProgressAt = now
            return false
        }
        guard deliveredBufferCount > 0, let lastProgressAt else { return false }
        return now - lastProgressAt >= stallInterval
    }
}

import Foundation

public enum RecordingPhase: Equatable, Sendable {
    case idle
    case preparing(UUID)
    case recording(UUID)
    case finishing(UUID)

    public var isCapturing: Bool {
        if case .recording = self { return true }
        return false
    }

    public var controlsAreLocked: Bool {
        self != .idle
    }
}

public enum CaptureStopReason: Equatable, Sendable {
    case userReleased
    case deviceDisconnected
    case cancelled
    case failed
}

public struct CapturedAudio: Equatable, Sendable {
    public let samples: [Float]
    public let stopReason: CaptureStopReason
    /// Buffers the capture tap failed to convert. Non-zero with no samples means
    /// the mic delivered audio we could not use — not that the user stayed silent.
    public let conversionFailureCount: Int

    public init(
        samples: [Float],
        stopReason: CaptureStopReason,
        conversionFailureCount: Int = 0
    ) {
        self.samples = samples
        self.stopReason = stopReason
        self.conversionFailureCount = conversionFailureCount
    }

    public var reportsUnusableInput: Bool {
        samples.isEmpty && conversionFailureCount > 0
    }
}

@MainActor
public final class RecordingCoordinator {
    public private(set) var phase: RecordingPhase = .idle
    public private(set) var stopReason: CaptureStopReason?

    public init() {}

    public func requestStart() -> UUID? {
        guard phase == .idle else { return nil }
        let sessionID = UUID()
        stopReason = nil
        phase = .preparing(sessionID)
        return sessionID
    }

    @discardableResult
    public func didStart(_ sessionID: UUID) -> Bool {
        guard phase == .preparing(sessionID) else { return false }
        phase = .recording(sessionID)
        return true
    }

    @discardableResult
    public func requestFinish(
        _ sessionID: UUID,
        reason: CaptureStopReason = .userReleased
    ) -> Bool {
        guard phase == .recording(sessionID) else { return false }
        stopReason = reason
        phase = .finishing(sessionID)
        return true
    }

    @discardableResult
    public func didFinish(_ sessionID: UUID) -> Bool {
        guard phase == .finishing(sessionID) else { return false }
        phase = .idle
        return true
    }

    /// Recover from a stuck phase when no session token is trustworthy any more
    /// (e.g. a wedged decode that never reported back).
    @discardableResult
    public func forceIdle() -> Bool {
        guard phase != .idle else { return false }
        stopReason = .failed
        phase = .idle
        return true
    }

    @discardableResult
    public func fail(_ sessionID: UUID) -> Bool {
        switch phase {
        case .preparing(sessionID), .recording(sessionID), .finishing(sessionID):
            stopReason = .failed
            phase = .idle
            return true
        default:
            return false
        }
    }
}

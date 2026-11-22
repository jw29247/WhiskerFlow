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
    /// A toggle recording reached one of `ToggleRecordingLimits`.
    case autoStopped(ToggleAutoStop)

    /// A fixed token for diagnostics; never free text. The older reasons keep
    /// the names `String(describing:)` gave them.
    public var diagnosticName: String {
        switch self {
        case .userReleased: return "userReleased"
        case .deviceDisconnected: return "deviceDisconnected"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .autoStopped(let limit): return "autoStopped.\(limit.rawValue)"
        }
    }

    /// An ordinary end of capture, so the engine can be kept for the next one.
    public var endsNormally: Bool {
        switch self {
        case .userReleased, .autoStopped: return true
        case .deviceDisconnected, .cancelled, .failed: return false
        }
    }
}

public struct CapturedAudio: Equatable, Sendable {
    public let samples: [Float]
    public let audioURL: URL?
    public let totalSampleCount: Int
    /// Absolute sample index represented by `samples[0]`. This is zero for
    /// ordinary in-memory captures and advances when a disk-backed capture has
    /// discarded its older resident tail.
    public let residentStartSample: Int
    public let stopReason: CaptureStopReason
    /// Buffers the capture tap failed to convert. Non-zero with no samples means
    /// the mic delivered audio we could not use — not that the user stayed silent.
    public let conversionFailureCount: Int
    /// The durable recording stopped accepting audio (for example, a full
    /// disk). Everything before the failure is still in the capture, but
    /// later speech is missing; this is a storage problem, not a microphone one.
    public let storageFailed: Bool

    public init(
        samples: [Float],
        stopReason: CaptureStopReason,
        conversionFailureCount: Int = 0,
        audioURL: URL? = nil,
        totalSampleCount: Int? = nil,
        residentStartSample: Int = 0,
        storageFailed: Bool = false
    ) {
        self.samples = samples
        self.stopReason = stopReason
        self.conversionFailureCount = conversionFailureCount
        self.audioURL = audioURL
        self.totalSampleCount = totalSampleCount ?? samples.count
        self.residentStartSample = residentStartSample
        self.storageFailed = storageFailed
    }

    public var reportsUnusableInput: Bool {
        totalSampleCount == 0 && conversionFailureCount > 0
    }

}

@MainActor
public final class RecordingCoordinator {
    public private(set) var phase: RecordingPhase = .idle
    public private(set) var stopReason: CaptureStopReason?

    private var discardedWhilePreparing: UUID?

    public init() {}

    public func requestStart() -> UUID? {
        guard phase == .idle else { return nil }
        let sessionID = UUID()
        stopReason = nil
        discardedWhilePreparing = nil
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

    /// What `requestDiscard()` stopped, so the caller knows whether a live
    /// capture has to be torn down.
    public enum Discard: Equatable, Sendable {
        /// The microphone was still opening. The session moves to `finishing`
        /// so no new dictation can start on the shared capture until the start
        /// in flight has backed out and called `completeDiscard`.
        case preparing(UUID)
        /// The microphone is live; the caller stops it without transcribing,
        /// then completes the session with `didFinish`.
        case recording(UUID)
    }

    /// Ends the dictation being prepared or recorded without transcribing it.
    /// Returns `nil` when nothing is being recorded, including while a finished
    /// recording is being transcribed.
    @discardableResult
    public func requestDiscard() -> Discard? {
        switch phase {
        case .preparing(let sessionID):
            stopReason = .cancelled
            phase = .finishing(sessionID)
            discardedWhilePreparing = sessionID
            return .preparing(sessionID)
        case .recording(let sessionID):
            stopReason = .cancelled
            phase = .finishing(sessionID)
            return .recording(sessionID)
        case .finishing, .idle:
            return nil
        }
    }

    /// Called when a start returns, however it ended. Releases a session that
    /// was discarded while preparing; does nothing otherwise.
    @discardableResult
    public func completeDiscard(_ sessionID: UUID) -> Bool {
        guard discardedWhilePreparing == sessionID else { return false }
        discardedWhilePreparing = nil
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

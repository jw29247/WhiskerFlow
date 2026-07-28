import Foundation

/// Deadlines for on-device decodes. A CoreML decode that wedges never returns
/// and ignores cancellation, so callers abandon it once its budget is spent.
public enum DecodeTimeoutPolicy {
    /// Hard ceiling, also used when the audio duration is unknown.
    public static let maximumTimeout: Double = 300
    /// Budget for a live partial decode of the growing buffer.
    public static let livePartialTimeout: Double = 20

    public static func timeout(forAudioSeconds duration: Double) -> Double {
        min(max(30, 3 * duration + 15), maximumTimeout)
    }
}

import Foundation

/// Deadlines for on-device decodes. A CoreML decode that wedges never returns
/// and ignores cancellation, so callers abandon it once its budget is spent.
public enum DecodeTimeoutPolicy {
    /// Hard ceiling, also used when the audio duration is unknown.
    public static let maximumTimeout: Double = 300
    /// Budget for a live partial decode of the growing buffer. A live window never
    /// exceeds `LiveDecodeWindowPolicy.hardCapSeconds`, so it needs nothing like the
    /// file-decode budget — and keeping it small is what lets the finish watchdog
    /// sit above the worst legitimate release.
    public static let livePartialTimeout: Double = 20
    /// Live decodes a single release can end up awaiting one after another: the
    /// window decode already in flight, the confirm pass's prefix decode, and the
    /// recovery decode of the unconfirmed tail.
    public static let livePartialsPerRelease = 3

    /// Longest a release may legitimately spend inside the live session's teardown.
    /// A watchdog below this reports slow decodes as failures; above it, only a
    /// genuine wedge trips.
    public static var liveFinishBudget: Double {
        livePartialTimeout * Double(livePartialsPerRelease)
    }

    public static func timeout(forAudioSeconds duration: Double) -> Double {
        min(max(30, 3 * duration + 15), maximumTimeout)
    }
}

import Foundation

/// Deadlines for on-device decodes. A CoreML decode that wedges never returns
/// and ignores cancellation, so callers abandon it once its budget is spent.
public enum DecodeTimeoutPolicy {
    /// Budgets below are tuned for a 16 GB+ Apple Silicon Mac. A base 8 GB
    /// machine swaps with several models resident, and Intel (or Rosetta) runs
    /// Core ML without the Neural Engine, so both get proportionally longer
    /// before a slow-but-healthy decode is abandoned as wedged.
    public static let hardwareScale: Double = hardwareScale(
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        isAppleSilicon: isNativeAppleSilicon
    )

    public static func hardwareScale(physicalMemoryBytes: UInt64, isAppleSilicon: Bool) -> Double {
        guard isAppleSilicon else { return 3 }
        return physicalMemoryBytes < 12 * 1_024 * 1_024 * 1_024 ? 2 : 1
    }

    private static var isNativeAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Hard ceiling, also used when the audio duration is unknown.
    public static var maximumTimeout: Double { baseMaximumTimeout * hardwareScale }
    public static let baseMaximumTimeout: Double = 300
    /// Budget for a short decode on the release path. Keeping it small is what
    /// lets the finish watchdog sit above the worst legitimate release.
    public static var livePartialTimeout: Double { baseLivePartialTimeout * hardwareScale }
    public static let baseLivePartialTimeout: Double = 20
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
        timeout(forAudioSeconds: duration, scale: hardwareScale)
    }

    public static func timeout(forAudioSeconds duration: Double, scale: Double) -> Double {
        min(max(30, 3 * duration + 15), baseMaximumTimeout) * scale
    }

    /// Whole-file decodes that are not split into bounded windows (Parakeet's
    /// disk-backed decode). Past the short-audio budget this grows at real time
    /// plus a minute instead of clamping, so a long dictation is never abandoned
    /// merely for being long; a healthy decode runs far faster than real time.
    public static func longFormTimeout(forAudioSeconds duration: Double, scale: Double = hardwareScale) -> Double {
        max(timeout(forAudioSeconds: duration, scale: scale), (max(0, duration) + 60) * scale)
    }

    /// Apple Speech file recognition. On-device recognition runs at roughly real
    /// time on older Macs, so the budget follows the recording length.
    public static func appleSpeechTimeout(forAudioSeconds duration: Double, scale: Double = hardwareScale) -> Double {
        max(90, 2 * max(0, duration) + 30) * scale
    }

    /// How long a caller that must decode (not a live partial) waits for another
    /// Core ML operation to release the shared gate: about one bounded-window
    /// decode, the longest thing that legitimately holds it besides a model load.
    public static var gateQueueWait: Double {
        timeout(forAudioSeconds: BoundedDecodeWindowPolicy.windowSeconds)
    }

    /// How long a decode waits for its model to finish loading before giving up
    /// (the load itself keeps running). Covers a first-run download and Core ML
    /// compile on a slow Mac.
    public static var modelPreparationWait: Double { 180 * hardwareScale }
}

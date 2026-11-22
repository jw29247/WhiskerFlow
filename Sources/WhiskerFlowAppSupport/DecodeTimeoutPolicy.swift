import Foundation

/// Deadlines for on-device decodes. A CoreML decode that wedges never returns
/// and ignores cancellation, so callers abandon it once its budget is spent.
public enum DecodeTimeoutPolicy {
    /// Budgets below are tuned for a 16 GB+ Apple Silicon Mac. A base 8 GB
    /// machine swaps with several models resident, so it gets proportionally
    /// longer before a slow-but-healthy decode is abandoned as wedged.
    public static let hardwareScale: Double = hardwareScale(
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )

    public static func hardwareScale(physicalMemoryBytes: UInt64) -> Double {
        physicalMemoryBytes < 12 * 1_024 * 1_024 * 1_024 ? 2 : 1
    }

    /// Hard ceiling, also used when the audio duration is unknown.
    public static var maximumTimeout: Double { baseMaximumTimeout * hardwareScale }
    public static let baseMaximumTimeout: Double = 300
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

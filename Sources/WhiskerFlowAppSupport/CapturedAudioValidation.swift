import Foundation

/// Validation applied before a captured file is handed to a speech recognizer.
///
/// The local engines reject audio shorter than 300 ms. Treating those taps as
/// retryable transcript failures leaves the app in an attention state even
/// though there is no recoverable speech. A short, complete capture that is
/// also below the normal audio floor is the same kind of non-dictation input.
public enum CapturedAudioDiscardReason: String, Equatable, Sendable {
    case empty
    case tooShort
    case silent
}

public enum CapturedAudioValidation {
    public static let sampleRate = 16_000
    public static let minimumDurationSeconds = 0.3
    public static let minimumSampleCount = Int(Double(sampleRate) * minimumDurationSeconds)

    /// A CoreAudio route rebuild can stop the engine before its first buffer.
    /// There is no recoverable transcript in that case, so the interruption
    /// should return the HUD to Ready instead of becoming a failed dictation.
    public static func shouldDismissEmptyDeviceInterruption(
        stopReason: CaptureStopReason,
        totalSampleCount: Int
    ) -> Bool {
        stopReason == .deviceDisconnected && totalSampleCount == 0
    }

    /// Returns a reason when a capture should never enter the transcription or
    /// retry queue. For long captures the resident samples may be only a tail;
    /// in that case the caller must retain the recording for normal recovery.
    public static func discardReason(
        totalSampleCount: Int,
        residentSamples: [Float]
    ) -> CapturedAudioDiscardReason? {
        guard totalSampleCount > 0 else { return .empty }
        guard totalSampleCount == residentSamples.count else {
            // A long recording may expose only its resident tail. Do not make a
            // decision about the whole file from that partial view.
            return totalSampleCount < minimumSampleCount ? .tooShort : nil
        }
        guard BoundedDecodeWindowPolicy.containsAudibleActivity(
            residentSamples,
            sampleRate: sampleRate
        ) else {
            return .silent
        }
        return totalSampleCount < minimumSampleCount ? .tooShort : nil
    }
}

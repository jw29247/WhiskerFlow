import Foundation

/// Validation applied before a captured file is handed to a speech recognizer.
///
/// The local engines reject audio shorter than 300 ms. Treating those taps as
/// retryable transcript failures leaves the app in an attention state even
/// though there is no recoverable speech. A short (at most two seconds),
/// complete capture that never rises above the silence floor is the same kind
/// of non-dictation input.
public enum CapturedAudioDiscardReason: String, Equatable, Sendable {
    case empty
    case tooShort
    case silent
}

public enum CapturedAudioValidation {
    public static let sampleRate = 16_000
    public static let minimumDurationSeconds = 0.3
    public static let minimumSampleCount = Int(Double(sampleRate) * minimumDurationSeconds)
    /// Silence is only judged for a capture this short — a stray tap or a press
    /// released before speaking. Anything longer keeps its audio and lets the
    /// recognizer decide, since a soft speaker on a distant mic can sit below any
    /// fixed floor and deleting real speech cannot be undone.
    public static let maximumSilentDiscardSeconds = 2.0
    public static let maximumSilentDiscardSampleCount = Int(Double(sampleRate) * maximumSilentDiscardSeconds)
    /// About -46 dBFS on a 100 ms frame: below the HUD's "too quiet" warning
    /// (about -45 dBFS) and the live window's speech line (-40 dBFS), so nothing
    /// the app treats as speech anywhere else is discarded here as silence.
    public static let silenceFrameRMS: Float = 0.005
    public static let silenceFrameSampleCount = sampleRate / 10

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
        guard totalSampleCount > maximumSilentDiscardSampleCount || containsSpeechEnergy(residentSamples) else {
            return .silent
        }
        return totalSampleCount < minimumSampleCount ? .tooShort : nil
    }

    /// Short frames, so a single soft word is not averaged away across a
    /// whole-second block. A trailing partial frame still counts.
    public static func containsSpeechEnergy(_ samples: [Float]) -> Bool {
        for start in stride(from: 0, to: samples.count, by: silenceFrameSampleCount) {
            let frame = samples[start..<min(samples.count, start + silenceFrameSampleCount)]
            let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
            if meanSquare.squareRoot() >= silenceFrameRMS { return true }
        }
        return false
    }
}

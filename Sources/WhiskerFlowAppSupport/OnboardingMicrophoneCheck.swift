import Foundation
import WhiskerFlowCore

/// "Say something": decides whether the microphone heard a voice, on top of
/// the same rolling assessment the recording HUD uses for its warnings.
///
/// Levels are the capture tap's normalized RMS (-50...0 dBFS mapped to 0...1).
/// Room tone sits below ~0.15; conversational speech a foot or two from a
/// laptop mic lands around 0.45–0.75.
public struct OnboardingMicrophoneCheck: Sendable {
    public enum State: Equatable, Sendable {
        case listening
        case heardSpeech
        /// Nothing voice-like after `quietVerdictSeconds`.
        case tooQuiet
    }

    /// About -29 dBFS: clearly above room tone, comfortably below normal speech.
    public static let speechLevelThreshold: Float = 0.42
    /// Cumulative, not contiguous: short words with pauses still count.
    public static let requiredSpeechSeconds: TimeInterval = 0.4
    public static let quietVerdictSeconds: TimeInterval = 5
    /// A stalled tap delivering one late buffer must not count as a long one.
    private static let maxBufferSeconds: TimeInterval = 0.25

    private var assessor = AudioSignalAssessor(now: { 0 })
    private var startedAt: TimeInterval?
    private var lastTime: TimeInterval?
    private var speechSeconds: TimeInterval = 0
    public private(set) var state: State = .listening
    public private(set) var loudestLevel: Float = 0

    public init() {}

    /// A clipping or too-quiet verdict from the shared assessor, if any.
    public var signalWarning: AudioSignalQuality? {
        assessor.quality.isWarning ? assessor.quality : nil
    }

    public mutating func reset() {
        self = OnboardingMicrophoneCheck()
    }

    @discardableResult
    public mutating func ingest(level: Float, peak: Float, at time: TimeInterval) -> State {
        let start = startedAt ?? time
        startedAt = start
        let delta = lastTime.map { min(max(0, time - $0), Self.maxBufferSeconds) } ?? 0.1
        lastTime = time
        loudestLevel = max(loudestLevel, level)
        assessor.ingest(level: level, peak: peak, at: time)
        if level >= Self.speechLevelThreshold { speechSeconds += delta }

        if state == .heardSpeech { return state }
        if speechSeconds >= Self.requiredSpeechSeconds {
            state = .heardSpeech
        } else if time - start >= Self.quietVerdictSeconds {
            state = .tooQuiet
        } else {
            state = .listening
        }
        return state
    }
}

/// How an input device is connected, reduced to what matters for dictation.
public enum AudioInputTransport: Equatable, Sendable {
    /// `wireless`: an iPhone microphone over Continuity, or AirPlay.
    case builtIn, usb, bluetooth, wireless, virtual, aggregate, other
}

/// Whether dictation may keep a capture engine prepared on an input while
/// idle, so the next press starts instantly.
///
/// Never on Bluetooth or other wireless microphones: holding a prepared
/// engine on a headset's microphone switches the headset from its
/// high-quality playback profile to its call profile, and every device change
/// rebuilt the engine and switched it again. On the Mac's speakers or wired
/// headphones that cost nothing; on Bluetooth headphones it broke playback
/// even when nobody was dictating.
public enum CaptureReadinessPolicy {
    public static func keepsEngineReady(transport: AudioInputTransport?, name: String) -> Bool {
        guard let transport else { return false }
        switch transport {
        case .bluetooth, .wireless: return false
        case .builtIn, .usb, .virtual, .aggregate, .other:
            let lowered = name.lowercased()
            // Some Bluetooth headsets appear behind an aggregate or with an
            // unexpected transport; their names give them away.
            return !["airpods", "beats", "bluetooth", "buds", "headset"].contains { lowered.contains($0) }
        }
    }
}

public enum MicrophoneInputAdvice: Equatable, Sendable {
    /// Bluetooth headsets drop to a narrow-band call codec while their mic is open.
    case bluetoothLowQuality
    /// A software device (e.g. a meeting app's loopback) may carry no voice at all.
    case virtualDevice

    public static func advice(transport: AudioInputTransport, name: String) -> MicrophoneInputAdvice? {
        let lowered = name.lowercased()
        if transport == .bluetooth || lowered.contains("airpods") || lowered.contains("beats") {
            return .bluetoothLowQuality
        }
        if transport == .virtual { return .virtualDevice }
        return nil
    }

    public var message: String {
        switch self {
        case .bluetoothLowQuality:
            return "AirPods and other Bluetooth mics switch to a lower-quality call mode while recording. Your Mac’s built-in or a wired mic will usually transcribe more accurately."
        case .virtualDevice:
            return "This looks like a virtual audio device. Pick a real microphone unless you know it carries your voice."
        }
    }
}

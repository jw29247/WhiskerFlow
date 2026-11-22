import Foundation
import WhiskerFlowCore

/// Why a toggle recording stopped by itself.
public enum ToggleAutoStop: String, Equatable, Sendable {
    /// A minute without speech after something was said.
    case silence
    /// A minute without speech and nothing was said at all.
    case noSpeech = "no_speech"
    /// The recording reached its maximum length.
    case maximumLength = "maximum_length"

    /// Shown in the HUD and on the Dictate screen once the text is saved.
    public func savedMessage(copiedToClipboard: Bool) -> String {
        let saved = copiedToClipboard ? "Your text is in History and on the clipboard." : "Your text is in History."
        return "\(stoppedAfter) \(saved)"
    }

    /// Shown when the recognizer heard nothing either, and the recording was discarded.
    public var nothingSaidMessage: String { "\(stoppedAfter) Nothing was said." }

    private var stoppedAfter: String {
        switch self {
        case .silence, .noSpeech: return "Stopped after a minute of silence."
        case .maximumLength: return "Stopped after \(Int(ToggleRecordingLimits.maximumSeconds / 60)) minutes."
        }
    }
}

/// What the Dictate screen says after a toggle recording stopped itself.
public struct AutoStopNotice: Equatable, Sendable {
    public let message: String
    /// The saved transcript, when there is one.
    public let recordID: UUID?

    public init(message: String, recordID: UUID?) {
        self.message = message
        self.recordID = recordID
    }
}

/// A forgotten toggle recording would keep the microphone live for ever. These
/// limits stop it: after a minute without speech, or at 30 minutes.
///
/// Speech is the level the capture tap already reports for each buffer, judged
/// against the HUD's "too quiet" line. The caller notes it once a second at
/// most; nothing here runs per buffer. Times are `systemUptime` seconds, so
/// tests inject them.
public struct ToggleRecordingLimits: Equatable, Sendable {
    public static let silenceSeconds: TimeInterval = 60
    public static let maximumSeconds: TimeInterval = 30 * 60
    /// A buffer at or above this normalized level counts as speech (about -45 dBFS).
    public static let speechLevel: Float = AudioSignalAssessor.quietLevelThreshold

    public let startedAt: TimeInterval
    public private(set) var lastSpeechAt: TimeInterval?

    /// Only a toggle dictation can be forgotten: hold-to-talk and the Assistant
    /// shortcuts end on release, and meetings have their own capture.
    public static func apply(to mode: RecordingMode, assistantShortcut: Bool) -> Bool {
        mode == .toggle && !assistantShortcut
    }

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    public mutating func noteSpeech(at time: TimeInterval) {
        lastSpeechAt = max(lastSpeechAt ?? time, time)
    }

    /// The limit reached at `time`, if any. Silence counts from the last speech,
    /// or from the start when nothing has been said.
    public func autoStop(at time: TimeInterval) -> ToggleAutoStop? {
        if time - startedAt >= Self.maximumSeconds { return .maximumLength }
        guard time - (lastSpeechAt ?? startedAt) >= Self.silenceSeconds else { return nil }
        return lastSpeechAt == nil ? .noSpeech : .silence
    }
}

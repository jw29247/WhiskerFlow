import Foundation

/// Which transcription backend handles a recording.
public enum TranscriptionEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case parakeetTDTv3
    case appleSpeech

    public var id: String { rawValue }

    public static let defaultEngine: TranscriptionEngineKind = .parakeetTDTv3

    /// Whisper (WhisperKit and the Whisper CLI) was removed: every recording now
    /// goes through Parakeet, so a stored Whisper choice, or anything unknown,
    /// resolves to the default.
    public static func engineForStoredPreferences(rawValue: String?) -> TranscriptionEngineKind {
        rawValue.flatMap(TranscriptionEngineKind.init(rawValue:)) ?? defaultEngine
    }

    /// The label for an engine recorded in History, including the removed ones.
    public static func displayName(forStored rawValue: String) -> String {
        if let engine = TranscriptionEngineKind(rawValue: rawValue) { return engine.displayName }
        switch rawValue {
        case "whisperKit": return "WhisperKit (removed)"
        case "whisperCLI": return "Whisper CLI (removed)"
        default: return rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .parakeetTDTv3: return "Parakeet TDT v3 (on-device)"
        case .appleSpeech: return "Apple Speech (built-in)"
        }
    }

    /// The model a record or receipt names.
    public var modelIdentifier: String {
        switch self {
        case .parakeetTDTv3: return "parakeet-tdt-0.6b-v3"
        case .appleSpeech: return "apple-speech"
        }
    }

    public var blurb: String {
        switch self {
        case .parakeetTDTv3: return "Fast, accurate on-device dictation, recommended for near-instant results."
        case .appleSpeech: return "No download, fully offline, built into macOS."
        }
    }
}

/// How the push-to-talk trigger behaves.
public enum RecordingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case holdToTalk
    case toggle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .holdToTalk: return "Hold to talk"
        case .toggle: return "Tap to start / stop"
        }
    }
}

/// What WhiskerFlow does with a finished transcript.
public enum DeliveryMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case pasteAtCursor
    case copyOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pasteAtCursor: return "Paste at the cursor"
        case .copyOnly: return "Copy to clipboard only"
        }
    }
}

/// Dictionary terms a recogniser may be told to expect. Each engine has its own
/// switch, and an engine whose switch is off never sees the terms.
/// Post-recognition replacement runs either way; hints only change what the
/// recogniser proposes.
public struct RecognizerHints: Sendable, Equatable {
    public var terms: [String]
    public var appleSpeech: Bool
    public var parakeet: Bool

    public init(terms: [String], appleSpeech: Bool = false, parakeet: Bool = false) {
        self.terms = terms
        self.appleSpeech = appleSpeech
        self.parakeet = parakeet
    }

    public static let none = RecognizerHints(terms: [])

    /// The terms `engine` should use, or none when its switch is off.
    public func terms(for engine: TranscriptionEngineKind) -> [String] {
        switch engine {
        case .appleSpeech: return appleSpeech ? terms : []
        case .parakeetTDTv3: return parakeet ? terms : []
        }
    }
}

public struct TranscriptionRequest: Sendable {
    public var audioURL: URL
    /// BCP-47 language code, or nil to let the engine auto-detect.
    public var language: String?
    public var hints: RecognizerHints

    public init(
        audioURL: URL,
        language: String? = "en",
        hints: RecognizerHints = .none
    ) {
        self.audioURL = audioURL
        self.language = language
        self.hints = hints
    }
}

public struct TranscriptionSegment: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptionSegment]
    public var language: String?
    public var duration: Double?

    public init(
        text: String,
        segments: [TranscriptionSegment] = [],
        language: String? = nil,
        duration: Double? = nil
    ) {
        self.text = text
        self.segments = segments
        self.language = language
        self.duration = duration
    }
}

public enum TranscriptionError: LocalizedError, Equatable {
    case engineUnavailable(TranscriptionEngineKind)
    case modelUnavailable(String)
    case emptyTranscript
    case cancelled
    case timedOut(seconds: Int)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let kind):
            return "\(kind.displayName) is not available."
        case .modelUnavailable(let model):
            return "Could not load the \(model) model."
        case .emptyTranscript:
            return "No speech was detected."
        case .cancelled:
            return "Transcription was cancelled."
        case .timedOut(let seconds):
            return "Transcription timed out after \(seconds)s."
        case .underlying(let message):
            return message
        }
    }
}

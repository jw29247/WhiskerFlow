import Foundation

/// Which transcription backend handles a recording.
public enum TranscriptionEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case whisperKit
    case appleSpeech
    case whisperCLI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .whisperKit: return "WhisperKit (on-device)"
        case .appleSpeech: return "Apple Speech (built-in)"
        case .whisperCLI: return "Whisper CLI (advanced)"
        }
    }

    public var blurb: String {
        switch self {
        case .whisperKit: return "Fast, accurate, runs on the Neural Engine. Downloads a model on first use."
        case .appleSpeech: return "No download, fully offline, built into macOS."
        case .whisperCLI: return "Use your own openai-whisper command. Requires a local install."
        }
    }
}

/// Logical Whisper model size. Each engine maps this to its own identifier.
public enum WhisperModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case tiny
    case base
    case small
    case medium

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tiny: return "Tiny — fastest"
        case .base: return "Base — balanced (recommended)"
        case .small: return "Small — more accurate"
        case .medium: return "Medium — most accurate, slower"
        }
    }

    /// English-only CoreML model identifier used by WhisperKit.
    public var whisperKitIdentifier: String {
        switch self {
        case .tiny: return "openai_whisper-tiny.en"
        case .base: return "openai_whisper-base.en"
        case .small: return "openai_whisper-small.en"
        case .medium: return "openai_whisper-medium.en"
        }
    }

    /// Model name passed to the openai-whisper CLI (`--model`).
    public var cliIdentifier: String { rawValue }
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

public struct TranscriptionRequest: Sendable {
    public var audioURL: URL
    /// BCP-47 language code, or nil to let the engine auto-detect.
    public var language: String?
    /// Optional priming text (names, jargon) to bias recognition.
    public var initialPrompt: String?
    public var model: WhisperModel

    public init(
        audioURL: URL,
        language: String? = "en",
        initialPrompt: String? = nil,
        model: WhisperModel = .base
    ) {
        self.audioURL = audioURL
        self.language = language
        self.initialPrompt = initialPrompt
        self.model = model
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

/// A pluggable speech-to-text backend.
public protocol TranscriptionEngine: Sendable {
    var kind: TranscriptionEngineKind { get }

    /// Whether the engine can run right now (e.g. CLI installed, permission granted).
    func isAvailable() async -> Bool

    /// Warm up / load the model so the first real transcription isn't penalized.
    func prepare(model: WhisperModel) async throws

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

public extension TranscriptionEngine {
    func isAvailable() async -> Bool { true }
    func prepare(model: WhisperModel) async throws {}
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

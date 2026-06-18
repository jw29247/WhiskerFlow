import Foundation
import WhiskerFlowCore

struct TranscriptionOutcome: Sendable {
    let result: TranscriptionResult
    let engine: TranscriptionEngineKind
}

/// Picks the configured engine, warms it up, and falls back to Apple Speech
/// when the primary engine is unavailable or fails (e.g. offline first run).
actor TranscriptionService {
    private let whisperKit = WhisperKitEngine()
    private let appleSpeech = AppleSpeechEngine()

    @discardableResult
    func prepare(kind: TranscriptionEngineKind, model: WhisperModel) async -> Bool {
        switch kind {
        case .whisperKit:
            do {
                try await whisperKit.prepare(model: model)
                return true
            } catch {
                return false
            }
        case .appleSpeech:
            return await appleSpeech.requestAuthorization()
        case .whisperCLI:
            return true
        }
    }

    func requestAppleSpeechAuthorization() async -> Bool {
        await appleSpeech.requestAuthorization()
    }

    /// Transcribe an in-memory 16 kHz mono float buffer with the warm WhisperKit
    /// pipe (single shared model instance — no extra load). Drives live dictation.
    func transcribeSamples(_ samples: [Float], language: String?, model: WhisperModel) async throws -> TranscriptionResult {
        try await whisperKit.transcribe(samples: samples, language: language, model: model)
    }

    func transcribe(
        audioURL: URL,
        kind: TranscriptionEngineKind,
        model: WhisperModel,
        language: String?,
        initialPrompt: String?,
        cliConfiguration: WhisperConfiguration,
        allowAppleFallback: Bool
    ) async throws -> TranscriptionOutcome {
        let request = TranscriptionRequest(
            audioURL: audioURL,
            language: language,
            initialPrompt: initialPrompt,
            model: model
        )

        do {
            let result = try await primaryTranscribe(request, kind: kind, cliConfiguration: cliConfiguration)
            return TranscriptionOutcome(result: result, engine: kind)
        } catch {
            if Task.isCancelled { throw error }
            if allowAppleFallback, kind != .appleSpeech {
                if let fallback = try? await appleSpeech.transcribe(request) {
                    return TranscriptionOutcome(result: fallback, engine: .appleSpeech)
                }
            }
            throw error
        }
    }

    private func primaryTranscribe(
        _ request: TranscriptionRequest,
        kind: TranscriptionEngineKind,
        cliConfiguration: WhisperConfiguration
    ) async throws -> TranscriptionResult {
        switch kind {
        case .whisperKit:
            return try await whisperKit.transcribe(request)
        case .appleSpeech:
            return try await appleSpeech.transcribe(request)
        case .whisperCLI:
            return try await WhisperCLIEngine(configuration: cliConfiguration).transcribe(request)
        }
    }
}

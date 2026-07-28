import AVFoundation
import Foundation
@preconcurrency import WhisperKit
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Primary engine: on-device Whisper via CoreML / Neural Engine. The model is
/// loaded once and kept warm, so only the first transcription pays the load cost.
actor WhisperKitEngine: TranscriptionEngine {
    private var pipe: WhisperKit?
    /// Keyed by identifier, not by `WhisperModel`, so switching between the
    /// English-only and multilingual variants of one size reloads the pipe.
    private var loadedIdentifier: String?

    nonisolated var kind: TranscriptionEngineKind { .whisperKit }

    func isAvailable() async -> Bool { true }

    func prepare(model: WhisperModel, language: String?) async throws {
        let identifier = model.whisperKitIdentifier(
            multilingual: WhisperModel.requiresMultilingualModel(language: language)
        )
        if pipe != nil, loadedIdentifier == identifier { return }

        do {
            let downloadBase = try ModelStoragePaths.prepareWhisperKitDownloadBase()
            let localAssets = try ModelStoragePaths.prepareLocalAssets(
                modelIdentifier: identifier
            )
            let kit: WhisperKit
            if let localAssets {
                kit = try await WhisperKit(
                    modelFolder: localAssets.modelFolder.path,
                    tokenizerFolder: localAssets.tokenizerDownloadBase,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
            } else {
                kit = try await WhisperKit(
                    model: identifier,
                    downloadBase: downloadBase,
                    tokenizerFolder: downloadBase,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: true
                )
            }
            pipe = kit
            loadedIdentifier = identifier
        } catch {
            pipe = nil
            loadedIdentifier = nil
            throw TranscriptionError.modelUnavailable(model.displayName)
        }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepare(model: request.model, language: request.language)
        guard let pipe else {
            throw TranscriptionError.modelUnavailable(request.model.displayName)
        }

        let deadline = Self.audioSeconds(at: request.audioURL)
            .map(DecodeTimeoutPolicy.timeout(forAudioSeconds:)) ?? DecodeTimeoutPolicy.maximumTimeout
        let results = try await decode(seconds: deadline) {
            try await pipe.transcribe(
                audioPath: request.audioURL.path,
                decodeOptions: Self.decodingOptions(language: request.language)
            )
        }

        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }

        let segments = results.flatMap(\.segments).map {
            WhiskerFlowCore.TranscriptionSegment(text: $0.text, start: Double($0.start), end: Double($0.end))
        }

        return WhiskerFlowCore.TranscriptionResult(
            text: text.plainTranscriptText,
            segments: segments,
            language: results.first?.language ?? request.language,
            duration: results.first?.timings.inputAudioSeconds
        )
    }

    /// Transcribe an in-memory 16 kHz mono float buffer using the warm pipe.
    /// Used by the live dictation loop. An empty result yields an empty string
    /// (a partial that hasn't caught any speech yet is not an error).
    func transcribe(samples: [Float], language: String?, model: WhisperModel) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepare(model: model, language: language)
        guard let pipe else {
            throw TranscriptionError.modelUnavailable(model.displayName)
        }

        // A live window is bounded by `LiveDecodeWindowPolicy.hardCapSeconds`, so it
        // gets the tight live budget rather than the file-decode budget: the release
        // path awaits these serially and the finish watchdog has to outlast them.
        let results = try await decode(seconds: DecodeTimeoutPolicy.livePartialTimeout) {
            try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodingOptions(language: language)
            )
        }

        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return WhiskerFlowCore.TranscriptionResult(
            text: text.plainTranscriptText,
            language: results.first?.language ?? language,
            duration: results.first?.timings.inputAudioSeconds
        )
    }

    /// Run a decode under an abandoning deadline. A timed-out decode leaves the
    /// pipe wedged, so drop it and force a fresh load next time.
    private func decode<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withAbandoningDeadline(seconds: seconds, operation: operation)
        } catch AsyncTimeoutError.timedOut {
            pipe = nil
            loadedIdentifier = nil
            throw TranscriptionError.timedOut(seconds: Int(seconds))
        }
    }

    private static func audioSeconds(at url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    private static func decodingOptions(language: String?) -> DecodingOptions {
        // WhisperKit 0.13 derives `detectLanguage` from `!usePrefillPrompt`, so
        // auto-detect stays off unless forced on. A nil language is the only
        // case that needs it, and it always loads the multilingual weights.
        DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
    }
}

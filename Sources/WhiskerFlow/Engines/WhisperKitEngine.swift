import Foundation
import WhisperKit
import WhiskerFlowCore

/// Primary engine: on-device Whisper via CoreML / Neural Engine. The model is
/// loaded once and kept warm, so only the first transcription pays the load cost.
actor WhisperKitEngine: TranscriptionEngine {
    private var pipe: WhisperKit?
    private var loadedModel: WhisperModel?

    nonisolated var kind: TranscriptionEngineKind { .whisperKit }

    func isAvailable() async -> Bool { true }

    func prepare(model: WhisperModel) async throws {
        if pipe != nil, loadedModel == model { return }

        do {
            let kit = try await WhisperKit(
                model: model.whisperKitIdentifier,
                verbose: false,
                prewarm: true,
                load: true,
                download: true
            )
            pipe = kit
            loadedModel = model
        } catch {
            pipe = nil
            loadedModel = nil
            throw TranscriptionError.modelUnavailable(model.displayName)
        }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepare(model: request.model)
        guard let pipe else {
            throw TranscriptionError.modelUnavailable(request.model.displayName)
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: request.language,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )

        let results = try await pipe.transcribe(audioPath: request.audioURL.path, decodeOptions: options)

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
}
